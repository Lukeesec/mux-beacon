<img src="Assets/MuxBeaconIcon-1024.png" width="112" alt="Mux Beacon app icon" align="right">

# Mux Beacon

Know when terminal agents need you—and get back to the exact tmux target.

Mux Beacon is a native macOS menu-bar inbox for Claude Code and Codex. It uses documented lifecycle hooks and completion callbacks, records local turn duration, shows optional pane-border badges, and makes notifications actionable.

![Mux Beacon inbox showing Claude and Codex agents grouped by state](docs/assets/mux-beacon-inbox.png)

## Why it exists

A busy tmux setup can hide finished work across sessions and windows. Mux Beacon turns each agent turn into a small lifecycle:

```text
prompt submitted → working → ready / failed
                    │    └→ needs attention (optional)
                    └────── waiting on background work (optional)
```

- A turn belongs to the prompt *you* submitted. Machine-injected prompts — task
  notifications from background subagents, auto-continuation, loop and schedule
  wake-ups — continue that turn instead of starting a new one, so one turn
  produces one alert and one duration.
- An agent another agent started (`claude -p` or `codex exec` from a tool call)
  is that agent's business: recorded quietly, and never allowed to take the
  tmux pane from the turn that spawned it.
- `UserPromptSubmit` records the start immediately; its notification is opt-in to avoid noise.
- Completion and failure notifications contain agent, project, duration, and `session › window`.
- Clicking **Open in Ghostty** returns you to the pane whatever app has focus and wherever you are in tmux: it picks a live tmux client, verifies the pane is actually on screen afterwards, and holds the terminal in front.
- **Acknowledge** clears the unread state; **Mark time logged** is available in the inbox.
- `PermissionRequest` is supported but its notification is off by default.
- A turn reports its outcome once; a completed turn is never rewritten by a late hook.
- No alert is sent for a pane you are already looking at.
- Prompts, commands, and final answers are not stored unless previews are explicitly enabled.

## Requirements

- macOS 13 or newer
- tmux 3.2 or newer
- A recent Claude Code with lifecycle hooks (including `StopFailure`), or Codex CLI with hooks and its completion callback
- Ghostty 1.3+ for exact window/tab focus; other terminals still receive the inbox and tmux metadata

## Install locally

```sh
git clone https://github.com/Lukeesec/mux-beacon.git
cd mux-beacon
./scripts/install-local.sh
mux-beacon install          # dry run: preview the hook changes
mux-beacon install --apply  # write them
```

The app installs into `/Applications` when writable, otherwise `~/Applications`, and registers with Launch Services. Finder can open it directly; `mux-beacon gui` is the reliable launcher for local ad-hoc builds that Spotlight has not indexed yet.

Applying the installation:

- adds owned handlers to `~/.claude/settings.json`;
- adds owned handlers to `~/.codex/hooks.json`;
- adds Codex's documented `agent-turn-complete` callback to `~/.codex/config.toml` when the `notify` slot is free;
- preserves an existing Codex `notify` command and prints a warning instead of replacing it;
- writes timestamped backups before changing existing files.

Codex asks you to review new hooks once. Open `/hooks` and trust the Mux Beacon definitions. The completion callback covers Codex versions where the lifecycle `Stop` hook is not emitted after each turn.

Permission events are deferred by default. Users who want them can install the adapter explicitly and then enable its notification in Settings:

```sh
mux-beacon install --apply --with-permission-events
```

Allow notifications when macOS prompts. In **System Settings → Notifications → Mux Beacon**, choose **Alerts** instead of **Banners** if notifications should remain until dismissed; macOS owns this setting, so apps cannot enforce it. To enable exact Ghostty focus, allow Mux Beacon to automate Ghostty under **System Settings → Privacy & Security → Automation**.

## Open the GUI

Mux Beacon is primarily a menu-bar app. Click its beacon icon in the macOS menu bar, open it from Finder or Spotlight when indexed, or run:

```sh
mux-beacon gui
```

Launching the app directly starts its menu-bar item without opening a window. Hook events and notification clicks never open or focus the inbox; only **Open window**, a fresh `mux-beacon gui` request, or `muxbeacon://inbox` brings it forward. Notification navigation returns directly to Ghostty and the captured tmux target.

