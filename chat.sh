#!/bin/bash
#
# Omarchy_ISO.sh - Creates an Arch Linux ISO with offline support for installing Omarchy.
# The live environment boots directly into a 'live' user session running Hyprland.
#

set -e -u -o pipefail

# --- Configuration ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$SCRIPT_DIR/Project"
ISO_BUILD_DIR="$SCRIPT_DIR/omarchy_iso_build"
ISO_OUTPUT_DIR="$SCRIPT_DIR"
ISO_LABEL="OMARCHY_$(date +%Y%m)"
ISO_VERSION=$(date +%Y.%m.%d)
LIVE_USER="live"
LIVE_PASS="live"

# --- Helper Functions ---
info() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# --- Pre-flight checks ---
info "Performing pre-flight checks..."
if [[ "$EUID" -ne 0 ]]; then
  error "This script must be run as root."
fi

for cmd in mkarchiso git pacman repo-add yay; do
  if ! command -v "$cmd" &> /dev/null; then
    error "$cmd not found. Please ensure archiso, git, pacman, and pacman-contrib are installed."
  fi
done

if [ ! -d "$PROJECT_DIR/omarchy-2.0.5" ] || [ ! -d "$PROJECT_DIR/iso_root" ]; then
    error "Project directories 'omarchy-2.0.5' or 'iso_root' not found in $PROJECT_DIR"
fi

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
OMARCHY_PACKAGES=( "rsync" "1password-beta" "1password-cli" "alacritty" "avahi" "bash-completion" "bat" "blueberry" "brightnessctl" "btop" "cargo" "clang" "cups" "cups-browsed" "cups-filters" "cups-pdf" "docker" "docker-buildx" "docker-compose" "dust" "evince" "eza" "fastfetch" "fcitx5" "fcitx5-gtk" "fcitx5-qt" "fd" "ffmpegthumbnailer" "fzf" "gcc14" "github-cli" "gnome-calculator" "gnome-keyring" "gnome-themes-extra" "gum" "gvfs-mtp" "hypridle" "hyprland" "hyprland-qtutils" "hyprlock" "hyprpicker" "hyprshot" "hyprsunset" "imagemagick" "impala" "imv" "inetutils" "jq" "kdenlive" "kvantum-qt5" "lazydocker" "lazygit" "less" "libqalculate" "libreoffice" "llvm" "localsend" "luarocks" "mako" "man" "mariadb-libs" "mise" "mpv" "nautilus" "noto-fonts" "noto-fonts-cjk" "noto-fonts-emoji" "noto-fonts-extra" "nss-mdns" "nvim" "obs-studio" "obsidian" "omarchy-chromium" "pamixer" "pinta" "playerctl" "plocate" "plymouth" "polkit-gnome" "postgresql-libs" "power-profiles-daemon" "python-gobject" "python-poetry-core" "python-terminaltexteffects" "ripgrep" "satty" "signal-desktop" "slurp" "spotify" "starship" "sushi" "swaybg" "swayosd" "system-config-printer" "tldr" "tree-sitter-cli" "ttf-cascadia-mono-nerd" "ttf-ia-writer" "ttf-jetbrains-mono" "typora" "tzupdate" "ufw" "ufw-docker" "unzip" "uwsm" "walker-bin" "walker" "waybar" "wf-recorder" "whois" "wiremix" "wireplumber" "wl-clip-persist" "wl-clipboard" "wl-screenrec" "woff2-font-awesome" "xdg-desktop-portal-gtk" "xdg-desktop-portal-hyprland" "xmlstarlet" "xournalpp" "yaru-icon-theme" "yay" "zoxide" "archinstall" "git" )

for pkg in "${OMARCHY_PACKAGES[@]}"; do
    echo "$pkg" >> packages.x86_64
done
sort -u packages.x86_64 -o packages.x86_64

