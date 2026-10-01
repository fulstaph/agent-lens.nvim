# Agent Lens UI/UX design

Date: 2026-10-01
Status: interaction design approved; written specification awaiting review

## Intent and agreed scope

The user wants Zed-style agent following inside Neovim: live code should be
pleasant to watch, agent activity should be understandable, and the plugin
should leave the user in control of their editor. The existing progressive
reveal, drafting caret, active-line highlight, and viewport easing were accepted.
The user approved improving all three workflows together: watching the agent,
editing alongside it, and reviewing changes afterward. README, Vim help, and
AGENTS.md updates are explicitly required.

The approved interaction design keeps current-window Follow as the default,
adds an optional dedicated agent split, pauses on manual navigation, returns
to a real source buffer on Insert mode, groups timeline activity by file,
preserves selection during incoming events, and moves full diff review into
a separate tab. This document defines the detailed behavior of that design.

Success means that the user can recognize what the agent is doing, interrupt
following without losing incoming activity, resume at the latest valid target,
inspect a stable timeline item, and review changes without rearranging their
existing windows or replacing unsaved text.

## Constraints and boundaries

- Support Neovim 0.10 and newer using builtins, `vim.uv`, and Git. Add no runtime
  dependencies, compiled components, or required statusline/icon plugins.
- Keep existing commands and public APIs usable. New commands and options are
  additive. Follow and successful-read tracking remain opt-in.
- Keep JSONL metadata-only and byte-compatible. Preview contents remain bounded
  in memory over the existing private local socket, with independent consumer
  validation. No new contents, prompts, patches, or raw deltas enter event logs.
- Preserve repository containment, symlink restrictions, buffer modification
  protections, current-tab boundaries, and protected-window checks.
- Show only observable activity. A listening socket or an old log does not prove
  that OMP/Pi is running. This work adds no heartbeat or agent installation probe.
- Reviews compare Git HEAD to disk. They are not historical per-event patches,
  and filesystem edits are not attributed to a particular process.
- Stage/apply/revert controls, agent chat, persistent sessions, and replay of
  streamed content are outside this scope.

## 1. Follow control and editing handoff

### States and transitions

Follow has separate control and activity state. Control is `off`, `following`,
or `paused`; activity records the latest valid read/draft/apply/success/error
event. A pause does not disable metadata polling or the preview receiver.
Existing `is_enabled()` is true for both following and paused states.

| Trigger | Required behavior |
| --- | --- |
| Enable Follow | Enter following and display the latest valid target, if any. |
| Manual navigation in the followed window | Pause before another agent update can move the viewport. |
| Insert mode in a followed draft | Pause, hand back the real source buffer, then allow normal editing. |
| Browse the timeline or start review in current-window mode | Pause; retain incoming activity without navigating the editor. |
| Explicit resume | Validate and display the newest target, then enter following. |
| Disable Follow or stop the plugin | Cancel motion, discard pending drafts, and release owned Follow UI. |
| User closes the agent split | Pause; recreate a split only on an explicit resume or mode command. |

Manual input must be distinguished from cursor, buffer, and scrolling changes
made by Follow itself. Guards cover programmatic view changes and scheduled
animation frames; a cursor autocmd alone is not evidence of user input. Modal
prompts, command-line windows, and protected editor states do not permit
background navigation or buffer replacement. In current-window mode, leaving
the followed editor window or changing tabs pauses navigation until resume.

Pause cancels viewport motion and freezes the displayed draft snapshot. New
previews replace one bounded pending snapshot for the active call; they do not
mutate the frozen buffer or accumulate a queue of animation frames. If a tool
finishes successfully while paused, resume opens the actual source buffer.
Failure or cancellation discards its speculative content and restores the
source buffer with the cursor/view preserved as far as the source permits.
Late snapshots from settled calls remain ignored.

The Insert-mode handoff maps the draft row to a valid source row and clamps
the column. It uses an existing modified source buffer when present, never
overwrites it with disk or draft text, and does not replay the insertion key.
If loading a safe source fails, remain paused, keep the draft read-only, and
show a useful error rather than accepting edits into a scratch buffer.

Resume consumes current state, not the backlog of intermediate locations. If
the target is no longer safe or loadable, remain paused with the reason visible.
Successful completion may finish the existing bounded reveal before settling;
a successful host connection closure must not truncate that reveal.

### Window modes

`follow.window = "current"` preserves existing safe-window selection. Explicit
user takeover pauses automatic selection of replacement windows.

