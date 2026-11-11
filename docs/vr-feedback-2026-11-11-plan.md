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
| V-5 | No "Fix / Float" on the mates quick wheel | Missing feature (confirmed absent) | Certain |
| V-6 | "Relax fix mates": a sandbox for grounded parts only, so the assembly follows | Feature | n/a (design below) |

Suggested order: **V-3 → V-4 → V-1 → V-5 → V-6**, with **V-2** investigated in parallel (it needs a reproduction before any fix).
V-5 and V-6 both change `scripts/ui/wheel_flows.gd` `_mates_entries`; do them together or in that order.

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
   ("Unfix it to move it, or Relax fix mates"). Keep the existing long text for the status line. Haptic already fires; keep it.
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

## V-5: no Fix / Float on the mates quick wheel (confirmed absent)

`scripts/ui/wheel_flows.gd` `_mates_entries()` has six wedges: Create, Type (sub-wheel), Flip, Clear picks, Relax / Return parts,
All tools. The comment says the bottom 60° belong to the "Clear" pill and a sub-wheel must not sit there. Fix / Float exists **only**
on the tablet (`ui/tablet_pages.gd` ~773 "Fix / Float selected part" → `mates_tool.toggle_fixed(_main.current_selected_part())`).

**Design (follows the existing ring rules).** Replace the single "Relax" wedge with a **sub-wheel**? No: the rule in
`wheel_flows.gd` ~204 says Return parts must be a top-level wedge on every ring while relaxed. So:
- Add a **"Fix / Float"** wedge to the mates ring (it becomes 7 wedges: check `tool_wheel_math.wedge_for`/`wedge_outline` handle
  7 and that the straight-down slot stays the pill; if the ring looks crowded at 7, make **"Ground"** a sub-wheel
  ("Fix / Float", "Relax fix mates" from V-6, "Relax all mates"/"Return parts") placed in the slot Relax has now, and keep "Return
  parts" top-level while relaxed as the existing code does. **Recommended: this sub-wheel**: it needs no 7th wedge, and V-6's new
  toggle belongs in it.)
- Fix / Float acts on **the part under the laser, else the laser-selected part** (`_main.current_selected_part()`). On the wheel the
  hand is busy pointing at wedges, so do not require a fresh pick: use the selection, and when nothing is selected the entry is
  greyed with the hint "Select a part first (laser-select it)" (the `_action(...)` helper already takes a `hint_disabled`).
  Label by state: "Float" if the selected part is fixed, "Fix" if not (like `_relax_entry` swaps its label); `mates_tool.is_fixed(part)`.
- Call `mates_tool.toggle_fixed(part)` (a coroutine; the existing `_report` message "X is now grounded (fixed)" goes to the
  mates prompt; also `say(...)` it so it shows on the wrist hint).
- Add an icon to `ui/ui_icons.gd` ("fix"/pin). Update `tests/wheel_*` tests that count wedges (`ls tests | grep wheel`) and
  `docs` wheel descriptions (`landing/tips.gd` if it mentions the wheel).

**Test.** Wheel entry list test: the entry exists, is disabled with no selection, label flips with the part's `fixed` flag.
`toggle_fixed` is already covered by the e2e mates tests.

---

## V-6: "Relax fix mates": sandbox for grounded parts only

**Request.** Like "Relax mates", but only for **fix** (grounded) occurrences, so the user can pick up the part in the world and the
rest of the assembly stays in context.

**Interpretation (confirm with the owner; the default below is the plan).** With fix-relax on:
- A grounded part can be grabbed (no `is_locked` refusal, no `_group_refusal` "is grounded"), **and the parts mated (directly or
  through a chain of mates) to it move with it as one rigid cluster**, so nothing is pulled apart. That is "the assembly stays in
  context". Mates stay **enforced**: it is not the full sandbox, where mated parts are left behind.
- The move is **temporary**, like Relax: nothing is saved; **Return parts** puts everything back (reusing the sandbox's `_home`
  poses and `return_parts()`), and the tablet/wheel toggle shows "Return parts" the same way.
