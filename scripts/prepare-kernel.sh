#!/bin/bash
#
# Prepare a kernel tree that matches the Venus OS Raspberry Pi 4 kernel
# (5.10.110-rpi-venus-8, Venus OS v3.x), so that out-of-tree modules built
# against it load on the device (same vermagic, same MODVERSIONS CRCs).
#
#   1. fetch victronenergy/linux at the commit used by the Venus recipe
#   2. apply the patches from meta-victronenergy (GCC 13 / gcc-plugin fixes)
#   3. take .config and Module.symvers from Victron's kernel-dev package
#   4. make olddefconfig modules_prepare (builds the arm_ssp_per_task plugin)
#
# Usage: scripts/prepare-kernel.sh [kernel-dir]     (default: ./kernel-src)
#
# Host packages (Ubuntu 24.04):
#   gcc-arm-linux-gnueabihf gcc-13-plugin-dev-arm-linux-gnueabihf
#   bison flex device-tree-compiler libgmp-dev libmpc-dev libssl-dev bc
set -euo pipefail

KVER=5.10.110
KPKG=5.10.110-rpi-venus-8-r0
LINUX_REPO=https://github.com/victronenergy/linux.git
LINUX_COMMIT=3859262148951d08d011c96d637383883c451739
META_COMMIT=e71b0c969dcb919753f242448142b90f40e5ed8f
META_FILES=https://raw.githubusercontent.com/victronenergy/meta-victronenergy/$META_COMMIT/meta-bsp/recipes-kernel/linux/files
FEED=${FEED:-https://updates.victronenergy.com/feeds/venus/release/packages/scarthgap/raspberrypi4}
PATCHES=(
	0001-gcc-plugins-remove-code-for-GCC-versions-older-than-.patch
	0002-gcc-plugins-remove-support-for-GCC-4.9-and-older.patch
	0003-gcc-plugins-remove-duplicate-include-in-gcc-common.h.patch
	0004-gcc-plugins-Reorganize-gimple-includes-for-GCC-13.patch
	0001-work-around-for-too-few-arguments-to-function-init_d.patch
	0001-ata-ahci-fix-enum-constants-for-gcc-13.patch
	wifi_cfg80211_certificate.patch
)
CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabihf-}
KDIR=$(realpath -m "${1:-$(dirname "$0")/../kernel-src}")
KMAKE=(make -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)")

for tool in git curl ar tar make bison flex "${CROSS_COMPILE}gcc"; do
	command -v "$tool" > /dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
plugin_dir=$("${CROSS_COMPILE}gcc" -print-file-name=plugin)
[ -e "$plugin_dir/include/plugin-version.h" ] || {
	echo "GCC plugin headers missing for ${CROSS_COMPILE}gcc (install gcc-13-plugin-dev-arm-linux-gnueabihf)." >&2
	echo "The Venus kernel uses GCC_PLUGIN_ARM_SSP_PER_TASK; modules built without it will not load." >&2
	exit 1
}

echo "==> kernel source ($LINUX_COMMIT) in $KDIR"
if [ ! -d "$KDIR/.git" ]; then
	git init -q "$KDIR"
	git -C "$KDIR" remote add origin "$LINUX_REPO"
fi
if [ "$(git -C "$KDIR" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$LINUX_COMMIT" ]; then
	git -C "$KDIR" fetch -q --depth 1 origin "$LINUX_COMMIT"
	git -C "$KDIR" checkout -q FETCH_HEAD
fi

echo "==> Venus patches (meta-victronenergy $META_COMMIT)"
for p in "${PATCHES[@]}"; do
	f=$(mktemp)
	curl -fsSL -o "$f" "$META_FILES/$p"
	if git -C "$KDIR" apply --reverse --check "$f" 2> /dev/null; then
		echo "    already applied: $p"
	else
		git -C "$KDIR" apply "$f" && echo "    applied: $p"
	fi
	rm -f "$f"
done

echo "==> .config and Module.symvers from kernel-dev_${KPKG}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/kernel-dev.ipk" "$FEED/kernel-dev_${KPKG}_raspberrypi4.ipk" || {
	echo "kernel-dev_${KPKG} not found in $FEED (set FEED=... to another Venus feed)" >&2; exit 1; }
(cd "$tmp" && ar x kernel-dev.ipk && mkdir x && tar -C x -xf data.tar.*)
cp "$tmp/x/boot/config-$KVER" "$KDIR/.config"
cp "$tmp/x/boot/Module.symvers-$KVER" "$KDIR/Module.symvers"

# An empty .scmversion stops setlocalversion from appending "+" (the tree is a
# modified git checkout); otherwise vermagic would be "5.10.110+" and the
# modules would be rejected.
: > "$KDIR/.scmversion"

echo "==> olddefconfig + modules_prepare"
"${KMAKE[@]}" -s olddefconfig
"${KMAKE[@]}" -s modules_prepare 2>&1 | grep -vE 'extract-cert|In file included|deprecated|ENGINE_|^\s+[0-9]+ \||^\s+\||note:|\^~' || true

release=$(cat "$KDIR/include/config/kernel.release")
[ "$release" = "$KVER" ] || { echo "unexpected kernel release '$release' (expected $KVER)" >&2; exit 1; }
grep -q '^CONFIG_GCC_PLUGIN_ARM_SSP_PER_TASK=y' "$KDIR/.config" || {
	echo "GCC plugins got disabled by olddefconfig - check the plugin headers" >&2; exit 1; }
echo "==> ready: $KDIR (kernel release $release). Build: make -C driver"
