#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Interactive Install Script
# Dualboot with Windows (preserves Windows EFI)
# Limine Bootloader (UEFI only)
# ==============================================================================

# --- Log setup ---
LOG_FILE="/tmp/arch_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging to $LOG_FILE"

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "❌ This script must be run in Bash. Try: bash $0"
  exit 1
fi

set -euo pipefail

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
  echo "❌ This script must be run as root."
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
declare -A PROTECTED_PARTS=()
echo "Scanning partitions for Windows..."

while IFS= read -r line; do
  eval "$line"
  [[ "${TYPE:-}" != "part" ]] && continue
  PART="/dev/${NAME}"
  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)
  if [[ "$FSTYPE" == vfat || "$FSTYPE" == fat32 || "$FSTYPE" == fat ]]; then
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/EFI/Microsoft" || -f "$TMP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
        PROTECTED_PARTS["$PART"]="Windows EFI found"
      fi
      umount "$TMP_MOUNT" || true
    fi
  elif [[ "$FSTYPE" == ntfs ]]; then
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/Windows" || -f "$TMP_MOUNT/bootmgr" ]]; then
        PROTECTED_PARTS["$PART"]="Windows NTFS found"
      fi
      umount "$TMP_MOUNT" || true
    fi
  fi
done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINT "$TARGET_DISK")

# --- Partitioning ---
if [[ ${#PROTECTED_PARTS[@]} -gt 0 ]]; then
  echo "✅ Windows partitions detected:"
  for k in "${!PROTECTED_PARTS[@]}"; do
    echo " - $k : ${PROTECTED_PARTS[$k]}"
  done
  echo
  echo "Free space on $TARGET_DISK will be used for Arch installation only."
  parted --script "$TARGET_DISK" unit GB print free
  read -rp "Enter EFI partition start (e.g. 1GB): " EFI_START
  read -rp "Enter EFI partition end (e.g. 3GB): " EFI_END
  read -rp "Enter ROOT partition start (e.g. 3GB): " ROOT_START
  read -rp "Enter ROOT partition end (e.g. 100%): " ROOT_END
  parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END"
  parted --script "$TARGET_DISK" set $(parted -s "$TARGET_DISK" print | awk '/^ /{n++; print n; exit}') esp on
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
sleep 2

# --- Detect new partitions ---
mapfile -t parts < <(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}')
efi_partition="${parts[-2]}"
root_partition="${parts[-1]}"
echo "EFI: $efi_partition, ROOT: $root_partition"

# --- Format and encrypt ---
mkfs.fat -F32 "$efi_partition"
cryptsetup luksFormat "$root_partition"
cryptsetup luksOpen "$root_partition" cryptroot

# --- Btrfs setup ---
mkfs.btrfs -f /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt
mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,boot}
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount "$efi_partition" /mnt/boot

# --- Base install ---
pacstrap /mnt base linux linux-firmware vim sudo networkmanager \
         btrfs-progs iwd git limine efibootmgr binutils

# --- Generate fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- User setup ---
read -rp "Username: " username
read -rsp "Password for $username: " user_pass; echo
read -rsp "Root password: " root_pass; echo

cat > /mnt/arch_install_vars.sh <<EOF
ROOT_PART="$root_partition"
USERNAME="$username"
USER_PASS="$user_pass"
ROOT_PASS="$root_pass"
EOF

# --- Chroot configuration ---
arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail
source /arch_install_vars.sh

# Locale & time
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "arch-linux" > /etc/hostname

# Users
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers

# Crypttab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
echo "cryptroot UUID=$ROOT_UUID none luks,discard" > /etc/crypttab

# Initramfs
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf keyboard keymap block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Swap
btrfs subvolume create /swap
btrfs filesystem mkswapfile --size 4g /swap/swapfile
swapon /swap/swapfile

# --- Limine setup (UEFI) ---
echo "[*] Installing Limine (UEFI)..."

mkdir -p /boot/EFI/{limine,Linux}
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

# Build EFI-stub kernels
echo "[*] Building EFI-stub kernel images..."
objcopy \
  --add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000 \
  --add-section .cmdline=/proc/cmdline --change-section-vma .cmdline=0x30000 \
  --add-section .linux=/boot/vmlinuz-linux --change-section-vma .linux=0x2000000 \
  --add-section .initrd=/boot/initramfs-linux.img --change-section-vma .initrd=0x3000000 \
  /usr/lib/systemd/boot/efi/linuxx64.efi.stub \
  /boot/EFI/Linux/arch-linux.efi

objcopy \
  --add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000 \
  --add-section .cmdline=/proc/cmdline --change-section-vma .cmdline=0x30000 \
  --add-section .linux=/boot/vmlinuz-linux --change-section-vma .linux=0x2000000 \
  --add-section .initrd=/boot/initramfs-linux-fallback.img --change-section-vma .initrd=0x3000000 \
  /usr/lib/systemd/boot/efi/linuxx64.efi.stub \
  /boot/EFI/Linux/arch-linux-fallback.efi

RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /swap/swapfile | awk '{print $1}')
RESUME_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)

cat > /boot/EFI/limine/limine.conf <<EOL
timeout: 5

/Arch Linux
    protocol: efi
    path: boot():/EFI/Linux/arch-linux.efi
    cmdline: cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ rootfstype=btrfs resume=UUID=$RESUME_UUID resume_offset=$RESUME_OFFSET

/Arch Linux (fallback)
    protocol: efi
    path: boot():/EFI/Linux/arch-linux-fallback.efi
    cmdline: cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ rootfstype=btrfs resume=UUID=$RESUME_UUID resume_offset=$RESUME_OFFSET
EOL

EFI_DEV=$(findmnt -no SOURCE /boot 2>/dev/null || true)
EFI_DEV="${EFI_DEV:-}"

DISK=$(lsblk -no pkname "$EFI_DEV" 2>/dev/null || true)
DISK="${DISK:-}"

PARTNO=$(lsblk -no partno "$EFI_DEV" 2>/dev/null || true)
PARTNO="${PARTNO:-}"

if [[ -n "$DISK" && -n "$PARTNO" ]]; then
  efibootmgr --create --disk "/dev/$DISK" --part "$PARTNO" \
      --label "Arch Linux (Limine)" \
      --loader '\EFI\limine\BOOTX64.EFI'
else
  echo "⚠️ Skipping efibootmgr — could not detect disk or partition number."
fi

echo "[+] Limine installation complete."

# Enable network
systemctl enable NetworkManager

rm -f /arch_install_vars.sh
EOF

# --- Cleanup ---
#umount -R /mnt
cryptsetup luksClose cryptroot
rm -rf "$TMP_MOUNT"

echo "✅ Installation complete. You can now reboot into Arch Linux via Limine."
