#!/bin/bash
BACKGROUND_LINK="$HOME/.config/hypr/background"
pkill swaybg 2>/dev/null
WALLPAPERS="$HOME/Pictures/wallpapers"
if [ -d "$WALLPAPERS" ] && [ "$(ls -A $WALLPAPERS)" ]; then
    WALLPAPER=$(find "$WALLPAPERS" -type f | shuf -n1)
    swaybg -i "$WALLPAPER" -m fill &
    rm -f "$BACKGROUND_LINK"
    ln -s "$WALLPAPER" "$BACKGROUND_LINK"
fi
