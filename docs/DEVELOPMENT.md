# Development

## Build and verify

```sh
swift build
swift run mux-beacon-self-test
./scripts/build-app.sh
codesign --verify --deep --strict "dist/Mux Beacon.app"
```

This machine's standalone Command Line Tools distribution does not ship XCTest or Swift Testing modules, so the repository includes a dependency-free self-test executable. It validates provider fixtures, state persistence, duration, installer idempotency/uninstall, and export escaping.

## Deterministic UI data

```sh
mux-beacon demo
```

To render an inbox screenshot without Screen Recording permission:

```sh
MUX_BEACON_SCREENSHOT_MODE=1 \
MUX_BEACON_SCREENSHOT_PATH="$PWD/docs/assets/mux-beacon-inbox.png" \
"dist/Mux Beacon.app/Contents/MacOS/MuxBeaconApp" --screenshot
```

The app snapshots only its own content view.

## Visual thesis

Mux Beacon is a calm native instrument panel: graphite material, crisp operational typography, a single blue brand accent, and semantic state color only where it speeds scanning.

The working surface leads. Motion is limited to working-state breathing, event insertion/removal, and the tmux target flash, all respecting Reduce Motion.

## Release signing

`scripts/build-app.sh` uses an ad-hoc signature by default. Set `MUX_BEACON_SIGNING_IDENTITY` to a Developer ID Application identity for hardened-runtime signing. Notarization credentials are intentionally supplied only through CI secrets.
