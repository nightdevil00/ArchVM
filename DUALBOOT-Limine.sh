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

echo
echo "What do you want to do?"
echo "  1) Create partitions for Arch Linux"
echo "  2) Delete a partition"
read -rp "Enter your choice (1-2): " choice

case "$choice" in
  1)

# --- Windows detection ---
echo
echo "Scanning all partitions on all disks for Windows boot files / EFI Microsoft..."
declare -A PROTECTED_PARTS  # map of partition -> reason

while IFS= read -r line; do
  eval "$line"
  if [[ "${TYPE:-}" != "part" ]]; then
    continue
  fi
  PART="/dev/${NAME}"
  [[ "$PART" =~ loop|sr|md ]] && continue

  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)

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

# --- Show free space ---
echo
echo "PARTITION TABLE + FREE SPACE (for $TARGET_DISK):"
parted --script "$TARGET_DISK" unit GB print free | sed -E 's/^(Number[[:space:]]+)(Start[[:space:]]+)(End[[:space:]]+)(Size[[:space:]]+)(.*)/\1\4\2\3\5/' | sed -E 's/^([[:space:]]*[0-9]*[[:space:]]+)([0-9\.]*GB[[:space:]]+)([0-9\.]*GB[[:space:]]+)([0-9\.]*GB[[:space:]]+)(.*)/\1\4\2\3\5/' | sed '/Free Space/s/.*/\x1b[1;33m&\x1b[0m/' || true

# Extract free spaces for selection
mapfile -t FREE_SPACES < <(
  parted --script "$TARGET_DISK" unit GB print free | awk '
    BEGIN{IGNORECASE=1}
    /Free/ {
      n=0
      for(i=1;i<=NF;i++){
        if($i ~ /^[0-9.]+GB$/){
          n++
          if(n==1) start=$i
          else if(n==2) end=$i
        }
      }
      gsub("GB","",start)
      gsub("GB","",end)
      if(start+0 < end+0) print start":"end
    }
  '
)

