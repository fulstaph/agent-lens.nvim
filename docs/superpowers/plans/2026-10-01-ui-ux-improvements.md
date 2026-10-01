# Agent Lens UI/UX Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make agent work comfortable to watch, interrupt, and review inside Neovim while preserving user text and window layouts.

**Architecture:** Keep the existing filesystem, metadata, and transient-content channels. Separate Follow control from its view, add copied status snapshots and a pure timeline projection, and give review windows explicit ownership. Share the existing safe path resolver across consumers.

**Tech Stack:** Lua, Neovim >= 0.10 builtins and `vim.uv`, Git CLI, existing Node-compatible Pi/OMP JavaScript extension; no new runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-10-01-ui-ux-design.md` — written specification approved on 2026-10-01.

## Global Constraints

- Support Neovim 0.10 and newer using builtins, `vim.uv`, and Git.
- Add no runtime dependencies, compiled components, or required statusline/icon plugins.
- Keep existing commands and public APIs usable. New commands and options are additive.
- Follow and successful-read tracking remain opt-in.
- Keep JSONL metadata-only and byte-compatible.
- Preserve repository containment, symlink restrictions, buffer modification protections, current-tab boundaries, and protected-window checks.
- Show only observable activity. A listening socket or an old log does not prove that OMP/Pi is running.
- Reviews compare Git HEAD to disk. They are not historical per-event patches.
- Keep preview limits at 1 MiB and 20,000 lines, one pending snapshot, existing sequence checks and recent-call tombstones.
- Default to current-window Follow, auto-pause enabled, right agent split, automatic half-width, grouped file timeline, and all-event filter.
- Retain the existing 180 ms reveal and `follow.animation = false` reduced-motion option.
- README, Vim help, AGENTS.md, CI, LuaCATS annotations, StyLua, and behavior tests are deliverables.
- Reuse the current managed worktree and preserve the accepted, uncommitted preview/animation work. Never reset it or stage unrelated work.

## Review Focus

1. User input arriving between a queued animation frame and a metadata callback must pause before either can move the editor; pinned by Task 3 `input_wins_over_queued_frames`.
2. Paths containing `%`, Unicode, spaces, and Git-special characters must display safely and identify the right file; pinned by Tasks 2, 5, and 6.
3. User-repurposed windows and a closed origin tab must survive review teardown; pinned by Task 7 `repurposed_windows_and_missing_origin`.
4. Linked worktrees and repositories without HEAD must produce correct repository-local results or an explicit unavailable-baseline message; pinned by Task 6 `worktree_and_unborn_head`.
5. Stale socket callbacks from a previous root while Follow is paused must not restore old content or alter new transport status; pinned by Tasks 2 and 3.

---

## File and interface map

| File | Responsibility |
| --- | --- |
| `lua/agent-lens/paths.lua` — new | Shared safe target resolver; no UI or Follow imports. |
| `lua/agent-lens/status.lua` — new | Copied status facts, formatting, details float, deduplicated change events. |
| `lua/agent-lens/follow_view.lua` — new | Source/draft buffers, guarded input/rendering, owned agent windows, handoff. |
| `lua/agent-lens/panel_model.lua` — new | Pure rows, grouping/filtering, stable selection resolution. |
| `lua/agent-lens/follow.lua` | Control/activity state, correlation, latest pending draft, pause/resume. |
| `lua/agent-lens/timeline.lua` | Bounded event storage, read ranges, acknowledgements, latest edit summaries. |
| `lua/agent-lens/panel.lua` | Projected rows, keymaps, stable viewport, action callbacks, status/footer. |
| `lua/agent-lens/diff.lua` | Current safe comparisons and deterministic changed-file enumeration. |
| `lua/agent-lens/diff_view.lua` | Hunk float, owned review tab, navigation, refresh, origin restoration. |
| `lua/agent-lens/init.lua`, `config.lua`, `health.lua` | Public commands/options, orchestration, diagnostics. |
| `lua/agent-lens/read_events.lua`, `live.lua` | Existing validation/transport plus observable channel facts. |
| `tests/*.lua`, `tests/live-preview.test.mjs`, `tests/live_preview.lua` | Public behavior, lifecycle, and real socket verification. |
| `README.md`, `doc/agent-lens.txt`, `AGENTS.md`, `.github/workflows/ci.yml` | User/developer contracts and verification coverage. |

Shared types are LuaCATS records, not mutable references into controllers:

- `FollowTarget`: `{root, call_id, phase, tool, path?, line?, agent, sequence?}` using existing lifecycle values.
- `DraftSnapshot`: existing validated preview event `{toolCallId, tool, path, line, sequence, agent, lines}`.
- `FollowState`: `{control: "off"|"following"|"paused", window: "current"|"split", reason?: string}`.
- `ActivityState`: `{phase: "idle"|"reading"|"drafting"|"applying"|"settled"|"failed", tool?, path?, line?, call_id?}`; path is repository-relative.
- `ChannelState`: `{state: string, peers?: integer, last_valid_at?: integer, error?: string}`. Timestamps use Unix seconds. Metadata state is `disabled|waiting|received|error`; preview state is `disabled|listening|receiving|error`. A preview with no peers returns to listening while retaining the last validated receipt time.
- `StatusSnapshot`: `{watcher: {state: "running"|"stopped", root?: string}, follow: FollowState, activity: ActivityState, metadata: ChannelState, preview: ChannelState}`.
- `PanelRow`: `{key, kind: "file"|"event", path, entry: TimelineEntry, event_ids: integer[], depth: integer, reads: integer, edits: integer, unread: integer, stats?: {added, removed}}`.
- `PanelOptions`: `{view: "files"|"events", filter: "all"|"reads"|"edits", unread_only: boolean, expanded: table<string, boolean>}`.
- `ReviewOrigin`: `{tab, win, buf, view}`; restore the view only if the origin still displays that buffer.

Tests use temporary repositories and buffers, never the user's project files.
Canonicalize fixture roots with `vim.uv.fs_realpath()` before comparing paths.
New headless test scripts follow the existing protected test/cleanup pattern,
print `<area> behavior OK`, and exit nonzero on an assertion failure.

## Task 0: Checkpoint the accepted animation baseline

**Files:** Existing modified/new preview and animation files reported by `git status`; the already committed spec is not part of this runtime checkpoint.

**Interfaces:** Produces a clean runtime baseline containing the already accepted `follow.record_preview()`, `live.start()/stop()`, `motion.reveal()/view()/stop()`, and the extension socket helper.

- [x] Inspect `git diff` and untracked files against the preceding session's accepted changes. Read the selected execution/worktree skill; reuse this checkout. If still detached, create `codex/ui-ux-improvements` at the current HEAD.
- [x] Confirm the accepted test results still apply to these files. If their contents changed since verification, rerun the affected existing suites before committing.
- [x] Commit only the identified baseline files with `feat: animate streamed agent code previews`: `.github/workflows/ci.yml`, `AGENTS.md`, `README.md`, `doc/agent-lens.txt`, `extensions/pi-read-events.js`, `extensions/live-preview.js`, `lua/agent-lens/config.lua`, `lua/agent-lens/follow.lua`, `lua/agent-lens/init.lua`, `lua/agent-lens/live.lua`, `lua/agent-lens/motion.lua`, `package.json`, `tests/package-manifest.test.mjs`, `tests/pi-read-events.test.mjs`, `tests/live-preview.test.mjs`, `tests/live_preview.lua`, and `tests/motion.lua`. Inspect the staged names before commit; exclude unrelated edits discovered during execution.

This task introduces no new behavior and needs no fabricated failing test.

## Task 1: Share the safe repository-target resolver

**Files:** Create `lua/agent-lens/paths.lua`, `tests/paths.lua`; modify resolver code in `follow.lua`, architecture/testing sections in `AGENTS.md`, and CI test steps.

**Interfaces:** Produces `paths.resolve(root: string, rel_path: string, allow_missing?: boolean): string|nil`. Existing `follow.target_path()` delegates with the same signature and semantics. No consumer gains weaker validation.

- [x] Write `tests/paths.lua` tests `existing_and_missing_targets`, `unsafe_paths_and_symlinks`, and `invalid_argument_types`. Assert safe paths resolve; absolute paths, traversal, `.git`, symlink components including dangling parents, directories, control characters, and malformed argument types return nil. Include these concrete assertions:

  ```lua
  assert(paths.resolve(root, "safe.lua", false) == root .. "/safe.lua")
  assert(paths.resolve(root, "nested/new.lua", true) == root .. "/nested/new.lua")
  assert(paths.resolve(root, "../escape.lua", true) == nil)
  assert(paths.resolve(root, ".git/config", false) == nil)
  assert(paths.resolve(root, "linked/new.lua", true) == nil)
  ```

- [x] Run `nvim --headless -u NONE -l tests/paths.lua`; expect FAIL because the module is missing.
- [x] Move the resolver into `paths.resolve()` and retain the public Follow delegate. Preserve canonical-root containment and lstat checks for every existing path component; handle invalid argument types without throwing.
- [x] Run the new path test plus `tests/follow.lua`, `tests/follow_lifecycle.lua`, and `tests/read_events.lua`; expect all scripts to exit 0 with their success messages. Add the new CI invocation and AGENTS.md command/module entry.
- [x] Run StyLua and commit these files with `refactor: share safe repository target resolution`.

## Task 2: Publish observable activity and transport status

**Files:** Create `status.lua`, `tests/status.lua`; modify `init.lua`, `follow.lua`, `read_events.lua`, `live.lua`, `health.lua`, README, Vim help, AGENTS.md, and CI.

**Interfaces:** Consumes Task 1's resolver. Produces `status.reset(): nil`, `status.set(section: "watcher"|"follow"|"activity"|"metadata"|"preview", value: table): nil`, `status.get(): StatusSnapshot`, `status.compact(snapshot?: StatusSnapshot): string`, `status.statusline(): string`, `status.open(): nil`, and `status.close(): nil`. A set copies only the section's declared fields and replaces the complete section so recovered errors can be cleared. `lens.status()` and `lens.statusline()` delegate; `:AgentLensStatus` opens details. Emit `User AgentLensStatusChanged` only for changed snapshots, coalescing scheduled notifications.

- [x] Write tests `snapshot_isolation_and_deduplication`, `percent_paths_and_labels`, `waiting_is_not_failure`, and `stale_channel_callbacks`. Test copied records, identical updates producing no extra event, `%` becoming `%%` in statusline output, a missing log/no peer staying waiting/listening, recovery clearing errors, and old-root callbacks leaving new-root facts untouched. Assert `status.get().activity.lines == nil` and that details/status updates preserve a pre-existing user statusline and winbar.
- [x] Run `nvim --headless -u NONE -l tests/status.lua`; expect FAIL for the missing module/API.
- [x] Implement the status interfaces and owned details float with q/Esc and safe cleanup through `status.close()`. Publish valid read/location receipt after consumer validation, receiver listening/valid preview receipt/error state, watcher root/state, and existing Follow phases. Return to listening when all preview peers close while preserving last-receipt time. Keep generation checks on queued callbacks. Do not infer host installation/liveness from log existence or peer counts.
- [x] Add the public APIs/command and transport facts to health. Document the snapshot schema, exact activity labels, optional statusline expression, User event, and recovery commands. Wire `tests/status.lua` into CI and AGENTS.md.
- [x] Run the new status test, metadata tests, and `npm run test:live`; expect success without notification spam or content in persisted records. Commit with `feat: expose agent activity and bridge status`.

## Task 3: Pause Follow and hand editing back to source buffers

**Files:** Create `follow_view.lua`, `tests/follow_controls.lua`; modify `follow.lua`, `motion.lua`, `init.lua`, `config.lua`, relevant existing Follow/motion tests, README, Vim help, AGENTS.md, and CI.

**Interfaces:** Consumes `paths.resolve()` and `status.set()`. Produces `follow.pause(reason?: string): boolean`, `follow.resume(): boolean`, `follow.state(): FollowState`, and `follow.stop(): nil`, preserving existing setup/toggle/clear/location/preview APIs. Produces view methods `setup(opts, on_user_input: fun(reason: string, insert: boolean)): nil`, `render(target: FollowTarget, draft?: DraftSnapshot): boolean`, `freeze(): nil`, `handoff(): boolean`, `current(): {win?: integer, buf?: integer, draft: boolean}`, and `clear(): nil`. View methods own buffers/rendering; controllers own correlation/pending snapshots. Add `lens.pause_follow()`, `lens.resume_follow()`, `:AgentLensPause`, `:AgentLensResume`, `follow.auto_pause = true`, and `keymaps.resume = "<leader>ar"`.

- [x] Write tests `freeze_and_resume_latest`, `input_wins_over_queued_frames`, `insert_handoff_keeps_unsaved_text`, `settled_and_cancelled_while_paused`, `stale_root_snapshot`, and `unsafe_modal_state`. Feed actual normal-mode navigation/Insert keys for input tests. Exercise a queued animation followed by input and a newer metadata callback; buffer/view must stay at the user's paused position. Core assertions include:

  ```lua
  assert(follow.pause("navigation"))
  assert(follow.is_enabled() and follow.state().control == "paused")
  assert(vim.deep_equal(before_lines, vim.api.nvim_buf_get_lines(draft_buf, 0, -1, false)))
  assert(vim.deep_equal(before_view, vim.api.nvim_win_call(win, vim.fn.winsaveview)))
  assert(follow.resume() and follow.state().control == "following")
  ```

  Set `animation = false` for exact snapshot assertions; test cancellation of queued 180 ms motion separately. Deliver many paused snapshots and resume to the newest one. Complete/error/close calls while paused, and verify no stale revival. Programmatic Follow movement must never auto-pause itself.
- [x] Run `nvim --headless -u NONE -l tests/follow_controls.lua`; expect FAIL for the missing controls.
- [x] Extract source/draft/window rendering into `follow_view.lua`; retain path/load protections and compatibility namespaces. Detect actual user input with input provenance and guarded programmatic changes, not bare CursorMoved events. Cancel queued motion on pause, maintain one bounded latest pending snapshot, and implement safe Insert-mode source handoff without replaying a key.
- [x] Implement the control APIs and new commands/mapping. Pause current-window Follow when the user leaves its window/tab or enters unsafe modal conditions; apply `auto_pause = false` only to ordinary-navigation pauses. Unsafe/unloadable resume stays paused with a visible reason. Clear returns enabled Follow to following/waiting; `lens.stop()` invokes `follow.stop()` and stops transports, leaving control off. Explicit resume enables Follow and restarts required watcher/transports through orchestration. Publish control changes through status.
- [x] Add documentation/CI commands. Run controls, existing Follow lifecycle, motion, metadata, and real preview integration tests; expect all success messages and unsaved text unchanged. Commit with `feat: pause agent following for user navigation and editing`.

## Task 4: Follow in an owned agent split

**Files:** Modify `follow_view.lua`, `follow.lua`, `config.lua`, `init.lua`; create `tests/follow_split.lua`; update README, Vim help, AGENTS.md, and CI.

**Interfaces:** Consumes Task 3's view/controller contract. Extend view setup with `follow.window` and `follow.split`; add `follow.set_window(mode: "current"|"split"): boolean`, `lens.set_follow_window(mode): boolean`, and `:AgentLensFollowMode [current|split]`. Defaults are `window = "current"`, `split = {position = "right", width = 0}`; zero is half-width, positive widths clamp, position is right/left. No-argument command toggles mode.

- [x] Write `split_keeps_focus`, `unrelated_edit_does_not_pause`, `input_inside_split_pauses`, `inactive_tab_catches_up`, and `closed_or_repurposed_split`. Assert split updates keep the original current window/buffer and modified text; navigation within the agent split pauses; closing it does not recreate it on incoming data; changing tabs causes no inactive cursor/window changes; returning catches up. Repurpose the split with a user buffer and assert teardown preserves it. Include very narrow editors and invalid mode/width inputs.
- [x] Run `nvim --headless -u NONE -l tests/follow_split.lua`; expect FAIL for the missing mode API/behavior.
- [x] Implement one owned split, sizing, no-focus creation, guarded teardown, inactive-tab catch-up, and mode transitions preserving control state. Render compact status in its owned winbar; after a user changes that winbar, stop replacing it. Resume/mode actions are the explicit opportunities to recreate a closed split.
- [x] Document options/mode command and wire the new tests. Run split and controls tests plus existing protected-window Follow tests; expect success. Commit with `feat: add a dedicated agent follow split`.

## Task 5: Group the timeline and preserve selection

**Files:** Create `panel_model.lua`, `tests/timeline_panel.lua`; modify `timeline.lua`, `panel.lua`, `config.lua`, `init.lua`, metadata tests, README, Vim help, AGENTS.md, and CI.

**Interfaces:** Produces `timeline.acknowledge(ids: integer[]): nil`, `timeline.mark_all_seen(): nil`, `timeline.unread_ids(): table<integer, boolean>`, `timeline.latest_edit_for_path(path): TimelineEntry|nil`, and an extended `summary()` retaining existing keys plus reads/edits/unread. Summary change numbers use the latest retained edit per file. Preserve/copy `TimelineEntry.range`. Produces `panel_model.project(entries: TimelineEntry[], opts: PanelOptions, unread_ids: table): PanelRow[]` and `panel_model.select(rows: PanelRow[], previous_rows: PanelRow[], previous_key?: string): string|nil`. Keys are `file:<path>` and `event:<id>`. Panel adds `setup(opts: {view: "files"|"events", filter: "all"|"reads"|"edits"}): nil`, `set_actions({open: fun(entry): boolean, preview?: fun(entry): boolean, browse: fun()}): nil`, `set_filter(filter): nil`, and `selected_ids(): integer[]`; `selected()` remains an entry-returning API. Setup initializes runtime expansion/unread-only state empty/false.

- [x] Write tests `read_range_survives_storage`, `latest_edit_stats_are_not_summed`, `stable_selection_and_screen_anchor`, `filters_expansion_and_acknowledgement`, `retention_and_clear`, and `unicode_percent_narrow_paths`. Two edit snapshots of one file with stats +3/-1 and +5/-2 must summarize +5/-2 even after a read. Select an older event, add a new event and reorder its group, then assert selected ID and screen offset are unchanged. Successful callbacks acknowledge matching IDs; false callbacks, scrolling, and rendering do not. Check trimming and clear prune acknowledgement/selection state.
- [x] Run `nvim --headless -u NONE -l tests/timeline_panel.lua`; expect FAIL for missing grouping/acknowledgement APIs.
- [x] Implement range preservation and bounded acknowledgement/latest-edit accounting in `timeline.lua`. Implement pure grouping, filtering, visible rows, group action resolution, and stable selection fallback in `panel_model.lua`.
- [x] Render model rows at actual display width, preserve selected row/screen anchor, and add status/header/footer. Add Tab expansion, f filters, u new-only, m mark-all-seen, g files/events, and existing navigation/close/refresh actions. Open a group via its latest edit when edits are included, otherwise latest matching read. Register p when a preview callback is provided by Task 7. Update action callbacks only through `set_actions()` to avoid importing orchestration into the pure model.
- [x] Add `timeline = {view = "files", filter = "all"}`, command `:AgentLensFilter [all|reads|edits]`, docs, and CI tests. Connect browsing to current-mode pause. Run timeline/panel, read, and existing timeline smoke tests; expect success. Commit with `feat: group agent activity with stable timeline selection`.

## Task 6: Supply safe current review comparisons

**Files:** Modify `diff.lua`; create `tests/review_diff.lua`; update Git comparison/architecture documentation in README, Vim help, AGENTS.md, and CI.

**Interfaces:** Consumes `paths.resolve()`. Preserve `file_diff(root, path): FileDiff|nil`, `head_contents()`, `working_contents()`, and `status_summary()`. Add `diff.review(root, path): FileDiff|nil, string|nil` for a validated current comparison with a useful error, and `diff.changed_files(root): string[], string|nil` for safe current paths in deterministic order, including deletions/untracked files. Use NUL-delimited Git path output. Missing HEAD is an explicit unavailable-baseline error, not a successful empty review. Keep rename fallback as separate old/new paths.

- [x] Write `partial_deletion_is_modified`, `added_deleted_and_untracked`, `special_paths_and_binary`, `unsafe_review_targets`, and `worktree_and_unborn_head`. Create temporary commits and changed files; assert partial line deletion is modified, missing tracked file is deleted, untracked file is added, safe special filenames resolve correctly, binary/unsafe paths cannot become text review, linked-worktree HEAD is used, and unborn HEAD returns nil with an explanatory error. Assert `changed_files()` is sorted/deduplicated and filenames are not misparsed as Git flags or object syntax.
- [x] Run `nvim --headless -u NONE -l tests/review_diff.lua`; expect FAIL for missing review/list APIs or the existing partial-deletion classification.
- [x] Implement review validation/error handling and safe enumeration. Determine file status from actual HEAD/disk existence. Treat Git output/return codes explicitly, including no-index diff exit 1. Do not read disk contents through rejected paths, and do not label binary/unavailable comparisons successful.
- [x] Document current comparisons, missing-HEAD recovery, and tracked/untracked/deletion behavior; add test invocation. Run review-diff, path, and existing diff/inline behavior tests; expect success. Commit with `fix: validate current review diffs and changed file paths`.

## Task 7: Preview hunks and preserve the editor during full review

**Files:** Modify `diff_view.lua`, `init.lua`, `panel.lua`; create `tests/review.lua`; update README, Vim help, AGENTS.md, and CI.

**Interfaces:** Consumes `diff.review()`, `diff.changed_files()`, panel selected entry/IDs, and Follow state/pause. Produces `diff_view.preview(entry: TimelineEntry, opts?: {root: string}): boolean`, `open(entry, opts?): boolean`, `navigate_hunk(delta: integer): boolean`, `navigate_file(delta: integer): boolean`, `refresh(): boolean`, and existing `close()/is_open()`. Optional root retains direct-call compatibility; orchestration always supplies the watched root. Add `lens.preview(): boolean` and `:AgentLensPreview`; extend `lens.show_diff()` to return whether opening succeeded. Panel callbacks acknowledge selected IDs only on success. Read actions safely open the stored range with unsaved-buffer protection.

- [x] Write `hunk_preview_and_refresh`, `review_preserves_original_layout`, `changed_file_navigation`, `repurposed_windows_and_missing_origin`, and `current_vs_split_follow_review`. Capture multiple original windows, their buffers/views, and unsaved hashes; open/close hunk and full review and assert preservation. Compare an old selected event to current disk, not its cached diff. Add/remove hunks/files while reviewing; R refreshes, indices clamp, and no filesystem event moves selection. Closing origins/reusing review windows preserves user buffers and chooses a safe surviving return window.
- [x] Run `nvim --headless -u NONE -l tests/review.lua`; expect FAIL for the missing preview API and existing disruptive full diff behavior.
- [x] Implement the bounded unified hunk float and separate full-review tab, carrying a `ReviewOrigin` through preview-to-full transition. Use unique session buffer names/owner tokens and compact file/comparison/hunk labels in owned UI. Never use `:only` in the original tab or force-delete user-modified/reused buffers. Keep the configured native diff orientation. Clamp hunk/file navigation at ends and refreshed hunk indices; use deterministic path order and a clear no-more-changes message when appropriate.
- [x] Bind ]h/[h, ]f/[f where applicable, R, q/Esc, and preview Enter-to-full. Restore the origin view only if its buffer is still the captured buffer. Close owned windows individually when a review tab contains user windows. Include cleanup after manual closure and avoid closing the last editor window.
- [x] Wire watch-root selection, current-mode pause, read-range opening, `:AgentLensPreview`, and timeline p/open callbacks. Dedicated split control stays following while its inactive tab retains latest activity; paused Follow never resumes merely because review closes.
- [x] Update docs/CI and run review, review-diff, timeline/panel, controls/split, and existing Follow safety tests; expect success. Commit with `feat: add hunk preview and preserve editor layout during review`.

## Task 8: Verify the integrated workflow, documentation, and live installation

**Files:** Modify/add `tests/ui_workflow.lua`, `tests/live-preview.test.mjs`, `tests/live_preview.lua`, `.github/workflows/ci.yml`, README, Vim help, and AGENTS.md. The approved plan/spec remain reference documents.

**Interfaces:** Uses the public commands and APIs from Tasks 2–7; adds no new product interface.

- [ ] Write the integration scenario `watch_pause_browse_review_resume`: stream a draft, pause by user navigation, receive newer content, browse/acknowledge a grouped timeline row, review a hunk/full diff, close back to the original layout, then resume to authoritative latest data. Assert no unsaved text, protected window, or current input focus is replaced. Extend the real socket observer with control/state queries and test successful completion/connection closure while paused. If this new integration test already passes, record that result; do not manufacture a failure.
- [ ] Run `nvim --headless -u NONE -l tests/ui_workflow.lua` and `npm run test:live`; confirm any newly exposed integration failure before changing orchestration.
- [ ] Repair only integration failures, missing command/API wiring, or lifecycle cleanup. Verify setup/stop/clear/restart/root changes reset pending snapshots, status, acknowledgement, ownership, autocmds, and generation-guarded work consistently. Avoid refactoring unrelated watcher or extension parsing behavior.
- [ ] Audit README, Vim help, and AGENTS.md against every command/API/default in the approved spec and this plan. Document all new modules, types, state transitions, trust/ownership rules, keymaps, exact tests, privacy limitations, and recovery commands. Add every new headless test to the existing Neovim 0.10.4/stable/nightly CI matrix. Extend command/config smoke checks to the new interfaces.
- [ ] Run the complete existing/new Lua suites, `npm run test:extension`, `npm run test:live`, `npm pack --dry-run --json`, `stylua --check .`, available Luacheck, and `git diff --check`. Expect every available check to pass; accurately record an unavailable checker rather than claiming it passed.
- [ ] Capture actual Neovim UI at normal and narrow widths for Follow pause/resume, selected older timeline activity receiving updates, and hunk/full review returning to existing splits. Inspect the captures; correct visible clipping, focus shifts, stale labels, and unintended cursor motion, then rerun affected checks.
- [ ] Complete the independent review required by the selected execution method. For Native, use one fresh whole-branch reviewer on the most capable available model; for subagent-driven execution, also retain each task's implementer/reviewer gates. Address actionable findings and rerun affected verification before installing the new UI into the running session.
- [ ] Revalidate the user's current Neovim/OMP local plugin paths. At a naturally settled agent call, safely reload Agent Lens, retaining watched root, modified-buffer hashes, existing timeline entries and selection, and user window layout. Initialize old entries as acknowledged for this first migration; new activity arriving afterward is unread. Verify new commands, status, pause/resume, and receiver readiness. Update user configuration only for missing required enablement; preserve their settings and make a backup. OMP already links this checkout; verify bridge loading without interrupting its session.
- [ ] Commit the integrated tests/docs/fixes with `test: verify integrated agent watch and review workflows`, update plan checkboxes to reflect actual results, and report the shipped behavior and any material verification limitation. Do not mark spec acceptance items complete until their checks were performed.

## Coverage and handoff

| Spec section | Implementing tasks |
| --- | --- |
| Intent, constraints, metadata privacy, version/dependency rules | 0–8; retained extension/privacy tests in 8 |
| Follow state, manual input, Insert handoff, pending snapshots | 3; real-channel integration in 8 |
| Dedicated split, sizing, focus, tab/window ownership | 4; review interaction in 7–8 |
| Status, actual transport facts, health, optional integration | 2; panel/split/review presentation in 4–5 and 7 |
| Grouping, filtering, stable selection, ranges, acknowledgements | 5; successful action acknowledgement in 7–8 |
| Current HEAD/disk data, safe paths, changed-file enumeration | 1 and 6 |
| Hunk/full review, ownership, navigation, origin restoration | 7; live workflow in 8 |
| README, Vim help, AGENTS.md, CI, visual/behavior verification | Each owning task; final consistency audit in 8 |

Recommended execution is **Native**: these tasks share controller/view and
status/projection interfaces, so keeping implementation context in this
session should reduce coordination overhead. The required independent final
review focuses on editor safety, lifecycle races, privacy, and spec coverage.
Subagent-driven execution remains available if the user prefers an independent
implementer/reviewer gate for every task.

Implementation starts after the user reviews this plan and chooses the
execution method. At that point read the corresponding required execution
skill; do not treat written-spec approval as approval of this new artifact.
