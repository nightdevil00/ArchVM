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
pacman -S linux linux-headers nvidia-dkms hyprland limine
```

This will download and reinstall the latest Linux kernel, headers, and the Limine bootloader.

### Regenerate Initramfs

After reinstalling the kernel, it is crucial to regenerate the initramfs to include the necessary hooks for BTRFS and LUKS2.

```bash
mkinitcpio -P
```

## 5. Deploy and Configure Limine

**Note:** Limine only supports FAT filesystems. This means your kernel (`vmlinuz-linux`) and initramfs (`initramfs-linux.img`) must reside on your EFI System Partition (ESP) which is mounted at `/boot`.

### Deploy Limine to the ESP

First, copy the Limine EFI executable to your ESP and create a UEFI boot entry:

```bash
mkdir -p /boot/EFI/arch-limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/arch-limine/
```

Then create a UEFI boot entry using `efibootmgr`:

```bash
efibootmgr \
  --create \
  --disk /dev/sdX \
  --part Y \
  --label "Arch Linux Limine Boot Loader" \
  --loader '\EFI\arch-limine\BOOTX64.EFI' \
  --unicode
```

**Note:**
* Replace `/dev/sdX` with your disk (e.g., `/dev/sda`, `/dev/nvme0n1`)
* Replace `Y` with the partition number of your ESP (e.g., `1` if ESP is `/dev/sda1`)

**Tip:** If `efibootmgr` doesn't work on your motherboard, copy to the fallback path instead and skip the `efibootmgr` step:
```bash
mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
```

### Create Limine Configuration

Create the `limine.conf` file in the same directory as the Limine EFI executable (`/boot/EFI/arch-limine/limine.conf`):

```
timeout: 5

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: cryptdevice=UUID=<UUID_of_LUKS_partition>:root root=/dev/mapper/root rw rootflags=subvol=@
    module_path: boot():/initramfs-linux.img
```

**Important:**

* Replace `<UUID_of_LUKS_partition>` with the actual UUID of your LUKS2 partition. Find it with `lsblk -f` or `blkid`.
* `boot():/` refers to the partition where `limine.conf` resides (your ESP).
* Add `rootflags=subvol=@` to specify your root BTRFS subvolume.
* Make sure `/boot` contains `vmlinuz-linux` and `initramfs-linux.img` (Limine cannot read BTRFS).

## 6. Exit and Reboot

Finally, exit the chroot environment and reboot your computer:

```bash
exit
umount -R /mnt
cryptsetup close root
reboot
```

Remove the live USB and your system should now boot normally.
