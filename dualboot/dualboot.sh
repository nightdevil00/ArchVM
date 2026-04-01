#!/usr/bin/env bash
# safe-arch-install.sh
# Safe Arch installer: auto-detect Windows partitions, pick largest free region,
# create 2GB EFI + root in that free region, LUKS2 + btrfs subvolumes, pacstrap, grub.
set -euo pipefail

# Optional: log everything (uncomment if you want a persistent log)
# exec > >(tee /var/log/arch_install.log) 2>&1

# must be root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

TMP_MOUNT="/mnt/__arch_install_tmp"
mkdir -p "$TMP_MOUNT"

# associative array to record protected Windows-like partitions
declare -A PROTECTED_PARTS=()

# Gather disks using parseable lsblk
declare -a DEVICES=()
declare -A DEV_MODEL DEV_SIZE DEV_TRAN DEV_MOUNT

while IFS= read -r line; do
  # lsblk -P gives KEY="VALUE" pairs; eval populates variables
  eval "$line"   # NAME, KNAME, TYPE, SIZE, MODEL, TRAN, MOUNTPOINT
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

# Auto-skip USB drives (so the install USB doesn't appear)
filtered_devices=()
for d in "${DEVICES[@]}"; do
  if [[ "${DEV_TRAN[$d]}" != "usb" ]]; then
    filtered_devices+=("$d")
  fi
