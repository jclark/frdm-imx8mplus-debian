#!/bin/sh
# Build imx8mp-frdm.dtb and the overlays from a kernel source tree.
# Usage: build-dt.sh <kernel-source> [<output-dir>]
# Needs cpp, dtc, fdtput (Debian: cpp, device-tree-compiler).
set -e
K=$1
O=${2:-.}
D=$K/arch/arm64/boot/dts/freescale
H=$(dirname "$0")
pp() {
	cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$D" -I "$K/scripts/dtc/include-prefixes" "$1"
}
pp "$D/imx8mp-frdm.dts" | dtc -q -@ -I dts -O dtb -o "$O/imx8mp-frdm.dtb" -
# Debian's kernel is built without CONFIG_INTERCONNECT_IMX8MP, so these block
# controllers would wait for ever for their interconnects; without the
# property they probe without them.
for n in /soc@0/bus@32c00000/blk-ctrl@32ec0000 /soc@0/bus@32c00000/blk-ctrl@32f10000 \
	/soc@0/bus@32c00000/blk-ctrl@32fc0000 /soc@0/blk-ctrl@38330000; do
	fdtput -d "$O/imx8mp-frdm.dtb" $n interconnects interconnect-names
done
for s in imx8mp-frdm-eqos-ptp imx8mp-frdm-eqos-ptp-200mhz; do
	pp "$H/$s.dtso" | dtc -q -@ -I dts -O dtb -o "$O/$s.dtbo" -
done
