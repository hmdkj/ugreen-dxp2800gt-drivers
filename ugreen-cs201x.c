// SPDX-License-Identifier: GPL-2.0-only
/*
 * ugreen-cs201x - hwmon driver for the Chipsea CS201x Super I/O / EC
 *		   as found in the UGREEN NASync DXP2800 GT.
 *
 * Derived from drivers/ugreen/ug_201x.c of UGREEN's GPL kernel release
 *   https://github.com/ugreen-opensource/kernel-6.12
 *   ("Description: For 2800gt", "Chip: CSCS201X", Author: Jason.Li,
 *    lijiang@ugreen.com, SPDX-License-Identifier: GPL-2.0-only)
 *
 * The vendor driver exposes fans and temperatures through a private
 * /proc/it86/ text interface and bundles them with watchdog, ARGB LED and
 * power-restore support. This rewrite keeps only the fan and temperature
 * paths and exports them through the standard hwmon ABI, so that
 * lm-sensors / fancontrol and anything else that speaks hwmon can use them.
 *
 * Register map and access sequences are taken verbatim from the vendor
 * driver; the differences are:
 *
 *  - hwmon registration instead of procfs
 *  - the EC I/O window is claimed with devm_request_region() and checked
 *    against ACPI reservations (the vendor driver claims only 0x2e/0x2f,
 *    and even talks to the EC after having released that region)
 *  - DMI product-name match in addition to the Super I/O chip ID, so the
 *    module cannot poke 0x2e on an unrelated machine
 *  - readings are cached for HZ/2 (hwmon reads one attribute per file, so
 *    an uncached "sensors" run would issue a dozen EC transactions)
 *  - all state is per-device and static; no global symbols
 *  - vendor's ug_msleep() is dropped: it compiles to a no-op unless
 *    CONFIG_UG_FEAT_MSLEEP is defined, and that config exists neither in
 *    the vendor Kconfig nor in ug_x86_64_defconfig, so the shipping UGOS
 *    build runs these sequences with no delay at all
 */

#include <linux/acpi.h>
#include <linux/auxiliary_bus.h>
#include <linux/delay.h>
#include <linux/dmi.h>
#include <linux/hwmon.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/slab.h>

#include "ugreen-cs201x.h"

#define DRVNAME			"ugreen-cs201x"
#define HWMON_NAME		"ugreen_cs201x"

/* Super I/O configuration space */
#define SIO_ADDR_PORT		0x2e
#define SIO_DATA_PORT		0x2f
#define SIO_REGION_LEN		2

#define SIO_REG_LDN		0x07
#define SIO_REG_CHIPID		0x20	/* 16 bit, 0x20 = MSB */
#define SIO_REG_CHIPREV		0x22	/* 16 bit */
#define SIO_REG_BASE		0x60	/* 16 bit, 0x60 = MSB */
#define SIO_REG_ENABLE		0x30

#define SIO_LDN_HOST2EC		0x0a
#define CS201X_CHIP_ID		0x2011

/* Host2EC indirect memory access (IMA) window, relative to its base */
#define IMA_HOST_CTS		0x00
#define IMA_CTRL		0x01	/* 0: no auto-increment, single byte */
#define IMA_ADDR		0x04	/* 4 bytes, EC address */
#define IMA_DATA		0x08
#define IMA_SEM			0x0c
#define IMA_REGION_LEN		0x10

/* EC address space */
#define EC_FAN_EN(ch)		(0x200053f0u + (ch))
#define EC_FAN_DUTY(ch)		(0x200053f4u + (ch))	/* 0-100, percent */
#define EC_FAN_SPEED_H(ch)	(0x200053f8u + 2 * (ch))
#define EC_FAN_SPEED_L(ch)	(0x200053f9u + 2 * (ch))

#define EC_ADC_CH2_CFG		0x20005370u
#define EC_ADC_CH4_CFG		0x20005371u
#define EC_NTC2_TEMP		0x200053e2u		/* vendor: cpu_temp */
#define EC_NTC4_TEMP		0x200053e4u		/* vendor: board_temp */

/*
 * The ARGB LED block, as far as the vendor driver uses it: 4 channels with
 * mode/light/period/duty bytes at 0x...00-0x...0f, flow control at 0x...40 and
 * three colour bytes per channel at 0x...44-0x...52. ugreen-cs201x-leds may
 * only access this range; the fan and temperature registers are below it.
 */
