Waveshare DSI-TOUCH v2 panel (RPI-HMI-7A) on Venus OS, Raspberry Pi 4
=====================================================================

Files
  waveshare-panel-regulator.ko   panel MCU on I2C 0x45: power rails, reset, backlight
  panel-waveshare-dsi-v2.ko      DSI panel driver (backport rpi-6.18.y -> 5.10)
  goodix.ko                      Goodix touch with polling (the panel has no IRQ line)
  vc4-kms-v3d-pi4.dtbo           KMS overlay (not shipped in the Venus Pi 4 image)
  vc4-kms-dsi-waveshare-panel-v2.dtbo   Waveshare overlay for the 5.10 device tree
  waveshare-display.sh           boot script, called from /data/rcS.local
  gui-v2-keep.sh                 optional: installs the new UI (gui-v2) from the feed
  fbrotate                       mirrors gui-v2's 1280x720 framebuffer (vfb, /dev/fb1)
                                 onto the 720x1280 panel, rotated
  gui-v2-qml.patch               gui-v2 QML fix, puts the on-screen keyboard at the
                                 bottom of the (scaled) UI on the 1280x720 screen
  panel                          optional: overlay parameters (default 7_0_inch_a)
  gui-v2.enabled                 optional: keep gui-v2 on the local display
  rotation                       optional: "ccw" turns the gui-v2 picture by 180 degrees
  no-landscape-fb                optional: let gui-v2 rotate itself (dialogs then close)

At every boot the script checks the kernel version, makes sure the overlays and
config.txt lines are present, loads the modules from /data, waits for /dev/fb0
so that the Venus GUI starts on the panel, and exposes the backlight to Venus
(brightness setting, display-off timer) via a ramdisk copy of /etc/venus.
The rootfs is not modified, so firmware updates keep the display working as
long as the kernel stays 5.10.110.

New UI (gui-v2): Victron does not ship it in the Raspberry Pi image and every
firmware update removes it. With gui-v2.enabled present, gui-v2-keep.sh installs
it from the Victron feed in the background once the network is up; until then
the classic UI is shown. Disable: rm /data/waveshare-display/gui-v2.enabled
gui-v2 closes its dialogs when it has to rotate itself, so with gui-v2 the
script gives it a landscape virtual framebuffer (vfb) that the fbrotate service
copies onto the panel, and Qt rotates the touch input. gui-v2 scales its
1024x600 layout to the 1280x720 screen, but places the on-screen keyboard as if
the screen were 1024x600, so the keyboard hung off the left edge; the script
patches ramdisk copies of two gui-v2 QML files (gui-v2-qml.patch) and
bind-mounts them over the originals.

Log:        /data/log/waveshare-display.log
Disable:    remove the waveshare-display.sh line from /data/rcS.local
Note:       Venus "Modification checks" can disable /data/rcS.local
            (renames it to rcS.local.disabled) when modifications are disallowed.
