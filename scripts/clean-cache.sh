#!/bin/bash

echo "Cleaning pacman cache..."
before=$(sudo ls /var/cache/pacman/pkg/*.pkg.tar.zst 2>/dev/null | wc -l)
echo "Packages in cache: $before"
sudo rm -rf /var/cache/pacman/pkg/download-*
sudo pacman -Scc
echo "Removed $before packages"

echo "Cleaning yay cache..."
yay -Scc

echo "Done!"