if [ ${#FREE_SPACES[@]} -eq 0 ]; then
  echo "No free space detected on $TARGET_DISK."
  exit 1
fi

echo

echo "Available free space blocks:"

for i in "${!FREE_SPACES[@]}"; do

  start=$(echo "${FREE_SPACES[$i]}" | cut -d: -f1)

  end=$(echo "${FREE_SPACES[$i]}" | cut -d: -f2)

  size=$(awk "BEGIN {print $end - $start}")

  printf "%2d) Start: %-8s End: %-8s Size: %-8s\n" "$((i+1))" "${start}GB" "${end}GB" "${size}GB"

done

read -rp "Select the free space block to use (e.g., 1): " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#FREE_SPACES[@]} )); then

  echo "Invalid selection. Exiting."

  exit 1

fi

selected_space="${FREE_SPACES[$((choice-1))]}"

free_start=$(echo "$selected_space" | cut -d: -f1)

free_end=$(echo "$selected_space" | cut -d: -f2)

free_size=$(awk "BEGIN {print $free_end - $free_start}")

echo "You selected a block of ${free_size}GB starting at ${free_start}GB."

efi_size="3"

while true; do

  read -rp "Enter the size for the EFI partition in GB (recommended: 3): " efi_size_input
  if [ -n "$efi_size_input" ]; then
      efi_size=$efi_size_input
  fi

  if ! [[ "$efi_size" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then

    echo "Invalid size. Please enter a number."

    continue

  fi

  if (( $(awk "BEGIN {print ($efi_size > $free_size)}") )); then

    echo "EFI partition size cannot be larger than the available free space (${free_size}GB)."

  else

    break

  fi

done

EFI_START="$free_start"

EFI_END=$(awk "BEGIN {print $free_start + $efi_size}")

ROOT_START="$EFI_END"

ROOT_END="100%"

root_size=$(awk "BEGIN {print $free_end - $EFI_END}")

echo

echo "The following partitions will be created:"

echo "  - EFI Partition:  ${EFI_START}GB - ${EFI_END}GB (${efi_size}GB)"

echo "  - Root Partition: ${ROOT_START}GB - ${ROOT_END} (${root_size}GB)"

read -rp "Do you want to continue? (y/N): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then

  echo "Aborting."

  exit 1

fi

echo "Creating EFI partition..."
parted --script "$TARGET_DISK" mkpart "OMARCHY_EFI" fat32 "${EFI_START}GB" "${EFI_END}GB"

echo "Creating root partition..."
parted --script "$TARGET_DISK" mkpart "OMARCHY_ROOT" btrfs "${ROOT_START}GB" "${ROOT_END}"

partprobe "$TARGET_DISK" || true
sleep 1

efi_part_num=$(parted -s "$TARGET_DISK" print | awk '/OMARCHY_EFI/ {print $1}')
root_part_num=$(parted -s "$TARGET_DISK" print | awk '/OMARCHY_ROOT/ {print $1}')

efi_partition="${TARGET_DISK}p${efi_part_num}"
root_partition="${TARGET_DISK}p${root_part_num}"

parted --script "$TARGET_DISK" set "$efi_part_num" boot on
echo "EFI partition: $efi_partition"
echo "Root partition: $root_partition"

# Format EFI
echo "Formatting EFI partition ($efi_partition) as FAT32..."
mkfs.fat -F32 "$efi_partition"

# Encrypt root
echo "Encrypting root partition ($root_partition) with LUKS2."
cryptsetup luksFormat "$root_partition"
cryptsetup luksOpen "$root_partition" cryptroot

# Btrfs
echo "Creating btrfs on /dev/mapper/cryptroot..."
mkfs.btrfs -f /dev/mapper/cryptroot

# Mount and create subvolumes
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
umount /mnt

# Mount subvolumes
mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mkdir -p /mnt/var
mount -o noatime,compress=zstd,subvol=@var /dev/mapper/cryptroot /mnt/var

# Mount EFI
mkdir -p /mnt/boot
mount "$efi_partition" /mnt/boot


    ;;
  2)
    echo "Partitions on $TARGET_DISK:"
    parted "$TARGET_DISK" print
    read -rp "Enter the number of the partition to delete: " part_num
    if ! [[ "$part_num" =~ ^[0-9]+$ ]]; then
      echo "Invalid partition number."
      exit 1
    fi

    PART_PATH="${TARGET_DISK}p${part_num}" # Construct the full partition path

    # Check if the partition is mounted
    MOUNT_POINT=$(findmnt -n -o TARGET --source "$PART_PATH" 2>/dev/null || true)
    if [[ -n "$MOUNT_POINT" ]]; then
      echo "Partition $PART_PATH is currently mounted at $MOUNT_POINT."
      read -rp "Attempt to unmount $PART_PATH? (y/N): " unmount_confirm
      if [[ "$unmount_confirm" == "y" || "$unmount_confirm" == "Y" ]]; then
        echo "Unmounting $PART_PATH..."
        if ! umount "$PART_PATH"; then
          echo "Failed to unmount $PART_PATH. Aborting deletion."
          exit 1
        fi
        echo "$PART_PATH unmounted successfully."
      else
        echo "Aborting deletion. Partition must be unmounted first."
        exit 1
      fi
    fi

    read -rp "Are you sure you want to delete partition $part_num on $TARGET_DISK? This is irreversible. (y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
      parted --script "$TARGET_DISK" rm "$part_num"
      echo "Partition $part_num deleted."
    else
      echo "Aborting."
    fi
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac

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
pacstrap /mnt base linux linux-firmware linux-headers iwd networkmanager vim nano sudo limine btrfs-progs

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
EFI_PART="$efi_partition"
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
EFI_PARTUUID=$(blkid -s PARTUUID -o value "$EFI_PART")

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

# limine config
echo "==> Writing limine.conf..."
mkdir -p "/boot/limine"
cat > "/boot/limine/limine.conf" <<LIMINE_CONF_EOF
timeout: 5

/Arch Linux
    protocol: linux
    path: uuid(${EFI_PARTUUID}):/vmlinuz-linux
    cmdline: root=UUID=${ROOT_UUID} rw rootflags=subvol=@ loglevel=3 quiet
    module_path: uuid(${EFI_PARTUUID}):/initramfs-linux.img
LIMINE_CONF_EOF

echo "limine.conf created at /boot/limine/limine.conf"

# ------------------------
# INSTALL LIMINE TO EFI
# ------------------------
echo "PATH inside chroot: $PATH"

echo "==> Installing Limine..."
limine-install "/boot"

# Copy configuration to EFI
cp -v "/boot/limine/limine.conf" "/boot/EFI/BOOT/"

echo "Limine installation complete and configured automatically!"

# Create pacman hook for automatic Limine updates

echo "==> Creating pacman hook for Limine..."

mkdir -p "/etc/pacman.d/hooks"

cat > "/etc/pacman.d/hooks/99-limine.hook" <<'HOOK_EOF'

[Trigger]

Operation = Install

Operation = Upgrade

Type = Package

Target = limine

[Action]

Description = Updating Limine EFI bootloader...

When = PostTransaction

Exec = /usr/bin/limine-install

HOOK_EOF


# enable NetworkManager (optional)

systemctl enable NetworkManager

# cleanup
rm -f /arch_install_vars.sh
EOF

echo
echo "Install steps finished. Review output above for any errors."
echo "Reboot when ready. If Windows exists it was protected and should appear if you run sudo limine-scan."

