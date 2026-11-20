# Debian on the NXP FRDM-IMX8MPLUS

This repository provides a device tree and a U-Boot script for running Debian 13 (trixie)
on the [NXP FRDM-IMX8MPLUS](https://www.nxp.com/design/design-center/development-boards-and-designs/FRDM-IMX8MPLUS)
(NXP i.MX 8M Plus), with Debian's own kernel, and the steps to install them. With them the
board's Ethernet PTP clock works with two pins on the J18 expansion header: one timestamps a
pulse-per-second (PPS) signal in hardware, the other generates a periodic output. Everything
else is Debian's, so a running board is updated as any Debian system is.

The motivating use is precise timing. The board's Ethernet PTP clock (PHC) can timestamp a
PPS signal in hardware, so the FRDM-IMX8MPLUS can serve as a PTP grandmaster with
[SatPulse](https://satpulse.net/).

The bring-up, and this repository documenting it, were done using Claude Opus 5.5 under my
supervision.

## What is in the repository

- `imx8mp-frdm.dtb`: the mainline device tree for the board, built from Debian's
  `linux-source-7.3` with overlay support (`-@`), and with one change for Debian's kernel
  (see [Why it is done this way](#why-it-is-done-this-way)).
- `imx8mp-frdm-eqos-ptp.dtbo`: the overlay that connects the PTP event pins. I have
  [submitted it upstream](https://lore.kernel.org/all/20261119062301.1778558-1-jjc@jclark.com/);
  `imx8mp-frdm-eqos-ptp.dtso` is its source, exactly as sent.
- `imx8mp-frdm-eqos-ptp-200mhz.dtbo`: an optional overlay that runs the PTP clock at 200 MHz
  instead of 100 MHz (see [The 200 MHz overlay](#the-200-mhz-overlay)). Its source is
  `imx8mp-frdm-eqos-ptp-200mhz.dtso`.
- `boot.scr`: the U-Boot script that boots Debian, built from `boot.cmd`.
- `build-dt.sh`: rebuilds the `.dtb` and `.dtbo` files from a kernel source tree.

## Installing

You need the board with NXP's factory image on its eMMC, a microSD card, a network connection
to the board's Ethernet port, and the serial console (USB-C connector J19; the
first of its two serial ports, at 115200). The eMMC is not changed: NXP's U-Boot on the eMMC
boots the card when one is present, and NXP's Linux when it is not.

Boot the board without a card and log in on the console as `root` (no password). Insert the
card. The commands below assume it appears as `/dev/mmcblk1`; check with `lsblk`, because
everything on it is lost. NXP's image mounts any filesystem on the card automatically, so
unmount it first:

```
umount /run/media/*mmcblk1* 2>/dev/null
curl -sSfL https://cloud.debian.org/images/cloud/trixie/latest/debian-13-nocloud-arm64.tar.xz \
  | tar -xOJ disk.raw | dd of=/dev/mmcblk1 bs=4M conv=fsync
sfdisk --part-attrs /dev/mmcblk1 1 LegacyBIOSBootable
```

This writes Debian's `nocloud` image to the card and marks its root partition bootable, so
that U-Boot looks there for a boot script.

Mount the card and change root into it:

```
R=/mnt/debian; mkdir -p $R
mount /dev/mmcblk1p1 $R; mount /dev/mmcblk1p15 $R/boot/efi
for d in dev dev/pts proc sys; do mount --bind /$d $R/$d; done
mv $R/etc/resolv.conf $R/etc/resolv.conf.link; cp /etc/resolv.conf $R/etc/resolv.conf
chroot $R
```

Inside the chroot, install a kernel from trixie-backports (7.3 at the time of writing,
2026-11), `openssh-server` and the device tree tools:

```
printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: trixie-backports\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
  > /etc/apt/sources.list.d/backports.sources
apt update
apt install -t trixie-backports linux-image-arm64
apt install device-tree-compiler openssh-server
printf 'do_symlinks = yes\nlink_in_boot = yes\n' > /etc/kernel-img.conf
v=$(ls /usr/lib/modules | sort -V | tail -n 1)
linux-update-symlinks install $v /boot/vmlinuz-$v
```

The `kernel-img.conf` setting makes `/boot/vmlinuz` and `/boot/initrd.img` symlinks to the
newest kernel, now and at every kernel upgrade, so the boot script always finds it.

Fetch the files from this repository and combine the device tree with the PTP overlay:

```
cd /boot
G=https://raw.githubusercontent.com/jclark/frdm-imx8mplus-debian/main
curl -sSfO $G/boot.scr
mkdir -p frdm; cd frdm
curl -sSfO $G/imx8mp-frdm.dtb -O $G/imx8mp-frdm-eqos-ptp.dtbo -O $G/imx8mp-frdm-eqos-ptp-200mhz.dtbo
fdtoverlay -i imx8mp-frdm.dtb -o /boot/frdm-imx8mplus.dtb imx8mp-frdm-eqos-ptp.dtbo
```

The boot script loads `/boot/frdm-imx8mplus.dtb`. To use the 200 MHz PTP clock, add
`imx8mp-frdm-eqos-ptp-200mhz.dtbo` to the end of the `fdtoverlay` command.

Then stop U-Boot from trying the image's UEFI boot loader, which does not work with NXP's
firmware, and deal with the image's first-boot setup:

```
mv /boot/efi/EFI/BOOT/BOOTAA64.EFI /boot/efi/EFI/BOOT/BOOTAA64.EFI.off
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
systemctl mask systemd-firstboot.service
mkdir -p -m 700 /root/.ssh; cat > /root/.ssh/authorized_keys
```

The last command reads your ssh public key: paste it, then type Ctrl-D. Without the mask,
`systemd-firstboot` stops the first boot to ask on the console for a locale, keymap, time
zone and root password. The image's root password is locked, so logging in is by ssh key
only, as `root`.

Leave the chroot, put back `resolv.conf`, unmount and reboot:

```
exit
mv $R/etc/resolv.conf.link $R/etc/resolv.conf
umount -R $R
reboot
```

The board boots Debian from the card and gets its address by DHCP on both Ethernet ports.

## The PTP pins

The overlay connects two pins of J18 to event channel 0 of the EQOS controller, which is
`end1` under Debian (`eth1` on NXP's image), and its PHC:

- pin 13 (GPIO1_IO08): external timestamp input, EXTTS channel 0
- pin 28 (GPIO1_IO09): periodic output, PEROUT channel 0

The PHC has no programmable pins (`n_pins` is 0): the channels are fixed to these pads by
the overlay. UART3 is on pins 8 (TX) and 10 (RX) as `/dev/ttymxc2`, with no overlay needed.

For SatPulse, with a receiver's serial port on UART3 and its PPS on pin 13, the
configuration in `/etc/satpulse.d/ttymxc2.toml` is along these lines:

```
[serial]
speed = 115200

[gps]
config = true

[phc]
interface = "end1"
channel = 0
```

There is no `pin` key, because the PHC has no pins. Run it with
`systemctl enable --now satpulse@ttymxc2`.

## The 200 MHz overlay

The stmmac driver steps the PHC by two periods of its reference clock, and the mainline
device tree runs that clock at 100 MHz, so timestamps come in steps of 20 ns. The clock can
run at up to 200 MHz, which halves the step to 10 ns. The overlay does this by setting
`VIDEO_PLL1` to 1200 MHz and taking the PTP clock from it, divided by 6.

On my board, with a GNSS receiver's PPS on pin 13, SatPulse's PHC offset RMS was 10.7 ns at
100 MHz (over about 7 minutes) and 6.9 ns at 200 MHz (over 11.6 hours). These are SatPulse's own figures, not
an independent measurement, and they were taken with my own build of a 7.3 kernel, not Debian's.

`VIDEO_PLL1` is the pixel clock source for an LVDS or MIPI-DSI panel, so the overlay is not
for a board driving one. The mainline device tree enables neither.

## Why it is done this way

NXP's U-Boot fails to initialize UEFI ("Unable to open OP-TEE session"), so the standard
UEFI boot of Debian's images does not work. Instead, U-Boot's standard boot finds `boot.scr`
on the card and runs it. It looks only in partitions marked bootable; in a GPT, the EFI
system partition counts as bootable, but Debian's root partition does not until it is given
the LegacyBIOSBootable attribute.

Debian's arm64 kernel is an uncompressed Image of about 48 MB, and NXP's default load
addresses leave room for only 44 MB before the device tree. `boot.scr` moves the kernel,
device tree and initrd higher, staying below the memory OP-TEE uses at 0x56000000. It finds
the root partition with `part uuid`, so it does not depend on the card's partition IDs.

Debian's kernel is built without `CONFIG_INTERCONNECT_IMX8MP`. Four block controllers in the
device tree (for USB, PCIe and HDMI) name interconnects and wait for ever for a driver that
never comes, so without a fix USB, PCIe and HDMI do not work. `imx8mp-frdm.dtb` deletes their
`interconnects` and `interconnect-names` properties; the block controller driver then runs
without interconnects. This is the only difference from the mainline device tree.

The mainline `imx8mp-frdm.dts` first appeared in Linux 7.0. Mainline does not build it with
overlay support yet, so Debian's own copy cannot take overlays; `imx8mp-frdm.dtb` here is
built with it.

## Known limits

- Debian's 7.3 kernel lacks
  [the stmmac support for `PTP_SYS_OFFSET_EXTENDED`](https://lore.kernel.org/all/20261008103809.1848255-1-jjc@jclark.com/),
  which comes in 7.4. Without it SatPulse 0.3 synchronizes the PHC but cannot send samples
  to chrony. SatPulse 0.4, in development at the time of writing,
  [falls back to `PTP_SYS_OFFSET`](https://github.com/jclark/satpulse/issues/547), which
  this kernel supports.
- linuxptp's `ts2phc` needs
  [the stmmac fix for the `PTP_EXTTS_REQUEST2` ioctl](https://lore.kernel.org/all/20261104052504.1886335-1-jjc@jclark.com/),
  which will be in 7.4; Debian's 7.3 kernel does not have it. SatPulse works without it.
- The device tree is built from 7.3 sources. Device trees are meant to keep working with
  later kernels, but I have not yet tried it with one.

## Rebuilding the device tree

`build-dt.sh` rebuilds the `.dtb` and `.dtbo` files from a kernel source tree (it needs `cpp`
and `dtc`), for example Debian's `linux-source-7.3` unpacked:

```
tar -xf /usr/src/linux-source-7.3.tar.xz
./build-dt.sh linux-source-7.3
```

The files here were built from Debian's `linux-source-7.3` (7.3.4). The `fdtput` step in
the script is the interconnect fix described above.

## Licence

The files written for this repository are under the MIT licence ([LICENSE](LICENSE)), except
where a file says otherwise. The device tree files are dual-licensed GPL or MIT, as their SPDX headers say;
`imx8mp-frdm.dtb` follows `imx8mp-frdm.dts` (GPL-2.0+ OR MIT).
