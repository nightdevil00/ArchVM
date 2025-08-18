#!/usr/bin/env bash
set -euo pipefail

# Arch Dialog Installer – Btrfs/LUKS or ext4 (UEFI/BIOS)
# Features:
# - Pick install disk (SATA/NVMe/virtio)
# - Filesystem: Btrfs on LUKS (default) or plain ext4 (optionally separate /home)
# - Creates EFI partition automatically; BIOS installs supported
# - Auto-detect CPU microcode & basic GPU driver set
# - Minimal base with linux + linux-lts, git, NetworkManager
# - Locale, timezone, hostname, mirrors (reflector with GeoIP)
# - Bootloader: GRUB (UEFI/BIOS) or systemd-boot (UEFI only)
# - Chroot into installed system at the end if you want
#
# Run this from the official Arch ISO as root with networking enabled.
# pacman -Sy --needed dialog git arch-install-scripts btrfs-progs dosfstools e2fsprogs cryptsetup grub efibootmgr reflector curl
# bash arch-dialog-installer.sh

#-------------------------------
# Helpers
#-------------------------------
err() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

require() {
  local missing=()
  for bin in "$@"; do command -v "$bin" >/dev/null 2>&1 || missing+=("$bin"); done
  if (( ${#missing[@]} )); then
    echo "The following dependencies are missing: ${missing[*]}" >&2
    echo "Run: pacman -Sy --needed ${missing[*]}" >&2
    exit 1
  fi
}

#-------------------------------
# Check deps
#-------------------------------
require dialog parted lsblk pacstrap genfstab arch-chroot sed awk grep cut sort uniq curl reflector mkfs.vfat mkfs.ext4 mkswap swapon cryptsetup mkfs.btrfs grub-install grub-mkconfig efibootmgr timedatectl

[[ $EUID -eq 0 ]] || err "Run as root"

# Ensure NTP
systemctl -q is-active systemd-timesyncd || true
info "Enabling NTP..."
timedatectl set-ntp true || true

#-------------------------------
# Dialog wrappers
#-------------------------------
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

d_msg(){ dialog --colors --backtitle "Arch Installer" --title "$1" --msgbox "$2" 12 70; }

d_yesno(){ dialog --colors --backtitle "Arch Installer" --title "$1" --yesno "$2" 12 70; }

d_input(){ dialog --colors --backtitle "Arch Installer" --title "$1" --inputbox "$2" 10 70 "$3" 2>"$TMPD/ans" || return 1; cat "$TMPD/ans"; }

d_menu(){
  # args: title height width menuheight items... (tag item)
  local title="$1"; shift
  dialog --backtitle "Arch Installer" --title "$title" --menu "$title" "$@" 2>"$TMPD/ans" || return 1
  cat "$TMPD/ans"
}

d_checklist(){
  # returns selected tags separated by space
  local title="$1"; shift
  dialog --backtitle "Arch Installer" --title "$title" --checklist "$title" "$@" 2>"$TMPD/ans" || return 1
  tr -d '"' < "$TMPD/ans"
}

#-------------------------------
# Disk selection
#-------------------------------
mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|nvme|vd)" | awk '{print $1"|"$0}')
(( ${#DISKS[@]} )) || err "No installable disks found"

MENU_ITEMS=()
for line in "${DISKS[@]}"; do
  dev=${line%%|*}
  desc=${line#*|}
  MENU_ITEMS+=("$dev" "$desc")
done

DISK=$(d_menu "Select install disk" 20 78 12 "${MENU_ITEMS[@]}") || exit 1

d_yesno "Confirm" "*** ALL DATA on\n$DISK\nwill be ERASED. Continue?" || exit 1

# Detect firmware
if [[ -d /sys/firmware/efi/efivars ]]; then
  FIRMWARE=UEFI
else
  FIRMWARE=BIOS
fi

#-------------------------------
# FS choice
#-------------------------------
FS=$(d_menu "Filesystem" 12 60 5 \
  btrfs "Btrfs on LUKS (recommended)" \
  ext4  "Plain ext4 (optionally separate /home)"
) || exit 1

# Partition sizes
EFI_SIZE=$(d_input "EFI size" "Enter EFI partition size (e.g. 512M or 1G)" "512M") || exit 1

SEPARATE_HOME=no
HOME_SIZE=""

if [[ $FS == ext4 ]]; then
  if dialog --backtitle "Arch Installer" --title "/home" --yesno "Create a separate /home partition?" 10 60; then
    SEPARATE_HOME=yes
    HOME_SIZE=$(d_input "Home size" "Enter /home partition size (rest goes to /). Example: 100G" "") || exit 1
  fi
fi

#-------------------------------
# User, host, locale/time
#-------------------------------
HOSTNAME=$(d_input "Hostname" "Enter hostname" "archbox") || exit 1
USERNAME=$(d_input "User" "Enter username" "arch") || exit 1
USERPASS=$(d_input "Password" "Enter user password" "arch") || exit 1
ROOTPASS=$(d_input "Root password" "Enter root password" "root") || exit 1

# sudo policy
SUDO_MODE=$(d_menu "Sudo policy" 12 60 5 \
  pw "User in wheel, sudo with password" \
  nopw "User in wheel, passwordless sudo" \
  none "No sudo for user"
) || exit 1

# Timezone & locale
TZ_DEFAULT="Europe/Bucharest"
TZONE=$(d_input "Timezone" "Enter timezone (e.g. Europe/Bucharest)" "$TZ_DEFAULT") || exit 1

# Choose locales (checked are generated). Keep en_US.UTF-8 by default.
LOCALE_CHOICES=(
  en_US.UTF-8 "English (US)" on
  ro_RO.UTF-8 "Romanian" off
  en_GB.UTF-8 "English (UK)" off
)

dialog --backtitle "Arch Installer" --title "Locales" --checklist "Select locales to generate" 15 70 6 "${LOCALE_CHOICES[@]}" 2>"$TMPD/loc" || exit 1
LOCALES_RAW=$(cat "$TMPD/loc" | tr -d '"')
read -r -a LOCALES <<< "$LOCALES_RAW"
[[ ${#LOCALES[@]} -gt 0 ]] || LOCALES=(en_US.UTF-8)

#-------------------------------
# Partitioning
#-------------------------------
info "Partitioning $DISK ..."
parted -s "$DISK" mklabel gpt

START=1MiB
EFI_END=$EFI_SIZE

if [[ $FIRMWARE == BIOS ]]; then
  # BIOS boot partition for GRUB with GPT
  parted -s "$DISK" mkpart bios_boot $START 3MiB
  parted -s "$DISK" set 1 bios_grub on
  START=3MiB
fi

# EFI (even on BIOS we still create it for future UEFI boots)
if [[ $FIRMWARE == UEFI ]]; then
  parted -s "$DISK" mkpart EFI fat32 $START $EFI_END
  parted -s "$DISK" set 1 esp on
else
  parted -s "$DISK" mkpart EFI fat32 $START $EFI_END
fi

# Calculate next start
# Use parted to get end of last partition
NEXT_START=$(
  parted -sm "$DISK" unit MiB print | awk -F: '/^1:/{gsub("MiB","",$3); print $3+1"MiB"}'
)

if [[ $FS == btrfs ]]; then
  # Single root PV (encrypted)
  parted -s "$DISK" mkpart cryptroot $NEXT_START 100%
else
  # ext4 layout: / (and optional /home)
  if [[ $SEPARATE_HOME == yes && -n "$HOME_SIZE" ]]; then
    parted -s "$DISK" mkpart root $NEXT_START "-"$HOME_SIZE
    parted -s "$DISK" mkpart home "-"$HOME_SIZE 100%
  else
    parted -s "$DISK" mkpart root $NEXT_START 100%
  fi
fi

# Refresh kernel partition table
partprobe "$DISK"
sleep 2

# Identify partitions
if [[ $DISK == *nvme* ]]; then
  P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3"
else
  P1="${DISK}1"; P2="${DISK}2"; P3="${DISK}3"
fi

mkfs.vfat -F32 "$P1"

#-------------------------------
# Format and mount
#-------------------------------
if [[ $FS == btrfs ]]; then
  cryptsetup -y -v luksFormat "$P2"
  cryptsetup open "$P2" cryptroot
  mkfs.btrfs -f -L ROOT /dev/mapper/cryptroot
  
  # Create subvolumes
  mount /dev/mapper/cryptroot /mnt
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@home
  umount /mnt

  # Mount with options
  mount -o subvol=@,compress=zstd,noatime /dev/mapper/cryptroot /mnt
  mkdir -p /mnt/{boot,home}
  mount -o subvol=@home,compress=zstd,noatime /dev/mapper/cryptroot /mnt/home
  mount "$P1" /mnt/boot
else
  if [[ $SEPARATE_HOME == yes && -n "$HOME_SIZE" ]]; then
    mkfs.ext4 -F "$P2"
    mkfs.ext4 -F "$P3"
    mount "$P2" /mnt
    mkdir -p /mnt/boot /mnt/home
    mount "$P3" /mnt/home
  else
    mkfs.ext4 -F "$P2"
    mount "$P2" /mnt
    mkdir -p /mnt/boot
  fi
  mount "$P1" /mnt/boot
fi

#-------------------------------
# Mirrors (reflector)
#-------------------------------
info "Refreshing mirrors with reflector..."
COUNTRY=$(curl -fsSL https://ipapi.co/country_name || true)
if [[ -n ${COUNTRY:-} ]]; then
  reflector --protocol https --country "$COUNTRY" --latest 30 --sort rate --save /etc/pacman.d/mirrorlist || true
else
  reflector --protocol https --latest 30 --sort rate --save /etc/pacman.d/mirrorlist || true
fi

#-------------------------------
# Package selection
#-------------------------------
# CPU microcode
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2); print $2}')
MICROCODE=()
case "$CPU_VENDOR" in
  GenuineIntel) MICROCODE+=(intel-ucode) ;;
  AuthenticAMD)  MICROCODE+=(amd-ucode)  ;;
esac

# GPU drivers (basic)
GPUINFO=$(lspci | grep -E "VGA|3D|Display" || true)
GPU_PKGS=(mesa)
if echo "$GPUINFO" | grep -qi nvidia; then
  GPU_PKGS+=(nvidia nvidia-utils)
fi
# For AMD/Intel, mesa covers most; Vulkan extras optional

BASE_PKGS=(base linux linux-lts linux-firmware git networkmanager sudo nano vim \
           btrfs-progs dosfstools e2fsprogs cryptsetup grub efibootmgr reflector)

ALL_PKGS=("${BASE_PKGS[@]}" "${MICROCODE[@]}" "${GPU_PKGS[@]}")

info "Installing base system..."
pacstrap -K /mnt "${ALL_PKGS[@]}"

genfstab -U /mnt >> /mnt/etc/fstab

#-------------------------------
# System config in chroot
#-------------------------------
arch-chroot /mnt bash -euo pipefail <<CHROOT
set -euo pipefail

ln -sf /usr/share/zoneinfo/$TZONE /etc/localtime
hwclock --systohc || true

# locales
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
CHROOT
for loc in "${LOCALES[@]}"; do
  arch-chroot /mnt sed -i "s/^#\(${loc} UTF-8\)/\1/" /etc/locale.gen || true
done
arch-chroot /mnt locale-gen

# Set locale (first selected)
PRIMARY_LOCALE=${LOCALES[0]:-en_US.UTF-8}
echo "LANG=$PRIMARY_LOCALE" > /mnt/etc/locale.conf

echo "$HOSTNAME" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# mkinitcpio hooks
if [[ "$FS" == btrfs ]]; then
  arch-chroot /mnt sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems btrfs fsck)/' /etc/mkinitcpio.conf
else
  arch-chroot /mnt sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
fi
arch-chroot /mnt mkinitcpio -P

# Users & sudo
arch-chroot /mnt bash -euo pipefail <<EOS
set -e
usermod -p "*" root >/dev/null 2>&1 || true
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USERPASS" | chpasswd
(echo "$ROOTPASS"; echo "$ROOTPASS") | passwd root
case "$SUDO_MODE" in
  pw)
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    ;;
  nopw)
    echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99_wheel_nopw
    chmod 440 /etc/sudoers.d/99_wheel_nopw
    ;;
  none)
    :
    ;;
esac
systemctl enable NetworkManager
EOS

# Bootloader
if [[ "$FIRMWARE" == UEFI ]]; then
  # Prompt for bootloader
  BOOTSEL="$(cat <<EOM
GRUB GRUB (recommended, flexible)
sdboot systemd-boot (simple, UEFI only)
EOM
)"
  echo "\$BOOTSEL" > /mnt/tmp/boot.sel
  
  arch-chroot /mnt bash -euo pipefail <<'EOSB'
set -e
PS3="Select bootloader: "
select choice in GRUB sdboot; do
  case "$choice" in
    GRUB)
      grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch
      break;;
    sdboot)
      bootctl install
      break;;
    *) ;;
  esac
