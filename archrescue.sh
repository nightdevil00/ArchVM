#!/bin/bash

# ==============================================================================
#
# Arch Linux Interactive Rescue Script
#
# This script is designed to be run from an Arch Linux live environment (e.g.,
# a bootable USB) to repair a broken installation. It provides a step-by-step
# interactive menu to mount the system, chroot as a specific user, and then
# perform repair operations.
#
# ==============================================================================

set -euo pipefail

# --- Utility Functions ---
C_BLUE="\e[34m"
C_GREEN="\e[32m"
C_RED="\e[31m"
C_RESET="\e[0m"

info() { echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
error() { echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; }
press_enter_to_continue() { read -rp "Press Enter to continue..."; }

# --- Main Script Functions ---

show_main_menu() {
    clear
    echo "========================================"
    echo " Arch Linux Rescue Script - Main Menu"
    echo "========================================"
    echo "1. Connect to Wi-Fi (Optional)"
    echo "2. Mount System Partitions"
    echo "3. Enter Rescue Shell (Chroot)"
    echo "4. Unmount and Reboot"
    echo "5. Exit"
    echo "----------------------------------------"
}

connect_wifi() {
    info "This will launch the interactive iwctl tool."
    echo "  Follow these steps inside iwctl:"
    echo "  1. Run: device list"
    echo "  2. Run: station <device_name> scan"
    echo "  3. Run: station <device_name> get-networks"
    echo "  4. Run: station <device_name> connect <SSID>"
    echo "  5. When connected, type 'exit' to return."
    echo
    iwctl
    success "Returned from iwctl. Check connection with 'ping archlinux.org'."
}

mount_system() {
    info "Listing available block devices..."
    lsblk -d -o NAME,SIZE,MODEL
    echo
    read -rp "Enter the disk containing your Arch Linux installation (e.g., sda, nvme0n1): " disk_name
    local disk="/dev/${disk_name}"
    if [ ! -b "${disk}" ]; then
        error "Disk ${disk} not found."
        return 1
    fi

    info "Listing partitions on ${disk}..."
    lsblk "${disk}"
    echo
    read -rp "Enter the LUKS partition name (e.g., sda2, nvme0n1p2): " luks_partition_name
    local luks_partition="/dev/${luks_partition_name}"

    if [ ! -b "${luks_partition}" ]; then
        error "Partition ${luks_partition} not found."
        return 1
    fi

    info "Opening LUKS container at ${luks_partition}..."
    cryptsetup open "${luks_partition}" cryptroot
    if [ $? -ne 0 ]; then
        error "Failed to open LUKS container."
        return 1
    fi
    success "LUKS container opened."

    # Wait for device mapper
    sleep 1
    if [ ! -b /dev/mapper/cryptroot ]; then
        error "/dev/mapper/cryptroot not found after opening LUKS."
        return 1
    fi

    info "Mounting BTRFS root subvolume to /mnt..."
    mount -o subvol=@ /dev/mapper/cryptroot /mnt
    if [ $? -ne 0 ]; then
        error "Failed to mount root subvolume."
        return 1
    fi

    # Mount other important filesystems for chroot
    info "Mounting additional filesystems..."
    mount -o subvol=@home /dev/mapper/cryptroot /mnt/home 2>/dev/null || true
    mount -o subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots 2>/dev/null || true
    
    # Mount EFI partition if it exists
    read -rp "Do you need to mount the EFI partition? (y/n): " mount_efi
    if [[ "$mount_efi" =~ ^[Yy]$ ]]; then
        read -rp "Enter the EFI partition name (e.g., sda1, nvme0n1p1): " efi_partition_name
        local efi_partition="/dev/${efi_partition_name}"
        if [ -b "${efi_partition}" ]; then
            mkdir -p /mnt/boot
            mount "${efi_partition}" /mnt/boot
            success "EFI partition mounted."
        else
            error "EFI partition ${efi_partition} not found."
        fi
    fi

    # Mount essential filesystems for chroot
    info "Binding essential filesystems..."
    mount --bind /dev /mnt/dev
    mount --bind /proc /mnt/proc
    mount --bind /sys /mnt/sys
    mount --bind /run /mnt/run
    
    # Enable internet in chroot
    mkdir -p /mnt/etc
    cp -L /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true

    success "System partitions mounted under /mnt."
}

enter_rescue_shell() {
    if ! mountpoint -q /mnt; then
        error "System partitions are not mounted. Please run option 2 first."
        return 1
    fi

    echo ""
    echo "Choose rescue shell mode:"
    echo "1. Root shell (no password needed, recommended for repairs)"
    echo "2. User shell (requires sudo password for privileged operations)"
    echo ""
    read -rp "Enter your choice [1-2]: " shell_mode

    local chroot_username="root"
    if [ "$shell_mode" = "2" ]; then
        read -rp "Enter the username: " chroot_username
        if [ -z "${chroot_username}" ]; then
            error "Username cannot be empty."
            return 1
        fi
        # Verify user exists in the chroot
        if ! grep -q "^${chroot_username}:" /mnt/etc/passwd; then
            error "User '${chroot_username}' not found in /etc/passwd."
            return 1
        fi
    fi

    info "Creating inner rescue menu script..."
    # Script goes in /tmp inside the chroot (which is /mnt/tmp from outside)
    local inner_script="/mnt/tmp/inner_rescue.sh"
    mkdir -p /mnt/tmp
    
    cat << 'EOF' > "${inner_script}"
#!/bin/bash

C_BLUE="\e[34m"
C_GREEN="\e[32m"
C_RED="\e[31m"
C_RESET="\e[0m"

info() { echo -e "\n${C_BLUE}INFO:${C_RESET} $1"; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1\n"; }
error() { echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; }

show_inner_menu() {
    clear
    echo "========================================"
    echo " Rescue Shell Menu (Running as: $USER)"
    echo "========================================"
    if [ "$EUID" -ne 0 ]; then
        echo " ⚠️  You will be prompted for your password for root commands."
        echo " ℹ️  If sudo fails, exit and choose 'Root shell' instead."
    else
        echo " ✓ Running as root - no password required"
    fi
    echo "----------------------------------------"
    echo "1. Reinstall Kernel (linux, linux-headers)"
    echo "2. Find and install NVIDIA drivers"
    echo "3. Regenerate Initramfs (mkinitcpio)"
    echo "4. Update all packages (pacman -Syu)"
    echo "5. Rebuild EFI stub images (if using Limine)"
    echo "6. Check disk usage"
    echo "7. Open interactive shell"
    echo "8. Exit Rescue Shell"
    echo "----------------------------------------"
}

run_as_root() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

while true; do
    show_inner_menu
    read -rp "Enter your choice [1-8]: " choice
    case $choice in
        1)
            info "Reinstalling kernel and headers..."
            run_as_root pacman -Syu --noconfirm linux linux-headers || {
                error "Kernel reinstallation failed."
                read -rp "Press Enter to continue..."
                continue
            }
            success "Kernel reinstallation complete."
            read -rp "Press Enter to continue..."
            ;;
        2)
            info "Installing NVIDIA drivers..."
            run_as_root pacman -Syu --noconfirm nvidia nvidia-utils || {
                error "NVIDIA driver installation failed."
                read -rp "Press Enter to continue..."
                continue
            }
            success "NVIDIA driver installation complete."
            read -rp "Press Enter to continue..."
            ;;
        3)
            info "Regenerating initramfs..."
            run_as_root mkinitcpio -P || {
                error "Initramfs regeneration failed."
                read -rp "Press Enter to continue..."
                continue
            }
            success "Initramfs regeneration complete."
            read -rp "Press Enter to continue..."
            ;;
        4)
            info "Updating all packages..."
            run_as_root pacman -Syu || {
                error "Package update failed."
                read -rp "Press Enter to continue..."
                continue
            }
            success "Package update complete."
            read -rp "Press Enter to continue..."
            ;;
        5)
            info "Rebuilding EFI stub images..."
            if [ ! -f /boot/EFI/Linux/arch-linux.efi ]; then
                error "EFI stub images not found. This is only for Limine installations."
                read -rp "Press Enter to continue..."
                continue
            fi
            
            # Get UUIDs
            ROOT_PART=$(grep cryptroot /etc/crypttab | awk '{print $2}' | sed 's/UUID=//')
            RESUME_UUID=$(findmnt -no UUID /)
            RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /swap/swapfile 2>/dev/null | awk '{print $1}' || echo "")
            
            # Create cmdline
            if [ -n "$RESUME_OFFSET" ]; then
                CMDLINE="cryptdevice=UUID=$ROOT_PART:cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ rootfstype=btrfs resume=UUID=$RESUME_UUID resume_offset=$RESUME_OFFSET quiet splash"
            else
                CMDLINE="cryptdevice=UUID=$ROOT_PART:cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ rootfstype=btrfs quiet splash"
            fi
            
            echo "$CMDLINE" > /tmp/cmdline.txt
            
            info "Rebuilding main image..."
            run_as_root objcopy \
                --add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000 \
                --add-section .cmdline=/tmp/cmdline.txt --change-section-vma .cmdline=0x30000 \
                --add-section .linux=/boot/vmlinuz-linux --change-section-vma .linux=0x2000000 \
                --add-section .initrd=/boot/initramfs-linux.img --change-section-vma .initrd=0x3000000 \
                /usr/lib/systemd/boot/efi/linuxx64.efi.stub \
                /boot/EFI/Linux/arch-linux.efi || {
                error "Failed to rebuild main image."
                read -rp "Press Enter to continue..."
                continue
            }
            
            info "Rebuilding fallback image..."
            run_as_root objcopy \
                --add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000 \
                --add-section .cmdline=/tmp/cmdline.txt --change-section-vma .cmdline=0x30000 \
                --add-section .linux=/boot/vmlinuz-linux --change-section-vma .linux=0x2000000 \
                --add-section .initrd=/boot/initramfs-linux-fallback.img --change-section-vma .initrd=0x3000000 \
                /usr/lib/systemd/boot/efi/linuxx64.efi.stub \
                /boot/EFI/Linux/arch-linux-fallback.efi || {
                error "Failed to rebuild fallback image."
                read -rp "Press Enter to continue..."
                continue
            }
            
            rm -f /tmp/cmdline.txt
            success "EFI stub images rebuilt successfully."
            read -rp "Press Enter to continue..."
            ;;
        6)
            info "Checking disk usage..."
            df -h
            echo
            btrfs filesystem usage / 2>/dev/null || true
            read -rp "Press Enter to continue..."
            ;;
        7)
            info "Opening interactive shell. Type 'exit' to return to menu."
            bash
            ;;
        8)
            info "Exiting rescue shell."
            exit 0
            ;;
        *)
            error "Invalid choice."
            read -rp "Press Enter to continue..."
            ;;
    esac
