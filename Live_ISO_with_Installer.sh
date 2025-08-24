#!/bin/bash
set -e

# Install archiso if missing 
if ! command -v mkarchiso &> /dev/null; then
    echo "Installing archiso..."
    sudo pacman -S --needed --noconfirm archiso
fi

# Prepare build folder 
mkdir -p ~/gnome-archiso
cd ~/gnome-archiso

# Copy releng profile as base
cp -r /usr/share/archiso/configs/releng/* ./

# Add packages
cat >> packages.x86_64 <<'EOF'
# --- GNOME Desktop ---
xorg
mesa
gnome
gdm
gnome-tweaks
gnome-shell-extensions
gnome-terminal

# --- Drivers ---
nvidia
nvidia-utils
linux-headers
bluez
bluez-utils

# --- Networking ---
networkmanager
network-manager-applet
inetutils
iproute2
iputils
dhclient

# --- Tools ---
nano
sudo
vim
git
base-devel
wget
vlc
gparted
spotify-launcher
firefox
EOF

# Customize live environment 
mkdir -p airootfs/root
cat > airootfs/root/customize_airootfs.sh <<'EOF'
#!/bin/bash
# Enable necessary services
systemctl enable gdm
systemctl enable NetworkManager
systemctl enable bluetooth

# Create user arch with password 'arch' and add to wheel
useradd -m -G wheel arch
echo "arch:arch" | chpasswd

# Passwordless sudo for wheel (optional, remove if you want sudo to ask password)
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Copy GNOME dconf defaults into arch's home so they apply in live session
if [ -f /etc/skel/.config/dconf/user ]; then
    mkdir -p /home/arch/.config/dconf
    cp /etc/skel/.config/dconf/user /home/arch/.config/dconf/user
    chown -R arch:arch /home/arch/.config
fi

# yay and Google Chrome will need to be installed manually after boot
echo "To install yay and Google Chrome, after boot run:"
echo "  git clone https://aur.archlinux.org/yay-bin.git"
echo "  cd yay-bin"
echo "  makepkg -si"
echo "  yay -S google-chrome"
EOF
chmod +x airootfs/root/customize_airootfs.sh

# Enable autologin for GNOME in live session
mkdir -p airootfs/etc/gdm
cat > airootfs/etc/gdm/custom.conf <<'EOF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=arch
EOF

# Add polkit GNOME authentication agent autostart
mkdir -p airootfs/etc/xdg/autostart
cat > airootfs/etc/xdg/autostart/polkit-gnome-authentication-agent.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Polkit Authentication Agent
Exec=/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

# GNOME default settings + extensions
mkdir -p airootfs/etc/skel/.config/dconf
mkdir -p gnome-dconf
cat > gnome-dconf/settings.ini <<'EOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/custom-wallpaper.jpg'
picture-uri-dark='file:///usr/share/backgrounds/custom-wallpaper.jpg'

[org/gnome/shell]
enabled-extensions=['dash-to-dock@micxgx.gmail.com', 'arcmenu@arcmenu.com']

[org/gnome/shell/extensions/dash-to-dock]
dock-position='BOTTOM'
dash-max-icon-size=48
show-trash=false
show-mounts=false
intellihide=true

[org/gnome/shell/extensions/arcmenu]
position-in-panel='right'
EOF

# Download wallpaper (adjust path if needed)
mkdir -p airootfs/usr/share/backgrounds
cp /home/mihai/Pictures/ColorWall/Wallpapers/12-Dark.jpg airootfs/usr/share/backgrounds/custom-wallpaper.jpg

# Compile dconf database
dconf compile airootfs/etc/skel/.config/dconf/user gnome-dconf

# Add custom Arch install script from GitHub
mkdir -p airootfs/root
curl -L https://raw.githubusercontent.com/nightdevil00/ArchVM/main/Install_Arch.sh -o airootfs/root/Install_Arch.sh
chmod +x airootfs/root/Install_Arch.sh

# Create desktop + applications launcher for Install Arch
mkdir -p airootfs/home/arch/Desktop
cat > airootfs/home/arch/Desktop/Install\ Arch.desktop <<'EOF'
[Desktop Entry]
Name=Install Arch
Comment=Run the Arch Linux Installer Script
Exec=gnome-terminal -- bash -c "/root/Install_Arch.sh; exec bash"
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;Utility;
EOF

# Copy launcher into GNOME Applications menu
mkdir -p airootfs/usr/share/applications
cp "airootfs/home/arch/Desktop/Install Arch.desktop" airootfs/usr/share/applications/Install\ Arch.desktop

# Make both executable
chmod +x "airootfs/home/arch/Desktop/Install Arch.desktop"
chmod +x "airootfs/usr/share/applications/Install Arch.desktop"

# Ensure Desktop file is owned by live user (arch, UID 1000)
chown -R 1000:1000 airootfs/home/arch/Desktop

# Custom profiledef.sh for ISO metadata
cat > profiledef.sh <<'EOF'
#!/usr/bin/env bash
iso_name="archlinux-gnome-custom"
iso_label="ARCH_GNOME_CUSTOM"
iso_publisher="Custom Arch Linux <https://archlinux.org>"
iso_application="Custom Arch Linux Live GNOME with Installer Script"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux.mbr' 'bios.syslinux.eltorito' 'uefi-x64.systemd-boot.esp' 'uefi-x64.systemd-boot.eltorito')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/root/customize_airootfs.sh"]="0:0:755"
  ["/root/Install_Arch.sh"]="0:0:755"
)
EOF

echo "✅ gnome-archiso folder ready at ~/gnome-archiso with GNOME, NVIDIA, yay, Chrome instructions, wallpaper, and installer script"
echo "Build your ISO with:"
echo "  cd ~/gnome-archiso"
echo "  mkarchiso -v ."
