#!/bin/bash

# ==============================================================================
#
# Interactive Arch Linux Repair Script
#
# This script is designed to be run from an Arch Linux live environment (e.g.,
# a bootable USB) to repair a broken installation. It automates the steps
# of mounting encrypted BTRFS partitions, connecting to Wi-Fi, reinstalling
# critical packages within a chroot, and reconfiguring the bootloader.
#
# ==============================================================================

set -e

# --- Utility Functions ---

# Colors for better output
C_BLUE="\e[34m"
C_GREEN="\e[32m"
C_RED="\e[31m"
C_RESET="\e[0m"

info() {
    echo -e "${C_BLUE}INFO:${C_RESET} $1"
}

success() {
    echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"
}

error() {
    echo -e "${C_RED}ERROR:${C_RESET} $1" >&2
}

press_enter_to_continue() {
    read -p "Press Enter to continue..."
}

# --- Core Functions ---

show_menu() {
    clear
    echo "========================================"
    echo " Arch Linux Repair Script"
    echo "========================================"
    echo "1. Connect to Wi-Fi (iwctl)"
    echo "2. Mount System Partitions"
    echo "3. Reinstall Kernel and Drivers (chroot)"
    echo "4. Configure Bootloader (Limine)"
    echo "5. Unmount and Reboot"
    echo "6. Exit"
    echo "----------------------------------------"
}

connect_wifi() {
    info "This will launch the interactive iwctl tool."
    info "Follow these steps inside iwctl:"
    echo "  1. Run: device list"
    echo "  2. Find your wireless device name (e.g., wlan0)."
    echo "  3. Run: station <device_name> scan"
    echo "  4. Run: station <device_name> get-networks"
    echo "  5. Run: station <device_name> connect <SSID>"
    echo "  6. When connected, type 'exit' to return to this script."
    echo
    iwctl
    success "Returned from iwctl. Check your connection with 'ping archlinux.org'."
}

mount_partitions() {
    info "Listing available block devices..."
    lsblk -d -o NAME,SIZE,MODEL
    echo

    read -p "Enter the LUKS partition name (e.g., sda2, nvme0n1p2): " luks_partition_name
    local luks_partition="/dev/${luks_partition_name}"
    read -p "Enter the EFI System Partition name (e.g., sda1, nvme0n1p1): " esp_partition_name
    local esp_partition="/dev/${esp_partition_name}"

    if [ ! -b "${luks_partition}" ]; then
        error "LUKS partition ${luks_partition} not found."
        return 1
    fi
    if [ ! -b "${esp_partition}" ]; then
        error "EFI partition ${esp_partition} not found."
        return 1
    fi

    info "Opening LUKS container at ${luks_partition}..."
    cryptsetup open "${luks_partition}" cryptroot
    if [ $? -ne 0 ]; then
        error "Failed to open LUKS container. Incorrect password or not a LUKS partition."
        return 1
    fi
    success "LUKS container opened as /dev/mapper/cryptroot."

    read -p "Enter the BTRFS root subvolume name (default: @): " root_subvol
    root_subvol=${root_subvol:-@}
    read -p "Enter the BTRFS home subvolume name (default: @home): " home_subvol
    home_subvol=${home_subvol:-@home}

    info "Mounting BTRFS subvolumes to /mnt..."
    mount -o "subvol=${root_subvol}" /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/home
    mount -o "subvol=${home_subvol}" /dev/mapper/cryptroot /mnt/home
    mkdir -p /mnt/boot
    mount "${esp_partition}" /mnt/boot

    success "System partitions mounted under /mnt."
    df -h /mnt /mnt/home /mnt/boot
}

reinstall_packages_chroot() {
    if ! mountpoint -q /mnt; then
        error "System partitions are not mounted. Please run option 2 first."
        return 1
    fi

    info "Preparing to enter chroot environment..."
    
    local chroot_script="/mnt/repair_script.sh"
    cat << EOF > "${chroot_script}"
#!/bin/bash
set -e

echo "--- Now inside chroot ---"
echo "Testing internet connectivity..."
if ! ping -c 1 archlinux.org &> /dev/null; then
    echo "WARNING: No internet connection inside chroot. Pacman will likely fail."
fi

echo "Syncing pacman repositories..."
pacman -Syy

echo "Reinstalling linux and linux-headers..."
pacman -S --noconfirm linux linux-headers

if lspci | grep -iq 'NVIDIA'; then
    echo "NVIDIA card detected. Reinstalling NVIDIA drivers..."
    pacman -S --noconfirm nvidia
else
    echo "No NVIDIA card detected. Skipping NVIDIA drivers."
fi

echo "Regenerating initramfs..."
mkinitcpio -P

echo "--- Leaving chroot ---"
EOF

    chmod +x "${chroot_script}"
    
    info "Entering chroot and executing repair script..."
    arch-chroot /mnt /repair_script.sh
    
    rm "${chroot_script}"
    success "Kernel and drivers reinstalled successfully."
}

configure_limine() {
    if ! mountpoint -q /mnt; then
        error "System partitions are not mounted. Please run option 2 first."
        return 1
    fi

    info "Running limine-deploy inside chroot..."
    arch-chroot /mnt limine-deploy

    echo
    info "Please provide the UUID of your LUKS partition to configure limine.cfg."
    lsblk -f
    echo
    read -p "Enter the UUID of your LUKS partition from the list above: " luks_uuid

    if [ -z "${luks_uuid}" ]; then
        error "LUKS UUID cannot be empty."
        return 1
    fi

    info "Creating new limine.cfg..."
    local limine_cfg="/mnt/boot/limine.cfg"
    cat << EOF > "${limine_cfg}"
TIMEOUT=5
DEFAULT_ENTRY=arch

:arch
PROTOCOL=linux
KERNEL_PATH=boot/vmlinuz-linux
CMDLINE=cryptdevice=UUID=${luks_uuid}:cryptroot root=/dev/mapper/cryptroot rw
INITRD_PATH=boot/initramfs-linux.img
EOF

    success "limine.cfg created at ${limine_cfg}"
    echo "--- limine.cfg content ---"
    cat "${limine_cfg}"
    echo "--------------------------"
}

unmount_and_reboot() {
    info "Unmounting all partitions under /mnt..."
    umount -R /mnt || true
    info "Closing LUKS container..."
    cryptsetup close cryptroot || true
    success "Cleanup complete. Rebooting in 3 seconds..."
    sleep 3
    reboot
}

# --- Main Loop ---

while true; do
    show_menu
    read -p "Enter your choice [1-6]: " choice
    case $choice in
        1) connect_wifi; press_enter_to_continue ;;
        2) mount_partitions; press_enter_to_continue ;;
        3) reinstall_packages_chroot; press_enter_to_continue ;;
        4) configure_limine; press_enter_to_continue ;;
        5)
            read -p "Are you sure you want to unmount and reboot? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                unmount_and_reboot
            else
                info "Reboot cancelled."
                press_enter_to_continue
            fi
            ;;
        6)
            info "Exiting script."
            exit 0
            ;;
        *)
            error "Invalid choice. Please enter a number between 1 and 6."
            press_enter_to_continue
            ;;
    esac
done
