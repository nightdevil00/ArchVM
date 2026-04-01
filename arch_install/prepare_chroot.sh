#!/bin/bash
set -e
CHROOT_DIR="arch-chroot"
if [ -d "$CHROOT_DIR" ]; then
  echo "Chroot directory already exists. Skipping creation."
  exit 0
fi
echo "Creating chroot directory..."
mkdir -p "$CHROOT_DIR"
echo "Bootstrapping Arch Linux base system..."
sudo pacstrap -c "$CHROOT_DIR" base base-devel git python-pip sudo jq archiso
echo "Chroot preparation complete."
