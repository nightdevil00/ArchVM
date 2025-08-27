#!/bin/bash

# Arch Linux Installation Script with Multiple Storage Support
# Supports /dev/nvme*, /dev/vda*, /dev/mmcblk* with ext4/btrfs, encryption, and DE selection

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "This script should not be run as root. Run as regular user with sudo access."
fi

# Check if running in UEFI mode
if [[ ! -d /sys/firmware/efi/efivars ]]; then
    error "This script requires UEFI mode. Legacy BIOS is not supported."
fi

# Function to detect available storage devices
detect_storage_devices() {
    local devices=()
    
    # Check for NVMe devices
    for dev in /dev/nvme*n1; do
        [[ -e "$dev" ]] && devices+=("$dev")
    done
    
    # Check for VirtIO devices
    for dev in /dev/vda /dev/vdb /dev/vdc; do
        [[ -e "$dev" ]] && devices+=("$dev")
    done
    
    # Check for MMC devices (memory cards)
    for dev in /dev/mmcblk*; do
        [[ -e "$dev" ]] && [[ "$dev" != *"p"* ]] && devices+=("$dev")
    done
    
    # Check for SATA/SCSI devices
    for dev in /dev/sd[a-z]; do
        [[ -e "$dev" ]] && devices+=("$dev")
    done
    
    echo "${devices[@]}"
}

# Function to select storage device
select_storage_device() {
    local devices=($(detect_storage_devices))
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        error "No suitable storage devices found!"
    fi
    
    echo -e "${BLUE}Available storage devices:${NC}"
    for i in "${!devices[@]}"; do
        local size=$(lsblk -bno SIZE "${devices[$i]}" | head -1 | numfmt --to=iec)
        echo "$((i+1)). ${devices[$i]} ($size)"
    done
    
    while true; do
        read -p "Select device (1-${#devices[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#devices[@]} ]]; then
            DEVICE="${devices[$((choice-1))]}"
            break
        else
            warn "Invalid selection. Please try again."
        fi
    done
    
    log "Selected device: $DEVICE"
}

# Function to select filesystem
select_filesystem() {
    echo -e "${BLUE}Select filesystem for root partition:${NC}"
    echo "1. ext4"
    echo "2. btrfs"
    
    while true; do
        read -p "Select filesystem (1-2): " choice
        case $choice in
            1) FILESYSTEM="ext4"; break ;;
            2) FILESYSTEM="btrfs"; break ;;
            *) warn "Invalid selection. Please try again." ;;
        esac
    done
    
    log "Selected filesystem: $FILESYSTEM"
}

# Function to configure encryption
configure_encryption() {
    read -p "Enable disk encryption? (y/N): " encrypt
    if [[ "$encrypt" =~ ^[Yy]$ ]]; then
        ENCRYPTION=true
        log "Disk encryption will be enabled"
    else
        ENCRYPTION=false
        log "Disk encryption will be disabled"
    fi
}

# Function to select desktop environment
select_desktop_environment() {
    echo -e "${BLUE}Select Desktop Environment:${NC}"
    echo "1. GNOME"
    echo "2. KDE Plasma"
    echo "3. Niri (Wayland compositor)"
    echo "4. Hyprland"
    echo "5. None (minimal install)"
    
    while true; do
        read -p "Select DE (1-5): " choice
        case $choice in
            1) DE="gnome"; break ;;
            2) DE="kde"; break ;;
            3) DE="niri"; break ;;
            4) DE="hyprland"; break ;;
            5) DE="none"; break ;;
            *) warn "Invalid selection. Please try again." ;;
        esac
    done
    
    log "Selected desktop environment: $DE"
    
    # If Hyprland is selected, offer dotfiles options
    if [[ "$DE" == "hyprland" ]]; then
        select_hyprland_dotfiles
    fi
}

