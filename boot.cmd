# U-Boot script for Debian on the FRDM-IMX8MPLUS.
# Build with: mkimage -A arm64 -T script -C none -d boot.cmd boot.scr
# NXP's default kernel_addr_r leaves 44 MB for the kernel, too little for
# Debian's uncompressed Image; these addresses stay below OP-TEE at 0x56000000.
setenv kernel_addr_r 0x48000000
setenv fdt_addr_r 0x4c000000
setenv ramdisk_addr_r 0x4c400000
part uuid ${devtype} ${devnum}:${distro_bootpart} rootuuid
setenv bootargs console=ttymxc1,115200 root=PARTUUID=${rootuuid} ro rootwait
load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} /boot/vmlinuz && load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} /boot/frdm-imx8mplus.dtb && load ${devtype} ${devnum}:${distro_bootpart} ${ramdisk_addr_r} /boot/initrd.img && booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
