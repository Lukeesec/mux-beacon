#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
source_app="$repo_root/dist/Mux Beacon.app"
destination_root="$HOME/Applications"
destination_app="$destination_root/Mux Beacon.app"
cli_directory="$HOME/.local/bin"

"$repo_root/scripts/build-app.sh"
mkdir -p "$destination_root" "$cli_directory"
osascript -e 'tell application id "com.lukeesec.MuxBeacon" to quit' >/dev/null 2>&1 || true
ditto "$source_app" "$destination_app"
ln -sfn "$destination_app/Contents/Helpers/mux-beacon" "$cli_directory/mux-beacon"
open -gj "$destination_app"

echo "Installed $destination_app"
echo "CLI: $cli_directory/mux-beacon"
echo "Preview hook changes with: mux-beacon install"
echo "Apply them with: mux-beacon install --apply"
