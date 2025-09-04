#!/bin/bash

# Arch Linux Installation Script
# Based on the requirements from file.txt and log files.

# --- Helper Functions ---
info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
    exit 1
}

size_to_mb() {
    size=$1
    if [[ $size == *"G" ]]; then
        echo $((${size//G/}*1024))
    elif [[ $size == *"M" ]]; then
        echo ${size//M/}
    elif [[ $size == *"K" ]]; then
        echo $((${size//K/}/1024))
    else
        echo $size
    fi
}

# --- Initial Setup ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run this script as root."
    fi
}

check_dialog() {
    if ! command -v dialog &> /dev/null; then
        info "dialog could not be found, installing it now."
        pacman -Sy --noconfirm dialog
    fi
}

# --- User Input ---
get_user_info() {
    username=$(dialog --inputbox "Enter your desired username:" 8 40 --stdout)
    password=$(dialog --passwordbox "Enter your password:" 8 40 --stdout)
    password_confirm=$(dialog --passwordbox "Confirm your password:" 8 40 --stdout)

    if [ "$password" != "$password_confirm" ]; then
        dialog --msgbox "Passwords do not match." 8 40
        get_user_info
    fi

    locale=$(dialog --inputbox "Enter your desired locale (e.g., us):" 8 40 "us" --stdout)
    language=$(dialog --inputbox "Enter your desired system language (e.g., en_US.UTF-8):" 8 40 "en_US.UTF-8" --stdout)
}

# --- System Setup ---
setup_system() {
    info "Setting up the system..."
    timedatectl set-ntp true

    info "Updating mirrorlist..."
    reflector --verbose --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

    info "Determining timezone..."
    timezone=$(curl -s ipinfo.io/timezone)
    dialog --yesno "Your timezone is detected as $timezone. Is this correct?" 8 40
    if [ $? -ne 0 ]; then
        timezone=$(dialog --inputbox "Please enter your timezone (e.g., Europe/Bucharest):" 8 40 --stdout)
    fi
    timedatectl set-timezone "$timezone"
}

# --- Disk Partitioning ---
partition_disk() {
    info "Partitioning the disk..."
    mapfile -t devices < <(lsblk -d -n -o NAME,SIZE,MODEL | awk '$1 ~ /^(sd|nvme|vd|mmcblk)/ {print "/dev/"$1, $2, $3}')
    disk=$(dialog --menu "Select a disk for installation:" 15 70 15 "${devices[@]}" --stdout)

    # Check for Windows installation
    has_efi=false
    has_ntfs=false
    while IFS= read -r line; do
        if echo "$line" | grep -iq "fat32"; then
            has_efi=true
        fi
        if echo "$line" | grep -iq "ntfs"; then
            has_ntfs=true
        fi
    done < <(lsblk -f -n -o FSTYPE,NAME "$disk")

    if $has_efi && $has_ntfs; then
        dialog --yesno "Windows installation detected on $disk. Do you want to format the entire disk? (WARNING: THIS WILL DELETE WINDOWS)" 10 60
        if [ $? -eq 0 ]; then
            # Format entire disk
            efi_size=$(dialog --inputbox "Enter the size for the EFI partition (e.g., 512M):" 8 40 "512M" --stdout)
            root_size=$(dialog --inputbox "Enter the size for the ROOT partition (e.g., 50G):" 8 40 "50G" --stdout)

            info "Partitioning $disk..."
            parted -s "$disk" mklabel gpt
            parted -s "$disk" mkpart ESP fat32 1MiB "$efi_size"
            parted -s "$disk" set 1 esp on
            parted -s "$disk" mkpart primary btrfs "$efi_size" 100%
        else
            # Install in free space
            free_space_info=$(parted -s "$disk" print free | grep "Free Space" | tail -n 1)
            if [ -z "$free_space_info" ]; then
                dialog --msgbox "No free space found on $disk." 8 40
                error "Installation aborted."
            fi

            free_space_start=$(echo "$free_space_info" | awk '{print $1}')
            free_space_end=$(echo "$free_space_info" | awk '{print $2}')
            free_space_size=$(echo "$free_space_info" | awk '{print $3}')

            dialog --yesno "Found $free_space_size of free space starting at $free_space_start. Do you want to install Arch Linux in this space?" 8 70
            if [ $? -ne 0 ]; then
                error "Installation aborted by user."
            fi

            efi_size=$(dialog --inputbox "Enter the size for the EFI partition (e.g., 512M):" 8 40 "512M" --stdout)
            root_size=$(dialog --inputbox "Enter the size for the ROOT partition (e.g., 50G):" 8 40 "50G" --stdout)

            efi_size_mb=$(size_to_mb "$efi_size")
            root_size_mb=$(size_to_mb "$root_size")
            free_space_size_mb=$(size_to_mb "$free_space_size")

            if [ $(($efi_size_mb + $root_size_mb)) -gt $free_space_size_mb ]; then
                dialog --msgbox "Not enough free space for the requested partition sizes." 8 60
                error "Installation aborted."
            fi

            efi_part_end=$(echo "$free_space_start" | sed 's/MB//' | awk -v efi_size="$efi_size_mb" '{print $1 + efi_size}')
            root_part_end=$(echo "$efi_part_end" | awk -v root_size="$root_size_mb" '{print $1 + root_size}')

            info "Creating partitions in free space..."
            parted -s "$disk" mkpart ESP fat32 "$free_space_start" "${efi_part_end}MB"
            parted -s "$disk" set 1 esp on
            parted -s "$disk" mkpart primary btrfs "${efi_part_end}MB" "${root_part_end}MB"
        fi
    else
        # No Windows detected, format the entire disk
        dialog --yesno "This will format the entire disk $disk. All data will be lost. Are you sure?" 8 40
        if [ $? -ne 0 ]; then
            error "Installation aborted by user."
        fi

        efi_size=$(dialog --inputbox "Enter the size for the EFI partition (e.g., 512M):" 8 40 "512M" --stdout)
        root_size=$(dialog --inputbox "Enter the size for the ROOT partition (e.g., 50G):" 8 40 "50G" --stdout)

        info "Partitioning $disk..."
        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart ESP fat32 1MiB "$efi_size"
        parted -s "$disk" set 1 esp on
        parted -s "$disk" mkpart primary btrfs "$efi_size" 100%
    fi
}


# --- Installation ---
install_base_system() {
    info "Installing the base system..."
    # Find the partition numbers
    efi_part_num=$(parted -s "$disk" print | grep -i "esp" | awk '{print $1}')
    root_part_num=$(parted -s "$disk" print | grep -i "btrfs" | awk '{print $1}')

    mkfs.fat -F32 "${disk}p${efi_part_num}"
    mkfs.btrfs -f "${disk}p${root_part_num}"
    mount "${disk}p${root_part_num}" /mnt
    btrfs su cr /mnt/@
    btrfs su cr /mnt/@home
    btrfs su cr /mnt/@pkg
    btrfs su cr /mnt/@log
    btrfs su cr /mnt/@snapshots
    umount /mnt

    mount -o noatime,compress=zstd,subvol=@ "${disk}p${root_part_num}" /mnt
    mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
    mount -o noatime,compress=zstd,subvol=@home "${disk}p${root_part_num}" /mnt/home
    mount -o noatime,compress=zstd,subvol=@pkg "${disk}p${root_part_num}" /mnt/var/cache/pacman/pkg
    mount -o noatime,compress=zstd,subvol=@log "${disk}p${root_part_num}" /mnt/var/log
    mount -o noatime,compress=zstd,subvol=@snapshots "${disk}p${root_part_num}" /mnt/.snapshots
    mount "${disk}p${efi_part_num}" /mnt/boot

    info "Installing base packages..."
    pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs git --parallel=8

    genfstab -U /mnt >> /mnt/etc/fstab
}

# --- Configuration ---
configure_system() {
    info "Configuring the system..."
    arch-chroot /mnt /bin/bash -c "
        ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
        hwclock --systohc
        echo '$language UTF-8' > /etc/locale.gen
        locale-gen
        echo 'LANG=$language' > /etc/locale.conf
        echo 'KEYMAP=$locale' > /etc/vconsole.conf
        echo 'archlinux' > /etc/hostname
        {
            echo '127.0.0.1   localhost'
            echo '::1         localhost'
            echo '127.0.1.1   archlinux.localdomain archlinux'
        } >> /etc/hosts
        echo 'root:$password' | chpasswd
        useradd -m -G wheel -s /bin/bash $username
        echo '$username:$password' | chpasswd
        echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers

        # Install additional packages
        pacman -S --noconfirm limine snapper
        
        # Configure Limine
        limine-install
        
        # Configure Snapper
        snapper -c root create-config /
        btrfs subvolume delete /.snapshots
        mkdir /.snapshots
        mount -a
        chmod 750 /.snapshots

        # Install GPU and CPU specific packages
        if lspci | grep -i 'nvidia'; then
            pacman -S --noconfirm nvidia nvidia-utils linux-headers
        fi
        if lscpu | grep -i 'intel'; then
            pacman -S --noconfirm intel-ucode
        fi

        # Enable services
        systemctl enable NetworkManager
        systemctl enable bluetooth
        systemctl enable snapper-timeline.timer
        systemctl enable snapper-cleanup.timer
    "
}

# --- Main Function ---
main() {
    start_time=$(date +%s)
    check_root
    check_dialog
    get_user_info
    setup_system
    partition_disk
    install_base_system
    configure_system
    end_time=$(date +%s)
    installation_time=$((end_time - start_time))

    dialog --yesno "Installation finished in $installation_time seconds. Do you want to chroot into the new system? (If you say no, the system will reboot)" 10 60
    if [ $? -eq 0 ]; then
        arch-chroot /mnt
    else
        reboot
    fi
}

main