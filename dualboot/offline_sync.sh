#!/bin/bash

# --- 0. Safety Cleanup ---
umount -R /mnt &>/dev/null
cryptsetup luksClose cryptroot &>/dev/null || true
swapoff -a &>/dev/null || true

TMP_MOUNT="/mnt/__arch_install_tmp"
mkdir -p "$TMP_MOUNT"

# --- 1. Checks ---
if [[ $EUID -ne 0 ]]; then
   gum style --foreground "#f38ba8" "ERROR: Run with sudo!"
   exit 1
fi

echo ":: Checking internet..."
if ! ping -c 1 8.8.8.8 &>/dev/null; then
   gum style --foreground "#f38ba8" "ERROR: Internet required."
   exit 1
fi

figlet -f smslant "ML4W OS Install"
echo ":: This script will install ArchLinux to your hard drive."
echo

# --- 2. Setup ---
TEST_MODE=false
[[ "$1" == "--test" ]] && TEST_MODE=true
IS_EFI=false
[[ -d "/sys/firmware/efi" ]] && IS_EFI=true

# --- Windows Detection ---
declare -a PROTECTED_PART_KEYS=()
declare -a PROTECTED_PART_VALUES=()
WINDOWS_EFI_PART=""

while IFS= read -r line; do
  eval "$line"
  if [[ "${TYPE:-}" != "part" ]]; then
    continue
  fi
  PART="/dev/${NAME}"
  if [[ "$PART" =~ loop|sr|md ]]; then
    continue
  fi

  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)

  if [[ "$FSTYPE" == "vfat" || "$FSTYPE" == "fat32" || "$FSTYPE" == "fat" ]]; then
    mkdir -p "$TMP_MOUNT"
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/EFI/Microsoft" ]] || [[ -f "$TMP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
        PROTECTED_PART_KEYS+=("$PART")
        PROTECTED_PART_VALUES+=("EFI Microsoft files found")
        WINDOWS_EFI_PART="$PART"
        echo "Protected (EFI): $PART -> EFI Microsoft files found"
      fi
      umount "$TMP_MOUNT" || true
    fi
  fi

  if [[ "$FSTYPE" == "ntfs" ]]; then
    mkdir -p "$TMP_MOUNT"
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/Windows" ]] || [[ -f "$TMP_MOUNT/bootmgr" ]]; then
        PROTECTED_PART_KEYS+=("$PART")
        PROTECTED_PART_VALUES+=("NTFS Windows files found")
        echo "Protected (NTFS): $PART -> NTFS Windows files found"
      fi
      umount "$TMP_MOUNT" || true
    fi
  fi
done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINT)

# 3. Drive Selection
TARGET_DRIVE=$(lsblk -dpno NAME,SIZE | gum choose --header "Select Drive" | awk '{print $1}')
[ -z "$TARGET_DRIVE" ] && exit 1
if [[ $TARGET_DRIVE =~ [0-9]$ ]]; then P="p"; else P=""; fi

