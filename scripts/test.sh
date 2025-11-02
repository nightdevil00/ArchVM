#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Interactive Install Script with Windows Dualboot support in free space and Limine bootloader
# ==============================================================================
# DISCLAIMER:
# This script is provided "as-is" for educational and personal use only.
# Use at your own risk. Review the script before running it.
# ==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

TMP_MOUNT="/mnt/__arch_install_tmp"
mkdir -p "$TMP_MOUNT"

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
  echo "No block devices found. Exiting."
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
  echo "Invalid selection. Exiting."
  exit 1
fi

TARGET_DISK="${DEVICES[$((disk_number-1))]}"
echo "You selected: $TARGET_DISK"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$TARGET_DISK"

echo
echo "Scanning all partitions on all disks for Windows boot files / EFI Microsoft..."
declare -a PROTECTED_PART_KEYS=()
declare -a PROTECTED_PART_VALUES=()

while IFS= read -r line; do
  eval "$line"
  if [[ "${TYPE:-}" != "part" ]]; then
    continue
  fi
  PART="/dev/${NAME}"
  if [[ "$PART" =~ loop|sr|md ]]; then
    continue
  fi

  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)

  if [[ "$FSTYPE" == "vfat" || "$FSTYPE" == "fat32" ]]; then
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/EFI/Microsoft" ]]; then
        PROTECTED_PART_KEYS+=("$PART")
        PROTECTED_PART_VALUES+=("EFI Microsoft files found")
        echo "Protected (EFI): $PART -> EFI Microsoft files found"
      fi
      umount "$TMP_MOUNT" || true
    fi
  fi

  if [[ "$FSTYPE" == "ntfs" ]]; then
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/Windows" ]]; then
        PROTECTED_PART_KEYS+=("$PART")
        PROTECTED_PART_VALUES+=("NTFS Windows files found")
        echo "Protected (NTFS): $PART -> NTFS Windows files found"
      fi
      umount "$TMP_MOUNT" || true
    fi
  fi
done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINT)

if [ ${#PROTECTED_PART_KEYS[@]} -gt 0 ]; then
  echo
  echo "Detected Windows partitions, they will NOT be modified."
  parted --script "$TARGET_DISK" unit GB print free || true
  echo
  echo "Provide partition positions for new Arch install within free space."
  read -rp "EFI start (e.g. 1GB): " EFI_START
  read -rp "EFI end (e.g. 3GB): " EFI_END
  read -rp "Root start (e.g. 3GB): " ROOT_START
  read -rp "Root end (e.g. 100%): " ROOT_END

  parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END"
  parted --script "$TARGET_DISK" set $(parted -s "$TARGET_DISK" print | awk '/^ /{n++; print n; exit}') boot on || true
  parted --script "$TARGET_DISK" mkpart primary btrfs "$ROOT_START" "$ROOT_END"

  partprobe "$TARGET_DISK" || true
  sleep 1
  parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
  efi_partition="${parts[-2]}"
  root_partition="${parts[-1]}"
else
  echo "No Windows partitions detected."
  read -rp "Wipe and use entire $TARGET_DISK for Arch? (yes/no): " yn
  if [[ "$yn" != "yes" ]]; then
    exit 0
  fi

  parted --script "$TARGET_DISK" mklabel gpt
  parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
  parted --script "$TARGET_DISK" set 1 boot on
  parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
  partprobe "$TARGET_DISK" || true

  parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
  efi_partition="${parts[0]}"
  root_partition="${parts[1]}"
fi

if [[ -z "${efi_partition:-}" || -z "${root_partition:-}" ]]; then
  echo "Couldn't determine new partition paths."
  exit 1
fi

mkfs.fat -F32 "$efi_partition"

echo "Encrypting root partition..."
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

pacstrap /mnt base linux linux-firmware linux-headers iwd networkmanager vim nano sudo limine efibootmgr btrfs-progs snapper

genfstab -U /mnt >> /mnt/etc/fstab

ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$root_partition")
echo "$ROOT_PARTUUID" > /mnt/ROOT_PARTUUID

read -rp "New username: " username
read -rsp "Password for $username: " user_password; echo
read -rsp "Root password: " root_password; echo

efi_partition_number=$(cat "/sys/class/block/$(basename "$efi_partition")/partition")

cat > /mnt/arch_install_vars.sh <<EOF
ROOT_PART="$root_partition"
EFI_DISK="$TARGET_DISK"
EFI_PART_NUM="$efi_partition_number"
USERNAME="$username"
USER_PASS="$user_password"
ROOT_PASS="$root_password"
EOF

arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail
source /arch_install_vars.sh

ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")

ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "arch-linux" > /etc/hostname

echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers

echo "cryptroot PARTUUID=$ROOT_PARTUUID none luks,discard" > /etc/crypttab

sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
cp /usr/share/limine/BOOTIA32.EFI /boot/EFI/limine/
mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI

efibootmgr --create --disk "$EFI_DISK" --part "$EFI_PART_NUM" --label "Arch Linux (Limine)" --loader /EFI/limine/BOOTX64.EFI --unicode

# ✅ FIXED LIMINE CONFIG SECTION
echo "Generating Limine configuration..."
cat > /boot/limine.conf <<EOC
TIMEOUT=5
DEFAULT_ENTRY=Arch Linux

:Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    INITRD_PATH=boot:///initramfs-linux.img
    CMDLINE=root=PARTUUID=${ROOT_PARTUUID} rootflags=subvol=@ rw cryptdevice=PARTUUID=${ROOT_PARTUUID}:cryptroot quiet splash
EOC

echo 'AUTO_UPDATE_LIMINE_CONF=no' > /etc/default/limine

# Optional Snapper setup
if ! snapper list-configs 2>/dev/null | grep -q "root"; then
  snapper -c root create-config /
fi
if ! snapper list-configs 2>/dev/null | grep -q "home"; then
  snapper -c home create-config /home
fi
sed -i 's/^TIMELINE_CREATE="yes"/TIMELINE_CREATE="no"/' /etc/snapper/configs/{root,home}
sed -i 's/^NUMBER_LIMIT="50"/NUMBER_LIMIT="5"/' /etc/snapper/configs/{root,home}

systemctl enable NetworkManager

rm -f /arch_install_vars.sh
EOF

echo
echo "✅ Installation complete!"
echo "You can now reboot. Windows (if detected) was preserved, and Limine will boot Arch Linux properly."
