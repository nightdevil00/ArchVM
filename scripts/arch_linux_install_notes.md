# Arch Linux installation notes

LUKS2 encrypted BTRFS system partition with Limine/Snapper integration and hybernate to swapfile

## Table of Contents

- [Table of Contents](#table-of-contents)
- [Introduction](#introduction)
- [Preparation](#preparation)
  - [Ensure proper network connectivity](#ensure-proper-network-connectivity)
  - [Set keymap and (optionally) font](#set-keymap-and-optionally-font)
  - [Confirm the system is UEFI](#confirm-the-system-is-uefi)
  - [Disk partitioning](#disk-partitioning)
- [Format the ESP partition](#format-the-esp-partition)
- [Prepare the system partition](#prepare-the-system-partition)
  - [Create LUKS encrypted container on the system partition](#create-luks-encrypted-container-on-the-system-partition)
  - [Create the BTRFS layout inside the LUKS container](#create-the-btrfs-layout-inside-the-luks-container)
- [Installing the Arch Linux](#installing-the-arch-linux)
- [Setting up Limine bootloader](#setting-up-limine-bootloader)
- [Final steps](#final-steps)
  - [Networking](#networking)
  - [Exit from chroot and reboot](#exit-from-chroot-and-reboot)
- [Useful post-install steps](#useful-post-install-steps)
  - [Configure networking](#configure-networking)
  - [Additional packages](#additional-packages)
  - [Install yay](#install-yay)
  - [Time](#time)
  - [TRIM support](#trim-support)
  - [Pacman hook for Limine](#pacman-hook-for-Limine)
  - [Swap and hibernation](#swap-and-hibernation)
  - [Snapper](#snapper)
  - [Automatic firmware updates](#automatic-firmware-updates)
  - [Install hyprland](#install-hyprland)

---

## Introduction

This is my typical installation of [Arch Linux](https://archlinux.org) with LUKS2 encrypted BTRFS system partition on an UEFI system. This document does not replace [the official Arch Linux installation guide](https://wiki.archlinux.org/title/Installation_guide) and the accompanying documentation. It is merely a condensed note of the most important steps, intended for my personal use. Use it at your own risk, and keep in mind that some of the instructions below may be outdated or unsuitable for your specific case.

The following features are characteristic of this installation:

- The [system partition is encrypted with LUKS2](https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system#LUKS_on_a_partition) and formatted with the [BTRFS](https://wiki.archlinux.org/title/Btrfs) file system using subvolumes.
- The ESP partition (FAT32) is not encrypted and is mounted as `/boot` (if that's not secure enough for someone, additional measures can be taken, such as using *Secure Boot*).
- I like small, fast and sexy lightweight bootloaders, which is why [Limine](https://codeberg.org/Limine/Limine) is the choice of mine. It has a wonderful integration with [Snapper](http://snapper.io) also.
- The installation also provides functional network connectivity after the reboot.
- The goal of the installation is a system intended to be further configured for everyday desktop use.

## Preparation

It is assumed that the system has been successfully booted from [the official Arch Linux ISO](https://archlinux.org/download/).

### Ensure proper network connectivity

The assumption is that a laptop is being used, intended to connect to the Internet via a wireless connection.

```sh
iwctl station <device> connect <SSID>
```

### Set keymap and (optionally) font

Use the command `localectl list-keymaps` or something like `ls /usr/share/kbd/keymaps/**/*.map.gz | grep bg` to list keymaps. Or just set:

```sh
loadkeys us
setfont ter-132b
```

### Confirm the system is UEFI

I usually explicitly use [UEFI](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface) 64-bit systems such as the Lenovo ThinkPad X1, T470s, T480s, T14, T14s, and other similar models, but you can check whether the current system is one by running the command:

```sh
cat /sys/firmware/efi/fw_platform_size
```

If this command prints 64 or 32 then the current system is UEFI.

### Disk partitioning

N.B. The assumption here is that we are setting up a new computer that will run only *Arch Linux*. No dual boot with *Windows* or other *Linux* installations.

One partition is needed for the [ESP](https://wiki.archlinux.org/title/EFI_system_partition), which will be used for `/boot` with a FAT32 file system. The remaining disk space will be encrypted with LUKS2 and formatted with BTRFS. This setup allows for flexible management of subvolumes within the container for specific directories, including snapshots or swap.

I prefer to have enough space in `/boot` for various purposes (including possibly multiple kernel versions), so I usually make this partition at least 2GB.

To start fresh, let's wipe all existing partitions on the disk. If there's any chance you might miss something currently stored on this disk, now is the time to proactively make a backup.

```sh
sgdisk --zap-all /dev/nvme0n1
```

Tools like `fdisk`, `cfdisk`, `cgdisk`, and others can be used here, but `parted` has the advantage of being script-friendly.

```sh
parted --script /dev/nvme0n1 \
    mklabel gpt \
    mkpart ESP fat32 1MiB 2049MiB \
    set 1 esp on \
    mkpart Linux btrfs 2050MiB 100%
```

## Format the ESP partition

Most probably the partition will be `/dev/nvme0n1p1` (partition `1` on disk `nvme0n1`), but this can be checked with `lsblk` command.

Let's format the ESP partition as FAT32.

```sh
mkfs.fat -F 32 /dev/nvme0n1p1
```

## Prepare the system partition

### Create LUKS encrypted container on the system partition

Simple as that:

```sh
cryptsetup luksFormat /dev/nvme0n1p2
```

It should be more than obvious that the password used to encrypt this system partition must not be random and obvious, but it also must not be forgotten.

Later, the UUID of this container will be needed, which can be obtained using the command `cryptsetup luksUUID /dev/nvme0n1p2` or the command `ls -l --time-style=+ /dev/disk/by-uuid/`. Make sure to save this UUID somewhere.

### Create the BTRFS layout inside the LUKS container

First, open the container (should appear as `/dev/mapper/root` using the command below):

```sh
cryptsetup open /dev/nvme0n1p2 root
```

Format it as BTRFS:

```sh
mkfs.btrfs /dev/mapper/root
```

Mount (temporarily) the newly created *btrfs* file system in `\mnt`:

```sh
mount /dev/mapper/root /mnt
```

And let's make some subvolumes. 

```sh
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache
btrfs subvolume create /mnt/@snapshots
```

At a later stage, another one for *swap* (and hibernation) will be added. However, this is done from the comfort of an already installed and functioning system. It is not critical to perform this manually at this point.

Let's unmount the temporarily mounted file system and mount the subvolumes instead (incl. the the vfat ESP partition). If you don't want compression just remove the compress option, but `level 1` is great for NMVE disks. Also `noatime` is fine for personal desktop setup.

```sh
umount /mnt
mount -o compress=zstd:1,noatime,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o compress=zstd:1,noatime,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_log /dev/mapper/root /mnt/var/log
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_cache /dev/mapper/root /mnt/var/cache
mount --mkdir -o compress=zstd:1,noatime,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
mount --mkdir /dev/nvme0n1p1 /mnt/boot
```

And we are ready to go with the installation itself.

## Installing the Arch Linux

Let's install some packages. Many guides will tell you that `pacstrap -K /mnt base linux linux-firmware` is more than enough. Even if that’s true, there are somehow higher expectations...

```sh
pacman -Syy
pacstrap -K /mnt base base-devel linux linux-firmware git vim btrfs-progs efibootmgr limine cryptsetup dhcpcd iwd networkmanager reflector bash-completion avahi acpi acpi_call acpid alsa-utils pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber sof-firmware firewalld bluez bluez-utils cups util-linux terminus-font openssh man sudo rsync intel-ucode
```

N.B. Replace `intel-ucode` with `amd-ucode` if you have an AMD processor.

Make fstab file from your current filesystem layout. Edit it manually in case of some obvious errors.

```sh
genfstab -U /mnt >> /mnt/etc/fstab
```

It's time to chroot to our /mnt point.

```sh
arch-chroot /mnt
```

Set the local time properly. Use your time zone.

```sh
ln -sf /usr/share/zoneinfo/Europe/Sofia /etc/localtime
hwclock --systohc
```

In the file `/etc/locale.gen` uncomment all the needed locales. In my case `en_US.UTF-8 UTF-8` and `bg_BG.UTF-8 UTF-8`. Save the changes in the file and execute command `locale-gen` after that. At the end add the English locale in `/etc/locale.conf`.

```sh
vim /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf
```

Create `/etc/vconsole.conf` file and add the following inside it. (FONT variable is optional)

```sh
vim /etc/vconsole.conf
KEYMAP=us
FONT=ter-132b
```

Set a hostname.

```sh
echo arch > /etc/hostname
```

Set up the root password

```sh
passwd
```

Add a new user, add it to wheel group and set a password.

```sh
useradd -mG wheel yovko
passwd yovko
```

Execute the following command and uncomment the line *to let members of group wheel execute any program*

```sh
EDITOR=vim visudo
```

Modify `/etc/mkinitcpio.conf` to have `btrfs` in MODULES, `/usr/bin/btrfs` in BINARIES, and `encrypt` in HOOKS. Add `encrypt` hook after `block` and before `filesystems`. 

If hibernation is to be used, `resume` needs to be added (somewhere after `udev`). If it is from a swap file inside an encrypted container (as in this case), then `resume` should be placed after the `encrypt` and `filesystem` hooks.

```sh
MODULES=(btrfs)
...
BINARIES=(/usr/bin/btrfs)
...
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)
...
```

Don't forget to execute `mkinitcpio -P` command.

## Setting up Limine bootloader

Limine setup on UEFI systems is very simple. Just make `/boot/EFI/limine` directory and copy the relevant file BOOT file there. For more [detailed instructions check the Limine page in the Arch wiki](https://wiki.archlinux.org/title/Limine#UEFI_systems).

```sh
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
```

Now we need to create an entry for Limine in the NVRAM:

```sh
efibootmgr --create --disk /dev/nvme0n1 --part 1 \
      --label "Arch Linux Limine Bootloader" \
      --loader '\EFI\limine\BOOTX64.EFI' \
      --unicode
```

N.B. `--disk /dev/nvme0n1 --part 1` means `/dev/nvme0n1p1`

N.B. Do NOT include `boot` when pointing to Limine Bootloader file.

N.B. In a Limine config, `boot():/` represents the partition on which `limine.conf` is located.

Finally let's make a basic configuration for Limine. Use the command `vim /boot/EFI/limine/limine.conf` and write inside the following (or at least the first of the two sections):

```sh
timeout: 3

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=<device-UUID>:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=<device-UUID>:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux-fallback.img
```

Remember [being advised to save an UUID](#create-luks-encrypted-container-on-the-system-partition)? Now is the time to use it. Replace the `<device-UUID>` above with the UUID of your LUKS container.

## Final steps

### Networking

Enable `NetworkManager` and `systemd-networkd` services before rebooting. Otherwise, you won't be able to connect. The `systemd-resolved` service is a kind of optional, but most probably it is better to enable it. Also you may need `dhcpcd.service` and (if you need WiFi) `iwd.service`.

```sh
systemctl enable NetworkManager
systemctl enable dhcpcd
systemctl enable iwd
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable bluetooth
systemctl enable cups
systemctl enable avahi-daemon
systemctl enable firewalld
systemctl enable acpid
systemctl enable reflector.timer

```

### Exit from chroot and reboot

It's time to exit the chroot, unmount the `/mnt`, close the crypted container and reboot to the newly installed Arch Linux.

```sh
exit
umount -R /mnt
cryptsetup close root
reboot
```

Do not forget to unplug the installation media (USB stick).

Enjoy!

## Useful post-install steps

Act as `root`, otherwise use `sudo`.

### Configure networking

A working network configuration needs to be adjusted according to [this guide](https://wiki.archlinux.org/title/Network_configuration). In my case I just need to do (once again):

```sh
iwctl station <device> connect <SSID>
```

### Additional packages

A set of useful stuff... and some Intel video drivers (specific to my hardware).

```sh
pacman -Syu wget htop gvfs gvfs-smb inetutils imagemagick usbutils easyeffects openbsd-netcat nss-mdns bat zip unzip brightnessctl xdg-user-dirs noto-fonts nerd-fonts ttf-jetbrains-mono libreoffice-fresh libreoffice-fresh-bg firefox thunderbird
```

Optional (only for Intel video):
```sh
pacman -Syu intel-media-driver mesa vulkan-intel
```

### Install yay

It is not recommended to use `makepkg` as root, so this step is supposed to be performed with a user account.

```sh
sudo pacman -S --needed git base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si
```

### Time

Check if `ntp` is active and if the time is right. Enable and start the time synchronization service (usually it is not enabled).

```sh
timedatectl
timedatectl set-ntp true
```

### TRIM support

Check if the SSD drive supports TRIM with the command `lsblk --discard`. Non-zero values of DISC-GRAN (discard granularity) and DISC-MAX (discard max bytes) indicate TRIM support.

The `util-linux` package provides `fstrim.service` and `fstrim.timer` systemd unit files. Enabling the timer will activate the service weekly. This is the so-called periodic TRIM.

```sh
pacman -S --needed util-linux
systemctl enable --now fstrim.timer
```

### Pacman hook for Limine

Add `/etc/pacman.d/hooks/99-limine.hook` file with the following content:

```sh
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine              

[Action]
Description = Deploying Limine after upgrade...
When = PostTransaction
Exec = /usr/bin/cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
```

### Swap and hibernation

Create swapfile in swap subvolume and enable it. I use swap to hibernate my laptop so, the size is the size of my RAM.

```sh
btrfs subvolume create /swap
btrfs filesystem mkswapfile --size 32g --uuid clear /swap/swapfile
swapon -p 0 /swap/swapfile
```

Add the following in the `/etc/fstab`:

```sh
/swap/swapfile none swap defaults,pri=0 0 0
```

Add `resume` in `/etc/mkinitcpio.conf` HOOKS...

```sh
HOOKS=(base udev keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems resume fsck)
```

... and execute:

```sh
mkinitcpio -P
```

Note: It is not mandatory anymore (on UEFI systems) but when using the `resume=` kernel parameter, it must point to the unlocked/mapped device (`/dev/mapper/root`) that contains the file system with the swap file i.e. `findmnt -no UUID -T /swap/swapfile`.

Check all possible commands (some will not be available before reboot): https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate#High_level_interface_(systemd)

### Snapper

```sh
pacman -Syu snapper
yay -S limine-snapper-sync limine-mkinitcpio-hook
```

Add `btrfs-overlayfs` at the end of the HOOKS in `/etc/mkinitcpio.conf` and execute `mkinitcpio -P`

```sh
umount /.snapshots
snapper -c root create-config /
snapper -c home create-config /home
sudo mount -a
sudo sed -i 's/^TIMELINE_CREATE="yes"/TIMELINE_CREATE="no"/' /etc/snapper/configs/{root,home}
sudo sed -i 's/^NUMBER_LIMIT="50"/NUMBER_LIMIT="5"/' /etc/snapper/configs/{root,home}
sudo sed -i 's/^NUMBER_LIMIT_IMPORTANT="10"/NUMBER_LIMIT_IMPORTANT="5"/' /etc/snapper/configs/{root,home}
```

(Optional): Copy configuration from `/etc/limine-snapper-sync.conf` to `/etc/default/limine` if it not already present. And change  in `/etc/default/limine`:

```sh
MAX_SNAPSHOT_ENTRIES=5
LIMIT_USAGE_PERCENT=85
ROOT_SNAPSHOTS_PATH="/@snapshots"
```

In `/etc/limine-snapper-sync.conf` find and disable/remove (if not used):

```sh
#COMMANDS_BEFORE_SAVE="limine-reset-enroll" 
#COMMANDS_AFTER_SAVE="limine-enroll-config"
```

Create (if it isn't there yet) `/boot/limine.conf` file and add `//Snapshots` inside. Replace `<machine-id>` with the output from the command `cat /etc/machine-id`.

```sh
term_font_scale: 2x2

/+Arch Linux
comment: Arch Linux
comment: machine-id=<machine-id>
  
    //Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=XXXXXX-XXXXXX:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs resume=UUID=YYYYY-YYYYYY resume_offset=ZZZZZZZ
    module_path: boot():/initramfs-linux.img

    //Snapshots
```

Execute the command `limine-snapper-sync` and if there are no errors `systemctl enable --now limine-snapper-sync.service`.

Available (important) commands are:
* `limine-snapper-list` - displays the current Limine snapshot entries
* `limine-snapper-sync` - synchronizes Limine snapshot entries with the Snapper list
* `limine-snapper-info` - provides information about versions, the total number of bootable snapshots, etc.
* `limine-snapper-restore` - restores the system, including matching kernel versions, from a selected bootable snapshot

Optionally install `snap-pac`. It triggers snapper to create snapshots during system updates.

```sh
pacman -Syu snap-pac
```

More information regarding Snapper integration with Limine (on Btrfs) here: https://wiki.archlinux.org/title/Limine#Snapper_snapshot_integration_for_Btrfs

### Automatic firmware updates

```sh
pacman -Syu fwupd udisks2
fwupdmgr get-devices
fwupdmgr refresh
fwupdmgr get-updates
fwupdmgr update
systemctl enable --now fwupd-refresh.timer
```

### Install Hyprland

```sh
sudo pacman -S hyprland nwg-displays xdg-desktop-portal-hyprland swaylock wofi dolphin kitty seatd uwsm libnewt mako greetd-regreet
yay -S wlogout
systemctl enable --now seatd.service
```

Optional: Configure Bulgarian (Phonetic) keyboard support (or any other non-default layout) and proper monitor:

```sh
~/.config/hypr/hyprland.conf:
input {
    # Bulgarian Phonetic support
    kb_layout = us, bg
    kb_variant =  , phonetic
    kb_options = grp:win_space_toggle
}

monitorv2 {
    output = eDP-1
    mode = 3840x2400@60
    position = 0x0
    scale = 2
}
```

And follow:
* Arch Linux Hyprland guide: https://wiki.archlinux.org/title/Hyprland
* UWSM guide: https://wiki.archlinux.org/title/Universal_Wayland_Session_Manager
* Hyprland Master tutorial: https://wiki.hypr.land/Getting-Started/Master-Tutorial/ 