#!/usr/bin/env bash
set -euo pipefail

#v1

# Helper functions
err() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# Enable NTP
info "Enabling NTP..."
systemctl enable systemd-timesyncd
systemctl start systemd-timesyncd
sleep 2
timedatectl set-ntp true

# Disk selection
DISKS=()
mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|nvme|vd)" | awk '{print $1"|"$0}')

(( ${#DISKS[@]} )) || err "No installable disks found"

echo "Available disks:"
for i in "${!DISKS[@]}"; do
    echo "$i) ${DISKS[$i]}"
done

read -rp "Select disk index [0]: " DISK_IDX
DISK_IDX=${DISK_IDX:-0}

# Validate input
[[ $DISK_IDX =~ ^[0-9]+$ ]] || err "Invalid index"
[[ $DISK_IDX -lt ${#DISKS[@]} ]] || err "Index out of range"

DISK=${DISKS[$DISK_IDX]}
DISK=${DISK%%|*}

read -rp "Erase all data on $DISK? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1

# Detect firmware
FIRMWARE=BIOS
[[ -d /sys/firmware/efi/efivars ]] && FIRMWARE=UEFI
info "Firmware detected: $FIRMWARE"

# Filesystem choice
echo "Filesystem options:"
echo "1) Btrfs on LUKS (recommended)"
echo "2) ext4 (optional /home)"
read -rp "Choice [1]: " FS_CHOICE
FS_CHOICE=${FS_CHOICE:-1}
if [[ $FS_CHOICE -eq 2 ]]; then
    FS=ext4
else
    FS=btrfs
fi

read -rp "Enter EFI size (e.g., 512M) [512M]: " EFI_SIZE
EFI_SIZE=${EFI_SIZE:-512M}

SEPARATE_HOME=no
HOME_SIZE=""
if [[ "$FS" == ext4 ]]; then
    read -rp "Create separate /home? [y/N]: " HOME_CHOICE
    [[ "$HOME_CHOICE" =~ ^[Yy]$ ]] && SEPARATE_HOME=yes
    if [[ $SEPARATE_HOME == yes ]]; then
        read -rp "Enter /home size (rest goes to /, e.g., 100G): " HOME_SIZE
    fi
fi

# User info
read -rp "Hostname [arch]: " HOSTNAME
HOSTNAME=${HOSTNAME:-arch}

read -rp "Username [archuser]: " USERNAME
USERNAME=${USERNAME:-archuser}

read -rsp "User password [archuser]: " USERPASS
echo
USERPASS=${USERPASS:-archuser}

read -rsp "Root password [root]: " ROOTPASS
echo
ROOTPASS=${ROOTPASS:-root}

# Sudo mode
echo "Sudo mode:"
echo "1) pw - User in wheel, sudo with password"
echo "2) nopw - User in wheel, passwordless sudo"
echo "3) none - No sudo"
read -rp "Choice [1]: " SUDO_CHOICE
SUDO_CHOICE=${SUDO_CHOICE:-1}
case $SUDO_CHOICE in
    1) SUDO_MODE=pw ;;
    2) SUDO_MODE=nopw ;;
    3) SUDO_MODE=none ;;
    *) SUDO_MODE=pw ;;
esac

read -rp "Timezone [Europe/Bucharest]: " TZONE
TZONE=${TZONE:-Europe/Bucharest}

LOCALES_STR="en_US.UTF-8"

# Partitioning
info "Partitioning $DISK ..."
parted -s "$DISK" mklabel gpt

START="1MiB"
EFI_END="$EFI_SIZE"

if [[ $FIRMWARE == BIOS ]]; then
    parted -s "$DISK" mkpart bios_boot "1MiB" "3MiB"
    parted -s "$DISK" set 1 bios_grub on
    START="3MiB"
fi

# Create EFI partition
parted -s "$DISK" mkpart EFI fat32 "$START" "$EFI_END"
if [[ $FIRMWARE == UEFI ]]; then
    parted -s "$DISK" set 2 esp on
fi

NEXT_START=$(parted -sm "$DISK" unit MiB print | awk -F: '/^/ {if ($1==2){gsub(/MiB/,"",$3); print $3+1"MiB"}}')

# Create root and optional home partitions
if [[ "$FS" == btrfs ]]; then
    # For btrfs, create one encrypted partition
    parted -s "$DISK" mkpart cryptroot "$NEXT_START" "100%"
    P2="${DISK}p3"
else
    # For ext4
    if [[ $SEPARATE_HOME == yes && -n "$HOME_SIZE" ]]; then
        # Calculate sizes
        parted -s "$DISK" mkpart root "$NEXT_START" "-${HOME_SIZE}"
        parted -s "$DISK" mkpart home "-${HOME_SIZE}" "100%"
        P2="${DISK}p3"
        P3="${DISK}p4"
    else
        # Single root partition
        parted -s "$DISK" mkpart root "$NEXT_START" "100%"
        P2="${DISK}p3"
        P3=""
    fi
fi

partprobe "$DISK"
sleep 2

# Assign partition device names
if [[ "$DISK" == *nvme* ]]; then
    P1="${DISK}p1"
    P2="${DISK}p2"
    [[ -n "$P3" ]] && P3="${DISK}p3"
else
    P1="${DISK}1"
    P2="${DISK}2"
    [[ -n "$P3" ]] && P3="${DISK}3"
fi

# Format EFI partition
mkfs.vfat -F32 "$P1"

# Formatting and mounting
if [[ "$FS" == btrfs ]]; then
    # Encrypt root partition
    cryptsetup -y -v luksFormat "$P2"
    cryptsetup open "$P2" cryptroot
    mkfs.btrfs -f -L ROOT /dev/mapper/cryptroot

    mount /dev/mapper/cryptroot /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    umount /mnt

    # Mount subvolumes
    mount -o subvol=@,compress=zstd,noatime /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/{boot,home}
    mount -o subvol=@home,compress=zstd,noatime /dev/mapper/cryptroot /mnt/home
    mount "$P1" /mnt/boot
else
    # ext4 fallback
    echo "Formatting root partition ($P2) as ext4..."
    mkfs.ext4 -F "$P2"
    mount "$P2" /mnt
    mkdir -p /mnt/boot
    mount "$P1" /mnt/boot

    if [[ "$SEPARATE_HOME" == yes && -n "$P3" ]]; then
        echo "Formatting /home partition ($P3) as ext4..."
        mkfs.ext4 -F "$P3"
        mkdir -p /mnt/home
        mount "$P3" /mnt/home
    fi
fi

# Refresh mirrors
info "Refreshing mirrors..."
COUNTRY=$(curl -fsSL https://ipapi.co/country_name || true)
if [[ -n ${COUNTRY:-} ]]; then
    reflector --protocol https --country "$COUNTRY" --latest 30 --sort rate --save /etc/pacman.d/mirrorlist || true
else
    reflector --protocol https --latest 30 --sort rate --save /etc/pacman.d/mirrorlist || true
fi

# Package installation
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2); print $2}')
MICROCODE=()
case "$CPU_VENDOR" in
    GenuineIntel) MICROCODE+=(intel-ucode) ;;
    AuthenticAMD) MICROCODE+=(amd-ucode) ;;
