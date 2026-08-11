# Troubleshooting

## Notifications do not appear

Open **System Settings → Notifications → Mux Beacon** and enable notifications. Focus and Do Not Disturb can delay or suppress presentation. Run:

```sh
mux-beacon test start --source codex
mux-beacon test ready --source codex
```

## Codex events do not arrive

Codex requires new or modified command hooks to be trusted. Open `/hooks`, review Mux Beacon, and trust it. `mux-beacon doctor` confirms whether the definition exists; it cannot bypass Codex's trust decision.

## A click cannot find Ghostty

Allow Mux Beacon under **System Settings → Privacy & Security → Automation**. Ghostty 1.3 routing is captured when `UserPromptSubmit` fires while Ghostty is frontmost. Mux Beacon refuses to guess if that capture is unavailable.

## A pane no longer exists

Pane IDs are stable only for the pane's lifetime. The event remains in history, but navigation becomes stale after the pane is destroyed.

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
