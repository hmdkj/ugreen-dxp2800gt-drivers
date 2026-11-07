#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Load ugreen-cs201x (fans, temperatures, front panel LEDs) and drop the fans
# from the EC's power-on 100 % to INIT_PWM. Fan control after that is left to
# whatever drives the hwmon pwm files. Meant to be registered as a TrueNAS Community Edition Post-Init
# command:
#
#   System Settings -> Advanced -> Init/Shutdown Scripts -> Add
#     Type: Command
#     Command: /mnt/<pool>/apps/ugreen-cs201x/scripts/ugreen-init.sh
#     When: Post Init
#
# Everything it needs lives next to it, on a pool dataset, because the
# TrueNAS root filesystem is replaced on every system update.
#
# Deliberately refuses to load a module built for a different kernel: after
# a TrueNAS update you must rebuild (scripts/build-in-docker.sh) rather than
# have a stale .ko forced in.

set -u

BASE=$(cd "$(dirname "$0")/.." && pwd)
KVER=$(uname -r)
KO="$BASE/build/$KVER/ugreen-cs201x.ko"
LOG="$BASE/ugreen-init.log"

# pwm (0-255) both fans get as soon as the module loads, until the fan
# controller takes over. 153 (60 %) keeps the drives under about 46 C even if
# nothing ever takes over. Override with e.g. INIT_PWM=128; empty leaves the
# EC alone.
INIT_PWM=${INIT_PWM-153}

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; }
die() { log "ERROR: $*"; exit 1; }

log "starting (kernel $KVER, base $BASE)"

# ---------------------------------------------------------------- the module

# Refuse before touching anything, so a missing build does not take down a
# setup that is working.
[ -f "$KO" ] || die "no module for this kernel: $KO not found. Rebuild with scripts/build-in-docker.sh"

# Start from a clean slate so that running this script twice gives the same
# result: unload the module.
if lsmod | grep -q '^ugreen_cs201x '; then
	rmmod ugreen_cs201x 2>>"$LOG" || die "cannot unload ugreen_cs201x (see $LOG)"
	log "unloaded ugreen_cs201x"
fi

find_hwmon() {
	local d
	for d in /sys/class/hwmon/hwmon*; do
		if [ -r "$d/name" ] && [ "$(cat "$d/name")" = "ugreen_cs201x" ]; then
			echo "$d"
			return 0
		fi
	done
	return 1
}

# The LEDs are multicolor LED class devices; the module depends on it.
modprobe -q led-class-multicolor 2>>"$LOG" || true
insmod "$KO" ${INIT_PWM:+init_pwm=$INIT_PWM} 2>>"$LOG" || die "insmod $KO failed (see $LOG and dmesg)"
log "loaded $KO"

# ------------------------------------------------------------------ the LEDs
#
# Optional: a failure here is logged but never stops the setup below.

# Power LED: steady, dim green so it is not glaring at night. Raise the green
# value (0-255) to make it brighter. The disk LEDs are left as the driver
# sets them: dark.
POWER_LED=/sys/class/leds/ugreen:rgb:power
POWER_LED_RGB="0 3 0"
if [ -e "$POWER_LED/trigger" ]; then
	if echo none > "$POWER_LED/trigger" 2>>"$LOG" &&
	   echo "$POWER_LED_RGB" > "$POWER_LED/multi_intensity" 2>>"$LOG" &&
	   echo 255 > "$POWER_LED/brightness" 2>>"$LOG"; then
		log "$(basename "$POWER_LED"): steady, rgb $POWER_LED_RGB"
	else
		log "WARNING: cannot set $POWER_LED"
	fi
fi

# ------------------------------------------------------------- find the hwmon

HWMON_DIR=$(find_hwmon) || die "the module is loaded but no hwmon device named ugreen_cs201x appeared (see dmesg)"

log "hwmon: $HWMON_DIR"
for f in fan1_input fan2_input temp1_input temp2_input pwm1 pwm2; do
	[ -e "$HWMON_DIR/$f" ] && log "  $f = $(cat "$HWMON_DIR/$f" 2>&1)"
done

# A fan header with nothing plugged into it reads 0 rpm. Controlling it is
# harmless, but say so, because it also means fanN_fault will latch.
for ch in 1 2; do
	if [ "$(cat "$HWMON_DIR/fan${ch}_input" 2>/dev/null || echo 0)" = "0" ]; then
		log "WARNING: fan$ch reads 0 rpm - is that header populated?"
	fi
done

# ----------------------------------------------------------------- drivetemp

# Drive temperatures as hwmon devices, for whatever controls the fans.
modprobe -q drivetemp 2>>"$LOG" || log "WARNING: cannot load drivetemp - no drive temperatures"
