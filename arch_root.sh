#!/bin/bash

set -e

# --- Helper functions ---
info() { echo -e "\e[1;34m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $*"; exit 1; }

# --- Disk and Partition Selection ---
info "Available disks:"
lsblk -d -n -o NAME,SIZE
read -p "Enter the name of the disk containing your Arch Linux installation (e.g., sda): " DISK

info "Available partitions on /dev/$DISK:"
lsblk -n -o NAME,SIZE,TYPE /dev/$DISK
read -p "Enter the name of the root partition (e.g., ${DISK}p2): " ROOT_PARTITION
read -p "Enter the name of the EFI partition (e.g., ${DISK}p1): " EFI_PARTITION

# --- LUKS Decryption ---
read -p "Is the root partition ($ROOT_PARTITION) encrypted with LUKS? (y/n): " IS_LUKS
LUKS_OPENED_BY_SCRIPT=false
if [ "$IS_LUKS" = "y" ]; then
    read -p "Enter a name for the unlocked LUKS container (e.g., cryptroot): " LUKS_NAME
    if [ -b "/dev/mapper/$LUKS_NAME" ]; then
        info "LUKS container $LUKS_NAME already exists."
        ROOT_DEVICE="/dev/mapper/$LUKS_NAME"
    else
        info "Opening LUKS container..."
        cryptsetup open /dev/$ROOT_PARTITION $LUKS_NAME
        ROOT_DEVICE="/dev/mapper/$LUKS_NAME"
        LUKS_OPENED_BY_SCRIPT=true
    fi
else
    ROOT_DEVICE="/dev/$ROOT_PARTITION"
fi

# --- Mount Filesystems ---
MOUNT_DIR="/mnt/arch"
mkdir -p "$MOUNT_DIR"

read -p "Is the root filesystem BTRFS? (y/n): " IS_BTRFS
if [ "$IS_BTRFS" = "y" ]; then
    read -p "Enter the name of the BTRFS subvolume to mount (e.g., @): " BTRFS_SUBVOLUME
    info "Mounting BTRFS subvolume..."
    mount -t btrfs -o subvol=$BTRFS_SUBVOLUME,compress=zstd "$ROOT_DEVICE" "$MOUNT_DIR"
else
    info "Mounting root filesystem..."
    mount "$ROOT_DEVICE" "$MOUNT_DIR"
fi

mkdir -p "$MOUNT_DIR/boot/EFI"
mount /dev/$EFI_PARTITION "$MOUNT_DIR/boot/EFI"

# --- Trap for cleanup ---
cleanup() {
    info "Cleaning up mounts..."
    umount -R -l "$MOUNT_DIR" 2>/dev/null || true
    if [ "$IS_LUKS" = "y" ] && [ "$LUKS_OPENED_BY_SCRIPT" = true ]; then
        cryptsetup close $LUKS_NAME
    fi
}
trap cleanup EXIT

# --- Install Grub Bootloader ---
info "Installing Grub bootloader..."
arch-chroot "$MOUNT_DIR" /bin/bash <<'GRUBEOF'
set -e
echo "Installing Grub packages..."
pacman -S --noconfirm grub efibootmgr
echo "Running grub-install..."
grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB
echo "Generating Grub configuration..."
grub-mkconfig -o /boot/grub/grub.cfg
echo "Grub installation completed."
GRUBEOF

# --- Interactive Chroot ---
info "Entering interactive arch-chroot. Type 'exit' to leave and unmount."
arch-chroot "$MOUNT_DIR"


