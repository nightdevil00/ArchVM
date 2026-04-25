#!/bin/bash

echo "Adding user to storage group..."
sudo usermod -aG storage $USER
echo "Done. You may need to log out and log back in for group changes to take effect."

echo ""
echo "Creating Polkit rule for mounting..."
sudo mkdir -p /etc/polkit-1/localauthority/50-local.d
sudo tee /etc/polkit-1/localauthority/50-mount.rules > /dev/null << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.udisks2.mount")
        return polkit.Result.YES;
});
EOF
echo "Polkit rule created."