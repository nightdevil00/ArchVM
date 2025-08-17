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

if blkid -o value -s LABEL "$RECOVERY_PART" | grep -iq "RECOVERY"; then
  echo ">>> Recovery partition detected. Entering REINSTALL MODE..."
  MODE="reinstall"
else
  echo ">>> No recovery partition found. Entering FRESH INSTALL MODE..."
  MODE="fresh"
fi

# ---------------- Partitioning and formatting ----------------
if [ "$MODE" = "fresh" ]; then
    # Fresh install
    echo "Wiping all partitions on $DISK..."
    sgdisk --zap-all $DISK

    echo "Creating partitions..."
    sgdisk -n 1:0:+1024M -t 1:ef00 $DISK   # EFI
    sgdisk -n 2:0:+20G   -t 2:8300 $DISK   # ROOT
    sgdisk -n 3:0:+4G    -t 3:8300 $DISK   # RECOVERY
    sgdisk -n 4:0:0      -t 4:8302 $DISK   # HOME

    echo "Formatting EFI partition..."
    mkfs.fat -F32 $EFI_PART

    echo "Formatting root partition..."
    mkfs.$FILESYSTEM $ROOT_PART

    echo "Formatting recovery partition..."
    mkfs.$FILESYSTEM -L RECOVERY $RECOVERY_PART

    echo "Formatting home partition..."
    mkfs.$FILESYSTEM $HOME_PART

    # Mount partitions
    mount $ROOT_PART /mnt
    mkdir -p /mnt/boot/efi
    mount $EFI_PART /mnt/boot/efi
    mkdir -p /mnt/recovery
    mount $RECOVERY_PART /mnt/recovery
    mkdir -p /mnt/home
    mount $HOME_PART /mnt/home

else
    # Reinstall mode
    echo "Wiping disk except recovery partition..."
    sgdisk --zap-all $DISK

    echo "Re-creating EFI, ROOT, HOME partitions..."
    sgdisk -n 1:0:+1024M -t 1:ef00 $DISK   # EFI
    sgdisk -n 2:0:+20G   -t 2:8300 $DISK   # ROOT
    sgdisk -n 4:0:0      -t 4:8302 $DISK   # HOME

    echo "Formatting EFI partition..."
    mkfs.fat -F32 $EFI_PART

    echo "Formatting root partition..."
    mkfs.$FILESYSTEM $ROOT_PART

    echo "Formatting home partition..."
    mkfs.$FILESYSTEM $HOME_PART

    # Mount partitions
    mount $ROOT_PART /mnt
    mkdir -p /mnt/boot/efi
    mount $EFI_PART /mnt/boot/efi
    mkdir -p /mnt/recovery
    mount -o ro $RECOVERY_PART /mnt/recovery
    mkdir -p /mnt/home
    mount $HOME_PART /mnt/home
fi

require_cmds reflector python curl

echo "=== Optimizing mirrors for installation (Bucharest + nearby) ==="
reflector --country Romania --country Germany --country Netherlands \
  --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# ---------------- Recovery ISO ----------------
if [ "$MODE" = "fresh" ]; then
    echo "=== Downloading Arch ISO into recovery partition ==="
    curl -L "$ARCH_ISO_URL" -o /mnt/recovery/archlinux.iso
else
    echo "=== Reinstall mode: using existing recovery ISO ==="
    if [ ! -f /mnt/recovery/archlinux.iso ]; then
        echo "Warning: recovery ISO not found! You may need to copy it manually."
    else
        echo "Recovery ISO already present: /mnt/recovery/archlinux.iso"
    fi
fi

# ---------------- Desktop Environment ----------------
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

# ---------------- Extra packages ----------------
if [ -f "$EXTRA_PKGS_FILE" ]; then
    EXTRA_PKGS=$(grep -vE "^\s*#|^\s*$" "$EXTRA_PKGS_FILE" | tr '\n' ' ')
else
    echo "Warning: $EXTRA_PKGS_FILE not found. Continuing without extra packages."
    EXTRA_PKGS=""
fi

# ---------------- Base system installation ----------------
echo "Installing base system and packages..."
pacstrap /mnt base base-devel linux linux-firmware sudo vim grub efibootmgr networkmanager git flatpak wget p7zip firefox man-db man-pages bash-completion $DE_PKGS $DM $EXTRA_PKGS

# Generate fstab
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ---------------- Configure system in chroot ----------------
arch-chroot /mnt /bin/bash -e <<'EOF'
set -e

# ---------------- Variables from outer script ----------------
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
HOSTNAME="$HOSTNAME"
LOCALE="$LOCALE"
TIMEZONE="$TIMEZONE"
RECOVERY_PART="$RECOVERY_PART"
ARCH_ISO_URL="$ARCH_ISO_URL"
DM="$DM"

# Hostname and hosts
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		    localhost
127.0.1.1	$HOSTNAME.localdomain $HOSTNAME
HOSTS

# Timezone & locale
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Pacman optimization
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
#grep -q "ILoveCandy" /etc/pacman.conf || echo "ILoveCandy" >> /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Syu --noconfirm

# User setup
echo root:$PASSWORD | chpasswd
echo "Creating user: $USERNAME"
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo $USERNAME:$PASSWORD | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# Enable services
systemctl enable NetworkManager
[[ "$DM" == *gdm* ]] && systemctl enable gdm
[[ "$DM" == *sddm* ]] && systemctl enable sddm
[[ "$DM" == *lightdm* ]] && systemctl enable lightdm
systemctl enable bluetooth.service || true

# GRUB installation
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# ---------------- GRUB dynamic recovery ISO loader ----------------
UUID_RECOVERY=$(blkid -s UUID -o value $RECOVERY_PART)

cat <<'EOF_GRUB' > /boot/grub/custom-recovery.cfg
search --no-floppy --set=recovery_part --fs-uuid UUID_PLACEHOLDER

for iso_file in ($recovery_part)/*.iso; do
    if [ -e $iso_file ]; then
        menuentry "Boot ISO: $(basename $iso_file)" {
            set isofile="$iso_file"
            loopback loop $isofile
            linux (loop)/arch/boot/x86_64/vmlinuz-linux img_dev=/dev/disk/by-uuid/UUID_PLACEHOLDER img_loop=$isofile earlymodules=loop
            initrd (loop)/arch/boot/x86_64/initramfs-linux.img
        }
    fi
done
EOF_GRUB

sed -i "s/UUID_PLACEHOLDER/$UUID_RECOVERY/" /boot/grub/custom-recovery.cfg
echo "source /boot/grub/custom-recovery.cfg" >> /etc/grub.d/40_custom
grub-mkconfig -o /boot/grub/grub.cfg

# ---------------- ISO update script & timer ----------------
cat <<UPDATESCRIPT > /usr/local/bin/update-recovery-iso
#!/bin/bash
set -e
UUID="$UUID_RECOVERY"
MOUNTPOINT="/tmp/recovery-\$UUID"
mkdir -p "\$MOUNTPOINT"
mount UUID="\$UUID" "\$MOUNTPOINT"
echo "Downloading latest Arch ISO..."
curl -L "$ARCH_ISO_URL" -o "\$MOUNTPOINT/archlinux.iso"
umount "\$MOUNTPOINT"
echo "Recovery ISO updated."
UPDATESCRIPT

chmod +x /usr/local/bin/update-recovery-iso

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
