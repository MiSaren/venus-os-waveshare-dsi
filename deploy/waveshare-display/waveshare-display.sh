#!/bin/sh
#
# Waveshare DSI-TOUCH v2 panel (e.g. RPI-HMI-7A) on Venus OS, Raspberry Pi 4.
#
# Runs early at boot from /data/rcS.local: after udev coldplug, before the GUI
# (svscan in rc5) starts. Everything lives on /data and the boot partition;
# the rootfs is not modified (except by the optional gui-v2 reinstall, see
# gui-v2-keep.sh), so Venus firmware updates and the normal <-> large image
# switch keep the display working as long as the kernel stays the same.
#
#  1. checks that the running kernel is the one the modules were built for
#  2. makes sure the overlays and config.txt lines exist on the boot partition
#  3. loads the backported modules (panel MCU/backlight, panel, goodix polling)
#  4. waits for /dev/fb0, so that the GUI starts on the panel (linuxfb)
#  5. exposes the backlight to Venus (brightness setting, display-off timer)
#  6. with gui-v2: a landscape virtual framebuffer mirrored onto the panel
#     (fbrotate), so that gui-v2 need not rotate itself and its dialogs work
#  7. if gui-v2.enabled exists and gui-v2 is missing (e.g. after a firmware
#     update), starts its installation in the background (gui-v2-keep.sh)
#
# The overlay parameters are read from $DIR/panel (default "7_0_inch_a"; touch
# options can be appended, e.g. "7_0_inch_a,invx"). Idempotent; can also be
# run by hand.

DIR=/data/waveshare-display
LOG=/data/log/waveshare-display.log
BOOT=/u-boot
KVER=5.10.110
PANEL_NODE=/proc/device-tree/soc/dsi@7e700000/dsi_panel@0
BL=/sys/class/backlight/10-0045
PANEL=$(cat "$DIR/panel" 2> /dev/null || echo 7_0_inch_a)

