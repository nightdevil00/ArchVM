#!/bin/bash
#
# install_omarchy.sh - A non-interactive script to install Arch Linux with Omarchy DE.
#

set -e -u -o pipefail

# --- Configuration ---
# Please edit these variables to match your desired setup.

# User and system settings
USERNAME="mihai"
PASSWORD="password" # IMPORTANT: This will be used for the user, root, and disk encryption.
FULL_NAME="Mihai"
EMAIL_ADDRESS="mihai@example.com"
HOSTNAME="omarchy-box"

# Localization
KEYBOARD_LAYOUT="us"
TIMEZONE="Europe/Bucharest" # Find your timezone with `timedatectl list-timezones`

# Disk settings
if [ -z "${1-}" ]; then
    error "Usage: $0 <disk_device>\nExample: $0 /dev/sda\nCommon device names: /dev/sda, /dev/vda, /dev/nvme0n1, /dev/mmcblk0"
fi
DISK="$1"
# IMPORTANT: The selected disk ($DISK) will be completely wiped.


# Omarchy project path
# The script assumes the omarchy-2.0.5 directory is in this path.
PROJECT_DIR="/home/mihai/Project"


# --- Helper Functions ---
info() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
    exit 1
}

# --- Pre-flight Checks ---
pre_flight_checks() {
    info "Performing pre-flight checks..."
    if [[ "$EUID" -ne 0 ]]; then
        error "This script must be run as root."
    fi

    for cmd in archinstall jq openssl lsblk git; do
        if ! command -v "$cmd" &> /dev/null; then
            error "Required command '$cmd' is not installed. Please install it."
        fi
    done

    if [ ! -b "$DISK" ]; then
        error "Disk $DISK does not exist. Please check the DISK variable."
    fi

    
}

# --- Generate Configs ---
generate_configs() {
    info "Generating archinstall configuration files..."

    # Calculate partition sizes
    local disk_size=$(lsblk -bdno SIZE "$DISK")
    local mib=$((1024 * 1024))
    local gib=$((mib * 1024))
    local disk_size_in_mib=$((disk_size / mib * mib))
    local gpt_backup_reserve=$((mib))
    local boot_partition_start=$((mib))
    local boot_partition_size=$((2 * gib))
    local main_partition_start=$((boot_partition_size + boot_partition_start))
    local main_partition_size=$((disk_size_in_mib - main_partition_start - gpt_backup_reserve))

    # Escape variables for JSON
    local password_escaped=$(echo -n "$PASSWORD" | jq -Rsa)
    local password_hash=$(openssl passwd -6 "$PASSWORD")
    local password_hash_escaped=$(echo -n "$password_hash" | jq -Rsa)
    local username_escaped=$(echo -n "$USERNAME" | jq -Rsa)

    # Create user_credentials.json
    cat <<-_EOF_ > user_credentials.json
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

    # Create user_configuration.json
    cat <<-_EOF_ > user_configuration.json
    {
        "archinstall-language": "English",
        "audio_config": { "audio": "pipewire" },
        "bootloader": "Limine",
        "disk_config": {
            "btrfs_options": { 
              "snapshot_config": {
                "type": "Snapper"
              }
            },
            "config_type": "default_layout",
            "device_modifications": [
                {
                    "device": "$DISK",
                    "partitions": [
                        {
                            "flags": [ "boot", "esp" ],
                            "fs_type": "fat32",
                            "mountpoint": "/boot",
                            "obj_id": "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
                            "size": {
                                "unit": "B",
                                "value": $boot_partition_size
                            },
                            "start": {
                                "unit": "B",
                                "value": $boot_partition_start
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
                            "fs_type": "btrfs",
                            "mount_options": [ "compress=zstd" ],
                            "obj_id": "8c2c2b92-1070-455d-b76a-56263bab24aa",
                            "size": {
                                "unit": "B",
                                "value": $main_partition_size
                            },
                            "start": {
                                "unit": "B",
                                "value": $main_partition_start
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
                "partitions": [ "8c2c2b92-1070-455d-b76a-56263bab24aa" ],
                "encryption_password": $password_escaped
            }
        },
        "hostname": "$HOSTNAME",
        "kernels": [ "linux" ],
        "network_config": { "type": "iso" },
        "ntp": true,
        "parallel_downloads": 8,
        "swap": true,
        "timezone": "$TIMEZONE",
        "locale_config": {
            "kb_layout": "$KEYBOARD_LAYOUT",
            "sys_enc": "UTF-8",
            "sys_lang": "en_US.UTF-8"
        },
        "packages": [
            "base-devel",
            "git"
        ]
    }
_EOF_
}

# --- Run Installation ---
run_installation() {
    info "Starting Arch Linux installation with archinstall..."
    archinstall --config user_configuration.json --creds user_credentials.json --silent

    info "Installing Omarchy Desktop Environment..."
    
    # Copy Omarchy project to the new system
    mkdir -p "/mnt/home/$USERNAME/.local/share"
    git clone https://github.com/basecamp/omarchy.git "/mnt/home/$USERNAME/.local/share/omarchy"

    # Chroot into the new system and run the Omarchy installer
    arch-chroot -u "$USERNAME" /mnt /bin/bash -c "env OMARCHY_CHROOT_INSTALL=1 OMARCHY_USER_NAME='$FULL_NAME' OMARCHY_USER_EMAIL='$EMAIL_ADDRESS' /home/$USERNAME/.local/share/omarchy/install.sh"

    info "Cleaning up configuration files..."
    rm user_configuration.json user_credentials.json
}

# --- Main Function ---
main() {
    pre_flight_checks
    generate_configs
    run_installation
    info "Installation complete! You can now reboot your system."
}

main