## Try it without touching hook configuration

```sh
mux-beacon demo
mux-beacon test ready --source codex
mux-beacon status
```

The app and demo require no tmux restart. Hooks may require a new or reloaded agent process.

Mux Beacon is hook-driven rather than a process scanner. It begins tracking an agent when a hook-enabled prompt is submitted; it cannot reconstruct turns that were already running before installation. Merely launching Claude or Codex does not produce a start event. Completions from sessions Mux Beacon never saw a prompt for — such as Codex automation or background task turns — are recorded quietly under History and do not notify.

Agents shell out to other agents. A `claude -p` or `codex exec` you run yourself is a turn like any other and notifies normally, but one started from inside another agent's tool call is not something you are waiting on — and because it lands in the same tmux pane, tracking it as a turn of its own would evict the turn that spawned it. Mux Beacon separates the two by walking the process tree: a top-level agent has one agent CLI above its hook, a nested one has two. Nested runs are recorded quietly and leave the incumbent turn alone. If the process tree cannot be read, the run is treated as top-level and notifies as before.

Claude Code fires `Stop` in two situations: the turn is over, or the agent has parked itself waiting on background work it registered. Mux Beacon reads the hook's `background_tasks` field to tell them apart. Only a real completion notifies by default; the paused state is a separate, opt-in alert.

## Notification content

![Example Mux Beacon notification showing project, state, agent, duration, tmux target, Open in Ghostty, and Acknowledge](docs/assets/notification-preview.svg)

macOS renders the project and state as the bold title, led by a color dot that mirrors the tmux badge palette (🟢 ready, 🔴 failed, 🟡 attention, 🔵 working, 🟣 waiting on background work), with the agent, the clock times the turn ran between, and its duration beneath it, and the tmux route in the body. Elapsed time alone does not tell you *which* twenty minutes to log, so the start and end times are shown in your own 12- or 24-hour format; the date is left out because a turn worth announcing happened today. A turn still running shows `from 14:03` in place of a range. The same window appears in the inbox and in `mux-beacon status`, and `mux-beacon export` carries full ISO timestamps. It controls final layout, truncation, persistence, and Focus/DND delivery. Routing details live in hidden notification metadata as an opaque event ID.

### Alerts for the pane you are watching

There is no point announcing a turn you are already looking at, so Mux Beacon does not. An alert is skipped only when the pane can be *proved* to be on screen at the moment of delivery:

- tmux reports it as the active pane, of the active window, of a session a live client is attached to — suspended clients are excluded, since they display nothing;
- that client's process chain leads to the application macOS reports as frontmost, which keeps the check working for any terminal emulator and needs no extra permissions;
- and when a Ghostty terminal was captured for the turn, a different Ghostty terminal being in front vetoes the skip.

Anything else — no tmux target, an unreachable server, a query that times out, another app in front — notifies. Suppressing an alert you needed is worse than showing one you did not, so every uncertain path falls through to notifying. The turn still lands unread in the inbox either way; only the banner is skipped, and the decision is made once, so looking away later does not produce a late banner for work you already saw.

Run `mux-beacon focus-status` to see the verdict and its reason for recent turns. Turn the behavior off with `mux-beacon notifications skip-watched off`; it is deliberately not changed by `notifications all`.

Background-pause alerts are deliberately quieter than the rest: they read *Waiting on background work*, say *still running* instead of a final duration, play no sound, and use a passive interruption level so they never wake the display.

Demo records are marked `DEMO` and intentionally have no live jump target. The GUI keeps sample-data controls out of the normal workflow; remove samples with `mux-beacon clear-demo`.

## Defaults

![Mux Beacon notification and privacy settings](docs/assets/mux-beacon-settings.png)

Completion and failure alerts are on. Start, permission, and background-pause alerts are off. Change them in the GUI or from the CLI:

```sh
mux-beacon notifications status
mux-beacon notifications start on
mux-beacon notifications start off
mux-beacon notifications background on
mux-beacon notifications skip-watched off
mux-beacon notifications all off
```

## Disable or remove Mux Beacon

Choose the level you want:

