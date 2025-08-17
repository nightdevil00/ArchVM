#!/bin/bash
set -e

# ========== CONFIGURATION ==========
DISK="/dev/vda"       # e.g., /dev/vda, /dev/sda, /dev/nvme0n1
USERNAME="mihai"
PASSWORD="1234"
HOSTNAME="arch"
LOCALE="en_US.UTF-8"
KEYMAP="us"
TIMEZONE="Europe/Bucharest"
FILESYSTEM="ext4"          # ext4, btrfs, xfs
EXTRA_PKGS_FILE="./extra_packages.txt"
ARCH_ISO_URL="https://mirror.rackspace.com/archlinux/iso/latest/archlinux-x86_64.iso"
# ==================================

# Ensure root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Ensure UEFI
if [ ! -d /sys/firmware/efi ]; then
    echo "Error: UEFI firmware not detected. Boot in UEFI mode."
    exit 1
fi

require_cmds() {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    if ((${#missing[@]})); then
        echo "Installing missing tools: ${missing[*]}"
        pacman -Sy --noconfirm "${missing[@]}"
    fi
}

# Ensure filesystem tools are available
case "$FILESYSTEM" in
    ext4) require_cmds e2fsprogs ;;
    btrfs) require_cmds btrfs-progs ;;
    xfs) require_cmds xfsprogs ;;
esac

# Detect partition suffix for NVMe drives
if [[ "$DISK" =~ nvme ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
  RECOVERY_PART="${DISK}p3"
  HOME_PART="${DISK}p4"
else
  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
  RECOVERY_PART="${DISK}3"
  HOME_PART="${DISK}4"
fi

echo "Starting Arch Linux installation on $DISK..."

# 1. Wipe existing partitions
echo "Wiping existing partitions on $DISK..."
sgdisk --zap-all $DISK

# 2. Create partitions
echo "Creating partitions..."
sgdisk -n 1:0:+1024M -t 1:ef00 $DISK
sgdisk -n 2:0:+20G  -t 2:8300 $DISK
sgdisk -n 3:0:+4G    -t 3:8300 $DISK
sgdisk -n 4:0:0      -t 4:8302 $DISK

# 3. Format partitions
echo "Formatting EFI partition as FAT32..."
mkfs.fat -F32 $EFI_PART

echo "Formatting root partition as $FILESYSTEM..."
mkfs.$FILESYSTEM $ROOT_PART

echo "Formatting recovery partition as $FILESYSTEM..."
mkfs.$FILESYSTEM $RECOVERY_PART

echo "Formatting home partition as $FILESYSTEM..."
mkfs.$FILESYSTEM $HOME_PART

# 4. Mount partitions
echo "Mounting root partition..."
mount $ROOT_PART /mnt

echo "Creating and mounting EFI partition..."
mkdir -p /mnt/boot/efi
mount $EFI_PART /mnt/boot/efi

echo "Creating and mounting recovery partition..."
mkdir -p /mnt/recovery
mount $RECOVERY_PART /mnt/recovery

echo "Creating and mounting home partition..."
mkdir -p /mnt/home
mount $HOME_PART /mnt/home

require_cmds reflector python curl

echo "=== Optimizing mirrors for installation (Bucharest + nearby) ==="
reflector --country Romania --country Germany --country Netherlands \
  --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# 5. Download Arch ISO into recovery 🔧
echo "=== Downloading Arch ISO into recovery partition ==="
curl -L "$ARCH_ISO_URL" -o /mnt/recovery/archlinux.iso

# 6. Desktop Environment
echo "Choose a Desktop Environment:"
select DE in "None (minimal)" "GNOME" "KDE Plasma" "XFCE" "Cinnamon"; do
  case $REPLY in
    1) DE_PKGS=""; DM=""; break ;;
    2) DE_PKGS="gnome gnome-extra"; DM="gdm"; break ;;
    3) DE_PKGS="plasma konsole"; DM="sddm"; break ;;
    4) DE_PKGS="xfce4 xfce4-goodies"; DM="lightdm lightdm-gtk-greeter"; break ;;
    5) DE_PKGS="cinnamon"; DM="lightdm lightdm-gtk-greeter"; break ;;
    *) echo "Invalid choice"; continue ;;
  esac