`follow.window = "split"` maintains one plugin-owned agent split in the current
tab. The default position is right and its default width is half the available
editor width, with a configurable fixed width. Creation and updates do not
change keyboard focus. Editing or navigating unrelated windows leaves this
split following; navigating or entering Insert mode inside it pauses Follow.
Changing tabs does not create background splits automatically. While the
owning tab is inactive, retain latest validated activity without cursor/window
changes there; a still-following split catches up when the user returns.

The split reuses the same read/draft/source pipeline and respects modified
buffers, bindings, diff windows, and pinned windows. Its ownership is tied to
the expected buffer/window relationship. A window repurposed by the user is
not subsequently closed as plugin UI. Switching modes keeps the latest target,
preserves the paused/following state, and releases only an unused owned split.

### Commands and API

- `:AgentLensFollow`: retain the existing enable/disable toggle.
- `:AgentLensPause` and `lens.pause_follow()`: idempotent pause.
- `:AgentLensResume` and `lens.resume_follow()`: enable if off, then resume.
- `:AgentLensFollowMode [current|split]` and `lens.set_follow_window(mode)`:
  choose a mode; the command without an argument toggles the two modes.
- Add configurable global `<leader>ar` for resume; existing mappings remain.
- `follow.auto_pause = true` by default. Setting it false disables automatic
  pauses from ordinary navigation, but Insert handoff and unsafe modal/editor
  conditions still protect the editor.

New option defaults are `follow.window = "current"`,
`follow.split = { position = "right", width = 0 }`,
`timeline = { view = "files", filter = "all" }`, and
`keymaps.resume = "<leader>ar"`. Split position accepts `right` or `left`;
width 0 chooses half the available width, and a positive integer requests a
fixed width clamped to the editor. An empty resume mapping disables that global
binding. Filters and view toggles update the in-session projection; setup opts
control initial values.

## 2. Activity and bridge visibility

A shared status snapshot exposes control state, window mode, latest activity,
repository-relative target and line, paused reason, and separate metadata and
preview transport facts. Public snapshots contain no draft contents and are
copies that consumers cannot mutate to alter plugin state.

User-facing activity labels are `Reading`, `Drafting`, `Applying`, `Settled`,
and `Failed`; pause has precedence in the compact display, with the most recent
activity available in details. Idle is not presented as thinking or generation.

Transport facts distinguish disabled tracking, waiting for data, received
metadata, preview listening/receiving, and actual errors. Missing logs and a
preview receiver with no peers are normal waiting states. A disconnected host
after a completed turn is not automatically an error. Only validated records
advance the received-data indicator. Explicit errors clear after successful
recovery or a successful restart of the affected channel.

The timeline header displays compact status and new-activity counts. The
plugin-owned agent split and review windows have compact winbars. Existing
user statuslines and winbars are not overwritten. Pause/resume gets a short
notification when needed for visibility with the panel closed; streamed frames
and routine lifecycle updates do not generate notification spam.

- `lens.status()` returns the structured snapshot.
- `lens.statusline()` returns a short, statusline-escaped string for optional
  integration with a built-in or third-party statusline.
- `:AgentLensStatus` opens a small read-only details float containing watched
  root, Follow state, latest validated activity, transport state, and errors.
- `:checkhealth agent-lens` reports these same observable transport facts and
  actionable recovery commands.

Use theme-linked highlight groups, readable text labels, and ASCII fallbacks.
Do not depend on color alone or a patched font. Existing
`follow.animation = false` remains the reduced-motion option. Status and
timeline refreshes are event-driven; do not rebuild the panel at frame rate.

## 3. Grouped and stable activity timeline

Keep the bounded chronological event model with monotonic IDs. Preserve the
read range currently passed by `read_events.lua` into `timeline.add()` but
dropped during entry construction. Read children can consequently open the
actual reported range.

`timeline.view = "files"` is the new default; `"events"` retains a flat feed.
File groups are ordered by their latest matching event. Each group shows the
repository-relative path, latest activity/time, read/edit counts, latest edit
statistics, and new-activity count. Groups are collapsed initially and expand
to show individual retained events with explicit read/edit labels. Use actual
window display width to truncate paths without breaking Unicode characters.

Grouping is a projection, not destructive coalescing of stored events. Filters
are `all`, `reads`, and `edits`. A read does not replace the file's latest edit
statistics. Group/header `+N/-M` values use the latest retained edit snapshot per
file; totals must not sum repeated HEAD-to-disk snapshots. Statistics are
labeled as retained latest comparisons, rather than a live repository-wide
total or agent-only change count. If a file has no retained edit, omit its
change numbers instead of implying a measured zero.