```sh
# Silence every notification but keep recording turns in the inbox
mux-beacon notifications all off

# Stop collecting new events by removing only Mux Beacon's agent hooks
mux-beacon uninstall --apply

# Remove hooks and move the app to Trash; local history is retained
./scripts/uninstall-local.sh
```

## tmux views

![Illustrated preview of Mux Beacon state badges embedded in tmux pane borders](docs/assets/tmux-badges-preview.svg)

The state appears at the left of each pane's top border—blue `● WORKING`, green `● READY`, yellow `● ATTENTION`, or red `● FAILED`—followed by the existing pane title and pane number. The illustration uses a neutral theme; tmux renders it using your terminal's font and background. These badges are most useful when a window is split into panes; desktop notifications and the menu-bar inbox provide visibility across hidden windows and sessions.

```sh
mux-beacon tmux popup
mux-beacon tmux enable-badges
mux-beacon tmux disable-badges
mux-beacon tmux badge-status
```

`mux-beacon tmux popup` opens a temporary tmux overlay of recent agent activity. Enter a row number to jump to that agent; press Return to close it.

Badges are opt-in and apply to the current tmux server. Run `enable-badges` once from inside that server; `badge-status` reports whether borders are enabled and how many panes have tracked state. Mux Beacon saves the exact existing `pane-border-status` and `pane-border-format` and restores them with `disable-badges`.

## Time records

Turn duration is measured from prompt submission until completion or failure.

```sh
mux-beacon export --format json --output mux-beacon-time.json
mux-beacon export --format csv --output mux-beacon-time.csv
```

The core exposes `TimeExportProvider` and `TimeEntryDraft` so a Clockify adapter can be added without changing hook or UI code. Direct Clockify credentials and API calls are deferred from the first release; see [Clockify integration design](docs/CLOCKIFY.md).

## Useful commands

| Command | Purpose |
|---|---|
| `mux-beacon doctor` | Check app, hooks, tmux, Ghostty, and local storage |
| `mux-beacon status` | Show recent activity in the terminal |
| `mux-beacon health` | Retire superseded records and missing tmux targets |
| `mux-beacon focus-status` | Explain which turns would skip their alert, and why |
| `mux-beacon gui` | Open the native inbox window |
| `mux-beacon notifications …` | Inspect or change alert preferences |
| `mux-beacon jump-last` | Open the newest unread event |
| `mux-beacon demo` / `clear-demo` | Add or remove anonymized sample data |
| `mux-beacon uninstall --apply` | Remove only Mux Beacon's hook handlers |

## How routing works

Mux Beacon stores stable tmux IDs and the exact server socket. Navigation uses:

```sh
tmux -S <socket> switch-client -c <client-tty> -t <pane-id>
```

Ghostty 1.3 does not expose a terminal TTY, so Mux Beacon captures the focused terminal ID synchronously at prompt submission. Ghostty 1.4 adds TTY/PID properties, allowing direct mapping. Ambiguous or stale routes fail closed instead of switching an arbitrary terminal.

The inbox checks target health every 30 seconds and whenever **Refresh** is clicked. Older active turns on the same tmux target and events whose panes no longer exist are acknowledged as stale and retained under **History** for 7 days. Running and unread records are never removed by history cleanup.

See [Architecture](docs/ARCHITECTURE.md), [Development](docs/DEVELOPMENT.md), and [Troubleshooting](docs/TROUBLESHOOTING.md).

## Prebuilt releases

Tagged releases attach an app zip built by CI. It is ad-hoc signed and not notarized, so macOS blocks the first launch of a downloaded copy: approve it under **System Settings → Privacy & Security → Open Anyway**, or build from source as shown above (local builds are not quarantined).

## Privacy and security

- Local-only SQLite database; no telemetry.
- User-only application-support directory and hook backups.
- No approval or denial actions from notifications.
- Opaque event IDs in notification metadata; no shell commands or tmux labels in URLs.
- Hook commands return success without steering the agent.

## Roadmap

- Developer ID signing and notarization for release builds, so downloads pass Gatekeeper without manual approval.
- Clockify export adapter on the existing provider boundary ([design](docs/CLOCKIFY.md)).

## License

MIT © 2026 Lukeesec contributors.
