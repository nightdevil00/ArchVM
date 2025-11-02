#!/usr/bin/env bash
set -euo pipefail

# ------------------------
# AUTO DETECTION
# ------------------------

# Detect EFI mount
EFI_MOUNT=$(findmnt -rn -t vfat | awk '{print $2; exit}')
if [[ -z "$EFI_MOUNT" ]]; then
    echo "❌ EFI partition not found. Mount your EFI partition first."
    exit 1
fi
echo "✅ EFI partition detected at $EFI_MOUNT"

# Detect root device
ROOT_DEVICE=$(findmnt -no SOURCE /)
if [[ -z "$ROOT_DEVICE" ]]; then
    echo "❌ Could not detect root device."
    exit 1
fi
echo "✅ Root device detected as $ROOT_DEVICE"

# Detect root UUID
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEVICE")
if [[ -z "$ROOT_UUID" ]]; then
    echo "❌ Could not detect root UUID."
    exit 1
fi
echo "✅ Root UUID: $ROOT_UUID"

# Detect latest kernel/initramfs
BOOT_DIR="/boot"
KERNEL_FILE=$(ls -1 $BOOT_DIR/vmlinuz-* | sort -V | tail -n1)
INITRAMFS_FILE=$(ls -1 $BOOT_DIR/initramfs-* | sort -V | tail -n1)

if [[ -z "$KERNEL_FILE" || -z "$INITRAMFS_FILE" ]]; then
    echo "❌ Could not detect kernel or initramfs in $BOOT_DIR"
    exit 1
fi
echo "✅ Kernel: $KERNEL_FILE"
echo "✅ Initramfs: $INITRAMFS_FILE"

# ------------------------
# WRITE LIMINE CONFIG
# ------------------------
echo "==> Writing limine.cfg..."
mkdir -p "$BOOT_DIR/limine"
cat > "$BOOT_DIR/limine/limine.cfg" <<EOF
TIMEOUT=5
DEFAULT_ENTRY=Linux

:Linux
PROTOCOL=linux
KERNEL_PATH=boot:///${KERNEL_FILE##*/} 
CMDLINE=root=UUID=$ROOT_UUID rw rootflags=subvol=@ loglevel=3 quiet splash
MODULE_PATH=boot:///${INITRAMFS_FILE##*/}
EOF

echo "✅ limine.cfg created at $BOOT_DIR/limine/limine.cfg"

# ------------------------
# INSTALL LIMINE TO EFI
# ------------------------
echo "==> Installing Limine..."
limine-install "$EFI_MOUNT"

# Copy configuration to EFI
cp -v "$BOOT_DIR/limine/limine.cfg" "$EFI_MOUNT/EFI/BOOT/"

# ------------------------
# CREATE EFI ENTRY
# ------------------------
BOOTDISK=$(findmnt -no SOURCE "$EFI_MOUNT" | sed 's/[0-9]*$//')
efibootmgr --create --disk "$BOOTDISK" --part 1 --label "Limine" --loader "\EFI\BOOT\limine.efi" || {
    echo "⚠️ EFI entry creation failed. Add manually in BIOS."
}

echo "✅ Limine installation complete and configured automatically!"

