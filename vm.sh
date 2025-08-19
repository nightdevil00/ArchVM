#!/usr/bin/env bash
set -euo pipefail

# Run this from the official Arch ISO as root with networking enabled.
# Dependencies:
# pacman -Sy --needed git arch-install-scripts btrfs-progs dosfstools e2fsprogs \
# cryptsetup grub efibootmgr reflector curl

#-----------------------------------------
# Helpers
#-----------------------------------------
err() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

require() {
    local missing=()
    for bin in "$@"; do command -v "$bin" >/dev/null 2>&1 || missing+=("$bin"); done
    (( ${#missing[@]} )) && { echo "Missing: ${missing[*]}"; exit 1; }
}

[[ $EUID -eq 0 ]] || err "Run as root"

#-----------------------------------------
# Enable NTP
#-----------------------------------------
info "Enabling and starting systemd-timesyncd..."
systemctl enable systemd-timesyncd
systemctl start systemd-timesyncd
sleep 2
timedatectl show
timedatectl set-ntp true

#-----------------------------------------
# Disk selection
#-----------------------------------------
mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|nvme|vd)" | awk '{print $1"|"$0}')
(( ${#DISKS[@]} )) || err "No installable disks found"

echo "Available disks:"
for i in "${!DISKS[@]}"; do
    echo "$i) ${DISKS[$i]}"
done
read -rp "Select disk index [0]: " DISK_IDX
DISK_IDX=${DISK_IDX:-0}
DISK=${DISKS[$DISK_IDX]}
DISK=${DISK%%|*}

read -rp "Erase all data on $DISK? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1

# Detect firmware
FIRMWARE=BIOS
[[ -d /sys/firmware/efi/efivars ]] && FIRMWARE=UEFI
info "Firmware detected: $FIRMWARE"

#-----------------------------------------
# Filesystem choice
#-----------------------------------------
echo "Filesystem options:"
echo "1) Btrfs on LUKS (recommended)"
echo "2) ext4 (optional /home)"
read -rp "Choice [1]: " FS_CHOICE
FS_CHOICE=${FS_CHOICE:-1}
[[ $FS_CHOICE -eq 2 ]] && FS=ext4 || FS=btrfs

read -rp "Enter EFI size (e.g., 512M) [512M]: " EFI_SIZE
EFI_SIZE=${EFI_SIZE:-512M}

SEPARATE_HOME=no
HOME_SIZE=""
if [[ $FS == ext4 ]]; then
    read -rp "Create separate /home? [y/N]: " HOME_CHOICE
    [[ "$HOME_CHOICE" =~ ^[Yy]$ ]] && SEPARATE_HOME=yes
    if [[ $SEPARATE_HOME == yes ]]; then
        read -rp "Enter /home size (rest goes to /, e.g. 100G): " HOME_SIZE
    fi
fi

#-----------------------------------------
# User / Host / Locale / Time
#-----------------------------------------
read -rp "Hostname [archbox]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archbox}

read -rp "Username [arch]: " USERNAME
USERNAME=${USERNAME:-arch}

read -rsp "User password [arch]: " USERPASS
echo
USERPASS=${USERPASS:-arch}

read -rsp "Root password [root]: " ROOTPASS
echo
ROOTPASS=${ROOTPASS:-root}

echo "Sudo mode:"
echo "1) pw - User in wheel, sudo with password"
echo "2) nopw - User in wheel, passwordless sudo"
echo "3) none - No sudo"
read -rp "Choice [1]: " SUDO_CHOICE
SUDO_CHOICE=${SUDO_CHOICE:-1}
case $SUDO_CHOICE in
    1) SUDO_MODE=pw ;;
    2) SUDO_MODE=nopw ;;
    3) SUDO_MODE=none ;;
    *) SUDO_MODE=pw ;;
esac

read -rp "Timezone [Europe/Bucharest]: " TZONE
TZONE=${TZONE:-Europe/Bucharest}

# Locales to generate
LOCALES=(en_US.UTF-8)
echo "Default locale: ${LOCALES[0]}"

#-----------------------------------------
# Partitioning
#-----------------------------------------
info "Partitioning $DISK ..."
parted -s "$DISK" mklabel gpt

START=1MiB
EFI_END=$EFI_SIZE

if [[ $FIRMWARE == BIOS ]]; then
    parted -s "$DISK" mkpart bios_boot $START 3MiB
    parted -s "$DISK" set 1 bios_grub on
    START=3MiB
fi

# EFI partition
parted -s "$DISK" mkpart EFI fat32 $START $EFI_END
[[ $FIRMWARE == UEFI ]] && parted -s "$DISK" set 1 esp on

# Determine start for next partition
NEXT_START=$(parted -sm "$DISK" unit MiB print | awk -F: '/^1:/{gsub("MiB","",$3); print $3+1"MiB"}')

# Root / Home partitions
if [[ $FS == btrfs ]]; then
    parted -s "$DISK" mkpart cryptroot $NEXT_START 100%
else
    if [[ $SEPARATE_HOME == yes && -n "$HOME_SIZE" ]]; then
        parted -s "$DISK" mkpart root $NEXT_START "-"$HOME_SIZE
        parted -s "$DISK" mkpart home "-"$HOME_SIZE 100%
    else
        parted -s "$DISK" mkpart root $NEXT_START 100%
    fi
fi

partprobe "$DISK"
sleep 2

# Partition names
if [[ $DISK == *nvme* ]]; then
    P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3"
else
    P1="${DISK}1"; P2="${DISK}2"; P3="${DISK}3"
fi

mkfs.vfat -F32 "$P1"

#-----------------------------------------
# Format and mount
#-----------------------------------------
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
    if [[ $SEPARATE_HOME == yes && -n "$HOME_SIZE" ]]; then
        mkfs.ext4 -F "$P2"
        mkfs.ext4 -F "$P3"
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

#-----------------------------------------
# Mirrors
#-----------------------------------------
info "Refreshing mirrors..."
COUNTRY=$(curl -fsSL https://ipapi.co/country_name || true)
if [[ -n ${COUNTRY:-} ]]; then
    reflector --protocol https --country "$COUNTRY" --latest 30 --sort rate --save /etc/pacman.d/mirrorlist || true
else
    reflector --protocol https --latest 30 --sort rate --save /etc/pacman.d/mirrorlist || true
fi

#-----------------------------------------
# Package selection
#-----------------------------------------
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2); print $2}')
MICROCODE=()
case "$CPU_VENDOR" in
    GenuineIntel) MICROCODE+=(intel-ucode) ;;
    AuthenticAMD) MICROCODE+=(amd-ucode) ;;
