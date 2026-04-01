#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root"
  exit 1
fi

# Define the sudoers file path
SUDOERS_FILE="/etc/sudoers.d/mihai_nopasswd"

# Create the sudoers file
echo "mihai ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"

# Set the correct permissions
chmod 0440 "$SUDOERS_FILE"

echo "✅ User 'mihai' now has passwordless sudo access."

