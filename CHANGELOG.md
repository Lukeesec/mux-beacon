# Changelog

## 0.2.3 — 2026-08-21

- A turn now belongs to the prompt you submitted. Claude Code publishes `source`
  on `UserPromptSubmit`; machine-injected prompts (`system` task notifications,
  auto-continuation, `loop_wakeup`, `schedule_wakeup`, `poll_event`) and hooks
  carrying `agent_id` continue the turn already in flight instead of opening a
  new one. Background subagents reporting back no longer produce a "Ready"
  notification while the run is still going.
- Pausing for background work is no longer reported as a completion. Claude
  fires `Stop` both when a turn ends and when it parks waiting on registered
  background work; the paused state is now its own preference, off by default,
  and its alert reads "Waiting on background work", shows "still running"
  instead of a final duration, plays no sound, and uses a passive interruption
  level so it never wakes the display.
- A completed turn is immutable. Claude reuses a finished turn's `prompt_id`
  until the next prompt, so a late `StopFailure` — rate limit, overload, server
  error — was rewriting a delivered "Ready" into a red "Failed" and notifying a
  second time. Late terminal hooks are now ignored, and a turn announces its
  outcome once.
- Turn durations and time-entry exports cover the whole user turn again.
  Injected continuations no longer retire the real turn as superseded, so one
  prompt yields one History record instead of a chain of fragments.
- `mux-beacon notifications background on|off` controls the new alert, and
  `doctor` recognizes a Codex `notify` slot owned by another command that
  forwards to Mux Beacon, reporting it as installed rather than missing.

## 0.2.2 — 2026-08-13

- Notification titles lead with a color dot matching the tmux badge palette,
  so state survives long project names and reads at a glance.
- Codex completions whose turn ID does not match the prompt hook's ID now merge
  into the session's active turn, fixing zero-second durations and lingering
  Working entries.
- Completions from sessions with no tracked prompt (for example Codex
  automation tasks) are recorded quietly in History instead of notifying.
- `mux-beacon test` seeds a tracked start so synthetic terminal events still
  notify and show a duration.
- Removed the no-op `summaryArgument` from notification content.

## 0.2.1 — 2026-08-12

- Fix a crash when reopening or closing the inbox and settings windows: closed
  windows were over-released (`isReleasedWhenClosed`), corrupting later
  window-animation teardown.

## 0.2.0 — 2026-08-12

- Distinctive native app and notification icon.
- Project-first notification hierarchy with native bold title treatment.
- Start notifications now opt-in; completion and failure remain enabled by default.
- CLI controls for individual notification types and opening the native GUI.
- Persistent-alert guidance and improved Applications/Launch Services registration.
- Reliable Codex completion delivery through its documented turn-complete callback.
- Correct tmux badge formatting plus a `badge-status` diagnostic.
- Fully fictional demo fixtures and regenerated documentation screenshots.
- Subprocess output is drained while commands run, and deep-link event IDs are no longer double-decoded.
- Documented the unsigned-release Gatekeeper caveat and the signing/notarization roadmap.

## 0.1.0 — 2026-08-11

- Native macOS menu-bar inbox and actionable notifications.
- Claude Code and Codex lifecycle adapters.
- Optional `UserPromptSubmit` start notifications.
- Permission-request support with notifications disabled by default.
- Exact client-aware tmux navigation and Ghostty 1.3 capture.
- Optional reversible pane-border badges and tmux popup.
- Local duration ledger, JSON/CSV export, and Clockify provider boundary.
- Idempotent installer, backups, diagnostics, demo fixtures, and deterministic screenshots.
