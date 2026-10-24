#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build ugreen-cs201x.ko and ugreen-cs201x-leds.ko for a TrueNAS Community
# Edition kernel inside a container, so
# that nothing is installed onto the appliance's root filesystem.
#
# Run this ON THE NAS (TrueNAS Community Edition ships Docker for its Apps feature):
#
#     ./scripts/build-in-docker.sh
#
# The results land in build/<kernel-version>/ugreen-cs201x{,-leds}.ko
#
# Two ways to get something to compile against:
#
#   headers (default)  install linux-headers-<kver> from the same apt
#                      repositories the appliance itself uses, then run
#                      "make modules_prepare" with the running kernel's
#                      config, because the TrueNAS headers package is known
#                      to ship without include/generated/autoconf.h.
#
#   --from-source      shallow-clone github.com/truenas/linux at the branch
#                      matching the kernel version and prepare that instead.
#                      Slower and bigger, but does not depend on the headers
#                      package being usable.
#
# Options:
#   --kver <ver>     kernel version to build for (default: uname -r)
#   --image <img>    container image (default: debian:<host VERSION_CODENAME>)
#   --config <file>  kernel config (default: /boot/config-<kver>, or
#                    /proc/config.gz, or the running kernel's ikconfig)
#   --from-source    use the truenas/linux git tree instead of the headers deb
#   --keep           keep the container's work directory for debugging

set -euo pipefail

cd "$(dirname "$0")/.."
SRCDIR=$PWD

KVER=$(uname -r)
IMAGE=
CONFIG=
FROM_SOURCE=0
KEEP=0

while [ $# -gt 0 ]; do
	case $1 in
	--kver) KVER=$2; shift 2 ;;
	--image) IMAGE=$2; shift 2 ;;
	--config) CONFIG=$2; shift 2 ;;
	--from-source) FROM_SOURCE=1; shift ;;
	--keep) KEEP=1; shift ;;
	-h|--help) sed -n '3,33p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