[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && mv "$LOG" "$LOG.old"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
loaded() { grep -q "^$1 " /proc/modules; }

log "start (kernel $(uname -r), uptime $(cut -d. -f1 /proc/uptime)s)"

# 1. Kernel check: the modules only fit the exact kernel they were built for.
if [ "$(uname -r)" != "$KVER" ]; then
	log "kernel $(uname -r) != $KVER: not loading, modules must be rebuilt"
	exit 0
fi
want=$(modinfo -F vermagic "$DIR/goodix.ko")
have=$(modinfo -F vermagic "/lib/modules/$KVER/kernel/drivers/input/touchscreen/goodix.ko")
if [ "$want" != "$have" ]; then
	log "vermagic mismatch ('$want' vs '$have'): not loading"
	exit 0
fi

# 2. Boot partition: overlays and config.txt lines (Venus updates only write
#    the rootfs, but a re-flashed card or a manual edit could lose them).
repaired=0
for f in vc4-kms-v3d-pi4.dtbo vc4-kms-dsi-waveshare-panel-v2.dtbo; do
	if ! cmp -s "$DIR/$f" "$BOOT/overlays/$f"; then
		cp "$DIR/$f" "$BOOT/overlays/$f" && repaired=1 && log "restored overlays/$f"
	fi
done
append() {	# add a line to config.txt, in an [all] section
	last=$(grep -E '^\[' "$BOOT/config.txt" | tail -n 1)
	[ -n "$last" ] && [ "$last" != "[all]" ] && printf '[all]\n' >> "$BOOT/config.txt"
	printf '%s\n' "$1" >> "$BOOT/config.txt" && repaired=1 && log "config.txt: added '$1'"
}
grep -qxF "dtoverlay=vc4-kms-v3d-pi4" "$BOOT/config.txt" || append "dtoverlay=vc4-kms-v3d-pi4"
panel_line="dtoverlay=vc4-kms-dsi-waveshare-panel-v2,$PANEL"
if ! grep -qxF "$panel_line" "$BOOT/config.txt"; then
	sed -i '/^dtoverlay=vc4-kms-dsi-waveshare-panel-v2\(,.*\)\{0,1\}$/d' "$BOOT/config.txt"
	append "$panel_line"
fi
[ "$repaired" = 1 ] && sync

if [ ! -d "$PANEL_NODE" ]; then
	log "panel overlay not active in this boot; reboot to enable the display"
	exit 0
fi

# 3. Modules. The stock goodix has no polling mode (the panel has no touch IRQ
#    line), so replace it before the MCU driver makes the touch controller probe.
modprobe -q backlight
modprobe -q drm
if loaded goodix && [ "$(cat /sys/module/goodix/srcversion 2> /dev/null)" != "$(modinfo -F srcversion "$DIR/goodix.ko")" ]; then
	rmmod goodix 2>> "$LOG" && log "removed stock goodix"
fi
for m in waveshare-panel-regulator panel-waveshare-dsi-v2 goodix; do
	if ! loaded "$(echo $m | tr - _)"; then
		if insmod "$DIR/$m.ko" 2>> "$LOG"; then log "loaded $m"; else log "FAILED to load $m"; fi
	fi
done

# 4. Wait for the KMS framebuffer (vc4 binds once the panel driver is in).
i=0
while [ ! -e /dev/fb0 ] && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
if [ -e /dev/fb0 ]; then
	log "display ready after ${i}s: $(cat /sys/class/graphics/fb0/name) $(cat /sys/class/graphics/fb0/virtual_size)"
else
	log "no /dev/fb0 after ${i}s"
	exit 0
fi

# 5. Let Venus drive the backlight like on a GX Touch: the brightness setting
#    (venus-platform) and the display-off timer (GUI) need the runtime features
#    backlight_device and blank_display_device in /etc/venus. That directory is
#    on the read-only rootfs, so mirror it to a ramdisk and bind-mount it over
#    /etc/venus, the same way Venus handles /service (S03overlays.sh). Skipped
#    if Venus ever ships these files itself.
features_added=0
if [ -d "$BL" ] && [ ! -e /etc/venus/backlight_device ]; then
	mkdir -p /run/overlays/etc-venus
	cp -a /etc/venus/. /run/overlays/etc-venus/
	echo "$BL" > /run/overlays/etc-venus/backlight_device
	echo "$BL/bl_power" > /run/overlays/etc-venus/blank_display_device
	if mount --bind /run/overlays/etc-venus /etc/venus; then
		features_added=1
		log "backlight features added to /etc/venus (ramdisk bind mount)"
	fi
fi

# When run by hand (services already up), restart what needs to see the changes:
# gui-v1 falls back to offscreen mode without /dev/fb0, and both GUIs read the
# blanking feature only at startup.
pid=$(pidof gui)
if [ -n "$pid" ] && { [ "$features_added" = 1 ] || ! tr '\0' '\n' < "/proc/$pid/environ" | grep -q '^QT_QPA_PLATFORM=linuxfb'; }; then
	svc -t /service/gui && log "restarted gui"
fi
if [ "$features_added" = 1 ] && [ -n "$(pidof venus-gui-v2)" ]; then
	svc -t /service/gui-v2 && log "restarted gui-v2"
fi
if [ "$features_added" = 1 ] && [ -n "$(pidof venus-platform)" ]; then
	svc -t /service/venus-platform && log "restarted venus-platform"
fi

# 6. gui-v2 rotates itself on a portrait screen, and then closes every dialog
#    right away (QR codes, value editors, confirmations; upstream gui-v2 does
#    this on purpose, its Popup overlay cannot be rotated). Give it a native
#    landscape screen instead: a 1280x720 virtual framebuffer (vfb) that
#    fbrotate mirrors onto the panel, with Qt rotating the touch input.
#    gui-v1 rotates itself without problems and keeps using the panel directly.
#    $DIR/rotation: "cw" (default) or "ccw" to turn the picture 180 degrees.
if [ -d /service/gui-v2 ] && [ ! -f "$DIR/no-landscape-fb" ]; then
	if [ "$(cat "$DIR/rotation" 2> /dev/null)" = ccw ]; then
		rot_arg=--ccw; touch_rot=90
	else
		rot_arg=; touch_rot=270
	fi
	if [ ! -e /dev/fb1 ]; then
		modprobe vfb vfb_enable=1 videomemorysize=2097152 &&
			fbset -fb /dev/fb1 -g 1280 720 1280 720 16 &&
			log "landscape framebuffer /dev/fb1 1280x720 ready"
	fi
	if [ -e /dev/fb1 ] && [ ! -d /service/fbrotate ]; then
		mkdir -p /run/overlays/fbrotate
		printf '#!/bin/sh\nexec 2>&1\nexec %s %s --blank %s /dev/fb1 /dev/fb0\n' \
			"$DIR/fbrotate" "$rot_arg" "$BL/bl_power" > /run/overlays/fbrotate/run
		chmod 755 /run/overlays/fbrotate/run
		ln -s /run/overlays/fbrotate /service/fbrotate	# picked up by svscan
		log "fbrotate service started"
	fi
	if [ -e /dev/fb1 ] && ! grep -q 'fb=/dev/fb1' /service/gui-v2/run; then
		sed -i "s|^\(\. /etc/profile.d/qt6.sh\) && exec |\1 \&\& export QT_QPA_PLATFORM=linuxfb:fb=/dev/fb1:mmsize=154x85 QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS=rotate=$touch_rot \&\& exec |" /service/gui-v2/run
		if grep -q 'fb=/dev/fb1' /service/gui-v2/run; then
			log "gui-v2 moved to the landscape framebuffer"
			[ -n "$(pidof venus-gui-v2)" ] && svc -t /service/gui-v2
		else
			log "gui-v2 run script not recognised, it keeps rotating itself"
		fi
	fi
fi

# 7. New UI (gui-v2): not in the Raspberry Pi image and removed by firmware
#    updates; (re)install it in the background once the network is up.
if [ -f "$DIR/gui-v2.enabled" ] && [ ! -e /opt/victronenergy/gui-v2/venus-gui-v2 ]; then
	setsid "$DIR/gui-v2-keep.sh" < /dev/null > /dev/null 2>&1 &
	log "gui-v2 missing: started background install"
fi
exit 0
