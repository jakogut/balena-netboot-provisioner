# Netboot

## Setup

### Raspberry Pi 4

The Pi 4 has netboot capability built into the bootloader that's flashed into the EEPROM. Unfortunately, as of this writing, the bootloader defaults to booting from the SD card, falling back to USB booting, and will not attempt to boot from the network.

In order to change this, we can use [rpi-imager](https://github.com/raspberrypi/rpi-imager). From the `Choose OS` menu, select `Misc utility images/Bootloader/Network Boot`. Choose an empty SD card to flash, and wait for the process to finish. Insert the flashed card into the Pi 4 and power it on. The green light will be solid until the process has finished, then will blink rapidly when the device can be powered off again.

### Fin (CM3+ Lite)

The Fin with the CM3+ Lite requires a single firmware file on the boot partition contained on the eMMC in order to network boot. To start, leave the power disconnected, and connect the Fin to your PC using a micro USB cable to the debug port, next to the power jack. Use the [usbboot](https://github.com/raspberrypi/usbboot) tool to boot your Fin in OTG device mode, exposing the onboard eMMC as a mass storage device.

```
$ sudo ./rpiboot
RPIBOOT: build-date Mar 25 2022 version 20220315~121405 1e27dd85
Waiting for BCM2835/6/7/2711...
Loading embedded: bootcode.bin
Sending bootcode.bin
Successful read 4 bytes
Waiting for BCM2835/6/7/2711...
Loading embedded: bootcode.bin
Loading embedded: bootcode.bin
Second stage boot server
Loading embedded: start.elf
File read: start.elf
Second stage boot server done
```

After the tool finishes, you should see the eMMC exposed as an 8 GB block device.

```
$ lsblk
<snip>
sdX           8:48   1  7.3G  0 disk
```

Repartition this device using fdisk, replacing `/dev/sdX` with the path to your block device.

`fdisk /dev/sdX`

At the prompt:
* Type `o` to create a new MBR partition table
* Type `n` then `p` for primary, `1` for the first partition on the drive, press ENTER to accept the default first sector, then type `+200M` for the last sector.
* Type `t`, then `c` to set the first partition to type `W95 FAT32 (LBA)`
* Type `w` to write the partition table and exit

Create and mount the filesystem for the boot partition:
```
$ mkfs.vfat /dev/sdX1
$ mkdir /mnt/boot
$ mount /dev/sdX1 /mnt/boot
```

Download `bootcode.bin` and write it to the boot partition:
```
$ curl -L \
https://github.com/raspberrypi/firmware/raw/master/boot/bootcode.bin \
    | sudo tee /mnt/boot/bootcode.bin > /dev/null
```

Sync, unmount the boot partition, and unplug your Fin.
```
$ sync && sudo umount /mnt/boot
```

(Special thanks to the wonderful [Arch Linux ARM](https://archlinuxarm.org)) project for the installation [instructions](https://archlinuxarm.org/platforms/armv8/broadcom/raspberry-pi-3) the above section is based on.)
