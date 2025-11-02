#!/bin/bash

CONFIG_FILE="$HOME/.config/matugen/config.toml"
SYMLINK_PATH="$HOME/.config/omarchy/current/background"

echo "Starting Matugen Wallpaper Watcher..."
echo "Monitoring: $SYMLINK_PATH"

while true; do
    # Wait for changes to the symlink
    inotifywait -e modify,create,delete,moved_to "$SYMLINK_PATH"

    # Resolve the symlink to get the actual wallpaper path
    WALLPAPER_PATH=$(readlink -f "$SYMLINK_PATH")

    if [ -f "$WALLPAPER_PATH" ]; then
        echo "Wallpaper changed to: $WALLPAPER_PATH"
        echo "Running matugen..."
        matugen image "$WALLPAPER_PATH" --config "$CONFIG_FILE"
        echo "matugen finished."

        # Optional: Add commands to reload applications here if matugen's config.toml doesn't handle it
        # For example, to restart Alacritty and Nautilus:
        # killall alacritty
        # killall nautilus

    else
        echo "Wallpaper path ($WALLPAPER_PATH) is not a valid file. Skipping matugen."
    fi

    # Add a small delay to prevent excessive runs if multiple changes occur rapidly
    sleep 2
done
