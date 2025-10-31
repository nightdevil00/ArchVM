#!/bin/bash
#v1

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect available disks
detect_disks() {
    log_info "Available disks:"
    lsblk -ndo NAME,SIZE,TYPE | grep -E 'nvme|vda|sda|sdb|sdc'
}

# Select disk
select_disk() {
    local disk
    read -p "Enter disk (e.g., /dev/nvme0n1, /dev/vda, /dev/sda): " disk
    
    if [ ! -b "$disk" ]; then
        log_error "Disk $disk not found"
        exit 1
    fi
    
    echo "$disk"
}

# Detect Windows partitions
detect_windows_partitions() {
    local disk=$1
    local windows_parts=()
    
    # Check for NTFS or Windows partition types
    while IFS= read -r part; do
        local fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "")
        if [[ "$fstype" == "ntfs" ]]; then
            windows_parts+=("$part")
        fi
    done < <(lsblk -npo NAME "$disk" | tail -n +2)
    
    printf '%s\n' "${windows_parts[@]}"
}

# Create partitions
create_partitions() {
    local disk=$1
    local has_windows=$2
    
    log_info "Creating partitions..."
    
    if [ "$has_windows" = "true" ]; then
        log_warn "Windows partitions detected - using free space only"
        # Use sgdisk to create partitions in free space
        local free_start=$(parted -s "$disk" print free | grep "Free Space" | tail -1 | awk '{print $2}' | sed 's/s//')
        local free_end=$(parted -s "$disk" print free | grep "Free Space" | tail -1 | awk '{print $3}' | sed 's/s//')
        
        # Create EFI (2G)
        sgdisk -n 0:${free_start}s:+2G -t 0:ef00 "$disk"
        
        # Create ROOT (rest of free space)
        sgdisk -n 0:0:${free_end}s -t 0:8300 "$disk"
    else
        log_info "No Windows partitions - using full disk"
        
        # Clear partition table
        sgdisk -Z "$disk"
        
        # Create GPT
        sgdisk -og "$disk"
        
        # Create EFI partition (2G)
        sgdisk -n 1:0:+2G -t 1:ef00 "$disk"
        
        # Create ROOT partition (rest)
        sgdisk -n 2:0:0 -t 2:8300 "$disk"
    fi
    
    # Reload partition table
    partprobe "$disk"
    sleep 1
    
    log_info "Partitions created successfully"
}