#define EC_LED_FIRST		0x20005400u
#define EC_LED_LAST		0x2000545fu

#define UGREEN_CS201X_NUM_FANS	2
#define UGREEN_CS201X_NUM_TEMPS	2

#define CACHE_INTERVAL		(HZ / 2)

/*
 * The EC duty register is a percentage while hwmon pwm* is 0-255.
 * Round-trip through the vendor's scaling so that a value written to pwm1
 * reads back as closely as the hardware allows.
 */
#define PWM_TO_DUTY(pwm)	((pwm) * 100 / 255)
#define DUTY_TO_PWM(duty)	DIV_ROUND_CLOSEST((duty) * 255, 100)

static bool force;
module_param(force, bool, 0);
MODULE_PARM_DESC(force,
		 "Skip the DMI product-name check (the Super I/O chip ID is still verified)");

static bool pwm_readback = true;
module_param(pwm_readback, bool, 0644);
MODULE_PARM_DESC(pwm_readback,
		 "Read pwm* back from the EC duty register (default). Set to 0 to report the last written value instead");

static int unload_pwm = -1;
module_param(unload_pwm, int, 0644);
MODULE_PARM_DESC(unload_pwm,
		 "PWM value (0-255) to program into both fans on module unload; -1 (default) leaves the EC untouched");

struct ugreen_cs201x_data {
	struct mutex lock;		/* serialises all EC access */
	u16 ec_base;
	unsigned long last_updated;	/* jiffies of the last cache refresh */
	bool valid;
	u16 rpm[UGREEN_CS201X_NUM_FANS];
	u8 duty[UGREEN_CS201X_NUM_FANS];	/* as read from the EC */
	u8 pwm[UGREEN_CS201X_NUM_FANS];		/* as last written by us */
	u8 enable[UGREEN_CS201X_NUM_FANS];	/* FANx_EN, as last written by us */
	u8 temp[UGREEN_CS201X_NUM_TEMPS];
};

static const char * const ugreen_cs201x_fan_labels[UGREEN_CS201X_NUM_FANS] = {
	"CPU fan", "System fan",
};

static const char * const ugreen_cs201x_temp_labels[UGREEN_CS201X_NUM_TEMPS] = {
	"CPU NTC", "Board NTC",
};

/* ---------------------------------------------------------------- Super I/O */

/*
 * Unlock/lock sequences are Chipsea specific: 0xa5, 0x69, 0x87 to enter
 * configuration mode, the reverse order to leave it. Not the ITE 0x87 0x01
 * 0x55 0x55 sequence.
 */
static int superio_enter(void)
{
	if (!request_muxed_region(SIO_ADDR_PORT, SIO_REGION_LEN, DRVNAME))
		return -EBUSY;

	outb(0xa5, SIO_ADDR_PORT);
	outb(0x69, SIO_ADDR_PORT);
	outb(0x87, SIO_ADDR_PORT);
	usleep_range(50, 100);

	return 0;
}

static void superio_exit(void)
{
	outb(0x87, SIO_ADDR_PORT);
	outb(0x69, SIO_ADDR_PORT);
	outb(0xa5, SIO_ADDR_PORT);

	release_region(SIO_ADDR_PORT, SIO_REGION_LEN);
}

static u8 superio_inb(u8 reg)
{
	outb(reg, SIO_ADDR_PORT);
	return inb(SIO_DATA_PORT);
}

static void superio_outb(u8 reg, u8 val)
{
	outb(reg, SIO_ADDR_PORT);
	outb(val, SIO_DATA_PORT);
}

static u16 superio_inw(u8 reg)
{
	u16 val;

	val = superio_inb(reg) << 8;
	val |= superio_inb(reg + 1);

	return val;
}

static void superio_select(u8 ldn)
{
	superio_outb(SIO_REG_LDN, ldn);
}

/* --------------------------------------------------------------- EC access */

/*
 * The EC is reached through an indirect window: program a 32 bit EC address
 * (MSB first, as the vendor driver does) and then read or write IMA_DATA.
 * Caller must hold data->lock.
 */
static void ec_set_addr(struct ugreen_cs201x_data *data, u32 addr)
{
	u16 base = data->ec_base;

	outb(0x00, base + IMA_CTRL);
	outb(addr >> 24, base + IMA_ADDR + 3);
	outb(addr >> 16, base + IMA_ADDR + 2);
	outb(addr >> 8, base + IMA_ADDR + 1);
	outb(addr, base + IMA_ADDR);
}