# Determine partition scheme based on Windows detection
if [ ${#PROTECTED_PART_KEYS[@]} -gt 0 ]; then
  echo
  echo "Windows detected! Using free space for Arch installation."
  echo "Partition table + free space:"
  parted --script "$TARGET_DRIVE" unit GB print free || true
  
  echo
  echo "Enter partition sizes within free space:"
  read -rp "EFI start (e.g. 1GB): " EFI_START
  read -rp "EFI end (e.g. 3GB): " EFI_END
  read -rp "Root start (e.g. 3GB): " ROOT_START
  read -rp "Root end (e.g. 60GB or 100%): " ROOT_END
  
  DUALBOOT=true
else
  DUALBOOT=false
fi

# 4. Input Validation
ROOT_PASS=""
while [[ -z "$ROOT_PASS" ]]; do ROOT_PASS=$(gum input --password --placeholder "Root Password"); done
NEW_USER=""
while [[ -z "$NEW_USER" ]]; do NEW_USER=$(gum input --placeholder "Username"); done
NEW_PASS=""
while [[ -z "$NEW_PASS" ]]; do NEW_PASS=$(gum input --password --placeholder "User Password"); done
TIMEZONE=$(timedatectl list-timezones | gum filter --placeholder "Select Timezone")
[ -z "$TIMEZONE" ] && TIMEZONE="UTC"
NEW_HOSTNAME=""
while [[ -z "$NEW_HOSTNAME" ]]; do NEW_HOSTNAME=$(gum input --placeholder "Hostname"); done

# --- Installation Method ---
echo
INSTALL_METHOD=$(echo -e "online\noffline" | gum choose --header "Select Installation Method" --selected=online)
echo "Selected: $INSTALL_METHOD"

# 5. Summary
clear
figlet -f smslant "Summary"
echo "  User:         $NEW_USER"
echo "  Timezone:     $TIMEZONE"
echo "  Hostname:     $NEW_HOSTNAME"
echo "  Drive:        $TARGET_DRIVE"
echo "  Boot Mode:    $([ "$IS_EFI" = true ] && echo "UEFI" || echo "BIOS")"
echo "  Dualboot:     $([ "$DUALBOOT" = true ] && echo "Yes (Windows)" || echo "No")"
echo "  Install:      $INSTALL_METHOD"
echo ""
gum confirm "WARNING: This will modify $TARGET_DRIVE. Continue?" || exit 1

set -e 
# --- EXECUTION ---

echo 
echo ":: Step 1: Partitioning..."
echo
if [ "$TEST_MODE" = false ]; then
    if [ "$DUALBOOT" = true ]; then
        parted --script "$TARGET_DRIVE" mkpart primary fat32 "$EFI_START" "$EFI_END"
        parted --script "$TARGET_DRIVE" set $(parted -s "$TARGET_DRIVE" print | awk '/fat32/{print $1}' | tail -n1) esp on || true
        parted --script "$TARGET_DRIVE" mkpart primary btrfs "$ROOT_START" "$ROOT_END"
        partprobe "$TARGET_DRIVE"
        
        sleep 1
        parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DRIVE" | awk '$2=="part"{print "/dev/"$1}'))
        EFI_PART="${parts[-2]}"
        ROOT_PART="${parts[-1]}"
    else
        sgdisk -Z $TARGET_DRIVE
        if [ "$IS_EFI" = true ]; then
            sgdisk -n 1:0:+512M -t 1:ef00 $TARGET_DRIVE
        else
            sgdisk -n 1:0:+1M -t 1:ef02 $TARGET_DRIVE
        fi
        sgdisk -n 2:0:0 -t 2:8300 $TARGET_DRIVE
        partprobe $TARGET_DRIVE
        sleep 2
        EFI_PART="${TARGET_DRIVE}${P}1"
        ROOT_PART="${TARGET_DRIVE}${P}2"
    fi
fi

echo
echo ":: Step 2: Formatting..."
echo
if [ "$TEST_MODE" = false ]; then
    if [ "$IS_EFI" = true ]; then mkfs.vfat -F 32 "$EFI_PART"; fi
    mkfs.btrfs -L ARCH_ROOT -f "$ROOT_PART"
fi

echo
echo ":: Step 3: Btrfs Subvolumes..."
echo
if [ "$TEST_MODE" = false ]; then

    echo ":: Mounting root temporarily to create subvolumes..."
    mount "$ROOT_PART" /mnt
    
    echo ":: Creating subvolumes..."
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@pkg
    btrfs subvolume create /mnt/@.snapshots

    echo ":: Unmounting to remount with correct options..."
    umount /mnt
    
    echo ":: Mounting root..."
    mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt

    echo ":: Creating directories..."
    mkdir -p /mnt/home
    mkdir -p /mnt/var/log
    mkdir -p /mnt/var/cache/pacman/pkg
    mkdir -p /mnt/.snapshots
    mkdir -p /mnt/boot

    echo ":: Mounting subvolumes..."
    mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
    mount -o noatime,compress=zstd,subvol=@log "$ROOT_PART" /mnt/var/log
    mount -o noatime,compress=zstd,subvol=@pkg "$ROOT_PART" /mnt/var/cache/pacman/pkg
    mount -o noatime,compress=zstd,subvol=@.snapshots "$ROOT_PART" /mnt/.snapshots

    if [ "$IS_EFI" = true ]; then 
        echo ":: Mounting EFI..."
        mount "$EFI_PART" /mnt/boot; 
    fi
fi

echo
echo ":: Step 4: Install System ($INSTALL_METHOD)..."
echo
if [ "$TEST_MODE" = false ]; then
    if [ "$INSTALL_METHOD" = "online" ]; then
        echo ":: Installing fresh system with pacstrap..."
        pacstrap /mnt base base-devel linux linux-firmware btrfs-progs limine \
            "$( [ "$IS_EFI" = true ] && echo "efibootmgr" )" \
            "$( [ "$IS_EFI" = true ] && echo "efitools" )" \
            networkmanager iwd sddm sudo vim git curl wget \
            "$( [ "$IS_EFI" = false ] && echo "grub" )"
    else
        echo ":: Cloning current system with rsync..."
        rsync -aAXhW --numeric-ids --info=progress2 \
            --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} \
            --exclude="/var/cache/pacman/pkg/*" \
            --exclude="/var/log/*" \
            --exclude="/etc/pacman.d/gnupg/*" \
            / /mnt/
    fi
fi

echo
echo ":: Step 5: Configuration (Chroot)..."
echo
if [ "$TEST_MODE" = false ]; then
    genfstab -U /mnt >> /mnt/etc/fstab
    cp --remove-destination /etc/resolv.conf /mnt/etc/resolv.conf

    echo ":: Waiting for UUID..."
    partprobe $TARGET_DRIVE
    udevadm settle
    sleep 2
    ROOT_UUID=$(lsblk -no UUID $ROOT_PART)
    if [ -z "$ROOT_UUID" ]; then sleep 3; ROOT_UUID=$(blkid -s UUID -o value $ROOT_PART); fi
    if [ -z "$ROOT_UUID" ]; then echo "ERROR: No UUID found."; exit 1; fi

    # Save variables for chroot
    cat > /mnt/arch_install_vars.sh <<EOF
ROOT_PART="$ROOT_PART"
EFI_PART="$EFI_PART"
TARGET_DRIVE="$TARGET_DRIVE"
ROOT_UUID="$ROOT_UUID"
NEW_HOSTNAME="$NEW_HOSTNAME"
TIMEZONE="$TIMEZONE"
ROOT_PASS="$ROOT_PASS"
NEW_USER="$NEW_USER"
NEW_PASS="$NEW_PASS"
INSTALL_METHOD="$INSTALL_METHOD"
IS_EFI="$IS_EFI"
WINDOWS_EFI_PART="$WINDOWS_EFI_PART"
EOF

    arch-chroot /mnt /bin/bash <<'CHROOTEOF'
    set -e
    
    source /arch_install_vars.sh
    
    if [ "$INSTALL_METHOD" = "online" ]; then
        echo ":: Online install: Generating mkinitcpio..."
        rm -rf /etc/mkinitcpio.conf.d
        rm -f /etc/mkinitcpio.d/*.preset
        rm -f /boot/vmlinuz* /boot/initramfs*
        
        echo "MODULES=(btrfs)" > /etc/mkinitcpio.conf
        echo "BINARIES=()" >> /etc/mkinitcpio.conf
        echo "FILES=()" >> /etc/mkinitcpio.conf
        echo "HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)" >> /etc/mkinitcpio.conf
        mkinitcpio -P
    else
        pacman-key --init
        pacman-key --populate archlinux
        
        echo ":: Cleaning boot config..."
        pacman -Rns --noconfirm archiso || true
        rm -rf /etc/mkinitcpio.conf.d
        rm -f /etc/mkinitcpio.d/*.preset
        rm -f /boot/vmlinuz* /boot/initramfs*
        
        echo "MODULES=(btrfs)" > /etc/mkinitcpio.conf
        echo "BINARIES=()" >> /etc/mkinitcpio.conf
        echo "FILES=()" >> /etc/mkinitcpio.conf
        echo "HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)" >> /etc/mkinitcpio.conf
        
        rm -f /etc/sudoers.d/g_wheel
        rm -f /etc/sudoers.d/01_archiso
        
        echo ":: Installing Linux Packages..."
        pacman -Sy --noconfirm linux linux-firmware btrfs-progs limine $([ "$IS_EFI" = true ] && echo "efibootmgr")
        mkinitcpio -P
    fi
    
    echo ":: Installing Limine..."
    mkdir -p /boot/EFI/limine
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
    cp /usr/share/limine/BOOTIA32.EFI /boot/EFI/limine/
    
    mkdir -p /boot/EFI/BOOT
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
    
    if [ "$IS_EFI" = true ]; then
        EFI_PART_NUM=$(cat "/sys/class/block/$(basename "$EFI_PART")/partition")
        efibootmgr --create --disk "$TARGET_DRIVE" --part "$EFI_PART_NUM" \
          --label "Arch Linux (Limine)" \
          --loader '\\EFI\\limine\\BOOTX64.EFI' --unicode || true
    fi

    cat > /boot/limine.conf <<LIMINECONF
TIMEOUT=5
DEFAULT_ENTRY=1

:Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    INITRD_PATH=boot:///initramfs-linux.img
    CMDLINE=root=UUID=$ROOT_UUID rw rootflags=subvol=@ rootfstype=btrfs quiet

:Arch Linux (fallback)
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    INITRD_PATH=boot:///initramfs-linux-fallback.img
    CMDLINE=root=UUID=$ROOT_UUID rw rootflags=subvol=@ rootfstype=btrfs quiet
LIMINECONF

    if [[ -n "$WINDOWS_EFI_PART" ]]; then
        WINDOWS_EFI_UUID=$(blkid -s UUID -o value "$WINDOWS_EFI_PART")
        cat >> /boot/limine.conf <<LIMINEWIN

:Windows
    PROTOCOL=chainload
    DRIVE=uuid:$WINDOWS_EFI_UUID
    PATH=\\EFI\\Microsoft\\Boot\\bootmgfw.efi
LIMINEWIN
    fi

    cp /boot/limine.conf /boot/EFI/limine/limine.conf
    
    echo "Setting Hostname..."
    echo "$NEW_HOSTNAME" > /etc/hostname

    echo "Setting Timezone to $TIMEZONE..."
    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    hwclock --systohc

    echo "Setting password for root..."
    echo "root:$ROOT_PASS" | chpasswd

    echo "Adding new user '$NEW_USER'..."
    useradd -m -G wheel -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$NEW_PASS" | chpasswd
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

    echo "Enabling NetworkManager..."    
    systemctl enable NetworkManager

    echo "Enabling sddm..."    
    systemctl enable sddm
    
    rm -f /arch_install_vars.sh
CHROOTEOF
    umount -R /mnt
fi

rm -rf "$TMP_MOUNT"

echo
figlet -f smslant "Done!"
echo ":: Installation Complete. Reboot and enjoy Archlinux OS!"
echo
if gum confirm "Do you want to reboot your system now?"; then
    reboot
fi