done
EOF

    chmod +x "${inner_script}"

    info "Entering rescue shell as user '${chroot_username}'. You will see a new menu."
    sleep 1
    
    # Test if we're actually running with proper TTY
    if [ "${chroot_username}" = "root" ]; then
        arch-chroot /mnt /tmp/inner_rescue.sh
    else
        # This will work because arch-chroot properly preserves the TTY
        # and su will be able to prompt for password
        arch-chroot /mnt su - "${chroot_username}" -c '/tmp/inner_rescue.sh'
    fi

    rm -f "${inner_script}"
    success "Returned from rescue shell."
}

unmount_and_reboot() {
    info "Unmounting all partitions and closing LUKS container..."
    sync
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    success "Cleanup complete. Rebooting in 3 seconds..."
    sleep 3
    reboot
}

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root."
    exit 1
fi

# --- Main Loop ---
while true; do
    show_main_menu
    read -rp "Enter your choice [1-5]: " choice
    case $choice in
        1) connect_wifi; press_enter_to_continue ;;
        2) mount_system; press_enter_to_continue ;;
        3) enter_rescue_shell; press_enter_to_continue ;;
        4)
            read -rp "Are you sure you want to unmount and reboot? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                unmount_and_reboot
            else
                info "Reboot cancelled."
                press_enter_to_continue
            fi
            ;;
        5) info "Exiting script."; exit 0 ;;
        *) error "Invalid choice."; press_enter_to_continue ;;
    esac
done
