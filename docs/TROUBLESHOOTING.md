# Troubleshooting

## Notifications do not appear

Open **System Settings → Notifications → Mux Beacon** and enable notifications. Select **Alerts**, rather than **Banners**, when they should remain until dismissed. Focus and Do Not Disturb can delay or suppress presentation. Run:

```sh
mux-beacon test start --source codex
mux-beacon test ready --source codex
```

Start notifications are off by default. Enable them with `mux-beacon notifications start on` before testing `start`.

Starting the Codex or Claude application does not itself fire `UserPromptSubmit`. Submit a prompt to create the Working event. Completion notifications are on by default; Claude uses its `Stop` hook and Codex uses its turn-complete callback. Confirm the installed definitions and preferences with:

```sh
mux-beacon doctor
mux-beacon notifications status
```

## The GUI does not appear

Mux Beacon normally lives in the menu bar. Open its beacon icon or run:

```sh
mux-beacon gui
```

The local installer registers the app with Launch Services and asks Spotlight to import it. Locally ad-hoc-signed builds may not appear in search immediately; `mux-beacon gui` bypasses search entirely. Re-run `./scripts/install-local.sh` if an older `~/Applications` installation is still being used.

## Codex events do not arrive

Codex requires new or modified command hooks to be trusted. Open `/hooks`, review Mux Beacon, and trust it. `mux-beacon doctor` confirms whether the definition exists; it cannot bypass Codex's trust decision.

`mux-beacon doctor` also reports the last event actually received from each agent and the separate Codex completion callback status. If the callback says **not installed**, run `mux-beacon install --apply`, then start a new Codex process. If another command is configured, Mux Beacon leaves it untouched; that notifier must forward Codex's JSON payload to `mux-beacon codex-notify` or be removed before reinstalling Mux Beacon.

Codex trusts the exact lifecycle hook definition. If `UserPromptSubmit` is also missing after a new prompt, open `/hooks`, review Mux Beacon, and trust it again.

## A click cannot find Ghostty

Allow Mux Beacon under **System Settings → Privacy & Security → Automation**. Ghostty 1.3 routing is captured when `UserPromptSubmit` fires while Ghostty is frontmost. Mux Beacon refuses to guess if that capture is unavailable.

## A pane no longer exists

Pane IDs are stable only for the pane's lifetime. The event remains in history, but navigation becomes stale after the pane is destroyed.

Click **Refresh** or run `mux-beacon health` to reconcile immediately; the app also checks every 30 seconds. Superseded turns and dead tmux targets move to **History** and are no longer clickable.

Demo records use fictional targets and cannot be opened. They are marked `DEMO`; remove them with `mux-beacon clear-demo`.

## Older running agents are missing

Mux Beacon receives lifecycle hooks; it does not inspect or reconstruct the state of arbitrary existing processes. Agents that were already running before hook installation appear after their next hook-enabled prompt. New Claude or Codex processes load the current hook configuration automatically; an older process may need to be restarted or reloaded.

## Restore pane borders

Pane-border badges are off until enabled for the current tmux server:

```sh
mux-beacon tmux badge-status
mux-beacon tmux enable-badges
```

Codex and Claude use the same pane state. If `badge-status` reports tracked panes but badges are disabled, enable them from inside that tmux server.

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
