#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
WORK_DIR="$SCRIPT_DIR/work"
OUT_DIR="$SCRIPT_DIR/out"
ISO_LABEL="ARCHHYPR"
ISO_VERSION=$(date +%Y.%m.%d)
ISO_NAME="archlinux-hyprland"

info() { echo -e "\e[32m[INFO]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root."
fi

for cmd in mkarchiso; do
    command -v "$cmd" &>/dev/null || error "$cmd not found. Install archiso."
done

info "Setting up build directory..."
rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"
cp -r /usr/share/archiso/configs/releng/ "$WORK_DIR/releng"
cd "$WORK_DIR/releng"

info "Customizing profiledef.sh..."
sed -i "s|^iso_name=.*|iso_name=\"$ISO_NAME\"|" profiledef.sh
sed -i "s|^iso_label=.*|iso_label=\"$ISO_LABEL\"|" profiledef.sh
sed -i "s|^iso_version=.*|iso_version=\"$ISO_VERSION\"|" profiledef.sh

info "Adding packages..."
cat << 'PKGS' > packages.x86_64
# Base
base
base-devel
linux
linux-firmware
linux-headers
intel-ucode
amd-ucode
syslinux
memtest86+
memtest86+-efi
squashfs-tools
edk2-shell
archiso
mkinitcpio-archiso

# Core
systemd
systemd-sysvcompat
glibc
gcc-libs
gcc
make
pkgconf
coreutils
btrfs-progs
cryptsetup
device-mapper
lvm2
dosfstools
e2fsprogs
parted
gptfdisk
sudo
vim
git
curl
wget
zsh
fish
bash-completion

# Network
networkmanager
iwd
dhcpcd
openresolv
firewalld
openssh

# Audio/Video
pipewire
pipewire-alsa
pipewire-pulse
wireplumber
sof-firmware

# Hyprland & Desktop
hyprland
hypridle
hyprlock
hyprpicker
hyprshot
hyprsunset
hyprutils
hyprlang
hyprgraphics
hyprcursor
xdg-desktop-portal-hyprland
xdg-desktop-portal-gtk

# Terminals
kitty
alacritty

# Apps
nautilus
chromium
fuzzel
waybar
swaybg
wofi
mako
grim
slurp
wl-clipboard
playerctl
brightnessctl
pamixer
bluez
bluez-utils
blueman
polkit
polkit-kde-agent

# Fonts & Icons
noto-fonts
noto-fonts-cjk
noto-fonts-emoji
ttf-jetbrains-mono
ttf-cascadia-code-nerd
adwaita-icon-theme
adwaita-cursors

# Utilities
rsync
reflector
pacman-mirrorlist
archinstall
dbus-broker
fuse3
gvfs
udisks2
libsecret
gnome-keyring
fastfetch
btop
eza
ripgrep
fd
bat
fzf
jq
tree
bc
htop

# Extras
python
python-pip
python-setuptools
nodejs
npm
PKGS

info "Setting up live environment in airootfs..."

# Setup sudo for live user
mkdir -p airootfs/etc/sudoers.d
echo "live ALL=(ALL) NOPASSWD: ALL" > airootfs/etc/sudoers.d/live
chmod 440 airootfs/etc/sudoers.d/live

# Setup live user via sysusers
mkdir -p airootfs/etc/sysusers.d
echo "u live 1000 \"Live User\" /home/live /bin/bash" > airootfs/etc/sysusers.d/live.conf
echo "m live wheel" >> airootfs/etc/sysusers.d/live.conf
echo "m live audio" >> airootfs/etc/sysusers.d/live.conf
echo "m live video" >> airootfs/etc/sysusers.d/live.conf
echo "m live storage" >> airootfs/etc/sysusers.d/live.conf
echo "m live input" >> airootfs/etc/sysusers.d/live.conf

# Setup autologin for live user
mkdir -p airootfs/etc/systemd/system/getty@tty1.service.d
cat << 'AUTOLOGIN' > airootfs/etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin live --noclear %I $TERM
AUTOLOGIN

# Create start-hyprland script
mkdir -p airootfs/usr/local/bin
cat << 'STARTHYPR' > airootfs/usr/local/bin/start-hyprland
#!/bin/bash
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_TYPE=wayland
export GDK_BACKEND=wayland,x11
export QT_QPA_PLATFORM=wayland;xcb
export SDL_VIDEODRIVER=wayland
export _JAVA_AWT_WM_NONREPARENTING=1
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
exec Hyprland
STARTHYPR
chmod +x airootfs/usr/local/bin/start-hyprland

# Create welcome script
cat << 'WELCOME' > airootfs/usr/local/bin/welcome.sh
#!/bin/bash
cat << 'EOF'
===========================================
       Arch Linux Hyprland Live
===========================================

Applications:
- Nautilus (File Manager)
- Fuzzel (App Launcher)
- Chromium (Browser)
- Kitty & Alacritty (Terminals)
- Waybar (Status Bar)

Keybinds:
- Super+Return: Open Terminal
- Super+Q: Close Window
- Super+E: File Manager
- Super+Space: App Launcher
- Super+F: Fullscreen
- Super+Arrow Keys: Move Focus
- Super+Shift+Arrow Keys: Move Window

Install Script:
Run /home/live/Install.sh to install Arch Linux.
chmod +x Install.sh
===========================================
EOF
WELCOME
chmod +x airootfs/usr/local/bin/welcome.sh

# Setup skel
mkdir -p airootfs/etc/skel/.config/hypr
mkdir -p airootfs/etc/skel/.config/waybar
mkdir -p airootfs/etc/skel/.local/share/wallpapers

cat << 'HYPRCONF' > airootfs/etc/skel/.config/hypr/hyprland.conf
$terminal = alacritty
$fileManager = nautilus
$menu = fuzzel

bind = SUPER, RETURN, exec, $terminal
bind = SUPER, Q, killactive,
bind = SUPER, M, exit,
bind = SUPER, E, exec, $fileManager
bind = SUPER, space, exec, $menu
bind = SUPER, F, fullscreen,

bind = SUPER, left, movefocus, l
bind = SUPER, right, movefocus, r
bind = SUPER, down, movefocus, d
bind = SUPER, up, movefocus, u

bind = SUPER SHIFT, left, movewindow, l
bind = SUPER SHIFT, right, movewindow, r
bind = SUPER SHIFT, down, movewindow, d
bind = SUPER SHIFT, up, movewindow, u

bind = SUPER, mouse_down, workspace, e+1
bind = SUPER, mouse_up, workspace, e-1



exec-once = waybar
exec-once = swaybg -i ~/.local/share/wallpapers/default.jpg -m fill
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = systemctl --user import-env WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = welcome.sh
HYPRCONF

cat << 'WAYBAR' > airootfs/etc/skel/.config/waybar/config
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "modules-left": ["hyprland/workspaces", "hyprland/window"],
    "modules-center": ["clock"],
    "modules-right": ["pulseaudio", "network", "battery", "tray"],
    "hyprland/workspaces": {
        "disable-scroll": false
    },
    "clock": {
        "format": "{:%Y-%m-%d %H:%M}",
        "tooltip-format": "<big>{:%Y %B}</big><br><i>{: %H:%M}</i>"
    },
    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon} {capacity}%",
        "format-icons": ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    },
    "network": {
        "format-wifi": "󰤨 {signalStrength}%",
        "format-ethernet": "󰈀",
        "tooltip-format": "{ifname} via {gwaddr}"
    },
    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "󰝟",
        "format-icons": {"default": ["󰕿", "󰖀", "󰕾"]},
        "on-click": "pavucontrol"
    },
    "tray": {
        "icon-size": 16,
        "spacing": 10
    }
}
WAYBAR

