#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Full Installer – Dualboot + Limine + Encryption + Snapper + Plymouth
# ==============================================================================

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

LOG_FILE="/tmp/arch_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging to $LOG_FILE"

TMP_MOUNT="/mnt/__tmp"
mkdir -p "$TMP_MOUNT"

# --- Disk selection ---
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
[[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#DEVICES[@]} )) || exit 1
TARGET_DISK="${DEVICES[$((num-1))]}"
echo "Selected: $TARGET_DISK"

# --- Windows detection ---
PROTECTED=0
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

# --- Partitioning ---
if (( PROTECTED )); then
  echo "Windows detected → using free space"
  parted --script "$TARGET_DISK" unit GB print free
  read -rp "EFI start (e.g. 1GB): " EFI_START
  read -rp "EFI end   (e.g. 3GB): " EFI_END
  read -rp "Root start (e.g. 3GB): " ROOT_START
  read -rp "Root end   (e.g. 100%): " ROOT_END
  parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END"
  parted --script "$TARGET_DISK" set $(parted -s "$TARGET_DISK" print | awk '/fat32/{print NR}') esp on
  parted --script "$TARGET_DISK" mkpart primary btrfs "$ROOT_START" "$ROOT_END"
else
  read -rp "Wipe $TARGET_DISK? (yes/no): " yn
  [[ "$yn" == "yes" ]] || exit 0
  parted --script "$TARGET_DISK" mklabel gpt
  parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
  parted --script "$TARGET_DISK" set 1 esp on
  parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
fi

partprobe "$TARGET_DISK"; sync; sleep 3

# --- Partition devices ---
if [[ "$TARGET_DISK" == *nvme* ]]; then
  EFI_DEV="${TARGET_DISK}p1"
  ROOT_DEV="${TARGET_DISK}p2"
else
  EFI_DEV="${TARGET_DISK}1"
  ROOT_DEV="${TARGET_DISK}2"
fi

# --- 1. LUKS ON RAW PARTITION (FIXED) ---
while true; do
  read -rsp "LUKS passphrase: " LUKS_PASS; echo
  read -rsp "Confirm: " LUKS_PASS2; echo
  [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && break
  echo "Mismatch. Try again."
done

if ! printf "%s" "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --force-password "$ROOT_DEV" -; then
  echo "LUKS FORMAT FAILED. Is the disk write-protected?"
  exit 1
fi

if ! printf "%s" "$LUKS_PASS" | cryptsetup open "$ROOT_DEV" root; then
  echo "LUKS OPEN FAILED. Wrong passphrase?"
  exit 1
fi

# --- 2. BTRFS ON LUKS ---
mkfs.btrfs /dev/mapper/root

# --- Subvolumes ---
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

# --- Swapfile ---
mount -o subvol=@swap /dev/mapper/root /mnt/swap
btrfs filesystem mkswapfile --size 4g /mnt/swap/swapfile
swapon /mnt/swap/swapfile
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)
umount /mnt/swap

# --- EFI ---
mkfs.fat -F32 "$EFI_DEV"
mount "$EFI_DEV" /mnt/boot

# --- Final variables ---
ROOT_PART="$ROOT_DEV"
EFI_PART="$EFI_DEV"
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
echo "EFI: $EFI_PART | Root: $ROOT_PART | UUID: $ROOT_UUID"

LUKS_UUID=\$(cryptsetup luksUUID $ROOT)

# --- Reflector (fast mirrors) ---
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# --- Install base system ---
pacstrap /mnt base base-devel linux linux-firmware sudo networkmanager btrfs-progs iwd git limine efibootmgr binutils \
         amd-ucode intel-ucode zram-generator plymouth snapper cryptsetup reflector vim dhcpcd firewalld bluez bluez-utils acpid avahi rsync bash-completion \
         pipewire pipewire-alsa pipewire-pulse wireplumber sof-firmware

# --- fstab + crypttab (FIXED) ---
genfstab -U /mnt >> /mnt/etc/fstab
echo "root UUID=$ROOT_UUID none luks,discard" >> /mnt/etc/crypttab

# --- User input ---
read -rp "Username: " username
read -rsp "Password: " user_pass; echo
read -rsp "Root password: " root_pass; echo

# --- Chroot setup ---
cat > /mnt/setup.sh <<EOF
#!/usr/bin/bash
set -euo pipefail

ROOT_UUID="$ROOT_UUID"
RESUME_OFFSET="$RESUME_OFFSET"
USERNAME="$username"
USER_PASS="$user_pass"
ROOT_PASS="$root_pass"


# Time / Locale
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "arch" > /etc/hostname
cat >> /etc/hosts <<HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 arch.localdomain arch
HOSTS

# Users
echo "root:\$ROOT_PASS" | chpasswd
useradd -m -G wheel "\$USERNAME"
echo "\$USERNAME:\$USER_PASS" | chpasswd
sed -i '/^# %wheel ALL=(ALL:ALL) ALL$/s/^# //' /etc/sudoers

# Initramfs
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^#BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
echo 'COMPRESSION="zstd"' >> /etc/mkinitcpio.conf
mkinitcpio -P

# Microcode
if grep -q AMD /proc/cpuinfo; then
  cp /boot/amd-ucode.img /boot/
elif grep -q Intel /proc/cpuinfo; then
  cp /boot/intel-ucode.img /boot/
fi

# ZRAM
cat > /etc/systemd/zram-generator.conf <<ZRAM
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
ZRAM

# Plymouth
plymouth-set-default-theme -R spinner

# Snapper
umount /.snapshots 2>/dev/null || true
btrfs subvolume delete /.snapshots 2>/dev/null || true
btrfs subvolume create /.snapshots
chmod 750 /.snapshots
snapper -c root create-config /
snapper -c home create-config /home
systemctl enable snapper-timeline.timer snapper-cleanup.timer

# Limine
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

efibootmgr --create --disk "$TARGET_DISK" --part 1 \
      --label "Arch Linux Limine Bootloader" \
      --loader '\\EFI\\limine\\BOOTX64.EFI' \
      --unicode
      
LUKS_UUID=\$(cryptsetup luksUUID $ROOT_PART)     

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


# Services
for s in NetworkManager dhcpcd iwd systemd-networkd systemd-resolved bluetooth cups avahi-daemon firewalld acpid reflector.timer; do
    systemctl enable $s
done

EOF

chmod +x /mnt/setup.sh
arch-chroot /mnt /setup.sh
rm /mnt/setup.sh

# --- Final cleanup ---
umount -R /mnt
swapoff -a
cryptsetup luksClose root
rm -rf "$TMP_MOUNT"

echo "Installation complete!"
echo "Reboot → select 'Arch Linux (Limine)' in UEFI"