# Function to select Hyprland dotfiles
select_hyprland_dotfiles() {
    echo -e "${BLUE}Hyprland Dotfiles Options:${NC}"
    echo "1. JaKooLit's Hyprland dotfiles (install now)"
    echo "2. Omarchy dotfiles (install now)"
    echo "3. Create post-install script only"
    echo "4. Skip dotfiles"
    
    while true; do
        read -p "Select option (1-4): " choice
        case $choice in
            1) 
                DOTFILES="jakoolit"
                INSTALL_DOTFILES_NOW=true
                break ;;
            2) 
                DOTFILES="omarchy"
                INSTALL_DOTFILES_NOW=true
                break ;;
            3) 
                DOTFILES="post-script"
                INSTALL_DOTFILES_NOW=false
                break ;;
            4) 
                DOTFILES="none"
                INSTALL_DOTFILES_NOW=false
                break ;;
            *) warn "Invalid selection. Please try again." ;;
        esac
    done
    
    log "Dotfiles option: $DOTFILES"
}

# Function to get user information
get_user_info() {
    read -p "Enter username: " USERNAME
    read -p "Enter hostname: " HOSTNAME
    
    # Validate username
    if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        error "Invalid username format"
    fi
    
    log "Username: $USERNAME"
    log "Hostname: $HOSTNAME"
}

# Function to detect existing partitions and Windows
detect_existing_system() {
    log "Detecting existing systems on $DEVICE..."
    
    # Check if disk has any partitions
    if ! parted -s "$DEVICE" print | grep -q "^ [0-9]"; then
        INSTALL_TYPE="clean"
        log "Clean disk detected - full installation"
        return
    fi
    
    # Check for Windows EFI partition
    EXISTING_EFI=""
    WINDOWS_DETECTED=false
    
    # Look for existing EFI system partition
    for part in $(lsblk -rno NAME,FSTYPE "$DEVICE" | awk '$2=="vfat" {print "/dev/"$1}'); do
        if [[ -n "$part" ]] && mountpoint=$(mktemp -d) && mount "$part" "$mountpoint" 2>/dev/null; then
            if [[ -d "$mountpoint/EFI/Microsoft" ]] || [[ -d "$mountpoint/EFI/Boot" ]]; then
                EXISTING_EFI="$part"
                WINDOWS_DETECTED=true
                log "Windows EFI partition detected: $part"
            fi
            umount "$mountpoint" 2>/dev/null
            rmdir "$mountpoint"
        fi
    done
    
    # Check for Windows NTFS partitions
    if lsblk -rno NAME,FSTYPE "$DEVICE" | grep -q "ntfs"; then
        WINDOWS_DETECTED=true
        log "Windows NTFS partitions detected"
    fi
    
    if [[ "$WINDOWS_DETECTED" == true ]]; then
        INSTALL_TYPE="dualboot"
        log "Dual-boot setup will be configured"
    else
        INSTALL_TYPE="clean"
        log "No Windows installation detected"
    fi
}

# Function to choose installation type
choose_installation_type() {
    if [[ "$INSTALL_TYPE" == "dualboot" ]]; then
        echo -e "${YELLOW}Windows installation detected!${NC}"
        echo -e "${BLUE}Installation Options:${NC}"
        echo "1. Dual-boot (install alongside Windows)"
        echo "2. Clean install (WIPE ENTIRE DISK - destroys Windows)"
        
        while true; do
            read -p "Select installation type (1-2): " choice
            case $choice in
                1) 
                    INSTALL_TYPE="dualboot"
                    log "Dual-boot installation selected"
                    break ;;
                2) 
                    INSTALL_TYPE="clean"
                    warn "Clean install will destroy all existing data!"
                    read -p "Are you absolutely sure? Type 'YES' to confirm: " confirm
                    if [[ "$confirm" == "YES" ]]; then
                        log "Clean installation confirmed"
                        break
                    else
                        log "Clean installation cancelled, returning to menu"
                    fi
                    ;;
                *) warn "Invalid selection. Please try again." ;;
            esac
        done
    fi
}

# Function to show disk layout and free space
show_disk_layout() {
    if [[ "$INSTALL_TYPE" == "dualboot" ]]; then
        log "Current disk layout:"
        lsblk "$DEVICE"
        echo ""
        
        # Show free space
        log "Analyzing free space..."
        parted -s "$DEVICE" print free
        echo ""
    fi
}

