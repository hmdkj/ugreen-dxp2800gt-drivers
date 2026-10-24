#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build ugreen-cs201x.ko and ugreen-cs201x-leds.ko for a TrueNAS Community
# Edition kernel inside a container, so
# that nothing is installed onto the appliance's root filesystem.
#
# Run this ON THE NAS (TrueNAS Community Edition ships Docker for its Apps feature):
#
#     bash ./scripts/build-in-docker.sh
#
# The results land in build/<kernel-version>/ugreen-cs201x{,-leds}.ko
#
# Three ways to get something to compile against, tried in this order:
#
#   host headers       the appliance ships the headers of its running kernel
#   (default)          (/lib/modules/<kver>/build -> /usr/src/linux-headers-*),
#                      including Module.symvers. They are copied into the
#                      container and prepared with the running kernel's config
#                      ("make modules_prepare"), because they are known to
#                      lack include/generated/autoconf.h. This is the only
#                      mode that is guaranteed to match the running kernel.
#
#   --apt-headers      install linux-headers-<kver> from the same apt
#                      repositories the appliance itself uses. TrueNAS does
#                      not publish that package for every release.
#
#   --from-source      shallow-clone github.com/truenas/linux at the branch
#                      matching the kernel version and prepare that instead.
#                      The branch head is usually not the running kernel's
#                      exact commit, and there is no Module.symvers, so the
#                      module carries no symbol CRCs and a kernel built with
#                      CONFIG_MODVERSIONS (TrueNAS) refuses it. Last resort.
#
# Options:
#   --kver <ver>     kernel version to build for (default: uname -r)
#   --image <img>    container image (default: debian:<host VERSION_CODENAME>)
#   --config <file>  kernel config (default: /boot/config-<kver>, or
#                    /proc/config.gz, or the running kernel's ikconfig)
#   --apt-headers    install the headers deb from the appliance's apt sources
#   --from-source    use the truenas/linux git tree instead of the headers
#   --rebuild-image  rebuild the cached toolchain image (to pick up Debian
#                    updates); otherwise it is built once and reused
#   --keep           keep the container's work directory for debugging
#
# The compilers and libraries live in a local image,
# ugreen-cs201x-build:<base image>, built on the first run and reused after
# that, so later runs start in seconds instead of re-installing them.

set -euo pipefail

cd "$(dirname "$0")/.."
SRCDIR=$PWD

KVER=$(uname -r)
IMAGE=
CONFIG=
MODE=
KEEP=0
REBUILD=0

while [ $# -gt 0 ]; do
	case $1 in
	--kver) KVER=$2; shift 2 ;;
	--image) IMAGE=$2; shift 2 ;;
	--config) CONFIG=$2; shift 2 ;;
	--apt-headers) MODE=apt; shift ;;
	--from-source) MODE=source; shift ;;
	--rebuild-image) REBUILD=1; shift ;;
	--keep) KEEP=1; shift ;;
	-h|--help) sed -n '3,48p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

die() { echo "error: $*" >&2; exit 1; }

HOSTKDIR=$(readlink -f "/lib/modules/$KVER/build" 2>/dev/null || true)
if [ -z "$MODE" ]; then
	if [ -f "$HOSTKDIR/Module.symvers" ]; then
		MODE=host
	else
		MODE=apt
	fi
fi
[ "$MODE" != host ] || [ -f "$HOSTKDIR/Module.symvers" ] ||
	die "no kernel headers for $KVER on this host (looked at /lib/modules/$KVER/build); use --apt-headers or --from-source"

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
if [ "$MODE" = apt ]; then
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
MODE=$2
HOSTKDIR=$3

export DEBIAN_FRONTEND=noninteractive

# The toolchain is already in the image (see the outer script). The
# appliance's apt repositories are only added for --apt-headers, after it,
# so that a broken or unreachable TrueNAS repo cannot take it down.
if [ "$MODE" = source ]; then
	# 6.12.15-production+truenas -> truenas/linux-6.12
	branch="truenas/linux-$(echo "$KVER" | cut -d. -f1,2)"
	echo "cloning $branch"
	git clone --depth 1 --branch "$branch" \
		https://github.com/truenas/linux /kbuild
	KDIR=/kbuild
elif [ "$MODE" = host ]; then
	# The appliance's own headers (mounted at /usr/src, read-only). Work on
	# a copy: modules_prepare writes into the tree. -P keeps symlinks, which
	# resolve inside the container because /usr/src is mounted at the same path.
	echo "using the host's kernel headers from $HOSTKDIR"
	mkdir /kbuild
	cp -aP "$HOSTKDIR/." /kbuild/
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