static u8 ec_read_byte(struct ugreen_cs201x_data *data, u32 addr)
{
	ec_set_addr(data, addr);
	udelay(1);

	return inb(data->ec_base + IMA_DATA);
}

static void ec_write_byte(struct ugreen_cs201x_data *data, u32 addr, u8 val)
{
	ec_set_addr(data, addr);
	outb(val, data->ec_base + IMA_DATA);
}

/* Caller must hold data->lock. */
static void ugreen_cs201x_update(struct ugreen_cs201x_data *data)
{
	int i;

	if (data->valid && time_before(jiffies, data->last_updated + CACHE_INTERVAL))
		return;

	for (i = 0; i < UGREEN_CS201X_NUM_FANS; i++) {
		u8 lo = ec_read_byte(data, EC_FAN_SPEED_L(i));
		u8 hi = ec_read_byte(data, EC_FAN_SPEED_H(i));

		data->rpm[i] = (hi << 8) | lo;
		data->duty[i] = ec_read_byte(data, EC_FAN_DUTY(i));
	}

	data->temp[0] = ec_read_byte(data, EC_NTC2_TEMP);
	data->temp[1] = ec_read_byte(data, EC_NTC4_TEMP);

	data->last_updated = jiffies;
	data->valid = true;
}

/* ------------------------------------------------------------------- hwmon */

static umode_t ugreen_cs201x_is_visible(const void *drvdata,
					enum hwmon_sensor_types type,
					u32 attr, int channel)
{
	switch (type) {
	case hwmon_fan:
	case hwmon_temp:
		return 0444;
	case hwmon_pwm:
		return 0644;
	default:
		return 0;
	}
}

static int ugreen_cs201x_read(struct device *dev, enum hwmon_sensor_types type,
			      u32 attr, int channel, long *val)
{
	struct ugreen_cs201x_data *data = dev_get_drvdata(dev);
	int ret = 0;

	mutex_lock(&data->lock);
	ugreen_cs201x_update(data);

	switch (type) {
	case hwmon_fan:
		switch (attr) {
		case hwmon_fan_input:
			*val = data->rpm[channel];
			break;
		case hwmon_fan_fault:
			/*
			 * Only a fan that is being driven can be reported as
			 * faulty. Consider both what the EC says and what we
			 * last asked for, since the duty register may not be
			 * readable on all firmware revisions.
			 */
			*val = !data->rpm[channel] &&
			       (data->duty[channel] || data->pwm[channel]);
			break;
		default:
			ret = -EOPNOTSUPP;
		}
		break;
	case hwmon_pwm:
		switch (attr) {
		case hwmon_pwm_input:
			*val = pwm_readback
				? clamp_val(DUTY_TO_PWM(data->duty[channel]), 0, 255)
				: data->pwm[channel];
			break;
		case hwmon_pwm_enable:
			/*
			 * The CS201x has no automatic fan control mode; the
			 * FANx_EN bit only gates the PWM output, and we always
			 * keep it set. Report what we programmed rather than
			 * reading the bit back: it is not known whether that
			 * register reads back at all, and fancontrol refuses
			 * to start unless pwmN_enable reads exactly 1.
			 */
			*val = data->enable[channel];
			break;
		default:
			ret = -EOPNOTSUPP;
		}
		break;
	case hwmon_temp:
		switch (attr) {
		case hwmon_temp_input:
			/*
			 * The EC linearises the NTC itself and reports whole
			 * degrees Celsius. 0x00 and 0xff mean the channel is
			 * not (yet) sampling: report an error rather than a
			 * bogus low temperature, which would make a fan
			 * control daemon slow the fans down.
			 */
			if (!data->temp[channel] || data->temp[channel] == 0xff)
				ret = -ENODATA;
			else
				*val = data->temp[channel] * 1000;
			break;
		default:
			ret = -EOPNOTSUPP;
		}
		break;
	default:
		ret = -EOPNOTSUPP;
	}

	mutex_unlock(&data->lock);

	return ret;
}

