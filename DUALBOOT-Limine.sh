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

# --- Detect partitions ---
EFI_PART=""
ROOT_PART=""
while IFS= read -r part; do
  [[ -z "$part" ]] && continue
  FSTYPE=$(blkid -s TYPE -o value "$part" 2>/dev/null || true)
  case "$FSTYPE" in
    vfat|fat32) EFI_PART="$part" ;;
    btrfs)      ROOT_PART="$part" ;;
  esac
done < <(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}')

[[ -z "$EFI_PART" || -z "$ROOT_PART" ]] && { echo "Partition detection failed"; exit 1; }
efi_partition="$EFI_PART"
root_partition="$ROOT_PART"
echo "EFI: $efi_partition | Root: $root_partition"

# --- Encryption ---
while true; do
  read -rsp "LUKS passphrase: " LUKS_PASS; echo
  read -rsp "Confirm: " LUKS_PASS2; echo
  [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && break
  echo "Mismatch. Try again."
done

printf "YES\n%s" "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$root_partition"
printf "%s" "$LUKS_PASS" | cryptsetup open "$root_partition" cryptroot

# --- Btrfs ---
mkfs.btrfs -f -O '^encrypt' /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
for sub in @ @home @snapshots @log @swap; do
  btrfs subvolume create "/mnt/$sub"
done
umount /mnt

mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,var/log,swap,boot}
mount -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount -o noatime,compress=zstd,subvol=@log /dev/mapper/cryptroot /mnt/var/log

# --- Swapfile ---
mount -o subvol=@swap /dev/mapper/cryptroot /mnt/swap
btrfs filesystem mkswapfile --size 4g /mnt/swap/swapfile
swapon /mnt/swap/swapfile
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)
umount /mnt/swap

# --- EFI ---
mkfs.fat -F32 "$efi_partition"
mount "$efi_partition" /mnt/boot

# --- Reflector (fast mirrors) ---
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# --- Install base system ---
pacstrap /mnt base linux linux-firmware sudo networkmanager btrfs-progs iwd git limine efibootmgr binutils \
         amd-ucode intel-ucode zram-generator plymouth snapper grub-btrfs

# --- fstab + crypttab ---
genfstab -U /mnt >> /mnt/etc/fstab
ROOT_UUID=$(blkid -s UUID -o value "$root_partition")
echo "cryptroot UUID=$ROOT_UUID none luks,discard" >> /mnt/etc/crypttab

# --- User input ---
read -rp "Username: " username
read -rsp "Password: " user_pass; echo
read -rsp "Root password: " root_pass; echo

# --- Chroot setup ---
cat > /mnt/setup.sh <<EOF
#!/usr/bin/bash
set -euo pipefail

# Variables
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
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
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
snapper -c root create-config /
snapper -c home create-config /home
btrfs subvolume delete /.snapshots
btrfs subvolume create /.snapshots
chmod 750 /.snapshots
systemctl enable snapper-timeline.timer snapper-cleanup.timer

# Limine
mkdir -p /boot/limine
cp /usr/share/limine/limine-bios.sys /boot/limine/
cp /usr/share/limine/BOOTX64.EFI /boot/

cat > /boot/limine.cfg <<LIM
TIMEOUT=5

Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    CMDLINE=root=UUID=\$ROOT_UUID rw rootflags=subvol=@ cryptdevice=UUID=\$ROOT_UUID:cryptroot resume=UUID=\$ROOT_UUID resume_offset=\$RESUME_OFFSET quiet splash
    MODULE_PATH=boot:///initramfs-linux.img

Arch Linux (fallback)
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    CMDLINE=root=UUID=\$ROOT_UUID rw rootflags=subvol=@ cryptdevice=UUID=\$ROOT_UUID:cryptroot resume=UUID=\$ROOT_UUID resume_offset=\$RESUME_OFFSET quiet splash
    MODULE_PATH=boot:///initramfs-linux-fallback.img
LIM

limine-deploy /boot/limine.cfg
efibootmgr --create --disk "$TARGET_DISK" --part 1 --label "Arch Linux (Limine)" --loader '\\limine\\BOOTX64.EFI'

# Services
systemctl enable NetworkManager snapper-timeline.timer snapper-cleanup.timer

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
echo "Reboot → select 'Arch Linux (Limine)' in UEFI"
