#!/usr/bin/env bash
set -euo pipefail

# ------------------------
# CONFIGURATION
# ------------------------
EFI_MOUNT="/boot"          # Mount point of EFI partition
ROOT_DEVICE="/dev/mapper/cryptroot"  # Your encrypted Btrfs root device
ROOT_MOUNT="/mnt"          # Where your system is mounted (for chroot)
TIMEOUT=5

# ------------------------
# CHECKS
# ------------------------
if [[ ! -d "$EFI_MOUNT" ]]; then
    echo "❌ EFI mount point not found: $EFI_MOUNT"
    exit 1
fi

if [[ ! -b "$ROOT_DEVICE" ]]; then
    echo "❌ Root device not found: $ROOT_DEVICE"
    exit 1
fi

# ------------------------
# CREATE LIMINE CONFIG
# ------------------------
echo "==> Writing Limine configuration..."
mkdir -p "$ROOT_MOUNT/boot/limine"
cat > "$ROOT_MOUNT/boot/limine/limine.cfg" <<EOF
TIMEOUT=$TIMEOUT
DEFAULT_ENTRY=Linux

:Linux
PROTOCOL=linux
KERNEL_PATH=boot:///vmlinuz-linux
CMDLINE=root=$ROOT_DEVICE rw rootflags=subvol=@ loglevel=3 quiet splash
MODULE_PATH=boot:///initramfs-linux.img
EOF

# ------------------------
# INSTALL LIMINE TO EFI
# ------------------------
echo "==> Installing Limine bootloader to EFI..."
mkdir -p "$EFI_MOUNT/EFI/BOOT"
limine-install "$EFI_MOUNT"

# ------------------------
# COPY CONFIG TO EFI
# ------------------------
cp -v "$ROOT_MOUNT/boot/limine/limine.cfg" "$EFI_MOUNT/EFI/BOOT/"

# ------------------------
# INSTALL EFI ENTRY (optional)
# ------------------------
BOOTDISK=$(findmnt -no SOURCE "$EFI_MOUNT" | sed 's/[0-9]*$//')
efibootmgr --create --disk "$BOOTDISK" --part 1 --label "Limine" --loader "\EFI\BOOT\limine.efi" || {
    echo "⚠️ EFI entry creation failed, add manually in BIOS if needed."
}

echo "✅ Limine configured successfully!"
echo "Check $ROOT_MOUNT/boot/limine/limine.cfg for kernel/initramfs paths."

