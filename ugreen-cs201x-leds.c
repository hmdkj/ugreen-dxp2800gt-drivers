// SPDX-License-Identifier: GPL-2.0-only
/*
 * ugreen-cs201x-leds - front panel LEDs of the UGREEN NASync DXP2800 GT
 *
 * The four ARGB LEDs (power, LAN, disk1, disk2) are driven by the same
 * Chipsea CS201x EC as the fans. The EC window and its lock belong to the
 * ugreen-cs201x module, which publishes them through an auxiliary device;
 * this module only binds to that device and never touches the I/O ports.
 *
 * Derived from drivers/ugreen/ug_201x.c (ArgbRgbSet/ArgbLightSet/ArgbModeSet)
 * and drivers/ugreen/leds-sio-201x.c of UGREEN's GPL kernel release
 *   https://github.com/ugreen-opensource/kernel-6.12
 * (Author: Jason.Li, lijiang@ugreen.com, SPDX-License-Identifier:
 * GPL-2.0-only). Register map and write sequences are the vendor's; the
 * differences are:
 *
 *  - LEDs are registered as multicolor LED class devices, so any RGB colour
 *    can be set and standard triggers (netdev, disk-activity, timer, ...)
 *    work
 *  - every EC access goes through the lock shared with the fan code (the
 *    vendor LED functions do not take the vendor's own lock)
 *  - the EC does the blinking where it can (blink_set); the LED core falls
 *    back to its software timer otherwise
 *  - the watchdog, power-switch bypass and power-restore settings of the
 *    vendor driver are not ported
 *
 * Register semantics that are not confirmed on hardware are marked
 * "UNVERIFIED" below.
 */

#include <linux/auxiliary_bus.h>
#include <linux/kernel.h>
#include <linux/led-class-multicolor.h>
#include <linux/leds.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>

#include "ugreen-cs201x.h"

#define DRVNAME			"ugreen-cs201x-leds"

#define NUM_LEDS		4
#define NUM_COLORS		3	/* red, green, blue */

/* EC registers of the ARGB block, per channel 0-3 */
#define EC_ARGB_MODE(id)	(0x20005400u + (id))
#define EC_ARGB_LIGHT(id)	(0x20005404u + (id))
#define EC_ARGB_PERIOD(id)	(0x20005408u + (id))
#define EC_ARGB_DUTY(id)	(0x2000540cu + (id))
#define EC_ARGB_FLOW_CTRL	0x20005440u
/* three bytes per channel, 4 apart */
#define EC_ARGB_COLOR_B(id)	(0x20005444u + ((id) << 2))
#define EC_ARGB_COLOR_R(id)	(0x20005445u + ((id) << 2))
#define EC_ARGB_COLOR_G(id)	(0x20005446u + ((id) << 2))

#define ARGB_MODE_OFF		0
#define ARGB_MODE_ON		1
#define ARGB_MODE_BLINK		2
/* ARGB_MODE_BREATH (3) exists in the EC but has no LED class equivalent */

/*
 * UNVERIFIED: period and duty are programmed by the vendor driver as
 * milliseconds / 50, i.e. in units of 50 ms. The vendor driver never blinks
 * faster than 100 ms.
 */
#define BLINK_UNIT_MS		50
#define BLINK_MIN_MS		100

struct ugreen_leds;

struct ugreen_led {
	struct led_classdev_mc mc;
	struct mc_subled subled[NUM_COLORS];
	struct ugreen_leds *priv;
	unsigned int id;
};

struct ugreen_leds {
	struct ugreen_cs201x_aux_device *aux;
	struct mutex lock;	/* keeps the multi-register LED updates whole */
	struct ugreen_led led[NUM_LEDS];
};

static const char * const ugreen_led_names[NUM_LEDS] = {
	"ugreen:rgb:power",
	"ugreen:rgb:lan",
	"ugreen:rgb:disk-1",
	"ugreen:rgb:disk-2",
};

static int ugreen_led_ec_write(struct ugreen_leds *priv, u32 addr, u8 val)
{
	return priv->aux->ops->write(priv->aux->ecdev, addr, val);
}

static int ugreen_led_set_mode(struct ugreen_leds *priv, unsigned int id, u8 mode)
{
	return ugreen_led_ec_write(priv, EC_ARGB_MODE(id), mode);
}

static int ugreen_led_brightness_set(struct led_classdev *cdev,
				     enum led_brightness brightness)
{
	struct led_classdev_mc *mc = lcdev_to_mccdev(cdev);
	struct ugreen_led *led = container_of(mc, struct ugreen_led, mc);
	struct ugreen_leds *priv = led->priv;
	unsigned int id = led->id;
	int ret;

	/* subled[i].brightness = intensity scaled by the requested brightness */
	led_mc_calc_color_components(mc, brightness);

	mutex_lock(&priv->lock);

	/*
	 * UNVERIFIED: the brightness is folded into the RGB bytes, and the
	 * EC "light" byte is left at full scale (set once in probe).
	 */
	ret = ugreen_led_ec_write(priv, EC_ARGB_COLOR_B(id), led->subled[2].brightness);
	if (!ret)
		ret = ugreen_led_ec_write(priv, EC_ARGB_COLOR_R(id), led->subled[0].brightness);
	if (!ret)
		ret = ugreen_led_ec_write(priv, EC_ARGB_COLOR_G(id), led->subled[1].brightness);
	if (!ret)
		ret = ugreen_led_set_mode(priv, id, brightness ? ARGB_MODE_ON : ARGB_MODE_OFF);

	mutex_unlock(&priv->lock);

	return ret;
}

/*
 * Let the EC blink the LED. Anything it cannot express (too fast, too slow,
 * zero) is refused, and the LED core then blinks it with its own timer.
 */
