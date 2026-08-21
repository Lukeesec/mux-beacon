# Repository guidance

## Product invariants

- Hook activity and notification clicks must never open or focus the Mux Beacon inbox. Only an explicit GUI action (`mux-beacon gui`, the menu-bar command, or `muxbeacon://inbox`) may do that.
- User-facing routes emphasize `session › window`. Pane and client identifiers are private routing metadata.
- Start, permission, and background-pause notifications are off by default. Completion and failure notifications are on by default.
- A turn belongs to the prompt the user submitted. Claude publishes `source` on `UserPromptSubmit`; only `user` and `sdk` open a tracked turn. `system`, `loop_wakeup`, `schedule_wakeup`, and `poll_event` continue the turn already in flight, and a hook carrying `agent_id` fired inside a subagent. An absent or unrecognized origin fails open so Codex and older Claude builds keep notifying.
- An agent started by another agent (`claude -p`, `codex exec` from a tool call) is recorded pre-acknowledged and must never supersede the turn that spawned it, since both share a tmux pane. Detection is process ancestry — two or more agent CLIs above the hook means nested — because Claude rewrites `CLAUDE_CODE_SESSION_ID` for the processes it spawns, so the environment cannot distinguish parent from child. An unreadable process tree means top-level, so the run still notifies.
- Claude fires `Stop` both when a turn ends and when it parks waiting on background work. `background_tasks` separates them; the paused state is its own opt-in alert, delivered silently at a passive interruption level.
- No alert is sent for a pane the user is already looking at, and that is on by default. Suppression requires proof — active pane, active window, a live (non-suspended) client attached, and that client's process chain reaching the frontmost application — and a captured Ghostty terminal may only veto, never confirm. Every uncertain path notifies; the record stays unread either way, and the decision is made once so looking away cannot produce a late banner.
- A turn reports its outcome once. Once an event has a completion time, later terminal hooks are ignored — Claude reuses a finished turn's `prompt_id` until the next prompt, so a late `StopFailure` must never rewrite a delivered result.
- Do not store prompts, commands, or final-answer previews unless the user explicitly enables previews.
- Preserve user configuration. Hook installation is additive, creates backups, and must not replace an existing Codex `notify` command.

## Agent integrations

- Claude completion arrives through its `Stop` lifecycle hook.
- Codex `UserPromptSubmit` arrives through `~/.codex/hooks.json`, but do not assume Codex emits `Stop` after every turn. Reliable Codex completion uses the documented top-level `notify` callback in `~/.codex/config.toml`, whose `agent-turn-complete` JSON is handled by `mux-beacon codex-notify`.
- Codex completion turn IDs do not match `UserPromptSubmit` prompt IDs, and Codex fires completions for every internal task, including automation sessions with no user prompt. Completions with unmatched IDs merge into the session's newest active turn; completions for untracked sessions must stay quiet (recorded pre-acknowledged, never notified).
- A third-party wrapper may own Codex's `notify` slot and re-invoke the previous command through its own arguments. That still delivers completions: report it as installed-and-forwarded, and leave the slot alone.
- Codex blocking `Stop` hooks require valid JSON on stdout; emit `{}` and no model-visible text.
- `SessionEnd` must not create a second stale record after a completed turn.
- Hook adapters must fail open: log local errors without interrupting Claude or Codex.

## tmux and Ghostty

- Keep tmux navigation client-aware and fail closed when the originating client or pane cannot be proven.
- Pane badges are opt-in per tmux server and must restore the exact prior border settings.
- Commas inside tmux conditional branches are separators. Use separate style tokens such as `#[fg=blue]#[bold]`, not `#[fg=blue,bold]`, in nested badge conditionals.
- Ghostty focus and tmux switching must not activate the Mux Beacon GUI as an intermediate step.

## Verification

Run before publishing:

```sh
swift build
swift run mux-beacon-self-test
zsh -n scripts/*.sh
./scripts/build-app.sh
codesign --verify --deep --strict "dist/Mux Beacon.app"
git diff --check
```

For integration changes, unit fixtures are not sufficient. Install the release build, apply configuration, start a fresh real agent process, and verify `mux-beacon doctor`, the SQLite event, the notification log, and the live tmux rendering. Remove only the exact synthetic or verification records and pane options created by the test.

Screenshots and fixtures must use anonymized demo data. Before public pushes, scan tracked files for credentials and personal paths, then wait for GitHub CI to pass.
