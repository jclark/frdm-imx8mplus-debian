# Debian on the NXP FRDM-IMX8MPLUS

This repository provides a device tree and a U-Boot script for running Debian 13 (trixie)
on the [NXP FRDM-IMX8MPLUS](https://www.nxp.com/design/design-center/development-boards-and-designs/FRDM-IMX8MPLUS)
(NXP i.MX 8M Plus), with Debian's own kernel, and the steps to install them. With them the
board's Ethernet PTP clock works with two pins on the 40-pin header: one timestamps a
pulse-per-second (PPS) signal in hardware, the other generates a periodic output. Everything
else is Debian's, so a running board is updated as any Debian system is.

The motivating use is precise timing. The board's Ethernet PTP clock (PHC) can timestamp a
PPS signal in hardware, so the FRDM-IMX8MPLUS can serve as a PTP grandmaster with
[SatPulse](https://satpulse.net/), or as an NTP server with chrony.

The bring-up, and this repository documenting it, were done using Claude Opus 5.5 under my
supervision.

## Files

- `imx8mp-frdm.dtb`: the mainline device tree for the board, built from Debian's
  `linux-source-7.3` so that overlays can be applied to it, with
  [one change for Debian's kernel](#how-it-works).
- `imx8mp-frdm-eqos-ptp.dtbo`: the overlay that connects the PTP event pins.
  `imx8mp-frdm-eqos-ptp.dtso` is its source, exactly as I
  [submitted it upstream](https://lore.kernel.org/all/20261119062301.1778558-1-jjc@jclark.com/).
- `imx8mp-frdm-eqos-ptp-200mhz.dtbo`: an optional overlay that
  [runs the PTP clock at 200 MHz](#200-mhz-ptp-clock) instead of 100 MHz. Its source is
  `imx8mp-frdm-eqos-ptp-200mhz.dtso`.
- `boot.scr`: the U-Boot script that boots Debian, built from `boot.cmd`.
- `Makefile`: builds the `.dtb` and `.dtbo` files from a kernel source tree.

## Installation

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
  | tar -xOJ disk.raw | dd of=/dev/mmcblk1 bs=4M conv=fsync status=progress
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

Then turn off the image's UEFI boot loader and its first-boot setup, set a root password and
add your ssh key:

```
mv /boot/efi/EFI/BOOT/BOOTAA64.EFI /boot/efi/EFI/BOOT/BOOTAA64.EFI.off
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
systemctl mask systemd-firstboot.service
passwd
mkdir -p -m 700 /root/.ssh; cat > /root/.ssh/authorized_keys
```

Without the mask, `systemd-firstboot` stops the first boot to ask on the console for a
locale, keymap, time zone and root password. `passwd` sets the root password, for logging in
on the console. For the last command, paste your ssh public key, then type Ctrl-D.

Leave the chroot, put back `resolv.conf`, unmount and reboot:

```
exit
mv $R/etc/resolv.conf.link $R/etc/resolv.conf
umount -R $R
reboot
```

The board boots Debian from the card and gets its address by DHCP on both Ethernet ports.
To find the address, log in on the console as `root` and run `ip -br addr`. The console is
also the way in if ssh does not work.

## Overlays

### PTP pins

`imx8mp-frdm-eqos-ptp.dtbo` connects two pins of the 40-pin header to event channel 0 of the
PHC of the EQOS Ethernet controller:

- pin 13 (GPIO1_IO08): external timestamp input, EXTTS channel 0
- pin 28 (GPIO1_IO09): periodic output, PEROUT channel 0

The PHC has no programmable pins, so the overlay fixes the channels to these pins. The EQOS
controller is `end1` under Debian. Its Ethernet port is the one next to the USB Type-A port.

### 200 MHz PTP clock

`imx8mp-frdm-eqos-ptp-200mhz.dtbo` runs the PHC's reference clock at 200 MHz instead of the
100 MHz of the mainline device tree. The stmmac driver steps the PHC by two periods of this
clock, so the step goes from 20 ns to 10 ns.

On my board, with a GNSS receiver's PPS on pin 13, SatPulse's PHC offset RMS was 10.7 ns at
100 MHz (over about 7 minutes) and 6.9 ns at 200 MHz (over 11.6 hours).

The overlay cannot be used with an LVDS or MIPI-DSI panel.

## Using with a GNSS receiver

Connect the receiver to the 40-pin header:

| Receiver | Header pin | Pin name | Function |
|---|---|---|---|
| PPS output | 13 | GPIO1_IO08 | EXTTS channel 0 |
| Serial TX | 10 | UART3_RXD | UART3 receive |
| Serial RX | 8 | UART3_TXD | UART3 transmit |
| Power, 5 V | 2 | VDD_5V | 5 V supply |
| Ground | 14 | GND | Ground |

UART3 is `/dev/ttymxc2` and needs no overlay.

### SatPulse

For SatPulse, the configuration in `/etc/satpulse.toml` is along these lines:

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
`systemctl enable --now satpulse@ttymxc2`. The SatPulse site covers
[installing SatPulse](https://satpulse.net/setup/satpulse-install.html) and
[setting up chrony and ptp4l](https://satpulse.net/setup/phc.html) with a PHC.

### NTP server with chrony and gpsd

chrony can take the PPS timestamps directly from the PHC, with gpsd giving it the time of
day from the receiver's NMEA output. 

Install chrony and gpsd:

```
apt install chrony gpsd
```

In `/etc/default/gpsd`, set:

```
DEVICES="/dev/ttymxc2"
GPSD_OPTIONS="-n"
```

Debian's AppArmor profile for gpsd does not allow `/dev/ttymxc*`. Allow it, and the
socket gpsd uses to send chrony the time of day:

```
cat >> /etc/apparmor.d/local/usr.sbin.gpsd <<'EOF'
/dev/ttymxc[0-9]* rw,
/run/chrony.clk.ttymxc[0-9]*.sock rw,
EOF
apparmor_parser -r /etc/apparmor.d/usr.sbin.gpsd
```

Put this in `/etc/chrony/conf.d/gnss.conf`:

```
refclock SOCK /run/chrony.clk.ttymxc2.sock refid NMEA noselect
refclock PHC /dev/ptp1:extpps:pin=-1 refid PPS lock NMEA
allow
```

The `NMEA` refclock is the time of day from gpsd. The `PPS` refclock timestamps the PPS on
the PHC of `end1` (`/dev/ptp1`), with `pin=-1` because the PHC has no programmable pins, and
takes the second from `NMEA`. `allow` lets any client use the server. Restart chrony and then
gpsd, which connects to chrony's socket when it starts:

```
systemctl restart chrony
systemctl restart gpsd
```

After a minute or so, `chronyc sources` shows `PPS` selected.

## How it works

The board boots Debian with a U-Boot script, `boot.scr`, rather than UEFI, because the NXP
U-Boot's UEFI support does not work. The root partition is given the LegacyBIOSBootable
attribute, because U-Boot looks for the script only in bootable partitions. The script loads
the kernel higher in memory than NXP's default addresses, because Debian's kernel is about
50 MB and does not fit below the default address of the device tree. It sets the root
partition to the one it was loaded from.

The `imx8mp-frdm.dtb` here removes the interconnect references from the mainline device
tree, because Debian's kernel lacks the i.MX 8M Plus interconnect driver
(`CONFIG_INTERCONNECT_IMX8MP`) and USB does not work without this change. It is
compiled in a way that allows overlays to be applied to it, unlike the one in mainline and
in Debian.

## Limitations

- SatPulse 0.3 synchronizes the PHC with Debian's 7.3 kernel but cannot send samples to
  chrony, because the kernel lacks
  [the stmmac support for `PTP_SYS_OFFSET_EXTENDED`](https://lore.kernel.org/all/20261008103809.1848255-1-jjc@jclark.com/),
  which comes in 7.4. The master branch of SatPulse has
  [a fix for this](https://github.com/jclark/satpulse/pull/548).
- `ts2phc` from linuxptp needs
  [a stmmac fix for the `PTP_EXTTS_REQUEST2` ioctl](https://lore.kernel.org/all/20261104052504.1886335-1-jjc@jclark.com/),
  which will be in 7.4 and is not in Debian's 7.3 kernel. SatPulse does not need it.
- The device tree is built from 7.3 sources. I have not yet tried it with a later kernel.

## Building the device tree

`imx8mp-frdm.dtb` is `imx8mp-frdm.dts` from version 7.3.4 of Debian's `linux-source-7.3`,
compiled with `dtc -@`, with the interconnect references removed. The `.dtbo` files are
compiled from the `.dtso` files here. The `Makefile` does this, given an unpacked kernel
source tree:

```
make KERNEL=linux-source-7.3
```

## Licence

The files written for this repository are under the MIT licence ([LICENSE](LICENSE)), except
where a file says otherwise. The `.dtso`, `.dtbo` and `.dtb` files are under GPL-2.0+ OR
MIT, the licence of the kernel's `imx8mp-frdm.dts`.
