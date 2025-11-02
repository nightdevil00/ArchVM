#!/bin/bash

# Define backup directory and file names
BACKUP_DIR="$HOME/dotfiles_backup_temp"
BACKUP_ARCHIVE="$HOME/dotfiles_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
PACMAN_PACKAGES_FILE="$BACKUP_DIR/pacman_packages.txt"
AUR_PACKAGES_FILE="$BACKUP_DIR/aur_packages.txt"

echo "Starting backup process..."

# Create temporary backup directory
mkdir -p "$BACKUP_DIR" || { echo "Error: Could not create backup directory."; exit 1; }

mkdir -p "$BACKUP_DIR/.config"
mkdir -p "$BACKUP_DIR/.local/share"

# 1. Export installed packages
echo "Exporting installed Pacman packages..."
pacman -Qqen > "$PACMAN_PACKAGES_FILE" || { echo "Error: Could not export Pacman packages."; rm -rf "$BACKUP_DIR"; exit 1; }
echo "Exporting installed AUR packages (via yay)..."
yay -Qqem > "$AUR_PACKAGES_FILE" || { echo "Error: Could not export AUR packages. Make sure yay is installed."; rm -rf "$BACKUP_DIR"; exit 1; }

# 2. Copy .config and .local/share
echo "Copying ~/.config to backup directory (excluding google-chrome and chromium)..."
rsync -aL --exclude-from="$HOME/exclude.txt" "$HOME/.config/" "$BACKUP_DIR/.config/" || { echo "Error: Could not copy ~/.config."; rm -rf "$BACKUP_DIR"; exit 1; }
echo "Copying ~/.local/share to backup directory..."
rsync -aL --exclude-from="$HOME/exclude.txt" "$HOME/.local/share/" "$BACKUP_DIR/.local/share/" || { echo "Error: Could not copy ~/.local/share."; rm -rf "$BACKUP_DIR"; exit 1; }

# 3. Compress them along with the package lists
echo "Creating compressed archive: $BACKUP_ARCHIVE"
tar -czf "$BACKUP_ARCHIVE" -C "$BACKUP_DIR" . || { echo "Error: Could not create archive."; rm -rf "$BACKUP_DIR"; exit 1; }

# Clean up temporary backup directory
echo "Cleaning up temporary backup directory..."
rm -rf "$BACKUP_DIR"

echo "Backup complete! Archive saved to: $BACKUP_ARCHIVE"
