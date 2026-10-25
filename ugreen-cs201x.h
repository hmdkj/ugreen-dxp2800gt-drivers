/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Interface between the EC core of ugreen-cs201x (owner of the EC I/O window
 * and its lock) and the front panel LEDs, which live in the same EC and are
 * linked into the same module.
 *
 * The LED code reaches the EC only through ugreen_cs201x_ec_led_write(),
 * so every EC transaction, fan or LED, goes through the same mutex.
 */
#ifndef UGREEN_CS201X_H
#define UGREEN_CS201X_H

#include <linux/device.h>
#include <linux/types.h>

struct ugreen_cs201x_data;

/*
 * Only the ARGB LED block of the EC address space is reachable through this;
 * everything else is rejected with -EINVAL, so that a bug in the LED code
 * cannot touch the fan registers.
 */
int ugreen_cs201x_ec_led_write(struct ugreen_cs201x_data *data, u32 addr, u8 val);

/* Register the LEDs as children of @dev; everything is released with @dev. */
int ugreen_cs201x_leds_init(struct device *dev, struct ugreen_cs201x_data *data);

#endif /* UGREEN_CS201X_H */
