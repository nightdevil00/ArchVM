#!/bin/bash
set -e

# --- Disk and Partition Selection ---
echo "Available disks:"
lsblk -d -n -o NAME,SIZE
read -p "Enter the name of the disk containing your Arch Linux installation (e.g., sda): " DISK

echo "Available partitions on /dev/$DISK:"
lsblk -n -o NAME,SIZE,TYPE /dev/$DISK
read -p "Enter the name of the root partition (e.g., ${DISK}p2): " ROOT_PARTITION
read -p "Enter the name of the EFI partition (e.g., ${DISK}p1): " EFI_PART

# --- LUKS Decryption ---
read -p "Is the root partition ($ROOT_PARTITION) encrypted with LUKS? (y/n): " IS_LUKS
LUKS_OPENED_BY_SCRIPT=false
if [ "$IS_LUKS" = "y" ]; then
    read -p "Enter a name for the unlocked LUKS container (e.g., cryptroot): " LUKS_NAME
    if [ -b "/dev/mapper/$LUKS_NAME" ]; then
        echo "LUKS container $LUKS_NAME already exists."
        ROOT_DEVICE="/dev/mapper/$LUKS_NAME"
    else
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
    echo "Mounting BTRFS subvolume..."
    mount -t btrfs -o subvol=$BTRFS_SUBVOLUME,compress=zstd "$ROOT_DEVICE" "$MOUNT_DIR"
else
    mount "$ROOT_DEVICE" "$MOUNT_DIR"
fi

# --- Mount EFI properly ---
mkdir -p "$MOUNT_DIR/boot"
mount "/dev/$EFI_PART" "$MOUNT_DIR/boot"

# Bind system dirs for chroot
mount --rbind /dev "$MOUNT_DIR/dev"
mount --rbind /proc "$MOUNT_DIR/proc"
mount --rbind /sys "$MOUNT_DIR/sys"
mount --make-rslave "$MOUNT_DIR/dev"
mount --make-rslave "$MOUNT_DIR/proc"
mount --make-rslave "$MOUNT_DIR/sys"

# --- Sanity Check ---
echo "=== SANITY CHECK ==="
lsblk -o NAME,MOUNTPOINT,FSTYPE,SIZE | grep -E "$DISK|$ROOT_PARTITION"
read -rp "Confirm that /mnt points to the correct root and /mnt/boot to EFI. Press Enter to continue or Ctrl+C to cancel."

# --- Chroot and Perform Actions ---
arch-chroot "$MOUNT_DIR" /bin/bash <<EOF
set -e

# --- Detect EFI automatically ---
ESP_PATH=""
for path in /boot/EFI /boot /efi; do
    if [ -d "\$path/EFI" ] || find "\$path" -maxdepth 1 -type d -iname "EFI" | grep -q .; then
        ESP_PATH="\$path"
        break
    fi
done
if [ -z "\$ESP_PATH" ]; then
    ESP_PATH="/boot"
    echo "Warning: Could not auto-detect ESP path. Defaulting to /boot."
else
    echo "Detected ESP path: \$ESP_PATH"
fi
mkdir -p /etc/default
echo "ESP_PATH=\$ESP_PATH" > /etc/default/limine

# --- Install base packages ---
pacman -Sy --noconfirm git base-devel sudo limine linux linux-headers nvidia nvidia-utils nvidia-settings

# --- Determine AUR user ---
if id -u mihai >/dev/null 2>&1; then
    AUR_USER="mihai"
else
    echo "Creating temporary AUR build user..."
    useradd -m -G wheel -s /bin/bash aurbuilder
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-aur
    chmod 440 /etc/sudoers.d/99-aur
    AUR_USER="aurbuilder"
fi

# --- Remove conflicting yay packages ---
for pkg in yay yay-bin yay-debug yay-bin-debug; do
    if pacman -Q "\$pkg" >/dev/null 2>&1; then
        echo "Removing conflicting package: \$pkg"
        pacman -Rns --noconfirm "\$pkg" || true
    fi
done

# --- Build yay-bin ---
runuser -u \$AUR_USER -- bash -c '
    git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
    cd /tmp/yay-bin
    makepkg -si --noconfirm
'

# --- Install limine AUR packages ---
runuser -u \$AUR_USER -- bash -c '
    yay -S --noconfirm limine-snapper-sync limine-mkinitcpio-hook
'

# --- Run Limine installer on correct disk ---
limine-install /dev/$DISK || true

# --- Cleanup temporary AUR user ---
if [ "\$AUR_USER" = "aurbuilder" ]; then
    userdel -r aurbuilder || true
    rm -f /etc/sudoers.d/99-aur
fi

EOF

# --- Unmount Filesystems ---
umount -R "$MOUNT_DIR"

if [ "$IS_LUKS" = "y" ] && [ "$LUKS_OPENED_BY_SCRIPT" = true ]; then
    cryptsetup close $LUKS_NAME
fi

echo "Chroot script finished successfully."
