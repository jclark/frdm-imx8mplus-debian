# Debian on the NXP FRDM-IMX8MPLUS

This repository provides a device tree and a U-Boot script for running Debian 13 (trixie)
on the [NXP FRDM-IMX8MPLUS](https://www.nxp.com/design/design-center/development-boards-and-designs/FRDM-IMX8MPLUS)
(NXP i.MX 8M Plus), with Debian's own kernel, and the steps to install them. With them the
board's Ethernet PTP clock works with two pins on the 40-pin header: one timestamps a
pulse-per-second (PPS) signal in hardware, the other generates a periodic output. Everything
else is Debian's, so a running board is updated as any Debian system is.

The motivating use is precise timing. The board's Ethernet PTP clock (PHC) can timestamp a
PPS signal in hardware, so the FRDM-IMX8MPLUS can serve as a PTP grandmaster with
[SatPulse](https://satpulse.net/).

The bring-up, and this repository documenting it, were done using Claude Opus 5.5 under my
supervision.

## What is in the repository

- `imx8mp-frdm.dtb`: the mainline device tree for the board, built from Debian's
  `linux-source-7.3` so that overlays can be applied to it, with
  [one change for Debian's kernel](#why-it-is-done-this-way).
- `imx8mp-frdm-eqos-ptp.dtbo`: the overlay that connects the PTP event pins.
  `imx8mp-frdm-eqos-ptp.dtso` is its source, exactly as I
  [submitted it upstream](https://lore.kernel.org/all/20261119062301.1778558-1-jjc@jclark.com/).
- `imx8mp-frdm-eqos-ptp-200mhz.dtbo`: an optional overlay that
  [runs the PTP clock at 200 MHz](#the-200-mhz-overlay) instead of 100 MHz. Its source is
  `imx8mp-frdm-eqos-ptp-200mhz.dtso`.
- `boot.scr`: the U-Boot script that boots Debian, built from `boot.cmd`.
- `build-dt.sh`: rebuilds the `.dtb` and `.dtbo` files from a kernel source tree.

## Installing

You need the board with NXP's factory image on its eMMC, a microSD card, a network connection
to the board's Ethernet port, and the serial console. The console is the first of the two
serial ports on USB-C connector J19, at 115200 baud. Nothing on the eMMC is changed. NXP's
U-Boot on the eMMC boots Debian from the card when the card is in, and NXP's Linux when it
is not.

Boot the board without a card and log in on the console as `root`, with no password. Insert
the card and check with `lsblk` that it is `/dev/mmcblk1`, as the commands below assume.
Everything on the card will be lost. NXP's image mounts the card automatically, so the first
command unmounts it:

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

With the `kernel-img.conf` setting, `/boot/vmlinuz` and `/boot/initrd.img` always point to
the newest kernel, including after upgrades. The boot script loads those.

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

Then turn off the image's UEFI boot loader and its first-boot setup, and add your ssh key:

```
mv /boot/efi/EFI/BOOT/BOOTAA64.EFI /boot/efi/EFI/BOOT/BOOTAA64.EFI.off
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
systemctl mask systemd-firstboot.service
mkdir -p -m 700 /root/.ssh; cat > /root/.ssh/authorized_keys
```

For the last command, paste your ssh public key, then type Ctrl-D. Without the mask,
`systemd-firstboot` stops the first boot to ask on the console for a locale, keymap, time
zone and root password. The root password stays locked, so you log in as `root` with your
ssh key.

Leave the chroot, put back `resolv.conf`, unmount and reboot:

```
exit
mv $R/etc/resolv.conf.link $R/etc/resolv.conf
umount -R $R
reboot
```

The board boots Debian from the card and gets its address by DHCP on both Ethernet ports.

## The PTP pins

The overlay connects two pins of the 40-pin header to event channel 0 of the PHC of the
EQOS Ethernet controller, `end1` under Debian:

- pin 13 (GPIO1_IO08): external timestamp input, EXTTS channel 0
- pin 28 (GPIO1_IO09): periodic output, PEROUT channel 0

The overlay fixes the channels to these pins. The PHC has no programmable pins. UART3 is on
pins 8 (TX) and 10 (RX) and appears as `/dev/ttymxc2`; it needs no overlay.

For SatPulse, with a receiver's serial port on UART3 and its PPS on pin 13, the
configuration in `/etc/satpulse.toml` is along these lines:

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

The overlay runs the PHC's reference clock at 200 MHz instead of the 100 MHz of the mainline
device tree. The stmmac driver steps the PHC by two periods of this clock, so the step goes
from 20 ns to 10 ns.

On my board, with a GNSS receiver's PPS on pin 13, SatPulse's PHC offset RMS was 10.7 ns at
100 MHz (over about 7 minutes) and 6.9 ns at 200 MHz (over 11.6 hours).

The overlay cannot be used with an LVDS or MIPI-DSI panel.

## Why it is done this way

The board boots Debian with a U-Boot script, `boot.scr`, rather than UEFI, because the NXP
U-Boot's UEFI support does not work. The root partition is given the LegacyBIOSBootable
attribute, because U-Boot looks for the script only in bootable partitions.

`boot.scr` loads the kernel higher in memory than NXP's default addresses, because Debian's
kernel is about 50 MB and does not fit below the default address of the device tree.
It sets the root partition to the one it was loaded from.

The `imx8mp-frdm.dtb` here removes the interconnect references from the mainline device
tree. Debian's kernel lacks the i.MX 8M Plus interconnect driver
(`CONFIG_INTERCONNECT_IMX8MP`), and without this change USB does not work.

The `imx8mp-frdm.dtb` in this repository is compiled in a way that allows overlays to be
applied to it. The one in mainline and in Debian is not.

## Known limits

- SatPulse 0.3 synchronizes the PHC with Debian's 7.3 kernel but cannot send samples to
  chrony, because the kernel lacks
  [the stmmac support for `PTP_SYS_OFFSET_EXTENDED`](https://lore.kernel.org/all/20261008103809.1848255-1-jjc@jclark.com/),
  which comes in 7.4. The master branch of SatPulse has
  [a fix for this](https://github.com/jclark/satpulse/pull/548).
- `ts2phc` from linuxptp needs
  [a stmmac fix for the `PTP_EXTTS_REQUEST2` ioctl](https://lore.kernel.org/all/20261104052504.1886335-1-jjc@jclark.com/),
  which will be in 7.4 and is not in Debian's 7.3 kernel. SatPulse does not need it.
- The device tree is built from 7.3 sources. I have not yet tried it with a later kernel.

## Rebuilding the device tree

`build-dt.sh` rebuilds the `.dtb` and `.dtbo` files from a kernel source tree, such as
Debian's `linux-source-7.3` unpacked. It needs `cpp` and `dtc`.

```
tar -xf /usr/src/linux-source-7.3.tar.xz
./build-dt.sh linux-source-7.3
```

The files here were built from version 7.3.4 of Debian's `linux-source-7.3`. The `fdtput`
step in the script removes the interconnect references.

## Licence

The files written for this repository are under the MIT licence ([LICENSE](LICENSE)), except
where a file says otherwise. The `.dtso`, `.dtbo` and `.dtb` files are under GPL-2.0+ OR
MIT, the licence of the kernel's `imx8mp-frdm.dts`.
