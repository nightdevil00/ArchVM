#!/bin/bash
set -e

echo "Installing awww-git..."
yay -S awww

echo "Verifying installation..."
command -v awww
command -v awww-daemon

echo "Creating systemd user service..."
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/awww-daemon.service << 'EOF'
[Unit]
Description=awww daemon
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/usr/bin/awww-daemon
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
EOF

WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
echo "Creating override file for Wayland display: $WAYLAND_DISPLAY"
mkdir -p ~/.config/systemd/user/awww-daemon.service.d
cat > ~/.config/systemd/user/awww-daemon.service.d/override.conf << EOF
[Service]
Environment=WAYLAND_DISPLAY=$WAYLAND_DISPLAY
Environment=XDG_RUNTIME_DIR=/run/user/%U
EOF

echo "Enabling and starting the daemon..."
systemctl --user daemon-reload
systemctl --user enable --now awww-daemon.service

echo "Checking service status..."
systemctl --user status awww-daemon.service --no-pager || true

echo "Done! awww-daemon is now enabled and running."
