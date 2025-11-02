#!/usr/bin/env bash
set -euo pipefail

echo "=== Arch Linux Installer (LUKS2 + BTRFS + Limine) ==="

# ========= SHOW DISKS =========
echo
echo "Available disks:"
lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/"
echo
read -rp "Select installation disk (e.g. /dev/nvme0n1): " DISK

if [[ ! -b "$DISK" ]]; then
    echo "❌ Invalid disk."
    exit 1
fi

# ========= SHOW PARTITIONS & FREE SPACE =========
echo
echo "Current partition layout of $DISK:"
parted "$DISK" -lm print free | \
awk -F: 'NR==1 {next}
         /free/ {printf "\033[1;32m%-10s%-15s%-15s%s\033[0m\n","FREE",""$2"",""$3"",""$4""}
         !/free/ {printf "%-10s%-15s%-15s%s\n",$1,$2,$3,$4}'

# ========= USER DETAILS =========
read -rp "Enter username: " USERNAME
read -srp "Enter user password: " USER_PASS; echo
read -srp "Enter root password: " ROOT_PASS; echo
read -srp "Enter LUKS encryption password: " LUKS_PASS; echo

# ========= GEO TIMEZONE =========
echo "Detecting timezone..."
TIMEZONE=$(curl -s https://ipapi.co/timezone || echo "UTC")
echo "Using timezone: $TIMEZONE"

# ========= WINDOWS DETECTION =========
HAS_WINDOWS=$(lsblk -f "$DISK" | grep -qi "ntfs" && echo 1 || echo 0)

if [[ "$HAS_WINDOWS" -eq 1 ]]; then
    echo
    echo "⚠️  Windows partitions detected on $DISK!"
    echo "Choose installation mode:"
    echo "1) Wipe entire disk and install Arch (⚠️ Destroys all data)"
    echo "2) Keep Windows and use existing free space for Arch"
    read -rp "Enter choice (1 or 2): " CHOICE
else
    echo
    echo "No Windows detected."
    echo "Choose installation mode:"
    echo "1) Wipe entire disk"
    echo "2) Use existing free space (if any)"
    read -rp "Enter choice (1 or 2): " CHOICE
fi

# ========= PARTITIONING =========
if [[ "$CHOICE" == "1" ]]; then
    echo "--- Wiping disk ---"
    sgdisk --zap-all "$DISK"
    parted --script "$DISK" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 2049MiB \
        set 1 esp on \
        mkpart Linux btrfs 2050MiB 100%

    ESP="${DISK}p1"
    ROOT="${DISK}p2"

else
    echo "--- Using free space ---"
    echo "Analyzing free space..."
    FREE_REGION=$(parted -m "$DISK" unit MiB print free | awk -F: '$1!~/Model/ && /free/ {print $2" "$3}' | awk '{if($2-$1>4096){print $1,$2;exit}}')
    if [[ -z "$FREE_REGION" ]]; then
        echo "❌ No sufficient free space found (need >4 GiB)."
        exit 1
    fi
    read FREE_START FREE_END <<< "$FREE_REGION"
    echo "Found free region: ${FREE_START}–${FREE_END} MiB"

    EFI_START="$FREE_START"
    EFI_END=$((EFI_START + 2048))
    ROOT_START=$((EFI_END + 1))
    ROOT_END="$FREE_END"

    echo
    echo "Proposed layout:"
    echo "  EFI : ${EFI_START}–${EFI_END} MiB (~2 GiB)"
    echo "  ROOT: ${ROOT_START}–${ROOT_END} MiB (rest)"
    read -rp "Proceed with this partitioning? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1

    parted --script "$DISK" \
        mkpart ESP fat32 "${EFI_START}MiB" "${EFI_END}MiB" \
        set 1 esp on
    parted --script "$DISK" \
        mkpart Linux btrfs "${ROOT_START}MiB" "${ROOT_END}MiB"

    # find newly created partitions by highest numbers
    ESP=$(ls ${DISK}* | sort | tail -n 2 | head -n 1)
    ROOT=$(ls ${DISK}* | sort | tail -n 1)
    echo "Created $ESP (EFI) and $ROOT (ROOT)"
fi

# ========= FORMAT & MOUNT =========
mkfs.fat -F32 "$ESP"

echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT" -
echo -n "$LUKS_PASS" | cryptsetup open "$ROOT" root -

mkfs.btrfs /dev/mapper/root
mount /dev/mapper/root /mnt

for sv in @ @home @var_log @var_cache @snapshots; do
    btrfs subvolume create /mnt/$sv
done

umount /mnt

mount -o compress=zstd:1,noatime,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o compress=zstd:1,noatime,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_log /dev/mapper/root /mnt/var/log
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_cache /dev/mapper/root /mnt/var/cache
mount --mkdir -o compress=zstd:1,noatime,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
mount --mkdir "$ESP" /mnt/boot

# ========= INSTALL SYSTEM =========
echo "--- Installing base system ---"
pacman -Sy --noconfirm archlinux-keyring
pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs efibootmgr \
    limine cryptsetup networkmanager reflector sudo vim intel-ucode \
    dhcpcd iwd firewalld bluez bluez-utils acpid avahi rsync bash-completion \
    pipewire pipewire-alsa pipewire-pulse wireplumber sof-firmware

genfstab -U /mnt >> /mnt/etc/fstab

# ========= CHROOT CONFIG =========
arch-chroot /mnt /bin/bash -e <<EOF
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

# mkinitcpio
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^#BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# limine setup
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
efibootmgr --create --disk $DISK --part 1 \
    --label "Arch Linux Limine Bootloader" \
    --loader '\\EFI\\limine\\BOOTX64.EFI' --unicode

LUKS_UUID=\$(cryptsetup luksUUID $ROOT)
cat <<LIMINE > /boot/EFI/limine/limine.conf
timeout: 5

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
LIMINE

for s in NetworkManager dhcpcd iwd systemd-networkd systemd-resolved bluetooth cups avahi-daemon firewalld acpid reflector.timer; do
    systemctl enable \$s
done
EOF

umount -R /mnt
cryptsetup close root
echo "✅ Installation complete! Reboot to start Arch Linux."

