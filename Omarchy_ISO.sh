#!/bin/bash
#
# Omarchy_ISO.sh - Creates an Arch Linux ISO with offline support for installing Omarchy.
# The live environment runs the Omarchy Desktop Environment.
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
info() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
    exit 1
}

# --- Pre-flight checks ---
info "Performing pre-flight checks..."
if [[ "$EUID" -ne 0 ]]; then
  error "This script must be run as root."
fi

for cmd in mkarchiso git pacman repo-add yay; do
  if ! command -v "$cmd" &> /dev/null; then
    error "$cmd not found. If it is installed, it might not be in the root user's PATH. You can try running this script with 'sudo -E ./Omarchy_ISO.sh'"
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


# --- Customize packages list ---
info "Customizing package list..."
OMARCHY_PACKAGES=(
    "1password-beta" "1password-cli" "alacritty" "avahi" "bash-completion" "bat" "blueberry" "brightnessctl" "btop" "cargo" "clang" "cups" "cups-browsed" "cups-filters" "cups-pdf" "docker" "docker-buildx" "docker-compose" "dust" "evince" "eza" "fastfetch" "fcitx5" "fcitx5-gtk" "fcitx5-qt" "fd" "ffmpegthumbnailer" "fzf" "gcc14" "github-cli" "gnome-calculator" "gnome-keyring" "gnome-themes-extra" "gum" "gvfs-mtp" "hypridle" "hyprland" "hyprland-qtutils" "hyprlock" "hyprpicker" "hyprshot" "hyprsunset" "imagemagick" "impala" "imv" "inetutils" "jq" "kdenlive" "kvantum-qt5" "lazydocker" "lazygit" "less" "libqalculate" "libreoffice" "llvm" "localsend" "luarocks" "mako" "man" "mariadb-libs" "mise" "mpv" "nautilus" "noto-fonts" "noto-fonts-cjk" "noto-fonts-emoji" "noto-fonts-extra" "nss-mdns" "nvim" "obs-studio" "obsidian" "omarchy-chromium" "pamixer" "pinta" "playerctl" "plocate" "plymouth" "polkit-gnome" "postgresql-libs" "power-profiles-daemon" "python-gobject" "python-poetry-core" "python-terminaltexteffects" "ripgrep" "satty" "signal-desktop" "slurp" "spotify" "starship" "sushi" "swaybg" "swayosd" "system-config-printer" "tldr" "tree-sitter-cli" "ttf-cascadia-mono-nerd" "ttf-ia-writer" "ttf-jetbrains-mono" "typora" "tzupdate" "ufw" "ufw-docker" "unzip" "uwsm" "walker-bin" "waybar" "wf-recorder" "whois" "wiremix" "wireplumber" "wl-clip-persist" "wl-clipboard" "wl-screenrec" "woff2-font-awesome" "xdg-desktop-portal-gtk" "xdg-desktop-portal-hyprland" "xmlstarlet" "xournalpp" "yaru-icon-theme" "yay" "zoxide" "archinstall" "git"
)
for pkg in "${OMARCHY_PACKAGES[@]}"; do
    echo "$pkg" >> packages.x86_64
done
sort -u packages.x86_64 -o packages.x86_64

# --- Create local repository for offline install ---
info "Creating local package repository from system cache..."
mkdir -p local_repo/x86_64