static int ugreen_cs201x_write(struct device *dev, enum hwmon_sensor_types type,
			       u32 attr, int channel, long val)
{
	struct ugreen_cs201x_data *data = dev_get_drvdata(dev);
	int ret = 0;

	if (type != hwmon_pwm)
		return -EOPNOTSUPP;

	switch (attr) {
	case hwmon_pwm_input:
		if (val < 0 || val > 255)
			return -EINVAL;

		mutex_lock(&data->lock);
		ec_write_byte(data, EC_FAN_DUTY(channel), PWM_TO_DUTY(val));
		data->pwm[channel] = val;
		data->valid = false;
		mutex_unlock(&data->lock);
		break;
	case hwmon_pwm_enable:
		/*
		 * Only manual control exists. Refuse 0 instead of clearing
		 * FANx_EN: it is not known whether that leaves the fan at
		 * full speed (what pwm_enable == 0 means in the hwmon ABI)
		 * or stops it, and getting that wrong cooks the machine.
		 */
		if (val != 1)
			return -EOPNOTSUPP;

		mutex_lock(&data->lock);
		ec_write_byte(data, EC_FAN_EN(channel), 1);
		data->enable[channel] = 1;
		mutex_unlock(&data->lock);
		break;
	default:
		ret = -EOPNOTSUPP;
	}

	return ret;
}

static int ugreen_cs201x_read_string(struct device *dev,
				     enum hwmon_sensor_types type,
				     u32 attr, int channel, const char **str)
{
	switch (type) {
	case hwmon_fan:
		if (attr != hwmon_fan_label)
			return -EOPNOTSUPP;
		*str = ugreen_cs201x_fan_labels[channel];
		return 0;
	case hwmon_temp:
		if (attr != hwmon_temp_label)
			return -EOPNOTSUPP;
		*str = ugreen_cs201x_temp_labels[channel];
		return 0;
	default:
		return -EOPNOTSUPP;
	}
}

static const struct hwmon_ops ugreen_cs201x_hwmon_ops = {
	.is_visible = ugreen_cs201x_is_visible,
	.read = ugreen_cs201x_read,
	.read_string = ugreen_cs201x_read_string,
	.write = ugreen_cs201x_write,
};

static const struct hwmon_channel_info * const ugreen_cs201x_hwmon_info[] = {
	HWMON_CHANNEL_INFO(fan,
			   HWMON_F_INPUT | HWMON_F_LABEL | HWMON_F_FAULT,
			   HWMON_F_INPUT | HWMON_F_LABEL | HWMON_F_FAULT),
	HWMON_CHANNEL_INFO(pwm,
			   HWMON_PWM_INPUT | HWMON_PWM_ENABLE,
			   HWMON_PWM_INPUT | HWMON_PWM_ENABLE),
	HWMON_CHANNEL_INFO(temp,
			   HWMON_T_INPUT | HWMON_T_LABEL,
			   HWMON_T_INPUT | HWMON_T_LABEL),
	NULL
};

static const struct hwmon_chip_info ugreen_cs201x_chip_info = {
	.ops = &ugreen_cs201x_hwmon_ops,
	.info = ugreen_cs201x_hwmon_info,
};

/* ------------------------------------------------- EC access for the LED module */

static bool ugreen_cs201x_led_addr_ok(u32 addr)
{
	return addr >= EC_LED_FIRST && addr <= EC_LED_LAST;
}

static int ugreen_cs201x_led_ec_read(struct device *ecdev, u32 addr, u8 *val)
{
	struct ugreen_cs201x_data *data = dev_get_drvdata(ecdev);

	if (!ugreen_cs201x_led_addr_ok(addr))
		return -EINVAL;

	mutex_lock(&data->lock);
	*val = ec_read_byte(data, addr);
	mutex_unlock(&data->lock);

	return 0;
}

static int ugreen_cs201x_led_ec_write(struct device *ecdev, u32 addr, u8 val)
{
	struct ugreen_cs201x_data *data = dev_get_drvdata(ecdev);

	if (!ugreen_cs201x_led_addr_ok(addr))
		return -EINVAL;

	mutex_lock(&data->lock);
	ec_write_byte(data, addr, val);
	mutex_unlock(&data->lock);

	return 0;
}

static const struct ugreen_cs201x_ec_ops ugreen_cs201x_led_ec_ops = {
	.read = ugreen_cs201x_led_ec_read,
	.write = ugreen_cs201x_led_ec_write,
};

static void ugreen_cs201x_aux_release(struct device *dev)
{
	struct ugreen_cs201x_aux_device *aux =
		container_of(to_auxiliary_dev(dev), struct ugreen_cs201x_aux_device, adev);

	kfree(aux);
}

