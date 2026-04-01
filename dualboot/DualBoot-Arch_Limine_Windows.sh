#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Full Installer – Dualboot + Limine + Encryption + Snapper + Plymouth
# Production-Ready Version (2025)
# ==============================================================================
# Features:
#  - Dual-boot aware (detects Windows)
#  - LUKS2 full disk encryption
#  - Btrfs with subvolumes (@, @home, @snapshots, @log, @swap)
#  - Snapper, Plymouth, zram, Limine bootloader
#  - Configurable hostname/locale/timezone
#  - Safe defaults, strong validation, modular design
#  - Optional non-interactive mode via environment variables (AUTO_* vars)
# ==============================================================================

set -euo pipefail
trap 'cleanup' EXIT

# ==============================================================================
# Configuration (customize or override with env vars)
# ==============================================================================
HOSTNAME=${HOSTNAME:-arch}
LOCALE=${LOCALE:-en_US.UTF-8}
TIMEZONE=${TIMEZONE:-UTC}
SWAP_SIZE=${SWAP_SIZE:-4G}

LOG_FILE="/tmp/arch_install_$(date +%Y%m%d_%H%M%S).log"
TMP_MOUNT="/mnt/__tmp"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "📘 Logging to: $LOG_FILE"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

mkdir -p "$TMP_MOUNT"

TARGET_DISK=""
EFI_DEV=""
ROOT_DEV=""
LUKS_UUID=""
ROOT_UUID=""
RESUME_OFFSET=""

# ==============================================================================
# Cleanup handler
# ==============================================================================
cleanup() {
  echo "🧹 Cleaning up..."
  umount -R /mnt 2>/dev/null || true
  umount "$TMP_MOUNT" 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  cryptsetup luksClose root 2>/dev/null || true
  rm -rf "$TMP_MOUNT"
}

# ==============================================================================
# Disk selection
# ==============================================================================
select_disk() {
  if [[ -n "${AUTO_DISK:-}" ]]; then
    TARGET_DISK="$AUTO_DISK"
    echo "⚙️  Using AUTO_DISK=$TARGET_DISK"
    return
  fi

  declare -a DEVICES=()
  declare -A DEV_MODEL DEV_SIZE DEV_TRAN

  while IFS= read -r line; do
    eval "$line"
    [[ "${TYPE:-}" == "disk" ]] || continue
    devpath="/dev/${NAME}"
    DEVICES+=("$devpath")
    DEV_MODEL["$devpath"]="${MODEL:-unknown}"
    DEV_SIZE["$devpath"]="${SIZE:-unknown}"
    DEV_TRAN["$devpath"]="${TRAN:-unknown}"
  done < <(lsblk -P -o NAME,TYPE,SIZE,MODEL,TRAN)

  echo "Available disks:"
  for i in "${!DEVICES[@]}"; do
    printf " %2d) %-12s %8s  %-15s [%s]\n" \
      "$((i+1))" "${DEVICES[i]}" "${DEV_SIZE[${DEVICES[i]}]}" \
      "${DEV_MODEL[${DEVICES[i]}]}" "${DEV_TRAN[${DEVICES[i]}]}"
  done

  read -rp "Select disk number: " num
  [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#DEVICES[@]} )) || { echo "Invalid choice."; exit 1; }
  TARGET_DISK="${DEVICES[$((num-1))]}"
  echo "Selected: $TARGET_DISK"
}

# ==============================================================================
# Detect Windows / Partition disk
# ==============================================================================
partition_disk() {
  local PROTECTED=0

  while IFS= read -r line; do
    eval "$line"
    [[ "${TYPE:-}" != "part" ]] && continue
    PART="/dev/${NAME}"
    FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)
    if [[ "$FSTYPE" =~ ^(vfat|fat32|ntfs)$ ]] && mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      [[ -d "$TMP_MOUNT/EFI/Microsoft" || -d "$TMP_MOUNT/Windows" ]] && PROTECTED=1
      umount "$TMP_MOUNT" 2>/dev/null || true
    fi
  done < <(lsblk -P -o NAME,TYPE "$TARGET_DISK")

  if (( PROTECTED )); then
    echo "💠 Windows detected → using free space"
    parted --script "$TARGET_DISK" unit GB print free
    read -rp "EFI start (e.g. 1GB): " EFI_START
    read -rp "EFI end   (e.g. 3GB): " EFI_END
    read -rp "Root start (e.g. 3GB): " ROOT_START
    read -rp "Root end   (e.g. 100%): " ROOT_END

    for var in EFI_START EFI_END ROOT_START ROOT_END; do
      [[ ${!var} =~ ^[0-9]+(MiB|GiB|MB|GB|%)$ ]] || { echo "Invalid size format in $var"; exit 1; }
    done

    parted --script "$TARGET_DISK" mkpart ESP fat32 "$EFI_START" "$EFI_END"
    parted --script "$TARGET_DISK" mkpart root btrfs "$ROOT_START" "$ROOT_END"
    parted --script "$TARGET_DISK" set 1 esp on
  else
    read -rp "⚠️ Wipe $TARGET_DISK? (yes/no): " yn
    [[ "$yn" == "yes" ]] || exit 0
    parted --script "$TARGET_DISK" mklabel gpt
    parted --script "$TARGET_DISK" mkpart ESP fat32 1MiB 2049MiB
    parted --script "$TARGET_DISK" mkpart root btrfs 2049MiB 100%
    parted --script "$TARGET_DISK" set 1 esp on
  fi

  partprobe "$TARGET_DISK"; sync; sleep 3

  # --- Dynamic detection ---
  EFI_DEV=$(lsblk -ln -o PATH,PARTLABEL "$TARGET_DISK" | awk '/ESP/{print $1; exit}') || true
  ROOT_DEV=$(lsblk -ln -o PATH,PARTLABEL "$TARGET_DISK" | awk '/root/{print $1; exit}') || true

  # fallback if no labels detected
  if [[ -z "$EFI_DEV" || -z "$ROOT_DEV" ]]; then
    if [[ "$TARGET_DISK" == *nvme* ]]; then
      EFI_DEV="${TARGET_DISK}p1"; ROOT_DEV="${TARGET_DISK}p2"
    else
      EFI_DEV="${TARGET_DISK}1"; ROOT_DEV="${TARGET_DISK}2"
    fi
  fi
}

