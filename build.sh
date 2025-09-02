#!/bin/bash
#
# Omarchy_ISO.sh - Creates an Arch Linux ISO with offline support for installing Omarchy.
# The live environment boots directly into a 'live' user session running Hyprland.
#

set -e -u -o pipefail

# --- Configuration ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$SCRIPT_DIR" # Assuming project root is the script directory
ISO_BUILD_DIR="$SCRIPT_DIR/omarchy_iso_build"
ISO_OUTPUT_DIR="$SCRIPT_DIR/release"
ISO_LABEL="OMARCHY_$(date +%Y%m)"
ISO_VERSION=$(date +%Y.%m.%d)
LIVE_USER="liveuser"
LIVE_PASS="liveuser" # This password is for the live environment, not for installation

# --- Host specific paths (provided by user) ---
HOST_CONFIG_DIR="/home/mihai/.config"
HOST_OMARCHY_LOCAL_DIR="/home/mihai/.local/share/omarchy"

# --- Helper Functions ---
info() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# --- Pre-flight checks ---
info "Performing pre-flight checks..."
if [[ "$EUID" -ne 0 ]]; then
  error "This script must be run as root."
fi

for cmd in mkarchiso git pacman repo-add; do
  if ! command -v "$cmd" &> /dev/null;
    then
    error "$cmd not found. Please ensure archiso, git, pacman, and pacman-contrib are installed."
  fi
done

# --- Setup build directory ---
info "Setting up build directory at $ISO_BUILD_DIR..."
rm -rf "$ISO_BUILD_DIR"
mkdir -p "$ISO_BUILD_DIR"
cd "$ISO_BUILD_DIR"

# --- Create archiso profile ---
info "Creating archiso profile..."
cp -r /usr/share/archiso/configs/releng/ .
mv releng omarchy_profile
cd omarchy_profile

# --- Customize profiledef.sh ---
info "Customizing profiledef.sh..."
sed -i "s|iso_name=\"archlinux\"|iso_name=\"omarchy\"|" profiledef.sh
sed -i "s|iso_label=\"ARCH_\\[email protected]%%Y%%m)\"|iso_label=\"$ISO_LABEL\"|" profiledef.sh
sed -i "s|iso_version=\"\\[email protected] +%Y.%m.%d)\"|iso_version=\"$ISO_VERSION\"|" profiledef.sh
sed -i "/^install_dir=/a autologin_user=$LIVE_USER" profiledef.sh
sed -i "/^install_dir=/a desktop_user=$LIVE_USER" profiledef.sh

# --- Packages list ---
info "Customizing package list..."
# Copy the combined omarchy.packages from the project root
cp "$PROJECT_DIR/builder/packages/omarchy.packages" packages.x86_64
sort -u packages.x86_64 -o packages.x86_64

# --- Local repo ---
info "Creating local package repository..."
mkdir -p local_repo/x86_64
# Copy pacman cache
if [ -d "/var/cache/pacman/pkg" ]; then
    cp /var/cache/pacman/pkg/*.pkg.tar.zst local_repo/x86_64/ 2>/dev/null || true
fi
# Copy yay cache (if available)
if [ -d "$HOME/.cache/yay" ]; then
    find "$HOME/.cache/yay" -name "*.pkg.tar.zst" -not -name "nvim*.pkg.tar.zst" -exec cp {} local_repo/x86_64/ \; 2>/dev/null || true
fi
repo-add local_repo/x86_64/omarchy_local.db.tar.gz local_repo/x86_64/*.pkg.tar.zst

cat >> pacman.conf <<EOF

[omarchy_local]
SigLevel = Optional TrustAll
Server = file://$(pwd)/local_repo/x86_64
EOF

# --- Customize airootfs ---
info "Customizing airootfs..."
AIROOTFS_HOME="airootfs/home/$LIVE_USER"
mkdir -p "$AIROOTFS_HOME"

# Copy omarchy installer files
# Re-clone omarchy repo to ensure it's fresh
rm -rf "$PROJECT_DIR/omarchy_tmp"
git clone https://github.com/basecamp/omarchy.git "$PROJECT_DIR/omarchy_tmp"
cp -r "$PROJECT_DIR/omarchy_tmp" "$AIROOTFS_HOME/omarchy_installer"

# Remove conflicting .desktop files
rm -f "$AIROOTFS_HOME/omarchy_installer/applications/imv.desktop"
rm -f "$AIROOTFS_HOME/omarchy_installer/applications/mpv.desktop"
rm -f "$AIROOTFS_HOME/omarchy_installer/applications/typora.desktop"

# Copy icon for the installer
mkdir -p "airootfs/usr/share/icons/hicolor/scalable/apps"
cp "$PROJECT_DIR/builder/icons/omarchy-icon.svg" "airootfs/usr/share/icons/hicolor/scalable/apps/omarchy-icon.svg"

# Copy omarchy config files
info "Copying omarchy config files to airootfs..."
OMARCHY_CONFIG_SRC="$AIROOTFS_HOME/omarchy_installer/config"
AIROOTFS_CONFIG="$AIROOTFS_HOME/.config"
mkdir -p "$AIROOTFS_CONFIG"
cp -r "$OMARCHY_CONFIG_SRC/"* "$AIROOTFS_CONFIG/"

# Copy omarchy bin files
info "Copying omarchy bin files to airootfs..."
OMARCHY_BIN_SRC="$AIROOTFS_HOME/omarchy_installer/bin"
AIROOTFS_BIN="airootfs/usr/local/bin"
mkdir -p "$AIROOTFS_BIN"
cp -r "$OMARCHY_BIN_SRC/"* "$AIROOTFS_BIN/"

# Copy omarchy applications
info "Copying omarchy applications to airootfs..."
OMARCHY_APP_SRC="$AIROOTFS_HOME/omarchy_installer/applications"
AIROOTFS_APP="airootfs/usr/share/applications"
mkdir -p "$AIROOTFS_APP"
cp -r "$OMARCHY_APP_SRC/"* "$AIROOTFS_APP/"

# Copy default bashrc from omarchy installer
cp "$AIROOTFS_HOME/omarchy_installer/default/bashrc" "$AIROOTFS_HOME/.bashrc"

# --- customize_airootfs.sh (runs inside the ISO) ---
info "Creating customize_airootfs.sh..."
cp "$PROJECT_DIR/archiso/configs/omarchy_profile/airootfs/root/customize_airootfs.sh" "airootfs/root/customize_airootfs.sh"
chmod +x "airootfs/root/customize_airootfs.sh"

# --- Build ISO ---
info "Building the ISO..."
mkdir -p "work" "out"
mkarchiso -v -w "work" -o "out" .

# --- Finalize ---
info "ISO build complete."
mkdir -p "$ISO_OUTPUT_DIR"
mv out/omarchy-*.iso "$ISO_OUTPUT_DIR/"
info "Omarchy ISO created at $ISO_OUTPUT_DIR/"
cd "$SCRIPT_DIR"
rm -rf "$ISO_BUILD_DIR"
rm -rf "$PROJECT_DIR/omarchy_tmp"
info "Done."