#!/usr/bin/env bash
# ==============================================================================
# Custom Arch ISO Builder
# Hyprland + Niri, SDDM, NVIDIA support, pre-configured live environment
# ==============================================================================

set -euo pipefail

# Colors
C_BLUE="\e[34m"
C_GREEN="\e[32m"
C_RED="\e[31m"
C_YELLOW="\e[33m"
C_RESET="\e[0m"

info() { echo -e "${C_BLUE}[INFO]${C_RESET} $1"; }
success() { echo -e "${C_GREEN}[SUCCESS]${C_RESET} $1"; }
error() { echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2; }
warn() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $1"; }

# Check root
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root"
  exit 1
fi

WORK_DIR="$(pwd)/archiso-work"
PROFILE_DIR="$WORK_DIR/releng"
OUT_DIR="$(pwd)/out"

info "Creating work directory structure..."
mkdir -p "$WORK_DIR" "$OUT_DIR"

# Clean any existing work
if [ -d "$WORK_DIR/releng" ]; then
    warn "Removing existing work directory..."
    rm -rf "$WORK_DIR/releng"
fi

# Copy base archiso profile
info "Copying archiso releng profile..."
cp -r /usr/share/archiso/configs/releng "$WORK_DIR/"
chmod u+w "$PROFILE_DIR/profiledef.sh"

# ==============================================================================
# Package List
# ==============================================================================

info "Configuring package list..."
cat >> "$PROFILE_DIR/packages.x86_64" <<'EOF'

# Display Server
xorg-server
xorg-xinit
xorg-xrandr
xorg-xsetroot

# Display Manager
sddm
qt5-wayland
qt6-wayland

# Wayland Compositors
hyprland
xdg-desktop-portal-hyprland
niri
xdg-desktop-portal-gnome

# NVIDIA Drivers
nvidia
nvidia-utils
nvidia-settings
egl-wayland

# Intel Graphics
intel-media-driver
vulkan-intel
mesa

# Essential Wayland
wayland
wayland-protocols
xorg-xwayland

# Terminal & Shell
alacritty
bash-completion

# Application Launcher
fuzzel

# File Manager
nautilus
gnome-themes-extra

# Fonts
ttf-dejavu
ttf-liberation
noto-fonts
noto-fonts-emoji
ttf-font-awesome

# Audio
pipewire
pipewire-alsa
pipewire-pulse
pipewire-jack
wireplumber
pavucontrol

# Network

iwd

# Tools
git
curl
wget
vim
nano
htop
btop
polkit-gnome
gnome-keyring
libnotify
gedit
ttf-jetbrains-mono-nerd
waybar

EOF



# ==============================================================================
# Airootfs Structure
# ==============================================================================

AIROOTFS="$PROFILE_DIR/airootfs"
info "Setting up airootfs structure..."

mkdir -p "$AIROOTFS/etc/skel/.config"/{hypr,niri,alacritty,fuzzel}
mkdir -p "$AIROOTFS/etc/sddm.conf.d"
mkdir -p "$AIROOTFS/etc/systemd/system"
mkdir -p "$AIROOTFS/usr/local/bin"
mkdir -p "$AIROOTFS/etc/modprobe.d"
mkdir -p "$AIROOTFS/etc/X11/xorg.conf.d"

# ==============================================================================
# Build and Include AUR Packages
# ==============================================================================

info "Building AUR packages for offline inclusion..."
AUR_BUILD_DIR="$WORK_DIR/aur_builds"
AUR_CACHE_DIR="$AIROOTFS/var/cache/pacman/pkg"

mkdir -p "$AUR_BUILD_DIR"
mkdir -p "$AUR_CACHE_DIR"

# Check if user wants to use local cache or build from AUR
echo ""
echo "AUR Package Options:"
echo "1) Build from AUR (requires makepkg, takes time)"
echo "2) Copy from local cache at /var/cache/pacman/pkg/"
echo "3) Skip AUR packages"
read -rp "Enter your choice [1-3]: " aur_choice

