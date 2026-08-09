#!/bin/bash
#
# qemu-armhf-build.sh -- build the FPP bb-kernel .deb packages inside an armhf
# userspace, so the resulting linux-headers package contains armhf host tools
# (fixdep/objtool/resolve_btfids) instead of the build host's. A cross-compile
# bakes the wrong-arch tools into the headers .deb and breaks on-device module
# builds; building natively-in-userspace avoids that.
#
# On an x86_64 host the armhf userspace runs under qemu-user-static (slow but
# works anywhere). On an aarch64 host the CPU executes aarch32 directly, so the
# same armhf chroot runs at full native speed with no emulation. Either way the
# bb-kernel scripts auto-select their native path because uname -m reports
# armv7l inside the chroot (see scripts/gcc.sh / system.sh).
#
# The bb-kernel working tree (this repo, including local patches) is bind-mounted
# into the chroot and built in place, so whatever you have checked out -- new
# patches under patches/, patch.sh edits, etc. -- is what gets built. Output
# .deb packages land in <bb-kernel>/deploy/ on the host.
#
# Usage:
#   sudo ./tools/qemu-armhf-build.sh                    # auto-fetch+cache nightly BBB image, build
#   sudo ./tools/qemu-armhf-build.sh --refresh          # re-check the nightly release for a newer build
#   sudo ./tools/qemu-armhf-build.sh --image /path/to/FPP-vX-BBB.img
#   sudo ./tools/qemu-armhf-build.sh --rootfs /srv/fpp-armhf        # reuse existing
#   sudo ./tools/qemu-armhf-build.sh --debootstrap                  # fresh Debian
#
# Source selection (first match wins): --image, --debootstrap, an already
# populated --rootfs, else the FPP nightly BBB image is downloaded automatically.
#
# Options:
#   --nightly           Fetch the nightly BBB image from the FalconChristmas/fpp
#                       'nightly' GitHub release (this is the default when no
#                       other source is given). Cached under --cache-dir and
#                       re-downloaded only when the asset's sha256 changes.
#   --fppos             Use the .fppos nightly asset instead of FPP-vnightly-BBB.img.zip.
#                       The .fppos is a squashfs root filesystem mounted directly
#                       (smaller download; needs kernel squashfs + loop support).
#   --refresh           Re-query the nightly release even if a cached image exists.
#   --cache-dir DIR     Where to cache the downloaded image (default: <parent>/fpp-image-cache).
#   --image PATH        Extract the armhf rootfs from this local .img instead.
#   --rootfs DIR        Rootfs directory to use/create (default: <parent>/bb-kernel-armhf-rootfs).
#   --part N            Partition number in the image holding the rootfs (default: auto-detect).
#   --menuconfig        Run an interactive 'make menuconfig' to review/edit the
#                       kernel config before the (multi-hour) compile. Otherwise
#                       the build is headless (configured from the FPP defconfig).
#   --debootstrap       Create the rootfs with debootstrap instead of from an image.
#   --suite NAME        debootstrap suite (default: bookworm).
#   --mirror URL        debootstrap mirror (default: http://deb.debian.org/debian).
#   --build CMD         Build command run inside the chroot (default: ./build_deb.sh).
#   -h, --help          Show this help.
#
# Needs (host): curl, python3, rsync, unzip (.img.zip) or kernel squashfs+loop
# (--fppos), and on x86: qemu-user-static + binfmt-support.
#
set -euo pipefail

err()  { echo "* $*" >&2; exit 1; }
warn() { echo "! $*" >&2; }
log()  { echo "== $*" >&2; }

# --- locate the bb-kernel repo (parent of this tools/ dir) ---
SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
KERNEL_DIR=$(dirname "$SCRIPT_DIR")

# --- defaults ---
IMAGE=""
ROOTFS=""
PART=""
DO_DEBOOTSTRAP=0
DO_NIGHTLY=0
USE_FPPOS=0
REFRESH=0
CACHE_DIR=""
IMG_VERSION=""        # set by fetch_nightly_image; used as the rootfs freshness marker
IMAGE_KIND="img"      # "img" (loop-mount partitions) or "squashfs" (mount directly)
MENUCONFIG=0          # 1 = run interactive 'make menuconfig' before the compile
SUITE="bookworm"
MIRROR="http://deb.debian.org/debian"
BUILD_CMD="./build_deb.sh"

