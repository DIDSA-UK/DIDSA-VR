# VR testing feedback 2026-11-11: plan

Source: the owner's testing notes of 2026-11-11 (Godot VR client). This doc is for the implementation session.
Code pointers were read on branch `ccr-dec7d67f-ipq5rn` (= `main` plus this doc). Line numbers drift: search for the symbol.
**Nothing here was run** (no Godot, no headset, no backend in the planning session). Each item says how sure the cause is.
**Reviewed 11 Nov** (second pass, against the code and the backend): V-3 and V-4 were overstated in the first draft and are now
"medium, instrument first"; V-2's rotation candidate was wrong and is replaced; the wheel layout in V-5 could not work with seven
wedges and is fixed; the tree item (V-7) is now a review of its own, `docs/feature-tree-review-2026-11-11.md`.
Headless tests cannot judge feel or fake a real grip (see `CLAUDE.md`); each item says what a test can and cannot cover.

The file-format and desktop-mode items from the same notes are in `DIDSA-UK/DIDSA-CAD`,
`docs/iges-jt-and-desktop-input-plan-2026-11-11.md`. Its F-3 adds one line to this repo (`main.gd`, `project_folder.gd`).

| Item | Summary | Kind | Cause certainty |
|---|---|---|---|
| V-1 | Grabbing a fixed parent assembly does nothing, with no "part is fixed" message on the hand | Bug (feedback) | High: the message path is known; which refusal fired is not |
| V-2 | Relaxed mates: cycling to the parent keeps small movements of the child | Bug | **Low: not found by reading; repro first** |
| V-3 | Appearance tool: a paint shows nothing until the next paint | Bug | **Medium: one real race, but narrower than first thought; instrument first** |
| V-4 | Mate preview ghost sometimes missing though Create moves the parts | Bug | **Medium: several silent no-ghost paths; instrument first** |
| V-5 | Fix / Float: controlled from the Assembly Tree, not the wheel; the wheel gets only "Relax fix" | Decision | n/a |
| V-6 | "Relax fix mates": grab a grounded assembly and carry it, mates intact; temporary | Feature | n/a (owner's rules below) |
| V-7 | Assembly Tree, phase T1 of `feature-tree-review-2026-11-11.md`: state icons, selection both ways, a bottom action bar (Fix / Float, view-only Hide, Isolate, Rename, Room, Delete), stays current | Feature + bugs (confirmed) | High (read) |

Suggested order: **V-1 → V-7 → V-5 → V-6**, with **V-3, V-4 and V-2** started by their instrumentation / reproduction steps in
parallel (each is a small first PR: logs plus a test), then fixed once the cause is known.
V-7 brings Fix / Float (V-5); V-6 adds the Relax fix wedge to `scripts/ui/wheel_flows.gd` `_mates_entries`.

Vocabulary the notes use: **"fix mate"** = an occurrence's `fixed` (grounded) flag; the backend has no "fix" mate type
(`MateType` is coincident, concentric, parallel, distance, angle, gear, rack_pinion, screw, limit_*).
**"Hand disc"** = the badge disc above the right hand (`ui/tool_badge.gd`) and the wrist hint panel next to it (`ui/wrist_hint.gd`,
fed by `ui/wheel_flows.gd` `say()` / `prompt_text()`).

---

## V-3: paint shows nothing until the next paint (medium confidence: instrument first)

**What the code does.** `scripts/appearance_tool.gd`: `ensure_loaded(root)` reads each Part once (`_load_part`: five awaited
requests, then `_model["parts"][pid] = entry` and `_loaded[pid] = true` at the very end). `forget()` clears it on every document load and
after a design-table edit (`main.gd` ~1273, ~1976, ~2372), so the **first paint after a load or an edit** always starts with a load.
`controller.gd` `_arm_paint` starts `ensure_loaded` without awaiting it (trigger down); a click's `_finish_paint` awaits it again;
a **hold** (the breadcrumb) goes to `_paint_row` **without** awaiting it. `apply()` → `_store()` PUTs, writes the response's override
list into the model and repaints.

**One real race (confirmed by reading), narrower than the first draft said.** Two loads of the same Part can run at once (the second
call doesn't see `_loaded` until the first finishes). A load clobbers a paint only if it **finishes after the PUT's response**
(`_model["parts"][pid] = entry` with the list read before the PUT). With a click the awaited load normally finishes before the PUT, so
this needs a slow load: a big assembly (five requests per Part, Parts read one after another) painted through the **breadcrumb**,
which does not wait. Then the paint disappears from the model until the next paint's PUT returns the full list again: "appears
later". It fits the report if the owner used the breadcrumb or painted soon after opening a file; it does not explain a plain click
on a small, already-read model.

**Other candidates to rule in or out** (the report can't distinguish them):
1. The part was inside an **open Room or with the section tool on**: their clip shader wears the part (`clip_look.gd`, `room_clip.gd`,
   `section_tool.gd`). `restyle()` replaces `material_override`; whether the clip re-wraps with the new look straight away depends on
   when those scripts re-check. Check by painting with a room open and the section tool on.
2. **Temporary paint** (mates relaxed or a scene showing: `is_temporary()`): goes to `_temporary`, not the backend. Check the
   wrist message said "temporary".
3. `restyle()`'s split-mesh path (`appearance_look.gd`): the `SIGNATURE` meta says "already split this way" by the triangle count
   per look, so a repaint that changes a look but not the grouping returns early **without** applying the new materials (the
   signature has the look's key in it, so check: `Rule.key_of(a)` must include the colour; if it does, this is not it).

**First PR (small): instrumentation + the race fix.**
- Log one line per paint (`print("DIDSA VR: paint: ...")`): row, root, temporary or not, PUT ok, override count in the response,
  `restyle()` result, the part's `material_override` colour after, whether a room / section clip was on, and whether a load was
  still running. The owner reproduces once; the log names the cause.
- Fix the race anyway (cheap, and it is a real bug): an in-flight map so a second `ensure_loaded` **awaits** the running load instead
  of starting another; a `_version` counter bumped by `_store` so a load that started before a PUT **keeps the newer override list**
  (merge its own fields: names, occurrences, patterns); `_paint_row` awaits `ensure_loaded` on the breadcrumb path too; `is_busy()`
  includes a running load.
- (Checked and ruled out: the backend's `legacy` rows. `appearance_overrides_response` only lists an `Occurrence.color` as legacy
  when no explicit override has the same key, so a fresh paint is never hidden by that path.)

**Test.** `tests/appearance_tool.gd` with `tests/fake_appearance_api.gd`: delay the GETs of the first load, start it, `apply()`
through the breadcrumb path, let the load finish; the override must still be in the model and the node painted. Plus "two quick
paints". The clip candidate needs a render test (`tests/appearance_clip_render.gd` exists: extend it with paint-while-clipped).

---

## V-4: mate preview ghost sometimes missing though Create works (medium confidence: instrument first)

**What differs between preview and Create** (`scripts/mates_tool.gd`, backend `router.py` `preview_mate_solve_endpoint` ~5184):
- Create (atomic) **PATCHes the driven part's current pose** first, then POSTs the mate with the solve **and the branch changes**
  (`build_create_payload(atomic)`). The preview sends neither.
- Moves are normally saved as they happen (`persist_pose`, latest-wins, on every release, rotate and nudge), so the stored pose is
  usually fresh. It is **stale** while that write is still in flight (a pick straight after a move), and for anything not persisted.
  So the pose difference explains *some* missing ghosts, not all: the first draft overstated it.
- The backend turns **any validation error into `converged: false`** (`except HTTPException: return converged=False`), and so does
  a fixed driven part; the client then shows **no ghost and no reason** (`preview_members()` returns `[]`; `status_text()` says
  "Ready - choose a mate type and Create").
- `_find_loaded_part()` can return the wrong copy or none (a sub-assembly's room open: the world's hidden copy and the room's carry the
  same owner and occurrence ids); the ghost is then added to a hidden copy or not at all.

**Fix.**
1. **Say why** when there is no ghost (the main fix): set a `_preview_note` from the HTTP error, `converged: false` (with
   `blocked_by` / `conflicting` if present: `branch_notice` already words those), a member not found on screen, or a superseded request;
   `status_text()` shows it instead of "Ready". Log the same line (`print("DIDSA VR: preview: ...")`) so `adb logcat` shows the cause
   next time. Backend (optional, small, in DIDSA-CAD): return the validation error's `type` in the preview response
   (`reason`) instead of a bare `converged: false`.
2. **Sync the pose before previewing**, as Create does: factor the PATCH out of `create_mate()` into `_sync_driven_pose()` and call it
   from both, only when the pose differs from the last one sent and under the same conditions as `atomic`. Cheap insurance against
   the in-flight case.
3. Pass the picked node (`near`) to `_find_loaded_part` for members, so the ghost goes on the copy you are looking at.

**Test.** Fake backend in `tests/mates_tool.gd`: (a) converges only after the PATCH: the ghost appears; (b) `converged: false`
sets the note; (c) a room open with the same owner / occurrence ids: the ghost is added to the room's node. e2e "move, then pick
straight away" in `tests/e2e_mates.gd` (live backend).

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
one; check which depth it was. **Also possible:** the refusal that fired was `"mated"` ("has mates on it: a mated sub-assembly can't be
moved as a unit yet"), not `"grounded"`; both only reach the status line today, so the owner may have seen neither. The log line
`DIDSA VR: <text>` (`_set_status` prints it) says which.

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
1. **The latch is not what is running.** With `group_deadzone` Off (Settings > Rooms, `app_settings.gd`), or for a part
   `GroupIndex.has_groups` says has no groups, the grip takes the *part* at once (`_begin_part_hold`) and it follows the hand
   immediately. Check the setting and `has_groups` on the owner's assembly. If this is it, the bug is that a grip can move the child
   before the user can choose: latch regardless of the setting for a part inside a sub-assembly, or make "Off" mean "take the
   innermost, no cycling" and say so.
2. **The thumbstick moves the selected child during the latch.** `controller.gd` `_physics_process` turns / pushes `selected_node`
   with the stick and A / B whenever something is selected (~line 221-245); nothing there checks `_latch`. If the child was also
   laser-selected, a touch of the stick (or A / B) while cycling moves it, and the group taken at commit keeps that offset. Fix: no
   stick / A / B manipulation while `_latch` is active.
3. **Something else moved members before the commit**: a *selected group's* `follow()`, scene / sandbox ghost updates while relaxed,
   or `two_hand_model.gd` (the other hand's gesture; it skips only `held` nodes, and latched nodes are not `held` yet).
(The first draft's "hand rotation at commit" candidate was wrong: `_begin_hold` takes the grab offset from the hand **at commit**, so a
rotation during the latch causes no jump.)

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

What goes on the mates ring: **Relax fix** (V-6), beside Relax / Return parts, so it sits where Relax mates sits (mates ring, tablet
toggle under "Relax mates", the pill turns into Return while on).

**Layout correction (review):** wedge `i` is centred at `i * 360 / count` degrees from the top (`tool_wheel_math.centre_angle`), so
**only an even count has a wedge straight down**; seven wedges would put two wedges astride the pill. So the ring needs **eight**:
add **Tree** (opens the Assembly Tree window, where Fix / Float now lives: the owner's direction, and one gesture from mating to fixing).
Clockwise from the top: Create (0°) · Type (45°) · Flip (90°) · Relax fix (135°) · **Clear picks (180°, straight down)** · Relax /
Return parts (225°) · Tree (270°) · All tools (315°). The root ring already has ten wedges, so eight draws. Check the names fit their
tiles (3 and 9 o'clock are the narrow ones: Flip and Tree are short). Update the comment above `_mates_entries` ("six wedges") and
the wheel tests that count wedges.

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
- **Temporary, like Relax:** nothing is saved (no `persist_pose`, no PATCH). Turning it on records every part's pose in `_home`
  exactly as `_enter_sandbox({})` does (simplest, and it is what Return already expects), and "Return" restores them in one undo step
  (`return_parts()`). Undo / redo of "return parts" works the same.
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
   cluster member `is_sandboxed`: true for every remembered part while fix-relax is on). The cluster's nodes come from
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

## V-7: the Assembly Tree (phase T1 of the tree review)

The tree now has its own review and plan: **`docs/feature-tree-review-2026-11-11.md`**. V-7 is its **phase T1**: the world tree's
bugs B1-B4 (a repeated sub-assembly selects the wrong part; the root row selects an arbitrary body; a nested Delete edits a shared
Part without saying so; refresh collapses the tree), state icons on the rows, selection both ways with a pulse in the world, and the
**bottom action bar** with Fix / Float (V-5), **view-only** Hide / Show (owner, 11 Nov: never saved, never the backend flag), Isolate,
Rename, Room and Delete; live refresh. Phases T2 (one component for world, rooms and table; a tree per room) and T3 (Mates and
Patterns sections, leader line, search) follow it. Tests are listed there.

---

## Verification limits (say these in the PRs)

- V-2's cause is unknown; if the new test passes, report "not reproduced".
- Headless runs cannot judge the haptic buzz, the feel of V-6's carry, or the wheel's real layout; the owner re-tests on the headset.
- V-3 and V-4: the first PR for each is instrumentation; the fix PR names the cause the log showed, or says it was not reproduced.
- V-3 and V-4 depend on timing against a real backend: the fakes in `tests/` reproduce the order, not the latency.
- Do not write "works on the headset" in `docs/status.md` (see `CLAUDE.md`).
- Update `docs/status.md`, add the new test files to `tests/run_all.sh` and `tests/README.md`, and index this plan and the tree review in `docs/README.md`.