esac

GPUINFO=$(lspci | grep -E "VGA|3D|Display" || true)
GPU_PKGS=(mesa)
echo "$GPUINFO" | grep -qi nvidia && GPU_PKGS+=(nvidia nvidia-utils linux-headers nvidia-settings)

BASE_PKGS=(base linux base-devel linux-firmware git networkmanager sudo nano vim \
           btrfs-progs dosfstools e2fsprogs cryptsetup grub efibootmgr reflector)
ALL_PKGS=("${BASE_PKGS[@]}" "${MICROCODE[@]}" "${GPU_PKGS[@]}")

info "Installing base system..."
pacstrap -K /mnt "${ALL_PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot setup
info "Configuring system inside chroot..."
arch-chroot /mnt env \
    USERNAME="$USERNAME" \
    USERPASS="$USERPASS" \
    ROOTPASS="$ROOTPASS" \
    HOSTNAME="$HOSTNAME" \
    SUDO_MODE="$SUDO_MODE" \
    FS="$FS" \
    TZONE="$TZONE" \
    LOCALES_STR="$LOCALES_STR" \
    /bin/bash -e <<'CHROOT'
set -euo pipefail

LOCALES=($LOCALES_STR)

# Timezone
ln -sf /usr/share/zoneinfo/$TZONE /etc/localtime
hwclock --systohc || true

