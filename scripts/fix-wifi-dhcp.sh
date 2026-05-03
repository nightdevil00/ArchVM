#!/bin/bash
# Fix WiFi DHCP so it works automatically on boot

set -e

NETWORK_FILE="/etc/systemd/network/25-wlan0.network"

if [ -f "$NETWORK_FILE" ]; then
    echo "Config already exists at $NETWORK_FILE"
else
    echo "Creating $NETWORK_FILE..."
    cat > "$NETWORK_FILE" << 'EOF'
[Match]
Name=wlan0

[Network]
DHCP=ipv4
EOF
fi

systemctl restart systemd-networkd
systemctl enable systemd-networkd

echo "Done. wlan0 will now get DHCP on boot automatically."
networkctl status wlan0