- Alternative reading (a persistent move of the whole assembly, i.e. an ordinary "move assembly" gesture) is simpler but is what the
  existing whole-model grab does already; so the plan assumes the temporary-cluster reading. **Ask the owner if it is wrong.**

**Implementation sketch (`scripts/mates_tool.gd`, `controller.gd`, wheel and tablet).**
1. State: `var relaxed_fixed := false` and `set_relaxed_fixed(on)`. Entering it calls `_enter_sandbox({})` (records `_home` for all
   parts, `relaxed` stays false so mates are still enforced everywhere else); to keep the two modes distinct add a
   `sandbox_kind: "all" | "fixed"` and make `is_sandboxed(part)` true in `fixed` mode only for the cluster being moved. Check every
   reader of `relaxed` (about 40 sites: `grep -n "relaxed" scripts/*.gd scripts/ui/*.gd`) and decide per site whether it means "mates
   not enforced" (leave false in fixed mode) or "the sandbox exists, moves are temporary" (use a new `in_sandbox()` that is true for
   both). The appearance tool's "temporary paint while relaxed" (`appearance_tool.gd is_temporary`) should follow `in_sandbox()`.
2. Cluster: a pure function `mate_cluster(owner_part_id, occurrence_id) -> Array[String]`: breadth-first over `mates` (each mate
   names two occurrences; skip coupler/limit mates, which do not place), the anchor first. Pattern copies follow their source.
   Pure and unit-testable (`tests/mates_tool.gd`).
3. Grab: in `controller._try_grab`, when `relaxed_fixed` and the target is fixed (`mates_tool.is_fixed(target)`), skip the
   `is_locked` refusal and build a `GroupSet`-like carrier from the cluster's nodes (reuse `GroupSet`; it already
   moves members rigidly about an anchor and has `follow()`, `restore()`, `finals()`). Hold the anchor as a group
   (`_held_group`), so `_update_held_part` does not call `constrain_drag`. Release: do **not** call `_finish_group_move` save paths
   (`persist_group_pose`); the move is a sandbox move (`sandbox` flag, as `_finish_group_move` already computes with
   `mates_tool.is_sandboxed(gs.anchor)`).
4. A fixed part that is **inside a sub-assembly** (nested): the same, with the sub-assembly's mates from
   `_nested_states`. If the cluster crosses a boundary, take the whole sub-assembly (use the group machinery's levels).
5. V-1's refusals consult `relaxed_fixed`: a fixed ancestor no longer refuses.
6. UI: wheel (V-5's sub-wheel): "Relax fix mates" toggle, label "Return parts" while on (like `_relax_entry`); tablet: a second
   toggle under "Relax mates" in `tablet_pages.gd` ~742 with the same sandbox rules (Scenes page asks before losing unsaved
   changes: reuse its guard). The two relax modes are exclusive: turning on "Relax mates" while fix-relax is on promotes to full
   relax without forgetting `_home`. The prompt text in `wheel_flows.gd` ~115 says which mode is on.
7. Messages: `_report("Fix mates relaxed: grab a fixed part and its mated parts come with it. Return parts puts everything back.")`.

**Tests.** Pure cluster test; a headless sandbox test in `tests/mates_sandbox.gd` style: fixed part + two mated parts, relax-fix,
move the anchor through the controller's group path, assert the cluster moved rigidly (relative poses unchanged), the stored
state was not written (no PATCH on the fake backend), `Return parts` restores every pose, and an unmated part is not moved.

---

## Verification limits (say these in the PRs)

- V-2's cause is unknown; if the new test passes, report "not reproduced".
- Headless runs cannot judge the haptic buzz, the feel of V-6's carry, or the wheel's real layout; the owner re-tests on the headset.
- V-3 and V-4 depend on timing against a real backend: the fakes in `tests/` reproduce the order, not the latency.
- Do not write "works on the headset" in `docs/status.md` (see `CLAUDE.md`).
- Update `docs/status.md`, add the new test files to `tests/run_all.sh` and `tests/README.md`, and index this plan in `docs/README.md`.
