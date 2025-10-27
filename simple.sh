#!/usr/bin/env bash
# safer-arch-install.sh
# Improved disk listing and Windows detection; safer partitioning when Windows is present.
set -euo pipefail

# check root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

TMP_MOUNT="/mnt/__arch_install_tmp"
mkdir -p "$TMP_MOUNT"
declare -A PROTECTED_PARTS=()  # map of partition -> reason

# Helper: print a parseable lsblk and return array of disks (TYPE=disk)
declare -a DEVICES=()
declare -A DEV_MODEL DEV_SIZE DEV_TRAN DEV_MOUNT

while IFS= read -r line; do
  # lsblk -P fields are KEY="VALUE"
  eval "$line"   # populates variables like NAME, KNAME, SIZE, MODEL, TRAN, MOUNTPOINT, TYPE
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

# --- Windows detection ---
echo
echo "Scanning all partitions on all disks for Windows boot files / EFI Microsoft..."


# Iterate partitions across all disks (not just selected) to identify Windows systems
while IFS= read -r line; do
  eval "$line"   # this yields NAME,TYPE,FSTYPE,MOUNTPOINT etc.
  if [[ "${TYPE:-}" != "part" ]]; then
    continue
  fi
  PART="/dev/${NAME}"
  # skip loop devices, zram, etc
  if [[ "$PART" =~ loop|sr|md ]]; then
    continue
  fi

  # Find filesystem type via blkid (non-interactive)
  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)

  # If VFAT/Efi, mount ro and look for EFI/Microsoft
  if [[ "$FSTYPE" == "vfat" || "$FSTYPE" == "fat32" || "$FSTYPE" == "fat" ]]; then
    mkdir -p "$TMP_MOUNT"
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/EFI/Microsoft" ]] || [[ -f "$TMP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]] || [[ -f "$TMP_MOUNT/EFI/Boot/bootx64.efi" ]]; then
        PROTECTED_PARTS["$PART"]="EFI Microsoft files found"
        echo "Protected (EFI): $PART -> ${PROTECTED_PARTS[$PART]}"
      fi
      umount "$TMP_MOUNT" || true
    fi
  fi

  # If NTFS, mount ro and look for Windows folder or boot files
  if [[ "$FSTYPE" == "ntfs" ]]; then
    mkdir -p "$TMP_MOUNT"
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/Windows" ]] || [[ -f "$TMP_MOUNT/bootmgr" ]] || [[ -d "$TMP_MOUNT/Boot" ]]; then
        PROTECTED_PARTS["$PART"]="NTFS Windows files found"
        echo "Protected (NTFS): $PART -> ${PROTECTED_PARTS[$PART]}"
      fi
      umount "$TMP_MOUNT" || true
    fi
  fi

done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINT)