# --- Local repo ---
info "Creating local package repository..."
mkdir -p local_repo/x86_64
cp /var/cache/pacman/pkg/*.pkg.tar.zst local_repo/x86_64/
if [ -n "${SUDO_USER-}" ]; then
    SUDO_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    YAY_CACHE_DIR="$SUDO_USER_HOME/.cache/yay"
    if [ -d "$YAY_CACHE_DIR" ]; then
        find "$YAY_CACHE_DIR" -name "*.pkg.tar.zst" -exec cp {} local_repo/x86_64/ \;
    fi
fi
repo-add local_repo/x86_64/omarchy_local.db.tar.gz local_repo/x86_64/*.pkg.tar.zst

cat >> pacman.conf <<EOF

[omarchy_local]
SigLevel = Optional TrustAll
Server = file://$(pwd)/local_repo/x86_64
EOF

# --- Customize airootfs ---
info "Customizing airootfs..."
AIROOTFS_HOME="/home/$LIVE_USER"
mkdir -p "airootfs/etc/pacman.d/omarchy_local_repo"
cp -r local_repo/x86_64/* "airootfs/etc/pacman.d/omarchy_local_repo/"

# Copy installer files
mkdir -p "airootfs/$AIROOTFS_HOME/installer"
cp -r "$PROJECT_DIR/omarchy-2.0.5" "airootfs/$AIROOTFS_HOME/installer/omarchy"
cp -r "$PROJECT_DIR/iso_root" "airootfs/$AIROOTFS_HOME/installer/iso_root"
chmod +x "airootfs/$AIROOTFS_HOME/installer/iso_root/.automated_script.sh"
chmod +x "airootfs/$AIROOTFS_HOME/installer/iso_root/configurator"

# Copy icon for the installer
mkdir -p "airootfs/usr/share/icons/hicolor/scalable/apps"
cp "/home/mihai/icon.svg" "airootfs/usr/share/icons/hicolor/scalable/apps/omarchy-installer.svg"

# --- Copy .config from host ---
HOST_CONFIG="/home/mihai/.config"
AIROOTFS_CONFIG="airootfs/$AIROOTFS_HOME/.config"
info "Copying .config from host to ISO build..."
# Create the target directory
mkdir -p "$AIROOTFS_CONFIG"
# Use rsync to copy files, excluding problematic directories.
rsync -aL --exclude 'google-chrome' --exclude 'gnome-boxes' --exclude 'qBittorrent' "$HOST_CONFIG/" "$AIROOTFS_CONFIG/"


# --- Copy .local/share/omarchy ---
HOST_OMARCHY="/home/mihai/.local/share/omarchy"
AIROOTFS_LOCAL="airootfs/$AIROOTFS_HOME/.local/share"
mkdir -p "$AIROOTFS_LOCAL"
if [ -d "$HOST_OMARCHY" ]; then
    cp -rL "$HOST_OMARCHY" "$AIROOTFS_LOCAL/"
else
    echo "[WARNING] Host omarchy folder not found at $HOST_OMARCHY"
fi

# Copy default bashrc
cp "$AIROOTFS_LOCAL/omarchy/default/bashrc" "airootfs/$AIROOTFS_HOME/.bashrc"

# --- Hyprland autostart for live user ---
cat <<'EOF' > "airootfs/$AIROOTFS_HOME/.bash_profile"
# Autostart Hyprland on TTY1
if [ -z "$DISPLAY" ] && [ "$(fgconsole)" -eq 1 ]; then
  exec Hyprland
fi
EOF

# --- customize_airootfs.sh (runs inside the ISO) ---
cat <<EOF > airootfs/root/customize_airootfs.sh
#!/bin/bash
set -e

# Create live user
useradd -m -s /bin/bash $LIVE_USER
echo "$LIVE_USER:$LIVE_PASS" | chpasswd
# Add user to wheel group for sudo and other necessary groups
groupadd -r autologin
usermod -aG wheel,video,audio,storage,power,autologin $LIVE_USER
# Grant passwordless sudo
echo "$LIVE_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/liveuser

# Enable autologin for tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOT > /etc/systemd/system/getty@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $LIVE_USER --noclear %I \$TERM
EOT

# Fix pacman for live environment
sed -i 's|Server = file://.*|Server = file:///etc/pacman.d/omarchy_local_repo|' /etc/pacman.conf

# --- Application menu shortcut for the live user ---
APP_DIR="/home/$LIVE_USER/.local/share/applications"
mkdir -p "\$APP_DIR"

cat <<DESKTOP > "\$APP_DIR/Install_Omarchy.desktop"
[Desktop Entry]
Name=Install Omarchy
Comment=Install Omarchy to your hard drive
Exec=sudo alacritty -e /home/$LIVE_USER/installer/iso_root/.automated_script.sh
Icon=omarchy-installer
Terminal=false
Type=Application
Categories=System;
DESKTOP

# Set ownership for the new live user's home directory
chown -R $LIVE_USER:$LIVE_USER /home/$LIVE_USER
chmod 755 /home/$LIVE_USER
chmod +x "\$APP_DIR/Install_Omarchy.desktop"
EOF

chmod +x airootfs/root/customize_airootfs.sh

# --- Build ISO ---
info "Building the ISO..."
mkdir -p "$ISO_BUILD_DIR/work" "$ISO_BUILD_DIR/out"
mkarchiso -v -w "$ISO_BUILD_DIR/work" -o "$ISO_BUILD_DIR/out" .

# --- Finalize ---
info "ISO build complete."
mv out/omarchy-*.iso "$ISO_OUTPUT_DIR/"
info "Omarchy ISO created at $ISO_OUTPUT_DIR/"
cd "$SCRIPT_DIR"
rm -rf "$ISO_BUILD_DIR"
info "Done."

