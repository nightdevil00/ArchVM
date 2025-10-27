#!/bin/bash

# Abort on error
set -e

# Ensure we're running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# List all available disks and assign numbers to them
echo "Available disks on this system:"

# Use lsblk to list disks with their size and model
disks=($(lsblk -d -o NAME,SIZE,MODEL | grep -E '^\S' | awk '{print $1}'))
disk_models=($(lsblk -d -o NAME,SIZE,MODEL | grep -E '^\S' | awk '{print $3}'))
disk_sizes=($(lsblk -d -o NAME,SIZE,MODEL | grep -E '^\S' | awk '{print $2}'))

# Display the disks with numbers
counter=1
for i in "${!disks[@]}"; do
    echo "$counter. ${disk_models[$i]} ${disk_sizes[$i]}"
    counter=$((counter + 1))
done

# Ask the user to select the disk by number
echo "Enter the number of the disk for Arch installation (e.g., 1, 2, etc.):"
read -r disk_number

# Validate the selection
if ! [[ "$disk_number" =~ ^[0-9]+$ ]] || [ "$disk_number" -le 0 ] || [ "$disk_number" -gt "${#disks[@]}" ]; then
    echo "Invalid selection. Exiting."
    exit 1
fi

# Get the selected disk name
selected_disk="${disks[$disk_number-1]}"

# Verify the selected disk exists
if [[ ! -b "/dev/$selected_disk" ]]; then
    echo "Error: Disk /dev/$selected_disk not found. Exiting."
    exit 1
fi

# Display the selected disk information
echo "You selected: /dev/$selected_disk"
lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "/dev/$selected_disk"

# Scan the selected disk for existing Windows partitions (EFI and NTFS)
echo "Scanning /dev/$selected_disk for Windows partitions..."
windows_partition=""
windows_efi_partition=""

# Search for Windows partitions (NTFS and EFI)
for part in $(lsblk -o NAME,FSTYPE,MOUNTPOINT "/dev/$selected_disk" | grep -E "ntfs|vfat" | awk '{print $1}'); do
    fs_type=$(lsblk -f /dev/$part | awk 'NR==2 {print $2}')
    
    if [[ "$fs_type" == "ntfs" ]]; then
        windows_partition="/dev/$part"
        echo "Windows NTFS partition found: $windows_partition"
    elif [[ "$fs_type" == "vfat" ]]; then
        windows_efi_partition="/dev/$part"
        echo "Windows EFI partition found: $windows_efi_partition"
    fi
done

# If no Windows partitions are found, ask if user wants to install on the full disk
if [[ -z "$windows_partition" || -z "$windows_efi_partition" ]]; then
    echo "No Windows partitions (NTFS and EFI) found on /dev/$selected_disk."
    echo "Would you like to install Arch on the full disk and erase all existing data? (y/n):"
    read -r choice
    if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
        echo "Exiting installation."
        exit 1
    fi

    echo "Proceeding with full disk installation."
    # Create new GPT partition table and partitions for Arch
    (
        echo "g"  # Create new GPT partition table
        echo "n"  # New partition for Arch EFI
        echo ""   # Default partition number
        echo ""   # Default first sector
        echo "+2G"  # Size of the Arch EFI partition (2GB)
        echo "n"  # New partition for Arch root
        echo ""   # Default partition number
        echo ""   # Default first sector
        echo ""   # Use remaining space for root partition
        echo "w"  # Write partition table
    ) | fdisk "/dev/$selected_disk"

    # Inform user of partition changes
    lsblk -f

    # Assign the partitions
    efi_partition="/dev/${selected_disk}1"  # Adjust as needed
    root_partition="/dev/${selected_disk}2"  # Adjust as needed

