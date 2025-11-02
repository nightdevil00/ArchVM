#!/usr/bin/env bash
set -euo pipefail

echo "=== Arch Linux Automated Installer (LUKS2 + BTRFS + Limine) ==="

# ========= USER INPUT =========
read -rp "Enter target disk (e.g. /dev/nvme0n1): " DISK
read -rp "Enter username: " USERNAME
read -srp "Enter user password: " USER_PASS; echo
read -srp "Enter root password: " ROOT_PASS; echo
read -srp "Enter LUKS encryption password: " LUKS_PASS; echo

# ========= GEO-LOCATION TIMEZONE =========
echo "Detecting timezone..."
TIMEZONE=$(curl -s https://ipapi.co/timezone || echo "UTC")
echo "Using timezone: $TIMEZONE"

# ========= PARTITIONING =========
echo "--- Partitioning $DISK ---"
sgdisk --zap-all "$DISK"
parted --script "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 2049MiB \
    set 1 esp on \
    mkpart Linux btrfs 2050MiB 100%

ESP="${DISK}p1"
ROOT="${DISK}p2"

# ========= FORMAT ESP =========
mkfs.fat -F 32 "$ESP"

# ========= ENCRYPT + BTRFS =========
echo "--- Setting up LUKS2 encrypted BTRFS partition ---"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT" -
echo -n "$LUKS_PASS" | cryptsetup open "$ROOT" root -

mkfs.btrfs /dev/mapper/root
mount /dev/mapper/root /mnt

for sub in @ @home @var_log @var_cache @snapshots; do
    btrfs subvolume create "/mnt/$sub"
done

umount /mnt

mount -o compress=zstd:1,noatime,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o compress=zstd:1,noatime,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_log /dev/mapper/root /mnt/var/log
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_cache /dev/mapper/root /mnt/var/cache
mount --mkdir -o compress=zstd:1,noatime,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
mount --mkdir "$ESP" /mnt/boot

# ========= INSTALL BASE SYSTEM =========
echo "--- Installing base system ---"
pacman -Sy --noconfirm archlinux-keyring
pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs efibootmgr \
    limine cryptsetup networkmanager reflector sudo vim intel-ucode \
    dhcpcd iwd firewalld bluez bluez-utils acpid avahi rsync bash-completion \
    pipewire pipewire-alsa pipewire-pulse wireplumber sof-firmware

genfstab -U /mnt >> /mnt/etc/fstab

# ========= CHROOT CONFIGURATION =========
arch-chroot /mnt /bin/bash -e <<EOF
# --- TIMEZONE ---
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# --- LOCALE ---
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# --- HOSTNAME ---
echo "arch" > /etc/hostname

# --- ROOT PASSWORD ---
echo "root:$ROOT_PASS" | chpasswd

# --- USER SETUP ---
useradd -mG wheel $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- MKINITCPIO CONFIG ---
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^#BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- LIMINE SETUP ---
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

efibootmgr --create --disk $DISK --part 1 \
      --label "Arch Linux Limine Bootloader" \
      --loader '\\EFI\\limine\\BOOTX64.EFI' \
      --unicode

LUKS_UUID=\$(cryptsetup luksUUID $ROOT)

cat <<LIMINECONF > /boot/EFI/limine/limine.conf
timeout: 3

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=\$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=\$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux-fallback.img
LIMINECONF

# --- ENABLE SERVICES ---
for s in NetworkManager dhcpcd iwd systemd-networkd systemd-resolved bluetooth cups avahi-daemon firewalld acpid reflector.timer; do
    systemctl enable \$s
done

EOF

# ========= FINAL CLEANUP =========
echo "--- Cleaning up ---"
umount -R /mnt
cryptsetup close root

echo "=== Installation complete! Reboot now and remove installation media. ==="

