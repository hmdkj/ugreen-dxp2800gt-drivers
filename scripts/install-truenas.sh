#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Copy this project onto a pool dataset so it survives TrueNAS updates, then
# print what to register in the UI.
#
#   bash ./scripts/install-truenas.sh [target-dir]
#
# Default target: /mnt/<first pool>/apps/ugreen-cs201x

set -euo pipefail

cd "$(dirname "$0")/.."
SRCDIR=$PWD
KVER=$(uname -r)

TARGET=${1:-}
if [ -z "$TARGET" ]; then
	pool=$(zpool list -Ho name 2>/dev/null | grep -v '^boot-pool$' | head -1)
	[ -n "$pool" ] || { echo "no data pool found; pass a target directory" >&2; exit 1; }
	TARGET="/mnt/$pool/apps/ugreen-cs201x"
fi

[ "$(readlink -f "$TARGET")" != "$SRCDIR" ] || { echo "target is the source directory" >&2; exit 1; }

echo "installing to $TARGET"
mkdir -p "$TARGET/scripts" "$TARGET/contrib" "$TARGET/build"

cp -v "$SRCDIR/ugreen-cs201x.c" "$SRCDIR/ugreen-cs201x-leds.c" "$SRCDIR/ugreen-cs201x.h" \
	"$SRCDIR/Makefile" "$SRCDIR/LICENSE" "$SRCDIR/README.md" "$TARGET/"
cp -v "$SRCDIR"/scripts/*.sh "$TARGET/scripts/"
cp -v "$SRCDIR"/contrib/fancontrol "$SRCDIR"/contrib/fancontrol.conf.in "$TARGET/contrib/"
chmod +x "$TARGET"/scripts/*.sh "$TARGET/contrib/fancontrol"

if [ -f "$SRCDIR/build/$KVER/ugreen-cs201x.ko" ]; then
	mkdir -p "$TARGET/build/$KVER"
	cp -v "$SRCDIR"/build/"$KVER"/ugreen-cs201x*.ko "$TARGET/build/$KVER/"
else
	echo
	echo "note: no module built for $KVER yet. On the NAS run:"
	echo "  sudo bash $TARGET/scripts/build-in-docker.sh"
fi

cat <<EOF

Installed. Remaining steps:

1. Check the fan curve in
     $TARGET/contrib/fancontrol.conf.in
   MINSTOP/MINSTART in particular should be measured on this machine
   (see README.md, "Measuring the fan curve").

2. Try it once by hand:
     sudo bash $TARGET/scripts/ugreen-init.sh

3. Make it survive reboots:
     TrueNAS UI -> System Settings -> Advanced -> Init/Shutdown Scripts -> Add
       Description: ugreen fan and LED control
       Type:        Command
       Command:     $TARGET/scripts/ugreen-init.sh
       When:        Post Init

After every TrueNAS update the kernel changes and the module must be
rebuilt with scripts/build-in-docker.sh. Until then the Post-Init script
fails loudly instead of loading a mismatched module, the fans fall back to
whatever the EC does on its own, and the LEDs keep the EC's default state.
EOF
