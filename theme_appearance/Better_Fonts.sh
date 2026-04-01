#!/bin/bash

# A script to install and configure fonts on Arch Linux based on a community guide.
# It handles pacman installations, AUR packages, and system-wide font configuration.

# --- SCRIPT PRE-CHECKS AND VARIABLES ---


# Font configuration requires writing to system directories like /etc.


# Define font packages to install from the official Arch repositories
OFFICIAL_FONTS=(
    "fontconfig"
    "ttf-liberation"
    "noto-fonts"
    "noto-fonts-emoji"
    "otf-font-awesome"
    "ttf-hack-nerd"
)

# Define font packages to install from the AUR
AUR_FONTS=(
    "ttf-ms-fonts"
    "ttf-google-fonts-git"
    "ttf-material-design-icons-git"
)

# --- FONT INSTALLATION ---

echo "--- Installing fonts from official Arch repositories ---"
# Install the necessary font packages using pacman.
# --noconfirm is used for automation, but the user should be aware.
# -Syu ensures the system is up-to-date before installing.
# It's highly recommended to let fontconfig stay, as it's a critical dependency.
sudo pacman -Syu --noconfirm "${OFFICIAL_FONTS[@]}"

echo "--- Installation complete for official packages. ---"
echo ""

# Ask the user which AUR helper they have.
echo "--- Installing fonts from the Arch User Repository (AUR) ---"
read -p "Please enter the name of your AUR helper (e.g., yay or paru): " AUR_HELPER

# Validate the AUR helper input
if [ -z "$AUR_HELPER" ]; then
    echo "No AUR helper specified. Skipping AUR font installation."
else
    # Check if the chosen helper exists
    if ! command -v "$AUR_HELPER" &> /dev/null; then
        echo "The command '$AUR_HELPER' was not found. Please make sure it's installed and in your PATH."
        echo "Skipping AUR font installation."
    else
        # Install AUR fonts using the specified helper
        echo "Using '$AUR_HELPER' to install AUR fonts..."
        "$AUR_HELPER" -S --noconfirm "${AUR_FONTS[@]}"
        echo "--- Installation complete for AUR packages. ---"
    fi
fi
echo ""

# --- FONT HINTING & ALIASING CONFIGURATION ---

echo "--- Configuring system-wide font rendering settings ---"

# Create a new configuration file for FreeType font rendering properties.
# This improves font hinting and appearance.
# Note: The guide also mentions 'infinality', which is a deprecated project.
# The 'interpreter-version=40' setting is the modern, recommended approach.
echo "Creating /etc/profile.d/freetype2.sh for interpreter-version=40..."
echo 'export FREETYPE_PROPERTIES="truetype:interpreter-version=40"' > /etc/profile.d/freetype2.sh

# Create the font configuration file for anti-aliasing and hinting settings.
# This file configures how fonts are rendered system-wide.
echo "Creating /etc/fonts/local.conf to enable hinting and anti-aliasing..."
cat > /etc/fonts/local.conf << EOL
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
    <!-- Enable sub-pixel rendering (cleartype) -->
    <match target="font">
        <edit name="rgba" mode="assign">
            <const>rgb</const>
        </edit>
    </match>
    <!-- Enable anti-aliasing (smooth edges) -->
    <match target="font">
        <edit name="antialias" mode="assign">
            <bool>true</bool>
        </edit>
    </match>
    <!-- Use a lighter hinting style for better clarity -->
    <match target="font">
        <edit name="hintstyle" mode="assign">
            <const>hintslight</const>
        </edit>
    </match>
    <!-- Use a suitable LCD filter for cleartext fonts -->
    <match target="font">
        <edit name="lcdfilter" mode="assign">
            <const>lcddefault</const>
        </edit>
    </match>
</fontconfig>
EOL

echo "--- Font configuration files created. ---"
echo ""

# --- FONT CACHE REGENERATION ---

echo "--- Regenerating the font cache ---"
# This command forces fontconfig to rebuild the cache, applying the new settings.
fc-cache -fv
echo "--- Font cache regenerated. All done! ---"
echo ""

echo "You may now need to log out and log back in, or reboot your system, for all changes to take effect."
echo "You can also adjust font settings manually in KDE Plasma's System Settings."
