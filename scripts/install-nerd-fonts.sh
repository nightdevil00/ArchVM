#!/bin/bash
# Install popular nerd fonts for waybar

sudo pacman -S --needed \
    ttf-hack-nerd \
    ttf-cascadia-code-nerd \
    ttf-firacode-nerd \
    ttf-jetbrains-mono-nerd \
    ttf-nerd-fonts-symbols-mono

fc-cache -f -v