# Some TrueNAS headers ship without include/generated/autoconf.h, which makes
# any out-of-tree build fail with "Kernel configuration is invalid". Then
# regenerate the generated files from the running kernel's config. Newer ones
# are already configured (and have no kconfig tools); see below.
PREPARED=0
if [ -f "$KDIR/include/generated/autoconf.h" ] && [ -f "$KDIR/include/config/auto.conf" ] &&
   [ ! -f "$KDIR/scripts/kconfig/Makefile" ]; then
	# The appliance's headers are already configured but carry neither
	# .config nor the kconfig tools, so "make olddefconfig" cannot run. Kbuild
	# still insists on a .config; give it one that is older than auto.conf so
	# it does not try to regenerate the generated files.
	echo "headers are already configured; skipping olddefconfig and modules_prepare"
	PREPARED=1
	cp /work/kconfig "$KDIR/.config"
	touch -d 2000-01-01 "$KDIR/.config"
	# auto.conf.cmd (the list of Kconfig files auto.conf depends on) is
	# also missing, and Kbuild would run syncconfig to make it. An empty one
	# is a valid "no dependencies" file.
	[ -e "$KDIR/include/config/auto.conf.cmd" ] || : > "$KDIR/include/config/auto.conf.cmd"
else
	cp /work/kconfig "$KDIR/.config"
	make -C "$KDIR" olddefconfig
fi
# modules_prepare also runs archheaders, which needs arch/*/entry/syscalls/
# Makefile and the like; those are stripped from the appliance's headers,
# whose generated files are all there already.
[ "$PREPARED" = 1 ] || make -C "$KDIR" modules_prepare

MODPOST_WARN=
if [ "$MODE" != apt ]; then
	# The branch head is not necessarily the exact running kernel, and
	# EXTRAVERSION ("-production") is not in the config. vermagic must match
	# the running kernel or insmod refuses the module, so pin the release.
	built=$(cat "$KDIR/include/config/kernel.release")
	if [ "$built" != "$KVER" ]; then
		echo "warning: source tree is $built, running kernel is $KVER; forcing the release string to $KVER" >&2
		echo "$KVER" > "$KDIR/include/config/kernel.release"
		printf '#define UTS_RELEASE "%s"\n' "$KVER" > "$KDIR/include/generated/utsrelease.h"
	fi
fi
# A bare source tree has no Module.symvers (that needs a full kernel build),
# so modpost cannot resolve exported symbols. Treat that as a warning to get a
# module at all, but such a module has no symbol CRCs and a CONFIG_MODVERSIONS
# kernel will refuse to load it ("no symbol version for module_layout").
if [ ! -f "$KDIR/Module.symvers" ]; then
	MODPOST_WARN=1
	echo "warning: no Module.symvers in $KDIR; the module will carry no symbol CRCs and a modversions kernel will reject it" >&2
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

# The toolchain goes into its own image so that docker caches it: installing
# it takes minutes, the module build itself a few seconds.
BUILD_IMAGE="ugreen-cs201x-build:$(echo "$IMAGE" | tr '/:' '--')"
if [ "$REBUILD" = 1 ] || ! docker image inspect "$BUILD_IMAGE" >/dev/null 2>&1; then
	echo "building the toolchain image $BUILD_IMAGE (first run only)"
	docker build $([ "$REBUILD" = 1 ] && echo "--pull --no-cache") -t "$BUILD_IMAGE" - <<DOCKERFILE
FROM $IMAGE
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \\
		build-essential bc bison flex libssl-dev libelf-dev kmod rsync \\
		ca-certificates git \\
	&& rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

echo "building for $KVER in $BUILD_IMAGE (mode=$MODE)"
docker run --rm \
	-v "$SRCDIR:/src:ro" \
	-v "$WORK:/work:ro" \
	-v "$SRCDIR/build/$KVER:/out" \
	$([ "$MODE" = host ] && echo "-v /usr/src:/usr/src:ro") \
	-w /build \
	"$BUILD_IMAGE" \
	bash /work/build.sh "$KVER" "$MODE" "$HOSTKDIR"

echo
echo "built: $SRCDIR/build/$KVER/ugreen-cs201x.ko"
echo "built: $SRCDIR/build/$KVER/ugreen-cs201x-leds.ko"