else
    # If Windows partitions are found, proceed with dual-boot setup
    # Confirm with user that Windows partitions will not be touched
    echo "Windows NTFS partition: $windows_partition"
    echo "Windows EFI partition: $windows_efi_partition"
    echo "These partitions will NOT be touched by the Arch installation script."

    # List available free space to partition
    echo "Checking available free space on /dev/$selected_disk..."
    free_space=$(lsblk -o NAME,SIZE | grep "$selected_disk" | grep -E "free" | awk '{print $2}')
    echo "Free space available: $free_space"

    # Ask user to select the free space for creating Arch partitions
    echo "Enter the size for the new Arch EFI partition (e.g., 2GB):"
    read -r efi_size
    echo "Enter the size for the Arch root partition (e.g., 30GB):"
    read -r root_size

    # Partitioning the disk
    echo "Creating partitions..."
    (
        echo "g"  # Create new GPT partition table
        echo "n"  # New partition for Arch EFI
        echo ""   # Default partition number
        echo ""   # Default first sector
        echo "+${efi_size}"  # Size of the Arch EFI partition (e.g., 2GB)
        echo "n"  # New partition for Arch root
        echo ""   # Default partition number
        echo ""   # Default first sector
        echo "+${root_size}"  # Size of the root partition (e.g., 30GB)
        echo "w"  # Write partition table
    ) | fdisk "/dev/$selected_disk"

    # Inform user of partition changes
    lsblk -f

    # Find the newly created partitions for EFI and root
    efi_partition="/dev/${selected_disk}1"  # Adjust as needed
    root_partition="/dev/${selected_disk}2"  # Adjust as needed
fi

# Ensure the EFI partition is formatted as FAT32
echo "Formatting EFI partition ($efi_partition) as FAT32..."
mkfs.fat -F32 "$efi_partition"

# Encrypt the root partition with LUKS2
echo "Encrypting root partition ($root_partition)..."
echo -n "Enter password for LUKS encryption (for both root and home partitions): "
read -rs LUKS_PASSWORD
echo

# Make sure the partition exists and format it
cryptsetup luksFormat "$root_partition"
cryptsetup luksOpen "$root_partition" cryptroot

# Create filesystem on the encrypted partition
echo "Creating Btrfs filesystem on root partition..."
mkfs.btrfs /dev/mapper/cryptroot

# Mount root filesystem and create subvolumes
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

# Mount root subvolume
mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir /mnt/home
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home

# Mount EFI partition for Arch (2GB EFI partition)
mkdir /mnt/boot
mount "$efi_partition" /mnt/boot

# Install the base system (packages will now be installed via pacstrap)
pacstrap /mnt base linux linux-firmware linux-headers vim nano sudo grub efibootmgr btrfs-progs kitty os-prober

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Get UUID of the encrypted partition
ROOT_UUID=$(blkid -s UUID -o value "$root_partition")
echo "$ROOT_UUID" > /mnt/root_uuid

# Chroot into new system
arch-chroot /mnt /bin/bash <<EOF

# Read ROOT_UUID from file
ROOT_UUID=\$(cat /root_uuid)

# Set timezone and locale
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set hostname
echo "arch-linux" > /etc/hostname

# Set root password
echo "Set root password"
passwd

# Create a new user
echo "Enter new username: "
read -r username
useradd -m -G wheel "\$username"
echo "Enter password for user \$username: "
passwd "\$username"

# Add user to sudoers file
echo "\$username ALL=(ALL) ALL" >> /etc/sudoers

# Configure crypttab
echo "cryptroot UUID=\$ROOT_UUID none luks,discard" > /etc/crypttab

# Configure mkinitcpio for LUKS and btrfs
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf

# Regenerate initramfs
mkinitcpio -P

# Install GRUB and configure bootloader
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Add Windows to GRUB if detected
echo "Adding Windows to GRUB bootloader..."
os-prober
grub-mkconfig -o /boot/grub/grub.cfg

# Enable necessary services
#systemctl enable NetworkManager

# Remove temporary file
rm /root_uuid

EOF

# Final Instructions
echo "Arch Linux installation complete. You should now reboot. Ensure your UEFI settings are correct for dual-booting."
echo "Windows should appear in the GRUB bootloader if it's installed."
