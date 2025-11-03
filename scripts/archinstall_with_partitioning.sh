#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Interactive Install Script with Windows Dualboot support
# ==============================================================================
# DISCLAIMER:
# This script is provided "as-is" for educational and personal use only.
# The author is NOT responsible for any damage, data loss, or system issues
# that may result from using or modifying this script. Use at your own risk.
# ==============================================================================

set -euo pipefail

# Check if running in Arch ISO
if [[ ! -d /run/archiso ]]; then
  echo "================================================================"
  echo "ERROR: This script must be run from the Arch Linux ISO!"
  echo "================================================================"
  echo
  echo "You are currently running from an installed system."
  echo "This script is designed to install Arch Linux and requires"
  echo "a clean environment provided by the Arch ISO."
  echo
  echo "To use this script:"
  echo "  1. Download the Arch Linux ISO from archlinux.org"
  echo "  2. Create a bootable USB stick"
  echo "  3. Boot from the USB stick"
  echo "  4. Run this script from the live environment"
  echo
  echo "WARNING: Running this script from an installed system"
  echo "         could damage your current installation!"
  echo "================================================================"
  exit 1
fi

# Check root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

# Check for gum and jq
if ! command -v gum &> /dev/null; then
    echo "gum could not be found. Please install it (e.g., pacman -S gum)."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "jq could not be found. Please install it (e.g., pacman -S jq)."
    exit 1
fi

abort() {
  gum style "${1:-Aborted installation}"
  echo
  gum style "You can retry later by running: ./archdualboot.sh"
  exit 1
}

step() {
  echo
  gum style "$1"
  echo
}

notice() {
  echo
  gum spin --spinner "pulse" --title "$1" -- sleep "${2:-2}"
  echo
}

# STEP 1: KEYBOARD LAYOUT
keyboard_form() {
  step "Let's setup your machine..."
  keyboards=$'Azerbaijani|azerty
Belarusian|by
Belgian|be-latin1
Bosnian|ba
Bulgarian|bg-cp1251
Croatian|croat
Czech|cz
Danish|dk-latin1
Dutch|nl
English (UK)|uk
English (US)|us
English (US, Dvorak)|dvorak
Estonian|et
Finnish|fi
French|fr
French (Canada)|cf
French (Switzerland)|fr_CH
Georgian|ge
German|de
German (Switzerland)|de_CH-latin1
Greek|gr
Hebrew|il
Hungarian|hu
Icelandic|is-latin1
Irish|ie
Italian|it
Japanese|jp106
Kazakh|kazakh
Khmer (Cambodia)|khmer
Kyrgyz|kyrgyz
Lao|la-latin1
Latvian|lv
Lithuanian|lt
Macedonian|mk-utf
Norwegian|no-latin1
Polish|pl
Portuguese|pt-latin1
Portuguese (Brazil)|br-abnt2
Romanian|ro
Russian|ru
Serbian|sr-latin
Slovak|sk-qwertz
Slovenian|slovene
Spanish|es
Spanish (Latin American)|la-latin1
Swedish|sv-latin1
Tajik|tj_alt-UTF8
Turkish|trq
Ukrainian|ua'
  choice=$(printf '%s\n' "$keyboards" | cut -d'|' -f1 | gum choose --height 10 --selected "English (US)" --header "Select keyboard layout") || abort
  keyboard=$(printf '%s\n' "$keyboards" | awk -F'|' -v c="$choice" '$1==c{print $2; exit}')

  # Only attempt to load keyboard layout if we're on a real console
  if [[ $(tty 2>/dev/null) == "/dev/tty"* ]]; then
    loadkeys "$keyboard" 2>/dev/null || true
  fi
}

keyboard_form