# Function to partition disk
partition_disk() {
    log "Partitioning $DEVICE..."
    
    # Determine partition naming scheme
    if [[ "$DEVICE" =~ nvme|mmcblk ]]; then
        PART_PREFIX="${DEVICE}p"
    else
        PART_PREFIX="${DEVICE}"
    fi
    
    if [[ "$INSTALL_TYPE" == "clean" ]]; then
        # Clean installation - wipe entire disk
        log "Performing clean installation (wiping entire disk)"
        wipefs -af "$DEVICE"
        
        # Create partition table
        parted -s "$DEVICE" mklabel gpt
        
        # Create EFI partition (512MB)
        parted -s "$DEVICE" mkpart primary fat32 1MiB 513MiB
        parted -s "$DEVICE" set 1 esp on
        
        # Create root partition (remaining space)
        parted -s "$DEVICE" mkpart primary 513MiB 100%
        
        # Set partition variables
        EFI_PART="${PART_PREFIX}1"
        ROOT_PART="${PART_PREFIX}2"
        
    elif [[ "$INSTALL_TYPE" == "dualboot" ]]; then
        # Dual-boot installation
        log "Performing dual-boot installation"
        
        # Find the largest free space
        FREE_SPACE=$(parted -s "$DEVICE" print free | grep "Free Space" | tail -1)
        if [[ -z "$FREE_SPACE" ]]; then
            error "No free space available for installation! Please shrink existing partitions first."
        fi
        
        FREE_START=$(echo "$FREE_SPACE" | awk '{print $1}')
        FREE_END=$(echo "$FREE_SPACE" | awk '{print $2}')
        FREE_SIZE=$(echo "$FREE_SPACE" | awk '{print $3}')
        
        log "Found free space: $FREE_SIZE (from $FREE_START to $FREE_END)"
        
        # Check if free space is sufficient (minimum 20GB)
        FREE_SIZE_GB=$(parted -s "$DEVICE" print free | grep "Free Space" | tail -1 | awk '{print $3}' | sed 's/GB//' | cut -d'.' -f1)
        if [[ "${FREE_SIZE_GB:-0}" -lt 20 ]]; then
            error "Insufficient free space ($FREE_SIZE). At least 20GB required for Linux installation."
        fi
        
        # Get next available partition number
        NEXT_PART_NUM=$(parted -s "$DEVICE" print | awk '/^ [0-9]/ {max=$1} END {print max+1}')
        
        # Create Linux root partition in free space
        parted -s "$DEVICE" mkpart primary "$FREE_START" "$FREE_END"
        
        # Set partition variables
        if [[ -n "$EXISTING_EFI" ]]; then
            EFI_PART="$EXISTING_EFI"
            log "Using existing EFI partition: $EFI_PART"
        else
            error "No existing EFI partition found. Cannot proceed with dual-boot."
        fi
        
        ROOT_PART="${PART_PREFIX}${NEXT_PART_NUM}"
        
    fi
    
    # Wait for partition table to be re-read
    sleep 2
    partprobe "$DEVICE"
    
    log "Created partitions:"
    log "  EFI: $EFI_PART"
    log "  Root: $ROOT_PART"
}

# Function to setup encryption
setup_encryption() {
    if [[ "$ENCRYPTION" == true ]]; then
        log "Setting up disk encryption..."
        
        echo -e "${YELLOW}Enter passphrase for disk encryption:${NC}"
        cryptsetup luksFormat "$ROOT_PART"
        
        echo -e "${YELLOW}Enter passphrase again to open encrypted volume:${NC}"
        cryptsetup open "$ROOT_PART" cryptroot
        
        ROOT_DEVICE="/dev/mapper/cryptroot"
    else
        ROOT_DEVICE="$ROOT_PART"
    fi
}

# Function to create filesystems
create_filesystems() {
    log "Creating filesystems..."
    
    # Format EFI partition only if it's a clean install
    if [[ "$INSTALL_TYPE" == "clean" ]]; then
        log "Formatting new EFI partition"
        mkfs.fat -F32 "$EFI_PART"
    else
        log "Using existing EFI partition (not formatting)"
    fi
    
    # Format root partition based on selected filesystem
    if [[ "$FILESYSTEM" == "ext4" ]]; then
        mkfs.ext4 -F "$ROOT_DEVICE"
    elif [[ "$FILESYSTEM" == "btrfs" ]]; then
        mkfs.btrfs -f "$ROOT_DEVICE"
    fi
}

