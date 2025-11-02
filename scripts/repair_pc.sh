#!/bin/bash

# Interactive script to repair a broken Arch Linux installation
# based on the repair_pc.md guide.

# This script is intended to be run from an Arch Linux live USB environment.

# --- Functions ---

show_menu() {
    echo "========================================"
    echo " Arch Linux Repair Script"
    echo "========================================"
    echo "1. Mount Partitions"
    echo "2. Reinstall Kernel and Bootloader"
    echo "3. Configure Limine Bootloader"
    echo "4. Unmount and Reboot"
    echo "5. Exit"
    echo "----------------------------------------"
}

mount_partitions() {
    echo "--- Mount Partitions ---"
    lsblk -d -n -o NAME,SIZE,MODEL
    echo
    read -p "Enter the LUKS partition (e.g., sda2): " LUKS_PARTITION_NAME
    LUKS_PARTITION="/dev/${LUKS_PARTITION_NAME}"
    read -p "Enter the EFI partition (e.g., sda1): " EFI_PARTITION_NAME
    EFI_PARTITION="/dev/${EFI_PARTITION_NAME}"

    if [ ! -b "${LUKS_PARTITION}" ]; then
        echo "Error: LUKS partition ${LUKS_PARTITION} not found."
        return 1
    fi
    if [ ! -b "${EFI_PARTITION}" ]; then
        echo "Error: EFI partition ${EFI_PARTITION} not found."
        return 1
    fi

    echo "Opening LUKS container..."
    cryptsetup open "${LUKS_PARTITION}" root
    if [ $? -ne 0 ]; then
        echo "Failed to open LUKS container. Incorrect password or not a LUKS partition."
        return 1
    fi

    read -p "Enter the BTRFS root subvolume name (default: @): " ROOT_SUBVOL
    ROOT_SUBVOL=${ROOT_SUBVOL:-@}
    read -p "Enter the BTRFS home subvolume name (default: @home): " HOME_SUBVOL
    HOME_SUBVOL=${HOME_SUBVOL:-@home}

    echo "Mounting filesystems..."
    mount -o "subvol=${ROOT_SUBVOL}" /dev/mapper/root /mnt
    mkdir -p /mnt/home
    mount -o "subvol=${HOME_SUBVOL}" /dev/mapper/root /mnt/home
    mkdir -p /mnt/boot
    mount "${EFI_PARTITION}" /mnt/boot

    echo "Partitions mounted successfully."
    df -h /mnt /mnt/home /mnt/boot
}

reinstall_packages() {
    echo "--- Reinstall Kernel and Bootloader ---"
    if ! mountpoint -q /mnt; then
        echo "Error: Partitions are not mounted. Please run option 1 first."
        return 1
    fi

    echo "Entering chroot and reinstalling packages (linux, linux-headers, limine)..."
    
    # Create a script to be executed inside the chroot
    cat << EOF > /mnt/reinstall.sh
#!/bin/bash
set -e
echo "Syncing pacman repositories..."
pacman -Syy
echo "Reinstalling packages..."
pacman -S --noconfirm linux linux-headers limine
echo "Regenerating initramfs..."
mkinitcpio -P
EOF

    chmod +x /mnt/reinstall.sh
    
    # Execute the script in the chroot
    arch-chroot /mnt /reinstall.sh
    
    # Clean up the script
    rm /mnt/reinstall.sh

    echo "Packages reinstalled and initramfs regenerated successfully."
}

configure_limine() {
    echo "--- Configure Limine Bootloader ---"
    if ! mountpoint -q /mnt; then
        echo "Error: Partitions are not mounted. Please run option 1 first."
        return 1
    fi

    echo "Deploying Limine bootloader..."
    arch-chroot /mnt limine-deploy

    echo
    echo "Please provide the UUID of your LUKS partition."
    lsblk -f
    echo
    read -p "Enter the UUID of your LUKS partition from the list above: " LUKS_UUID

    if [ -z "${LUKS_UUID}" ]; then
        echo "Error: LUKS UUID cannot be empty."
        return 1
    fi

    echo "Creating limine.cfg..."
    cat << EOF > /mnt/boot/limine.cfg
TIMEOUT=5
DEFAULT_ENTRY=arch

:arch
PROTOCOL=linux
KERNEL_PATH=boot/vmlinuz-linux
CMDLINE=cryptdevice=UUID=${LUKS_UUID}:root root=/dev/mapper/root rw
INITRD_PATH=boot/initramfs-linux.img
EOF

    echo "limine.cfg created successfully at /mnt/boot/limine.cfg"
    echo "--- limine.cfg content ---"
    cat /mnt/boot/limine.cfg
    echo "--------------------------"
}

unmount_and_reboot() {
    echo "--- Unmount and Reboot ---"
    echo "Unmounting all partitions under /mnt..."
    umount -R /mnt
    echo "Closing LUKS container..."
    cryptsetup close root
    echo "Rebooting now..."
    sleep 3
    reboot
}

# --- Main Loop ---

while true; do
    show_menu
    read -p "Enter your choice [1-5]: " choice
    case $choice in
        1)
            mount_partitions
            ;;
        2)
            reinstall_packages
            ;;
        3)
            configure_limine
            ;;
        4)
            read -p "Are you sure you want to unmount and reboot? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                unmount_and_reboot
            else
                echo "Reboot cancelled."
            fi
            ;;
        5)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid choice. Please enter a number between 1 and 5."
            ;;
    esac
    echo
    read -p "Press Enter to continue..."
    clear
done
