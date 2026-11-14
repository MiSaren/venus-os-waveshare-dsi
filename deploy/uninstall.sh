#!/bin/sh
#
# Remove the Waveshare DSI-TOUCH v2 panel support from Venus OS. Reboot afterwards.
# If gui-v2 was installed, it stays until the next firmware update (or run
# "opkg install start-gui-v1" on a writable rootfs to switch back now).

DST=/data/waveshare-display
HOOK=/data/rcS.local

if [ -f "$HOOK" ]; then
	sed -i "\|^$DST/waveshare-display.sh\$|d" "$HOOK"
	# nothing left but the shebang: remove the hook file
	[ "$(grep -cv '^#!' "$HOOK")" = 0 ] && rm -f "$HOOK"
fi
sed -i -e '/^dtoverlay=vc4-kms-v3d-pi4$/d' \
       -e '/^dtoverlay=vc4-kms-dsi-waveshare-panel-v2\(,.*\)\{0,1\}$/d' /u-boot/config.txt
rm -f /u-boot/overlays/vc4-kms-v3d-pi4.dtbo /u-boot/overlays/vc4-kms-dsi-waveshare-panel-v2.dtbo
rm -rf "$DST"
sync
echo "Removed. Reboot now."
