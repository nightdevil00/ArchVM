#!/bin/bash
set -e

# Paths
SRC="/home/mihai/.config"
DST="/home/mihai/omarchy_iso_build/omarchy_profile/airootfs/root/.config"

# Create destination if it doesn't exist
mkdir -p "$DST"

# Copy all directories except google-chrome
for item in "$SRC"/*; do
    base_item=$(basename "$item")
    if [ "$base_item" != "google-chrome" ]; then
        cp -rL "$item" "$DST/"
    fi
done

# Remove unwanted folder if it exists
rm -rf "$DST/gnome-boxes"

echo "Copy complete. 'google-chrome' excluded, 'gnome-boxes' removed."

