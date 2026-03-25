#!/bin/bash

# Add user to wheel group if not already
sudo usermod -aG wheel $(whoami)

# Add passwordless sudo for wheel group
echo "%wheel ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/wheel-nopasswd > /dev/null
sudo chmod 440 /etc/sudoers.d/wheel-nopasswd

echo "Done! Passwordless sudo enabled for $(whoami)"
