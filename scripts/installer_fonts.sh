#!/bin/bash

# This script installs fonts system-wide for Arch Linux.
# It assumes that the fonts are located in a 'fonts' directory
# in the same directory as this script.

# Exit immediately if a command exits with a non-zero status.
set -e

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo." >&2
    exit 1
fi

# Determine the script's directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
SOURCE_DIR="$SCRIPT_DIR/fonts"

# Destination directory for the fonts
DEST_DIR="/usr/share/fonts/custom_fonts"

# Check if the source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: The source font directory was not found at $SOURCE_DIR" >&2
    exit 1
fi

# Create the destination directory
echo "Creating destination directory: $DEST_DIR"
mkdir -p "$DEST_DIR"

# Copy the font files
echo "Copying fonts to $DEST_DIR..."
cp -v "$SOURCE_DIR"/* "$DEST_DIR/"

# Update the font cache
echo "Updating font cache..."
fc-cache -f -v

echo "Fonts have been installed successfully."
