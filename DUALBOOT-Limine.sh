#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Interactive Install Script with Windows Dualboot support in free space and Limine bootloader
# ==============================================================================
# DISCLAIMER: Use at your own risk. This script will erase data if you select full disk.
# ==============================================================================

set -euo pipefail

TMP_MOUNT="/mnt/__arch_install_tmp"
mkdir -p "$TMP_MOUNT"

# Helper: list disks
declare -a DEVICES=()
declare -A DEV_MODEL DEV_SIZE DEV_TRAN DEV_MOUNT

while IFS= read -r line; do
    eval "$line"
    if [[ "${TYPE:-}" == "disk" ]]; then
        devpath="/dev/${NAME}"
        DEVICES+=("$devpath")
        DEV_MODEL["$devpath"]="${MODEL:-unknown}"
        DEV_SIZE["$devpath"]="${SIZE:-unknown}"
        DEV_TRAN["$devpath"]="${TRAN:-unknown}"
        DEV_MOUNT["$devpath"]="${MOUNTPOINT:-}"
    fi
done < <(lsblk -P -o NAME,KNAME,TYPE,SIZE,MODEL,TRAN,MOUNTPOINT)

if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "No block devices found."
    exit 1
fi

echo "Available physical disks:"
for i in "${!DEVICES[@]}"; do
    idx=$((i+1))
    d=${DEVICES[$i]}
    printf "%2d) %-12s  %8s  %-10s  transport=%s\n" \
        "$idx" "$d" "${DEV_SIZE[$d]}" "${DEV_MODEL[$d]}" "${DEV_TRAN[$d]}"
done

read -rp $'Enter the number of the disk for Arch installation (e.g., 1): ' disk_number
if ! [[ "$disk_number" =~ ^[0-9]+$ ]] || (( disk_number < 1 || disk_number > ${#DEVICES[@]} )); then
    echo "Invalid selection."
    exit 1
fi

TARGET_DISK="${DEVICES[$((disk_number-1))]}"
echo "You selected: $TARGET_DISK"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$TARGET_DISK"

# --- Windows detection ---
echo
echo "Scanning all partitions on all disks for Windows boot files / EFI Microsoft..."
declare -A PROTECTED_PARTS=()  # ⚠ must initialize for set -u

while IFS= read -r line; do
    eval "$line"
    if [[ "${TYPE:-}" != "part" ]]; then
        continue
    fi
    PART="/dev/${NAME}"
    FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)

    if [[ "$FSTYPE" =~ fat|vfat ]]; then
        mkdir -p "$TMP_MOUNT"
        if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
            if [[ -d "$TMP_MOUNT/EFI/Microsoft" ]] || [[ -f "$TMP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
                PROTECTED_PARTS["$PART"]="EFI Microsoft detected"
                echo "Protected (EFI): $PART -> ${PROTECTED_PARTS[$PART]}"
            fi
            umount "$TMP_MOUNT" || true
        fi
    fi

    if [[ "$FSTYPE" == "ntfs" ]]; then
        mkdir -p "$TMP_MOUNT"
        if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
            if [[ -d "$TMP_MOUNT/Windows" ]] || [[ -f "$TMP_MOUNT/bootmgr" ]]; then
                PROTECTED_PARTS["$PART"]="Windows NTFS detected"
                echo "Protected (NTFS): $PART -> ${PROTECTED_PARTS[$PART]}"
            fi
            umount "$TMP_MOUNT" || true
        fi
    fi
done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINT)

# Decide partitioning method
if [ ${#PROTECTED_PARTS[@]} -gt 0 ]; then
    echo
    echo "Detected Windows partitions, script will only use free space."
    parted --script "$TARGET_DISK" unit GB print free
    read -rp "EFI start (e.g., 1GB): " EFI_START
    read -rp "EFI end   (e.g., 3GB): " EFI_END
    read -rp "Root start (e.g., 3GB): " ROOT_START
    read -rp "Root end   (e.g., 100%): " ROOT_END

    parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END"
    parted --script "$TARGET_DISK" set $(parted -s "$TARGET_DISK" print | awk '/^ /{n++; print n; exit}') boot on
    parted --script "$TARGET_DISK" mkpart primary btrfs "$ROOT_START" "$ROOT_END"
    partprobe "$TARGET_DISK" || true
else
    read -rp "No Windows detected. Use full disk? (yes/no): " yn
    if [[ "$yn" != "yes" ]]; then
        echo "Aborting."
        exit 0
    fi
    parted --script "$TARGET_DISK" mklabel gpt
    parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
    parted --script "$TARGET_DISK" set 1 boot on
    parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
    partprobe "$TARGET_DISK" || true
fi

# Determine EFI and root partitions
sleep 1
parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
efi_partition="${parts[-2]}"
root_partition="${parts[-1]}"
echo "EFI: $efi_partition  ROOT: $root_partition"

# Format EFI and setup root LUKS+BTRFS
mkfs.fat -F32 "$efi_partition"
cryptsetup luksFormat "$root_partition"
cryptsetup luksOpen "$root_partition" cryptroot
mkfs.btrfs -f /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
mkdir -p /mnt/boot
mount "$efi_partition" /mnt/boot

# Pacstrap base system
pacstrap /mnt base linux linux-firmware linux-headers vim sudo btrfs-progs iwd networkmanager efibootmgr git

# Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Save variables for chroot
read -rp "New username: " username
read -rsp "Password for $username: " user_password; echo
read -rsp "Root password: " root_password; echo

cat > /mnt/arch_install_vars.sh <<EOF
ROOT_PART="$root_partition"
USERNAME="$username"
USER_PASS="$user_password"
ROOT_PASS="$root_password"
EOF

# Chroot for config & Limine installation
arch-chroot /mnt /bin/bash <<'CHROOT_EOF'
set -euo pipefail
source /arch_install_vars.sh

# Get UUIDs automatically
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# Timezone & locale
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname & users
echo "arch-linux" > /etc/hostname
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers

# Crypttab
echo "cryptroot UUID=$ROOT_UUID none luks,discard" > /etc/crypttab

# Mkinitcpio hooks
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install Limine bootloader
pacman -Sy --noconfirm limine
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

# Create Limine config automatically
RESUME_UUID=$(findmnt -no UUID -T /swap/swapfile || true)
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /swap/swapfile || true)

cat > /boot/EFI/limine/limine.conf <<CONF
timeout: 3

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ rootfstype=btrfs resume=UUID=$RESUME_UUID resume_offset=$RESUME_OFFSET
    module_path: boot():/initramfs-linux.img
/Arch Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ rootfstype=btrfs resume=UUID=$RESUME_UUID resume_offset=$RESUME_OFFSET
    module_path: boot():/initramfs-linux-fallback.img
CONF

# Add EFI boot entry
efibootmgr --create --disk $(lsblk -no PKNAME $ROOT_PART | head -1) --part 1 \
    --label "Arch Linux Limine Bootloader" \
    --loader '\EFI\limine\BOOTX64.EFI' --unicode

# Enable NetworkManager
systemctl enable NetworkManager

# Cleanup
rm -f /arch_install_vars.sh
CHROOT_EOF

echo
echo "Installation complete. Review above logs and reboot."