done

# 7. Read extra packages
if [ -f "$EXTRA_PKGS_FILE" ]; then
    EXTRA_PKGS=$(grep -vE "^\s*#|^\s*$" "$EXTRA_PKGS_FILE" | tr '\n' ' ')
else
    echo "Warning: $EXTRA_PKGS_FILE not found. Continuing without extra packages."
    EXTRA_PKGS=""
fi

# 8. Install base packages
echo "Installing base system and packages..."
pacstrap /mnt base base-devel linux linux-firmware sudo vim grub efibootmgr networkmanager git flatpak wget p7zip firefox man-db man-pages bash-completion $DE_PKGS $DM $EXTRA_PKGS

# 9. Generate fstab
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# 10. Configure system inside chroot
echo "Configuring system..."
arch-chroot /mnt /bin/bash -e <<EOF

echo $HOSTNAME > /etc/hostname

# Setup hosts file
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		    localhost
127.0.1.1	$HOSTNAME.localdomain $HOSTNAME
HOSTS

# Timezone setup
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale setup
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Optimize pacman configuration
echo "=== Optimizing mirrors for installed system ==="
reflector --country Romania --country Germany --country Netherlands \
  --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

echo "=== Customizing pacman.conf ==="
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
#grep -q "ILoveCandy" /etc/pacman.conf || echo "ILoveCandy" >> /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
# Enable multilib
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

# Update package databases and upgrade system
echo "=== Updating system after enabling multilib ==="
pacman -Syu --noconfirm

# Set root password
echo root:$PASSWORD | chpasswd

# Add user, set password, add to wheel group for sudo
echo "Creating user: $USERNAME"
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo $USERNAME:$PASSWORD | chpasswd

# Allow wheel group sudo without password prompt (optional)
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# Enable essential services
systemctl enable NetworkManager
[[ "$DM" == *gdm* ]] && systemctl enable gdm
[[ "$DM" == *sddm* ]] && systemctl enable sddm
[[ "$DM" == *lightdm* ]] && systemctl enable lightdm
systemctl enable bluetooth.service || true

# Install and configure GRUB for UEFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

### Add custom GRUB entry for recovery ISO
echo "=== Adding GRUB recovery ISO entry ==="
cat <<'EOF_GRUB' >> /etc/grub.d/40_custom

menuentry "Arch Linux Recovery ISO (loopback)" {
    set isofile="/archlinux.iso"
    search --no-floppy --set=iso_part --file \$isofile
    loopback loop (\$iso_part)\$isofile
    linux (loop)/arch/boot/x86_64/vmlinuz-linux img_dev=/dev/disk/by-uuid/$(blkid -s UUID -o value $RECOVERY_PART) img_loop=\$isofile earlymodules=loop
    initrd (loop)/arch/boot/x86_64/initramfs-linux.img
}
EOF_GRUB

# Rebuild GRUB config so new entry shows up
grub-mkconfig -o /boot/grub/grub.cfg



echo "=== Creating ISO update script ==="
cat <<UPDATESCRIPT > /usr/local/bin/update-recovery-iso
#!/bin/bash
set -e
UUID="\$UUID_RECOVERY"
MOUNTPOINT="/tmp/recovery-\$UUID"
mkdir -p "\$MOUNTPOINT"
mount UUID="\$UUID" "\$MOUNTPOINT"
echo "Downloading latest Arch ISO..."
curl -L "$ARCH_ISO_URL" -o "\$MOUNTPOINT/archlinux.iso"
umount "\$MOUNTPOINT"
echo "Recovery ISO updated."
UPDATESCRIPT

chmod +x /usr/local/bin/update-recovery-iso

echo "=== Creating systemd service and timer ==="
cat <<SERVICE > /etc/systemd/system/update-recovery-iso.service
[Unit]
Description=Update Recovery ISO

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-recovery-iso
SERVICE

cat <<TIMER > /etc/systemd/system/update-recovery-iso.timer
[Unit]
Description=Weekly update of Recovery ISO

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl enable update-recovery-iso.timer

EOF

echo "Arch Linux UEFI installation complete. You can reboot now."
