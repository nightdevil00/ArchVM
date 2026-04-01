#!/bin/bash
# This script provides an analysis of the omarchy installation process.
# It maps the purpose of each script sourced by install.sh,
# identifies packages installed, and notes file modifications/copies.

# --- Main Installer: omarchy/install.sh ---
# Purpose: Orchestrates the entire Omarchy setup.
# Actions:
#   - Sets OMARCHY_PATH and OMARCHY_INSTALL variables.
#   - Adds OMARCHY_PATH/bin to the system PATH.
#   - Sources various scripts for preparation, packaging, configuration, login, and finishing.

# --- Sourced Scripts Analysis ---

# 1. Preparation Scripts (omarchy/install/preflight/)

# omarchy/install/preflight/show-env.sh
# Purpose: Displays environment variables relevant to the installation.
# Actions: Prints environment variables to stdout.
# Packages: None.
# Files Modified/Copied: None.

# omarchy/install/preflight/trap-errors.sh
# Purpose: Sets up error trapping to exit on non-zero status.
# Actions: Uses 'set -eE' and defines a trap for ERR signal.
# Packages: None.
# Files Modified/Copied: None.

# omarchy/install/preflight/guard.sh
# Purpose: Performs initial checks to ensure the environment is suitable for installation.
# Actions: Checks for root privileges, internet connection, etc.
# Packages: None.
# Files Modified/Copied: None.

# omarchy/install/preflight/chroot.sh
# Purpose: Detects if the script is running inside a chroot environment.
# Actions: Sets a CHROOT_ENV variable.
# Packages: None.
# Files Modified/Copied: None.

# omarchy/install/preflight/pacman.sh
# Purpose: Configures pacman for the installation.
# Actions: Initializes pacman keyring, installs archlinux-keyring, sets up parallel downloads.
# Packages: archlinux-keyring (installed if not present).
# Files Modified/Copied: /etc/pacman.conf (modified for parallel downloads).

# omarchy/install/preflight/migrations.sh
# Purpose: Handles migrations for previous Omarchy versions.
# Actions: Executes migration scripts if necessary.
# Packages: None.
# Files Modified/Copied: Depends on migration scripts.

# omarchy/install/preflight/first-run-mode.sh
# Purpose: Determines if this is the first run of the installer.
# Actions: Sets a FIRST_RUN_MODE variable.
# Packages: None.
# Files Modified/Copied: None.

# 2. Packaging Scripts (omarchy/install/packaging/)

# omarchy/install/packages.sh
# Purpose: Installs core system and desktop environment packages.
# Actions: Uses 'sudo pacman -S --noconfirm --needed' to install a long list of packages.
# Packages: (See detailed list below - will be extracted from this file)
#     - 1password-beta
#     - 1password-cli
#     - asdcontrol-git
#     - alacritty
#     - avahi
#     - bash-completion
#     - bat
#     - blueberry
#     - brightnessctl
#     - btop
#     - cargo
#     - clang
#     - cups
#     - cups-browsed
#     - cups-filters
#     - cups-pdf
#     - docker
#     - docker-buildx
#     - docker-compose
#     - dust
#     - evince
#     - eza
#     - fastfetch
#     - fcitx5
#     - fcitx5-gtk
#     - fcitx5-qt
#     - fd
#     - ffmpegthumbnailer
#     - fontconfig
#     - fzf
#     - gcc14
#     - github-cli
#     - gnome-calculator
#     - gnome-keyring
#     - gnome-themes-extra
#     - gum
#     - gvfs-mtp
#     - gvfs-smb
#     - hypridle
#     - hyprland
#     - hyprland-qtutils
#     - hyprlock
#     - hyprpicker
#     - hyprshot
#     - hyprsunset
#     - imagemagick
#     - impala
#     - imv
#     - inetutils
#     - iwd
#     - jq
#     - kdenlive
#     - kvantum-qt5
#     - lazydocker
#     - lazygit
#     - less
#     - libqalculate
#     - libreoffice
#     - llvm
#     - localsend
#     - luarocks
#     - mako
#     - man
#     - mariadb-libs
#     - mise
#     - mpv
#     - nautilus
#     - noto-fonts
#     - noto-fonts-cjk
#     - noto-fonts-emoji
#     - noto-fonts-extra
#     - nss-mdns
#     - nvim
#     - obs-studio
#     - obsidian
#     - omarchy-chromium
#     - pamixer
#     - pinta
#     - playerctl
#     - plocate
#     - plymouth
#     - polkit-gnome
#     - postgresql-libs
#     - power-profiles-daemon
#     - python-gobject
#     - python-poetry-core
#     - python-terminaltexteffects
#     - qt5-wayland
#     - ripgrep
#     - satty
#     - signal-desktop
#     - slurp
#     - spotify
#     - starship
#     - sushi
#     - swaybg
#     - swayosd
#     - system-config-printer
#     - tldr
#     - tree-sitter-cli
#     - ttf-cascadia-mono-nerd
#     - ttf-ia-writer
#     - ttf-jetbrains-mono-nerd
#     - typora
#     - tzupdate
#     - ufw
#     - ufw-docker
#     - unzip
#     - uwsm
#     - walker-bin
#     - waybar
#     - wf-recorder
#     - whois
#     - wiremix
#     - wireplumber
#     - wl-clip-persist
#     - wl-clipboard
#     - wl-screenrec
#     - woff2-font-awesome
#     - xdg-desktop-portal-gtk
#     - xdg-desktop-portal-hyprland
#     - xmlstarlet
#     - xournalpp
#     - yaru-icon-theme
#     - yay
#     - zoxide
# Files Modified/Copied: None directly, but system packages are installed.