# Summarize
if [ ${#PROTECTED_PARTS[@]} -gt 0 ]; then
  echo
  echo "Detected Windows/EFI partitions; they will not be touched."
  echo "Scanning for largest free space on $TARGET_DISK..."

  # get free-space blocks: output format "start:end:size:type"
  # we'll parse for entries where type == "free"
  largest_start=""
  largest_end=""
  largest_size=0

  while IFS=: read -r num start end size type rest; do
    if [[ "$type" == "free" ]]; then
      # remove GB/MB suffix for math
      s_val=$(echo "$size" | sed 's/[^0-9.]//g')
      unit=$(echo "$size" | grep -o '[A-Za-z]*')
      # normalize to GB
      if [[ "$unit" =~ [Mm]B ]]; then
        s_val=$(awk -v v="$s_val" 'BEGIN{print v/1024}')
      fi
      if (( $(echo "$s_val > $largest_size" | bc -l) )); then
        largest_size=$s_val
        largest_start=$start
        largest_end=$end
      fi
    fi
  done < <(parted -m "$TARGET_DISK" unit GB print free | tail -n +3)

  if [[ -z "$largest_start" ]]; then
    echo "No free space detected. Exiting."
    exit 1
  fi

  echo "Largest free region found: $largest_start → $largest_end ($largest_size GB)"
  echo "Creating 2GB EFI partition at start of that region and using the rest for root."

  # convert to numeric for parted math
  start_gb=$(echo "$largest_start" | sed 's/GB//')
  end_gb=$(echo "$largest_end" | sed 's/GB//')
  efi_start="${start_gb}GB"
  efi_end="$(awk -v s="$start_gb" 'BEGIN{print s+2}')GB"
  root_start="$efi_end"
  root_end="${end_gb}GB"

  parted --script "$TARGET_DISK" mkpart primary fat32 "$efi_start" "$efi_end"
  parted --script "$TARGET_DISK" set $(parted -s "$TARGET_DISK" print | awk '/^ /{n++; print n; exit}') boot on || true
  parted --script "$TARGET_DISK" mkpart primary btrfs "$root_start" "$root_end"

  partprobe "$TARGET_DISK" || true
  sleep 1

  parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
  efi_partition="${parts[-2]}"
  root_partition="${parts[-1]}"

  echo "Created EFI partition:  $efi_partition  (${efi_start}–${efi_end})"
  echo "Created root partition: $root_partition (${root_start}–${root_end})"

else
  # No Windows detected: confirm full disk wipe
  echo "No Windows partitions detected on any disk."
  read -rp "Proceed to wipe and use the entire $TARGET_DISK for Arch? (yes/no): " yn
  if [[ "$yn" != "yes" ]]; then
    echo "Aborting."
    exit 0
  fi

  echo "Creating new GPT and partitions (EFI + root) on $TARGET_DISK"
  parted --script "$TARGET_DISK" mklabel gpt
  # create 2GB EFI
  parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
  parted --script "$TARGET_DISK" set 1 boot on
  # rest as root
  parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
  partprobe "$TARGET_DISK" || true

  # find created partitions
  parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
  efi_partition="${parts[0]}"
  root_partition="${parts[1]}"
  echo "EFI partition: $efi_partition"
  echo "Root partition: $root_partition"
fi

# Final safety check: ensure EFI and root variables exist
if [[ -z "${efi_partition:-}" || -z "${root_partition:-}" ]]; then
  echo "Couldn't determine new partition paths automatically. Listing partitions for manual verification:"
  lsblk -o NAME,KNAME,SIZE,FSTYPE,MOUNTPOINT "$TARGET_DISK"
  echo "Please re-run the script after confirming partition names."
  exit 1
fi

# Format EFI partition
echo "Formatting EFI partition ($efi_partition) as FAT32..."
mkfs.fat -F32 "$efi_partition"

# Ask for LUKS passphrase (interactively) then format root and open
echo "Encrypting root partition ($root_partition) with LUKS2."
echo "You will be prompted interactively by cryptsetup."
cryptsetup luksFormat "$root_partition"
cryptsetup luksOpen "$root_partition" cryptroot

# create btrfs
echo "Creating btrfs on /dev/mapper/cryptroot..."
mkfs.btrfs -f /dev/mapper/cryptroot

# mount and create subvolumes
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home

# mount efi
mkdir -p /mnt/boot
mount "$efi_partition" /mnt/boot

# pacstrap
pacstrap /mnt base linux linux-firmware linux-headers iwd networkmanager vim nano sudo grub efibootmgr btrfs-progs os-prober

# genfstab
genfstab -U /mnt >> /mnt/etc/fstab

# Save root partition path for chroot
echo "$root_partition" > /mnt/ROOT_PART_PATH

# user input for username/password
read -rp "New username: " username
read -rsp "Password for $username: " user_password; echo
read -rsp "Root password: " root_password; echo

cat > /mnt/arch_install_vars.sh <<EOF
ROOT_PART="$root_partition"
USERNAME="$username"
USER_PASS="$user_password"
ROOT_PASS="$root_password"
EOF

# chroot and finish configuration
arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail
# Load variables created earlier
source /arch_install_vars.sh

# find UUID of root partition (the underlying encrypted partition)
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# timezone / locale
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# hostname
echo "arch-linux" > /etc/hostname

# set root password
echo "root:$ROOT_PASS" | chpasswd

# create user
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers

# crypttab
echo "cryptroot UUID=$ROOT_UUID none luks,discard" > /etc/crypttab

# mkinitcpio hooks
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# grub config - append cryptdevice param to default if present
if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub; then
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
else
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot\"" >> /etc/default/grub
fi

# install grub to EFI
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# enable NetworkManager (optional)
systemctl enable NetworkManager

# cleanup
rm -f /arch_install_vars.sh
EOF

echo
echo "Install steps finished. Review output above for any errors."
echo "Reboot when ready. If Windows exists it was protected and should appear in GRUB if os-prober detected it."

