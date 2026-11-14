# Waveshare DSI-TOUCH v2 panel modules and overlays for Venus OS (Raspberry Pi 4,
# kernel 5.10.110-rpi-venus).
#
#   ../scripts/prepare-kernel.sh   once: prepares ../kernel-src
#   make                           modules + overlays into out/
#   make dist                      release tarball into ../dist/
#   make clean

KDIR          ?= $(CURDIR)/../kernel-src
ARCH          ?= arm
CROSS_COMPILE ?= arm-linux-gnueabihf-
KMAKE          = $(MAKE) -C $(KDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE)

DTC           := $(KDIR)/scripts/dtc/dtc
DTC_CPP_FLAGS := -nostdinc -I$(KDIR)/include -I$(KDIR)/arch/arm/boot/dts/include \
                 -undef -D__DTS__ -x assembler-with-cpp
OVERLAYS      := vc4-kms-dsi-waveshare-panel-v2

DEPLOY        := $(CURDIR)/../deploy
DISTDIR       := $(CURDIR)/../dist
PKG           := venus-os-waveshare-dsi
KREL           = $(shell cat $(KDIR)/include/config/kernel.release 2>/dev/null)

.PHONY: all modules overlays dist clean
all: modules overlays out/fbrotate

# userspace helper: mirrors the landscape framebuffer onto the portrait panel
out/fbrotate: ../fbrotate/fbrotate.c
	mkdir -p out
	$(CROSS_COMPILE)gcc -O2 -Wall -Wextra -static -s -o $@ $<

modules:
	$(KMAKE) M=$(CURDIR) modules
	mkdir -p out && cp *.ko out/

overlays: $(OVERLAYS:%=out/%.dtbo) out/vc4-kms-v3d-pi4.dtbo

out/%.dtbo: dts/%-overlay.dts
	mkdir -p out
	$(CROSS_COMPILE)cpp $(DTC_CPP_FLAGS) $< -o out/$*.pp.dts
	$(DTC) -@ -H epapr -I dts -O dtb -b 0 -Wno-unit_address_vs_reg -o $@ out/$*.pp.dts
	rm -f out/$*.pp.dts

# The KMS overlay is not shipped in the Venus Pi 4 image; build it from the 5.10 tree
out/vc4-kms-v3d-pi4.dtbo:
	mkdir -p out
	$(KMAKE) overlays/vc4-kms-v3d-pi4.dtbo
	cp $(KDIR)/arch/arm/boot/dts/overlays/vc4-kms-v3d-pi4.dtbo $@

dist: all
	rm -rf $(DISTDIR)/$(PKG)
	mkdir -p $(DISTDIR)/$(PKG)/waveshare-display
	cp $(DEPLOY)/install.sh $(DEPLOY)/uninstall.sh $(DISTDIR)/$(PKG)/
	cp $(DEPLOY)/waveshare-display/* out/*.ko out/*.dtbo out/fbrotate $(DISTDIR)/$(PKG)/waveshare-display/
	tar -C $(DISTDIR) --owner=0 --group=0 -czf $(DISTDIR)/$(PKG)-rpi4-$(KREL).tar.gz $(PKG)
	@echo "==> $(DISTDIR)/$(PKG)-rpi4-$(KREL).tar.gz"

clean:
	$(KMAKE) M=$(CURDIR) clean
	rm -rf out
