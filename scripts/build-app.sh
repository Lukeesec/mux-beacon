#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
configuration=${CONFIGURATION:-release}
app_path="$repo_root/dist/Mux Beacon.app"

cd "$repo_root"
swift build -c "$configuration" --product MuxBeaconApp
swift build -c "$configuration" --product mux-beacon
bin_path=$(swift build -c "$configuration" --show-bin-path)

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Helpers" "$app_path/Contents/Resources"
cp "$repo_root/Packaging/Info.plist" "$app_path/Contents/Info.plist"
cp "$repo_root/Assets/MuxBeacon.icns" "$app_path/Contents/Resources/MuxBeacon.icns"
cp "$bin_path/MuxBeaconApp" "$app_path/Contents/MacOS/MuxBeaconApp"
cp "$bin_path/mux-beacon" "$app_path/Contents/Helpers/mux-beacon"
chmod 755 "$app_path/Contents/MacOS/MuxBeaconApp" "$app_path/Contents/Helpers/mux-beacon"

if [[ -n ${MUX_BEACON_SIGNING_IDENTITY:-} ]]; then
  codesign --force --deep --options runtime --entitlements "$repo_root/Packaging/MuxBeacon.entitlements" --sign "$MUX_BEACON_SIGNING_IDENTITY" "$app_path"
else
  codesign --force --deep --sign - "$app_path"
fi

echo "$app_path"