# Get partition names
get_partitions() {
    local disk=$1
    local parts=($(lsblk -npo NAME "$disk" | tail -n +2))
    
    # Assume last two partitions are EFI and ROOT
    if [ ${#parts[@]} -ge 2 ]; then
        EFI_PART="${parts[-2]}"
        ROOT_PART="${parts[-1]}"
    else
        log_error "Could not identify partitions"
        exit 1
    fi
}

# Format partitions
format_partitions() {
    log_info "Formatting partitions..."
    
    mkfs.fat -F 32 "$EFI_PART"
    mkfs.ext4 -F "$ROOT_PART"
    
    log_info "Partitions formatted"
}

# Mount partitions
mount_partitions() {
    log_info "Mounting partitions..."
    
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot
    
    log_info "Partitions mounted"
}

# Install base system
install_base() {
    log_info "Installing Arch Linux base system..."
    
    pacstrap -K /mnt base linux linux-firmware
    
    log_info "Base system installed"
}

# Generate fstab
generate_fstab() {
    log_info "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
}

# Configure system
configure_system() {
    local username=$1
    local password=$2
    local hostname=$3
    
    log_info "Configuring system..."
    
    # Set hostname
    echo "$hostname" > /mnt/etc/hostname
    
    # Set timezone
    arch-chroot /mnt ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    arch-chroot /mnt hwclock --systohc
    
    # Locale
    echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
    arch-chroot /mnt locale-gen
    echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
    
    # Create user
    log_info "Creating user: $username"
    arch-chroot /mnt useradd -m "$username"
    echo "$username:$password" | arch-chroot /mnt chpasswd
    
    # Install sudo
    arch-chroot /mnt pacman -S --noconfirm sudo
    
    # Add user to sudo
    arch-chroot /mnt usermod -aG wheel "$username"
    
    # Enable sudo for wheel group
    sed -i 's/^# %wheel/%wheel/' /mnt/etc/sudoers
    
    log_info "System configured"
}

# Install Limine bootloader
install_limine() {
    local disk=$1
    local efi_part=$2
    local root_part=$3
    
    log_info "Installing Limine bootloader..."
    
    # Install limine package
    arch-chroot /mnt pacman -S --noconfirm limine efibootmgr
    
    # Get partition UUIDs
    local efi_uuid=$(blkid -s PARTUUID -o value "$efi_part")
    local root_uuid=$(blkid -s PARTUUID -o value "$root_part")
    
    # Copy Limine EFI to ESP
    arch-chroot /mnt mkdir -p /boot/EFI/limine
    arch-chroot /mnt cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
    
    # Create limine.conf
    cat > /mnt/boot/limine.conf << 'EOF'
TIMEOUT=3

:Arch Linux
PROTOCOL=limine
KERNEL_PARTITION_UUID=
KERNEL_PATH=/boot/vmlinuz-linux
MODULE_PATH=/boot/initramfs-linux.img
KERNEL_CMDLINE=root=PARTUUID= rw
EOF
    
    # Update limine.conf with actual UUIDs
    sed -i "s|KERNEL_PARTITION_UUID=|KERNEL_PARTITION_UUID=$root_uuid|g" /mnt/boot/limine.conf
    sed -i "s|KERNEL_CMDLINE=root=PARTUUID=|KERNEL_CMDLINE=root=PARTUUID=$root_uuid|g" /mnt/boot/limine.conf
    
    # Create UEFI boot entry
    arch-chroot /mnt efibootmgr --create --disk "$disk" --label "Limine" \
        --loader '\EFI\limine\BOOTX64.EFI' --unicode
    
    log_info "Limine installed and deployed"
}

# Install AUR packages
install_aur_packages() {
    local username=$1
    
    log_info "Installing yay AUR helper..."
    arch-chroot /mnt pacman -S --noconfirm git base-devel
    arch-chroot /mnt sudo -u "$username" git clone https://aur.archlinux.org/yay.git /tmp/yay
    arch-chroot /mnt sudo -u "$username" bash -c "cd /tmp/yay && makepkg -si --noconfirm"
    
    # Install AUR packages for Limine
    log_info "Installing Limine AUR packages..."
    arch-chroot /mnt sudo -u "$username" yay -S --noconfirm limine-snapper-sync limine-mkinitcpio-hook
}

# Get user input
get_user_input() {
    read -p "Enter username: " USERNAME
    if [ -z "$USERNAME" ]; then
        log_error "Username cannot be empty"
        exit 1
    fi
    
    read -sp "Enter password: " PASSWORD
    echo
    if [ -z "$PASSWORD" ]; then
        log_error "Password cannot be empty"
        exit 1
    fi
    
    read -p "Enter hostname (default: arch): " HOSTNAME
    HOSTNAME=${HOSTNAME:-arch}
}

# Main installation
main() {
    log_info "=== Arch Linux Installation Script ==="
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Detect and select disk
    detect_disks
    DISK=$(select_disk)
    
    # Detect Windows partitions
    WINDOWS_PARTS=$(detect_windows_partitions "$DISK")
    if [ -n "$WINDOWS_PARTS" ]; then
        log_warn "Found Windows partitions:"
        echo "$WINDOWS_PARTS"
        HAS_WINDOWS="true"
    else
        log_info "No Windows partitions detected"
        HAS_WINDOWS="false"
    fi
    
    # Get user input
    get_user_input
    
    # Confirm before proceeding
    echo ""
    log_warn "This will modify $DISK"
    log_warn "Username: $USERNAME"
    log_warn "Hostname: $HOSTNAME"
    log_warn "Windows protected: $HAS_WINDOWS"
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
    # Installation steps
    create_partitions "$DISK" "$HAS_WINDOWS"
    get_partitions "$DISK"
    format_partitions
    mount_partitions
    install_base
    generate_fstab
    configure_system "$USERNAME" "$PASSWORD" "$HOSTNAME"
    install_limine "$DISK" "$EFI_PART" "$ROOT_PART"
    install_aur_packages "$USERNAME"
    
    log_info "Installation complete!"
    log_info "Mounted at /mnt - use 'arch-chroot /mnt' to enter"
    log_info "Run 'reboot' when finished"
}

main "$@"