# STEP 2: USER
user_form() {
  step "Let's setup your user account..."

  while true; do
    username=$(gum input --placeholder "Alphanumeric without spaces (like dhh)" --prompt.foreground="#845DF9" --prompt "Username> ") || abort

    if [[ "$username" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
      break
    else
      notice "Username must be alphanumeric with no spaces" 1
    fi
  done

  while true; do
    password=$(gum input --placeholder "Used for user + root + disk encryption" --prompt.foreground="#845DF9" --password --prompt "Password> ") || abort
    password_confirmation=$(gum input --placeholder "Must match the password you just typed" --prompt.foreground="#845DF9" --password --prompt "Confirm> ") || abort

    if [[ -n "$password" && "$password" == "$password_confirmation" ]]; then
      break
    elif [[ -z "$password" ]]; then
      notice "Your password can't be blank!" 1
    else
      notice "Passwords didn't match!" 1
    fi
  done

  # Hash the password using yescrypt (same password for user, root, and encryption)
  password_hash=$(printf '%s' "$password" | openssl passwd -6 -stdin)

  full_name=$(gum input --placeholder "Used for git authentication (hit return to skip)" --prompt.foreground="#845DF9" --prompt "Full name> " || echo "")
  email_address=$(gum input --placeholder "Used for git authentication (hit return to skip)" --prompt.foreground="#845DF9" --prompt "Email address> " || echo "")

  while true; do
    hostname=$(gum input --placeholder "Alphanumeric without spaces (or return for 'omarchy')" --prompt.foreground="#845DF9" --prompt "Hostname> " || echo "")

    if [[ "$hostname" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
      break
    elif [[ -z "$hostname" ]]; then
      hostname="omarchy"
      break
    else
      notice "Hostname must be alphanumeric using dashes or underscores but no spaces" 1
    fi
  done

  # Pick timezone
  geo_guessed_timezone=$(tzupdate -p 2>/dev/null || echo "")

  if [[ -n "$geo_guessed_timezone" ]]; then
    timezone=$(timedatectl list-timezones | gum choose --height 10 --selected "$geo_guessed_timezone" --header "Timezone") || abort
  else
    timezone=$(timedatectl list-timezones | gum filter --height 10 --header "Timezone") || abort
  fi
}

user_form

# Confirmation loop
while true; do
  echo -e "Field,Value\nUsername,$username\nPassword,$(printf "%${#password}s" | tr ' ' '*')\nFull name,${full_name:-[Skipped]}\nEmail address,${email_address:-[Skipped]}\nHostname,$hostname\nTimezone,$timezone\nKeyboard,$keyboard" |
    gum table -s "," -p

  echo
  if gum confirm --negative "No, change it" "Does this look right?"; then
    break
  else
    keyboard_form
    user_form
  fi
done

TMP_MOUNT="/mnt/__arch_install_tmp"
mkdir -p "$TMP_MOUNT"

# Disk selection
get_disk_info() {
  local device="$1"
  local size model

  size=$(lsblk -dno SIZE "$device" 2>/dev/null || echo "unknown")
  model=$(lsblk -dno MODEL "$device" 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || echo "")

  local display="$device"
  [[ -n "$size" ]] && display="$display $size"
  [[ -n "$model" ]] && display="$display - $model"

  echo "$display"
}

disk_form() {
  step "Let's select where to install Arch..."

  # Exclude the install media
  local exclude_disk
  exclude_disk=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null | sed 's/[0-9]*$//' || echo "")

  # List all installable disks
  local available_disks_raw
  available_disks_raw=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E '/dev/(sd|hd|vd|nvme|mmcblk|xvd)' | ( if [[ -n "$exclude_disk" ]]; then grep -Fvx "$exclude_disk"; else cat; fi; ) || echo "")

  if [[ -z "$available_disks_raw" ]]; then
    echo "No suitable disks found!"
    exit 1
  fi

  # Get available disks and format them with info
  local disk_options_array=()
  while IFS= read -r device; do
    if [[ -n "$device" ]]; then
      disk_info=$(get_disk_info "$device")
      disk_options_array+=("$disk_info")
    fi
  done <<<"$available_disks_raw"

  # Join array elements with newlines
  local disk_options
  printf -v disk_options "%s\n" "${disk_options_array[@]}"

  selected_display=$(echo "$disk_options" | gum choose --height 10 --header "Select install disk") || abort
  TARGET_DISK=$(echo "$selected_display" | awk '{print $1}')
}

disk_form

while true; do
  gum style "Everything will be overwritten. There is no recovery possible."
  echo
  if gum confirm --affirmative "Yes, format disk" --negative "No, change it" "Confirm overwriting \"${TARGET_DISK}\""; then
    break
  else
    disk_form
  fi
done

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$TARGET_DISK"

# --- Windows detection ---
echo
echo "Scanning all partitions for Windows boot files..."
declare -a PROTECTED_PART_KEYS=()
declare -a PROTECTED_PART_VALUES=()
WINDOWS_EFI_PART=""

# Iterate partitions to identify Windows systems
while IFS= read -r line; do
  eval "$line"
  if [[ "${TYPE:-}" != "part" ]]; then
    continue
  fi
  PART="/dev/${NAME}"
  
  # Skip loop devices, zram, etc
  if [[ "$PART" =~ loop|sr|md|zram ]]; then
    continue
  fi

  # Find filesystem type
  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || echo "")

  # Check VFAT/FAT for EFI/Microsoft
  if [[ "$FSTYPE" =~ ^(vfat|fat32|fat)$ ]]; then
    mkdir -p "$TMP_MOUNT"
    if mount -o ro "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/EFI/Microsoft" ]] || [[ -f "$TMP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
        PROTECTED_PART_KEYS+=("$PART")
        PROTECTED_PART_VALUES+=("EFI Microsoft files found")
        WINDOWS_EFI_PART="$PART"
        echo "Protected (EFI): $PART -> EFI Microsoft files found"
      fi
      umount "$TMP_MOUNT" 2>/dev/null || true
    fi
  fi

  # Check NTFS for Windows
  if [[ "$FSTYPE" == "ntfs" ]]; then
    mkdir -p "$TMP_MOUNT"
    if mount -o ro "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/Windows" ]] || [[ -f "$TMP_MOUNT/bootmgr" ]]; then
        PROTECTED_PART_KEYS+=("$PART")
        PROTECTED_PART_VALUES+=("NTFS Windows files found")
        echo "Protected (NTFS): $PART -> NTFS Windows files found"
      fi
      umount "$TMP_MOUNT" 2>/dev/null || true
    fi
  fi
