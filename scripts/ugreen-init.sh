#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Load ugreen-cs201x (fans, temperatures, front panel LEDs), then start
# fancontrol. Meant to be registered as a TrueNAS Community Edition Post-Init
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
CONF_IN="$BASE/contrib/fancontrol.conf.in"
FANCONTROL="$BASE/contrib/fancontrol"
CONF=/run/ugreen-cs201x/fancontrol.conf
LOG="$BASE/ugreen-init.log"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; }
die() { log "ERROR: $*"; exit 1; }

log "starting (kernel $KVER, base $BASE)"

# ---------------------------------------------------------------- the module

# The module used to be split in two; the LED half cannot stay loaded.
if lsmod | grep -q '^ugreen_cs201x_leds '; then
	{ rmmod ugreen_cs201x_leds && rmmod ugreen_cs201x; } 2>>"$LOG" ||
		die "cannot unload the old two-module build (see $LOG); reboot"
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

load_module() {
	# The LEDs are multicolor LED class devices; the module depends on it.
	modprobe -q led-class-multicolor 2>>"$LOG" || true
	[ -f "$KO" ] || die "no module for this kernel: $KO not found. Rebuild with scripts/build-in-docker.sh"
	insmod "$KO" 2>>"$LOG" || die "insmod $KO failed (see $LOG and dmesg)"
	log "loaded $KO"
}

# Entries of /proc/ioports inside the EC window 0x200-0x20f that are not ours
# (at the time of writing: "pnp 00:03" at 0x200-0x207, the firmware's
# reservation). While one is there, the driver cannot claim the window and
# its probe fails with -EBUSY.
window_holders() {
	grep -iE '^ *020[0-9a-f]-' /proc/ioports 2>/dev/null | grep -v 'ugreen-cs201x' | tr -s ' \n' ' '
}

wait_for_window() {
	local i holders
	for i in $(seq 1 120); do
		holders=$(window_holders)
		[ -z "$holders" ] && { [ "$i" -eq 1 ] || log "EC window free after $((i - 1))s"; return 0; }
		[ "$i" -ne 1 ] || log "EC window 0x200-0x20f is held by: $holders; waiting up to 120s for it to be released"
		sleep 1
	done
	log "WARNING: still held after 120s by: $holders; loading anyway"
}

if lsmod | grep -q '^ugreen_cs201x '; then
	if ! find_hwmon >/dev/null; then
		# Loaded earlier but its probe failed; start over with a free window.
		log "ugreen_cs201x is loaded without a hwmon device; unloading it"
		rmmod ugreen_cs201x 2>>"$LOG" || die "cannot unload ugreen_cs201x (see $LOG)"
	else
		log "ugreen_cs201x already loaded"
	fi
fi

if ! lsmod | grep -q '^ugreen_cs201x '; then
	wait_for_window
	load_module
fi

# ------------------------------------------------------------------ the LEDs
#
# Optional: a failure here is logged but never stops the fan setup below.

# Keep the disk LEDs dark: their activity blinking is too bright for a room.
# The driver already leaves them off at probe; this also drops a trigger set
# earlier (e.g. by hand) when the module was already loaded. For the old
# behaviour, echo disk-activity into their "trigger" files (see README.md).
# Same rule as above: never stop the fan setup over this.
for led in /sys/class/leds/ugreen:rgb:disk-1 /sys/class/leds/ugreen:rgb:disk-2; do
	[ -e "$led/trigger" ] || continue
	if echo none > "$led/trigger" 2>>"$LOG" && echo 0 > "$led/brightness" 2>>"$LOG"; then
		log "$(basename "$led"): off"
	else
		log "WARNING: cannot turn off $led"
	fi
done

# Power LED: steady, dim green so it is not glaring at night. Raise the green
# value (0-255) to make it brighter. Same rule as above: never stop the fan
# setup over this.
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

HWMON_DIR=$(find_hwmon) || die "the module is loaded but no hwmon device named ugreen_cs201x appeared (see dmesg and /proc/ioports)"

HWMON=$(basename "$HWMON_DIR")
DEVPATH=$(readlink -f "$HWMON_DIR/device" | sed -e 's|^/sys/||')
[ -n "$DEVPATH" ] || die "cannot resolve $HWMON_DIR/device"

log "hwmon: $HWMON ($DEVPATH)"
for f in fan1_input fan2_input temp1_input temp2_input pwm1 pwm2; do
	[ -e "$HWMON_DIR/$f" ] && log "  $f = $(cat "$HWMON_DIR/$f" 2>&1)"
done

# A fan header with nothing plugged into it reads 0 rpm. Controlling it is
# harmless, but say so, because it also means fanN_fault will latch.
for ch in 1 2; do
	if [ "$(cat "$HWMON_DIR/fan${ch}_input" 2>/dev/null || echo 0)" = "0" ]; then
		log "WARNING: fan$ch reads 0 rpm - is that header populated? Consider removing pwm$ch from $CONF_IN"
	fi
done

# ---------------------------------------------------------------- fancontrol

[ -f "$CONF_IN" ] || die "$CONF_IN not found"
[ -x "$FANCONTROL" ] || die "$FANCONTROL not found or not executable"

# Stop a fancontrol we started earlier; it restores the fans to full speed
# on SIGTERM, and the new instance takes over from there.
if [ -f /run/fancontrol.pid ]; then
	oldpid=$(cat /run/fancontrol.pid)
	if kill -0 "$oldpid" 2>/dev/null; then
		log "stopping previous fancontrol (pid $oldpid)"
		kill -TERM "$oldpid" 2>/dev/null
		for _ in 1 2 3 4 5; do
			kill -0 "$oldpid" 2>/dev/null || break
			sleep 1
		done
	fi
	rm -f /run/fancontrol.pid
fi

mkdir -p "$(dirname "$CONF")"
sed -e "s|@HWMON@|$HWMON|g" -e "s|@DEVPATH@|$DEVPATH|g" "$CONF_IN" > "$CONF"

if ! "$FANCONTROL" --check "$CONF" >>"$LOG" 2>&1; then
	die "fancontrol rejected $CONF (see $LOG)"
fi

setsid "$FANCONTROL" "$CONF" >>"$LOG" 2>&1 &
sleep 2

if [ -f /run/fancontrol.pid ] && kill -0 "$(cat /run/fancontrol.pid)" 2>/dev/null; then
	log "fancontrol running (pid $(cat /run/fancontrol.pid)) with $CONF"
else
	die "fancontrol did not stay up (see $LOG)"
fi
