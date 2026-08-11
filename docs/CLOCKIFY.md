# Clockify integration design

Clockify is intentionally an extension point in v1, not a required service.

## Existing public boundary

`TimeExportProvider` receives completed `TimeEntryDraft` values containing:

- local event ID;
- project name and generated description;
- start, end, and wall-clock duration;
- Claude or Codex source;
- optional external ID for idempotent updates.

## Future adapter

A Clockify provider should:

1. Store the API token in Keychain, never in Mux Beacon's SQLite database.
2. Let users map local repository names to Clockify workspace/project/task IDs.
3. Use the local event ID as an idempotency key in provider metadata where possible.
4. Preview creates/updates before sending them.
5. Persist returned Clockify time-entry IDs so retries update rather than duplicate.
6. Keep failures retryable without changing the local logged state.

The UI should expose **Export to Clockify** beside **Mark time logged** only when the provider validates its configuration.