# Function to mount filesystems and create subvolumes
mount_filesystems() {
    log "Mounting filesystems..."
    
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        mount "$ROOT_DEVICE" /mnt
        
        # Create btrfs subvolumes
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home
        btrfs subvolume create /mnt/@var
        btrfs subvolume create /mnt/@snapshots
        
        umount /mnt
        
        # Mount subvolumes
        mount -o noatime,compress=zstd,space_cache=v2,subvol=@ "$ROOT_DEVICE" /mnt
        mkdir -p /mnt/{home,var,boot,.snapshots}
        mount -o noatime,compress=zstd,space_cache=v2,subvol=@home "$ROOT_DEVICE" /mnt/home
        mount -o noatime,compress=zstd,space_cache=v2,subvol=@var "$ROOT_DEVICE" /mnt/var
        mount -o noatime,compress=zstd,space_cache=v2,subvol=@snapshots "$ROOT_DEVICE" /mnt/.snapshots
    else
        mount "$ROOT_DEVICE" /mnt
        mkdir -p /mnt/{home,boot}
    fi
    
    # Mount EFI partition
    mount "$EFI_PART" /mnt/boot
}

# Function to install base system
install_base_system() {
    log "Installing base system..."
    
    # Update package database
    pacman -Sy
    
    # Install base packages
    pacstrap /mnt base base-devel linux linux-firmware linux-headers
    
    # Generate fstab
    genfstab -U /mnt >> /mnt/etc/fstab
    
    log "Base system installed successfully"
}

# Function to configure system
configure_system() {
    log "Configuring system..."
    
    # Create chroot script
    cat > /mnt/configure_system.sh << 'CHROOT_EOF'
#!/bin/bash

# Set timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

# Configure locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set hostname
echo "HOSTNAME_PLACEHOLDER" > /etc/hostname

# Configure hosts
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   HOSTNAME_PLACEHOLDER.localdomain HOSTNAME_PLACEHOLDER
EOF

# Enable essential services
systemctl enable NetworkManager
systemctl enable systemd-timesyncd

# Install and configure GRUB
pacman -S --noconfirm grub efibootmgr

# Install additional packages (including network management)
pacman -S --noconfirm networkmanager wget curl git vim nano sudo wpa_supplicant dhcpcd

# Configure sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Install NVIDIA drivers
pacman -S --noconfirm nvidia nvidia-utils nvidia-settings

CHROOT_EOF
    
    # Replace placeholder with actual hostname
    sed -i "s/HOSTNAME_PLACEHOLDER/$HOSTNAME/g" /mnt/configure_system.sh
    
    # Make script executable and run it
    chmod +x /mnt/configure_system.sh
    arch-chroot /mnt /configure_system.sh
    
    # Remove the script
    rm /mnt/configure_system.sh
}

# Function to setup GRUB
setup_grub() {
    log "Setting up GRUB bootloader..."
    
    # Create GRUB installation script
    cat > /mnt/setup_grub.sh << 'GRUB_EOF'
#!/bin/bash

if [[ "ENCRYPTION_PLACEHOLDER" == "true" ]]; then
    # Add encryption support to GRUB
    echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
    
    # Get UUID of encrypted partition
    ROOT_UUID=$(blkid -s UUID -o value ROOT_PART_PLACEHOLDER)
    sed -i "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
    
    # Add encrypt hook to mkinitcpio
    sed -i 's/HOOKS=(.*)/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
    
    # Regenerate initramfs
    mkinitcpio -P
fi

# Install os-prober for dual-boot detection
if [[ "INSTALL_TYPE_PLACEHOLDER" == "dualboot" ]]; then
    pacman -S --noconfirm os-prober
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# Generate GRUB configuration
grub-mkconfig -o /boot/grub/grub.cfg

GRUB_EOF
    
    # Replace placeholders
    sed -i "s/ENCRYPTION_PLACEHOLDER/$ENCRYPTION/g" /mnt/setup_grub.sh
    sed -i "s|ROOT_PART_PLACEHOLDER|$ROOT_PART|g" /mnt/setup_grub.sh
    sed -i "s/INSTALL_TYPE_PLACEHOLDER/$INSTALL_TYPE/g" /mnt/setup_grub.sh
    
    # Make script executable and run it
    chmod +x /mnt/setup_grub.sh
    arch-chroot /mnt /setup_grub.sh
    
    # Remove the script
    rm /mnt/setup_grub.sh
}