esac

GPUINFO=$(lspci | grep -E "VGA|3D|Display" || true)
GPU_PKGS=(mesa)
echo "$GPUINFO" | grep -qi nvidia && GPU_PKGS+=(nvidia nvidia-utils)

BASE_PKGS=(base linux linux-lts linux-firmware git networkmanager sudo nano vim \
           btrfs-progs dosfstools e2fsprogs cryptsetup grub efibootmgr reflector)
ALL_PKGS=("${BASE_PKGS[@]}" "${MICROCODE[@]}" "${GPU_PKGS[@]}")

info "Installing base system..."
pacstrap -K /mnt "${ALL_PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab

#-----------------------------------------
# Chroot configuration
#-----------------------------------------
arch-chroot /mnt /bin/bash -e <<'CHROOT'
set -e

# Variables passed via environment
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
USERPASS="$USERPASS"
ROOTPASS="$ROOTPASS"
SUDO_MODE="$SUDO_MODE"
FS="$FS"
TZONE="$TZONE"
MICROCODE=(${MICROCODE[@]})
LOCALES=(${LOCALES[@]})
P1="$P1"
P2="$P2"
P3="$P3"

ln -sf /usr/share/zoneinfo/$TZONE /etc/localtime
hwclock --systohc || true

# Locales
for loc in "${LOCALES[@]}"; do
    sed -i "s/^#\(${loc} UTF-8\)/\1/" /etc/locale.gen || true
done
locale-gen
echo "LANG=${LOCALES[0]}" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# mkinitcpio hooks
if [[ "$FS" == btrfs ]]; then
    sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems btrfs fsck)/' /etc/mkinitcpio.conf
else
    sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# Users & sudo
usermod -p "*" root >/dev/null 2>&1 || true
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
(echo "$ROOTPASS"; echo "$ROOTPASS") | passwd root

case "$SUDO_MODE" in
    pw)
        sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
        ;;
    nopw)
        echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99_wheel_nopw
        chmod 440 /etc/sudoers.d/99_wheel_nopw
        ;;
    none)
        :
        ;;
esac

systemctl enable NetworkManager


CHROOT

# -------------------------------
# GRUB installation
# -------------------------------
info "Installing GRUB..."
if [[ $FIRMWARE == UEFI ]]; then
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
    arch-chroot /mnt grub-install --target=i386-pc "$DISK"
fi

# Configure GRUB parameters depending on FS
if [[ $FS == btrfs ]]; then
    CRYPT_UUID=$(blkid -s UUID -o value "$P2")
    GRUB_CMDLINE="cryptdevice=UUID=$CRYPT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw"
else
    ROOT_UUID=$(blkid -s UUID -o value "$P2")
    GRUB_CMDLINE="root=UUID=$ROOT_UUID rw"
fi

# Update /etc/default/grub inside chroot
arch-chroot /mnt bash -c "sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE\"|' /etc/default/grub"

# Generate GRUB configuration
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

info "GRUB installation and configuration complete!"
