# Troubleshooting

## Notifications do not appear

Open **System Settings → Notifications → Mux Beacon** and enable notifications. Select **Alerts**, rather than **Banners**, when they should remain until dismissed. Focus and Do Not Disturb can delay or suppress presentation. Run:

```sh
mux-beacon test start --source codex
mux-beacon test ready --source codex
```

Start notifications are off by default. Enable them with `mux-beacon notifications start on` before testing `start`.

## The GUI does not appear

Mux Beacon normally lives in the menu bar. Open its beacon icon or run:

```sh
mux-beacon gui
```

The local installer registers the app with Launch Services and asks Spotlight to import it. Locally ad-hoc-signed builds may not appear in search immediately; `mux-beacon gui` bypasses search entirely. Re-run `./scripts/install-local.sh` if an older `~/Applications` installation is still being used.

## Codex events do not arrive

Codex requires new or modified command hooks to be trusted. Open `/hooks`, review Mux Beacon, and trust it. `mux-beacon doctor` confirms whether the definition exists; it cannot bypass Codex's trust decision.

## A click cannot find Ghostty

Allow Mux Beacon under **System Settings → Privacy & Security → Automation**. Ghostty 1.3 routing is captured when `UserPromptSubmit` fires while Ghostty is frontmost. Mux Beacon refuses to guess if that capture is unavailable.

## A pane no longer exists

Pane IDs are stable only for the pane's lifetime. The event remains in history, but navigation becomes stale after the pane is destroyed.

Demo records use fictional targets and cannot be opened. They are marked `DEMO`; remove them with **Clear demo** in the GUI or `mux-beacon clear-demo`.

## Restore pane borders

```sh
mux-beacon tmux disable-badges
```

Mux Beacon restores the exact values saved when badges were enabled.

## Inspect logs and data

```sh
open "$HOME/Library/Application Support/Mux Beacon"
mux-beacon status
mux-beacon doctor
```
