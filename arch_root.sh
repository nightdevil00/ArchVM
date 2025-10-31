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

# --- Chroot and Perform Actions ---
arch-chroot "$MOUNT_DIR" /bin/bash <<EOF
set -e

echo "Detecting EFI mount point..."
ESP_PATH=""

# Detect most common EFI mount locations
for path in /boot/EFI /boot /efi; do
    if [ -d "\$path/EFI" ] || [ -d "\$path/EFI" ] || find "\$path" -maxdepth 1 -type d -iname "EFI" | grep -q .; then
        ESP_PATH="\$path"
        break
    fi
done

# Fallback if nothing found
if [ -z "\$ESP_PATH" ]; then
    ESP_PATH="/boot"
    echo "Warning: Could not auto-detect ESP path. Defaulting to /boot."
else
    echo "Detected ESP path: \$ESP_PATH"
fi

echo "Preconfiguring Limine ESP path..."
mkdir -p /etc/default
echo "ESP_PATH=\$ESP_PATH" > /etc/default/limine

echo "Installing required base packages..."
pacman -Sy --noconfirm git base-devel sudo limine

# Determine which user to use for AUR builds
if id -u mihai >/dev/null 2>&1; then
    AUR_USER="mihai"
else
    echo "Creating temporary AUR build user..."
    useradd -m -G wheel -s /bin/bash aurbuilder
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-aur
    chmod 440 /etc/sudoers.d/99-aur
    AUR_USER="aurbuilder"
fi

# Remove conflicting yay variants quietly
for pkg in yay yay-bin yay-debug yay-bin-debug; do
    if pacman -Q "\$pkg" >/dev/null 2>&1; then
        echo "Removing conflicting package: \$pkg"
        pacman -Rns --noconfirm "\$pkg" || true
    fi
done

echo "Installing yay-bin as \$AUR_USER..."
runuser -u \$AUR_USER -- bash -c '
    git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
    cd /tmp/yay-bin
    makepkg -si --noconfirm
'

echo "Installing limine-snapper-sync and limine-mkinitcpio-hook..."
runuser -u \$AUR_USER -- bash -c '
    yay -S --noconfirm limine-snapper-sync limine-mkinitcpio-hook
'

echo "Running limine-install on /dev/$DISK..."
limine-install /dev/$DISK || true

echo "All packages installed successfully inside chroot."

# Clean up temporary AUR user if created
if [ "\$AUR_USER" = "aurbuilder" ]; then
    echo "Cleaning up temporary AUR user..."
    userdel -r aurbuilder || true
    rm -f /etc/sudoers.d/99-aur
fi

EOF




info "All operations completed successfully."