die() { echo "error: $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found. On TrueNAS Community Edition it comes with Apps; enable Apps first, or run this script on another machine with --kver $KVER"

# Match the appliance's Debian release so the module is built with the same
# toolchain generation as the kernel it will be loaded into.
if [ -z "$IMAGE" ]; then
	# "|| true": without /etc/os-release (e.g. macOS) the subshell fails and
	# set -e would end the script silently instead of reaching die below.
	codename=$( . /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" || true )
	[ -n "$codename" ] || die "cannot detect the Debian codename (no /etc/os-release?). Run this on the NAS, or pass --image debian:<codename> --kver <ver> --config <file>"
	IMAGE="debian:$codename"
fi

# The kernel config is needed either way: the headers package lacks the
# generated files, and a fresh git tree has no config at all.
WORK=$(mktemp -d)
trap '[ "$KEEP" = 1 ] || rm -rf "$WORK"' EXIT

if [ -n "$CONFIG" ]; then
	cp "$CONFIG" "$WORK/kconfig"
elif [ -f "/boot/config-$KVER" ]; then
	cp "/boot/config-$KVER" "$WORK/kconfig"
elif [ -f /proc/config.gz ]; then
	zcat /proc/config.gz > "$WORK/kconfig"
else
	die "no kernel config found (looked at /boot/config-$KVER and /proc/config.gz); pass --config"
fi
echo "using kernel config: $(wc -l < "$WORK/kconfig") lines"

# The appliance's apt configuration is reused verbatim rather than guessing
# repository URLs, which differ between TrueNAS releases.
mkdir -p "$WORK/apt/sources.list.d" "$WORK/apt/keyrings"
if [ "$FROM_SOURCE" = 0 ]; then
	[ -f /etc/apt/sources.list ] && cp /etc/apt/sources.list "$WORK/apt/sources.list"
	cp /etc/apt/sources.list.d/* "$WORK/apt/sources.list.d/" 2>/dev/null || true
	cp /usr/share/keyrings/* "$WORK/apt/keyrings/" 2>/dev/null || true
	cp /etc/apt/keyrings/* "$WORK/apt/keyrings/" 2>/dev/null || true
	# Keys apt trusts globally, and any key a source pins with Signed-By /
	# signed-by=, wherever it lives (kept at the same absolute path).
	mkdir -p "$WORK/apt/trusted.gpg.d" "$WORK/apt/extra"
	cp /etc/apt/trusted.gpg.d/* "$WORK/apt/trusted.gpg.d/" 2>/dev/null || true
	# "|| true": grep exits 1 when nothing matches, which pipefail + set -e
	# would turn into a silent exit.
	{ grep -hoiE 'signed-by[=:] *[^] ]+' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true; } |
		sed -E 's/^[^=:]*[=:] *//' | sort -u | while read -r keyfile; do
		[ -f "$keyfile" ] || continue
		mkdir -p "$WORK/apt/extra$(dirname "$keyfile")"
		cp "$keyfile" "$WORK/apt/extra$keyfile"
	done
	[ ! -f /etc/apt/trusted.gpg ] || cp /etc/apt/trusted.gpg "$WORK/apt/trusted.gpg.d/host-trusted.gpg"
	if [ -z "$(ls -A "$WORK/apt/sources.list.d")" ] && [ ! -s "$WORK/apt/sources.list" ]; then
		die "no apt sources found on this host; run with --from-source instead"
	fi
fi

mkdir -p "$SRCDIR/build/$KVER"

cat > "$WORK/build.sh" <<'INNER'
set -euo pipefail

KVER=$1
FROM_SOURCE=$2

export DEBIAN_FRONTEND=noninteractive

# Toolchain first, from the image's own Debian repositories. The appliance's
# repositories are added afterwards, so that a broken or unreachable TrueNAS
# repo cannot take the whole toolchain install down with it.
apt-get update
apt-get install -y --no-install-recommends build-essential bc bison flex \
	libssl-dev libelf-dev kmod rsync ca-certificates

if [ "$FROM_SOURCE" = 1 ]; then
	apt-get install -y --no-install-recommends git
	# 6.12.15-production+truenas -> truenas/linux-6.12
	branch="truenas/linux-$(echo "$KVER" | cut -d. -f1,2)"
	echo "cloning $branch"
	git clone --depth 1 --branch "$branch" \
		https://github.com/truenas/linux /kbuild
	KDIR=/kbuild
else
	cp -a /work/apt/sources.list /etc/apt/sources.list.d/truenas-host.list 2>/dev/null || true
	cp -a /work/apt/sources.list.d/. /etc/apt/sources.list.d/ 2>/dev/null || true
	mkdir -p /usr/share/keyrings
	cp -a /work/apt/keyrings/. /usr/share/keyrings/ 2>/dev/null || true
	mkdir -p /etc/apt/trusted.gpg.d
	cp -a /work/apt/trusted.gpg.d/. /etc/apt/trusted.gpg.d/ 2>/dev/null || true
	cp -a /work/apt/extra/. / 2>/dev/null || true

	# A repository we have no key for must not abort the run; the install
	# below is what decides whether this mode can work.
	apt-get update || echo "warning: some repositories failed to update" >&2

	if ! apt-get install -y --no-install-recommends "linux-headers-$KVER"; then
		echo >&2
		echo "linux-headers-$KVER is not installable from these repositories." >&2
		echo "Re-run the outer script with --from-source." >&2
		exit 1
	fi
	KDIR=/lib/modules/$KVER/build
	[ -d "$KDIR" ] || KDIR=/usr/src/linux-headers-$KVER
fi

[ -d "$KDIR" ] || { echo "no kernel build tree at $KDIR" >&2; exit 1; }

# The TrueNAS headers package ships without include/generated/autoconf.h,
# which makes any out-of-tree build fail with "Kernel configuration is
# invalid". Regenerate the generated files from the running kernel's config.
cp /work/kconfig "$KDIR/.config"
make -C "$KDIR" olddefconfig
make -C "$KDIR" modules_prepare

MODPOST_WARN=
if [ "$FROM_SOURCE" = 1 ]; then
	# The branch head is not necessarily the exact running kernel, and
	# EXTRAVERSION ("-production") is not in the config. vermagic must match
	# the running kernel or insmod refuses the module, so pin the release.
	built=$(cat "$KDIR/include/config/kernel.release")
	if [ "$built" != "$KVER" ]; then
		echo "warning: source tree is $built, running kernel is $KVER; forcing the release string to $KVER" >&2
		echo "$KVER" > "$KDIR/include/config/kernel.release"
		printf '#define UTS_RELEASE "%s"\n' "$KVER" > "$KDIR/include/generated/utsrelease.h"
	fi
	# A source tree has no Module.symvers (that needs a full kernel build),
	# so modpost cannot resolve exported symbols. Treat that as a warning;
	# the module then loads without CRC checks for those symbols.
	[ -f "$KDIR/Module.symvers" ] || MODPOST_WARN=1
fi

# Keep the source read-only: build in a copy.
mkdir -p /build
cp /src/ugreen-cs201x.c /src/ugreen-cs201x-leds.c /src/ugreen-cs201x.h /src/Makefile /build/
KBUILD_MODPOST_WARN=$MODPOST_WARN make -C "$KDIR" M=/build W=1 modules

for mod in ugreen-cs201x ugreen-cs201x-leds; do
	strip --strip-debug "/build/$mod.ko"
	modinfo "/build/$mod.ko"
	cp "/build/$mod.ko" "/out/$mod.ko"
done
INNER

echo "building for $KVER in $IMAGE (from_source=$FROM_SOURCE)"
docker run --rm \
	-v "$SRCDIR:/src:ro" \
	-v "$WORK:/work:ro" \
	-v "$SRCDIR/build/$KVER:/out" \
	-w /build \
	"$IMAGE" \
	bash /work/build.sh "$KVER" "$FROM_SOURCE"

echo
echo "built: $SRCDIR/build/$KVER/ugreen-cs201x.ko"
echo "built: $SRCDIR/build/$KVER/ugreen-cs201x-leds.ko"
