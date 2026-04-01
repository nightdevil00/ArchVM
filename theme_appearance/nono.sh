#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Interactive Install Script with Windows Dualboot support and Limine bootloader
# ==============================================================================
# DISCLAIMER: For educational/personal use only. Review carefully before running.
# ==============================================================================

set -euo pipefail

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

TMP_MOUNT="/mnt/__arch_install_tmp"
mkdir -p "$TMP_MOUNT"

# --- Detect disks ---
declare -a DEVICES=()
declare -A DEV_MODEL DEV_SIZE DEV_TRAN DEV_MOUNT

while IFS= read -r line; do
    eval "$line"
    [[ "${TYPE:-}" == "disk" ]] || continue
    DEVICES+=("/dev/${NAME}")
    DEV_MODEL["/dev/${NAME}"]="${MODEL:-unknown}"
    DEV_SIZE["/dev/${NAME}"]="${SIZE:-unknown}"
    DEV_TRAN["/dev/${NAME}"]="${TRAN:-unknown}"
    DEV_MOUNT["/dev/${NAME}"]="${MOUNTPOINT:-}"
done < <(lsblk -P -o NAME,KNAME,TYPE,SIZE,MODEL,TRAN,MOUNTPOINT)

if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "No block devices found. Exiting."
    exit 1
fi

echo "Available physical disks:"
for i in "${!DEVICES[@]}"; do
    idx=$((i+1))
    d=${DEVICES[$i]}
    printf "%2d) %-12s  %8s  %-10s  transport=%s\n" "$idx" "$d" "${DEV_SIZE[$d]}" "${DEV_MODEL[$d]}" "${DEV_TRAN[$d]}"
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
echo "Scanning all partitions on $TARGET_DISK for Windows boot files..."
declare -A PROTECTED_PARTS=()  # initialize properly

mapfile -t PARTS_ARRAY < <(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}')

for part in "${PARTS_ARRAY[@]}"; do
    FSTYPE=$(blkid -s TYPE -o value "$part" 2>/dev/null || true)
    [[ -z "$FSTYPE" ]] && continue

    # check EFI Microsoft
    if [[ "$FSTYPE" == "vfat" || "$FSTYPE" == "fat32" ]]; then
        mkdir -p "$TMP_MOUNT"
        if mount -o ro,noload "$part" "$TMP_MOUNT" 2>/dev/null; then
            if [[ -d "$TMP_MOUNT/EFI/Microsoft" ]]; then
                PROTECTED_PARTS["$part"]="EFI Microsoft files found"
                echo "Protected (EFI): $part"
            fi
            umount "$TMP_MOUNT"
        fi
    fi

    # check NTFS Windows
    if [[ "$FSTYPE" == "ntfs" ]]; then
        mkdir -p "$TMP_MOUNT"
        if mount -o ro,noload "$part" "$TMP_MOUNT" 2>/dev/null; then
            if [[ -d "$TMP_MOUNT/Windows" || -f "$TMP_MOUNT/bootmgr" ]]; then
                PROTECTED_PARTS["$part"]="NTFS Windows files found"
                echo "Protected (NTFS): $part"
            fi
            umount "$TMP_MOUNT"
        fi
    fi
done

# --- Partitioning ---
if [ ${#PROTECTED_PARTS[@]} -gt 0 ]; then
    echo
    echo "Detected Windows partitions. Only free space will be used."
    parted --script "$TARGET_DISK" unit GB print free
    read -rp "EFI start (GB): " EFI_START
    read -rp "EFI end (GB): " EFI_END
    read -rp "Root start (GB): " ROOT_START
    read -rp "Root end (GB or 100%): " ROOT_END

    parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END"
    parted --script "$TARGET_DISK" set $(parted -s "$TARGET_DISK" print | awk '/^ /{n++; print n; exit}') boot on
    parted --script "$TARGET_DISK" mkpart primary btrfs "$ROOT_START" "$ROOT_END"
else
    echo "No Windows detected. Using full disk."
    parted --script "$TARGET_DISK" mklabel gpt
    parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
    parted --script "$TARGET_DISK" set 1 boot on
    parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
fi

partprobe "$TARGET_DISK"

# --- Assign EFI and root partitions reliably ---
mapfile -t NEW_PARTS < <(lsblk -ln -o NAME,TYPE,FSTYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1":"$3":"$4}')

efi_partition=""
root_partition=""

for p in "${NEW_PARTS[@]}"; do
    IFS=":" read -r DEV UUID FSTYPE <<< "$p"
    if [[ "$FSTYPE" == "vfat" || "$FSTYPE" == "fat32" ]]; then
        efi_partition="$DEV"
    elif [[ "$FSTYPE" == "btrfs" || "$FSTYPE" == "" ]]; then
        root_partition="$DEV"
    fi
done

if [[ -z "$efi_partition" || -z "$root_partition" ]]; then
    echo "Could not determine EFI or root partition. Exiting."
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$TARGET_DISK"
    exit 1
fi

echo "EFI partition: $efi_partition"
echo "Root partition: $root_partition"

# --- Format & encrypt ---
mkfs.fat -F32 "$efi_partition"
cryptsetup luksFormat "$root_partition"
cryptsetup luksOpen "$root_partition" cryptroot
mkfs.btrfs -f /dev/mapper/cryptroot

# --- BTRFS subvolumes ---
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
mkdir -p /mnt/boot
mount "$efi_partition" /mnt/boot

# --- Base install ---
pacstrap /mnt base base-devel linux linux-firmware linux-headers vim sudo networkmanager btrfs-progs iwd limine efibootmgr

# --- FSTAB ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- User setup ---
read -rp "New username: " username
read -rsp "Password for $username: " user_password; echo
read -rsp "Root password: " root_password; echo

cat > /mnt/arch_install_vars.sh <<EOF
ROOT_PART="$root_partition"
USERNAME="$username"
USER_PASS="$user_password"
ROOT_PASS="$root_password"
EFI_PART="$efi_partition"
EOF

# --- Chroot & configure ---
arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail
source /arch_install_vars.sh

# Timezone & locale
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "arch-linux" > /etc/hostname

# Passwords
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers

# Crypttab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
echo "cryptroot UUID=$ROOT_UUID none luks,discard" > /etc/crypttab

# Mkinitcpio
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Limine installation
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
efibootmgr --create --disk "$EFI_PART" --part 1 --label "Arch Linux Limine" --loader '\EFI\limine\BOOTX64.EFI' --unicode

# Limine config
cat > /boot/limine.conf <<LIMCONF
timeout: 3

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux-fallback.img
LIMCONF

# Enable NetworkManager
systemctl enable NetworkManager

mkinitcpio -P

# Cleanup
rm -f /arch_install_vars.sh
EOF

echo
echo "Arch installation with Limine completed!"
echo "Reboot and remove installation media."