while [ $# -gt 0 ]; do
	case "$1" in
		--image)       IMAGE=$2; shift 2 ;;
		--rootfs)      ROOTFS=$2; shift 2 ;;
		--part)        PART=$2; shift 2 ;;
		--debootstrap) DO_DEBOOTSTRAP=1; shift ;;
		--menuconfig)  MENUCONFIG=1; shift ;;
		--nightly)     DO_NIGHTLY=1; shift ;;
		--fppos)       DO_NIGHTLY=1; USE_FPPOS=1; shift ;;
		--refresh)     REFRESH=1; shift ;;
		--cache-dir)   CACHE_DIR=$2; shift 2 ;;
		--suite)       SUITE=$2; shift 2 ;;
		--mirror)      MIRROR=$2; shift 2 ;;
		--build)       BUILD_CMD=$2; shift 2 ;;
		--keep)        shift ;;   # accepted for compatibility; rootfs is kept regardless
		-h|--help)     sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
		*)             err "unknown option: $1 (try --help)" ;;
	esac
done

# Default rootfs is a SIBLING of the bb-kernel repo, never inside it -- the repo
# gets bind-mounted into the chroot, so a rootfs under it would nest recursively.
ROOTFS=${ROOTFS:-$(dirname "$KERNEL_DIR")/bb-kernel-armhf-rootfs}
CACHE_DIR=${CACHE_DIR:-$(dirname "$KERNEL_DIR")/fpp-image-cache}

[ "$(id -u)" = 0 ] || err "must run as root (sudo) -- needs loop mounts, bind mounts and chroot"

# --- decide whether we need qemu emulation ---
HOST_ARCH=$(uname -m)
NEED_QEMU=1
case "$HOST_ARCH" in
	aarch64|armv7l|armv8l) NEED_QEMU=0 ;;
esac

QEMU_BIN=""
if [ "$NEED_QEMU" = 1 ]; then
	QEMU_BIN=$(command -v qemu-arm-static || true)
	[ -n "$QEMU_BIN" ] || err "qemu-arm-static not found. Install: apt-get install qemu-user-static binfmt-support"
	if command -v update-binfmts >/dev/null 2>&1; then
		if ! update-binfmts --display qemu-arm 2>/dev/null | grep -q 'flags:.*F'; then
			warn "qemu-arm binfmt is missing the 'F' (fix-binary) flag; exec inside chroot may fail."
			warn "Try: update-binfmts --enable qemu-arm   (or reinstall qemu-user-static)"
		fi
	fi
	log "x86 host detected -- building under qemu-user emulation (slow)."
else
	log "ARM host detected ($HOST_ARCH) -- armhf chroot runs natively, no emulation."
fi

