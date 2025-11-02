Use iwctl to connect to wifi
ping -c 3 archlinux.org

lsblk

cfdisk /dev/sdXY

2G EFI System
remaining space Linux filesystem

Encrypt the root with LUKS2
cryptsetup luksFormat /dev/sda2
YES
enter the password
Open
cryptsetup open /dev/sda2 root
This creates /dev/mapper/root.
Create subvolumes Do NOT create a subvolume for snapshots
mkfs.fat -F32 /dev/sda1
mkfs.btrfs /dev/mapper/root
mount /dev/mapper/root /mnt

btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@pkg
btrfs su cr /mnt/@log

umount /mnt
mount -o compress=zstd:1,noatime,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o compress=zstd:1,noatime,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o compress=zstd:1,noatime,subvol=@pkg /dev/mapper/root /mnt/var/cache/pacman/pkg
mount --mkdir -o compress=zstd:1,noatime,subvol=@log /dev/mapper/root /mnt/var/log

mount --mkdir /dev/sda1 /mnt/boot

reflector --verbose -c us -a 12 --sort rate --save /etc/pacman.d/mirrorlist

pacstrap -K /mnt base base-devel linux linux-firmware git vim btrfs-progs efibootmgr limine cryptsetup dhcpcd iwd networkmanager reflector bash-completion avahi acpi acpi_call acpid alsa-utils pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber sof-firmware util-linux openssh man sudo rsync

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt

ln -sf /usr/share/zoneinfo/Europe/Sofia /etc/localtime
timedatectl set-ntp true
hwclock --systohc

vim /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

vim /etc/vconsole.conf
KEYMAP=us

echo arch > /etc/hostname

passwd

useradd -mG wheel john
passwd john

EDITOR=vim visudo

/etc/mkinitcpio.conf

MODULES=(btrfs)
...
HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)
...

mkinitcpio -P

Setting up Limine bootloader

mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

Now we need to create an entry for Limine in the NVRAM:

efibootmgr --create --disk /dev/sda2 --part 1 --label "Arch Linux Limine Bootloader" --loader '\EFI\limine\BOOTX64.EFI' --unicode

efibootmgr -v

N.B. --disk /dev/nvme0n1 --part 1 means /dev/nvme0n1p1

N.B. Do NOT include boot when pointing to Limine Bootloader file.

N.B. In a Limine config, boot():/ represents the partition on which limine.conf is located.

blkid /dev/sda2
cryptsetup luksUUID /dev/sda2

Finally let's make a basic configuration for Limine. Use the command vim /boot/EFI/limine/limine.conf and write inside the following (or at least the first of the two sections):

timeout: 3

/Arch Linux
protocol: linux
path: boot():/vmlinuz-linux
cmdline: quiet cryptdevice=UUID=:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
protocol: linux
path: boot():/vmlinuz-linux
cmdline: quiet cryptdevice=UUID=:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
module_path: boot():/initramfs-linux-fallback.img

cryptsetup luksUUID /dev/sda2

Remember being advised to save an UUID? Now is the time to use it. Replace the above with the UUID of your LUKS container.
Later you will need the UUID of this container, which can be obtained through the command - cryptsetup luksUUID/dev/nvme0n1p2 or the command ls -l --time-style=+ /dev/disk/by-uuid/. Make sure you save this UUID somewhere.

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

exit
umount -R /mnt
cryptsetup close root
reboot

Reboot and login as user and run: curl -fsSL https://omarchy.org/install | bash

https://learn.omacom.io/2/the-omarchy-manual/96/manual-installation

good luck!!
