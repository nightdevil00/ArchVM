#!/bin/bash

# Abort on error
set -e

# Ensure we're running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Install necessary dependencies
pacman -Syu --noconfirm
pacman -S --noconfirm \
    btrfs-progs \
    cryptsetup \
    grub \
    efibootmgr \
    linux \
    linux-firmware \
    linux-headers \
    nvidia-open-dkms \
    gedit \
    nano \
    sudo \
    vim \
    kitty \
    base-devel

# Variables
LUKS_PASSWORD=""

# List all available disks and partitions
echo "Available disks on this system:"
lsblk -d -o NAME,SIZE,MODEL

# Prompt the user to select a disk for Arch installation
echo "Enter the disk for Arch installation (e.g., /dev/sda):"
read -r disk

# Verify the selected disk exists
if [[ ! -b "$disk" ]]; then
    echo "Error: Disk $disk not found. Exiting."
    exit 1
fi

# Scan the selected disk for existing Windows partitions (EFI and NTFS)
echo "Scanning $disk for Windows partitions..."
windows_partition=""
windows_efi_partition=""

# Search for Windows partitions (NTFS and EFI)
for part in $(lsblk -o NAME,FSTYPE,MOUNTPOINT "$disk" | grep -E "ntfs|vfat" | awk '{print $1}'); do
    fs_type=$(lsblk -f /dev/$part | awk 'NR==2 {print $2}')
    
    if [[ "$fs_type" == "ntfs" ]]; then
        windows_partition="/dev/$part"
        echo "Windows NTFS partition found: $windows_partition"
    elif [[ "$fs_type" == "vfat" ]]; then
        windows_efi_partition="/dev/$part"
        echo "Windows EFI partition found: $windows_efi_partition"
    fi
done

# Ensure Windows partitions were found
if [[ -z "$windows_partition" || -z "$windows_efi_partition" ]]; then
    echo "Error: Could not find both Windows NTFS and EFI partitions on $disk."
    exit 1
fi

# Confirm with user that Windows partitions will not be touched
echo "Windows NTFS partition: $windows_partition"
echo "Windows EFI partition: $windows_efi_partition"
echo "These partitions will NOT be touched by the Arch installation script."

# List available free space to partition
echo "Checking available free space on $disk..."
free_space=$(lsblk -o NAME,SIZE | grep "$disk" | grep -E "free" | awk '{print $2}')
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
) | fdisk "$disk"

# Inform user of partition changes
lsblk -f

# Find the newly created partitions for EFI and root
efi_partition="${disk}1"  # Adjust as needed
root_partition="${disk}2"  # Adjust as needed

# Encrypt the root partition with LUKS2
echo "Encrypting root partition..."
echo -n "Enter password for LUKS encryption (for both root and home partitions): "
read -rs LUKS_PASSWORD
echo

cryptsetup luksFormat "$root_partition"  # Root partition
cryptsetup luksOpen "$root_partition" cryptroot

# Create filesystems
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

# Install the base system
pacstrap /mnt base linux linux-firmware linux-headers nvidia-open-dkms vim nano sudo grub efibootmgr btrfs-progs

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into new system
arch-chroot /mnt /bin/bash <<'EOF'

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
useradd -m -G wheel "$username"
echo "Enter password for user $username: "
passwd "$username"

# Add user to sudoers file
echo "$username ALL=(ALL) ALL" >> /etc/sudoers

# Install GRUB and configure bootloader
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Add Windows to GRUB if detected
echo "Adding Windows to GRUB bootloader..."
os-prober
grub-mkconfig -o /boot/grub/grub.cfg

# Enable necessary services
systemctl enable NetworkManager

# Set up LUKS password for unlocking at boot
echo -n "$LUKS_PASSWORD" > /etc/crypttab

# Exit chroot
EOF

# Final Instructions
echo "Arch Linux installation complete. You should now reboot. Ensure your UEFI settings are correct for dual-booting."
echo "Windows should appear in the GRUB bootloader if it's installed."

