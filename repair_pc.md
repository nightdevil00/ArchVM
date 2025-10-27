# PC Repair Guide: Reinstalling Kernel and Bootloader with arch-chroot (BTRFS + LUKS2)

This guide will walk you through the process of using `arch-chroot` to reinstall the Linux kernel, headers, and the Limine bootloader on a system with BTRFS on LUKS2 encryption. This is a common procedure to fix a broken Arch Linux installation that fails to boot.

## Prerequisites

*   A bootable Arch Linux USB drive.
*   An internet connection.
*   Basic knowledge of the Linux command line.

## 1. Boot from Live USB

First, boot your computer from the Arch Linux live USB. You may need to change the boot order in your BIOS/UEFI settings.

## 2. Identify and Mount Partitions

Once you are in the live environment, you need to identify and mount the partitions of your broken system.

*   Use `lsblk` or `fdisk -l` to list the available partitions.
*   Identify your encrypted LUKS2 partition (e.g., `/dev/sda2`) and your EFI System Partition (ESP) (e.g., `/dev/sda1`).

### Open the LUKS2 Container

Use `cryptsetup` to open the encrypted container:

```bash
cryptsetup open /dev/sdXn root
```

Replace `/dev/sdXn` with your LUKS2 partition. You will be prompted for your encryption password. The decrypted device will be available at `/dev/mapper/root`.

### Mount the BTRFS Subvolumes

Now, mount the BTRFS subvolumes. You may need to identify the correct subvolume names. A common convention is to use `@` for the root subvolume and `@home` for the home subvolume.

```bash
mount -o subvol=@ /dev/mapper/root /mnt
mount -o subvol=@home /dev/mapper/root /mnt/home
mount /dev/sdXn /mnt/boot
```

**Note:** 
*   Replace `/dev/sdXn` with your ESP partition.
*   If you have other BTRFS subvolumes, mount them accordingly.

## 3. Use arch-chroot

Next, use `arch-chroot` to enter your broken system:

```bash
arch-chroot /mnt
```

This will change the root directory to `/mnt` and give you access to your system's files and programs.

## 4. Reinstall Kernel, Headers, and Limine

Now, you can reinstall the necessary packages using `pacman`:

```bash

```

This will download and reinstall the latest Linux kernel, headers, and the Limine bootloader.

### Regenerate Initramfs

After reinstalling the kernel, it is crucial to regenerate the initramfs to include the necessary hooks for BTRFS and LUKS2.

```bash
mkinitcpio -P
```

## 5. Configure Limine

After the installation is complete, you need to configure Limine.

First, run the Limine deploy command:

```bash
limine-deploy
```

Then, you need to create a `limine.cfg` file in your `/boot` directory. Here is a sample configuration:

```
TIMEOUT=5
DEFAULT_ENTRY=arch

:arch
PROTOCOL=linux
KERNEL_PATH=boot/vmlinuz-linux
CMDLINE=cryptdevice=UUID=<UUID_of_LUKS_partition>:root root=/dev/mapper/root rw
INITRD_PATH=boot/initramfs-linux.img
```

**Important:**

*   Replace `<UUID_of_LUKS_partition>` with the actual UUID of your LUKS2 partition. You can find the UUID with the command `lsblk -f`.
*   Make sure the `KERNEL_PATH` and `INITRD_PATH` are correct.

## 6. Exit and Reboot

Finally, exit the chroot environment and reboot your computer:

```bash
exit
umount -R /mnt
cryptsetup close root
reboot
```

Remove the live USB and your system should now boot normally.
