#!/bin/bash
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/applications/icons"

# ── Step 1: create directories ──
mkdir -p "$BIN_DIR" "$APP_DIR" "$ICON_DIR"

# ── Step 2: install scripts to ~/.local/bin ──

cat >"$BIN_DIR/niri-launch-webapp" <<'SCRIPT'
#!/bin/bash
browser=$(xdg-settings get default-web-browser)
case $browser in
google-chrome*|brave*|microsoft-edge*|opera*|vivaldi*|helium*) ;;
*) browser="chromium.desktop" ;;
esac
exec setsid -- $(sed -n 's/^Exec=\([^ ]*\).*/\1/p' \
  {~/.local,~/.nix-profile,/usr}/share/applications/$browser 2>/dev/null | head -1) \
  --app="$1" "${@:2}"
SCRIPT

cat >"$BIN_DIR/niri-launch-or-focus" <<'SCRIPT'
#!/bin/bash
if (($# == 0)); then
  echo "Usage: niri-launch-or-focus [window-pattern] [launch-command]" >&2; exit 1
fi
WINDOW_PATTERN="$1"
LAUNCH_COMMAND="${2:-niri msg action spawn -- $WINDOW_PATTERN}"
WINDOW_ID=$(niri msg windows | awk -v p="$WINDOW_PATTERN" '
  /^Window ID [0-9]+/ { id = $3; gsub(/:/,"",id) }
  $1=="App" && tolower($0)~tolower(p) { print id; exit }
  $1=="Title:" {
    title=$0; gsub(/^Title: "|"$/,"",title)
    if(tolower(title)~tolower(p)) { print id; exit }
  }')
if [[ -n $WINDOW_ID ]]; then niri msg action focus-window "$WINDOW_ID"
else eval exec setsid $LAUNCH_COMMAND; fi
SCRIPT

cat >"$BIN_DIR/niri-launch-or-focus-webapp" <<'SCRIPT'
#!/bin/bash
if (($# == 0)); then
  echo "Usage: niri-launch-or-focus-webapp [window-pattern] [url-and-flags...]" >&2
  exit 1
fi
WINDOW_PATTERN="$1"; shift
exec niri-launch-or-focus "$WINDOW_PATTERN" "niri-launch-webapp $@"
SCRIPT

cat >"$BIN_DIR/niri-webapp-handler-hey" <<'SCRIPT'
#!/bin/bash
url="$1"; web_url="https://app.hey.com"
if [[ $url =~ ^mailto: ]]; then
  email=$(echo "$url" | sed 's/mailto://')
  web_url="https://app.hey.com/messages/new?to=$email"
fi
exec niri-launch-webapp "$web_url"
SCRIPT

cat >"$BIN_DIR/niri-webapp-handler-zoom" <<'SCRIPT'
#!/bin/bash
url="$1"; web_url="https://app.zoom.us/wc/home"
if [[ $url =~ ^zoom(mtg|us):// ]]; then
  confno=$(echo "$url" | sed -n 's/.*[?&]confno=\([^&]*\).*/\1/p')
  if [[ -n $confno ]]; then
    pwd=$(echo "$url" | sed -n 's/.*[?&]pwd=\([^&]*\).*/\1/p')
    if [[ -n $pwd ]]; then web_url="https://app.zoom.us/wc/join/$confno?pwd=$pwd"
    else web_url="https://app.zoom.us/wc/join/$confno"; fi
  fi
fi
exec niri-launch-webapp "$web_url"
SCRIPT

cat >"$BIN_DIR/niri-webapp-remove" <<'SCRIPT'
#!/bin/bash
set -e
if (( $# == 0 )); then
  echo "Usage: niri-webapp-remove <name...>" >&2
  for f in "$HOME/.local/share/applications/"*.desktop; do
    grep -q '^Exec=.*\(niri-launch-webapp\|niri-webapp-handler\).*' "$f" 2>/dev/null &&
      basename "$f" .desktop
  done; exit 1
fi
for APP_NAME in "$@"; do
  rm -f "$HOME/.local/share/applications/$APP_NAME.desktop"
  rm -f "$HOME/.local/share/applications/icons/$APP_NAME.png"
  echo "Removed $APP_NAME"
done
SCRIPT

cat >"$BIN_DIR/niri-window-close-all" <<'SCRIPT'
#!/bin/bash
niri msg windows | awk '/^Window ID [0-9]+/{id=$3;gsub(/:/,"",id);print id}' |
  while read -r id; do niri msg action focus-window "$id" && niri msg action close-window; done
niri msg action focus-workspace 1
SCRIPT

chmod +x "$BIN_DIR/niri-launch-webapp" "$BIN_DIR/niri-launch-or-focus" \
        "$BIN_DIR/niri-launch-or-focus-webapp" \
        "$BIN_DIR/niri-webapp-handler-hey" "$BIN_DIR/niri-webapp-handler-zoom" \
        "$BIN_DIR/niri-webapp-remove" "$BIN_DIR/niri-window-close-all"

# ── Step 3: download icons ──

declare -A ICONS
ICONS=(
  [HEY]=https://dashboardicons.com/DALL-E_AI_Icon_HEY.png
  [Basecamp]=https://dashboardicons.com/DALL-E_AI_Icon_Basecamp.png
  [WhatsApp]=https://dashboardicons.com/DALL-E_AI_Icon_WhatsApp.png
  [Google\ Photos]=https://dashboardicons.com/DALL-E_AI_Icon_Google_Photos.png
  [Google\ Contacts]=https://dashboardicons.com/DALL-E_AI_Icon_Google_Contacts.png
  [Google\ Messages]=https://dashboardicons.com/DALL-E_AI_Icon_Google_Messages.png
  [Google\ Maps]=https://dashboardicons.com/DALL-E_AI_Icon_Google_Maps.png
  [ChatGPT]=https://dashboardicons.com/DALL-E_AI_Icon_ChatGPT.png
  [YouTube]=https://dashboardicons.com/DALL-E_AI_Icon_YouTube.png
  [GitHub]=https://dashboardicons.com/DALL-E_AI_Icon_GitHub.png
  [X]=https://dashboardicons.com/DALL-E_AI_Icon_X.png
  [Figma]=https://dashboardicons.com/DALL-E_AI_Icon_Figma.png
  [Discord]=https://dashboardicons.com/DALL-E_AI_Icon_Discord.png
  [Zoom]=https://dashboardicons.com/DALL-E_AI_Icon_Zoom.png
  [Fizzy]=https://dashboardicons.com/DALL-E_AI_Icon_Fizzy.png
)

echo "Downloading icons..."
for name in "${!ICONS[@]}"; do
  dest="$ICON_DIR/$name.png"
  if [[ ! -f $dest ]]; then
    curl -fsSL -o "$dest" "${ICONS[$name]}" && echo "  $name" || echo "  $name (failed)"
  fi
done

# Fallback: use Google favicons for anything missing
for name in "${!ICONS[@]}"; do
  dest="$ICON_DIR/$name.png"
  if [[ ! -s $dest ]]; then
    case $name in
      HEY)          url="https://app.hey.com" ;;
      Basecamp)     url="https://launchpad.37signals.com" ;;
      WhatsApp)     url="https://web.whatsapp.com" ;;
      Google\ Photos) url="https://photos.google.com" ;;
      Google\ Contacts) url="https://contacts.google.com" ;;
      Google\ Messages) url="https://messages.google.com" ;;
      Google\ Maps) url="https://maps.google.com" ;;
      ChatGPT)      url="https://chatgpt.com" ;;
      YouTube)      url="https://youtube.com" ;;
      GitHub)       url="https://github.com" ;;
      X)            url="https://x.com" ;;
      Figma)        url="https://figma.com" ;;
      Discord)      url="https://discord.com" ;;
      Zoom)         url="https://zoom.us" ;;
      Fizzy)        url="https://app.fizzy.do" ;;
    esac
    favicon="https://www.google.com/s2/favicons?domain=$url&sz=128"
    curl -fsSL -o "$dest" "$favicon" 2>/dev/null && echo "  $name (favicon)"
  fi
