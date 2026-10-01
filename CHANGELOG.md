# Changelog

## Unreleased

- Respect Git ignore rules: ignored files never reach the timeline, and Linux skips watching ignored directories.
- Linux: report files created inside new directories before their watcher attaches; new-directory ignore lookups never block.
- Compute watcher diffs asynchronously, one file at a time in arrival order, so Git never blocks editing.
- Fix ignore globs with Lua pattern characters (the default `lazy-lock.json` entry never matched); support `[...]`/`[!...]` classes.
- Validate options: invalid types or values are reported once and replaced by defaults. Removed the unused `diff_source` and `filter.min_change_bytes` options.
- Keep live previews connected when Neovim lags: the bridge skips intermediate frames and sends the newest (including final) snapshot once the socket drains, and Neovim decodes only the newest bounded snapshot, instead of a disconnect discarding the edit.
- Restore Follow's input detection after a render error, and keep it suppressed during nested reveal frames.
- Truncate `<git-dir>/agent-lens/reads.jsonl` once it exceeds 4 MiB.
- Only run the `checktime` autocmds while watching.

## v0.1.0-beta.1 — 2026-10-01

First beta of the Neovim plugin and optional Pi/OMP bridge.

- Watch filesystem edits, highlight Git HEAD-to-disk changes, and track successful agent reads.
- Follow agent activity in the current editor or a dedicated split, with pause/resume controls and safe editing handoff.
- Show bounded, animated streamed code drafts over private local sockets; drafts remain in memory until tool results restore the source view.
- Group timeline activity by file, filter reads/edits, and retain stable selection and unread markers.
- Preview individual hunks or review current changes in an owned diff tab while preserving editor layout.
- Inspect watcher, follow, metadata, and preview status with `:AgentLensStatus`.
- Include repository path validation, watcher cancellation, buffer lifecycle, and stale-event protections.

Requires Neovim 0.10 or newer and Git. Read tracking and live previews require
the bridge in a Pi/OMP session. Restart both applications after installing.
This is a prerelease; feedback on the watch, pause, review, and resume workflow is welcome.
