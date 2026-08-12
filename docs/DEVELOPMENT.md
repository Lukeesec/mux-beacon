# Development

## Build and verify

```sh
swift build
swift run mux-beacon-self-test
./scripts/build-app.sh
codesign --verify --deep --strict "dist/Mux Beacon.app"
```

The self-test executable is dependency-free so it also runs on standalone Command Line Tools installs, which do not ship XCTest or Swift Testing. It validates provider fixtures, state persistence, duration, installer idempotency/uninstall, and export escaping.

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

The app snapshots only its own content view. Use `MUX_BEACON_HOME` to point the app at a scratch data directory so screenshots never include real events.

## Release signing

`scripts/build-app.sh` uses an ad-hoc signature by default. Set `MUX_BEACON_SIGNING_IDENTITY` to a Developer ID Application identity for hardened-runtime signing. Notarization credentials are intentionally supplied only through CI secrets.
