#!/usr/bin/env bash
set -euo pipefail

# ===== Configuration =====
WORKDIR="$HOME/archiso-build"
ISO_NAME="ArchOmarchy.iso"
ARCH_INSTALLER_URL="https://raw.githubusercontent.com/nightdevil00/ArchVM/main/omarchy-test.sh"
ARCH="https://raw.githubusercontent.com/nightdevil00/ArchVM/main/testing.sh"
LIMINE_URL="https://raw.githubusercontent.com/nightdevil00/ArchVM/main/limine.sh"

# ===== Install archiso if missing =====
sudo pacman -Sy --needed archiso --noconfirm

# ===== Prepare working directory =====
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cp -r /usr/share/archiso/configs/releng/ "$WORKDIR/myiso"

# ===== Add git and reflector to live ISO packages =====
echo -e "git\nreflector" >> "$WORKDIR/myiso/packages.x86_64"

# ===== Add installer scripts =====
mkdir -p "$WORKDIR/myiso/airootfs/root"
mkdir -p "$WORKDIR/myiso/airootfs/usr/local/bin"

# ArchInstallerScript -> /usr/local/bin for systemd execution
curl -fsSL "$ARCH_INSTALLER_URL" -o "$WORKDIR/myiso/airootfs/root/ArchInstallerScript.sh"
chmod +x "$WORKDIR/myiso/airootfs/root/ArchInstallerScript.sh"

# ArchInstallerScript -> /usr/local/bin for systemd execution
curl -fsSL "$ARCH" -o "$WORKDIR/myiso/airootfs/root/testing.sh"
chmod +x "$WORKDIR/myiso/airootfs/root/testing.sh"


# git-pull.sh helper
cat <<'EOF' > "$WORKDIR/myiso/airootfs/root/git-pull.sh"
#!/usr/bin/env bash
set -euo pipefail

INSTALLER_PATH="/root/ArchInstallerScript.sh"
INSTALLER_URL="https://raw.githubusercontent.com/nightdevil00/ArchVM/main/omarchy-test.sh"
LIMINE_PATH="/root/Limine.sh"
LIMINE_URL="https://raw.githubusercontent.com/nightdevil00/ArchVM/main/limine.sh"

echo "==> Updating ArchInstallerScript from GitHub..."
if [[ -f "$INSTALLER_PATH" ]]; then
    cp "$INSTALLER_PATH" "${INSTALLER_PATH}.bak"
    echo "Backup created at ${INSTALLER_PATH}.bak"
fi
curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_PATH"
chmod +x "$INSTALLER_PATH"

echo "==> Updating Limine from GitHub..."
if [[ -f "$LIMINE_PATH" ]]; then
    cp "$LIMINE_PATH" "${LIMINE_PATH}.bak"
    echo "Backup created at ${LIMINE_PATH}.bak"
fi
curl -fsSL "$LIMINE_URL" -o "$LIMINE_PATH"
chmod +x "$LIMINE_PATH"

echo "Update complete! Run with: $INSTALLER_PATH"
echo "Update complete! Run with: $LIMINE_PATH"

EOF
chmod +x "$WORKDIR/myiso/airootfs/root/git-pull.sh"

# ===== Add limine-install.sh =====
cat <<'EOF' > "$WORKDIR/myiso/airootfs/root/limine-install.sh"
#!/usr/bin/env bash
set -euo pipefail

echo "===== Limine Bootloader Installation ====="

pacman -Sy --noconfirm limine efibootmgr

# Detect EFI partition (vfat mounted at /boot or /efi)
ESP_PART=$(lsblk -rpno NAME,MOUNTPOINT,FSTYPE | awk '$2=="/boot" && ($3=="vfat" || $3=="FAT32"){print $1}')
if [[ -n "$ESP_PART" ]]; then
    ESP_DISK=$(lsblk -no PKNAME "$ESP_PART")
    ESP_DISK="/dev/$ESP_DISK"

    echo "ESP detected: $ESP_PART on disk $ESP_DISK"

    mkdir -p /boot/EFI/limine
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

    # Optional fallback path
    mkdir -p /boot/EFI/BOOT
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI

    # Create config
    cat > /boot/EFI/limine/limine.conf <<EOCFG
TIMEOUT=5
DEFAULT_ENTRY=Arch Linux

:Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot():/vmlinuz-linux
    CMDLINE=root=UUID=$(blkid -s UUID -o value $(findmnt -no SOURCE /)) rw quiet
    MODULE_PATH=boot():/initramfs-linux.img
EOCFG

    efibootmgr --create --disk "$ESP_DISK" --part 1 \
        --label "Arch Linux (Limine)" \
        --loader '\EFI\limine\BOOTX64.EFI' --unicode || echo "UEFI entry might already exist"
else
    echo "No EFI partition detected. Skipping UEFI setup."
fi


ROOT_DISK=$(lsblk -no PKNAME $(findmnt -no SOURCE /))
limine bios-install "/dev/$ROOT_DISK" || echo "BIOS stage1/2 install done (check manually if needed)"

echo "===== Limine installation complete! ====="
EOF
chmod +x "$WORKDIR/myiso/airootfs/root/limine-install.sh"

# ===== Configure root autologin on TTY1 =====
mkdir -p "$WORKDIR/myiso/airootfs/etc/systemd/system/getty@tty1.service.d"
cat <<EOF > "$WORKDIR/myiso/airootfs/etc/systemd/system/getty@tty1.service.d/override.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF

# ===== Create systemd service to auto-run installer =====
cat <<'EOF' > "$WORKDIR/myiso/airootfs/etc/systemd/system/archinstaller.service"
[Unit]
Description=Run ArchInstallerScript on live boot
After=getty@tty1.service
Requires=getty@tty1.service

[Service]
Type=simple
ExecStart=/root/ArchInstallerScript.sh
ExecStopPost=/bin/bash -c 'exec /bin/bash'   # Drop into shell if installer exits
StandardInput=tty-force
StandardOutput=inherit
StandardError=inherit

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
mkdir -p "$WORKDIR/myiso/airootfs/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/archinstaller.service \
   "$WORKDIR/myiso/airootfs/etc/systemd/system/multi-user.target.wants/archinstaller.service"

# ===== Build the ISO =====
sudo mkarchiso -v -w "$WORKDIR/work" -o "$WORKDIR/out" "$WORKDIR/myiso"

# ===== Rename output ISO =====
if [[ -f "$WORKDIR/out/archlinux-*.iso" ]]; then
    mv "$WORKDIR"/out/archlinux-*.iso "$WORKDIR/out/$ISO_NAME"
fi

echo "==> ISO built successfully: $WORKDIR/out/$ISO_NAME"
echo "Boot the ISO, root will auto-login, and ArchInstallerScript will run automatically."
echo "To update installer: /root/git-pull.sh"
echo "To install bootloader manually: /root/limine-install.sh"