static void ugreen_cs201x_aux_unregister(void *arg)
{
	struct ugreen_cs201x_aux_device *aux = arg;

	auxiliary_device_delete(&aux->adev);
	auxiliary_device_uninit(&aux->adev);
}

/* Publish the LED block of the EC to ugreen-cs201x-leds, if it is loaded. */
static int ugreen_cs201x_add_led_aux(struct device *dev)
{
	struct ugreen_cs201x_aux_device *aux;
	int ret;

	aux = kzalloc(sizeof(*aux), GFP_KERNEL);
	if (!aux)
		return -ENOMEM;

	aux->adev.name = UGREEN_CS201X_AUX_LEDS_NAME;
	aux->adev.id = 0;
	aux->adev.dev.parent = dev;
	aux->adev.dev.release = ugreen_cs201x_aux_release;
	aux->ecdev = dev;
	aux->ops = &ugreen_cs201x_led_ec_ops;

	ret = auxiliary_device_init(&aux->adev);
	if (ret) {
		kfree(aux);
		return ret;
	}

	ret = auxiliary_device_add(&aux->adev);
	if (ret) {
		auxiliary_device_uninit(&aux->adev);	/* frees aux */
		return ret;
	}

	return devm_add_action_or_reset(dev, ugreen_cs201x_aux_unregister, aux);
}

/* ---------------------------------------------------------- platform driver */

static int ugreen_cs201x_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct ugreen_cs201x_data *data;
	struct device *hwmon_dev;
	struct resource *res;
	int i, ret;

	res = platform_get_resource(pdev, IORESOURCE_IO, 0);
	if (!res)
		return -ENODEV;

	if (!devm_request_region(dev, res->start, resource_size(res), DRVNAME)) {
		dev_err(dev, "failed to claim EC I/O window %pR\n", res);
		return -EBUSY;
	}

	data = devm_kzalloc(dev, sizeof(*data), GFP_KERNEL);
	if (!data)
		return -ENOMEM;

	data->ec_base = res->start;
	mutex_init(&data->lock);
	platform_set_drvdata(pdev, data);

	/*
	 * Enable both fan PWM outputs and put ADC channels 2 and 4 into
	 * temperature mode, exactly as the vendor driver's InitEc() does.
	 */
	mutex_lock(&data->lock);
	for (i = 0; i < UGREEN_CS201X_NUM_FANS; i++) {
		ec_write_byte(data, EC_FAN_EN(i), 1);
		data->enable[i] = 1;
		/*
		 * Seed the shadow pwm value from whatever the EC is currently
		 * driving, so that pwm_readback=0 does not report 0 until
		 * something writes pwm* for the first time.
		 */
		data->pwm[i] = clamp_val(DUTY_TO_PWM(ec_read_byte(data, EC_FAN_DUTY(i))),
					 0, 255);
	}
	ec_write_byte(data, EC_ADC_CH2_CFG, 1);
	ec_write_byte(data, EC_ADC_CH4_CFG, 1);
	mutex_unlock(&data->lock);

	hwmon_dev = devm_hwmon_device_register_with_info(dev, HWMON_NAME, data,
							&ugreen_cs201x_chip_info,
							NULL);
	if (IS_ERR(hwmon_dev))
		return PTR_ERR(hwmon_dev);

	dev_info(dev, "CS201x EC at %#x, hwmon: %s\n", data->ec_base,
		 dev_name(hwmon_dev));

	/*
	 * The LEDs are optional: the fans must keep working if the auxiliary
	 * device cannot be created.
	 */
	ret = ugreen_cs201x_add_led_aux(dev);
	if (ret)
		dev_warn(dev, "LED interface unavailable: %d\n", ret);

	return 0;
}

static void ugreen_cs201x_remove(struct platform_device *pdev)
{
	struct ugreen_cs201x_data *data = platform_get_drvdata(pdev);
	int i;

	if (unload_pwm < 0 || unload_pwm > 255)
		return;

	mutex_lock(&data->lock);
	for (i = 0; i < UGREEN_CS201X_NUM_FANS; i++)
		ec_write_byte(data, EC_FAN_DUTY(i), PWM_TO_DUTY(unload_pwm));
	mutex_unlock(&data->lock);

	dev_info(&pdev->dev, "left both fans at pwm %d\n", unload_pwm);
}

