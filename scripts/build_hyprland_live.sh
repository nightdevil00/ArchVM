#!/bin/bash

set -e

# --- Configuration ---
ISO_NAME="archlinux-hyprland"
ISO_PUBLISHER="Your Name"
ISO_APPLICATION_ID="Arch Linux Hyprland"
ISO_VERSION=$(date +%Y.%m.%d)
WORK_DIR="work"
OUT_DIR="out"
LIVE_DIR="live"

# --- Check for root privileges ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# --- Install dependencies ---
pacman -Syu --noconfirm archiso

# --- Create working directory ---
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cp -r /usr/share/archiso/configs/releng/ "$WORK_DIR"

# --- Add packages to the ISO ---
cat << EOF >> "$WORK_DIR/releng/packages.x86_64"
# Hyprland
hyprland
xdg-desktop-portal-hyprland
# Terminal
kitty
alacritty
# File Manager
thunar
nautilus
# App Launcher
wofi
# Status Bar
waybar
# Display Manager
sddm
# Network
networkmanager
# Bluetooth
bluez
bluez-utils
# NVIDIA
nvidia
nvidia-utils
# Other
base
base-devel
linux
linux-firmware
vim
git
sudo
polkit-kde-agent
gedit
nano
EOF

# --- Configure live user ---
mkdir -p "$WORK_DIR/releng/airootfs/etc/sudoers.d"
echo "live ALL=(ALL) NOPASSWD: ALL" > "$WORK_DIR/releng/airootfs/etc/sudoers.d/live"


# --- Copy configuration files ---
mkdir -p "$WORK_DIR/releng/airootfs/home/live"
shopt -s dotglob  # Enable globbing for dotfiles
cp -r "$LIVE_DIR"/* "$WORK_DIR/releng/airootfs/home/live/"
shopt -u dotglob  # Disable it after

mkdir -p "$WORK_DIR/releng/airootfs/etc"
cp -r airootfs/etc/* "$WORK_DIR/releng/airootfs/etc/"

# --- Enable services ---
mkdir -p "$WORK_DIR/releng/airootfs/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/sddm.service "$WORK_DIR/releng/airootfs/etc/systemd/system/multi-user.target.wants/sddm.service"
ln -sf /usr/lib/systemd/system/NetworkManager.service "$WORK_DIR/releng/airootfs/etc/systemd/system/multi-user.target.wants/NetworkManager.service"

# --- Configure SDDM ---
mkdir -p "$WORK_DIR/releng/airootfs/etc/sddm.conf.d"
cat << EOF > "$WORK_DIR/releng/airootfs/etc/sddm.conf.d/20-user.conf"
[Users]
HideUsers=
RememberLastUser=true
EOF

# --- Create live user ---
mkdir -p "$WORK_DIR/releng/airootfs/root"
cat << EOF > "$WORK_DIR/releng/airootfs/root/customize_airootfs.sh"
#!/bin/bash
set -e
useradd -m -G wheel -s /bin/bash live
echo "live:live" | chpasswd
EOF
chmod +x "$WORK_DIR/releng/airootfs/root/customize_airootfs.sh"

# --- Build the ISO ---
mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$WORK_DIR/releng"

echo "--- ISO build complete ---"
echo "ISO available at: $OUT_DIR/$ISO_NAME-$ISO_VERSION-x86_64.iso"
