#!/bin/bash

# Define restore directory
RESTORE_DIR="/tmp/dotfiles_restore_temp"

echo "Starting restore process..."

# 1. Prompt user for the backup archive path
read -p "Enter the absolute path to your backup archive (.tar.gz): " BACKUP_ARCHIVE_PATH

if [ ! -f "$BACKUP_ARCHIVE_PATH" ]; then
    echo "Error: Backup archive not found at $BACKUP_ARCHIVE_PATH"
    exit 1
fi

# Create temporary restore directory
mkdir -p "$RESTORE_DIR" || { echo "Error: Could not create restore directory."; exit 1; }

# 2. Decompress the archive
echo "Decompressing $BACKUP_ARCHIVE_PATH to $RESTORE_DIR..."
tar -xzf "$BACKUP_ARCHIVE_PATH" -C "$RESTORE_DIR" || { echo "Error: Could not decompress archive."; rm -rf "$RESTORE_DIR"; exit 1; }

# 3. Restore .config and .local/share
read -p "This will overwrite your current ~/.config and ~/.local/share. Do you want to proceed? (y/N): " CONFIRM_RESTORE_FILES
if [[ "$CONFIRM_RESTORE_FILES" =~ ^[Yy]$ ]]; then
    echo "Restoring ~/.config..."
    rsync -a --delete "$RESTORE_DIR/.config/" "$HOME/.config/" || { echo "Error: Could not restore ~/.config."; rm -rf "$RESTORE_DIR"; exit 1; }
    echo "Restoring ~/.local/share..."
    rsync -a --delete "$RESTORE_DIR/.local/share/" "$HOME/.local/share/" || { echo "Error: Could not restore ~/.local/share."; rm -rf "$RESTORE_DIR"; exit 1; }
else
    echo "File restoration skipped."
fi

# 4. Install Pacman packages
PACMAN_PACKAGES_FILE="$RESTORE_DIR/pacman_packages.txt"
if [ -f "$PACMAN_PACKAGES_FILE" ]; then
    read -p "This will install/reinstall Pacman packages. Do you want to proceed? (y/N): " CONFIRM_INSTALL_PACMAN
    if [[ "$CONFIRM_INSTALL_PACMAN" =~ ^[Yy]$ ]]; then
        echo "Installing Pacman packages..."
        sudo pacman -S --needed - < "$PACMAN_PACKAGES_FILE" || { echo "Error: Could not install Pacman packages."; rm -rf "$RESTORE_DIR"; exit 1; }
    else
        echo "Pacman package installation skipped."
    fi
else
    echo "Pacman package list not found in backup."
fi

# 5. Install AUR packages
AUR_PACKAGES_FILE="$RESTORE_DIR/aur_packages.txt"
if [ -f "$AUR_PACKAGES_FILE" ]; then
    read -p "This will install/reinstall AUR packages using yay. Do you want to proceed? (y/N): " CONFIRM_INSTALL_AUR
    if [[ "$CONFIRM_INSTALL_AUR" =~ ^[Yy]$ ]]; then
        echo "Installing AUR packages..."
        yay -S --needed - < "$AUR_PACKAGES_FILE" || { echo "Error: Could not install AUR packages. Make sure yay is installed."; rm -rf "$RESTORE_DIR"; exit 1; }
    else
        echo "AUR package installation skipped."
    fi
else
    echo "AUR package list not found in backup."
fi

# Clean up temporary restore directory
echo "Cleaning up temporary restore directory..."
rm -rf "$RESTORE_DIR"

echo "Restore process complete!"
