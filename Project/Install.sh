#!/usr/bin/env bash
set -euo pipefail

echo "=== Arch Linux Installer (LUKS2 + BTRFS + Limine) ==="
echo "=== Dual Boot Support ==="
echo

TMP_MOUNT="/mnt/__arch_install_tmp"
mkdir -p "$TMP_MOUNT"

declare -a DEVICES=()
declare -A DEV_MODEL DEV_SIZE DEV_TRAN
declare PROTECTED_PARTS=()

while IFS= read -r line; do
    eval "$line"
    if [[ "${TYPE:-}" == "disk" ]]; then
        devpath="/dev/${NAME}"
        DEVICES+=("$devpath")
        DEV_MODEL["$devpath"]="${MODEL:-unknown}"
        DEV_SIZE["$devpath"]="${SIZE:-unknown}"
        DEV_TRAN["$devpath"]="${TRAN:-unknown}"
    fi
done < <(lsblk -P -o NAME,KNAME,TYPE,SIZE,MODEL,TRAN,MOUNTPOINT)

echo "Available disks:"
for i in "${!DEVICES[@]}"; do
    idx=$((i+1))
    d=${DEVICES[$i]}
    printf "%2d) %-12s %8s %s\n" "$idx" "$d" "${DEV_SIZE[$d]}" "${DEV_MODEL[$d]}"
done

read -rp "Select disk number: " disk_number
TARGET_DISK="${DEVICES[$((disk_number-1))]}"
echo "Selected: $TARGET_DISK"

