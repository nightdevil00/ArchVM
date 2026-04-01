#!/bin/bash

# Installer for Nautilus custom scripts
# Works on Arch Linux (and derivatives)

SCRIPT_DIR="$HOME/.local/share/nautilus/scripts"
CREATE_FILE="$SCRIPT_DIR/Create File"
OPEN_TERM="$SCRIPT_DIR/Open Terminal Here"

echo "[*] Installing Nautilus custom scripts..."

# Ensure zenity is installed (needed for Create File)
if ! command -v zenity &>/dev/null; then
    echo "[*] Installing zenity..."
    sudo pacman -S --noconfirm zenity || {
        echo "[!] Failed to install zenity. Exiting."
        exit 1
    }
fi

# Create scripts directory if missing
mkdir -p "$SCRIPT_DIR"

# -------------------------------
# Script 1: Create File
# -------------------------------
cat > "$CREATE_FILE" <<'EOF'
#!/bin/bash

# Get the current directory Nautilus was opened in
current_dir="$(pwd)"

# Prompt the user for filename (with extension)
filename=$(zenity --entry --title="Create File" --text="Enter file name (with extension):")

# Exit if nothing entered
[ -z "$filename" ] && exit 0

# If file already exists, ask confirmation
if [ -e "$current_dir/$filename" ]; then
    zenity --question --title="File Exists" --text="File '$filename' already exists. Overwrite?"
    if [ $? -ne 0 ]; then
        exit 0
    fi
fi

# Create the file
touch "$current_dir/$filename"

# Success message
zenity --info --title="File Created" --text="File '$filename' created in:\n$current_dir"
EOF

chmod +x "$CREATE_FILE"
echo "[✓] Installed: Create File script"


# -------------------------------
# Script 2: Open Terminal Here
# -------------------------------
cat > "$OPEN_TERM" <<'EOF'
#!/bin/bash
# Open Terminal Here script

TERMINAL="${TERMINAL:-}"

if [ -n "$TERMINAL" ]; then
    exec "$TERMINAL"
elif command -v xdg-terminal-exec >/dev/null 2>&1; then
    exec xdg-terminal-exec
elif command -v alacritty >/dev/null 2>&1; then
    exec alacritty
elif command -v konsole >/dev/null 2>&1; then
    exec konsole
else
    exec gnome-terminal
fi
EOF

chmod +x "$OPEN_TERM"
echo "[✓] Installed: Open Terminal Here script"


echo
echo "[✓] Installation complete!"
echo "   → Right-click inside Nautilus → Scripts → Create File"
echo "   → Right-click inside Nautilus → Scripts → Open Terminal Here"

