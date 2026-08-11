#!/bin/zsh
set -euo pipefail

app_path="$HOME/Applications/Mux Beacon.app"
cli_path="$HOME/.local/bin/mux-beacon"

if [[ -x "$cli_path" ]]; then
  "$cli_path" uninstall --apply
fi

if [[ -L "$cli_path" ]]; then
  unlink "$cli_path"
fi
if [[ -d "$app_path" ]]; then
  osascript -e 'tell application "Mux Beacon" to quit' 2>/dev/null || true
  mv "$app_path" "$HOME/.Trash/Mux Beacon.app.$(date +%Y%m%d-%H%M%S)"
fi

echo "Removed hooks and moved the app to Trash. Local history remains in Library/Application Support/Mux Beacon."