# ==============================================================================
# Encryption + Btrfs setup
# ==============================================================================
setup_encryption_btrfs() {
  local LUKS_PASS
  if [[ -n "${AUTO_LUKS_PASS:-}" ]]; then
    LUKS_PASS="$AUTO_LUKS_PASS"
  else
    while true; do
      read -rsp "LUKS passphrase: " LUKS_PASS; echo
      read -rsp "Confirm: " LUKS_PASS2; echo
      [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && break
      echo "Mismatch. Try again."
    done
  fi

  printf "%s" "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --force-password "$ROOT_DEV" -
  printf "%s" "$LUKS_PASS" | cryptsetup open "$ROOT_DEV" root

  mkfs.btrfs /dev/mapper/root

  mount /dev/mapper/root /mnt
  for sub in @ @home @snapshots @log @swap; do
    btrfs subvolume create "/mnt/$sub"
  done
  umount /mnt

  mount -o noatime,compress=zstd,subvol=@ /dev/mapper/root /mnt
  mkdir -p /mnt/{home,.snapshots,var/log,swap,boot}
  mount -o noatime,compress=zstd,subvol=@home /dev/mapper/root /mnt/home
  mount -o noatime,compress=zstd,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
  mount -o noatime,compress=zstd,subvol=@log /dev/mapper/root /mnt/var/log

  mount -o subvol=@swap /dev/mapper/root /mnt/swap
  if ! btrfs filesystem mkswapfile --size "$SWAP_SIZE" /mnt/swap/swapfile; then
    echo "⚠️ btrfs-progs too old, skipping swapfile creation."
  else
    swapon /mnt/swap/swapfile
    RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)
    umount /mnt/swap
  fi

  mkfs.fat -F32 "$EFI_DEV"
  mount "$EFI_DEV" /mnt/boot

  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
  LUKS_UUID=$(cryptsetup luksUUID "$ROOT_DEV")

  echo "EFI: $EFI_DEV | Root: $ROOT_DEV | LUKS_UUID=$LUKS_UUID"
}

# ==============================================================================
# Base system install
# ==============================================================================
install_base_system() {
  reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
  cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

  pacstrap /mnt base base-devel linux linux-firmware sudo networkmanager btrfs-progs \
           iwd git limine efibootmgr binutils amd-ucode intel-ucode zram-generator \
           plymouth snapper cryptsetup reflector vim dhcpcd firewalld bluez bluez-utils \
           acpid avahi rsync bash-completion pipewire pipewire-alsa pipewire-pulse wireplumber sof-firmware

  genfstab -U /mnt >> /mnt/etc/fstab
  echo "root UUID=$LUKS_UUID none luks,discard" >> /mnt/etc/crypttab
}

# ==============================================================================
# System configuration inside chroot
# ==============================================================================
configure_system() {
  local USERNAME PASSWORD

  USERNAME=${AUTO_USER:-$(read -rp "Username: " u; echo "$u")}
  echo "Root and user passwords will be set interactively inside chroot."

  cat > /mnt/setup.sh <<EOF
#!/usr/bin/bash
set -euo pipefail

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
cat >> /etc/hosts <<HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

passwd
useradd -m -G wheel "$USERNAME"
passwd "$USERNAME"
sed -i '/^# %wheel ALL=(ALL:ALL) ALL$/s/^# //' /etc/sudoers

sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^#BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
echo 'COMPRESSION="zstd"' >> /etc/mkinitcpio.conf
mkinitcpio -P

cat > /etc/systemd/zram-generator.conf <<ZRAM
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
ZRAM

plymouth-set-default-theme -R spinner

umount /.snapshots 2>/dev/null || true
btrfs subvolume delete /.snapshots 2>/dev/null || true
btrfs subvolume create /.snapshots
chmod 750 /.snapshots
snapper -c root create-config /
snapper -c home create-config /home
systemctl enable snapper-timeline.timer snapper-cleanup.timer

mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
efibootmgr --create --disk "$TARGET_DISK" --part 1 \
  --label "Arch Linux (Limine)" \
  --loader '\\EFI\\limine\\BOOTX64.EFI' --unicode

LUKS_UUID=$(cryptsetup luksUUID "$ROOT_DEV")

cat <<LIMINECONF > /boot/EFI/limine/limine.conf
timeout: 3

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=\$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=\$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux-fallback.img
LIMINECONF

systemctl enable NetworkManager iwd bluetooth cups avahi-daemon firewalld acpid reflector.timer
EOF

  chmod +x /mnt/setup.sh
  arch-chroot /mnt /setup.sh || { echo "❌ Chroot setup failed"; exit 1; }
  rm /mnt/setup.sh
}

# ==============================================================================
# Main
# ==============================================================================
main() {
  select_disk
  partition_disk
  setup_encryption_btrfs
  install_base_system
  configure_system

  echo "✅ Installation complete!"
  echo "Reboot and select 'Arch Linux (Limine)' in UEFI menu."
  echo "Hostname: $HOSTNAME | Locale: $LOCALE | Timezone: $TIMEZONE"
}

main
