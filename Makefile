# Build the device tree and overlays from an unpacked kernel source tree:
#   make KERNEL=linux-source-7.3
# Needs cpp, dtc and fdtput (Debian: cpp, device-tree-compiler).

ifndef KERNEL
$(error set KERNEL to the kernel source tree)
endif

CPP = cpp
DTC = dtc
FDTPUT = fdtput

DTS = $(KERNEL)/arch/arm64/boot/dts/freescale
DTCPP = $(CPP) -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
	-I $(DTS) -I $(KERNEL)/scripts/dtc/include-prefixes

# Debian's kernel lacks CONFIG_INTERCONNECT_IMX8MP, and USB does not work
# unless the interconnect references of these block controllers are removed.
BLK_CTRLS = /soc@0/bus@32c00000/blk-ctrl@32ec0000 /soc@0/bus@32c00000/blk-ctrl@32f10000 \
	/soc@0/bus@32c00000/blk-ctrl@32fc0000 /soc@0/blk-ctrl@38330000

OVERLAYS = imx8mp-frdm-eqos-ptp.dtbo imx8mp-frdm-eqos-ptp-200mhz.dtbo

all: imx8mp-frdm.dtb $(OVERLAYS)

imx8mp-frdm.dtb:
	$(DTCPP) $(DTS)/imx8mp-frdm.dts | $(DTC) -q -@ -I dts -O dtb -o $@.tmp -
	for n in $(BLK_CTRLS); do $(FDTPUT) -d $@.tmp $$n interconnects interconnect-names || exit 1; done
	mv $@.tmp $@

$(OVERLAYS):
	$(DTCPP) $(@:.dtbo=.dtso) | $(DTC) -q -@ -I dts -O dtb -o $@ -

.PHONY: all imx8mp-frdm.dtb $(OVERLAYS)
