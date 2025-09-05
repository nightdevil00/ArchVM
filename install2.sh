#!/bin/bash

# Arch Linux Installation Script


# --- Logging ---
log_file="/root/arch_install_$(date +%Y-%m-%d_%H-%M-%S).log"
exec &> >(tee -a "$log_file")

log_failure() {
    error "Script failed. Log saved to $log_file"
}

trap log_failure ERR

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
    elif [[ $size == *"MB" ]]; then
        echo ${size//MB/}
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



# --- User Input ---
get_user_info() {
    read -p "Enter your desired username: " username

    while true; do
        read -s -p "Enter your password: " password
        echo
        read -s -p "Confirm your password: " password_confirm
        echo
        if [ "$password" == "$password_confirm" ]; then
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done

    read -p "Enter your desired locale (e.g., us) [us]: " locale
    locale=${locale:-us}
    read -p "Enter your desired system language (e.g., en_US.UTF-8) [en_US.UTF-8]: " language
    language=${language:-en_US.UTF-8}
}

# --- System Setup ---
setup_system() {
    info "Setting up the system..."
    timedatectl set-ntp true

    info "Initializing pacman keys..."
    pacman-key --init
    pacman-key --populate archlinux

    info "Updating mirrorlist..."
    reflector --verbose --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

    info "Determining timezone..."
    timezone=$(curl -s ipinfo.io/timezone)
    read -p "Your timezone is detected as $timezone. Is this correct? (y/N) " confirm_tz
    if [[ ! "$confirm_tz" =~ ^[yY]$ ]]; then
        read -p "Please enter your timezone (e.g., Europe/Bucharest): " timezone
    fi
    timedatectl set-timezone "$timezone"
}

# --- Disk Partitioning ---
partition_disk() {
    info "Partitioning the disk..."
    devices=()
    while read -r name size model; do
        if [[ $name =~ ^(sd|nvme|vd|mmcblk) ]]; then
            devices+=("/dev/$name" "$size $model")
        fi
    done < <(lsblk -d -n -o NAME,SIZE,MODEL)

    if [ ${#devices[@]} -eq 0 ]; then
        error "No disks found."
    fi

    echo "Available disks:"
    i=0
    for ((i=0; i<${#devices[@]}; i+=2)); do
        echo "$((i/2+1))) ${devices[i]} (${devices[i+1]})"
    done
    
    read -p "Select a disk for installation (1, 2, ...): " disk_num
    disk_index=$(( (disk_num-1)*2 ))
    if [ -z "${devices[$disk_index]}" ]; then
        error "Invalid disk selection."
    fi
    disk=${devices[$disk_index]}


    if [ -z "$disk" ]; then
        error "No disk selected. Installation aborted."
    fi

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
        read -p "Windows installation detected on $disk. Do you want to format the entire disk? (WARNING: THIS WILL DELETE WINDOWS) (y/N) " format_disk
        if [[ "$format_disk" =~ ^[yY]$ ]]; then
            # Format entire disk
            info "Wiping all signatures from $disk..."
            wipefs -a "$disk"

            read -p "Enter the size for the EFI partition (e.g., 2200M) [2200M]: " efi_size
            efi_size=${efi_size:-2200M}
            read -p "Enter the size for the ROOT partition (e.g., 30G) [30G]: " root_size
            root_size=${root_size:-30G}

            info "Partitioning $disk..."
            parted -s "$disk" mklabel gpt
            parted -s "$disk" mkpart ESP fat32 1MiB "$efi_size"
            parted -s "$disk" set 1 esp on
            parted -s "$disk" mkpart primary btrfs "$efi_size" 100%
        else
            # Install in free space
            free_space_info=$(parted -s --unit=MB "$disk" print free | grep "Free Space" | tail -n 1)
            if [ -z "$free_space_info" ]; then
                error "No free space found on $disk. Installation aborted."
            fi

            free_space_start=$(echo "$free_space_info" | awk '{print $1}' | sed 's/MB//')
            free_space_end=$(echo "$free_space_info" | awk '{print $2}' | sed 's/MB//')
            free_space_size_mb=$(echo "$free_space_info" | awk '{print $3}' | sed 's/MB//')

            read -p "Found ${free_space_size_mb}MB of free space starting at ${free_space_start}MB. Do you want to install Arch Linux in this space? (y/N) " install_in_free
            if [[ ! "$install_in_free" =~ ^[yY]$ ]]; then
                error "Installation aborted by user."
            fi

            read -p "Enter the size for the EFI partition (e.g., 2200M) [2200M]: " efi_size
            efi_size=${efi_size:-2200M}
            read -p "Enter the size for the ROOT partition (e.g., 30G) [30G]: " root_size
            root_size=${root_size:-30G}

            efi_size_mb=$(size_to_mb "$efi_size")
            root_size_mb=$(size_to_mb "$root_size")

            if [ $(($efi_size_mb + $root_size_mb)) -gt $free_space_size_mb ]; then
                error "Not enough free space for the requested partition sizes. Installation aborted."
            fi

            efi_part_end=$(awk -v efi_size="$efi_size_mb" 'BEGIN {print $1 + efi_size}')
            root_part_end=$(awk -v root_size="$root_size_mb" 'BEGIN {print $1 + root_size}')

            info "Creating partitions in free space..."
            parted -s "$disk" mkpart ESP fat32 "${free_space_start}MB" "${efi_part_end}MB"
            parted -s "$disk" set 1 esp on
            parted -s "$disk" mkpart primary btrfs "${efi_part_end}MB" "${root_part_end}MB"
        fi
    else
        # No Windows detected, format the entire disk
        read -p "This will format the entire disk $disk. All data will be lost. Are you sure? (y/N) " confirm_format
        if [[ ! "$confirm_format" =~ ^[yY]$ ]]; then
            error "Installation aborted by user."
        fi

        info "Wiping all signatures from $disk..."
        wipefs -a "$disk"

        read -p "Enter the size for the EFI partition (e.g., 2200M) [2200M]: " efi_size
        efi_size=${efi_size:-2200M}
        read -p "Enter the size for the ROOT partition (e.g., 30G) [30G]: " root_size
        root_size=${root_size:-30G}

        info "Partitioning $disk..."
        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart ESP fat32 1MiB "$efi_size"
        parted -s "$disk" set 1 esp on
        parted -s "$disk" mkpart primary btrfs "$efi_size" 100%
    fi

    info "Informing the OS about the new partition table..."
    partprobe "$disk"
    blockdev --rereadpt "$disk"
    sleep 2
}


# --- Installation ---
install_base_system() {
    info "Installing the base system..."
    # Find the partition numbers
   # Ensure kernel sees new partitions
   partprobe "$disk"
   sleep 2  # wait a moment

  # Determine partition names
   if [[ $disk == /dev/nvme* || $disk == /dev/mmcblk* ]]; then
        efi_part="${disk}p1"
        root_part="${disk}p2"
   else
        efi_part="${disk}1"
        root_part="${disk}2"
   fi

# Get root partition (last partition)
   root_part=$(lsblk -ln -o NAME,TYPE "$disk" | awk '$2=="part" {print "/dev/"$1}' | tail -n1)

   if [ ! -b "$efi_part" ]; then
    error "EFI partition $efi_part not found."
   fi
  if [ ! -b "$root_part" ]; then
    error "Root partition $root_part not found."
  fi

    info "Encrypting the root partition..."
    echo -n "$password" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --hash sha512 --key-size 512 --iter-time 10000 --use-urandom "$root_part" -
    echo -n "$password" | cryptsetup open "$root_part" cryptroot -

    info "Creating BTRFS filesystem on the encrypted partition..."
    mkfs.btrfs -f /dev/mapper/cryptroot
    mount /dev/mapper/cryptroot /mnt || error "Failed to mount cryptroot."

    info "Creating BTRFS subvolumes..."
    btrfs su cr /mnt/@
    btrfs su cr /mnt/@home
    btrfs su cr /mnt/@pkg
    btrfs su cr /mnt/@log
    btrfs su cr /mnt/@snapshots
    umount /mnt || error "Failed to unmount cryptroot."

    info "Mounting subvolumes..."
    mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt || error "Failed to mount @ subvolume."
    mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
    mount -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home || error "Failed to mount @home subvolume."
    mount -o noatime,compress=zstd,subvol=@pkg /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg || error "Failed to mount @pkg subvolume."
    mount -o noatime,compress=zstd,subvol=@log /dev/mapper/cryptroot /mnt/var/log || error "Failed to mount @log subvolume."
    mount -o noatime,compress=zstd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots || error "Failed to mount @snapshots subvolume."
    
    info "Mounting boot partition..."
    mkfs.fat -F32 "$efi_part"
    mount "$efi_part" /mnt/boot || error "Failed to mount boot partition."

    info "Installing base packages..."
    pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs git cryptsetup grub snapper networkmanager bluez-utils efibootmgr grub-btrfs

    genfstab -U /mnt >> /mnt/etc/fstab
}

# --- Configuration ---
configure_system() {
    info "Configuring the system..."

    if [ ! -f /mnt/bin/bash ]; then
        error "/mnt/bin/bash not found. pacstrap might have failed."
    fi

    root_part_uuid=$(blkid -s PARTUUID -o value "$root_part")

    info "Configuring mkinitcpio for encryption..."
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /mnt/etc/mkinitcpio.conf

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

        info \"Configuring GRUB...\"
        sed -i \"s/^GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"cryptdevice=PARTUUID=$root_part_uuid:cryptroot quiet splash\"/\" /etc/default/grub
        sed -i 's/#GRUB_ENABLE_CRYPTODISK/GRUB_ENABLE_CRYPTODISK/' /etc/default/grub

        info \"Regenerating initramfs...\"
        mkinitcpio -P
        
        info \"Installing GRUB...\"
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
        grub-mkconfig -o /boot/grub/grub.cfg
        
        # Configure Snapper
        snapper -c root create-config /
        snapper -c home create-config /home
        mount -a
        chmod 750 /.snapshots
        sed -i 's/^TIMELINE_CREATE=\"yes\"/TIMELINE_CREATE=\"no\"/' /etc/snapper/configs/{root,home}
        sed -i 's/^NUMBER_LIMIT=\"50\"/NUMBER_LIMIT=\"5\"/' /etc/snapper/configs/{root,home}
        sed -i 's/^NUMBER_LIMIT_IMPORTANT=\"10\"/NUMBER_LIMIT_IMPORTANT=\"5\"/' /etc/snapper/configs/{root,home}

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
        systemctl enable grub-btrfs.path

        # Add a helper to create a new snapshot
        tee /usr/local/bin/new-snapshot <<'EOF' >/dev/null
#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Check if a description is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <description>"
  exit 1
fi

# Create a new snapshot with the provided description
snapper -c root create --description "$1"
EOF

        chmod +x /usr/local/bin/new-snapshot
    "
}

# --- Main Function ---
main() {
    start_time=$(date +%s)
    check_root
    get_user_info
    setup_system
    partition_disk
    install_base_system
    configure_system
    end_time=$(date +%s)
    installation_time=$((end_time - start_time))

    read -p "Installation finished in $installation_time seconds. Do you want to chroot into the new system? (If you say no, the system will reboot) (y/N) " chroot_choice
    if [[ "$chroot_choice" =~ ^[yY]$ ]]; then
        arch-chroot /mnt
    else
        reboot
    fi
}

main