done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || echo "")

# Partitioning logic
if [ ${#PROTECTED_PART_KEYS[@]} -gt 0 ]; then
  echo
  echo "Detected Windows partitions:"
  for i in "${!PROTECTED_PART_KEYS[@]}"; do
    echo "  ${PROTECTED_PART_KEYS[$i]} -> ${PROTECTED_PART_VALUES[$i]}"
  done
  echo

  gum style "Windows partitions were found. How would you like to proceed?"
  partition_choice=$(gum choose "Install Arch in free space (dual-boot with Windows)" "Wipe entire disk and install Arch") || abort

  if [[ "$partition_choice" == "Install Arch in free space (dual-boot with Windows)" ]]; then
    gum style "The script will create partitions in free space only."
    echo

    echo "PARTITION TABLE + FREE SPACE (for $TARGET_DISK):"
    parted --script "$TARGET_DISK" unit GB print free || true

    echo
    gum style "Provide start and end positions for new Arch partitions."
    gum style "Look at the 'Free Space' sections above and use those ranges."
    gum style "Example: If free space shows '500GB to 931GB', use start=500GB end=600GB"
    gum style "Units: Use GB (e.g., 500GB) or % (e.g., 50%)"

    EFI_START=$(gum input --placeholder "e.g. 500GB" --prompt.foreground="#845DF9" --prompt "EFI start> ") || abort
    EFI_END=$(gum input --placeholder "e.g. 502GB" --prompt.foreground="#845DF9" --prompt "EFI end> ") || abort
    ROOT_START=$(gum input --placeholder "e.g. 502GB" --prompt.foreground="#845DF9" --prompt "Root start> ") || abort
    ROOT_END=$(gum input --placeholder "e.g. 100%" --prompt.foreground="#845DF9" --prompt "Root end> ") || abort

    echo "Creating partitions..."
    parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END" || abort "Failed to create EFI partition"
    parted --script "$TARGET_DISK" mkpart primary btrfs "$ROOT_START" "$ROOT_END" || abort "Failed to create root partition"
    
    # Set ESP flag on new EFI partition
    LAST_PART_NUM=$(parted -s "$TARGET_DISK" print | grep -E '^ [0-9]+' | tail -n2 | head -n1 | awk '{print $1}')
    parted --script "$TARGET_DISK" set "$LAST_PART_NUM" esp on 2>/dev/null || true

    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2

    # Get the newly created partitions (last two)
    parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
    num_parts=${#parts[@]}
    efi_partition="${parts[$((num_parts-2))]}"
    root_partition="${parts[$((num_parts-1))]}"
  else
    gum confirm --negative "No, change it" "Wipe entire $TARGET_DISK for Arch?" || abort

    echo "Creating new GPT and partitions..."
    parted --script "$TARGET_DISK" mklabel gpt || abort "Failed to create GPT"
    parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB || abort "Failed to create EFI"
    parted --script "$TARGET_DISK" set 1 esp on || abort "Failed to set ESP flag"
    parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100% || abort "Failed to create root"
    
    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2

    parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
    efi_partition="${parts[0]}"
    root_partition="${parts[1]}"
  fi
else
  echo "No Windows partitions detected."
  gum style "How would you like to partition $TARGET_DISK?"
  partition_choice=$(gum choose "Use full disk for Arch (automatic)" "Manual partition (advanced)") || abort

  if [[ "$partition_choice" == "Use full disk for Arch (automatic)" ]]; then
    gum confirm --negative "No, change it" "Wipe entire $TARGET_DISK for Arch?" || abort

    echo "Creating new GPT and partitions..."
    parted --script "$TARGET_DISK" mklabel gpt || abort "Failed to create GPT"
    parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB || abort "Failed to create EFI"
    parted --script "$TARGET_DISK" set 1 esp on || abort "Failed to set ESP flag"
    parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100% || abort "Failed to create root"
    
    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2

    parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
    efi_partition="${parts[0]}"
    root_partition="${parts[1]}"
  else
    gum style "Manual partitioning selected."
    echo
    gum style "WARNING: This will delete the existing partition table!"
    
    if ! gum confirm --negative "Cancel" "Create new GPT partition table on $TARGET_DISK?"; then
      abort "User cancelled manual partitioning"
    fi
    
    echo "Creating new GPT partition table..."
    parted --script "$TARGET_DISK" mklabel gpt || abort "Failed to create GPT"
    
    gum style "Provide start and end positions for partitions."
    gum style "Leave blank to use defaults (2GB EFI, rest for root)."
    
    EFI_START=$(gum input --placeholder "Default: 1MiB" --prompt.foreground="#845DF9" --prompt "EFI start (or Enter for default)> " || echo "")
    EFI_END=$(gum input --placeholder "Default: 2049MiB" --prompt.foreground="#845DF9" --prompt "EFI end (or Enter for default)> " || echo "")
    ROOT_START=$(gum input --placeholder "Default: 2049MiB" --prompt.foreground="#845DF9" --prompt "Root start (or Enter for default)> " || echo "")
    ROOT_END=$(gum input --placeholder "Default: 100%" --prompt.foreground="#845DF9" --prompt "Root end (or Enter for default)> " || echo "")

    # Use defaults if empty
    [[ -z "$EFI_START" ]] && EFI_START="1MiB"
    [[ -z "$EFI_END" ]] && EFI_END="2049MiB"
    [[ -z "$ROOT_START" ]] && ROOT_START="2049MiB"
    [[ -z "$ROOT_END" ]] && ROOT_END="100%"

    echo "Creating partitions..."
    echo "  EFI: $EFI_START to $EFI_END"
    echo "  Root: $ROOT_START to $ROOT_END"
    
    parted --script "$TARGET_DISK" mkpart primary fat32 "$EFI_START" "$EFI_END" || abort "Failed to create EFI partition"
    parted --script "$TARGET_DISK" set 1 esp on || abort "Failed to set ESP flag"
    parted --script "$TARGET_DISK" mkpart primary btrfs "$ROOT_START" "$ROOT_END" || abort "Failed to create root partition"

    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2

    parts=($(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print "/dev/"$1}'))
    efi_partition="${parts[0]}"
    root_partition="${parts[1]}"
  fi
fi

# Verify partitions
if [[ -z "${efi_partition:-}" || -z "${root_partition:-}" ]]; then
  echo "ERROR: Could not determine partition paths!"
  lsblk -o NAME,KNAME,SIZE,FSTYPE,MOUNTPOINT "$TARGET_DISK"
  exit 1
fi

echo "EFI partition: $efi_partition"
echo "Root partition: $root_partition"
sleep 2

clear

# Save user data
echo "$full_name" >user_full_name.txt
echo "$email_address" >user_email_address.txt

# Create credentials JSON (using same password for user login and disk encryption)
password_escaped=$(echo -n "$password" | jq -Rsa)
password_hash_escaped=$(echo -n "$password_hash" | jq -Rsa)
username_escaped=$(echo -n "$username" | jq -Rsa)

cat <<-_EOF_ >user_credentials.json
{
    "encryption_password": $password_escaped,
    "root_enc_password": $password_hash_escaped,
    "users": [
        {
            "enc_password": $password_hash_escaped,
            "groups": [],
            "sudo": true,
            "username": $username_escaped
        }
    ]
}
_EOF_

# Get partition sizes and starts
EFI_PART_SIZE_BYTES=$(lsblk -bno SIZE "$efi_partition" 2>/dev/null || echo "2147483648")
ROOT_PART_SIZE_BYTES=$(lsblk -bno SIZE "$root_partition" 2>/dev/null || echo "107374182400")

# Calculate partition start positions (1MiB = 1048576 bytes)
EFI_PART_START=1048576
ROOT_PART_START=$((EFI_PART_START + EFI_PART_SIZE_BYTES))

# Detect kernel (T2 Mac support)
if lspci -nn 2>/dev/null | grep -q "106b:180[12]"; then
  kernel_choice="linux-t2"
else
  kernel_choice="linux"
fi

EFI_OBJ_ID=$(uuidgen)
ROOT_OBJ_ID=$(uuidgen)

# Create configuration JSON
cat <<-_EOF_ >user_configuration.json
{
    "app_config": null,
    "archinstall-language": "English",
    "auth_config": {},
    "audio_config": { "audio": "pipewire" },
    "bootloader": "Limine",
    "custom_commands": [],
    "disk_config": {
        "btrfs_options": { 
          "snapshot_config": {
            "type": "Snapper"
          }
        },
        "config_type": "default_layout",
        "device_modifications": [
            {
                "device": "$TARGET_DISK",
                "partitions": [
                    {
                        "btrfs": [],
                        "dev_path": "$efi_partition",
                        "flags": [ "boot", "esp" ],
                        "fs_type": "fat32",
                        "mount_options": [],
                        "mountpoint": "/boot",
                        "obj_id": "$EFI_OBJ_ID",
                        "size": {
                            "sector_size": { "unit": "B", "value": 512 },
                            "unit": "B",
                            "value": $EFI_PART_SIZE_BYTES
                        },
                        "start": {
                            "sector_size": { "unit": "B", "value": 512 },
                            "unit": "B",
                            "value": $EFI_PART_START
                        },
                        "status": "create",
                        "type": "primary"
                    },
                    {
                        "btrfs": [
                            { "mountpoint": "/", "name": "@" },
                            { "mountpoint": "/home", "name": "@home" },
                            { "mountpoint": "/var/log", "name": "@log" },
                            { "mountpoint": "/var/cache/pacman/pkg", "name": "@pkg" }
                        ],
                        "dev_path": "$root_partition",
                        "flags": [],
                        "fs_type": "btrfs",
                        "mount_options": [ "compress=zstd" ],
                        "mountpoint": null,
                        "obj_id": "$ROOT_OBJ_ID",
                        "size": {
                            "sector_size": { "unit": "B", "value": 512 },
                            "unit": "B",
                            "value": $ROOT_PART_SIZE_BYTES
                        },
                        "start": {
                            "sector_size": { "unit": "B", "value": 512 },
                            "unit": "B",
                            "value": $ROOT_PART_START
                        },
                        "status": "create",
                        "type": "primary"
                    }
                ],
                "wipe": true
            }
        ],
        "disk_encryption": {
            "encryption_type": "luks",
            "lvm_volumes": [],
            "iter_time": 2000,
            "partitions": [ "$ROOT_OBJ_ID" ],
            "encryption_password": $password_escaped
        }
    },
    "hostname": "$hostname",
    "kernels": [ "$kernel_choice" ],
    "network_config": { "type": "iso" },
    "ntp": true,
    "parallel_downloads": 8,
    "script": null,
    "services": [],
    "swap": true,
    "timezone": "$timezone",
    "locale_config": {
        "kb_layout": "$keyboard",
        "sys_enc": "UTF-8",
        "sys_lang": "en_US.UTF-8"
    },
    "mirror_config": {
        "custom_repositories": [],
        "custom_servers": [
            {"url": "https://mirror.omarchy.org/\$repo/os/\$arch"},
            {"url": "https://mirror.rackspace.com/archlinux/\$repo/os/\$arch"},
            {"url": "https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"}
        ],
        "mirror_regions": {},
        "optional_repositories": []
    },
    "packages": [
        "base-devel",
        "git",
        "omarchy-keyring"
    ],
    "profile_config": {
        "gfx_driver": null,
        "greeter": null,
        "profile": {}
    },
    "version": "3.0.9"
}
_EOF_

# Run archinstall
step "Running archinstall..."
archinstall --config user_configuration.json --creds user_credentials.json || abort "archinstall failed"

# Add Windows entry to Limine
step "Configuring bootloader..."

# Wait for devices to settle
sleep 3

# Mount partitions
if mount | grep -q "/mnt"; then
    echo "Partitions already mounted"
else
    mount /dev/mapper/cryptroot /mnt 2>/dev/null || mount "$root_partition" /mnt || abort "Failed to mount root"
    mkdir -p /mnt/boot
    mount "$efi_partition" /mnt/boot || abort "Failed to mount boot"
fi

# Add Windows to Limine config
if [[ -n "$WINDOWS_EFI_PART" ]]; then
    arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

if [[ -f /boot/limine.conf ]]; then
    WINDOWS_EFI_UUID=\$(blkid -s UUID -o value "$WINDOWS_EFI_PART" 2>/dev/null || echo "")
    if [[ -n "\$WINDOWS_EFI_UUID" ]]; then
        cat >> /boot/limine.conf <<LIMINE_WINDOWS

:Windows
    PROTOCOL=chainload
    DRIVE=uuid:\$WINDOWS_EFI_UUID
    PATH=\\\\EFI\\\\Microsoft\\\\Boot\\\\bootmgfw.efi
LIMINE_WINDOWS
        echo "Windows entry added to Limine"
    fi
fi

systemctl enable NetworkManager 2>/dev/null || true
EOF
fi

# Cleanup
echo "Cleaning up..."
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
cryptsetup luksClose cryptroot 2>/dev/null || true
rm -rf "$TMP_MOUNT"

echo
echo "=============================================="
echo "Installation completed!"
echo "=============================================="
echo
echo "Review output above for any errors."
if [[ -n "$WINDOWS_EFI_PART" ]]; then
    echo "Windows dual-boot configured."
fi
echo "You can now reboot."
echo