# omarchy/install/packaging/fonts.sh
# Purpose: Installs and configures fonts.
# Actions: Copies fonts, rebuilds font cache.
# Packages: None directly, but relies on font packages being installed.
# Files Modified/Copied: /usr/share/fonts/ (copies fonts), font cache.

# omarchy/install/packaging/lazyvim.sh
# Purpose: Installs and configures LazyVim (Neovim setup).
# Actions: Clones LazyVim, runs Neovim setup.
# Packages: None directly, relies on Neovim being installed.
# Files Modified/Copied: ~/.config/nvim/ (LazyVim configuration).

# omarchy/install/packaging/webapps.sh
# Purpose: Installs web applications (e.g., browser extensions, PWAs).
# Actions: Downloads and installs web app related files.
# Packages: None directly.
# Files Modified/Copied: ~/.local/share/applications/ (creates .desktop files), browser profiles.

# omarchy/install/packaging/tuis.sh
# Purpose: Installs Terminal User Interface (TUI) applications.
# Actions: Installs various TUI tools.
# Packages: None directly.
# Files Modified/Copied: None directly.

# 3. Configuration Scripts (omarchy/install/config/)

# omarchy/install/config/config.sh
# Purpose: Copies core configuration files (dotfiles) to the user's home directory.
# Actions: Copies files from omarchy/config to ~/.config, ~/.local/share, etc.
# Packages: None.
# Files Modified/Copied: ~/.config/, ~/.local/share/, etc.

# omarchy/install/config/theme.sh
# Purpose: Sets up the system theme.
# Actions: Configures GTK, Qt, icon themes.
# Packages: None.
# Files Modified/Copied: ~/.config/gtk-3.0/, ~/.config/gtk-4.0/, ~/.config/qt5ct/, ~/.config/qt6ct/.

# omarchy/install/config/branding.sh
# Purpose: Applies Omarchy branding.
# Actions: Sets wallpaper, login screen background, etc.
# Packages: None.
# Files Modified/Copied: Wallpaper files, display manager config.

# omarchy/install/config/git.sh
# Purpose: Configures Git.
# Actions: Sets Git user name, email, default editor.
# Packages: None.
# Files Modified/Copied: ~/.gitconfig.

# omarchy/install/config/gpg.sh
# Purpose: Configures GPG.
# Actions: Sets up GPG agent, imports keys.
# Packages: None.
# Files Modified/Copied: ~/.gnupg/.n

# omarchy/install/config/timezones.sh
# Purpose: Sets the system timezone.
# Actions: Links /etc/localtime.
# Packages: None.
# Files Modified/Copied: /etc/localtime.

# omarchy/install/config/increase-sudo-tries.sh
# Purpose: Increases the number of sudo password attempts.
# Actions: Modifies sudoers configuration.
# Packages: None.
# Files Modified/Copied: /etc/sudoers.d/.

# omarchy/install/config/increase-lockout-limit.sh
# Purpose: Increases account lockout limit.
# Actions: Modifies PAM configuration.
# Packages: None.
# Files Modified/Copied: /etc/pam.d/.

# omarchy/install/config/ssh-flakiness.sh
# Purpose: Addresses SSH connection flakiness.
# Actions: Modifies SSH client configuration.
# Packages: None.
# Files Modified/Copied: ~/.ssh/config.

# omarchy/install/config/detect-keyboard-layout.sh
# Purpose: Detects and sets keyboard layout.
# Actions: Configures Xorg and Wayland keyboard settings.
# Packages: None.
# Files Modified/Copied: /etc/X11/xorg.conf.d/, Wayland compositor config.