done

# ── Step 4: create .desktop files ──

install_webapp() {
  local name="$1" url="$2" icon="$3" custom_exec="$4" mime_types="$5"
  local exec_cmd

  if [[ -n $custom_exec ]]; then
    exec_cmd=""
    for word in $custom_exec; do
      if [[ -x $BIN_DIR/$word ]]; then exec_cmd+="$BIN_DIR/$word "
      else exec_cmd+="$word "; fi
    done
    exec_cmd="${exec_cmd% }"
  else
    exec_cmd="$BIN_DIR/niri-launch-webapp $url"
  fi

  cat >"$APP_DIR/$name.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=$name
Comment=$name
Exec=$exec_cmd
Terminal=false
Type=Application
Icon=$ICON_DIR/$icon
StartupNotify=true
EOF
  if [[ -n $mime_types ]]; then
    echo "MimeType=$mime_types" >>"$APP_DIR/$name.desktop"
  fi
  chmod +x "$APP_DIR/$name.desktop"
  echo "  $name"
}

echo "Creating desktop files..."
install_webapp "HEY"             https://app.hey.com                        "HEY.png"             "niri-webapp-handler-hey %u" "x-scheme-handler/mailto"
install_webapp "Basecamp"        https://launchpad.37signals.com            "Basecamp.png"        "" ""
install_webapp "WhatsApp"        https://web.whatsapp.com/                  "WhatsApp.png"        "" ""
install_webapp "Google Photos"   https://photos.google.com/                 "Google Photos.png"   "" ""
install_webapp "Google Contacts" https://contacts.google.com/               "Google Contacts.png" "" ""
install_webapp "Google Messages" https://messages.google.com/web/conversations "Google Messages.png" "" ""
install_webapp "Google Maps"     https://maps.google.com                    "Google Maps.png"     "" ""
install_webapp "ChatGPT"         https://chatgpt.com/                       "ChatGPT.png"         "" ""
install_webapp "YouTube"         https://youtube.com/                       "YouTube.png"         "" ""
install_webapp "GitHub"          https://github.com/                        "GitHub.png"          "" ""
install_webapp "X"               https://x.com/                             "X.png"               "" ""
install_webapp "Figma"           https://figma.com/                         "Figma.png"           "" ""
install_webapp "Discord"         https://discord.com/channels/@me           "Discord.png"         "" ""
install_webapp "Zoom"            https://app.zoom.us/wc/home                "Zoom.png"            "niri-webapp-handler-zoom %u" "x-scheme-handler/zoommtg;x-scheme-handler/zoomus"
install_webapp "Fizzy"           https://app.fizzy.do/                      "Fizzy.png"           "" ""

# ── Step 5: add ~/.local/bin to PATH ──

if ! grep -qs '\.local/bin' "$HOME/.bashrc"; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  echo "Added ~/.local/bin to PATH in ~/.bashrc"
fi

export PATH="$HOME/.local/bin:$PATH"

# ── Step 6: update desktop database ──

if command -v update-desktop-database &>/dev/null; then
  update-desktop-database "$APP_DIR" 2>/dev/null || true
fi

# Restart dms so it picks up the new desktop files
if pgrep -x dms &>/dev/null; then
  dms restart 2>/dev/null || true
fi

# ── done ──
echo ""
echo "All done — 15 webapps installed and ready."
echo "PATH updated for this session. Open your app launcher (Mod+Space) to see them."