case "$aur_choice" in
    1)
        info "Building AUR packages from source..."
        
        # Temporarily drop to build user (can't build as root)
        if ! command -v sudo &>/dev/null; then
            warn "sudo not found, attempting to build as root (may fail)"
        fi
        
        # Build each package
        for pkg in "limine-snapper-sync" "limine-mkinitcpio-hook"; do
            info "Building $pkg..."
            
            cd "$AUR_BUILD_DIR"
            
            # Clone from AUR
            if git clone "https://aur.archlinux.org/${pkg}.git"; then
                cd "$pkg"
                
                # Build as non-root if possible
                if [[ $EUID -eq 0 ]] && command -v sudo &>/dev/null; then
                    # Create temporary build user
                    useradd -m -G wheel builduser 2>/dev/null || true
                    echo "builduser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builduser
                    chown -R builduser:builduser "$AUR_BUILD_DIR/$pkg"
                    
                    # Build
                    su - builduser -c "cd '$AUR_BUILD_DIR/$pkg' && makepkg -s --noconfirm" || {
                        error "Failed to build $pkg"
                        continue
                    }
                    
                    # Copy built package to cache
                    cp "$AUR_BUILD_DIR/$pkg"/*.pkg.tar.zst "$AUR_CACHE_DIR/" 2>/dev/null || {
                        error "No package file found for $pkg"
                        continue
                    }
                    
                    success "$pkg built and added to ISO cache"
                else
                    warn "Cannot build as root without sudo. Skipping $pkg."
                fi
                
                cd "$AUR_BUILD_DIR"
            else
                error "Failed to clone $pkg from AUR"
            fi
        done
        
        # Cleanup build user
        userdel -r builduser 2>/dev/null || true
        rm -f /etc/sudoers.d/builduser
        ;;
        
    2)
        info "Copying from local pacman cache..."
        
        LOCAL_CACHE="/var/cache/pacman/pkg"
        
        if [ ! -d "$LOCAL_CACHE" ]; then
            error "Local cache directory not found: $LOCAL_CACHE"
        else
            # Copy AUR packages if they exist
            found_any=false
            for pkg in "limine-snapper-sync" "limine-mkinitcpio-hook"; do
                # Find the package (handles version numbers)
                pkg_file=$(find "$LOCAL_CACHE" -name "${pkg}-*.pkg.tar.zst" | sort -V | tail -1)
                
                if [ -n "$pkg_file" ] && [ -f "$pkg_file" ]; then
                    cp "$pkg_file" "$AUR_CACHE_DIR/"
                    success "Copied: $(basename "$pkg_file")"
                    found_any=true
                else
                    warn "Package not found in local cache: $pkg"
                    echo "    You can install it first with: yay -S $pkg"
                fi
            done
            
            if [ "$found_any" = false ]; then
                warn "No AUR packages found in local cache"
                echo ""
                echo "To build them first, run:"
                echo "  yay -S limine-snapper-sync limine-mkinitcpio-hook"
                echo "Then re-run this script and choose option 2"
            fi
        fi
        ;;
        
    3)
        info "Skipping AUR packages"
        ;;
        
    *)
        warn "Invalid choice, skipping AUR packages"
        ;;
esac

# Create a list of available AUR packages for the user
if [ -d "$AUR_CACHE_DIR" ] && [ "$(ls -A "$AUR_CACHE_DIR"/*.pkg.tar.zst 2>/dev/null)" ]; then
    cat > "$AIROOTFS/etc/skel/AVAILABLE_AUR_PACKAGES.txt" <<'EOF'
# Pre-installed AUR Packages in ISO

The following AUR packages are available offline in this ISO.
They are located in: /var/cache/pacman/pkg/

## Installation

### During archinstall:
These packages will be automatically available to pacman.

### Manual installation:
```bash
sudo pacman -U /var/cache/pacman/pkg/limine-snapper-sync-*.pkg.tar.zst
sudo pacman -U /var/cache/pacman/pkg/limine-mkinitcpio-hook-*.pkg.tar.zst
```

### Using pacstrap (during installation):
```bash
pacstrap /mnt limine-snapper-sync limine-mkinitcpio-hook
```

## Packages Included:

EOF
    
    # List the actual packages included
    for pkg in "$AUR_CACHE_DIR"/*.pkg.tar.zst; do
        if [ -f "$pkg" ]; then
            echo "- $(basename "$pkg")" >> "$AIROOTFS/etc/skel/AVAILABLE_AUR_PACKAGES.txt"
        fi
    done
    
    success "AUR packages added to ISO cache"
    info "Available packages listed in ~/AVAILABLE_AUR_PACKAGES.txt"
else
    info "No AUR packages included in ISO"
fi

# Clean up build directory
rm -rf "$AUR_BUILD_DIR"

info "Downloading ArchVM scripts for offline use..."
ARCHVM_DIR="$AIROOTFS/etc/skel/ArchVM"
mkdir -p "$ARCHVM_DIR"

# Clone the repository during build
if git clone https://github.com/nightdevil00/ArchVM "$ARCHVM_DIR"; then
    success "ArchVM scripts downloaded successfully"
    
    # Make all scripts executable
    find "$ARCHVM_DIR" -type f -name "*.sh" -exec chmod +x {} \;
    
    # Create a README in the directory
    cat > "$ARCHVM_DIR/README.md" <<'README_EOF'
# ArchVM Scripts

These scripts are included offline in this Live ISO.
All scripts are pre-downloaded and executable.

## Usage

All scripts are in your PATH. Just type the script name:
```bash
# Example (adjust to actual script names in the repo)
./script-name.sh
```

## Update Scripts

To get the latest version from GitHub (requires internet):
```bash
archvm-update
```
README_EOF
    
else
    error "Failed to download ArchVM scripts"
    warn "ISO will build without ArchVM scripts"
    warn "Users will need to run 'archvm-clone' after connecting to internet"
fi


# ==============================================================================
# Hyprland Configuration
# ==============================================================================

info "Creating Hyprland configuration..."
cat > "$AIROOTFS/etc/skel/.config/hypr/hyprland.conf" <<'EOF'
# Hyprland Configuration for Live ISO

# Monitor configuration (auto-detect)
monitor=,preferred,auto,1

# NVIDIA specific
env = LIBVA_DRIVER_NAME,nvidia
env = XDG_SESSION_TYPE,wayland
env = GBM_BACKEND,nvidia-drm
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = WLR_NO_HARDWARE_CURSORS,1

# XDG
env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_DESKTOP,Hyprland

# Input configuration
input {
    kb_layout = us
    follow_mouse = 1
    sensitivity = 0
    touchpad {
        natural_scroll = true
    }
}

# General settings
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}


# Animations
animations {
    enabled = true
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = windowsOut, 1, 7, default, popin 80%
    animation = border, 1, 10, default
    animation = borderangle, 1, 8, default
    animation = fade, 1, 7, default
    animation = workspaces, 1, 6, default
}

# Layouts
dwindle {
    pseudotile = true
    preserve_split = true
}

# Keybindings
$mainMod = SUPER
bind = CONTROL, ESCAPE, exit,

# Applications
bind = $mainMod, SPACE, exec, fuzzel
bind = $mainMod, RETURN, exec, alacritty
bind = $mainMod, F, exec, nautilus

# Window management
bind = $mainMod, Q, killactive,
bind = $mainMod SHIFT, E, exit,
bind = $mainMod, V, togglefloating,
bind = $mainMod, P, pseudo,
bind = $mainMod, J, togglesplit,

# Move focus
bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d

# Switch workspaces
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod, 0, workspace, 10

# Move window to workspace
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9
bind = $mainMod SHIFT, 0, movetoworkspace, 10

# Mouse bindings
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

# Autostart
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = gsettings set org.gnome.desktop.interface gtk-theme 'Breeze-Dark'
exec-once = gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
exec-once = alacritty migrate
exec-once = waybar &
EOF

# ==============================================================================
# Niri Configuration
# ==============================================================================

info "Creating Niri configuration..."
cat > "$AIROOTFS/etc/skel/.config/niri/config.kdl" <<'EOF'
// Niri Configuration for Live ISO

input {
    keyboard {
        xkb {
            layout "us"
        }
    }
    
    touchpad {
        natural-scroll true
    }
}

output "eDP-1" {
    mode "1920x1080@60"
}

layout {
    gaps 8
    center-focused-column "never"
}

prefer-no-csd

// NVIDIA environment
environment {
    LIBVA_DRIVER_NAME "nvidia"
    GBM_BACKEND "nvidia-drm"
    __GLX_VENDOR_LIBRARY_NAME "nvidia"
    WLR_NO_HARDWARE_CURSORS "1"
}

// Keybindings
binds {
    // Applications
    Mod+Space { spawn "fuzzel"; }
    Mod+Return { spawn "alacritty"; }
    Mod+F { spawn "nautilus"; }
    
    // Window management
    Ctrl+Escape { quit; }
    Mod+Q { close-window; }
    Mod+Shift+E { quit; }
    
    // Focus movement
    Mod+Left { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up { focus-window-up; }
    Mod+Down { focus-window-down; }
    
    // Window movement
    Mod+Shift+Left { move-column-left; }
    Mod+Shift+Right { move-column-right; }
    Mod+Shift+Up { move-window-up; }
    Mod+Shift+Down { move-window-down; }
    
    // Workspaces
    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }
    
    Mod+Shift+1 { move-column-to-workspace 1; }
    Mod+Shift+2 { move-column-to-workspace 2; }
    Mod+Shift+3 { move-column-to-workspace 3; }
    Mod+Shift+4 { move-column-to-workspace 4; }
    Mod+Shift+5 { move-column-to-workspace 5; }
}

spawn-at-startup "nm-applet" "--indicator"
spawn-at-startup "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"
spawn-at-startup "gsettings" "set" "org.gnome.desktop.interface" "gtk-theme" "Breeze-Dark"
spawn-at-startup "gsettings" "set" "org.gnome.desktop.interface" "color-scheme" "prefer-dark"
EOF

# ==============================================================================
# Alacritty Configuration
# ==============================================================================

info "Creating Alacritty configuration..."
cat > "$AIROOTFS/etc/skel/.config/alacritty/alacritty.toml" <<'EOF'
[window]
opacity = 0.95
padding = { x = 10, y = 10 }

[font]
size = 11.0

[font.normal]
family = "DejaVu Sans Mono"
style = "Regular"

[colors.primary]
background = "#1e1e2e"
foreground = "#cdd6f4"

[shell]
program = "/bin/bash"
EOF

# ==============================================================================
# Fuzzel Configuration
# ==============================================================================

info "Creating Fuzzel configuration..."
cat > "$AIROOTFS/etc/skel/.config/fuzzel/fuzzel.ini" <<'EOF'
[main]
terminal=alacritty
layer=overlay
width=50

[colors]
background=1e1e2edd
text=cdd6f4ff
match=89b4faff
selection=313244ff
selection-text=cdd6f4ff
border=89b4faff

[border]
width=2
radius=8
EOF

# ==============================================================================
# SDDM Configuration
# ==============================================================================

info "Creating SDDM configuration..."
cat > "$AIROOTFS/etc/sddm.conf.d/autologin.conf" <<'EOF'
[Autologin]
User=live
Session=hyprland

[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Theme]
Current=breeze
EOF

# Note: Hyprland and Niri packages provide their own .desktop files
# so we don't need to create them manually

# ==============================================================================
# NVIDIA Configuration
# ==============================================================================

info "Creating NVIDIA configuration..."
cat > "$AIROOTFS/etc/modprobe.d/nvidia.conf" <<'EOF'
options nvidia-drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF

cat > "$AIROOTFS/etc/X11/xorg.conf.d/10-nvidia.conf" <<'EOF'
Section "OutputClass"
    Identifier "nvidia"
    MatchDriver "nvidia-drm"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration"
    Option "PrimaryGPU" "yes"
    ModulePath "/usr/lib/nvidia/xorg"
    ModulePath "/usr/lib/xorg/modules"
EndSection
EOF

# ==============================================================================
# Setup Live User - Proper Build-Time Configuration
# ==============================================================================

info "Configuring live user setup in profiledef.sh..."

# Backup original profiledef.sh
cp "$PROFILE_DIR/profiledef.sh" "$PROFILE_DIR/profiledef.sh.backup"

# Append customizations to profiledef.sh
cat >> "$PROFILE_DIR/profiledef.sh" <<'PROFILEDEF_EOF'

# Custom file permissions
file_permissions+=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/usr/local/bin/archvm-clone.sh"]="0:0:755"
)

# Custom airootfs script - runs during ISO build
customize_airootfs() {
    echo "Running custom airootfs modifications..."
    
    # Load NVIDIA modules
    cat > "${airootfs_dir}/etc/modules-load.d/nvidia.conf" <<EOF
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF
    
    # Create live user in chroot
    echo "Creating live user..."
    arch-chroot "${airootfs_dir}" /bin/bash <<'CHROOT_EOF'
set -e

# Create user with UID 1000 (important for SDDM)
if ! id live &>/dev/null 2>&1; then
    useradd -m -u 1000 -G wheel,audio,video,network,storage -s /bin/bash live
fi
echo 'live:live' | chpasswd

# Enable sudo for wheel group
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Ensure home directory exists
mkdir -p /home/live

# Copy skel configs to live user (including the new .bashrc)
if [ -d /etc/skel/.config ]; then
    cp -r /etc/skel/.config /home/live/ 2>/dev/null || true
fi
if [ -d /etc/skel/ArchVM ]; then
    cp -r /etc/skel/ArchVM /home/live/ 2>/dev/null || true
fi

# Fix ownership
chown -R live:live /home/live

# Create .bashrc with welcome message
cat > /home/live/.bashrc <<'BASHRC_EOF'
# ArchVM Live ISO
export PATH="$HOME/ArchVM:$PATH"

# Only show welcome on interactive shells
if [[ $- == *i* ]]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                          ║"
    echo "║       Welcome to ArchVM Custom Live Environment         ║"
    echo "║                                                          ║"
    echo "║  Keybindings:                                            ║"
    echo "║    SUPER + SPACE  → Fuzzel (App Launcher)               ║"
    echo "║    SUPER + ENTER  → Alacritty (Terminal)                ║"
    echo "║    SUPER + F      → Nautilus (File Manager)             ║"
    echo "║                                                          ║"
    echo "║  Sessions Available:                                     ║"
    echo "║    - Hyprland (default)                                  ║"
    echo "║    - Niri                                                ║"
    echo "║                                                          ║"
    echo "║  ArchVM Scripts: ~/ArchVM/ (offline & ready!)           ║"
    echo "║    All scripts are executable and in your PATH          ║"
    echo "║    Run 'archvm-update' to sync latest from GitHub       ║"
    echo "║                                                          ║"
    echo "║  User: live | Password: live                             ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    
    # List available scripts
    if [ -d "$HOME/ArchVM" ]; then
        echo "📦 Available ArchVM scripts:"
        find "$HOME/ArchVM" -maxdepth 2 -type f -name "*.sh" -executable -printf "   • %f\n" | sort
        echo ""
    fi
    
    # Show available AUR packages if file exists
    if [ -f "$HOME/AVAILABLE_AUR_PACKAGES.txt" ]; then
        echo "📦 Pre-installed AUR packages available offline!"
        echo "   See: ~/AVAILABLE_AUR_PACKAGES.txt for details"
        echo ""
    fi
fi

# Standard bash completion
[ -r /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion
BASHRC_EOF

# Create .bash_profile to ensure .bashrc is sourced
cat > /home/live/.bash_profile <<'BASH_PROFILE_EOF'
[[ -f ~/.bashrc ]] && . ~/.bashrc
BASH_PROFILE_EOF

# Fix ownership
chown live:live /home/live/.bashrc
chown live:live /home/live/.bash_profile

CHROOT_EOF

    # Enable services using systemctl in the chroot environment
    echo "Enabling services..."
    arch-chroot "${airootfs_dir}" systemctl enable sddm.service --now
    arch-chroot "${airootfs_dir}" systemctl set-default graphical.target
    arch-chroot "${airootfs_dir}" systemctl enable NetworkManager.service
    
    # Ensure SDDM config is in place
    if [ ! -f "${airootfs_dir}/etc/sddm.conf.d/autologin.conf" ]; then
        echo "Warning: /etc/sddm.conf.d/autologin.conf not found!"
    fi

    # Create ArchVM clone script
    cat > "${airootfs_dir}/usr/local/bin/archvm-clone.sh" <<'CLONE_EOF'
#!/usr/bin/env bash

echo "Cloning ArchVM repository..."

if [ -d "$HOME/ArchVM" ]; then
    echo "ℹ️  ArchVM already exists at $HOME/ArchVM"
    read -p "Update existing repository? (y/n): " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        cd "$HOME/ArchVM"
        git pull
        echo "✓ Repository updated!"
    fi
else
    cd "$HOME"
    if git clone https://github.com/nightdevil00/ArchVM; then
        echo "✓ ArchVM cloned successfully!"
    else
        echo "❌ Failed to clone. Check your internet connection."
        exit 1
    fi
fi

# Make scripts executable
if [ -d "$HOME/ArchVM" ]; then
    find "$HOME/ArchVM" -type f -name "*.sh" -exec chmod +x {} \; 
    echo "✓ All scripts are now executable"
    echo ""
    echo "Scripts are available in: $HOME/ArchVM"
    echo "They are also in your PATH - just type the script name!"
fi
CLONE_EOF

    chmod +x "${airootfs_dir}/usr/local/bin/archvm-clone.sh"
    # Create ArchVM update script (for updating from GitHub)
    cat > "${airootfs_dir}/usr/local/bin/archvm-update.sh" <<'UPDATE_EOF'
#!/usr/bin/env bash

echo "Updating ArchVM scripts from GitHub..."

if [ ! -d "$HOME/ArchVM" ]; then
    echo "❌ ArchVM directory not found at $HOME/ArchVM"
    exit 1
fi

cd "$HOME/ArchVM"

if git pull; then
    echo "✓ ArchVM scripts updated successfully!"
    find "$HOME/ArchVM" -type f -name "*.sh" -exec chmod +x {} \;
    echo "✓ All scripts are executable"
else
    echo "❌ Failed to update. Check your internet connection."
    exit 1
fi
UPDATE_EOF

    chmod +x "${airootfs_dir}/usr/local/bin/archvm-update.sh"

    # Create symlinks for easier access
    ln -sf /usr/local/bin/archvm-clone.sh "${airootfs_dir}/usr/local/bin/archvm-clone"
    ln -sf /usr/local/bin/archvm-update.sh "${airootfs_dir}/usr/local/bin/archvm-update"
    
    echo "✓ Custom airootfs modifications complete."
}
PROFILEDEF_EOF

# ==============================================================================
# Build ISO
# ==============================================================================

info "Starting ISO build process..."
info "This may take 15-30 minutes depending on your internet speed..."

cd "$WORK_DIR"

# Clean previous builds
if [ -d "$PROFILE_DIR/work" ]; then
    warn "Cleaning previous build artifacts..."
    rm -rf "$PROFILE_DIR/work"
fi

# Build the ISO
info "Building ISO..."
mkarchiso -v -w "$PROFILE_DIR/work" -o "$OUT_DIR" "$PROFILE_DIR"

# Find the generated ISO
ISO_FILE=$(find "$OUT_DIR" -name "*.iso" -type f -printf "%T@ %p\n" | sort -n | tail -1 | cut -d' ' -f2-)

if [ -n "$ISO_FILE" ]; then
    success "ISO built successfully!"
    echo ""
    echo "========================================"
    echo "         Build Complete!"
    echo "========================================"
    echo "ISO Location: $ISO_FILE"
    echo "ISO Size: $(du -h "$ISO_FILE" | cut -f1)"
    echo ""
    echo "To test the ISO:"
    echo "  qemu-system-x86_64 -enable-kvm -m 4G -cdrom \"$ISO_FILE\""
    echo ""
    echo "To write to USB (replace /dev/sdX):"
    echo "  sudo dd if=\"$ISO_FILE\" of=/dev/sdX bs=4M status=progress && sync"
    echo "========================================"
else
    error "ISO file not found in $OUT_DIR"
    exit 1
fi
