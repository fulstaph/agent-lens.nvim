# Changelog

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