# omarchy/install/config/xcompose.sh
# Purpose: Configures XCompose.
# Actions: Sets XCompose file.
# Packages: None.
# Files Modified/Copied: ~/.XCompose.

# omarchy/install/config/mise-ruby.sh
# Purpose: Configures Mise (version manager) for Ruby.
# Actions: Installs Ruby versions via Mise.
# Packages: None directly, relies on Mise.
# Files Modified/Copied: ~/.config/mise/.

# omarchy/install/config/docker.sh
# Purpose: Configures Docker.
# Actions: Adds user to docker group, enables docker service.
# Packages: None directly, relies on Docker being installed.
# Files Modified/Copied: User groups, systemd service.

# omarchy/install/config/mimetypes.sh
# Purpose: Configures MIME types.
# Actions: Sets default applications for file types.
# Packages: None.
# Files Modified/Copied: ~/.config/mimeapps.list.

# omarchy/install/config/localdb.sh
# Purpose: Sets up local database (e.g., PostgreSQL, MariaDB).
# Actions: Initializes database, creates users.
# Packages: None directly, relies on database packages.
# Files Modified/Copied: Database configuration files.

# omarchy/install/config/sudoless-asdcontrol.sh
# Purpose: Configures passwordless sudo for asdcontrol.
# Actions: Modifies sudoers configuration.
# Packages: None.
# Files Modified/Copied: /etc/sudoers.d/.

# omarchy/install/config/hardware/network.sh
# Purpose: Configures network hardware.
# Actions: Sets up NetworkManager, iwd, etc.
# Packages: None directly, relies on network packages.
# Files Modified/Copied: /etc/NetworkManager/, /etc/iwd/.

# omarchy/install/config/hardware/fix-fkeys.sh
# Purpose: Fixes function keys behavior.
# Actions: Modifies kernel parameters or udev rules.
# Packages: None.
# Files Modified/Copied: Kernel boot parameters, udev rules.

# omarchy/install/config/hardware/bluetooth.sh
# Purpose: Configures Bluetooth.
# Actions: Enables Bluetooth service, sets up devices.
# Packages: None directly, relies on Bluetooth packages.
# Files Modified/Copied: /etc/bluetooth/.

# omarchy/install/config/hardware/printer.sh
# Purpose: Configures printers.
# Actions: Enables CUPS service, adds printers.
# Packages: None directly, relies on CUPS.
# Files Modified/Copied: /etc/cups/.

# omarchy/install/config/hardware/usb-autosuspend.sh
# Purpose: Configures USB autosuspend.
# Actions: Modifies kernel parameters or udev rules.
# Packages: None.
# Files Modified/Copied: Kernel boot parameters, udev rules.

# omarchy/install/config/hardware/ignore-power-button.sh
# Purpose: Configures power button behavior.
# Actions: Modifies systemd-logind configuration.
# Packages: None.
# Files Modified/Copied: /etc/systemd/logind.conf.

# omarchy/install/config/hardware/nvidia.sh
# Purpose: Configures Nvidia graphics drivers.
# Actions: Sets up Nvidia modules, Xorg configuration.
# Packages: None directly, relies on Nvidia drivers.
# Files Modified/Copied: /etc/modprobe.d/, /etc/X11/xorg.conf.d/.

# omarchy/install/config/hardware/fix-f13-amd-audio-input.sh
# Purpose: Fixes F13 key and AMD audio input issues.
# Actions: Specific hardware fixes.
# Packages: None.
# Files Modified/Copied: Kernel boot parameters, udev rules.

# 4. Login Scripts (omarchy/install/login/)

# omarchy/install/login/plymouth.sh
# Purpose: Configures Plymouth (boot splash screen).
# Actions: Sets up Plymouth theme, rebuilds initramfs.
# Packages: None directly, relies on Plymouth.
# Files Modified/Copied: /etc/plymouth/, initramfs.

# omarchy/install/login/limine-snapper.sh
# Purpose: Configures Limine bootloader with Snapper.
# Actions: Sets up Limine, integrates with Snapper for snapshots.
# Packages: None directly, relies on Limine and Snapper.
# Files Modified/Copied: Bootloader configuration.

# omarchy/install/login/alt-bootloaders.sh
# Purpose: Configures alternative bootloaders.
# Actions: Sets up other bootloaders if detected.
# Packages: None.
# Files Modified/Copied: Bootloader configuration.

# 5. Finishing Scripts (omarchy/install/)

# omarchy/install/reboot.sh
# Purpose: Reboots the system after installation.
# Actions: Executes 'sudo reboot'.
# Packages: None.
# Files Modified/Copied: None.
