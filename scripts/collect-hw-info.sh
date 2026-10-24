#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Read-only reconnaissance for porting ugreen-cs201x to this machine.
# Run as root on the NAS. It changes nothing; it only prints what the
# driver and the build need to know. TrueNAS disables root SSH by default,
# so log in as the admin user and use sudo:
#
#   ssh <admin-user>@nas 'sudo bash -s' < scripts/collect-hw-info.sh

set -u

hr() { printf '\n===== %s\n' "$1"; }

hr "kernel"
uname -a
echo "uname -r: $(uname -r)"

hr "product identity (the driver matches DMI_PRODUCT_NAME == 'DXP2800 GT')"
for f in product_name sys_vendor board_name product_version bios_version; do
	printf '%-16s %s\n' "$f:" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null || echo '<unreadable>')"
done

hr "CPU"
grep -m1 'model name' /proc/cpuinfo

hr "I/O port reservations around the Super I/O and EC (0x2e/0x2f, 0x62/0x66)"
grep -iE '002e|0062|0066|ec_|superio|pnp' /proc/ioports || echo "no matches"
echo "--- full /proc/ioports below 0x1000:"
awk -F- '$1+0 < 0x1000' /proc/ioports 2>/dev/null | head -40

hr "existing hwmon devices"
for d in /sys/class/hwmon/hwmon*; do
	[ -e "$d/name" ] || continue
	printf '%-28s %s\n' "$d" "$(cat "$d/name")"
done

hr "loaded modules of interest"
lsmod | grep -E '^(it87|k10temp|coretemp|drivetemp|nct6775|ugreen)' || echo "none loaded"

hr "modules available in this kernel"
for m in drivetemp k10temp coretemp it87; do
	printf '%-12s %s\n' "$m:" "$(modinfo -n "$m" 2>/dev/null || echo '<not present>')"
done

hr "kernel features needed by the LED module"
cfg="/boot/config-$(uname -r)"
[ -f "$cfg" ] || cfg=
if [ -n "$cfg" ]; then
	grep -E '^(# )?CONFIG_(AUXILIARY_BUS|NEW_LEDS|LEDS_CLASS|LEDS_CLASS_MULTICOLOR|LEDS_TRIGGER_NETDEV|LEDS_TRIGGER_DISK|LEDS_TRIGGER_BLKDEV)[= ]' "$cfg" || echo "none of them found in $cfg"
else
	echo "no /boot/config-$(uname -r); try: zcat /proc/config.gz"
fi
echo "--- LEDs registered right now:"
ls /sys/class/leds/ 2>/dev/null || echo "none"

hr "ACPI resource conflict messages from this boot"
dmesg 2>/dev/null | grep -iE 'acpi.*(resource|conflict)|lockdown' | head -20 || echo "none"

hr "module loading restrictions"
echo "lockdown: $(cat /sys/kernel/security/lockdown 2>/dev/null || echo '<not available>')"
echo "secure boot (efivars): $(od -An -t u1 -j 4 -N 1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tr -d ' ' || echo '<not available>')"
echo "module.sig_enforce in cmdline: $(grep -o 'module.sig_enforce=[01]' /proc/cmdline || echo 'not set')"
cat /proc/cmdline

hr "what is available to build with"
echo "kernel build dir: $(test -d "/lib/modules/$(uname -r)/build" && echo present || echo MISSING)"
echo "/boot/config-$(uname -r): $(test -f "/boot/config-$(uname -r)" && echo present || echo missing)"
echo "/proc/config.gz: $(test -f /proc/config.gz && echo present || echo missing)"
for t in gcc make docker podman install-dev-tools dmidecode sensors fancontrol; do
	printf '%-20s %s\n' "$t:" "$(command -v "$t" || echo '<not found>')"
done

hr "apt sources (needed to fetch matching kernel headers)"
cat /etc/apt/sources.list 2>/dev/null
cat /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null

hr "root filesystem mount flags"
findmnt -no SOURCE,FSTYPE,OPTIONS / 2>/dev/null || mount | grep ' / '

hr "pools (a place to keep the module across upgrades)"
zpool list -Ho name 2>/dev/null || echo "zpool not available"

hr "done"