declare -A PROTECTED_PARTS
while IFS= read -r line; do
    eval "$line"
    if [[ "${TYPE:-}" != "part" ]]; then continue; fi
    PART="/dev/${NAME}"
    [[ "$PART" =~ loop|sr|md|zram ]] && continue
    
    FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)
    
    if [[ "$FSTYPE" == "vfat" || "$FSTYPE" == "fat32" || "$FSTYPE" == "fat" ]]; then
        mkdir -p "$TMP_MOUNT"
        if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
            if [[ -d "$TMP_MOUNT/EFI/Microsoft" ]] || [[ -f "$TMP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
                PROTECTED_PARTS["$PART"]="Windows EFI"
                echo "Found Windows EFI: $PART"
            fi
            umount "$TMP_MOUNT" || true
        fi
    fi
    
    if [[ "$FSTYPE" == "ntfs" ]]; then
        mkdir -p "$TMP_MOUNT"
        if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
            if [[ -d "$TMP_MOUNT/Windows" ]] || [[ -f "$TMP_MOUNT/bootmgr" ]]; then
                PROTECTED_PARTS["$PART"]="Windows NTFS"
                echo "Found Windows: $PART"
            fi
            umount "$TMP_MOUNT" || true
        fi
    fi
done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINT)

DUALBOOT=false
if [ ${#PROTECTED_PARTS[@]} -gt 0 ]; then
    echo
    echo "Windows detected! Dual boot mode."
    DUALBOOT=true
    echo "Current partition layout:"
    parted --script "$TARGET_DISK" unit GB print free
    echo
    read -rp "EFI partition start (e.g. 1GB): " EFI_START
    read -rp "EFI partition end (e.g. 3GB): " EFI_END
    read -rp "Root partition start (e.g. 3GB): " ROOT_START
    read -rp "Root partition end (e.g. 60GB or 100%): " ROOT_END
    
    parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END"
    EFI_PART_NUM=$(parted -s "$TARGET_DISK" print | awk 'END{print $1}')
    parted --script "$TARGET_DISK" set "$EFI_PART_NUM" boot on
    parted --script "$TARGET_DISK" mkpart primary btrfs "$ROOT_START" "$ROOT_END"
    ROOT_PART_NUM=$(parted -s "$TARGET_DISK" print | awk 'END{print $1}')
else
    read -rp "Wipe disk and use entirely for Arch? (yes/no): " yn
    if [[ "$yn" != "yes" ]]; then
        echo "Aborting."
        exit 0
    fi
    sgdisk --zap-all "$TARGET_DISK"
    parted --script "$TARGET_DISK" mklabel gpt
    parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
    parted --script "$TARGET_DISK" set 1 boot on
    parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
    EFI_PART_NUM=1
    ROOT_PART_NUM=2
fi

partprobe "$TARGET_DISK" || true
sleep 2

# Robust partition path detection
if [[ "$TARGET_DISK" == *nvme* || "$TARGET_DISK" == *mmcblk* ]]; then
    efi_partition="${TARGET_DISK}p${EFI_PART_NUM}"
    root_partition="${TARGET_DISK}p${ROOT_PART_NUM}"
else
    efi_partition="${TARGET_DISK}${EFI_PART_NUM}"
    root_partition="${TARGET_DISK}${ROOT_PART_NUM}"
fi

echo "EFI: $efi_partition (Number: $EFI_PART_NUM)"
echo "Root: $root_partition (Number: $ROOT_PART_NUM)"

read -rp "Username: " USERNAME
read -srp "User password: " USER_PASS; echo
read -srp "Root password: " ROOT_PASS; echo
read -srp "LUKS encryption password: " LUKS_PASS; echo

TIMEZONE=$(curl -s https://ipapi.co/timezone 2>/dev/null || echo "UTC")
echo "Using timezone: $TIMEZONE"

echo "Formatting EFI..."
mkfs.fat -F 32 "$efi_partition"

echo "Encrypting root with LUKS2..."
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$root_partition" -
echo -n "$LUKS_PASS" | cryptsetup open "$root_partition" root -

echo "Creating BTRFS..."
mkfs.btrfs -L ARCH_ROOT /dev/mapper/root
mount /dev/mapper/root /mnt

for sub in @ @home @var_log @var_cache @snapshots; do
    btrfs subvolume create "/mnt/$sub"
done

umount /mnt

mount -o compress=zstd:1,noatime,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o compress=zstd:1,noatime,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_log /dev/mapper/root /mnt/var/log
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_cache /dev/mapper/root /mnt/var/cache
mount --mkdir -o compress=zstd:1,noatime,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
mount --mkdir "$efi_partition" /mnt/boot

echo "Installing base system..."
pacman -Sy --noconfirm archlinux-keyring
pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs efibootmgr \
    limine cryptsetup networkmanager reflector sudo vim intel-ucode amd-ucode \
    dhcpcd iwd firewalld bluez bluez-utils acpid avahi rsync bash-completion \
    pipewire pipewire-alsa pipewire-pulse wireplumber sof-firmware

genfstab -U /mnt >> /mnt/etc/fstab

LUKS_UUID=$(cryptsetup luksUUID "$root_partition")

arch-chroot /mnt /bin/bash -e <<CHROOT
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
echo "arch" > /etc/hostname

echo "root:$ROOT_PASS" | chpasswd

useradd -mG wheel $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^#BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

efibootmgr --create --disk $TARGET_DISK --part $EFI_PART_NUM \
    --label "Arch Linux Limine" \
    --loader '\\\\EFI\\\\limine\\\\BOOTX64.EFI' \
    --unicode

cat <<LIMINE > /boot/EFI/limine/limine.conf
timeout: 3

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux-fallback.img
LIMINE

for s in NetworkManager dhcpcd iwd systemd-networkd systemd-resolved bluetooth cups avahi-daemon firewalld acpid reflector.timer; do
    systemctl enable \$s
done
CHROOT

umount -R /mnt
cryptsetup close root

echo
echo "=== Installation Complete! ==="
echo "Reboot and remove installation media."
echo "Bootloader: Limine (select Arch Linux from menu)"
echo "Encryption: LUKS2"
echo "Filesystem: BTRFS with subvolumes (@, @home, @var_log, @var_cache, @snapshots)"
