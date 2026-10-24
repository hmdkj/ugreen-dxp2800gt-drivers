#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Load ugreen-cs201x (fans, temperatures) and ugreen-cs201x-leds (front panel
# LEDs), then start fancontrol. Meant to be registered as a
# TrueNAS Community Edition Post-Init command:
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

if ! lsmod | grep -q '^ugreen_cs201x '; then
	# The core registers an auxiliary device for the LED module.
	modprobe -q auxiliary 2>>"$LOG" || true
	[ -f "$KO" ] || die "no module for this kernel: $KO not found. Rebuild with scripts/build-in-docker.sh"

	if ! insmod "$KO" 2>>"$LOG"; then
		die "insmod $KO failed (see $LOG and dmesg)"
	fi
	log "loaded $KO"
else
	log "ugreen_cs201x already loaded"
fi

# ------------------------------------------------------------------ the LEDs
#
# Optional: a failure here is logged but never stops the fan setup below.

KO_LEDS="$BASE/build/$KVER/ugreen-cs201x-leds.ko"
if [ -f "$KO_LEDS" ] && ! lsmod | grep -q '^ugreen_cs201x_leds'; then
	modprobe -q led-class-multicolor 2>>"$LOG" || true
	if insmod "$KO_LEDS" 2>>"$LOG"; then
		log "loaded $KO_LEDS"
	else
		log "WARNING: insmod $KO_LEDS failed (see $LOG and dmesg); continuing without LEDs"
	fi
fi

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

# ------------------------------------------------------------- find the hwmon

HWMON_DIR=
for d in /sys/class/hwmon/hwmon*; do
	if [ -r "$d/name" ] && [ "$(cat "$d/name")" = "ugreen_cs201x" ]; then
		HWMON_DIR=$d
		break
	fi
done
[ -n "$HWMON_DIR" ] || die "the module is loaded but no hwmon device named ugreen_cs201x appeared"

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