# --- mount bookkeeping + cleanup ---
MOUNTS=()
LOOP=""
TMP_MNT=""
cleanup() {
	set +e
	for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
		umount "${MOUNTS[$i]}" 2>/dev/null || umount -l "${MOUNTS[$i]}" 2>/dev/null
	done
	if [ -n "$TMP_MNT" ] && [ -d "$TMP_MNT" ]; then
		umount "$TMP_MNT" 2>/dev/null || umount -l "$TMP_MNT" 2>/dev/null
		rmdir "$TMP_MNT" 2>/dev/null
	fi
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT INT TERM

bind_mount() {
	local src=$1 dst=$2 type=${3:-bind}
	mkdir -p "$dst"
	if [ "$type" = bind ]; then
		mount --bind "$src" "$dst"
	else
		mount -t "$type" "$type" "$dst"
	fi
	MOUNTS+=("$dst")
}

# --- fetch + cache the FPP nightly BBB image, sets IMAGE and IMG_VERSION ---
NIGHTLY_REPO="FalconChristmas/fpp"
NIGHTLY_TAG="nightly"

fetch_nightly_image() {
	command -v curl    >/dev/null || err "curl not found (needed to fetch the nightly image)"
	command -v python3 >/dev/null || err "python3 not found (needed to parse the GitHub API)"
	local mode="zip"; [ "$USE_FPPOS" = 1 ] && mode="fppos"
	if [ "$mode" = fppos ]; then
		command -v mount >/dev/null || err "mount not found (needed for --fppos squashfs)"
	else
		command -v unzip >/dev/null || err "unzip not found (needed to unpack the .img.zip)"
	fi

	mkdir -p "$CACHE_DIR"
	local api="https://api.github.com/repos/${NIGHTLY_REPO}/releases/tags/${NIGHTLY_TAG}"
	local auth=(); local tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
	[ -n "$tok" ] && auth=(-H "Authorization: Bearer $tok")

	log "Querying GitHub for the nightly BBB image (${mode})"
	local meta; meta=$(curl -fsSL "${auth[@]}" "$api") || err "failed to query $api"

	# url \t sha256(empty if absent) \t version-key \t asset-name
	local line; line=$(printf '%s' "$meta" | python3 -c '
import json,sys
d=json.load(sys.stdin); mode=sys.argv[1]
def match(n):
    return (n.endswith(".fppos") and "BBB" in n) if mode=="fppos" else n=="FPP-vnightly-BBB.img.zip"
for a in d.get("assets",[]):
    n=a.get("name","")
    if match(n):
        dig=a.get("digest","") or ""
        if dig.startswith("sha256:"): dig=dig[7:]
        ver=dig or ("%s:%s"%(a.get("updated_at",""),a.get("size","")))
        print("\t".join([a.get("browser_download_url",""),dig,ver,n])); break
' "$mode") || err "could not parse GitHub API response"
	[ -n "$line" ] || err "no matching ${mode} BBB asset in ${NIGHTLY_REPO} '${NIGHTLY_TAG}' release"
	local url digest verkey aname
	IFS=$'\t' read -r url digest verkey aname <<<"$line"

	# 'usable' is what the extract step consumes: a raw .img for the zip asset,
	# or the .fppos squashfs itself (it IS the rootfs, mounted read-only later).
	local art="$CACHE_DIR/$aname" marker="$CACHE_DIR/$aname.verkey" usable
	if [ "$mode" = fppos ]; then usable="$art"; IMAGE_KIND=squashfs
	else                          usable="$CACHE_DIR/${aname%.zip}"; IMAGE_KIND=img; fi

	if [ "$REFRESH" = 0 ] && [ -f "$usable" ] && [ "$(cat "$marker" 2>/dev/null)" = "$verkey" ]; then
		log "  cached image is current ($aname) -- skipping download"
	else
		log "  downloading $aname (~1-1.5GB)"
		curl -fSL --retry 3 "${auth[@]}" -o "$art.tmp" "$url" || err "download failed: $url"
		if [ -n "$digest" ]; then
			local got; got=$(sha256sum "$art.tmp" | awk '{print $1}')
			[ "$got" = "$digest" ] || err "sha256 mismatch for $aname (got $got, expected $digest)"
			log "  sha256 verified"
		fi
		if [ "$mode" = fppos ]; then
			mv -f "$art.tmp" "$usable"   # keep the squashfs; mounted directly at extract time
		else
			mv -f "$art.tmp" "$art"
			rm -f "$usable"
			log "  unzipping -> $usable"
			unzip -o -j "$art" -d "$CACHE_DIR" >/dev/null
			[ -f "$usable" ] || usable=$(find "$CACHE_DIR" -maxdepth 1 -name '*.img' | head -n1)
			[ -n "$usable" ] && [ -f "$usable" ] || err "no .img produced from $aname"
			rm -f "$art"                 # drop the zip, keep the .img
		fi
		printf '%s\n' "$verkey" > "$marker"
	fi
	IMAGE="$usable"; IMG_VERSION="$verkey"
}

# --- choose a rootfs source: explicit flags win, else reuse, else nightly ---
[ "$REFRESH" = 1 ] && [ -z "$IMAGE" ] && [ "$DO_DEBOOTSTRAP" = 0 ] && DO_NIGHTLY=1
if [ "$DO_NIGHTLY" = 0 ] && [ -z "$IMAGE" ] && [ "$DO_DEBOOTSTRAP" = 0 ]; then
	if [ -d "$ROOTFS/etc" ] && [ -e "$ROOTFS/bin/sh" ]; then
		log "Reusing existing rootfs at $ROOTFS (pass --refresh to fetch a newer nightly)"
	else
		DO_NIGHTLY=1
	fi
fi
[ "$DO_NIGHTLY" = 1 ] && fetch_nightly_image

# A newer nightly than the one the current rootfs was built from is stale.
if [ -n "$IMG_VERSION" ] && [ -d "$ROOTFS/etc" ] && \
   [ "$(cat "$ROOTFS/.fpp-image-version" 2>/dev/null)" != "$IMG_VERSION" ]; then
	log "Nightly image changed since the cached rootfs -- re-extracting at $ROOTFS"
	rm -rf "$ROOTFS"
fi

# --- populate the rootfs (idempotent: skip if already populated) ---
if [ -d "$ROOTFS/etc" ] && [ -e "$ROOTFS/bin/sh" ]; then
	log "Reusing existing rootfs at $ROOTFS"
elif [ -n "$IMAGE" ]; then
	[ -f "$IMAGE" ] || err "image not found: $IMAGE"
	mkdir -p "$ROOTFS"
	if [ "$IMAGE_KIND" = squashfs ] || [ "${IMAGE##*.}" = fppos ]; then
		# .fppos is a squashfs that IS the rootfs (read-only) -- mount and copy out
		log "Extracting armhf rootfs from squashfs $IMAGE"
		TMP_MNT=$(mktemp -d)
		mount -t squashfs -o loop,ro "$IMAGE" "$TMP_MNT" || err "failed to mount squashfs $IMAGE"
		[ -d "$TMP_MNT/etc" ] || err "$IMAGE is not a root filesystem (no /etc inside)"
		log "  rsync -> $ROOTFS"
		rsync -aHAX --numeric-ids "$TMP_MNT"/ "$ROOTFS"/
		umount "$TMP_MNT"; rmdir "$TMP_MNT"; TMP_MNT=""
	else
	log "Extracting armhf rootfs from $IMAGE"
	LOOP=$(losetup -fP --show "$IMAGE")
	log "  loop device: $LOOP"
	TMP_MNT=$(mktemp -d)
	# pick the rootfs partition: explicit --part, else auto-detect (below)
	local_part=""
	if [ -n "$PART" ]; then
		local_part="${LOOP}p${PART}"
	else
		# FPP BBB images put the rootfs on partition 3; detect it rather than assume,
		# by taking the largest partition that looks like a Linux root (/etc /bin /lib).
		best_size=0
		for p in "${LOOP}"p*; do
			[ -b "$p" ] || continue
			if mount -o ro "$p" "$TMP_MNT" 2>/dev/null; then
				if [ -d "$TMP_MNT/etc" ] && [ -d "$TMP_MNT/bin" ] && [ -d "$TMP_MNT/lib" ]; then
					sz=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
					[ "$sz" -gt "$best_size" ] && { best_size=$sz; local_part="$p"; }
				fi
				umount "$TMP_MNT"
			fi
		done
	fi
	[ -n "$local_part" ] || err "could not locate rootfs partition in $IMAGE (try --part N)"
	log "  rootfs partition: $local_part"
	mount -o ro "$local_part" "$TMP_MNT"   # tracked via $TMP_MNT for cleanup()
	mkdir -p "$ROOTFS"
	log "  rsync -> $ROOTFS (image is space-tight; copying out)"
	rsync -aHAX --numeric-ids "$TMP_MNT"/ "$ROOTFS"/
	umount "$TMP_MNT"
	losetup -d "$LOOP"; LOOP=""
	rmdir "$TMP_MNT"; TMP_MNT=""
	fi
	# record which nightly this rootfs came from so we can detect staleness
	[ -n "$IMG_VERSION" ] && printf '%s\n' "$IMG_VERSION" > "$ROOTFS/.fpp-image-version"
elif [ "$DO_DEBOOTSTRAP" = 1 ]; then
	command -v debootstrap >/dev/null || err "debootstrap not installed (apt-get install debootstrap)"
	log "debootstrap armhf $SUITE -> $ROOTFS"
	mkdir -p "$ROOTFS"
	if [ "$NEED_QEMU" = 1 ]; then
		debootstrap --arch=armhf --foreign "$SUITE" "$ROOTFS" "$MIRROR"
		cp "$QEMU_BIN" "$ROOTFS/usr/bin/"
		chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
	else
		debootstrap --arch=armhf "$SUITE" "$ROOTFS" "$MIRROR"
	fi
else
	err "no rootfs: use --nightly (default), --image PATH, --debootstrap, or an existing --rootfs"
fi

# --- stage qemu + DNS into the rootfs ---
if [ "$NEED_QEMU" = 1 ]; then
	cp "$QEMU_BIN" "$ROOTFS/usr/bin/"
fi
cp -f /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true

# --- kernel pseudo-filesystems + the bb-kernel source tree ---
bind_mount /proc      "$ROOTFS/proc"
bind_mount /sys       "$ROOTFS/sys"
bind_mount /dev       "$ROOTFS/dev"
bind_mount /dev/pts   "$ROOTFS/dev/pts"
mkdir -p "$ROOTFS/run"; bind_mount /run "$ROOTFS/run" 2>/dev/null || true

BIND_SRC="/opt/bb-kernel-src"
bind_mount "$KERNEL_DIR" "$ROOTFS$BIND_SRC"

# --- install build deps + build, all as armhf ---
# Run the in-chroot steps from a script file executed with the terminal still
# attached -- NOT via 'bash -s <<HEREDOC', which makes stdin the heredoc text and
# leaves interactive tools (make menuconfig) with no keyboard.
if [ "$MENUCONFIG" = 1 ]; then
	AUTO_BUILD_LINE='# --menuconfig: AUTO_BUILD left unset so build_deb.sh runs menuconfig'
	log "Entering chroot -- menuconfig will run (review/save), then build"
else
	AUTO_BUILD_LINE='export AUTO_BUILD=1   # headless: skip menuconfig, build from the FPP defconfig'
	log "Entering chroot to install deps and build ($BUILD_CMD)"
fi
CHROOT_SCRIPT="$ROOTFS/root/.fpp-chroot-build.sh"
cat > "$CHROOT_SCRIPT" <<CHROOT
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export HOME=/root
export TERM="${TERM:-xterm}"
echo "== inside chroot: uname -m = \$(uname -m)"
# bb-kernel's host_det.sh deps PLUS debhelper (dpkg-buildpackage's
# debhelper-compat build-dep) and ncurses-term (terminfo for menuconfig). The
# marker is versioned, so changing this list re-triggers the install; delete
# \$ROOTFS/var/lib/.fpp-kernel-build-deps-2 to force a re-run.
if [ ! -f /var/lib/.fpp-kernel-build-deps-2 ]; then
	apt-get update
	apt-get install -y --no-install-recommends \
		bash bc bison build-essential cpio fakeroot flex lsb-release lz4 man-db \
		gettext pkg-config libmpc-dev u-boot-tools xz-utils zstd libdw-dev libelf-dev \
		bindgen rust-src rustc rustfmt rust-clippy libncurses-dev libssl-dev \
		debhelper ncurses-term \
		git ccache rsync device-tree-compiler kmod ca-certificates wget dpkg-dev
	touch /var/lib/.fpp-kernel-build-deps-2
fi
# The FPP rootfs ships duplicate user.email/user.name, which breaks bb-kernel's
# scripts/git.sh; collapse to one clean identity.
for k in user.email user.name; do git config --global --unset-all "\$k" 2>/dev/null || true; done
git config --global user.email "fpp-build@localhost"
git config --global user.name  "FPP Build"
$AUTO_BUILD_LINE
cd "$BIND_SRC"
$BUILD_CMD
CHROOT
chroot "$ROOTFS" /bin/bash /root/.fpp-chroot-build.sh
rm -f "$CHROOT_SCRIPT"

log "Build finished. .deb packages are in: $KERNEL_DIR/deploy/"
ls -1 "$KERNEL_DIR"/deploy/*.deb 2>/dev/null || warn "no .deb found in deploy/ -- check build output above"
