#!/bin/bash

# This script configures passwordless sudo for pacman for the current user.

# The user to be granted passwordless sudo access for pacman
USER_TO_CONFIGURE="$USER"
SUDOERS_FILE="/etc/sudoers.d/$USER_TO_CONFIGURE-pacman"

# Check if the configuration file already exists
if [ -e "$SUDOERS_FILE" ]; then
    echo "Configuration already exists for '$USER_TO_CONFIGURE' in $SUDOERS_FILE."
    # Optional: Display the existing configuration
    echo "Current content:"
    cat "$SUDOERS_FILE"
    exit 0
fi

# The rule to be added
SUDO_RULE="$USER_TO_CONFIGURE ALL=(ALL) NOPASSWD: /usr/bin/pacman"

# Create the sudoers file for the user
echo "Creating sudoers file for '$USER_TO_CONFIGURE'..."
sudo sh -c "echo '$SUDO_RULE' > '$SUDOERS_FILE'"

# Set the correct permissions for the sudoers file
sudo chmod 440 "$SUDOERS_FILE"

# Validate the sudoers file syntax
echo "Validating sudoers file..."
if sudo visudo -c; then
    echo "Sudoers file updated successfully for '$USER_TO_CONFIGURE'."
else
    echo "Error: Sudoers file has syntax issues. Removing the created file..."
    sudo rm "$SUDOERS_FILE"
    echo "Removal complete. Please check the script and try again."
    exit 1
fi

echo "Passwordless sudo for pacman has been configured for '$USER_TO_CONFIGURE'."