# Locales
for loc in "${LOCALES[@]}"; do
    sed -i "s/^#\(${loc} UTF-8\)/\1/" /etc/locale.gen || true
done
locale-gen
echo "LANG=${LOCALES[0]}" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# mkinitcpio hooks
if [[ "$FS" == btrfs ]]; then
    sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems btrfs fsck)/' /etc/mkinitcpio.conf
else
    sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# Users
usermod -p "*" root >/dev/null 2>&1 || true
echo "Creating user: $USERNAME"
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
echo -e "$ROOTPASS\n$ROOTPASS" | passwd root

# Sudo setup
case "$SUDO_MODE" in
    pw)
        sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
        ;;
    nopw)
        echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99_wheel_nopw
        chmod 440 /etc/sudoers.d/99_wheel_nopw
        ;;
    none) ;;
esac

# Enable NetworkManager
systemctl enable NetworkManager
CHROOT

# Install GRUB
info "Installing GRUB..."
if [[ $FIRMWARE == UEFI ]]; then
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
    arch-chroot /mnt grub-install --target=i386-pc "$DISK"
fi

# Determine UUID for root or cryptroot
if [[ "$FS" == btrfs ]]; then
    CRYPT_UUID=$(blkid -s UUID -o value "$P2")
    GRUB_CMDLINE="cryptdevice=UUID=$CRYPT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw"
else
    ROOT_UUID=$(blkid -s UUID -o value "$P2")
    GRUB_CMDLINE="root=UUID=$ROOT_UUID rw"
fi

arch-chroot /mnt bash -c "sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE\"|' /etc/default/grub"
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Step: Install yay and Google Chrome
arch-chroot /mnt /bin/bash -e <<'YAY'
set -euo pipefail

USERNAME=$(awk -F: '($3>=1000)&&($1!="nobody"){print $1; exit}' /etc/passwd)
USERHOME="/home/$USERNAME"

echo "[INFO] Installing yay and Google Chrome for user: $USERNAME"
mkdir -p "$USERHOME"
chown -R "$USERNAME:$USERNAME" "$USERHOME"
cd "$USERHOME"

# Clone yay-bin
if [[ ! -d yay-bin ]]; then
    sudo -u "$USERNAME" git clone https://aur.archlinux.org/yay-bin.git
fi
cd yay-bin
sudo -u "$USERNAME" makepkg -si --noconfirm
cd ..

# Install Google Chrome
sudo -u "$USERNAME" yay -S --noconfirm google-chrome

# Create after_selection.sh script
cat > "$USERHOME/after_selection.sh" <<'CHOICE'
#!/bin/bash
set -euo pipefail

USERNAME=$(whoami)
USERHOME="/home/$USERNAME"

echo "Choose a program to install:"
echo "1) JaKooLit (Arch-Hyprland)"
echo "2) Omarchy"
read -rp "Selection [1/2, empty to skip]: " PROG_CHOICE

case "$PROG_CHOICE" in
    1)
        REPO="https://github.com/JaKooLit/Arch-Hyprland"
        DIR="$USERHOME/Arch-Hyprland"
        ;;
    2)
        REPO="https://github.com/basecamp/omarchy"
        DIR="$USERHOME/.local/share/omarchy"
        ;;
    *)
        echo "No custom program selected, skipping."
        exit 0
        ;;
esac

if [[ ! -d "$DIR" ]]; then
    git clone "$REPO" "$DIR"
fi
cd "$DIR"

if [[ -f install.sh ]]; then
    bash install.sh
fi

echo "[INFO] $PROG_CHOICE installation complete!"
CHOICE
chmod +x "$USERHOME/after_selection.sh"
chown "$USERNAME:$USERNAME" "$USERHOME/after_selection.sh"
echo "[INFO] Yay and Chrome installed. A script 'after_selection.sh' has been placed in your home folder."
YAY
