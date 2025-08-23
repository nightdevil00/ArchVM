#!/bin/bash

# Export Pacman explicitly installed packages
echo "Exporting explicitly installed Pacman packages to pacman_explicit_packages.txt..."
pacman -Qqe > pacman_explicit_packages.txt
echo "Done."

# Export user-installed Flatpak applications
echo "Exporting user-installed Flatpak applications to flatpak_user_apps.txt..."
flatpak list --app --columns=application > flatpak_user_apps.txt
echo "Done."

# Export user-installed Flatpak runtimes
echo "Exporting user-installed Flatpak runtimes to flatpak_user_runtimes.txt..."
flatpak list --runtime --columns=application > flatpak_user_runtimes.txt
echo "Done."

# Export system-wide Flatpak applications (if any)
echo "Exporting system-wide Flatpak applications to flatpak_system_apps.txt (might be empty)..."
flatpak list --app --columns=application --system > flatpak_system_apps.txt
echo "Done."

# Export system-wide Flatpak runtimes (if any)
echo "Exporting system-wide Flatpak runtimes to flatpak_system_runtimes.txt (might be empty)..."
flatpak list --runtime --columns=application --system > flatpak_system_runtimes.txt
echo "Done."

echo "All package lists exported successfully to your current directory."