# Function to create user
create_user() {
    log "Creating user account..."
    
    cat > /mnt/create_user.sh << 'USER_EOF'
#!/bin/bash

# Create user
useradd -m -G wheel -s /bin/bash USERNAME_PLACEHOLDER

# Set user password
echo "Please set password for USERNAME_PLACEHOLDER:"
passwd USERNAME_PLACEHOLDER

# Set root password
echo "Please set root password:"
passwd

USER_EOF
    
    sed -i "s/USERNAME_PLACEHOLDER/$USERNAME/g" /mnt/create_user.sh
    
    chmod +x /mnt/create_user.sh
    arch-chroot /mnt /create_user.sh
    
    rm /mnt/create_user.sh
}

# Function to install desktop environment
install_desktop_environment() {
    if [[ "$DE" == "none" ]]; then
        log "Skipping desktop environment installation"
        return
    fi
    
    log "Installing desktop environment: $DE"
    
    cat > /mnt/install_de.sh << 'DE_EOF'
#!/bin/bash

case "DE_PLACEHOLDER" in
    gnome)
        pacman -S --noconfirm gnome gnome-extra gdm
        systemctl enable gdm
        ;;
    kde)
        pacman -S --noconfirm plasma plasma-wayland-session kde-applications sddm
        systemctl enable sddm
        ;;
    niri)
        # Install Niri from AUR (will be done with yay later)
        pacman -S --noconfirm wayland wayland-protocols xorg-xwayland
        ;;
    hyprland)
        pacman -S --noconfirm hyprland waybar wofi kitty
        ;;
esac

# Install Xorg for compatibility
pacman -S --noconfirm xorg-server xorg-apps

DE_EOF
    
    sed -i "s/DE_PLACEHOLDER/$DE/g" /mnt/install_de.sh
    
    chmod +x /mnt/install_de.sh
    arch-chroot /mnt /install_de.sh
    
    rm /mnt/install_de.sh
}

# Function to install yay and post-install packages
install_post_packages() {
    log "Installing yay AUR helper and additional packages..."
    
    cat > /mnt/install_post.sh << 'POST_EOF'
#!/bin/bash

# Switch to user for yay installation
sudo -u USERNAME_PLACEHOLDER bash << 'YAY_EOF'
cd /home/USERNAME_PLACEHOLDER

# Install yay
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay

# Install google-chrome
yay -S --noconfirm google-chrome

# Install Niri if selected
if [[ "DE_PLACEHOLDER" == "niri" ]]; then
    yay -S --noconfirm niri
fi

YAY_EOF

POST_EOF
    
    sed -i "s/USERNAME_PLACEHOLDER/$USERNAME/g" /mnt/install_post.sh
    sed -i "s/DE_PLACEHOLDER/$DE/g" /mnt/install_post.sh
    
    chmod +x /mnt/install_post.sh
    arch-chroot /mnt /install_post.sh
    
    rm /mnt/install_post.sh
}

