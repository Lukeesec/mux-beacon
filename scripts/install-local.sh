#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
source_app="$repo_root/dist/Mux Beacon.app"
if [[ -n ${MUX_BEACON_INSTALL_DIR:-} ]]; then
  destination_root="$MUX_BEACON_INSTALL_DIR"
elif [[ -w /Applications ]]; then
  destination_root="/Applications"
else
  destination_root="$HOME/Applications"
fi
destination_app="$destination_root/Mux Beacon.app"
cli_directory="$HOME/.local/bin"

"$repo_root/scripts/build-app.sh"
mkdir -p "$destination_root" "$cli_directory"
osascript -e 'tell application id "com.lukeesec.MuxBeacon" to quit' >/dev/null 2>&1 || true
for _ in {1..40}; do
  pgrep -x MuxBeaconApp >/dev/null || break
  sleep 0.05
done
ditto "$source_app" "$destination_app"
ln -sfn "$destination_app/Contents/Helpers/mux-beacon" "$cli_directory/mux-beacon"
launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$launch_services" -f "$destination_app"
mdimport "$destination_app" >/dev/null 2>&1 || true
open -gj "$destination_app" --args --background

echo "Installed $destination_app"
echo "CLI: $cli_directory/mux-beacon"
echo "Preview hook changes with: mux-beacon install"
echo "Apply them with: mux-beacon install --apply"