static struct platform_driver ugreen_cs201x_driver = {
	.driver = {
		.name = DRVNAME,
	},
	.probe = ugreen_cs201x_probe,
	.remove = ugreen_cs201x_remove,
};

static struct platform_device *ugreen_cs201x_pdev;

/*
 * Not __initconst: MODULE_DEVICE_TABLE() aliases the symbol so that udev can
 * autoload the module from the machine's dmi: modalias.
 */
static const struct dmi_system_id ugreen_cs201x_dmi_table[] = {
	{
		.matches = {
			DMI_EXACT_MATCH(DMI_PRODUCT_NAME, "DXP2800 GT"),
		},
	},
	{}
};
MODULE_DEVICE_TABLE(dmi, ugreen_cs201x_dmi_table);

/* Identify the chip and read out the address of the Host2EC IMA window. */
static int __init ugreen_cs201x_find(u16 *ec_base)
{
	u16 chip_id, chip_rev, base;
	int ret;

	ret = superio_enter();
	if (ret) {
		pr_err(DRVNAME ": Super I/O ports %#x-%#x are busy\n",
		       SIO_ADDR_PORT, SIO_ADDR_PORT + SIO_REGION_LEN - 1);
		return ret;
	}

	chip_id = superio_inw(SIO_REG_CHIPID);
	if (chip_id != CS201X_CHIP_ID) {
		pr_info(DRVNAME ": no CS201x here (chip ID %#06x)\n", chip_id);
		ret = -ENODEV;
		goto out;
	}
	chip_rev = superio_inw(SIO_REG_CHIPREV);

	superio_select(SIO_LDN_HOST2EC);
	base = superio_inw(SIO_REG_BASE);
	if (!base || base == 0xffff) {
		pr_err(DRVNAME ": bogus Host2EC base address %#06x\n", base);
		ret = -ENODEV;
		goto out;
	}
	superio_outb(SIO_REG_ENABLE, 0x01);

	pr_info(DRVNAME ": found CS201x rev %#x, Host2EC window at %#x\n",
		chip_rev, base);
	*ec_base = base;

out:
	superio_exit();

	return ret;
}

static int __init ugreen_cs201x_init(void)
{
	struct resource res = {
		.name = DRVNAME,
		.flags = IORESOURCE_IO,
	};
	u16 ec_base;
	int ret;

	if (!dmi_check_system(ugreen_cs201x_dmi_table) && !force) {
		const char *product = dmi_get_system_info(DMI_PRODUCT_NAME);

		pr_info(DRVNAME ": unsupported product \"%s\", use force=1 to override\n",
			product ?: "unknown");
		return -ENODEV;
	}

	ret = ugreen_cs201x_find(&ec_base);
	if (ret)
		return ret;

	res.start = ec_base;
	res.end = ec_base + IMA_REGION_LEN - 1;

	/*
	 * The vendor driver never claims this window at all. Warn about an
	 * ACPI reservation the same way it87 does instead of silently
	 * fighting the firmware over it.
	 */
	ret = acpi_check_resource_conflict(&res);
	if (ret)
		return ret;

	ret = platform_driver_register(&ugreen_cs201x_driver);
	if (ret)
		return ret;

	ugreen_cs201x_pdev = platform_device_alloc(DRVNAME, ec_base);
	if (!ugreen_cs201x_pdev) {
		ret = -ENOMEM;
		goto err_unregister;
	}

	ret = platform_device_add_resources(ugreen_cs201x_pdev, &res, 1);
	if (ret)
		goto err_put;

	ret = platform_device_add(ugreen_cs201x_pdev);
	if (ret)
		goto err_put;

	return 0;

err_put:
	platform_device_put(ugreen_cs201x_pdev);
err_unregister:
	platform_driver_unregister(&ugreen_cs201x_driver);

	return ret;
}

static void __exit ugreen_cs201x_exit(void)
{
	platform_device_unregister(ugreen_cs201x_pdev);
	platform_driver_unregister(&ugreen_cs201x_driver);
}

module_init(ugreen_cs201x_init);
module_exit(ugreen_cs201x_exit);

MODULE_AUTHOR("Derived from UGREEN's ug_201x.c by Jason.Li <lijiang@ugreen.com>");
MODULE_DESCRIPTION("hwmon driver for the Chipsea CS201x EC in the UGREEN DXP2800 GT");
MODULE_LICENSE("GPL v2");