# Function to install Hyprland dotfiles
install_hyprland_dotfiles() {
    if [[ "$DE" != "hyprland" ]] || [[ "$DOTFILES" == "none" ]]; then
        return
    fi
    
    if [[ "$INSTALL_DOTFILES_NOW" == true ]]; then
        log "Installing Hyprland dotfiles: $DOTFILES"
        
        cat > /mnt/install_dotfiles.sh << 'DOTFILES_EOF'
#!/bin/bash

# Switch to user for dotfiles installation
sudo -u USERNAME_PLACEHOLDER bash << 'USER_DOTFILES_EOF'
cd /home/USERNAME_PLACEHOLDER

case "DOTFILES_PLACEHOLDER" in
    jakoolit)
        echo "Installing JaKooLit's Hyprland dotfiles..."
        
        # Install required dependencies first
        yay -S --noconfirm --needed hyprland-git waybar-git swww sddm-git \
        rofi-lbonn-wayland-git dunst otf-font-awesome ttf-jetbrains-mono-nerd \
        polkit-gnome python-requests starship swaylock-effects swaybg \
        swayidle wlogout xdg-desktop-portal-hyprland-git pamixer pavucontrol \
        brightnessctl bluez bluez-utils blueman network-manager-applet grim \
        slurp wf-recorder wl-clipboard cliphist python-pyamdgpuinfo \
        inxi lm_sensors amd-ucode thermald btop jq gvfs gvfs-mtp \
        ffmpegthumbs kde-cli-tools kimageformats qt5-wayland qt6-wayland \
        gtk4 libva-mesa-driver qt5-svg qt5-quickcontrols2 qt5-graphicaleffects
        
        # Clone and install JaKooLit dotfiles
        git clone --depth=1 https://github.com/JaKooLit/Arch-Hyprland.git ~/Arch-Hyprland
        cd ~/Arch-Hyprland
        
        # Make install script executable and run
        chmod +x install.sh
        ./install.sh --auto
        ;;
        
    omarchy)
        echo "Installing Omarchy dotfiles..."
        
        # Install basic dependencies
        yay -S --noconfirm --needed waybar rofi-wayland dunst \
        ttf-jetbrains-mono-nerd polkit-gnome swaylock swayidle \
        wlogout grim slurp wl-clipboard brightnessctl pavucontrol
        
        # Clone Omarchy dotfiles (adjust URL as needed)
        git clone https://github.com/omakoto/omarchy-dotfiles.git ~/omarchy-dotfiles
        cd ~/omarchy-dotfiles
        
        # Copy configuration files
        mkdir -p ~/.config
        cp -r .config/* ~/.config/ 2>/dev/null || true
        cp -r .local ~/.local 2>/dev/null || true
        
        echo "Omarchy dotfiles installed. Please check their documentation for additional setup steps."
        ;;
esac

USER_DOTFILES_EOF

DOTFILES_EOF
        
        sed -i "s/USERNAME_PLACEHOLDER/$USERNAME/g" /mnt/install_dotfiles.sh
        sed -i "s/DOTFILES_PLACEHOLDER/$DOTFILES/g" /mnt/install_dotfiles.sh
        
        chmod +x /mnt/install_dotfiles.sh
        arch-chroot /mnt /install_dotfiles.sh
        
        rm /mnt/install_dotfiles.sh
    fi
}

# Function to create post-install dotfiles script
create_post_install_script() {
    if [[ "$DE" == "hyprland" ]] && ([[ "$DOTFILES" == "post-script" ]] || [[ "$INSTALL_DOTFILES_NOW" == false ]]); then
        log "Creating post-install dotfiles script..."
        
        cat > /mnt/home/$USERNAME/install-hyprland-dotfiles.sh << 'POST_DOTFILES_EOF'
#!/bin/bash

# Hyprland Dotfiles Installation Script
# Run this script after your first login

echo "=== Hyprland Dotfiles Installation ==="
echo "Choose your preferred dotfiles setup:"
echo "1. JaKooLit's Hyprland dotfiles (comprehensive setup)"
echo "2. Omarchy dotfiles (minimal setup)"
echo "3. Exit"

read -p "Select option (1-3): " choice

case $choice in
    1)
        echo "Installing JaKooLit's Hyprland dotfiles..."
        
        # Install required dependencies
        yay -S --needed hyprland-git waybar-git swww sddm-git \
        rofi-lbonn-wayland-git dunst otf-font-awesome ttf-jetbrains-mono-nerd \
        polkit-gnome python-requests starship swaylock-effects swaybg \
        swayidle wlogout xdg-desktop-portal-hyprland-git pamixer pavucontrol \
        brightnessctl bluez bluez-utils blueman network-manager-applet grim \
        slurp wf-recorder wl-clipboard cliphist python-pyamdgpuinfo \
        inxi lm_sensors amd-ucode thermald btop jq gvfs gvfs-mtp \
        ffmpegthumbs kde-cli-tools kimageformats qt5-wayland qt6-wayland \
        gtk4 libva-mesa-driver qt5-svg qt5-quickcontrols2 qt5-graphicaleffects
        
        # Clone and install
        cd ~
        git clone --depth=1 https://github.com/JaKooLit/Arch-Hyprland.git
        cd Arch-Hyprland
        chmod +x install.sh
        ./install.sh
        
        echo "JaKooLit dotfiles installed! Logout and log back in to see changes."
        ;;
        
    2)
        echo "Installing Omarchy dotfiles..."
        
        # Install basic dependencies
        yay -S --needed waybar rofi-wayland dunst ttf-jetbrains-mono-nerd \
        polkit-gnome swaylock swayidle wlogout grim slurp wl-clipboard \
        brightnessctl pavucontrol
        
        # Clone and install
        cd ~
        git clone https://github.com/omakoto/omarchy-dotfiles.git
        cd omarchy-dotfiles
        
        # Copy config files
        mkdir -p ~/.config
        cp -r .config/* ~/.config/ 2>/dev/null || true
        cp -r .local ~/.local 2>/dev/null || true
        
        echo "Omarchy dotfiles installed! Please check their documentation for additional setup."
        ;;
        
    3)
        echo "Installation cancelled."
        exit 0
        ;;
        
    *)
        echo "Invalid selection."
        exit 1
        ;;
esac

echo ""
echo "Installation completed!"
echo "You may want to reboot or logout/login to see all changes take effect."

POST_DOTFILES_EOF
        
        # Make script executable and owned by user
        chmod +x /mnt/home/$USERNAME/install-hyprland-dotfiles.sh
        arch-chroot /mnt chown $USERNAME:$USERNAME /home/$USERNAME/install-hyprland-dotfiles.sh
        
        log "Post-install dotfiles script created at /home/$USERNAME/install-hyprland-dotfiles.sh"
    fi
}

# Function to cleanup and finish
cleanup_and_finish() {
    log "Cleaning up and finishing installation..."
    
    # Sync disks
    sync
    
    # Unmount filesystems
    if [[ "$FILESYSTEM" == "btrfs" ]]; then
        umount /mnt/{.snapshots,var,home,boot}
    else
        umount /mnt/{boot,home}
    fi
    umount /mnt
    
    # Close encrypted volume if used
    if [[ "$ENCRYPTION" == true ]]; then
        cryptsetup close cryptroot
    fi
    
    log "Installation completed successfully!"
    log "You can now reboot into your new Arch Linux system."
    
    read -p "Reboot now? (y/N): " reboot_now
    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# Main installation function
main() {
    log "Starting Arch Linux installation..."
    
    # Check internet connection
    if ! ping -c 1 google.com &> /dev/null; then
        error "No internet connection. Please connect to the internet and try again."
    fi
    
    # Update system clock
    timedatectl set-ntp true
    
    # Get user choices
    select_storage_device
    detect_existing_system
    choose_installation_type
    show_disk_layout
    select_filesystem
    configure_encryption
    select_desktop_environment
    get_user_info
    
    # Confirm installation
    echo -e "${YELLOW}Installation Summary:${NC}"
    echo "Device: $DEVICE"
    echo "Installation Type: $INSTALL_TYPE"
    if [[ "$INSTALL_TYPE" == "dualboot" ]]; then
        echo "EFI Partition: $EXISTING_EFI (existing)"
    fi
    echo "Filesystem: $FILESYSTEM"
    echo "Encryption: $ENCRYPTION"
    echo "Desktop Environment: $DE"
    if [[ "$DE" == "hyprland" ]]; then
        echo "Hyprland Dotfiles: $DOTFILES"
        echo "Install During Setup: $INSTALL_DOTFILES_NOW"
    fi
    echo "Username: $USERNAME"
    echo "Hostname: $HOSTNAME"
    
    read -p "Proceed with installation? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "Installation cancelled."
        exit 0
    fi
    
    # Perform installation
    partition_disk
    setup_encryption
    create_filesystems
    mount_filesystems
    install_base_system
    configure_system
    setup_grub
    create_user
    install_desktop_environment
    install_post_packages
    install_hyprland_dotfiles
    create_post_install_script
    cleanup_and_finish
}

# Run main function
main "$@"
