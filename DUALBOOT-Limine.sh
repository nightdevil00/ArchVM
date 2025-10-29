#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Interactive Install Script with Windows Dualboot support in free space
# and Limine bootloader (UEFI only)
# ==============================================================================
set -euo pipefail

# check root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

TMP_MOUNT="/mnt/__arch_install_tmp"
mkdir -p "$TMP_MOUNT"

# --- List available disks ---
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

echo "Available physical disks:"
for i in "${!DEVICES[@]}"; do
  idx=$((i+1))
  d=${DEVICES[$i]}
  printf "%2d) %-12s  %8s  %-10s  transport=%s\n" \
    "$idx" "$d" "${DEV_SIZE[$d]}" "${DEV_MODEL[$d]}" "${DEV_TRAN[$d]}"
done

read -rp $'Enter the number of the disk for Arch installation (e.g., 1): ' disk_number
TARGET_DISK="${DEVICES[$((disk_number-1))]}"
echo "Selected: $TARGET_DISK"

# --- Windows detection ---
declare -A PROTECTED_PARTS
echo "Scanning partitions for Windows..."
while IFS= read -r line; do
  eval "$line"
  [[ "${TYPE:-}" != "part" ]] && continue
  PART="/dev/${NAME}"
  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)
  if [[ "$FSTYPE" == vfat || "$FSTYPE" == fat32 || "$FSTYPE" == fat ]]; then
    mkdir -p "$TMP_MOUNT"
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      [[ -d "$TMP_MOUNT/EFI/Microsoft" || -f "$TMP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]] && PROTECTED_PARTS["$PART"]="Windows EFI found"
      umount "$TMP_MOUNT"
    fi
  elif [[ "$FSTYPE" == ntfs ]]; then
    mkdir -p "$TMP_MOUNT"
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      [[ -d "$TMP_MOUNT/Windows" || -f "$TMP_MOUNT/bootmgr" ]] && PROTECTED_PARTS["$PART"]="Windows NTFS found"
      umount "$TMP_MOUNT"
    fi
  fi
done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINT "$TARGET_DISK")

if [[ ${#PROTECTED_PARTS[@]} -gt 0 ]]; then
  echo "Windows partitions detected, free space will be used for Arch installation only."
  parted --script "$TARGET_DISK" unit GB print free
  read -rp "EFI start (e.g. 1GB): " EFI_START
  read -rp "EFI end (e.g. 3GB): " EFI_END
  read -rp "Root start (e.g. 3GB): " ROOT_START
  read -rp "Root end (e.g. 100%): " ROOT_END
  parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END"
  parted --script "$TARGET_DISK" set $(parted -s "$TARGET_DISK" print | awk '/^ /{n++; print n; exit}') boot on
  parted --script "$TARGET_DISK" mkpart primary btrfs "$ROOT_START" "$ROOT_END"
else
  read -rp "Use full disk $TARGET_DISK? (yes/no): " yn
  [[ "$yn" != "yes" ]] && exit 0
  parted --script "$TARGET_DISK" mklabel gpt
  parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
  parted --script "$TARGET_DISK" set 1 boot on
  parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
fi

partprobe "$TARGET_DISK" || true
sleep 1
parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
efi_partition="${parts[-2]}"
root_partition="${parts[-1]}"
echo "EFI: $efi_partition, ROOT: $root_partition"

# Format EFI
mkfs.fat -F32 "$efi_partition"

# Encrypt root
cryptsetup luksFormat "$root_partition"
cryptsetup luksOpen "$root_partition" cryptroot

# BTRFS and subvolumes
mkfs.btrfs -f /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt
mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home /mnt/.snapshots
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mkdir -p /mnt/boot
mount "$efi_partition" /mnt/boot

# Pacstrap
pacstrap /mnt base linux linux-firmware vim sudo networkmanager btrfs-progs iwd git limine

# Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Save passwords for chroot
read -rp "Username: " username
read -rsp "Password for $username: " user_pass; echo
read -rsp "Root password: " root_pass; echo

cat > /mnt/arch_install_vars.sh <<EOF
ROOT_PART="$root_partition"
USERNAME="$username"
USER_PASS="$user_pass"
ROOT_PASS="$root_pass"
EOF

# Chroot
arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail
source /arch_install_vars.sh

# Timezone / locale
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "arch-linux" > /etc/hostname

# Root / user
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers

# Crypttab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
echo "cryptroot UUID=$ROOT_UUID none luks,discard" > /etc/crypttab

# Initramfs hooks
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Create swap subvolume
btrfs subvolume create /swap
btrfs filesystem mkswapfile --size 4g /swap/swapfile
swapon -p 0 /swap/swapfile

# Limine setup
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /swap/swapfile | awk '{print $1}')
RESUME_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)

cat > /boot/EFI/limine/limine.conf <<EOL
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
EOL

# Add EFI entry
efibootmgr --create --disk "$ROOT_PART" --part 1 --label "Arch Linux Limine Bootloader" --loader '\EFI\limine\BOOTX64.EFI' --unicode

# Enable NetworkManager
systemctl enable NetworkManager

rm -f /arch_install_vars.sh
EOF

echo "Installation complete. Reboot now!"
