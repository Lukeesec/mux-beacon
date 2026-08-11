# Contributing

Thanks for improving Mux Beacon.

1. Open an issue for behavior or interface changes.
2. Keep hook handlers passive, bounded, and backward-compatible with documented payloads.
3. Add a fixture or self-test for lifecycle, installer, routing, or persistence changes.
4. Run `swift build`, `swift run mux-beacon-self-test`, and `zsh -n scripts/*.sh`.
5. Do not include real prompts, paths, session names, API tokens, or notification databases in fixtures or screenshots.

Pull requests should explain user-visible behavior, failure modes, and any config migration.
