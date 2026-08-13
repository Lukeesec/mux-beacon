# Changelog

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