done
EOSB
else
  arch-chroot /mnt grub-install --target=i386-pc "$DISK"
fi

# Configure entries
if [[ "$FS" == btrfs ]]; then
  CRYPT_UUID=$(blkid -s UUID -o value "$P2")
  # Mapper name we used is cryptroot
  ROOTOPTS="root=/dev/mapper/cryptroot rootflags=subvol=@ rw"
  KPARMS="cryptdevice=UUID=$CRYPT_UUID:cryptroot"
else
  # ext4 root partition is P2 or P3 depending on home
  if [[ -e "$P2" && $(blkid -s TYPE -o value "$P2") == ext4 ]]; then ROOT_UUID=$(blkid -s UUID -o value "$P2"); fi
  ROOTOPTS="root=UUID=$ROOT_UUID rw"
  KPARMS=""
fi

if [[ "$FIRMWARE" == UEFI ]]; then
  # Detect if systemd-boot or grub was installed
  if arch-chroot /mnt test -d /boot/EFI/systemd; then
    # systemd-boot
    mkdir -p /mnt/boot/loader/entries
    cat > /mnt/boot/loader/loader.conf <<EOF
default arch
timeout 3
console-mode keep
EOF
    cat > /mnt/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /$([ ${#MICROCODE[@]} -gt 0 ] && echo ${MICROCODE[0]} | sed 's/-ucode//')-ucode.img
initrd  /initramfs-linux.img
options $KPARMS $ROOTOPTS
EOF
    cat > /mnt/boot/loader/entries/arch-lts.conf <<EOF
title   Arch Linux (lts)
linux   /vmlinuz-linux-lts
initrd  /$([ ${#MICROCODE[@]} -gt 0 ] && echo ${MICROCODE[0]} | sed 's/-ucode//')-ucode.img
initrd  /initramfs-linux-lts.img
options $KPARMS $ROOTOPTS
EOF
  else
    # GRUB
    if [[ -n "$KPARMS" ]]; then
      arch-chroot /mnt sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$KPARMS\"|" /etc/default/grub
    fi
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  fi
else
  # BIOS with GRUB
  if [[ -n "$KPARMS" ]]; then
    arch-chroot /mnt sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$KPARMS\"|" /etc/default/grub
  fi
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi

# Final touch: enable ssh optionally
# arch-chroot /mnt systemctl enable sshd

CHROOT

#-------------------------------
# Offer chroot shell to user
#-------------------------------
if dialog --backtitle "Arch Installer" --title "Chroot" --yesno "Enter an interactive chroot now?" 10 60; then
  arch-chroot /mnt
fi

d_msg "Done" "Installation complete. You can now reboot (umount -R /mnt; swapoff -a; reboot)"