Selection keys identify an event ID or a file-group path, never a list index.
Incoming updates preserve the selected item and its screen position where
possible. They do not move the selection to the newest row. If retention trims
the selected event, select the nearest surviving item in the prior visible
order and clamp the view. Changing filters keeps the same selection when it
remains visible, otherwise selects that file's group or the nearest visible row.

New activity is counted only for retained unacknowledged events. Moving the
cursor, scrolling, or merely rendering a row does not acknowledge it. Opening
an event successfully acknowledges that event. Opening a group successfully
acknowledges its events matching the current filter. An explicit mark-all-seen
action acknowledges the retained feed. Trimming and clear remove obsolete
acknowledgement state; it remains bounded by retained IDs.

### Timeline actions

- `j/k` and existing `]a/[a` move among selectable visible rows.
- `<Tab>` expands/collapses the selected file group.
- `<CR>` opens the selected child event. On a group, prefer its latest edit
  when edits are included, otherwise open its latest matching read.
- `p` previews the selected edit's current first hunk; a read opens its range.
- `f` and `:AgentLensFilter [all|reads|edits]` cycle/select the filter.
- `u` toggles showing only groups/events with new activity.
- `m` marks all retained activity seen; `g` toggles files/events views.
- `q` closes and `R` refreshes as before. Show a compact footer with key hints.

`panel.selected()` continues returning a `TimelineEntry`, resolving group
selection using the same action rule as `<CR>`. Empty and filtered-empty states
explain the reason and relevant control. A waiting bridge state must not claim
that read events are enabled and connected merely because tracking was requested.

## 4. Hunk and full-file review

Review always uses the watched repository root rather than an unrelated cwd.
Immediately before opening or changing files, validate paths again and compute
the current HEAD-to-disk comparison. Selecting an old event does not promise
its historical contents; window labels say `HEAD → disk` and identify the file.
File status follows actual HEAD/disk existence: removing some lines from an
existing file is a modification, not deletion of the file.

### Hunk preview

`:AgentLensPreview` and the timeline `p` action open a read-only unified hunk
float with surrounding context, `+/-` highlighting, file path, hunk index, and
key hints. A command without a selected timeline edit uses the current file
when it belongs to the watched root. Binary or unchanged files show an accurate
message rather than an empty successful preview.

`]h/[h` move between hunks. `<CR>` opens the full comparison of the same file;
`q` or `<Esc>` closes the float and restores its valid originating window/view.
`R` refreshes the current comparison while retaining the selected hunk when
possible.
Size is bounded by the editor; narrow windows use wrapped/scrollable unified
text. Pure additions, deletions, and zero-line hunk anchors remain navigable.
Hunk indices clamp when a refreshed comparison changes the number of hunks.

### Full comparison and changed-file navigation

`:AgentLensDiff` keeps its existing entry point but opens or reuses a dedicated
review tab. The configured vertical/horizontal layout still controls the two
read-only native diff buffers. Never use `:only` on the user's original tab.
Capture the origin tab/window and view; the close action returns there when
still valid, otherwise chooses a surviving ordinary window without forcing
unsaved buffers to close.

Full review supports `]h/[h`, `]f/[f`, and `q`. Changed-file navigation enumerates
safe files currently differing from HEAD, including tracked deletions and
untracked files, in deterministic path order. Skip binaries with a clear
message. Represent renames as separate old/new paths when the existing diff
engine cannot produce a reliable rename comparison. Refresh the file list on
file navigation and explicit `R`; streaming writes do not move the user's
chosen review file or hunk automatically.

All review buffers/windows carry explicit ownership. Close only the preview
or review windows still owned by this session. If the user has added or
repurposed windows in the review tab, preserve them instead of closing the
whole tab. Never close the last editor window or delete a modified/reused
buffer. Manual closure cleans up orphan scratch buffers and ownership state.

Reviewing pauses current-window Follow. It does not stop an agent split in a
different window; interacting with that agent split still pauses it normally.
Closing review does not resume paused Follow automatically. Resume from a
paused state is always explicit.

## 5. Architecture and contracts

Keep component boundaries focused on the new interactions:

| Component | Responsibility and interface |
| --- | --- |
| `init.lua` | Commands, public API, source orchestration, and mode/review handoffs. |
| `follow.lua` | Follow control/activity state, active call correlation, bounded latest pending snapshot, pause/resume decisions. |
| `follow_view.lua` (new) | Source/draft buffer lifecycle, owned agent windows, guarded rendering, Insert handoff, and motion cancellation. |
| `paths.lua` (new) | Shared repository-relative target validation; preserve `follow.target_path()` as a compatibility delegate. |
| `motion.lua` | Existing bounded text/caret/viewport animation; cancellation cannot resurrect a paused or removed view. |
| `status.lua` (new) | Copied observable status snapshots, compact labels, statusline escaping, details UI, and change notifications. |
| `timeline.lua` | Bounded immutable event records, ranges, latest edit statistics, acknowledgement bookkeeping. |
| `panel_model.lua` (new) | Pure grouping/filtering and stable row identities; no editor windows or buffers. |
| `panel.lua` | Render projected rows, preserve selection/view, dispatch actions, and show compact status/help. |
| `diff.lua` | Current safe HEAD/disk comparisons, hunks, and changed-file enumeration. |
| `diff_view.lua` | Owned hunk float/review tab, navigation, refresh, origin restoration, and cleanup. |
| `read_events.lua` / `live.lua` | Existing trust boundaries plus observable channel facts; no UI ownership. |
| `health.lua` | Explain dependency, watched-root, and transport facts from the same status contracts. |

Controllers publish discrete status changes. UI consumers do not modify Follow
or transport internals through snapshot references. Avoid dependency cycles:
path validation and panel projection are leaves, and low-level views do not
import `init.lua`. `AgentLensStatusChanged` is a `User` autocmd emitted when the
observable snapshot changes, enabling optional integrations without polling.

Existing preview limits (1 MiB, 20,000 lines), recent-call tombstones, sequence
checks, queue limits, socket permissions, and cleanup generations remain in
force. Pause stores at most one latest pending draft, not every stream delta.
Clear resets timeline acknowledgement, selection, pending activity, and marks;
if Follow remains enabled it returns to following/waiting without a target.
Stop cancels all timers/transports and owned Follow views. Explicit review
windows can still be closed safely afterward through the review owner.

## 6. Documentation and verification

Implementation is not complete until all of these are updated together:

- **README.md:** explain watch/edit/review workflows, defaults, pause/resume,
  split mode, grouped/flat timeline, filtering/new activity, hunk/full review,
  statusline integration, transport diagnosis, and HEAD-to-disk limitations.
- **doc/agent-lens.txt:** document every command, Lua API, option, keymap,
  ownership rule, and recovery action with matching defaults and help tags.
- **AGENTS.md:** update module tree, data flow, types/state transitions,
  trust/ownership rules, public interfaces, and exact behavioral test commands.
- **CI:** run new public-behavior tests across Neovim 0.10.4, stable, and nightly
  alongside the existing headless and extension/integration suites.

Tests must exercise outcomes rather than mirror implementation details:

1. Manual input pauses; programmatic navigation/animation does not. Insert
   handoff preserves unsaved source text. Protected/modal states stay safe.
2. Streaming while paused leaves the visible snapshot/view unchanged, stays
   bounded, and resumes at the latest target. Success/error/cancellation and
   socket closure cannot resurrect stale or cancelled previews.
3. Dedicated split updates preserve user focus and unrelated buffers. Closing,
   switching tabs, repurposing windows, changing roots, stop, and restart clean
   up correctly.
4. Grouping, filters, expansion, unread acknowledgement, retention trimming,
   Unicode/narrow layouts, and incoming updates preserve intended selection.
   Read ranges survive storage. Repeated edit snapshots are not added together.
5. Observable bridge states distinguish disabled/waiting/received/error without
   inferring host liveness. Labels escape statusline metacharacters and do not
   replace user statuslines/winbars or produce frame-level notifications.
6. Hunk and changed-file navigation handle additions, deletions, untracked
   files, changed comparisons, binaries, unsafe paths, and missing origins.
   Opening/closing review preserves original splits, views, and unsaved text.
   User-created/reused review windows are preserved.
7. Existing commands/configuration, metadata privacy tests, real socket preview
   integration, reduced-motion behavior, and teardown tests still pass.

Capture the actual Neovim UI for a live-follow pause/resume scenario, a grouped
timeline receiving updates while an older entry is selected, and hunk/full
review returning to an existing multi-window layout. Review normal and narrow
widths visually. Run StyLua, Luacheck when available, and whitespace checks;
report any unavailable check accurately.

## Acceptance checklist

- [ ] All three approved workflows are implemented without extra dependencies.
- [ ] Follow pause/resume and editing handoff preserve editor control and text.
- [ ] Compact status represents observed facts and supports optional integration.
- [ ] Grouping/filtering/new activity never destabilize the selected timeline item.
- [ ] Review uses current HEAD-to-disk data and preserves user window ownership.
- [ ] New and existing behavior/privacy/integration tests pass.
- [ ] README, Vim help, AGENTS.md, and CI describe the shipped behavior consistently.
- [ ] Actual Neovim UI has been checked at normal and narrow widths.

Written-spec approval is followed by a separate implementation plan and choice
of execution method before product code changes begin.
