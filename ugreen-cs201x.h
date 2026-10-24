/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Interface between ugreen-cs201x (owner of the EC I/O window and its lock)
 * and ugreen-cs201x-leds (front panel LEDs, which live in the same EC).
 *
 * The core module registers one auxiliary device named "ugreen_cs201x.leds"
 * (KBUILD_MODNAME of the core + ".leds"); the LED module binds to it and
 * reaches the EC only through the ops below, so every EC transaction, fan or
 * LED, goes through the same mutex.
 */
#ifndef UGREEN_CS201X_H
#define UGREEN_CS201X_H

#include <linux/auxiliary_bus.h>
#include <linux/device.h>
#include <linux/types.h>

#define UGREEN_CS201X_AUX_LEDS_NAME	"leds"
#define UGREEN_CS201X_AUX_LEDS_MATCH	"ugreen_cs201x." UGREEN_CS201X_AUX_LEDS_NAME

/*
 * Only the ARGB LED block of the EC address space is reachable through these
 * ops; the core rejects everything else with -EINVAL, so that a bug in the
 * LED driver cannot touch the fan registers.
 */
struct ugreen_cs201x_ec_ops {
	int (*read)(struct device *ecdev, u32 addr, u8 *val);
	int (*write)(struct device *ecdev, u32 addr, u8 val);
};

struct ugreen_cs201x_aux_device {
	struct auxiliary_device adev;
	struct device *ecdev;	/* platform device that owns the EC window */
	const struct ugreen_cs201x_ec_ops *ops;
};

#endif /* UGREEN_CS201X_H */
