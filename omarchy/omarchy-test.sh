#!/usr/bin/env bash
set -euo pipefail

# ===== Helper Functions =====
abort() { echo "$1"; exit 1; }

retry_command() {
    local cmd="$1"
    local tries=5
    local count=0
    until $cmd; do
        count=$((count + 1))
        echo "Command failed: $cmd"
        if [ "$count" -ge "$tries" ]; then
            echo "Reached max retries. Exiting."
            exit 1
        fi
        echo "Retrying in 5s... ($count/$tries)"
        sleep 5
    done
}

working_network() {
    ping -c 1 archlinux.org >/dev/null 2>&1
}

# ===== Step 1: Keyboard layout =====
read -p "Keyboard layout (e.g., us): " KB_LAYOUT
loadkeys "$KB_LAYOUT"

# ===== Step 2: Network =====
echo "Checking network..."
if ! working_network; then
    echo "No network detected. Configure Wi-Fi manually via iwctl."
fi

# ===== Step 3: User info =====
read -p "Username: " USERNAME
read -sp "Password: " PASSWORD
echo
read -p "Full name (optional): " FULLNAME
read -p "Email address (optional): " EMAIL
read -p "Hostname [omarchy]: " HOSTNAME
HOSTNAME="${HOSTNAME:-omarchy}"
read -p "Timezone (e.g., Europe/London): " TIMEZONE

# ===== Step 4: Disk selection =====
echo "Available disks:"
lsblk -dno NAME,SIZE,MODEL | grep -E '^(sd|vd|nvme|mmcblk)'

# Prompt for target disk
while true; do
    read -p "Target disk (e.g., /dev/sda, /dev/nvme0n1, /dev/mmcblk0): " DISK
    # Verify that disk exists and is a block device
    if [[ -b "$DISK" ]] && [[ "$DISK" =~ ^/dev/(sd|vd|nvme|mmcblk)[0-9]*$ ]]; then
        echo "WARNING: All data on $DISK will be destroyed!"
        read -p "Are you sure? (yes/no): " CONFIRM
        if [[ "$CONFIRM" == "yes" ]]; then
            break
        else
            echo "Aborted. Select disk again."
        fi
    else
        echo "Invalid disk. Try again."
    fi
done

# ===== Step 5: Partitioning =====
# Wipe existing partitions
sgdisk -Z "$DISK"

# EFI partition: 2100 MiB
sgdisk -n 1:0:+2100M -t 1:EF00 "$DISK"

# Root partition: rest of the disk
sgdisk -n 2:0:0 -t 2:8300 "$DISK"

# LUKS2 encryption and BTRFS formatting as before
echo -n "$PASSWORD" | cryptsetup luksFormat "${DISK}2" -
echo -n "$PASSWORD" | cryptsetup open "${DISK}2" cryptroot -
mkfs.fat -F32 "${DISK}1"
mkfs.btrfs -f /dev/mapper/cryptroot


# ===== Step 5: Partitioning =====
sgdisk -Z "$DISK"  # wipe
sgdisk -n 1:0:+2100M -t 1:EF00 "$DISK"   # EFI
sgdisk -n 2:0:0 -t 2:8300 "$DISK"       # root

# ===== Step 6: LUKS2 + BTRFS =====
echo -n "$PASSWORD" | cryptsetup luksFormat "${DISK}2" -
echo -n "$PASSWORD" | cryptsetup open "${DISK}2" cryptroot -

mkfs.fat -F32 "${DISK}1"
mkfs.btrfs -f /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
umount /mnt

mount -o compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg}
mount -o compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o compress=zstd,subvol=@log /dev/mapper/cryptroot /mnt/var/log
mount -o compress=zstd,subvol=@pkg /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount "${DISK}1" /mnt/boot

# ===== Step 7: Base system =====
retry_command "pacstrap /mnt base linux linux-firmware base-devel git sudo btrfs-progs"

# ===== Step 8: Fstab =====
genfstab -U /mnt >> /mnt/etc/fstab

# ===== Step 9: Chroot config =====
arch-chroot /mnt /bin/bash <<EOF
# Set hostname
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1 localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

# Set root password
echo "root:$PASSWORD" | chpasswd

# Create user
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Sudoers
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Timezone & locale
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Enable networking
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Install Limine
git clone https://github.com/limine-bootloader/limine.git /tmp/limine
cd /tmp/limine
make
make install
EOF

# ===== Step 10: Omarchy install =====
arch-chroot /mnt /bin/bash <<EOF
git clone https://github.com/basecamp/omarchy.git /tmp/omarchy
cd /tmp/omarchy
./install.sh
EOF

echo "Installation complete. Reboot into your new system!"

