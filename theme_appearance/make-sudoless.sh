#!/bin/sh
set -e

USER="mihai"
SUDOERS_FILE="/etc/sudoers.d/$USER-nopasswd"

if [ -f "$SUDOERS_FILE" ]; then
    echo "NOPASSWD sudo already configured for $USER"
    exit 0
fi

echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 440 "$SUDOERS_FILE"

echo "Done. $USER can now run sudo commands without a password."
echo "Test with: sudo -k && sudo true"
