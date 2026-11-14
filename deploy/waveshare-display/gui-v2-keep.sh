#!/bin/sh
#
# Keep the new Venus UI (gui-v2) on the local display across firmware updates.
#
# Victron does not ship the native gui-v2 in the Raspberry Pi image, but the
# package is in the feed for this architecture. A firmware update writes a
# fresh rootfs (without gui-v2, with a small 1.1 GB filesystem), so reinstall
# it from the feed configured for the installed Venus version:
#
#   wait for the feed server -> grow the rootfs (Venus' resize2fs.sh)
#   -> opkg install start-gui-v2 (replaces start-gui-v1, switches the service)
#   -> restore the original fstab / read-only rootfs -> RunningVersion = 2
#
# Started in the background by waveshare-display.sh when gui-v2 is missing and
# /data/waveshare-display/gui-v2.enabled exists. Disable: remove that file.

DIR=/data/waveshare-display
LOG=/data/log/waveshare-display.log
GUIV2=/opt/victronenergy/gui-v2/venus-gui-v2
FEED=https://updates.victronenergy.com/feeds/venus/

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') gui-v2: $*" >> "$LOG"; }

exec 9> /run/gui-v2-keep.lock
flock -n 9 || exit 0                    # another instance is running
[ -f "$DIR/gui-v2.enabled" ] || exit 0
[ -e "$GUIV2" ] && exit 0               # present (or shipped by Victron one day)

# 1. Wait for the feed server: up to 60 min, otherwise retry on next boot.
i=0
until curl -s -m 10 -o /dev/null "$FEED"; do
	i=$((i + 1))
	if [ $i -ge 60 ]; then log "no connection to the feed, will retry on next boot"; exit 1; fi
	sleep 60
done
log "not installed on $(head -n 1 /opt/victronenergy/version) ($(sed -n 3p /opt/victronenergy/version)), installing from the feed"

# 2. Writable rootfs with enough space. resize2fs.sh also switches fstab to rw;
#    keep the original so the rootfs is read-only again afterwards.
was_ro=0
awk '$2 == "/" && $4 ~ /(^|,)ro($|,)/ { f = 1 } END { exit !f }' /proc/mounts && was_ro=1
cp /etc/fstab /run/fstab.orig
/opt/victronenergy/swupdate-scripts/resize2fs.sh >> "$LOG" 2>&1

restore() {
	cmp -s /run/fstab.orig /etc/fstab || cp /run/fstab.orig /etc/fstab
	sync
	if [ "$was_ro" = 1 ]; then
		mount -o remount,ro / 2>> "$LOG" || log "rootfs stays writable until reboot"
	fi
}

# 3. Install. Replacing start-gui-v1 stops gui-v1 and starts the gui-v2 service.
out=/run/gui-v2-keep.opkg
if opkg update > "$out" 2>&1 && opkg install start-gui-v2 >> "$out" 2>&1 && [ -e "$GUIV2" ]; then
	grep -vE '^(Downloading|Configuring|Updated source)' "$out" | sed 's/^/    /' >> "$LOG"
	log "installed $(opkg status gui-v2 | sed -n 's/^Version: //p')"
	dbus -y com.victronenergy.settings /Settings/Gui/RunningVersion SetValue %2 > /dev/null 2>&1
	svc -t /service/venus-platform      # re-evaluates OnScreenGuiv2Supported
	"$DIR/waveshare-display.sh"         # landscape framebuffer for the new gui-v2 service
	rc=0
else
	sed 's/^/    /' "$out" | tail -n 20 >> "$LOG"
	log "install FAILED, staying on gui-v1 (retry on next boot)"
	rc=1
fi
rm -f "$out"
restore
exit $rc