static int ugreen_led_blink_set(struct led_classdev *cdev,
				unsigned long *delay_on, unsigned long *delay_off)
{
	struct led_classdev_mc *mc = lcdev_to_mccdev(cdev);
	struct ugreen_led *led = container_of(mc, struct ugreen_led, mc);
	struct ugreen_leds *priv = led->priv;
	unsigned long period;
	int ret;

	if (!*delay_on && !*delay_off) {
		*delay_on = 500;
		*delay_off = 500;
	}

	if (*delay_on < BLINK_MIN_MS || *delay_off < BLINK_MIN_MS)
		return -EINVAL;

	/* the EC stores both values in one byte */
	period = (*delay_on + *delay_off) / BLINK_UNIT_MS;
	if (period > U8_MAX)
		return -EINVAL;

	mutex_lock(&priv->lock);

	/* UNVERIFIED: period = on + off, duty = on, as the vendor driver does */
	ret = ugreen_led_ec_write(priv, EC_ARGB_PERIOD(led->id), period);
	if (!ret)
		ret = ugreen_led_ec_write(priv, EC_ARGB_DUTY(led->id),
					  *delay_on / BLINK_UNIT_MS);
	if (!ret)
		ret = ugreen_led_set_mode(priv, led->id, ARGB_MODE_BLINK);

	mutex_unlock(&priv->lock);

	return ret;
}

static int ugreen_leds_register(struct device *dev, struct ugreen_leds *priv,
				unsigned int id)
{
	static const int color_ids[NUM_COLORS] = {
		LED_COLOR_ID_RED, LED_COLOR_ID_GREEN, LED_COLOR_ID_BLUE,
	};
	struct ugreen_led *led = &priv->led[id];
	struct led_classdev *cdev = &led->mc.led_cdev;
	int i;

	led->priv = priv;
	led->id = id;

	for (i = 0; i < NUM_COLORS; i++) {
		led->subled[i].color_index = color_ids[i];
		led->subled[i].channel = i;
		led->subled[i].intensity = U8_MAX;
	}
	led->mc.num_colors = NUM_COLORS;
	led->mc.subled_info = led->subled;

	cdev->name = ugreen_led_names[id];
	cdev->max_brightness = U8_MAX;
	/* The power LED is lit at boot, the others are dark (see probe). */
	cdev->brightness = id == 0 ? U8_MAX : 0;
	cdev->brightness_set_blocking = ugreen_led_brightness_set;
	cdev->blink_set = ugreen_led_blink_set;

	return devm_led_classdev_multicolor_register(dev, &led->mc);
}

static int ugreen_leds_probe(struct auxiliary_device *adev,
			     const struct auxiliary_device_id *id)
{
	struct ugreen_cs201x_aux_device *aux =
		container_of(adev, struct ugreen_cs201x_aux_device, adev);
	struct device *dev = &adev->dev;
	struct ugreen_leds *priv;
	unsigned int i;
	int ret;

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->aux = aux;
	ret = devm_mutex_init(dev, &priv->lock);
	if (ret)
		return ret;
	auxiliary_set_drvdata(adev, priv);

	/*
	 * Same initial state as the vendor driver: flow control register to 1,
	 * "light" byte at full scale, power LED on and the others off. No
	 * colour is written; the EC keeps whatever it has.
	 * UNVERIFIED: what the flow control register does (the vendor comments
	 * contradict its values).
	 */
	mutex_lock(&priv->lock);
	ret = ugreen_led_ec_write(priv, EC_ARGB_FLOW_CTRL, 1);
	for (i = 0; !ret && i < NUM_LEDS; i++) {
		ret = ugreen_led_ec_write(priv, EC_ARGB_LIGHT(i), U8_MAX);
		if (!ret)
			ret = ugreen_led_set_mode(priv, i, i == 0 ? ARGB_MODE_ON : ARGB_MODE_OFF);
	}
	mutex_unlock(&priv->lock);
	if (ret)
		return dev_err_probe(dev, ret, "cannot initialise the LED block\n");

	for (i = 0; i < NUM_LEDS; i++) {
		ret = ugreen_leds_register(dev, priv, i);
		if (ret)
			return dev_err_probe(dev, ret, "cannot register LED %s\n",
					     ugreen_led_names[i]);
	}

	dev_info(dev, "registered %d LEDs\n", NUM_LEDS);

	return 0;
}

static void ugreen_leds_remove(struct auxiliary_device *adev)
{
	struct ugreen_leds *priv = auxiliary_get_drvdata(adev);

	/* As the vendor driver does; the LEDs keep their last state. */
	mutex_lock(&priv->lock);
	ugreen_led_ec_write(priv, EC_ARGB_FLOW_CTRL, 0);
	mutex_unlock(&priv->lock);
}

static const struct auxiliary_device_id ugreen_leds_id_table[] = {
	{ .name = UGREEN_CS201X_AUX_LEDS_MATCH },
	{}
};
MODULE_DEVICE_TABLE(auxiliary, ugreen_leds_id_table);

static struct auxiliary_driver ugreen_leds_driver = {
	.name = "leds",
	.probe = ugreen_leds_probe,
	.remove = ugreen_leds_remove,
	.id_table = ugreen_leds_id_table,
};
module_auxiliary_driver(ugreen_leds_driver);

MODULE_AUTHOR("Derived from UGREEN's ug_201x.c and leds-sio-201x.c by Jason.Li <lijiang@ugreen.com>");
MODULE_DESCRIPTION("Front panel LEDs of the UGREEN DXP2800 GT (Chipsea CS201x EC)");
MODULE_LICENSE("GPL v2");
