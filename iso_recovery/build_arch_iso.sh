#!/bin/bash

# This script automates the creation of a custom Arch Linux ISO.
# It installs git and includes a specified script for the root user.

set -eo pipefail

# --- Configuration ---
# The directory where the ISO build will take place.
BUILD_DIR="archiso_build_$(date +%Y%m%d)"
# The name of the profile to base the ISO on (releng is the standard).
ARCHISO_PROFILE="releng"
# The name of the script to be included.
SCRIPT_NAME="install.sh"
RESCUE_SCRIPT="archrescue.sh"


# --- Main Script ---

# 1. Check for root privileges
if [[ "${EUID}" -ne 0 ]]; then
  echo "This script needs to be run as root to use pacman and mkarchiso."
  echo "Please run with: sudo ./build_arch_iso.sh"
  exit 1
fi

# 2. Ensure archiso is installed
if ! pacman -Q archiso &>/dev/null; then
  echo "-> archiso is not installed. Installing it now..."
  pacman -Syu --noconfirm archiso
else
  echo "-> archiso is already installed."
fi

# 3. Set up the build environment
echo "-> Setting up the build directory: ${BUILD_DIR}"
# Clean up any previous build attempts
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# 4. Copy the ArchISO profile
echo "-> Copying the '${ARCHISO_PROFILE}' profile..."
cp -r "/usr/share/archiso/configs/${ARCHISO_PROFILE}/" ./profile

# 5. Customize the packages
echo "-> Adding 'git' to the package list..."
echo "git" >> ./profile/packages.x86_64
echo "nano" >> ./profile/packages.x86_64

# 6. Add the custom script
echo "-> Copying script to be included in the ISO..."
# This directory corresponds to the root user's home directory on the live ISO
mkdir -p ./profile/airootfs/root/
cp "/home/mihai/simple.sh" "./profile/airootfs/root/${SCRIPT_NAME}"
chmod +x "./profile/airootfs/root/${SCRIPT_NAME}"
echo "-> Script copied and made executable."

cp "/home/mihai/archrescue.sh" "./profile/airootfs/root/${RESCUE_SCRIPT}"
chmod +x "./profile/airootfs/root/${RESCUE_SCRIPT}"
echo "-> Script copied and made executable."

# 7. Configure auto-start
echo "-> Configuring script to auto-start on boot..."
echo "sh /root/install.sh" >> "./profile/airootfs/root/.bash_profile"
echo "-> Script configured to auto-start."

# 7. Build the ISO
echo "-> Starting the ISO build process (this can take a significant amount of time)..."
# The -v flag enables verbose output.
# The work directory (-w) and output directory (-o) are specified.
mkarchiso -v -w ./work -o ./out ./profile

# 8. Completion
echo ""
echo "✅ ISO build complete!"
echo "Your custom Arch Linux ISO is located in the '${BUILD_DIR}/out' directory."
echo "You can now burn the .iso file to a USB drive or use it in a virtual machine."

