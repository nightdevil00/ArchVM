#!/bin/bash
#
# Omarchy_ISO.sh - Creates an Arch Linux ISO with offline support for installing Omarchy.
# The live environment boots directly into Hyprland.
#

set -e -u -o pipefail

# --- Configuration ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$SCRIPT_DIR/Project"
ISO_BUILD_DIR="$SCRIPT_DIR/omarchy_iso_build"
ISO_OUTPUT_DIR="$SCRIPT_DIR"
ISO_LABEL="OMARCHY_$(date +%Y%m)"
ISO_VERSION=$(date +%Y.%m.%d)

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
    error "$cmd not found. Run with 'sudo -E ./Omarchy_ISO.sh'"
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
sed -i "s|iso_label=\"ARCH_\$(date +%Y%m)\"|iso_label=\"$ISO_LABEL\"|" profiledef.sh
sed -i "s|iso_version=\"\$(date +%Y.%m.%d)\"|iso_version=\"$ISO_VERSION\"|" profiledef.sh
sed -i "/^install_dir=/a autologin_user=root" profiledef.sh
sed -i "/^install_dir=/a desktop_user=root" profiledef.sh

# --- Packages list ---
info "Customizing package list..."

OMARCHY_PACKAGES=( "1password-beta" "1password-cli" "alacritty" "avahi" "bash-completion" "bat" "blueberry" "brightnessctl" "btop" "cargo" "clang" "cups" "cups-browsed" "cups-filters" "cups-pdf" "docker" "docker-buildx" "docker-compose" "dust" "evince" "eza" "fastfetch" "fcitx5" "fcitx5-gtk" "fcitx5-qt" "fd" "ffmpegthumbnailer" "fzf" "gcc14" "github-cli" "gnome-calculator" "gnome-keyring" "gnome-themes-extra" "gum" "gvfs-mtp" "hypridle" "hyprland" "hyprland-qtutils" "hyprlock" "hyprpicker" "hyprshot" "hyprsunset" "imagemagick" "impala" "imv" "inetutils" "jq" "kdenlive" "kvantum-qt5" "lazydocker" "lazygit" "less" "libqalculate" "libreoffice" "llvm" "localsend" "luarocks" "mako" "man" "mariadb-libs" "mise" "mpv" "nautilus" "noto-fonts" "noto-fonts-cjk" "noto-fonts-emoji" "noto-fonts-extra" "nss-mdns" "nvim" "obs-studio" "obsidian" "omarchy-chromium" "pamixer" "pinta" "playerctl" "plocate" "plymouth" "polkit-gnome" "postgresql-libs" "power-profiles-daemon" "python-gobject" "python-poetry-core" "python-terminaltexteffects" "ripgrep" "satty" "signal-desktop" "slurp" "spotify" "starship" "sushi" "swaybg" "swayosd" "system-config-printer" "tldr" "tree-sitter-cli" "ttf-cascadia-mono-nerd" "ttf-ia-writer" "ttf-jetbrains-mono" "typora" "tzupdate" "ufw" "ufw-docker" "unzip" "uwsm" "walker-bin" "waybar" "wf-recorder" "whois" "wiremix" "wireplumber" "wl-clip-persist" "wl-clipboard" "wl-screenrec" "woff2-font-awesome" "xdg-desktop-portal-gtk" "xdg-desktop-portal-hyprland" "xmlstarlet" "xournalpp" "yaru-icon-theme" "yay" "zoxide" "archinstall" "git" )

for pkg in "${OMARCHY_PACKAGES[@]}"; do
    echo "$pkg" >> packages.x86_64
done
sort -u packages.x86_64 -o packages.x86_64

# --- Create local repository for offline install ---
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
mkdir -p airootfs/etc/pacman.d/omarchy_local_repo
cp -r local_repo/x86_64/* airootfs/etc/pacman.d/omarchy_local_repo/

# Copy Omarchy installer files
mkdir -p airootfs/root/installer
cp -r "$PROJECT_DIR/omarchy-2.0.5" airootfs/root/installer/omarchy
cp -r "$PROJECT_DIR/iso_root" airootfs/root/installer/iso_root

# --- Copy .config from host into airootfs ---
HOST_CONFIG="/home/mihai/.config"
AIROOTFS_CONFIG="$ISO_BUILD_DIR/omarchy_profile/airootfs/root/.config"
mkdir -p "$AIROOTFS_CONFIG"

info "Copying .config from host to ISO build root..."
for dir in "$HOST_CONFIG"/*; do
    base=$(basename "$dir")
    if [ "$base" != "google-chrome" ]; then
        cp -rL "$dir" "$AIROOTFS_CONFIG/"
    fi
done

# Remove gnome-boxes if it exists
rm -rf "$AIROOTFS_CONFIG/gnome-boxes"
rm -rf "$AIROOTFS_CONFIG/qBittorrent"

# --- Copy .local/share/omarchy from host ---
HOST_OMARCHY="/home/mihai/.local/share/omarchy"
AIROOTFS_LOCAL="$ISO_BUILD_DIR/omarchy_profile/airootfs/root/.local/share"
mkdir -p "$AIROOTFS_LOCAL"

if [ -d "$HOST_OMARCHY" ]; then
    cp -rL "$HOST_OMARCHY" "$AIROOTFS_LOCAL/"
else
    echo "[WARNING] Host omarchy folder not found at $HOST_OMARCHY"
fi

# Copy default bashrc
cp "$AIROOTFS_LOCAL/omarchy/default/bashrc" "$ISO_BUILD_DIR/omarchy_profile/airootfs/root/.bashrc"

# --- customize_airootfs.sh ---
cat <<'EOF' > airootfs/root/customize_airootfs.sh
#!/bin/bash
set -e

# Fix pacman for live environment
sed -i 's|Server = file://.*|Server = file:///etc/pacman.d/omarchy_local_repo|' /etc/pacman.conf

# --- Application menu shortcut for installer ---
APP_DIR="/root/.local/share/applications"
mkdir -p "$APP_DIR"

# --- Copy custom icon into ISO root ---
ICON_SRC="/home/mihai/icon.svg"
ICON_DST="/root/.local/share/icons/icon.svg"
mkdir -p "$(dirname "$ICON_DST")"
cp "$ICON_SRC" "$ICON_DST"

# --- Application menu shortcut for installer ---
APP_DIR="/root/.local/share/applications"
mkdir -p "$APP_DIR"

cat <<DESKTOP > "$APP_DIR/Install_Omarchy.desktop"
[Desktop Entry]
Name=Install Omarchy
Comment=Install Omarchy to your hard drive
Exec=alacritty -e /root/installer/iso_root/.automated_script.sh
Icon=$ICON_DST
Terminal=false
Type=Application
Categories=System;
DESKTOP

chmod +x "$APP_DIR/Install_Omarchy.desktop"



# --- Create seamless auto-login service ---
cat <<'SERVICE_EOF' > /etc/systemd/system/seamless-login.service
[Unit]
Description=Seamless Auto-Login
Conflicts=getty@tty1.service
After=systemd-user-sessions.service getty@tty1.service
PartOf=graphical.target

[Service]
Type=simple
ExecStart=/usr/local/bin/seamless-login uwsm start -- hyprland.desktop
Restart=always
RestartSec=2
User=root
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal+console
PAMName=login

[Install]
WantedBy=graphical.target
SERVICE_EOF

# Enable seamless login
systemctl enable seamless-login.service

# Disable any DMs to avoid conflicts
#systemctl disable lightdm.service sddm.service gdm.service || true

# Permissions
chown -R root:root /root
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

