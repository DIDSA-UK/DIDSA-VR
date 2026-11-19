# Plan: dimensions and constraints at parity with the flat app (sessions)

**Status: final (2026-11-18), revised for running (2026-11-19). Gate met 2026-11-19; S0 and S8 done 2026-11-19 (S8 in its own session)** (section 1). Defaults F1-F7 (section 2) can still be changed before the session that uses them.

The build plan for [`dimension-constraint-parity-scope.md`](dimension-constraint-parity-scope.md) (the gap tables, the workflow and the owner's
decisions of 2026-11-18). Written for **coding sessions**: each session below is one repo, one branch, one PR. Line numbers drift: search for
the named symbol. Status of every session: the tracker (section 7).

## 1. Gate: when this starts

Not before all of these hold. **Checked 2026-11-19: items 1 and 2 hold** (DIDSA-CAD #385 merged to `main` with A, B, C1-C3 and D done;
C's item 10 was done by reading only, not run against VR: the owner decides whether that is enough, else S2's e2e covers it; DIDSA-VR `main` has no open work in the named files after
P2 / P4 and this plan were merged). Item 3 is each session's own setup. The first session does not re-check items 1-2.

1. DIDSA-CAD `docs/bug-report-2026-11-18-plan.md` is complete: its Progress table shows parts A, B, C (C1, C2, C3) and D done, and the
   branch holding them (`ccr-5fd5d437-1l26qn` and C's) is **merged to DIDSA-CAD `main`**. Part C's own VR check (its item 10: VR handles the new
   `convert-entities/edge` shapes) is done, because it touches the same session code.
2. DIDSA-VR `main` has nothing open in `scripts/design_table/sketch_session.gd`, `sketch_selection.gd`, `dimension_layout.gd`, `sketch_view.gd`
   or `table_editor.gd`'s sketch half (check open PRs).
3. VR e2e sessions run their backend from DIDSA-CAD `main` (`tools/start_backend.sh` with `CAD_DIR` on a `main` checkout).

## 2. Defaults that unblock sessions (change them before the session that uses them)

| ID | Default | Used by |
|---|---|---|
| F1 | Catalogue option keys are the flat app's ghost keys (`length`, `h`, `v`, `horizontalAngle`, `diameter`, `radius`, `arcLength`, `majorradius`, ..., `linear`, `perpendicular`, `lineDistance`, `angle`, `pointAngle`, `minDistance`, `maxDistance`, `tangentDistance`, `farDistance`); VR renames its keys to them | S0, S4 |
| F2 | An unplaced dimension keeps VR's automatic layout (`dimension_layout.gd`, the side with room); a placed one (a saved `label`) is drawn at its placement in both apps | S2 |
| F3 | The kind cycle is the **right stick left / right**, only while a preview is live, the laser is on the sheet and the table is not engaged; otherwise the stick does what it does now | S5 |
| F4 | **B** is "one step back" in the dimension flow (pad to preview, preview to picking); it already closes the selection drawer, which stays first | S5 |
| F5 | A label is moved by holding the trigger on it and dragging (as the table's resize handles); a quick pull keeps its present meaning (select; a second quick pull opens the pad) | S6 |
| F6 | A sketch point is dragged by holding the trigger on it with Select (points first; lines and whole shapes after) | S10 |
| F7 | "Every candidate at once" (VR's present style) is a toggle on the options row, off by default (decision 3) | S5 |

## 3. Contract of record

### 3.1 The catalogue (`DIDSA-CAD/docs/sketch-dimension-catalogue.json`)

Data, not code: both clients read it in **tests only** (no runtime dependency, nothing copied between licences).

```json
{
  "version": 1,
  "entries": [
    {
      "picks": ["line"],                 // the selection, in pick order
      "ordered": false,                  // true: pick order matters (three points: the vertex first)
      "when": null,                      // a condition from the fixed list below, or null
      "options": [                       // in drawer order; the first is the default unless "default" says otherwise
        {"key": "length", "label": "Length", "creates": "distance:linear"},
        {"key": "h", "label": "Horizontal length", "creates": "distance:horizontal"},
        {"key": "v", "label": "Vertical length", "creates": "distance:vertical"},
        {"key": "horizontalAngle", "label": "Angle to horizontal", "creates": "horizontal_angle", "side": "pointer"}
      ],
      "default": "length",
      "cursor_rule": null                // "point_pair_box" for two points (H above / below the pair's box, V left / right, else aligned)
    }
  ],
  "pinned": {                            // every Point of the picks pinned: reference (driven) dimensions instead
    "offer": "reference",
    "kinds": {"line": ["distance", "horizontal", "vertical", "horizontal_angle"], "arc": ["radius", "diameter", "arc_length"]}
  }
}
```

(The comments explain the fields; the file itself is plain JSON.)

- `picks` vocabulary: `point`, `line`, `circle`, `arc`, `ellipse`, `ellipse_arc`. Unordered entries match in any order.
- `when` vocabulary (fixed; a new one is a contract change): `lines_parallel`, `lines_not_parallel`, `point_not_on_line_end`,
  `point_not_of_curve`, `curves_apart` (the gap exists), `line_misses_curve`.
- `creates`: the backend constraint `type` (with `:orientation` for a distance, `:min` / `:max` for the side) or `radius` / `diameter` for the
  circle's own size constraint.
- `side: "pointer"`: which angle it is follows the pointer (quadrant) and is frozen at the drop.
- `label`: the text both apps show.

Table rows to encode: the flat app as built at the gate (DIDSA-CAD `bug-report-2026-11-18-plan.md`, "Notes from the implementation of A"
and "of D"), including an option that only shows under a condition (Minimum only while two circles are apart, Tangent only while the line
misses the circle).

### 3.2 Label placement

The saved `label` of a constraint (`PUT .../constraints/{id}/label`; fields per kind in DIDSA-CAD `client/lib/api/dimension_label_placement.dart`'s
table, the new types in `client/lib/sketch/dimension_types.dart`'s header) is the one placement both apps read and write. VR implements
the meanings from those descriptions and the plan text, **not by translating the Dart** (DIDSA-CAD `LICENSING.md`, rule 1, applies in spirit:
VR code is written from the spec). Golden placements (pointer -> placement -> label centre) go in the catalogue file's sibling
`docs/sketch-label-placement-cases.json` (S0) so both apps test against the same numbers.

### 3.3 Conflict rule (decision 1)

A constraint or dimension the backend's solve does not converge with **right after it is made** is deleted again and the reason shown
(VR does this today; the flat app learns it in S1). A conflict that appears **later** (an edited value, a moved reference) is kept; the
solve's `solver_reported_failed_constraint_ids` turn what they hold red, in both apps (VR learns this in S3).

## 4. Session rules

- **One repo, one branch, one PR**, about 1 500 changed lines with tests at most. If the list overflows, stop at the last green checkpoint and
  split; record the split in the tracker.
- **Start:** read sections 1-4 here, the session's brief, the previous session's handoff (tracker Notes), and only the scope sections and files
  the brief names. Do not re-derive the scope's findings or re-read a finished session's diff.
- **Reading budget.** These files are large; never read one whole. `grep -n` the named symbol and read that function (and its callers if needed):
  DIDSA-CAD `sketch_controller.dart` (~19 900 lines), `sketch_projector.dart` (~1 300); DIDSA-VR `table_editor.gd` (~3 100),
  `sketch_session.gd` (~2 800), `sketch_view.gd` (~1 000). The test files they belong to are read the same way: find the nearest existing case
  and copy its pattern.
- **Run tests narrowly while working** (the one test file, `tests/run_all.sh` filtered as `tests/README.md` shows), and the full `ci.sh` once
  at the end, in the background to a file; read the summary lines, not the whole log.
- **Env:** VR: `TOOLS_DIR=/opt/tools CAD_DIR=<CAD checkout on main> tools/setup_test_env.sh <pieces>`, then `source /opt/tools/env.sh`.
  Install only the pieces the session needs (section 9): `godot` always; `render` only where the brief has a render test; `backend` only with
  e2e; never `flutter` in a VR session. CAD client: Flutter as in that repo's notes. The first Flutter compile is slow: run long suites in the
  background to a file.
- **VR test rules** (DIDSA-VR `CLAUDE.md`, `tests/README.md`): a new test file goes in `tests/run_all.sh` and a row in `tests/README.md`;
  live-backend tests also in `tests/e2e_ci_list.txt`; `DIDSA_NO_LANDING=1`; a test that instantiates `main.tscn` sets `secrets_file_path` first.
- **Finish:** the brief's exit criteria pass; `tests/ci.sh` (VR) or the full `flutter test` + `flutter analyze` on `lib` (CAD client);
  the tracker row, whose Notes are the **handoff for the next session** (at most 15 lines: what changed, the symbols added or renamed, anything left
  for later, the headset checklist); a dated `docs/status.md` entry (built, verified, not verified); a **headset checklist** in the handoff for anything a
  person must feel or see. Never write "works on the headset" unless the owner says so.

## 5. Order (revised 2026-11-19)

```
S0 (done) -> S8 (CAD) -> S9 (VR, new files only; parallel with the VR lane)
          -> S1 (CAD, flat)
          -> S2 -> S3+S4 -> S5 -> S6 -> S10 (+ S7 if it fits) -> S7 if left     (VR lane: they share table_editor.gd / sketch_session.gd)
```

**Sessions that share one session (2026-11-19).** A merge is worth it only when both phases are in the same repo, read the same files, use the
same model (section 9) and fit section 4's size together; otherwise the second phase pays for carrying the first one's context on every turn.
- **S3+S4: one session.** Both mostly change `sketch_session.gd` and `sketch_selection.gd`, both M, both Sonnet medium; S4 does not need S3, so
  they are two checkpoints on the same files. Do S3 first, commit and push it green, then S4. If S3 alone passes ~800 changed lines, stop
  after it and run S4 as its own session (record the split in the tracker).
- **S7 after S10 in the same session, if it fits.** Same input code in `table_editor.gd`, both Sonnet. Start S7 only if S10 ends under ~900
  changed lines; otherwise S7 runs alone.
- **Not merged, and why:** S0 / S8 and S1 (S1 would run at Opus rates; S0 alone was 1 356 lines); S1 and S2 (different repos and toolchains,
  no shared files); S2 and S4 (over the size together); S5 and S6 (S5 is the Opus design session; S6's routine work should not pay Opus rates).
- **Sizes run high.** S0, sized S, came to 1 356 changed lines (much of it JSON). Treat a brief's size as a lower bound and keep the
  stop-and-split rule of section 4.

- **S0 and S8 were planned as one CAD session** (S0 overflowed; S8 now runs alone): both are "write the contract from the Dart and a test that reads it", in the same repo, with the same
  Flutter setup; one start-up and one first Flutter compile instead of two. If it overflows section 4's size, it stops after S0 and S8 runs alone.
- **S1** runs any time after S0 (CAD repo, no overlap with VR).
- **S9** only adds `scripts/motion/sketch_projector.gd` and its test, so it runs in parallel with the VR lane without conflicts.
- **S10 moved before S7, and after S6**: S6's label drag (F5) and S10's point drag (F6) are both a trigger-hold in `table_editor.gd`'s Select
  branch, so they are built one after the other on the same code (S10 reuses S6's hold; when a label and a point are both under the laser, the
  nearer hit wins, a tie goes to the point). **S7 is last** so its intent layer covers every input, drag included.
- Only one VR lane session at a time. **Branches:** the sessions so far share `ccr-be4859df-3jil9a` in both repos; a session starts from that
  branch's tip (pull first) unless it has been merged to `main`. Two sessions in the **same repo** never run at the same time on one branch
  (S1 and S8 are both CAD: run them one after the other, or give the second its own branch).

## 6. Sessions

### S0 - Catalogue and placement cases (CAD: docs + client tests, S)

Read: section 3; DIDSA-CAD `client/lib/sketch/sketch_controller.dart` (`_rebuildDimensionGhosts`, `_curveDistanceGhosts`, `_lineCurveDistanceGhosts`,
`_buildLineLengthGhost`, `_buildPointLineGhosts`, `referenceDimensionKinds`), `client/lib/sketch/dimension_types.dart`, `label_drag_resolver.dart`.
Tasks: write `docs/sketch-dimension-catalogue.json` to 3.1 from the code as built; write `docs/sketch-label-placement-cases.json` (for each
placement kind: geometry, three pointers, the placement, the label centre); a flat test `client/test/sketch_dimension_catalogue_test.dart` that
builds each entry's selection in a controller and checks options, order, labels, default, cursor rule and the `when` conditions; a placement test
reading the cases. Exit: both tests pass; any mismatch found is fixed in the **file** if the code is right, else listed for S1.

### S1 - Flat app: the conflict rule and reference dimensions (CAD client, M)

Needs S0. Read: 3.3, scope decisions 1 and 4; `sketch_controller.dart` (`confirmGhostValue`, every `create*Constraint` call site, `_solveAndTrackDof`,
`referenceDimensionKinds`, `addReferenceDimension`, `_everyPointPinned`), `sketch_dimension_bar.dart`.
Tasks: after making a constraint, a non-converged solve deletes it again and puts the reason in `errorMessage` (one helper, used by every
creation path; the undo entry is not pushed); between pinned things the dimension tool offers reference dimensions from the catalogue's
`pinned` block (Dimension tool, not only the bar), including the part D kinds; the bar lists the D kinds. Exit: controller tests for take-back
per creation path (dimension, relation, inferred), later-conflict stays red, the pinned offer; the S0 catalogue test still passes.

### S2 - VR: see and touch every dimension (VR, M-L)

Needs S0. Read: scope "Dimensions"; 3.2; `sketch_session.gd` (`dimension_items`, `driven_items`, `_ref_dim_key`, `_ref_dim_spec`,
`dimension_value`, `edit_dimension`, `angle_spec`), `dimension_layout.gd`, `sketch_view.gd` (`_rebuild_dimensions`, `_layout_for`, `annotation_near`).
Tasks:
- `dimension_items` draws the six part D types (arc length: a concentric arc with `⌒`; the two angles: the angle layout with the saved
  `quadrant`; the four distances: a linear dimension between the measured ends, as `dimension_types.dart`'s header describes).
- A saved `label` placement is honoured for every type (F2: unplaced keeps the automatic layout). The two-line angle draws in its saved quadrant.
- `dimension_value` / `edit_dimension` cover every value type (field per type: `distance`, `angle_degrees`, `length`); an angle edit keeps its quadrant.
- Delete works for all of them (the cascade already catches them; check).
- Reference dimensions of the new kinds draw correctly (`_ref_dim_key` learns them).

Tests: `tests/design_table_logic.gd` layout cases per new spec kind and against `sketch-label-placement-cases.json`; a new
`tests/e2e_sketch_dimension_types.gd` (live backend: make each D type through the routes, read it back in VR, edit its value, delete it, and a
placement written by the route drawn where it says); `tests/sketch_style_render.gd` renders one of each. Exit: those pass; `ci.sh` green.

### S3 - VR: constraint state and relations (VR, M)

Needs S2. Read: scope "Constraints"; 3.3; `sketch_session.gd` (`_ingest_state`, `dof`, `converged`, `constraint_items`, `_glyph_spot`, `CONSTRAINT_GLYPHS`),
`sketch_selection.gd`, `sketch_view.gd` (`_draw_constraint_glyphs`, `rebuild`'s colours), `UiFeedback`.
Tasks:
- Geometry coloured fully / under / over constrained, as the flat app does: the backend's `dof` and `converged`; the points of
  `solver_reported_failed_constraint_ids` red.
- DOF on the status line; a haptic tick when the sketch reaches fully constrained (the mates tool's pattern).
- **Unfix** in the Select menu.
- Fix the glyph owners. Reading the code, the Fix glyph looks for `entity_id` and Equal radius for entity ids, but the backend sends `point_ids`
  and centre / rim Point ids, so neither glyph seems to be drawn; confirm, then fix.
- Every glyph type lights what it holds when hovered or picked.

Tests: logic tests for the colour states and the glyph owners; e2e: fully constrained after the last dimension, a later conflict (an edited
value) shown red and not taken back. Exit: those pass; headset checklist: colours readable on the slab and a white part.

### S4 - VR: option parity (VR, M)

Needs S0, S2. Read: the catalogue; `sketch_session.gd` (`_ghosts_raw`, `_ghosts_for`, `_ghost`, `confirm_ghost`, `_select_for_dimension`, `keep_driven`),
`sketch_selection.gd` (`options`).
Tasks: `_ghosts_raw` produces exactly the catalogue's options (keys F1, labels, order, defaults, `when` conditions, the cursor rule's
default for two points), creating through the same routes; the third Point pick (the first is the vertex; any other third pick restarts);
the pinned block offers reference kinds. A VR catalogue test (`tests/sketch_dimension_catalogue.gd`) builds each entry's selection in a
session model and compares. Exit: the catalogue test passes with no expected-fail left; e2e creates one of each D option from a VR pick.

### S5 - VR: preview, choose, drop (VR, M-L)

Needs S4. Read: scope "The VR workflow"; 2 (F3, F4, F7); DIDSA-CAD bug-report plan part A (flow and notes); `table_editor.gd` (`_on_right_pressed`,
the dimension / Select branch, `_type_dimension`, `dimension_typed`, `_update_options`), `table_manip.gd` (`_update_engaged`, `drive_input`),
`sketch_view.gd` (`show_ghosts`, `ghost_near`).
Tasks:
- One preview at the laser's hit on the sheet, laid out by the placement rules (3.2).
- The kinds on the options row with the current one lit, and the stick cycle (F3); the two-point cursor rule until a kind is chosen.
- Angle sector from the laser, sticky near the lines (the flat app's rule, plan part A fix 2a).
- Trigger on empty sheet drops: freezes kind, placement and side, and opens the number pad at the label.
- Confirm creates the dimension and saves the placement (`PUT .../label`).
- B steps back (F4); the "every candidate" toggle (F7).

Tests: logic tests for the stick ownership (engaged vs not), the cursor rule, the sticky sector, step-back; e2e: pick -> preview -> drop -> type
-> the constraint and its saved placement on the backend. Exit: those pass; headset checklist: preview feel, stick cycling, reaching the pad.

### S6 - VR: edit what is there (VR, M)

Needs S5. Tasks:
- Label drag for existing dimensions (F5), saved.
- The radius / diameter switch on an existing circle dimension (the flat app's toggle).
- Editing an angle's side.
- A dimension placed in VR shows at the same place in the flat app.

Tests: logic + e2e round trip (VR moves a label; the route returns that placement). Exit: those pass; headset checklist: grabbing a small label
with a shaking laser.

### S7 - VR: hand-ready input (VR, S-M)

Needs S6 and S10 (runs last). Tasks: one intent layer in `table_editor.gd` for the sketcher (select, cancel / back, next / previous, adjust, drag) that the
controller code calls into; every stick action mirrored by a button on the options row or deck; label / glyph / ghost hit sizes per input source
(`GHOST_RADIUS`, `GLYPH_HIT_MM` become per-input constants). No hand tracking (DIDSA-CAD roadmap, DIDSA-VR item 10). Tests: the intent
layer driven without a controller (as a hand source would) reaches the same results as S5's tests. Exit: those pass.

### S8 - Sketch projector: port spec and golden vectors (CAD: docs + tools, S-M)

Runs in the same session as S0, after it (section 5). Read: DIDSA-CAD `docs/sketch-drag-projector.md`, `client/lib/sketch/projector/sketch_projector.dart`,
`client/test/sketch_projector_test.dart`, and how the mates projector was handed over (`docs/motion/projector-spec.md`, `vectors.json`).
Tasks: `docs/motion/sketch-projector-spec.md` (the method, every constraint type's residual including part D's, the branch rules taken
from the reference frame, the continuation walk and its constants, the group restriction, what `unsupported` means); a small Dart tool that
exports `docs/motion/sketch-vectors.json` (input points, constraints, anchors, pinned, wish, expected output and residual) from the golden cases
plus a drag-path case per type. Exit: the export is reproducible (`--check` mode as the mates vectors have); the Dart projector passes its own vectors.

### S9 - VR: the sketch projector (VR, L)

Needs S8. Tasks: `scripts/motion/sketch_projector.gd`, written from the spec (forward-mode derivatives, the residual per type, the min-norm
correction, the walk, the group restriction), no scene tree. Test: `tests/sketch_projector_vectors.gd` against `sketch-vectors.json` (every
vector within its tolerance) and a timing line (frame budget on the slowest vector). Exit: all vectors pass; timing recorded. If it overflows,
split: core + distance / angle / line types first, curves and part D second.

### S10 - VR: dragging sketch points (VR, M-L)

Needs S9 and S6 (S3 through it). Reuses S6's trigger-hold (section 5 for which hit wins). Tasks: Select's trigger-hold on a point drags it (F6) through the projector each frame, the rest of its group following;
the drop sends the result as a wish (`solve-and-refresh` with `point_updates` and anchors, as the flat app does) and takes the backend's answer;
points pinned by a reference, the origin or a Fix do not move; DOF colours (S3) update on the drop. Tests: logic (a drag on a dimensioned
shape keeps its dimensions within tolerance every frame); e2e (drag, drop, the backend's positions). Exit: those pass; headset checklist: the
feel of a constrained point sliding along its path.

## 7. Tracker

| Session | Repo | State | Branch / PR | Notes |
|---|---|---|---|---|
| S0 | CAD | **Done** (2026-11-19) | DIDSA-CAD `ccr-be4859df-3jil9a` (no PR yet) | Added `docs/sketch-dimension-catalogue.json` (17 entries, `pinned`), `docs/sketch-label-placement-cases.json` (15 placement kinds, 22 cases x 3 pointers), `client/test/sketch_dimension_catalogue_test.dart` (builds each entry in a real `SketchController`), `client/test/sketch_label_placement_cases_test.dart`.<br>Beyond 3.1's shape: an option may carry its own `when` (Minimum: `curves_apart`; Tangent: `line_misses_curve`; point + curve min / max: `point_not_of_curve`); top-level `notes` (selections that offer nothing; two Points on two parallel lines read as the lines; pick rules), `conditions` and `cursor_rules` (prose); `pinned.kinds` keys are the picks joined by `+`.<br>Options: code and catalogue agreed everywhere, no fix needed. **Left for S1:** `referenceDimensionKinds` lacks the part D kinds the `pinned` block lists (`horizontal_angle`, `arc_length`, `point_angle`, `min_distance` / `max_distance`); the test's `_pinnedKindsAwaitingS1` lists them and S1 empties it.<br>For S2: the two-line `angle` places by `radius` + `along` (arc length), the part D angles by `radius` + `angle` (degrees); a full ellipse's axis is linear tip to tip, an elliptical arc's is radial; arc length's dimension arc never goes inside 0.1 r. For S4: VR keys become the catalogue's (F1: `majorradius`, `minDistance`, `tangentDistance`, ...).<br>No VR change, so no headset checklist. |
| S1 | CAD client | Not started | | |
| S2 | VR | **Done** (2026-11-19) | DIDSA-VR `ccr-be4859df-3jil9a` (no PR yet) | Changed: `sketch_session.gd` (`dimension_items` -> `_dimension_item` per type; `dimension_value` / `edit_dimension` cover the six part D types, field `length` / `distance` / `angle_degrees`, an edit sends only the value so the quadrant stays), `dimension_layout.gd` (spec `arc_length`; a saved placement for every kind), the part D reference kinds drawn (`_part_d_ref_spec`, `_ref_dim_key`, `_dimension_kind`). Delete needed no change (the cascade and `delete_annotations` are generic).<br>Symbols for S4 / S5: spec builders `arc_length_spec(arc)`, `horizontal_angle_spec(line, quadrant, value, place)`, `point_angle_spec(v, p1, p2, quadrant, place)`, `point_circle_spec(point, curve, side, place)`, `circle_circle_spec`, `line_circle_spec`, `line_distance_spec`; `circle_spec` / `angle_spec(l1, l2, value, quadrant, place)` / `perp_spec` take the saved placement. S4: build the candidates' `spec` with the same builders (a ghost then looks like what it becomes); `_ref_dim_request` still only knows the old keys.<br>Layout spec keys: `place {offset, along}` (+ `u` for two parallel lines) on linear / perp / horizontal / vertical; `label_r` on radius / diameter; `label_a` (absolute radians) and `r` on angle; `ra` + `label_a` on arc_length. `text_uv` is the saved label centre exactly (the golden cases pass within 1e-3, 63 placements, 15 kinds). S5 writes a placement by inverting these (the cases file lists each formula); `_place_on_arc`, `_linear_place`, `_place_of` are the readers.<br>Behaviour changes: two-line distance / angle are laid out from the lines' middles; a point-to-line distance measures to the line's extension; the two-line angle draws the sector its value (or saved quadrant) names, a candidate (no value) still the nearer.<br>Left: **ellipse axes**: the flat app draws a full ellipse's axis tip-to-tip with the doubled value (`ellipseAxisForDistanceConstraint`; VR stores `man` / `mnn`), VR draws centre-to-tip with the semi value, so a placement the flat app saved for an ellipse axis lands on the wrong line: S4 (ellipse diameters) decides both together. **Delete then Undo** restores the constraint, not its saved placement (S6). Reference dimensions carry no placement on the backend. Delete and edit were not checked for ellipse arcs.<br>Tests: new `tests/sketch_label_placement.gd` (cases fixture copy, `same` against the CAD checkout), layout cases in `tests/design_table_logic.gd`, new `tests/e2e_sketch_dimension_types.gd` (real backend, in `e2e_ci_list.txt`, all `true`), one of each in `tests/sketch_style_render.gd` (looked at; picture only). `tests/ci.sh`: 5357 SMOKE lines, 0 failures.<br>Headset checklist: the arc sign (U+2312) draws in the headset font (it does in the software render); a label saved by the flat app reads at arm's length, and the broken dimension line / leader to a label put far away looks right; the part D labels are hit by the laser (select, double pull edits) at the same size as the old ones; a two-line angle in a saved quadrant, and an arc-length dimension on a small arc (never inside a tenth of its radius), look right. |
| S3 | VR | Not started | | One session with S4 (section 5) |
| S4 | VR | Not started | | One session with S3 (section 5) |
| S5 | VR | Not started | | |
| S6 | VR | Not started | | |
| S7 | VR | Not started | | In S10's session if S10 ends under ~900 lines (section 5) |
| S8 | CAD | **Done** (2026-11-19) | DIDSA-CAD `ccr-be4859df-3jil9a` (no PR yet) | Added (DIDSA-CAD): `docs/motion/sketch-projector-spec.md` (the port spec: inputs / outputs, group and skip rules, the residual of all 25 supported types incl. part D's, branch rules, the walk as pseudocode, constants, as-built gaps); `docs/motion/sketch-vectors.json` (90 cases, 358 frames: 32 golden, 32 drag paths, 7 branch crossings, 19 scenes); `client/test/support/sketch_vectors.dart` (the generator, wire-form serialiser, replay), `client/test/sketch_vectors_test.dart` (check mode, in the full suite), `tools/sketch_vectors/export.sh [--check]`; the golden cases moved to `client/test/support/sketch_projector_cases.dart` (+11 part D cases, run by `sketch_projector_test.dart` too). No `lib` change.<br>**For S9:** read spec sections 1-11 and replay the file as section 10 says (each frame from the file's previous `expected`, not the port's). Constraints are in the backend wire form VR already parses. Tolerance per case = 1e-5 x the start's diagonal; a 1e-10 nudge of any input moves no Dart answer by 0.5 % of it, so a faithful port has margin. Compare `unsupported`, `converged`, `rows`, `variable_points` and the group's ids exactly; `exit` / `walks` / `iterations` are informational. Timing vector: `scene-chain-20-curled` (~2 ms per frame, Dart JIT in `flutter test`).<br>**Branch rules** (S8 row's question): spec section 5: six signs, all from the reference frame; the two-line `angle` ignores `quadrant`, part D angles use it and fall back to the reference only when it is null.<br>**As built, pinned by the vectors (spec 7.4, open for the owner, not port defects):** walks on curved constraints stop up to ~9e-4 mm short of the nearest point (`omega` never grows back after a rejection); a nearly straight dimensioned chain does not move at all (`scene-chain-20-nearly-straight`); the arm near full reach ends 0.2-0.5 mm off the axis. If the owner wants them fixed, the Dart projector and the vectors change first (CAD), then S9 follows.<br>Size: about 1 690 added lines (about 220 of them moved from `sketch_projector_test.dart`) plus 1 236 generated JSON lines. Branch rules for the next CAD session: S1 runs on `ccr-be4859df-3jil9a` after this (one CAD session at a time on the branch) or on its own branch. No VR change, so no headset checklist. |
| S9 | VR | Not started | | |
| S10 | VR | Not started | | |

## 8. Prompt for each session

> Repo: `<DIDSA-CAD | DIDSA-VR>` (attach the other one; this plan lives in DIDSA-VR `docs/dimension-constraint-parity-plan.md`). Implement
> **Sn** of that plan. Read sections 1-4 and the Sn brief first, then the previous session's handoff in the tracker, then the scope sections it
> names, then only the files the brief lists, within section 4's reading budget. Install only the environment pieces section 9 gives for Sn. Follow section 3 exactly. Stop when the brief's exit criteria pass; do not start the next
> session's work. Finish with the tracker row (branch / PR, handoff notes, the headset checklist) and a dated `docs/status.md` entry (built,
> verified, not verified). No unrelated refactors; run the tests the brief names against the real backend where it says so; say what you could
> only verify by reading.

## 9. Model, effort and environment per session (2026-11-19)

The model is chosen by how much the session must **decide** rather than follow. A spec, a numerical port or an input design with open
choices gets the strongest model; a brief that is a list of named changes against a finished contract gets the mid model. No session is
small and mechanical enough for the smallest model, because each one needs the whole build-test-fix loop.

| Session | Model | Effort | Env pieces | Why |
|---|---|---|---|---|
| S0, S8 | Opus | high | CAD: Flutter | (Separate sessions since S0 overflowed.) Write the two contracts every later session tests against; a wrong row or residual spreads to S1, S2, S4, S5, S9. Mostly reading and short, exact output. |
| S1 | Sonnet | medium | CAD: Flutter | Named changes in a known controller, with tests to S0's file. |
| S2 | Sonnet | high | `godot render backend` | Wide but specified (six types, placement from the cases file); the most lines in the lane. |
| S3+S4 | Sonnet | medium | `godot backend` | One session (section 5). S3: colours, a status line, Unfix, a glyph fix it confirms first. S4: make `_ghosts_raw` match the catalogue; the catalogue test decides it. |
| S5 | Opus | high | `godot backend` | The interaction design: stick ownership against table engagement, step-back, the sticky sector; the most judgement in the plan. |
| S6 | Sonnet | medium | `godot backend` | Label drag and edits on S5's machinery. |
| S10 (+ S7 if it fits) | Sonnet | high | `godot backend` | Wires S9's projector into S6's hold; the maths is already done and tested. Move to Opus if S9's handoff lists open branch-rule questions. |
| S7 | Sonnet | medium | `godot` | A refactor behind an intent layer, checked by re-running S5's tests through it. |
| S9 | Opus | high | `godot` | A numerical port from a spec (derivatives, min-norm step, the walk); vectors decide pass or fail, but getting there needs the maths. |

Opus: `claude-opus-5-5`; Sonnet: `claude-sonnet-5-5`. If a Sonnet session stops twice on the same failure, rerun that session on Opus from its
last green checkpoint rather than letting it keep trying.

**Saving start-up cost.** Every session above runs `tools/setup_test_env.sh` (Godot, Mesa, the backend's conda env). Putting it in the cloud
environment's setup script (one environment for the VR lane, one for CAD) means it runs once when a container is built, not in each session's
token budget.
