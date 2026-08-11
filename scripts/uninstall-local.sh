#!/bin/zsh
set -euo pipefail

cli_path="$HOME/.local/bin/mux-beacon"

if [[ -x "$cli_path" ]]; then
  "$cli_path" uninstall --apply
fi

if [[ -L "$cli_path" ]]; then
  unlink "$cli_path"
fi
osascript -e 'tell application "Mux Beacon" to quit' 2>/dev/null || true
timestamp=$(date +%Y%m%d-%H%M%S)
for app_path in "/Applications/Mux Beacon.app" "$HOME/Applications/Mux Beacon.app"; do
  if [[ -d "$app_path" ]]; then
    if [[ "$app_path" == /Applications/* ]]; then
      location="system"
    else
      location="user"
    fi
    mv "$app_path" "$HOME/.Trash/Mux Beacon.$location.$timestamp.app"
  fi
done

echo "Removed hooks and moved the app to Trash. Local history remains in Library/Application Support/Mux Beacon."
