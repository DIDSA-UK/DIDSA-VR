# VR testing feedback 2026-11-11: plan

Source: the owner's testing notes of 2026-11-11 (Godot VR client). This doc is for the implementation session.
Code pointers were read on branch `ccr-dec7d67f-ipq5rn` (= `main` plus this doc). Line numbers drift: search for the symbol.
**Nothing here was run** (no Godot, no headset, no backend in the planning session). Each item says how sure the cause is.
Headless tests cannot judge feel or fake a real grip (see `CLAUDE.md`); each item says what a test can and cannot cover.

The file-format and desktop-mode items from the same notes are in `DIDSA-UK/DIDSA-CAD`,
`docs/iges-jt-and-desktop-input-plan-2026-11-11.md`. Its F-3 adds one line to this repo (`main.gd`, `project_folder.gd`).

| Item | Summary | Kind | Cause certainty |
|---|---|---|---|
| V-1 | Grabbing a fixed parent assembly does nothing, with no "part is fixed" message on the hand | Bug (feedback) | High: the code paths are known |
| V-2 | Relaxed mates: cycling to the parent keeps small movements of the child | Bug | **Low: not found by reading; repro first** |
| V-3 | Appearance tool: a paint shows nothing until the next paint | Bug | High (a race, read in the code) |
| V-4 | Mate preview ghost sometimes missing though Create moves the parts | Bug | High (preview skips a step Create does) |
| V-5 | Fix / Float: controlled from the Assembly Tree, not the wheel; the wheel gets only "Relax fix" | Decision | n/a |
| V-6 | "Relax fix mates": grab a grounded assembly and carry it, mates intact; temporary | Feature | n/a (owner's rules below) |
| V-7 | Assembly Tree: state icons (fixed, constraint, hidden), selection both ways, an action bar (Fix / Float, Hide, Isolate, Rename, Room, Delete), stays current | Feature + bug (repeat sub-assemblies select the wrong part) | High (read) |

Suggested order: **V-3 → V-4 → V-1 → V-7 → V-5 → V-6**, with **V-2** investigated in parallel (it needs a reproduction before any fix).
V-7 brings Fix / Float (V-5); V-6 adds the Relax fix wedge to `scripts/ui/wheel_flows.gd` `_mates_entries`.

Vocabulary the notes use: **"fix mate"** = an occurrence's `fixed` (grounded) flag; the backend has no "fix" mate type
(`MateType` is coincident, concentric, parallel, distance, angle, gear, rack_pinion, screw, limit_*).
**"Hand disc"** = the badge disc above the right hand (`ui/tool_badge.gd`) and the wrist hint panel next to it (`ui/wrist_hint.gd`,
fed by `ui/wheel_flows.gd` `say()` / `prompt_text()`).

---

## V-3: paint shows nothing until the next paint (do first, high confidence)

**Cause (read).** `scripts/appearance_tool.gd`:
- `ensure_loaded(root)` skips a part only when `_loaded.has(pid)`. `_load_part(pid)` makes **five sequential awaited requests**
  and only sets `_loaded[pid] = true` and `_model["parts"][pid] = entry` at the very end.
- `controller.gd` `_arm_paint` calls `appearance_tool.ensure_loaded(...)` **fire-and-forget** on trigger-down, and
  `_finish_paint` calls `await ensure_loaded(...)` again on trigger-up. If the first load is still in flight (always, for a quick
  click on a part not yet read), the second call sees `_loaded` unset and starts a **duplicate** `_load_part`.
- Then `apply()` → `_store()` PUTs the override, writes the response into `_model["parts"][root]` and repaints. A load that began
  **before** the PUT finishes **after** it and does `_model["parts"][pid] = entry` with the *old* override list: the paint vanishes
  from the model. The screen shows the old colour. The **next** paint's PUT response returns the whole override list again, so the
  earlier colour "appears later". That is exactly the report.
- `_busy` only covers the PUT, not the loads.

**Fix.**
1. In-flight de-duplication: `var _loading: Dictionary = {}` pid → true (or a stored `Signal`/awaitable). `ensure_loaded` /
   `_load_part` for a pid already loading must **await the existing load**, not start another. Simplest: keep a
   `Dictionary` pid → `Array[Callable]`/a `_load_done(pid)` signal and `await` it.
2. Never let a load clobber newer data: give the model a `_version` counter bumped by `_store` (every successful PUT) and by
   `_set_overrides`. `_load_part` records the version when it starts; when it finishes, if the version changed, **merge only the
   fields it alone owns** (names, occurrences, patterns) and keep the model's current `appearance_overrides`
   (or re-fetch `/appearance-overrides` once). Do not overwrite.
3. `_finish_paint` / `_paint_row` should `await ensure_loaded` (they do) **and** `apply()` should treat `is_busy()` as
   "a load or a PUT is running" so two quick clicks cannot interleave (the controller already refuses a new press while `_busy`).
   Extend `is_busy()` to include `_loading`.
4. Check `_mirror_legacy` while there: it only mirrors when `record.size() == 1`. Painting a *body* of a top-level occurrence
   sends `{path, body_id}`; confirm against the backend (`appearance_routes.py` `put_appearance_override`) whether that case also
   writes `Occurrence.color` and is returned flagged `legacy`, because `_set_overrides` **skips `legacy` rows**. If it does, that is
   a second way to lose a fresh paint; fix by mirroring for every record the backend marks legacy.

**Test.** `tests/appearance_tool.gd` with `tests/fake_appearance_api.gd`: make the fake delay the first
GET `/parts/{id}` by a few frames, call `ensure_loaded` twice, then `apply`, then let the delayed load finish; assert the model
still holds the override and the node is painted. This one is fully testable headless. Also add the "two quick paints" case.

---

## V-4: mate preview ghost sometimes missing though Create works

**Cause (read, high confidence).** `scripts/mates_tool.gd`:
- `create_mate()` with `atomic` **first PATCHes the driven part's current pose to the backend**
  (`PATCH /parts/{owner}/occurrences/{driven}` with `pose_to_json(_local_pose(part))`; its comment: "the solver starts from the
  stored pose, so without that it would solve from wherever the part used to be"), then POSTs the mate with the solve.
- `_run_preview()` POSTs `.../preview-mate-solve` **without that sync**. If the stored pose is stale (the part was moved by hand,
  `persist_pose` is async or was skipped, or the part was moved in a sandbox or room), the preview solves from the wrong start:
  it may **not converge**, and `preview_members()` returns `[]` for `converged == false`, so **no ghost and no message**
  (`status_text()` then says "Ready — choose a mate type and Create."). Create syncs, converges, and moves the parts. That is the
  report.
- Other silent paths in `_run_preview` worth fixing together: a non-OK HTTP result and `_find_loaded_part()` returning null both
  produce no ghost and no message; a newer `request_preview()` supersedes a slower one via `_preview_seq` (correct) but five call sites
  re-fire it, so a burst can leave the last one pending while the picks are complete.

**Fix.**
1. Before the preview request, sync the driven part's pose exactly as Create does: factor the PATCH out of `create_mate()` into
   `_sync_driven_pose(owner, driven, part)` and call it from both (skip it when relaxed, or when the driven part is fixed / a
   pattern copy: same conditions as `atomic`). Debounce: only PATCH when the pose differs from the last pose sent
   (`_last_synced_pose[occ]`), so a flurry of Flip / Next-solution presses costs no extra requests.
   Alternative to evaluate: a `driven_transform` field on the preview request, if the backend's
   `MateSolvePreviewResponse` / endpoint can take one (`router.py` `preview_mate_solve_endpoint`, ~line 5184). That avoids writing
   state during a preview, which is better, but it is a backend change; use the PATCH unless the owner wants the endpoint change.
2. Say why when there is no ghost. In `_run_preview` set a `_preview_note` from: HTTP error (`_friendly_error(result)`), `converged ==
   false` ("The mate can't be met from where the part is: move it closer, or Flip / Next solution"), `members` empty, or the part not
   found on screen. `status_text()` shows it instead of "Ready". Keep "Ready" only when a ghost is shown or the type has none.
3. Log (`print("DIDSA VR: preview: ...")`) the reason once per request: the owner will see it in `adb logcat` next time.

**Test.** `tests/mates_tool.gd` with `tests/fake_mates_tool.gd` / the existing mate request fakes: a fake backend that converges
**only** if the PATCH arrived first; assert the ghost appears (fails today). A second case: `converged: false` sets the note. The
live-backend `tests/e2e_mates.gd` may be extended with "move part by hand, then preview" (needs a running backend; list in
`tests/e2e_ci_list.txt`).

---

## V-1: grabbing a fixed parent does nothing, and says nothing on the hand

**What exists.** The user-facing messaging system is the controller's `tool_message` signal: `main.gd` ~558 connects it to **both**
`_set_status` and `_wheel_flows.say` (the toast on the wrist hint panel). Refusals for a single part already use it
(`mates_tool.notify_locked`, `notify_nested_locked` via `_report`, shown by the mates prompt) plus a haptic
(`trigger_haptic_pulse("haptic", 0.0, 0.6, 0.12, 0.0)`).
For **groups** the refusal text goes to `group_message`, which `main.gd` ~183 connects **only to `_set_status`** (the console / launcher
status), **not** to `_wheel_flows.say`. So it never reaches the hand disc. That is the gap.

**A second gap.** `controller.gd` `_group_refusal(gs)` checks "grounded" only for `gs.depth == 1`
(`mates_tool.group_state(root, occ)` → `"grounded"`). For a deeper group (`depth > 1`, a fixed sub-assembly inside a sub-assembly) it
checks only `nested_occurrence_locked` (mated), never `fixed`, so a grounded sub-assembly one level down is not refused with the
right words and the part either does not move or moves on screen only. The owner's case ("a fix on the parent assembly") may be this
one; check which depth it was.

**Fix.**
1. Route every group refusal to the hand: in `_begin_group_hold` (where `group_message.emit(refusal)` is) also
   `tool_message.emit(refusal)`, or simply connect `group_message` to `_wheel_flows.say` next to the existing `_set_status`
   connection in `main.gd`. The latter also shows "Holding X (n parts)" and the breadcrumb on the wrist: check that is wanted;
   if not, emit only the refusal text on `tool_message`.
2. Add a **short** hand message for the fixed case, as the owner asked: `"Part is fixed"` as the title or first words, then the rest
   ("Float it in the Assembly Tree, or Relax fix"). Keep the existing long text for the status line. Haptic already fires; keep it.
3. Make `_group_refusal` complete: for any depth, walk the group's chain of occurrences (`gs.prefix` / `group_parts`) and refuse if
   **any ancestor level is fixed** (use `occurrence_state(owner)` for the top level and `_nested_states[part_id]["occurrences"]`
   for deeper ones; add `mates_tool.group_fixed(owner_part_id, occurrence_id) -> bool` next to `group_state`). Use it for the depth > 1 case.
4. **Tell the user while cycling, before they commit.** `_show_latch_level` / `GroupIndex.breadcrumb` build the caption per level.
   Append "(fixed)" to a level that `_group_refusal` would refuse, and tint the brackets amber (`GroupCues.brackets`), so the
   user sees it before leaving the dead zone and not after. Reuse the same refusal function (call it with a `GroupSet` built for
   that level, or split the check into a pure `refusal_for(level)`).
5. Respect V-6: when "Relax fix mates" is on, a fixed ancestor does **not** refuse (see V-6).

**Test.** `tests/group_select.gd` (latch and cycle, headless): a fixed sub-assembly at depth 1 and depth 2 → the refusal text is emitted
on both `group_message` and `tool_message`; the caption carries "(fixed)". Haptic cannot be asserted headless.

---

## V-2: relaxed mates, cycling to the parent keeps small child movements (reproduce first)

**What the owner wants.** Grip a part, cycle (trigger) to its parent, then move: the child must not have moved relative to the parent.

**What the code says.** The grip **latches** and moves nothing: `_try_grab` → `_begin_latch(target)` (only for parts inside a
sub-assembly, `GroupIndex.has_groups`, and only with `group_deadzone > 0`); trigger clicks `_cycle_latch`; leaving the dead
sphere runs `_commit_latch` → `_begin_group_hold(target, level)` → `GroupSet.new(...)` (which records `starts` at *that* moment)
and `_begin_hold(target, target.global_transform)` (grab offset taken at that moment). By that code nothing moves during the
cycling, so **the cause was not found by reading**. Do not guess a fix; reproduce.

**Candidates to check, in order.**
1. **The latch is not what is running.** With `group_deadzone` Off (Settings > Rooms, `app_settings.gd` `group_deadzone` 0), or for a
   part `GroupIndex.has_groups` says has no groups, the grip takes the *part* at once (`_begin_part_hold`) and it **follows the
   hand immediately**; the owner then "cycles" on a part that is already moving. Check what the setting was, and what
   `has_groups` returned, on the owner's assembly. If this is it, the real bug is that a grip can start moving the child before
   the user can choose: in that case also latch when the part is held at depth 0 inside a sub-assembly regardless of the setting, or
   make the setting's "Off" mean "take the innermost, no cycling" and say so.
2. **Relaxed (sandbox) specifics.** In the sandbox every part is "remembered" in `mates_tool._home` and `is_sandboxed(part)` is true;
   `_group_refusal` returns "" at once. Check `_commit_latch` vs the pose of the *child* after leaving the sphere: the dead zone
   is translation-only (`assembly-rooms-scope.md` 4.1: "the part does not rotate while latched"), but `_begin_hold` computes
   `_grab_offset = global_transform.affine_inverse() * target.global_transform` from the hand's **current** rotation, and
   `_update_held_part` applies the hand's **rotation** from then on. A hand that rotated a few degrees during the cycling
   therefore rotates the group about the grab point with no deliberate gesture. Confirm by logging the child's and the hand's
   transforms at `_begin_latch` and `_commit_latch`.
3. **The group's members were moved before the commit by something else**: the thumbstick / A / B push on a *selected* group
   (`_sel_group.follow()`), scene or sandbox ghost updates (`mates_tool` `_process` while relaxed), or `two_hand_model.gd` (the
   other hand's gesture moving the world, ~line 399, skips only `held` nodes).
4. **Rotation at commit.** If 2 is the cause, fix by freezing the hand's rotation at latch time: store `_latch["basis"]` and, at
   commit, build the hold so the group keeps its pose and only follows rotation changes **from the commit moment**
   (`_grab_offset` from the hand pose at commit is already that; so check that `_begin_hold` is really given the pose at commit).

**First step (a test, not a fix).** Extend `tests/group_select.gd`: grip a child in a two-level fixture, move the hand inside the
dead zone and rotate it a little, click the trigger twice, assert **every member's global transform is unchanged** at every step, then
move the hand out and assert the first frame after commit does not change any member's pose. Run it with mates relaxed
and unrelaxed. If it passes, the cause is not in this path: ask the owner for the exact sequence (hand held still? Off setting? which
depth?) and add logging at `_begin_latch`, `_cycle_latch`, `_commit_latch`. State plainly in the PR that the cause was not
reproduced if that is the outcome.

---

## V-5: Fix / Float lives in the Assembly Tree (owner's decision, 11 Nov); the wheel gets only "Relax fix"

**Decision.** Fix / Float is **not** a mates-wheel action and not a mate type. It is controlled from the **Assembly Tree** (V-7), as in
desktop CAD (the flat app already does it there: `component_context_menu.dart` Fix / Float, and a push-pin in
`assembly_tree_panel.dart`). The earlier wheel-wedge and "Fix as a mate type" ideas are dropped.

What stays on the mates ring: **one** new wedge, **Relax fix** (V-6), beside Relax / Return parts, so it sits where Relax mates sits
(mates ring, tablet toggle under "Relax mates", the pill turns into Return while on). Seven wedges, clockwise from the top: Create ·
Type · Flip · Clear picks (straight down) · Relax fix · Relax / Return parts · All tools (check the order puts Clear straight down at
seven; if not, move one wedge so it is; the bottom wedge is never a sub-wheel). Update the comment above `_mates_entries` ("six
wedges") and the wheel tests that count wedges.

The tablet's "Fix / Float selected part" button (`tablet_pages.gd` ~773) stays as a fast path for the laser-selected part; it calls the
same function as the tree (one implementation: `mates_tool.toggle_fixed`, made undoable in V-7).

---

## V-6: "Relax fix mates": move a grounded assembly as one, mates intact

**Owner's description (settled).** With fix-relax on, the user can grab a grounded part, **or a part grounded by mates to another grounded
part**, and move / turn the assembly around in the world **while all its mates are maintained**. Fix mates are a staple of CAD and
let the designer control the design; relaxing them is a **temporary** switch, and turning it off sends everything back exactly as
Relax / Return parts does ("reinforce").

**Rules.**
- Only **fixed** is relaxed. Every other mate stays enforced. This is **not** the full sandbox (where mated parts are left behind).
- **Grounded cluster** = every part reachable by mates (breadth-first through `mates`, skipping coupler / limit mates, which place
  nothing; pattern copies follow their source) from a **fixed** part. Grabbing a part that is *in* a grounded cluster **and has no
  free motion** (fixed itself, or fully constrained by its mates to that cluster) carries the **whole cluster rigidly**, anchor =
  the part in hand. All relative poses in it are unchanged, so every mate stays satisfied.
- A part in the cluster **with free motion** (a hinge, a slider) keeps its ordinary constrained drag (it moves within what its mates
  allow; the rest stays put): relaxing fix does not change that. The cluster only moves when what you hold cannot move on its own.
  **How to tell:** the existing live solve already says it: `_accept_anchor` (`mates_tool.gd` ~2620) sets `state["stuck"]` when the
  backend returns an empty free-motion `basis` ("fully constrained: it can't move. Relax all mates..."). With fix-relax on, that
  moment **promotes the drag to a cluster carry** from the part's current pose (rebase the hold: `_grab_offset` from the hand and
  the part now, so there is no jump) instead of just buzzing. A *fixed* part never starts a solve: it carries the cluster at once.
- Parts **not** connected to a fixed part by mates (free parts, a separate cluster with no ground) are untouched: ordinary grab.
- **Temporary, like Relax:** nothing is saved (no `persist_pose`, no PATCH). Each part moved is remembered in `_home` the first time
  it is carried (same structure as `_enter_sandbox`), and "Return" restores every remembered pose in one undo step
  (`return_parts()`), exactly as the full sandbox does. Undo / redo of "return parts" works the same.
- Mates made or edited while fix-relax is on are solved when the parts go home, as in the sandbox (`note_sandbox_mate`).
- Two modes, one rule for the pill and prompt: `relaxed` (all) and `relaxed_fixed` (fix only). Turning **Relax** (all) on while
  fix-relax is on promotes to the full sandbox **keeping `_home`**; turning fix-relax on while Relax is on is a no-op (greyed with
  "Mates are already relaxed").

**Implementation sketch.**
0. UI: the wedge in V-5, the tablet toggle, the pill. Fix / Float itself is in the tree (V-7).
1. `mates_tool.gd`: `var relaxed_fixed := false`, `set_relaxed_fixed(on)` (off = `return_parts()`), a pure
   `grounded_cluster(owner_part_id, occurrence_id) -> Array[String]` (unit-testable), `in_sandbox()` = `relaxed or relaxed_fixed`
   for "moves are temporary" readers. Go through every use of `relaxed` (about 40: `grep -n "relaxed" scripts/*.gd scripts/ui/*.gd`)
   and decide: "mates are not enforced" (keep on `relaxed`) vs "temporary / has a sandbox" (use `in_sandbox()`): the appearance tool's
   temporary paint, scenes, `is_sandboxed`, the pill, `_return_parts`, the tablet toggle text.
2. `is_locked(part)` (fixed + mated + enforced, the "grounded by a mate" refusal in `controller._try_grab`): false when `relaxed_fixed`.
   `_group_refusal` (V-1): a fixed level no longer refuses when `relaxed_fixed`.
3. `controller.gd`: when the target is in a grounded cluster and carrying applies, build the carrier from the cluster's nodes (reuse
   `GroupSet`: anchor + `follow()` / `restore()` / `finals()`), set `_held_group`, so `_update_held_part` skips `constrain_drag`, and
   release does **not** save (`_finish_group_move` already computes `sandbox := mates_tool.is_sandboxed(gs.anchor)`: make every
   cluster member `is_sandboxed` while carried, and record `_home` for them on first carry). The cluster's nodes come from
   `_find_loaded_part(owner, occ)` for each id; nested clusters inside a sub-assembly use `_nested_states`; if the cluster crosses a
   sub-assembly boundary take the whole sub-assembly (the group levels from `group_index.gd`).
4. Haptics / messages: a short buzz on carry start; `say("Moving the fixed assembly: Return puts it back")` once per press.
5. UI: V-5's "Relax fix" wedge (the only one) (label "Return" while on) and a toggle under "Relax mates" on the tablet (`tablet_pages.gd` ~742) with
   the same unsaved-scene guard the existing toggle has. `wheel_flows.gd` prompt (~115): "Fix mates relaxed: grab a fixed part
   and its assembly comes with it. Return puts everything back." While on, `pill_entry()` is Return (as for full relax). The
   mates-ring prompt names the mode. While fix-relax is on, tint fixed parts' brackets / add a small pin marker so the user can see
   what will carry.
6. The ghost / lines options (Settings > Assemble: "Relaxed: ghost where each part goes back" / "line to where it goes back") apply to
   fix-relax too, since they read `_home`.

**Tests (headless; `tests/mates_sandbox.gd` style, with `fake_mates_tool.gd`).** (a) pure cluster test: fixed A, B mated to A, C mated to
B, D unmated, E on a separate ungrounded pair; the cluster of A is {A,B,C}; (b) grab A with fix-relax on: A, B, C move rigidly
(relative transforms unchanged to tolerance), D and E do not, nothing PATCHed on the fake backend; (c) grab C when the fake solve
reports an empty basis (stuck): promotes to the cluster carry without a pose jump; with a non-empty basis it stays a constrained
drag; (d) Return restores every pose in one undo step; (e) fix-relax then full Relax keeps `_home`; (f) off by default and not
persisted across a reload. **Cannot be tested headless:** how the carry feels with the hand, and the real solver's stuck report
timing (the live-backend e2e `tests/e2e_mates_motion.gd` can cover the second).

---

## V-7: the Assembly Tree, made a real CAD tree (owner: "we've neglected the tree")

**What exists** (`scripts/assembly_tree_window.gd`, 375 lines, a floating `diegetic_panel` 0.28 x 0.34 m / 480 x 600 px, opened from the
tablet): lazy GET `/parts/{id}/occurrences` per level, Part names filled in, rows with an expand arrow, a name button, and two buttons on
**every** row: **Room** and **Delete** (two-press "Sure? (n mates)"). Tapping a name calls `main.select_part_by_occurrence_id(id)`.

**Gaps found.**
1. **No state on the rows.** `OccurrenceResponse` already returns `fixed`, `hidden`, `suppressed`, `color`, and unresolved files
   (`resolved_part_id == null`); none is shown. The backend's `GET /parts/{id}/constraint-status` (fixed / fully constrained /
   under-constrained with DOF / over-constrained; what the flat app's tree icons use) is not read.
2. **Tree → world selection is wrong for repeats.** `select_part_by_occurrence_id` matches the **first** visible node whose
   `occurrence_id` meta equals the row's id. A sub-assembly placed twice has the **same** child occurrence ids under both
   placements, so a row under the second placement selects the part in the first. Match on the full path instead (`group_path`
   meta, `group_index.gd`: the occurrence ids from the root down).
3. **Sub-assembly rows can't be selected** ("expand it and select one of its own parts"), although the world can now select a group
   (`controller.select_group_level`).
4. **No world → tree.** The controller has no selection signal; selecting in the world does not highlight, expand to, or scroll to
   the row.
5. **No Fix / Float, Hide / Show, Isolate, Rename** from the tree; Room and Delete are always on screen on every row, which crowds a
   480 px panel and makes a mis-press on Delete easy.
6. **Goes stale.** It only refreshes on `mark_stale()` (file opened, part added) or the Refresh button, not after a mate, a fix, a
   move, a delete in the world, or a room edit.

**Design.**

*Row layout* (one line each, left to right): indent · expand arrow · **state icon** · name (dimmed when hidden, struck / amber when
unresolved or suppressed) · nothing else. Per-row buttons go: the actions are on the **selected** row only (below).
State icon, one slot, same rule as the flat app (`_buildConstraintBadge`): **pin** = fixed; **lock** = fully constrained; **open
lock** = under-constrained (the DOF count in the hint); **warning** = over-constrained; nothing for a free, unmated part. Add `pin`
and `lock_open` / `warning` to `ui/ui_icons.gd` if missing (`lock` and `eye_off` exist). A hidden occurrence also gets `eye_off`.
Constraint status comes from one GET per expanded level's Part (`/parts/{part}/constraint-status`, keyed by occurrence id); fall
back to the `fixed` flag alone if the call fails.

*Selection, both ways* (one selection, shared with the world):
- Tap a row: a leaf selects its part, matched by **path** (fixes gap 2); a sub-assembly row selects the whole group
  (`select_group_level` with the level built from the row's path; `GroupIndex.levels` already builds these); the root row clears the
  selection. The selected row is highlighted with the theme's selection colour.
- Add `signal selection_changed(node: Node3D, level: Dictionary)` to `controller.gd`, emitted from `_set_selection`, `_clear_selection`
  and `select_group_level`. The tree listens (via `main.gd`): it expands the ancestors (fetching levels as needed), highlights the
  row, and scrolls it into view (`scroll_target` is the `ScrollContainer`). Debounce so a fast laser sweep doesn't refetch.
- Optional, after the above: laser hover on a row pre-highlights the part in the world (the same overlay `face_highlight` /
  `_set_grab_hover` uses), and hovering a part highlights its row.

*Actions on the selected row*: an **action bar** at the bottom of the window (fixed position, so it never scrolls away), showing the
actions for the selected row; greyed with the reason when not allowed:
- **Fix / Float** (label by state). `PATCH /parts/{owner}/occurrences/{occ}` `{"fixed": bool}` where owner = the row's
  `parent_part_id`. For the active root this is `mates_tool.toggle_fixed`; generalise it to take `(owner, occ, label)` so nested rows
  work too, and update the right state afterwards (`occurrences` for the active root, `_other_states` for a room's Part,
  `_nested_states` for a sub-assembly's). Make it **one undo step** (`command_stack.push`, persists). A fixed occurrence's mates now
  anchor on it: call the same refresh the mates tool does after a change (`refresh_mates` / `refresh_nested_state`).
  Not offered on the root row, on a pattern copy (its place is the pattern's), or on an unresolved file.
- **Hide / Show** and **Isolate**: use the world's existing, undoable hide (`main.gd` `_push_visibility_command` and the isolate
  code ~783), applied to every node under the row's path, so the tree and the Show / Hide wheel agree. Do not write the backend
  `hidden` flag here: the VR client's hide is a view action today; changing that is a separate decision (the flat app does write it).
- **Rename**: the popup keyboard (`popup_keyboard.gd`), `PATCH ... {"name_override": text}` (empty clears). One undo step.
- **Room** (open / close the row's Part as an Assembly Room) and **Delete** (two-press, "Sure? (n mates)"): the existing code,
  moved from every row to the bar.
- Later, not in this pass: Mate (start the Mates tool with this part as the first pick), Appearance (paint this row's level), a
  Mates folder under each assembly listing its mates (select one → `mates_tool` highlight, delete), search.

*Keeping it current*: refresh the affected level (not the whole tree; keep the expanded state and the selection) on
`mates_tool.mates_changed`, `mates_tool.document_changed`, `room_manager.rooms_changed`, a delete or add, and after its own actions.
Keep the Refresh button.

*Size*: the panel may need to grow (taller, e.g. 0.28 x 0.42 m) for the action bar; check readability at `open_distance` in the UI lab
(`lab/ui_lab.tscn`, F6) and `tests/` render checks.

**Where the flat app already is.** `client/lib/viewport3d/assembly_tree_panel.dart` has the pin and constraint icons, and
`component_context_menu.dart` has Edit alone, Focus, Move / Rotate, Hide, Isolate, Fix / Float, Mate, Pattern, Rename, Appearance,
Delete. Use it as the reference for wording and rules (e.g. "Float this component first" for a fixed part's Move / Rotate), so the
two apps behave the same. Nothing in this item changes the backend.

**Tests** (`tests/assembly_tree_window.gd` exists for the pure row code; `tests/e2e_assembly_tree.gd` for the live backend):
- pure: rows carry `fixed` / `hidden` / unresolved; the state icon chosen for each constraint state; the action list for a row
  (root, top-level, nested, pattern copy, unresolved);
- path selection: two placements of one sub-assembly, select a child row under the second, the node selected is the second's (fails
  today);
- world → tree: emitting `selection_changed` for a nested part expands its ancestors and marks its row;
- Fix / Float from a nested row PATCHes the parent Part's occurrence, updates `_nested_states`, and undo reverts it (fake backend);
- e2e: fix from the tree, then a grab of that part is refused with the V-1 message.
**Cannot be tested headless:** readability and reach of the bar in the headset.

---

## Verification limits (say these in the PRs)

- V-2's cause is unknown; if the new test passes, report "not reproduced".
- Headless runs cannot judge the haptic buzz, the feel of V-6's carry, or the wheel's real layout; the owner re-tests on the headset.
- V-3 and V-4 depend on timing against a real backend: the fakes in `tests/` reproduce the order, not the latency.
- Do not write "works on the headset" in `docs/status.md` (see `CLAUDE.md`).
- Update `docs/status.md`, add the new test files to `tests/run_all.sh` and `tests/README.md`, and index this plan in `docs/README.md`.
