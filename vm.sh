#!/usr/bin/env bash
set -euo pipefail

# -------------------------------
# Helpers
# -------------------------------
err() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

require() {
    local missing=()
    for bin in "$@"; do command -v "$bin" >/dev/null 2>&1 || missing+=("$bin"); done
    if (( ${#missing[@]} )); then
        echo "Missing dependencies: ${missing[*]}" >&2
        exit 1
    fi
}

# -------------------------------
# Check deps
# -------------------------------
require parted lsblk pacstrap genfstab arch-chroot sed awk grep cut sort uniq curl \
        reflector mkfs.vfat mkfs.ext4 mkswap swapon cryptsetup mkfs.btrfs grub-install \
        grub-mkconfig efibootmgr timedatectl

[[ $EUID -eq 0 ]] || err "Run as root"

# -------------------------------
# NTP
# -------------------------------
info "Enabling systemd-timesyncd..."
systemctl enable systemd-timesyncd
systemctl start systemd-timesyncd
timedatectl set-ntp true

# -------------------------------
# User input
# -------------------------------
read -rp "Target disk (e.g. /dev/vda, /dev/nvme0n1): " DISK
read -rp "Root password: " ROOTPASS
read -rp "Username: " USERNAME
read -rp "User password: " USERPASS
read -rp "Hostname: " HOSTNAME
read -rp "Timezone (e.g. Europe/Bucharest): " TZONE
read -rp "Filesystem (btrfs/ext4): " FS
if [[ $FS == ext4 ]]; then
    read -rp "Create separate /home? (yes/no): " SEPARATE_HOME
    if [[ $SEPARATE_HOME == yes ]]; then
        read -rp "Size for /home (e.g. 100G): " HOME_SIZE
    fi
else
    SEPARATE_HOME=no
fi

# -------------------------------
# Partitioning
# -------------------------------
info "Partitioning $DISK..."
parted -s "$DISK" mklabel gpt
START=1MiB
EFI_SIZE=512MiB
if [[ -d /sys/firmware/efi/efivars ]]; then
    FIRMWARE=UEFI
else
    FIRMWARE=BIOS
fi

if [[ $FIRMWARE == BIOS ]]; then
    parted -s "$DISK" mkpart bios_boot $START 3MiB
    parted -s "$DISK" set 1 bios_grub on
    START=3MiB
fi

parted -s "$DISK" mkpart EFI fat32 $START $EFI_SIZE
[[ $FIRMWARE == UEFI ]] && parted -s "$DISK" set 2 esp on

NEXT_START=$(
    parted -sm "$DISK" unit MiB print | awk -F: '/^2:/{gsub("MiB","",$3); print $3+1"MiB"}'
)

if [[ $FS == btrfs ]]; then
    parted -s "$DISK" mkpart cryptroot $NEXT_START 100%
else
    if [[ $SEPARATE_HOME == yes ]]; then
        parted -s "$DISK" mkpart root $NEXT_START "-"$HOME_SIZE
        parted -s "$DISK" mkpart home "-"$HOME_SIZE 100%
    else
        parted -s "$DISK" mkpart root $NEXT_START 100%
    fi
fi

partprobe "$DISK"
sleep 2

# -------------------------------
# Identify partitions
# -------------------------------
if [[ $DISK == *nvme* ]]; then
    P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3"
else
    P1="${DISK}1"; P2="${DISK}2"; P3="${DISK}3"
fi

mkfs.vfat -F32 "$P1"

# -------------------------------
# Format and mount
# -------------------------------
if [[ $FS == btrfs ]]; then
    cryptsetup -y -v luksFormat "$P2"
    cryptsetup open "$P2" cryptroot
    mkfs.btrfs -f -L ROOT /dev/mapper/cryptroot
    mount /dev/mapper/cryptroot /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    umount /mnt
    mount -o subvol=@,compress=zstd,noatime /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/{boot,home}
    mount -o subvol=@home,compress=zstd,noatime /dev/mapper/cryptroot /mnt/home
    mount "$P1" /mnt/boot
else
    if [[ $SEPARATE_HOME == yes ]]; then
        mkfs.ext4 -F "$P2" && mkfs.ext4 -F "$P3"
        mount "$P2" /mnt
        mkdir -p /mnt/boot /mnt/home
        mount "$P3" /mnt/home
    else
        mkfs.ext4 -F "$P2"
        mount "$P2" /mnt
        mkdir -p /mnt/boot
    fi
    mount "$P1" /mnt/boot
fi

# -------------------------------
# Mirrors
# -------------------------------
COUNTRY=$(curl -fsSL https://ipapi.co/country_name || true)
if [[ -n "$COUNTRY" ]]; then
    reflector --protocol https --country "$COUNTRY" --latest 30 --sort rate --save /etc/pacman.d/mirrorlist || true
else
    reflector --protocol https --latest 30 --sort rate --save /etc/pacman.d/mirrorlist || true
fi

# -------------------------------
# Base system packages
# -------------------------------
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2); print $2}')
MICROCODE=()
case "$CPU_VENDOR" in
    GenuineIntel) MICROCODE+=(intel-ucode) ;;
    AuthenticAMD) MICROCODE+=(amd-ucode) ;;
esac

GPUINFO=$(lspci | grep -E "VGA|3D|Display" || true)
GPU_PKGS=(mesa)
if echo "$GPUINFO" | grep -qi nvidia; then GPU_PKGS+=(nvidia nvidia-utils); fi

BASE_PKGS=(base linux linux-lts linux-firmware git networkmanager sudo nano vim \
           btrfs-progs dosfstools e2fsprogs cryptsetup grub efibootmgr reflector)

ALL_PKGS=("${BASE_PKGS[@]}" "${MICROCODE[@]}" "${GPU_PKGS[@]}")

info "Installing base system..."
pacstrap -K /mnt "${ALL_PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab

# -------------------------------
# System config in chroot
# -------------------------------
arch-chroot /mnt /bin/bash <<CHROOT
set -e
ln -sf /usr/share/zoneinfo/$TZONE /etc/localtime
hwclock --systohc
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# Locales
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# mkinitcpio hooks
if [[ "$FS" == btrfs ]]; then
    sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems btrfs fsck)/' /etc/mkinitcpio.conf
else
    sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# Users
usermod -p "*" root 2>/dev/null || true
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
echo "$ROOTPASS" | passwd --stdin root || true
echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers

systemctl enable NetworkManager
CHROOT

# -------------------------------
# GRUB installation
# -------------------------------
if [[ $FIRMWARE == UEFI ]]; then
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
    arch-chroot /mnt grub-install --target=i386-pc "$DISK"
fi

# Configure GRUB
if [[ $FS == btrfs ]]; then
    CRYPT_UUID=$(blkid -s UUID -o value "$P2")
    ROOT_OPTS="cryptdevice=UUID=$CRYPT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw"
else
    ROOT_UUID=$(blkid -s UUID -o value "$P2")
    ROOT_OPTS="root=UUID=$ROOT_UUID rw"
fi

arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

info "Installation complete. You can now reboot!"
