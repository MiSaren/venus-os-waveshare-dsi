#!/bin/sh
#
# Install Waveshare DSI-TOUCH v2 panel support on Venus OS (Raspberry Pi 4).
# Run on the GX device as root from the unpacked release directory:
#
#   ./install.sh [--gui-v2] [--panel <overlay parameters>]
#
#   --gui-v2   also install and keep the new UI (gui-v2) on the local display
#              (downloads it from the Victron feed after the display is up)
#   --panel    overlay parameters, default "7_0_inch_a" (RPI-HMI-7A); touch
#              options can be appended, e.g. "7_0_inch_a,invx"
#
# Then reboot. Remove again with ./uninstall.sh.
set -e

SRC=$(cd "$(dirname "$0")" && pwd)
DST=/data/waveshare-display
HOOK=/data/rcS.local
CALL="$DST/waveshare-display.sh"
gui_v2=0
panel=

while [ $# -gt 0 ]; do
	case "$1" in
	--gui-v2) gui_v2=1 ;;
	--panel) shift; panel="$1" ;;
	*) echo "usage: $0 [--gui-v2] [--panel <overlay parameters>]" >&2; exit 2 ;;
	esac
	shift
done

machine=$(cat /etc/venus/machine 2> /dev/null || true)
[ "$machine" = raspberrypi4 ] || { echo "This is for Venus OS on a Raspberry Pi 4 (machine: '${machine:-unknown}')." >&2; exit 1; }
built=$(modinfo -F vermagic "$SRC/waveshare-display/goodix.ko" | cut -d' ' -f1)
[ "$(uname -r)" = "$built" ] || { echo "Running kernel $(uname -r), but the modules were built for $built: rebuild them." >&2; exit 1; }

mkdir -p "$DST"
cp "$SRC"/waveshare-display/* "$DST"/
chmod 755 "$DST"/*.sh
[ -n "$panel" ] && echo "$panel" > "$DST/panel"
[ "$gui_v2" = 1 ] && touch "$DST/gui-v2.enabled"

# Boot hook: keep whatever else is in rcS.local.
[ -f "$HOOK" ] || printf '#!/bin/sh\n' > "$HOOK"
grep -qxF "$CALL" "$HOOK" || printf '%s\n' "$CALL" >> "$HOOK"
chmod 755 "$HOOK"

# Copies the overlays to /u-boot/overlays and adds the config.txt lines
# (the same check runs on every boot).
"$CALL"
echo "Installed to $DST. Reboot to activate the display; log: /data/log/waveshare-display.log"