done
# Fallback: if filtering removed everything (rare), use original list
if [ ${#filtered_devices[@]} -gt 0 ]; then
  DEVICES=("${filtered_devices[@]}")
fi

echo "Available physical disks:"
for i in "${!DEVICES[@]}"; do
  idx=$((i+1))
  d=${DEVICES[$i]}
  printf "%2d) %-12s  %8s  %-18s  transport=%s\n" \
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

# --- Windows detection across all partitions ---
echo
echo "Scanning all partitions on all disks for Windows boot files / EFI Microsoft..."

# Iterate partitions across all disks to identify Windows systems
while IFS= read -r line; do
  eval "$line"   # NAME, TYPE, FSTYPE, MOUNTPOINT
  if [[ "${TYPE:-}" != "part" ]]; then
    continue
  fi
  PART="/dev/${NAME}"
  # skip loop devices, zram, cdrom, md devices
  if [[ "$PART" =~ loop|sr|md|zram ]]; then
    continue
  fi

  # Find filesystem type via blkid
  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)

  # If VFAT/FAT, mount read-only and look for EFI/Microsoft markers
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

  # If NTFS, mount ro and look for Windows folder / boot files
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

# --- Partitioning: either automatic free-space use (if Windows detected) or full-disk wipe ---
if [ ${#PROTECTED_PARTS[@]} -gt 0 ]; then
  echo
  echo "Detected Windows/EFI partitions; they will NOT be touched."
  echo "Scanning for largest free space on $TARGET_DISK..."

  # find largest "Free Space" block using parted -m print free (GB units)
  largest_start=""
  largest_end=""
  largest_size=0

  # parse parted -m output; fields are colon-separated: num:start:end:size:fs:...
  while IFS=: read -r num start end size fstype rest; do
    # parted returns sizes like "396.00GB" or "512kB". We only care about entries where fstype=="free"
    if [[ "$fstype" == "free" ]]; then
      # normalize size to numeric GB using awk (handles MB/GB)
      s_val=$(echo "$size" | awk '
        {
          sub(/GB$/,"",$0); sub(/MB$/,"",$0);
          val=$0;
          unit=substr($0, length($0));
        }
      ')
      # Better: use a more robust awk to extract numeric and unit
      s_num=$(echo "$size" | awk '{ gsub(/,/, ""); match($0, /([0-9]+(\.[0-9]+)?)([A-Za-z]+)?/, m); printf "%s %s", m[1], m[3]}')
      s_num_val=$(echo "$s_num" | awk '{print $1}')
      s_num_unit=$(echo "$s_num" | awk '{print $2}')
      if [[ "$s_num_unit" == "MB" || "$s_num_unit" == "kB" || "$s_num_unit" == "KB" ]]; then
        # convert MB to GB
        s_gb=$(awk -v v="$s_num_val" 'BEGIN{printf "%.6f", v/1024}')
      else
        # GB or empty treat as GB
        s_gb="$s_num_val"
      fi

      # compare floats using awk
      is_larger=$(awk -v a="$s_gb" -v b="$largest_size" 'BEGIN{print (a > b) ? 1 : 0}')
      if [[ "$is_larger" -eq 1 ]]; then
        largest_size="$s_gb"
        # parted returns start/end with units like "115.00GB"; store them
        largest_start="$start"
        largest_end="$end"
      fi
    fi
  done < <(parted -m "$TARGET_DISK" unit GB print free | tail -n +3)

  if [[ -z "$largest_start" ]]; then
    echo "No free space detected on $TARGET_DISK. Exiting to avoid accident."
    exit 1
  fi

  echo "Largest free region found: $largest_start → $largest_end (~${largest_size} GB)"
  echo "Will create a 2GB EFI partition at the start of that region and use the rest for root."
  echo "Preview (confirm to proceed):"
  echo "  EFI: start=$largest_start  end=$(awk -v s=\"$largest_start\" 'BEGIN{print s+2}')GB"
  echo "  ROOT: start=$(awk -v s=\"$largest_start\" 'BEGIN{print s+2}')GB  end=$largest_end"
  read -rp "Proceed to create these partitions? (yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborting per user request."
    exit 0
  fi

  # compute numeric start/end without units for parted math
  start_gb=$(echo "$largest_start" | sed 's/GB$//')
  end_gb=$(echo "$largest_end" | sed 's/GB$//')
  # compute efi end = start + 2
  efi_end_gb=$(awk -v s="$start_gb" 'BEGIN{printf "%.6f", s+2}')
  efi_start="${start_gb}GB"
  efi_end="${efi_end_gb}GB"
  root_start="${efi_end}"
  root_end="${end_gb}GB"

  # create partitions with parted
  parted --script "$TARGET_DISK" mkpart primary fat32 "$efi_start" "$efi_end"
  partprobe "$TARGET_DISK" || true
  # find the partition index whose start matches efi_start (safer than last index heuristic)
  efi_idx=$(parted -m "$TARGET_DISK" unit GB print | tail -n +3 | awk -F: -v s="$start_gb" '$2==s {print $1; exit}')
  if [[ -n "$efi_idx" ]]; then
    parted --script "$TARGET_DISK" set "$efi_idx" esp on || true
  else
    # fallback: set the last partition we just created as esp
    last_idx=$(parted -m "$TARGET_DISK" print | tail -n 1 | awk -F: '{print $1}')
    if [[ -n "$last_idx" ]]; then
      parted --script "$TARGET_DISK" set "$last_idx" esp on || true
    fi
  fi

  parted --script "$TARGET_DISK" mkpart primary btrfs "$root_start" "$root_end"
  partprobe "$TARGET_DISK" || true
  sleep 1

  # find newly created partitions (best effort: assume they are the last two partitions)
  parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
  if (( ${#parts[@]} >= 2 )); then
    efi_partition="${parts[-2]}"
    root_partition="${parts[-1]}"
  else
    echo "Could not determine new partitions automatically. Listing partitions for manual inspection:"
    lsblk -o NAME,KNAME,SIZE,FSTYPE,MOUNTPOINT "$TARGET_DISK"
    echo "Please re-run after confirming partition names."
    exit 1
  fi

  echo "Created EFI partition:  $efi_partition  (${efi_start}–${efi_end})"
  echo "Created root partition: $root_partition (${root_start}–${root_end})"

else
  # No Windows detected on any disk — full disk install (user must confirm)
  echo "No Windows partitions detected on any disk."
  read -rp "Proceed to wipe and use the entire $TARGET_DISK for Arch? (yes/no): " yn
  if [[ "$yn" != "yes" ]]; then
    echo "Aborting."
    exit 0
  fi

  echo "Creating new GPT and partitions (EFI + root) on $TARGET_DISK"
  parted --script "$TARGET_DISK" mklabel gpt
  # create ~2GB EFI (1MiB start to avoid alignment issues)
  parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
  parted --script "$TARGET_DISK" set 1 esp on
  # rest as root
  parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
  partprobe "$TARGET_DISK" || true

  # find created partitions
  parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
  if (( ${#parts[@]} >= 2 )); then
    efi_partition="${parts[0]}"
    root_partition="${parts[1]}"
  else
    echo "Couldn't determine partition names. Aborting."
    exit 1
  fi

  echo "EFI partition: $efi_partition"
  echo "Root partition: $root_partition"
fi

# Sanity check: ensure we have variables
if [[ -z "${efi_partition:-}" || -z "${root_partition:-}" ]]; then
  echo "Couldn't determine new partition paths automatically. Listing partitions for manual verification:"
  lsblk -o NAME,KNAME,SIZE,FSTYPE,MOUNTPOINT "$TARGET_DISK"
  echo "Please re-run the script after confirming partition names."
  exit 1
fi

# Format EFI partition
echo "Formatting EFI partition ($efi_partition) as FAT32..."
mkfs.fat -F32 "$efi_partition"

# Encrypt root partition with LUKS2
echo "Encrypting root partition ($root_partition) with LUKS2."
echo "You will be prompted interactively by cryptsetup."
cryptsetup luksFormat "$root_partition"
cryptsetup luksOpen "$root_partition" cryptroot

# Make btrfs
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

# Install base system
pacstrap /mnt base linux linux-firmware linux-headers iwd networkmanager vim nano sudo grub efibootmgr btrfs-progs os-prober

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Save root partition path + credentials for chrooting
echo "$root_partition" > /mnt/ROOT_PART_PATH

# Collect user input
read -rp "New username: " username
read -rsp "Password for $username: " user_password; echo
read -rsp "Root password: " root_password; echo

cat > /mnt/arch_install_vars.sh <<EOF
ROOT_PART="$root_partition"
USERNAME="$username"
USER_PASS="$user_password"
ROOT_PASS="$root_password"
EOF

# Enter chroot to finalize installation
arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail
# Load variables created earlier
source /arch_install_vars.sh

# find UUID of the underlying encrypted partition
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

# create user and add to wheel
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers

# configure crypttab
echo "cryptroot UUID=$ROOT_UUID none luks,discard" > /etc/crypttab

# mkinitcpio hooks for LUKS + btrfs
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# ensure os-prober is allowed for grub
if ! grep -q '^GRUB_DISABLE_OS_PROBER=false' /etc/default/grub 2>/dev/null; then
  echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

# configure GRUB boot options for encrypted root
if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub 2>/dev/null; then
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
else
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot\"" >> /etc/default/grub
fi

# install grub to EFI
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# enable NetworkManager (and other services if desired)
systemctl enable NetworkManager

# cleanup sensitive var file
rm -f /arch_install_vars.sh
EOF

# Ensure host-side copy of secret is removed (defense-in-depth)
shred -u /mnt/arch_install_vars.sh 2>/dev/null || rm -f /mnt/arch_install_vars.sh || true

echo
echo "Installation steps finished. Review output above for any errors."
echo "You can now reboot. If Windows exists it was protected and should appear in GRUB."

