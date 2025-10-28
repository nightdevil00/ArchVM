#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Interactive Install Script with Windows Dualboot & Limine Bootloader
# ==============================================================================

set -euo pipefail

# --- Color definitions ---
C_RESET="\033[0m"
C_RED="\033[1;31m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_CYAN="\033[1;36m"
C_WHITE="\033[1;37m"

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
  echo -e "${C_RED}This script must be run as root.${C_RESET}"
  exit 1
fi

TMP_MOUNT="/mnt/__arch_install_tmp"
mkdir -p "$TMP_MOUNT"

# --- Enumerate disks ---
declare -a DEVICES=()
declare -A DEV_MODEL DEV_SIZE DEV_TRAN

while IFS= read -r line; do
  eval "$line"
  if [[ "${TYPE:-}" == "disk" ]]; then
    devpath="/dev/${NAME}"
    DEVICES+=("$devpath")
    DEV_MODEL["$devpath"]="${MODEL:-unknown}"
    DEV_SIZE["$devpath"]="${SIZE:-unknown}"
    DEV_TRAN["$devpath"]="${TRAN:-unknown}"
  fi
done < <(lsblk -P -o NAME,TYPE,SIZE,MODEL,TRAN)

if [ ${#DEVICES[@]} -eq 0 ]; then
  echo -e "${C_RED}No block devices found.${C_RESET}"
  exit 1
fi

echo -e "${C_WHITE}Available disks:${C_RESET}"
for i in "${!DEVICES[@]}"; do
  d=${DEVICES[$i]}
  printf "%2d) %-12s  %8s  %-10s  transport=%s\n" \
    "$((i+1))" "$d" "${DEV_SIZE[$d]}" "${DEV_MODEL[$d]}" "${DEV_TRAN[$d]}"
done

read -rp $'\nSelect the disk for Arch installation: ' disk_number
if ! [[ "$disk_number" =~ ^[0-9]+$ ]] || (( disk_number < 1 || disk_number > ${#DEVICES[@]} )); then
  echo -e "${C_RED}Invalid selection.${C_RESET}"
  exit 1
fi

TARGET_DISK="${DEVICES[$((disk_number-1))]}"
echo -e "${C_GREEN}Selected:${C_RESET} $TARGET_DISK"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$TARGET_DISK"

# --- Reflector (fastest mirrors) ---
echo
echo -e "${C_CYAN}Refreshing mirrorlist with fastest servers...${C_RESET}"
pacman -Sy --noconfirm reflector
reflector --country "$(curl -s https://ipapi.co/country_name || echo Worldwide)" --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
echo -e "${C_GREEN}Mirrorlist updated successfully.${C_RESET}"

# --- Windows detection ---
echo
echo -e "${C_WHITE}Scanning for Windows partitions...${C_RESET}"
declare -a PROTECTED_PARTS=()

while IFS= read -r line; do
  eval "$line"
  [[ "${TYPE:-}" != "part" ]] && continue
  PART="/dev/${NAME}"
  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)

  if [[ "$FSTYPE" =~ ^(vfat|fat32|fat)$ ]]; then
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/EFI/Microsoft" ]]; then
        echo -e "${C_YELLOW}Protected:${C_RESET} $PART (EFI Microsoft detected)"
        PROTECTED_PARTS+=("$PART")
      fi
      umount "$TMP_MOUNT" || true
    fi
  elif [[ "$FSTYPE" == "ntfs" ]]; then
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/Windows" ]]; then
        echo -e "${C_YELLOW}Protected:${C_RESET} $PART (Windows detected)"
        PROTECTED_PARTS+=("$PART")
      fi
      umount "$TMP_MOUNT" || true
    fi
  fi
done < <(lsblk -P -o NAME,TYPE,FSTYPE)

# --- If Windows detected ---
if [ ${#PROTECTED_PARTS[@]} -gt 0 ]; then
  echo
  echo -e "${C_WHITE}Windows detected. Using available free space only.${C_RESET}"
  echo
  echo -e "${C_CYAN}Partition table for $TARGET_DISK:${C_RESET}"
  echo -e "${C_WHITE}───────────────────────────────────────────────${C_RESET}"
  parted --script "$TARGET_DISK" unit GB print free | \
    sed -E "s/(Free Space)/${C_YELLOW}\1${C_RESET}/"
  echo -e "${C_WHITE}───────────────────────────────────────────────${C_RESET}"

  # Auto-detect first free block
  FREE_LINE=$(parted --script "$TARGET_DISK" unit GB print free | grep "Free Space" | head -n 1)
  if [[ -z "$FREE_LINE" ]]; then
    echo -e "${C_RED}No free space available!${C_RESET}"
    exit 1
  fi

  FREE_START=$(echo "$FREE_LINE" | awk '{print $1}' | tr -d 'GB')
  FREE_END=$(echo "$FREE_LINE" | awk '{print $2}' | tr -d 'GB')
  FREE_SIZE=$(echo "$FREE_LINE" | awk '{print $3}' | tr -d 'GB')
  echo
  echo -e "Detected free space: ${C_YELLOW}${FREE_START}GB → ${FREE_END}GB (${FREE_SIZE}GB)${C_RESET}"

  # Suggested layout
  EFI_START="${FREE_START}GB"
  EFI_END=$(awk -v s="$FREE_START" 'BEGIN{printf "%.2fGB", s+2}')
  ROOT_START="$EFI_END"
  ROOT_END_DEFAULT="100%"

  echo
  echo -e "Suggested partitions:"
  echo -e "  • EFI : ${C_CYAN}${EFI_START}${C_RESET} → ${C_CYAN}${EFI_END}${C_RESET} (2GB)"
  echo -e "  • ROOT: ${C_CYAN}${ROOT_START}${C_RESET} → ${C_CYAN}${ROOT_END_DEFAULT}${C_RESET}"
  echo
  read -rp "Use entire free space for root? (yes/no): " use_all

  if [[ "$use_all" =~ ^[Nn][Oo]?$ ]]; then
    read -rp "Enter ROOT end (e.g., 60GB, min 30GB): " ROOT_END_CUSTOM
    ROOT_END_VAL=$(echo "$ROOT_END_CUSTOM" | tr -d 'GB')
    if (( $(echo "$ROOT_END_VAL < 30" | bc -l) )); then
      echo -e "${C_RED}Root must be ≥ 30GB.${C_RESET}"
      exit 1
    fi
    ROOT_END="$ROOT_END_CUSTOM"
  else
    ROOT_END="$ROOT_END_DEFAULT"
  fi

  echo
  echo -e "${C_YELLOW}Summary:${C_RESET}"
  echo "  EFI : $EFI_START → $EFI_END"
  echo "  ROOT: $ROOT_START → $ROOT_END"
  read -rp "Proceed? (yes/no): " confirm
  [[ "$confirm" != "yes" ]] && exit 0

  echo "Creating partitions..."
  parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END"
  parted --script "$TARGET_DISK" set 1 boot on || true
  parted --script "$TARGET_DISK" mkpart primary btrfs "$ROOT_START" "$ROOT_END"
  partprobe "$TARGET_DISK"

  sleep 1
  parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
  efi_partition="${parts[-2]}"
  root_partition="${parts[-1]}"
else
  echo
  echo -e "${C_WHITE}No Windows detected. Using full disk.${C_RESET}"
  read -rp "Erase all data on $TARGET_DISK and install Arch? (yes/no): " confirm
  [[ "$confirm" != "yes" ]] && exit 0

  parted --script "$TARGET_DISK" mklabel gpt
  parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
  parted --script "$TARGET_DISK" set 1 boot on
  parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
  partprobe "$TARGET_DISK"
  parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
  efi_partition="${parts[0]}"
  root_partition="${parts[1]}"
fi

echo -e "${C_GREEN}EFI partition:${C_RESET} $efi_partition"
echo -e "${C_GREEN}ROOT partition:${C_RESET} $root_partition"

# --- Filesystem setup ---
mkfs.fat -F32 "$efi_partition"
cryptsetup luksFormat "$root_partition"
cryptsetup luksOpen "$root_partition" cryptroot
mkfs.btrfs -f /dev/mapper/cryptroot

# Subvolumes
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
mkdir -p /mnt/boot
mount "$efi_partition" /mnt/boot

# --- Install base ---
pacstrap /mnt base linux linux-firmware linux-headers networkmanager vim nano sudo limine efibootmgr btrfs-progs

# --- fstab ---
genfstab -U /mnt >> /mnt/etc/fstab
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$root_partition")

# --- Hostname ---
read -rp "Enter system hostname: " hostname
echo "$hostname" > /mnt/etc/hostname

# --- Limine config ---
cat > /mnt/boot/limine.conf <<EOF
TIMEOUT=5
DEFAULT_ENTRY=1

:Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    INITRD_PATH=boot:///initramfs-linux.img
    CMDLINE=root=PARTUUID=${ROOT_PARTUUID} rootflags=subvol=@ rw cryptdevice=PARTUUID=${ROOT_PARTUUID}:cryptroot
EOF

# --- User setup ---
read -rp "New username: " username
read -rsp "Password for $username: " user_password; echo
read -rsp "Root password: " root_password; echo

efi_partition_number=$(cat "/sys/class/block/$(basename "$efi_partition")/partition")

# Pass vars into chroot
cat > /mnt/arch_install_vars.sh <<EOF
ROOT_PART="$root_partition"
EFI_DISK="$TARGET_DISK"
EFI_PART_NUM="$efi_partition_number"
USERNAME="$username"
USER_PASS="$user_password"
ROOT_PASS="$root_password"
EOF

# --- chroot ---
arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail
source /arch_install_vars.sh
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")

ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers

echo "cryptroot PARTUUID=$ROOT_PARTUUID none luks,discard" > /etc/crypttab
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Limine install
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
efibootmgr --create --disk "$EFI_DISK" --part "$EFI_PART_NUM" --label "Arch Linux (Limine)" --loader /EFI/limine/BOOTX64.EFI --unicode

mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI

systemctl enable NetworkManager
rm -f /arch_install_vars.sh
EOF

# --- Final steps ---
echo
echo -e "${C_GREEN}✅ Installation complete!${C_RESET}"
echo
echo -e "The system is ready to boot."
echo -e "Would you like to enter the installed system (chroot) before rebooting?"
read -rp "Enter chroot now? [y/N]: " enter_chroot

if [[ "$enter_chroot" =~ ^[Yy]$ ]]; then
  echo
  echo -e "${C_CYAN}Mounting and entering chroot...${C_RESET}"
  mount --bind /dev /mnt/dev
  mount --bind /sys /mnt/sys
  mount --bind /proc /mnt/proc
  arch-chroot /mnt
  echo
  echo -e "${C_YELLOW}Exiting chroot. You can reboot when ready.${C_RESET}"
else
  echo
  echo -e "${C_CYAN}Skipping manual chroot.${C_RESET}"
fi

echo
read -rp "Would you like to reboot now? [Y/n]: " reboot_choice
if [[ ! "$reboot_choice" =~ ^[Nn]$ ]]; then
  echo -e "${C_GREEN}Rebooting...${C_RESET}"
  umount -R /mnt
  reboot
else
  echo -e "${C_YELLOW}Installation complete. You can reboot later manually.${C_RESET}"
fi
