#!/bin/bash
set -e

echo "Switching from iwd/systemd-resolved to NetworkManager..."

# Install NetworkManager first (while still online)
if ! command -v nmcli &>/dev/null; then
    echo "Installing NetworkManager..."
    if command -v apt &>/dev/null; then
        apt install -y network-manager
    elif command -v dnf &>/dev/null; then
        dnf install -y NetworkManager
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm networkmanager
    fi
fi

# Enable and start NetworkManager (before removing iwd)
echo "Enabling NetworkManager..."
systemctl enable NetworkManager
systemctl start NetworkManager

# Wait for NetworkManager to be fully up
sleep 2

# Stop and disable iwd
if command -v iwd &>/dev/null; then
    echo "Stopping iwd..."
    systemctl stop iwd 2>/dev/null || true
    systemctl disable iwd 2>/dev/null || true
    systemctl mask iwd 2>/dev/null || true
fi

# Stop and disable systemd-resolved
if command -v systemd-resolved &>/dev/null; then
    echo "Stopping systemd-resolved..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
fi

# Create default resolv.conf
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 1.0.0.1" >> /etc/resolv.conf

echo "Done! Run 'nmcli device wifi list' to see available networks."