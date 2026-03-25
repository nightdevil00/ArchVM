#!/bin/bash
set -e

sudo sed -i 's/inode\/directory;//g' /usr/share/applications/kitty-open.desktop
sudo update-desktop-database /usr/share/applications/ 2>/dev/null || true
xdg-mime default nautilus.desktop inode/directory
