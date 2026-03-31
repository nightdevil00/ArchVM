#!/bin/bash

set -e

KEEP_PACKAGES=(
    "base"
    "linux"
    "linux-firmware"
    "systemd"
    "btrfs-progs"
    "sudo"
    "mkinitcpio"
    "limine"
    "nvidia-open-dkms"
    "nvidia-utils"
    "nvidia-settings"
    "libva-nvidia-driver"
    "plymouth"
    "sof-firmware"
    "intel-ucode"
    "iwd"
    "networkmanager"
    "yay-bin"
    "base-devel"
)

echo "Packages to keep:"
for pkg in "${KEEP_PACKAGES[@]}"; do
    if pacman -Q "$pkg" &>/dev/null; then
        echo "  - $pkg"
    else
        echo "  - $pkg (not installed)"
    fi
done
echo

mapfile -t EXPLICIT < <(pacman -Qeq)

REMOVE=()
for pkg in "${EXPLICIT[@]}"; do
    skip=false
    for keep in "${KEEP_PACKAGES[@]}"; do
        if [[ "$pkg" == "$keep" ]]; then
            skip=true
            break
        fi
    done
    if [[ "$skip" == false ]]; then
        REMOVE+=("$pkg")
    fi
done

if [[ ${#REMOVE[@]} -eq 0 ]]; then
    echo "No packages to remove!"
    exit 0
fi

echo "Packages to remove (${#REMOVE[@]}):"
printf '  - %s\n' "${REMOVE[@]}"
echo

read -p "Remove all these packages? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo "Removing packages..."
sudo pacman -Rcs "${REMOVE[@]}"

echo "Emptying /home/mihai/..."
cd /home/mihai
shopt -s dotglob
rm -rf *
shopt -u dotglob
cd ~

echo "Done!"
xdg-user-dirs-update

read -p "Reboot now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    xdg-user-dirs-update & sudo reboot
fi