# Setup shell profiles
cat << 'PROFILE' > airootfs/etc/skel/.profile
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_TYPE=wayland
export GDK_BACKEND=wayland,x11
export QT_QPA_PLATFORM=wayland;xcb
export SDL_VIDEODRIVER=wayland
export _JAVA_AWT_WM_NONREPARENTING=1
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec start-hyprland
fi
PROFILE

cp airootfs/etc/skel/.profile airootfs/etc/skel/.bash_profile

# Enable services via symlinks
mkdir -p airootfs/etc/systemd/system/multi-user.target.wants
mkdir -p airootfs/etc/systemd/system/bluetooth.target.wants
for svc in NetworkManager bluetooth; do
    ln -sf /usr/lib/systemd/system/$svc.service airootfs/etc/systemd/system/multi-user.target.wants/$svc.service
done

# Setup tmpfiles.d to initialize live home with correct permissions
mkdir -p airootfs/etc/tmpfiles.d
cat << 'TMPFILES' > airootfs/etc/tmpfiles.d/live-home.conf
# Copy skel to live home if empty and set ownership
C /home/live - - - - /etc/skel
z /home/live 0755 live live - -
Z /home/live - live live - -
TMPFILES

info "Copying Install.sh to /etc/skel..."
mkdir -p airootfs/etc/skel
cp "$PROJECT_DIR/Install.sh" airootfs/etc/skel/Install.sh
chmod +x airootfs/etc/skel/Install.sh

# Set permissions in profiledef.sh
sed -i '/file_permissions=(/a \  ["/usr/local/bin/start-hyprland"]="0:0:755"\n  ["/usr/local/bin/welcome.sh"]="0:0:755"' profiledef.sh

info "Building ISO (this may take a while)..."
mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" .

info "ISO build complete!"
ls -lh "$OUT_DIR/$ISO_NAME-"*.iso