info "Copying all packages from pacman cache..."
cp /var/cache/pacman/pkg/*.pkg.tar.zst local_repo/x86_64/

info "Copying all packages from yay cache..."
if [ -n "${SUDO_USER-}" ]; then
    SUDO_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    YAY_CACHE_DIR="$SUDO_USER_HOME/.cache/yay"
    if [ -d "$YAY_CACHE_DIR" ]; then
        find "$YAY_CACHE_DIR" -name "*.pkg.tar.zst" -exec cp {} local_repo/x86_64/ \;
    fi
fi

info "Creating local repository database..."
repo-add local_repo/x86_64/omarchy_local.db.tar.gz local_repo/x86_64/*.pkg.tar.zst

cat >> pacman.conf <<EOF

[omarchy_local]
SigLevel = Optional TrustAll
Server = file://$(pwd)/local_repo/x86_64
EOF

# --- Customize airootfs for live DE and offline installer ---
info "Customizing airootfs..."
mkdir -p airootfs/etc/pacman.d/omarchy_local_repo
cp -r local_repo/x86_64/* airootfs/etc/pacman.d/omarchy_local_repo/

mkdir -p airootfs/root/installer
cp -r "$PROJECT_DIR/omarchy-2.0.5" airootfs/root/installer/omarchy
cp -r "$PROJECT_DIR/iso_root" airootfs/root/installer/iso_root

sed -i '/"custom_repositories": \[]/c\"custom_repositories": [ { "url": "file:///etc/pacman.d/omarchy_local_repo", "name": "omarchy_local" } ],' airootfs/root/installer/iso_root/configurator

sed -i '/chroot_bash -lc "curl/d' airootfs/root/installer/iso_root/.automated_script.sh
cat <<'EOF' >> airootfs/root/installer/iso_root/.automated_script.sh
  OMARCHY_USER="$(jq -r '.users[0].username' user_credentials.json)"
  mkdir -p "/mnt/home/$OMARCHY_USER/.local/share"
  cp -r /root/installer/omarchy "/mnt/home/$OMARCHY_USER/.local/share/"
  chroot_bash -lc "bash ~/.local/share/omarchy/install.sh"
EOF

cat <<'EOF' > airootfs/root/customize_airootfs.sh
#!/bin/bash
set -e

# Fix pacman.conf for the live environment
sed -i 's|Server = file://.*|Server = file:///etc/pacman.d/omarchy_local_repo|' /etc/pacman.conf

# Debug: List contents of /root
echo "--- Listing contents of /root ---"
ls -la /root
echo "---------------------------------"

# Setup Omarchy configs for root user (live user)
mkdir -p /root/.local/share
cp -r /root/installer/omarchy /root/.local/share/
mkdir -p /root/.config
cp -R /root/.local/share/omarchy/config/* /root/.config/

# Copy user's config files
if [ -n "${SUDO_USER-}" ]; then
    SUDO_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    CONFIG_DIRS=(
        "alacritty" "btop" "chromium" "dconf" "fastfetch" "fontconfig" "hypr"
        "lazygit" "nautilus" "omarchy" "pulse" "swayosd" "systemd" "uwsm"
        "walker" "waybar" "xournalpp"
    )
    for dir in "${CONFIG_DIRS[@]}"; do
        if [ -d "$SUDO_USER_HOME/.config/$dir" ]; then
            cp -r "$SUDO_USER_HOME/.config/$dir" "/root/.config/"
        fi
    done
fi

cp /root/.local/share/omarchy/default/bashrc /root/.bashrc


# Autostart Hyprland on tty1
echo 'if [ -z "$DISPLAY" ] && [ \"$(tty)\" = \"/dev/tty1\" ]; then exec Hyprland; fi' >> /root/.bash_profile

# Create a desktop shortcut for the installer
mkdir -p /root/Desktop
cat <<DESKTOP > /root/Desktop/Install_Omarchy.desktop
[Desktop Entry]
Name=Install Omarchy
Comment=Install Omarchy to your hard drive
Exec=alacritty -e /root/installer/iso_root/.automated_script.sh
Icon=system-installer
Terminal=false
Type=Application
Categories=System;
DESKTOP
chmod +x /root/Desktop/Install_Omarchy.desktop

# Set permissions
chown -R root:root /root
EOF

chmod +x airootfs/root/customize_airootfs.sh



# --- Build the ISO ---
info "Building the ISO... (this may take a while)"
# Create work and out directories for mkarchiso
mkdir -p "$ISO_BUILD_DIR/work" "$ISO_BUILD_DIR/out"
# Call mkarchiso directly
mkarchiso -v -w "$ISO_BUILD_DIR/work" -o "$ISO_BUILD_DIR/out" .

# --- Finalize ---
info "ISO build complete."
mv out/omarchy-*.iso "$ISO_OUTPUT_DIR/"
info "Omarchy ISO created at $ISO_OUTPUT_DIR/omarchy-....iso"
cd "$SCRIPT_DIR"
rm -rf "$ISO_BUILD_DIR"

info "Done."
Done."
