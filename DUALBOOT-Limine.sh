#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Interactive Install Script – Fixed & Limine UEFI
# Dualboot with Windows (preserves Windows EFI)
# Encrypted Btrfs + Subvolumes + Swapfile + Resume + Limine
# ==============================================================================

LOG_FILE="/tmp/arch_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging to $LOG_FILE"

[[ -n "${BASH_VERSION:-}" ]] || { echo "Run in Bash"; exit 1; }
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

TMP_MOUNT="/mnt/__arch_install_tmp"
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
  printf " %2d) %-12s %8s  %-10s  [%s]\n" \
    "$((i+1))" "${DEVICES[i]}" "${DEV_SIZE[${DEVICES[i]}]}" \
    "${DEV_MODEL[${DEVICES[i]}]}" "${DEV_TRAN[${DEVICES[i]}]}"
done

read -rp "Select disk number: " num
[[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#DEVICES[@]} )) || exit 1
TARGET_DISK="${DEVICES[$((num-1))]}"
echo "Selected: $TARGET_DISK"

# --- Windows detection ---
declare -A PROTECTED_PARTS=()
while IFS= read -r line; do
  eval "$line"
  [[ "${TYPE:-}" != "part" ]] && continue
  PART="/dev/${NAME}"
  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)
  if [[ "$FSTYPE" =~ ^(vfat|fat32|fat)$ ]] && mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
    [[ -d "$TMP_MOUNT/EFI/Microsoft" ]] && PROTECTED_PARTS["$PART"]="Windows EFI"
    umount "$TMP_MOUNT" 2>/dev/null || true
  elif [[ "$FSTYPE" == "ntfs" ]] && mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
    [[ -d "$TMP_MOUNT/Windows" ]] && PROTECTED_PARTS["$PART"]="Windows NTFS"
    umount "$TMP_MOUNT" 2>/dev/null || true
  fi
done < <(lsblk -P -o NAME,TYPE "$TARGET_DISK")

# --- Partitioning ---
if [[ ${#PROTECTED_PARTS[@]} -gt 0 ]]; then
  echo "Windows partitions protected:"
  for p in "${!PROTECTED_PARTS[@]}"; do echo " - $p"; done
  echo "Using free space only."
  parted --script "$TARGET_DISK" unit GB print free
  read -rp "EFI start (e.g. 1GB): " EFI_START
  read -rp "EFI end   (e.g. 3GB): " EFI_END
  read -rp "Root start (e.g. 3GB): " ROOT_START
  read -rp "Root end   (e.g. 100%): " ROOT_END
  parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END"
  parted --script "$TARGET_DISK" set $(parted -s "$TARGET_DISK" print | awk '/fat32/{print NR}') esp on
  parted --script "$TARGET_DISK" mkpart primary btrfs "$ROOT_START" "$ROOT_END"
else
  read -rp "Wipe $TARGET_DISK and use full disk? (yes/no): " yn
  [[ "$yn" == "yes" ]] || exit 0
  parted --script "$TARGET_DISK" mklabel gpt
  parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
  parted --script "$TARGET_DISK" set 1 esp on
  parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
fi

partprobe "$TARGET_DISK"; sleep 2

# --- Detect partitions ---
mapfile -t parts < <(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}')
efi_partition="${parts[-2]}"
root_partition="${parts[-1]}"
echo "EFI: $efi_partition | Root: $root_partition"

# --- Encryption ---
read -rsp "LUKS passphrase: " LUKS_PASS; echo
read -rsp "Confirm passphrase: " LUKS_PASS2; echo
[[ "$LUKS_PASS" == "$LUKS_PASS2" ]] || { echo "Passphrases don't match"; exit 1; }

printf "YES\n%s" "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$root_partition"
printf "%s" "$LUKS_PASS" | cryptsetup open "$root_partition" cryptroot

# --- Btrfs + subvolumes ---
mkfs.btrfs -f -O '^encrypt' /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@log
umount /mnt

mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,var/log,boot}
mount -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount -o noatime,compress=zstd,subvol=@log /dev/mapper/cryptroot /mnt/var/log

mkfs.fat -F32 "$efi_partition"
mount "$efi_partition" /mnt/boot

# --- Swapfile ---
btrfs subvolume create /mnt/@swap
mount -o subvol=@swap /dev/mapper/cryptroot /mnt/swap
btrfs filesystem mkswapfile --size 4g /mnt/swap/swapfile
swapon /mnt/swap/swapfile
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)
umount /mnt/swap

# --- Install base system ---
pacstrap /mnt base linux linux-firmware sudo networkmanager btrfs-progs iwd git limine efibootmgr binutils amd-ucode intel-ucode

# --- fstab ---
genfstab -U /mnt >> /mnt/etc/fstab
ROOT_UUID=$(blkid -s UUID -o value "$root_partition")
echo "cryptroot UUID=$ROOT_UUID none luks,discard" >> /mnt/etc/crypttab

# --- User input ---
read -rp "Username: " username
read -rsp "Password: " user_pass; echo
read -rsp "Root password: " root_pass; echo

# --- Chroot script ---
cat > /mnt/setup.sh <<EOF
#!/usr/bin/bash
set -euo pipefail

# Variables
ROOT_PART="$root_partition"
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
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 arch.localdomain arch" >> /etc/hosts

# Users
echo "root:\$ROOT_PASS" | chpasswd
useradd -m -G wheel "\$USERNAME"
echo "\$USERNAME:\$USER_PASS" | chpasswd
sed -i '/^# %wheel ALL=(ALL:ALL) ALL$/s/^# //' /etc/sudoers

# Initramfs
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Microcode
if grep -q AMD /proc/cpuinfo; then
  cp /boot/amd-ucode.img /boot/
elif grep -q Intel /proc/cpuinfo; then
  cp /boot/intel-ucode.img /boot/
fi

# --- LIMINE INSTALL ---
mkdir -p /boot/limine
cp /usr/share/limine/limine-bios.sys /boot/limine/
cp /usr/share/limine/BOOTX64.EFI /boot/

cat > /boot/limine.cfg <<LIM
TIMEOUT=5

Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    CMDLINE=root=UUID=\$ROOT_UUID rw rootflags=subvol=@ cryptdevice=UUID=\$ROOT_UUID:cryptroot resume=UUID=\$ROOT_UUID resume_offset=\$RESUME_OFFSET
    MODULE_PATH=boot:///initramfs-linux.img

Arch Linux (fallback)
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    CMDLINE=root=UUID=\$ROOT_UUID rw rootflags=subvol=@ cryptdevice=UUID=\$ROOT_UUID:cryptroot resume=UUID=\$ROOT_UUID resume_offset=\$RESUME_OFFSET
    MODULE_PATH=boot:///initramfs-linux-fallback.img
LIM

# Deploy Limine
limine-deploy /boot/limine.cfg

# Create EFI entry
efibootmgr --create --disk "$TARGET_DISK" --part 1 --label "Arch Linux (Limine)" --loader '\\limine\\BOOTX64.EFI'

systemctl enable NetworkManager
EOF

chmod +x /mnt/setup.sh
arch-chroot /mnt /setup.sh
rm /mnt/setup.sh

# --- Final ---
umount -R /mnt
swapoff -a
cryptsetup luksClose cryptroot
rm -rf "$TMP_MOUNT"

echo "Installation complete!"
echo "Reboot and select 'Arch Linux (Limine)' in UEFI boot menu."
