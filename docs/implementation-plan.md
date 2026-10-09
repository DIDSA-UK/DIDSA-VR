# Implementation plan: references, dimensioning and modelling depth (DIDSA-VR + DIDSA-CAD)

Supersedes the earlier short version of this file. Written 2026-10-08 as the spec for an implementing session.

## Context

On 2026-10-08 John and Claude scoped two areas of the DIDSA-VR design table and recorded decisions in `docs/scope-references-and-dimensioning.md`,
`docs/scope-modelling-depth.md` and `docs/implementation-plan.md` (VR repo) and in `docs/roadmap.md` (CAD repo), all on branch `ccr-b3b16f97-0i1850`.
This plan turns those into one ordered, executable spec for a **new session** to implement end to end. Outcome: centres / edges / vertices usable silently and
robustly inside sketches; persistent reference dimensions in both apps; re-attach for every feature; and a modelling toolset (Create Plane, Loft, Sweep, Pattern,
Boolean, Merge, Split, Trim, Offset, direct edit, Ellipse, Spline, Text) driven by a per-feature interface and a docked properties panel, with preview and redo. At the
end the session renders and sends John images of the dock panel for every tool so he can reorganise the layout next.

Repos: **BE** = DIDSA-CAD `backend/`, **FA** = DIDSA-CAD `client/` (Flutter), **VR** = DIDSA-VR (Godot 4). GitHub: `didsa-uk/didsa-vr`, `didsa-uk/didsa-cad`.

## Rules for the implementing session

1. **Do the work yourself. Do not delegate to agents or subagents** (no Agent tool, no workflows). Read, edit, run and test directly.
2. Start by reading, in the VR repo: `README.md`, `docs/status.md` (large; skim headings and the design-table sections), `docs/design-table.md`, `docs/design-table-gaps.md`,
   `docs/handover-references-overhaul.md`, `docs/scope-references-and-dimensioning.md`, `docs/scope-modelling-depth.md`, `tests/README.md`; in CAD: `docs/roadmap.md`,
   `docs/reference-identity-design.md`, `docs/live-preview-pattern.md`, `docs/flutter-widget-test-lessons.md`.
3. **Branch:** develop on `ccr-b3b16f97-0i1850` in both repos (it already holds the docs). Commit in small, described steps; push after each phase (`git push -u origin ccr-b3b16f97-0i1850`,
   retry up to 4 times on network failure). **Do not open pull requests.**
4. Add the second repo to the session with `add_repo` (the session starts with one). Clone both under one working folder; use full clones or set the fetch refspec to `+refs/heads/*:refs/remotes/origin/*` so upstream tracking works.
5. **Test in Godot at the stages marked "GODOT GATE" below**, and run the headless suite after every VR change. Report honestly what was verified headless, in a software render, against a real backend, or not at all.
   Nothing here has been seen on a headset; never claim feel.
6. Respect existing conventions: GDScript matches the surrounding style and comment density; tests print `SMOKE` lines and are registered per `tests/README.md`; backend changes are additive and covered by pytest; shared-schema and
   native-file changes are additive so older clients ignore them. Update `docs/status.md`, `docs/design-table.md`, `docs/design-table-gaps.md` and `docs/roadmap.md` as items close.
7. Do not put a model name in commits or code. Commits end with the attribution lines the session is given.
8. If a step is blocked (tool missing, test cannot run), say so in the status doc and the final report, do a fake-backend equivalent where one exists, and continue; do not skip silently.

## Step 0: environment and baseline (S)

1. **Godot 4.7.2** (the CI version) is not installed. Download `https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip` (reachable from the sandbox),
   unzip to a folder outside the repo, `chmod +x`, export `GODOT`. `xvfb-run` is present for render tests.
2. Run VR baseline: `GODOT=... tests/ci.sh` and `tests/ci_render.sh`; record results.
3. **Backend:** `pythonocc-core` and FastAPI are not installed. Try, in order: `pip install` of `backend/requirements*.txt`; micromamba / conda-forge `pythonocc-core` + pip for the rest; the repo's Docker image if Docker works.
   If the real backend can run, also run `backend` pytest baseline and VR `tests/ci_e2e.sh`. If it cannot after a reasonable try, record that, and rely on pytest-free reasoning plus the fake backend (`tests/helpers/fake_cad.gd`) for VR, and say which backend tests were written but not run.
4. **Flutter** is not installed. Try installing the Flutter SDK matching `client/pubspec.yaml` (3.6+). If not possible, write FA changes carefully against the existing code and tests, state they were not run.
5. **Before-image of the dock:** write `tests/dock_panels_render.gd` (see "Final deliverable") in its first form and render the *current* deck options row for Extrude, Fillet and Mirror to PNG, as the "before" for John.
**Exit:** a baseline table (what ran, what passed, what could not run and why) saved in `docs/status.md`.

## Phase 1: backend defects (S)

**1.1 At-midpoint next to a converted hole (R-A).**
- BE: write the failing pytest first: sketch on a face with a hole, `convert-entities/edge` on the rim (`construction: true`), then `POST .../constraints {"type":"at_midpoint","point_id","line_id"}` on a pinned construction line;
  expect convergence (`solve-and-refresh`: `converged: true`, no blame). Fix: stop creating the provisional radius `distance` constraint when the converted circle is Fixed; if that is insufficient, make `at_midpoint` pass
  `_residual_verified_convergence`. Files: `backend/app/sketch/solver.py`, `constraints.py`, convert-entities handlers in `backend/app/document/router.py` (near line 4468 and 4515).
- VR: flip the pinned expectation in `tests/e2e_references_more.gd`; keep the take-back path only if a cause remains.
**1.2 Idempotent `convert-entities/edge` (R-E).**
- BE: return the existing Circle / Arc for the same edge (as `convert-entities/vertex` does); pytest that two calls give one entity.
- VR: drop the remembered-answer workaround in `scripts/design_table/sketch_session.gd` once the test passes.
**Exit:** both pytest cases pass (or are written and flagged unrun); VR e2e updated; headless suite green.

## Phase 2: silent, robust references (R-C) (M-L)

Requirement: centres, edges and vertices all usable in sketches; the linking mechanism silent so a dimension feels attached to the part's own edge / point / centre, not a projection; robustness is the acceptance bar.

- **2.1 BE reference flag.** Add a reference flag on entities created by the convert-entities routes (points, lines, circles, arcs); include in responses and native format (additive). Files: `backend/app/sketch/models.py`, `schemas.py`, `backend/app/document/native_format.py`. Tests: save/load round trip; old files load.
- **2.2 BE `convert-entities/face`.** Planar face perpendicular to the sketch plane gives a pinned construction line; a revolved/conical face with axis perpendicular gives a live centre (`circle_centre`-style reference). Reuse signature + OCCT-history machinery (`reference_signature.py`, `reference_history.py`). Idempotent. Tests per face kind and for lost/moved flagging after an upstream edit.
- **2.3 BE cleanup of unused references.** When the last dimension/constraint on a reference is removed, remove the helper entity (or expose what the client needs to). Test, including re-creation on Undo.
- **2.4 FA honour the flag.** Draw reference entities quietly; exclude from selection/delete; use the face route in the picking flow. Files: `client/lib/sketch/sketch_controller.dart`, `sketch_canvas.dart`, `sketch_constraint_overlay.dart` (keep both renderings in step). Widget tests per `docs/flutter-widget-test-lessons.md`.
- **2.5 VR.** `scripts/design_table/part_references.gd` gains face entries; `snap_resolver.gd` a "face axis" kind; `sketch_session.gd` (`ensure_reference`) creates silent references and cleans up; `sketch_view.gd`, `sketch_selection.gd`, `dimension_layout.gd` hide or quiet reference entities and highlight the part's own geometry. Extend `tests/design_table_references.gd`, `design_table_references_more.gd`, `e2e_references*.gd`.
- **2.6 Robustness suite** (one test each, headless with fake backend and real backend where possible): (1) follows or flags after an upstream edit, never silently rebinds; (2) no duplicates on re-pick; (3) survives save, reopen, flat app; (4) no orphans, Undo restores; (5) a failed reference leaves nothing half-made and tells the user; (6) hidden/rolled-back features and reopened earlier sketches resolve correctly.
- **GODOT GATE A:** headless suite + `tests/ci_render.sh`; extend `tests/references_render.gd` to render a sketch with a silent reference dimension to a PNG and check no helper geometry is drawn.
**Exit:** blind-hole scenario works end to end in tests; six robustness tests pass; docs updated.

## Phase 3: persistent reference dimensions (R-B) (M; BE + FA + VR together, same pass)

- **3.1 BE.** A `reference_dimensions` list on the Sketch: `{id, kind (distance|horizontal|vertical|radius|diameter|angle), refs}`; create / edit / delete routes; calculated value in the sketch response; native-format round trip (additive). Solver untouched. Tests: value follows the part after an upstream edit; old files load.
- **3.2 FA.** Draw them in brackets in both sketch renderings (`sketch_canvas.dart`, `sketch_constraint_overlay.dart`; share code or test both); create and delete UI. Widget tests.
- **3.3 VR.** Replace the editor-only bracketed dimension in `sketch_session.gd` with the new routes; Undo still works; `dimension_layout.gd` unchanged in look. Update fake backend (`tests/helpers/fake_cad.gd`) and tests.
- **GODOT GATE B:** headless suite; render a sketch with reference dimensions to PNG.
**Exit:** a reference dimension made in VR survives close/reopen, save/open, and appears in the flat app and the reverse (as far as tests allow; state what ran).

## Phase 4: re-attach for every feature (R-D) (M)

- **4.1 BE.** Let PATCH of Fillet, Chamfer, Pattern, Mirror, Shell and Create Plane accept a replacement reference, re-measure its signature and clear the flag; add whole-edge re-attach to the sketch re-attach route. Tests in the style of `backend/tests/test_reference_identity.py`.
- **4.2 VR.** A **Fix** action on a flagged Build row (`scripts/design_table/build_tree.gd`, `table_build.gd`) that enters a pick mode matching the reference kind (edge, face, axis) using `PartFeatures.edge_ref` / `face_ref` in `part_features.gd`, then PATCH and rebuild. Extend `tests/e2e_references_lost.gd` to a chamfer; add a fake-backend test.
**Exit:** move a fillet onto a chamfer's corner, see the chamfer flagged, pick a new edge, flag clears (tested).

## Phase 5: modelling foundations, M0 (M-L, VR)

- **5.1 Per-feature interface.** Define a small interface (options list, picks required and validation, create and PATCH payload builders, optional preview call). Move Extrude, Revolve, Fillet, Chamfer, Shell, Mirror onto it **one at a time** out of `scripts/design_table/table_editor.gd` (`apply_feature`, option rows, hints); `table_tools.gd` stays the registry. No behaviour change; existing design-table tests stay green after each move.
- **5.2 Docked properties panel.** A panel like `table_tree_window.gd` that shows all of the active tool's settings from the interface's option list, replacing the deck's options row (`table_ui.gd`). First version reproduces today's controls and keeps the existing style (`ui/themes/`); layout/colour reorganisation is John's next step, not this session's.
- **5.3 Body pick.** Laser picks a whole body on the table copy with highlight (`scripts/laser_pick.gd`, `face_highlight.gd`, `topology_pick.gd`).
- **5.4 Pick from earlier sketches.** The Build tree row of a finished sketch exposes its profiles and lines to the laser, for Loft sections, Sweep paths and Pattern directions.
- **5.5 Preview, both mechanisms.** (a) Coarse-preview call for Pattern (`POST .../pattern-features/coarse-preview`) and Loft (`.../loft-features/coarse-preview`), shown as a translucent body, nothing persisted. (b) Eager create + PATCH for everything else, Cancel deletes the feature, following `docs/live-preview-pattern.md`. Add a mesh-size budget check as a test.
- **5.6 Redo (features only).** A redo stack beside `feature_stack` (`table_editor.gd` `undo()` area): undo keeps the create payload, redo resends it (new id), any new action clears it; Build-tree edits reapply the new value. Redo button on the deck.
- **GODOT GATE C:** full headless suite, `ci_render.sh`, and render the panel for each of the six existing tools.
**Exit:** six existing features run through interface and panel; undo then redo of an Extrude works; a translucent fillet preview shows (render).

## Phase 6: new tools, in the decided order (VR, each with all of: registration in `table_tools.gd`, feature class on the interface, `part_features.gd` call, panel options, Build-tree row with Edit, fake-backend test, real-backend e2e if the backend can run, flat-app-opens-it check where possible)

- **6.1 Create Plane** (offset from a plane or face first). Exit: make a plane, sketch on it.
- **6.2 Loft** (2+ sections, each a profile on its own plane; guide curves later; coarse-preview). Exit: two-section loft edited from the Build tree.
- **6.3 Sweep** (path in one sketch, profile in another, path lines picked from the finished sketch). Exit: a swept pipe.
- **6.4 Pattern** (rectangular/circular; direction via edge, sketch line or X/Y/Z chip; count, spacing, reverse, second direction, axis, angle, merge; coarse-preview), **Boolean** (Subtract/Common), **Merge**, **Split**. Check `mate_health.gd` / `dirty_mates.gd` against added and consumed bodies. Exit: made and edited; mates flagged correctly.
- **6.5 Trim, Offset** sketch tools; **Modify** category (Move/Delete Face, Move/Scale/Delete Body) using `ACCENT_MODIFY`; backend routes already exist. Exit: trim a rectangle; move a face on an imported STEP part (fixture).
- **6.6 Ellipse, Ellipse Arc, Spline, Text**, and ellipse edges as references (R-F). Text uses the full keyboard (`scripts/popup_keyboard.gd`) and a font choice. Exit: each draws, dimensions, extrudes.
- **GODOT GATE D (after each of 6.1–6.6):** headless suite green; fake-backend test for the tool; render the tool's panel to PNG.
**Exit of phase:** every tool above reachable on the deck, editable from the Build tree, with preview where decided; docs updated; deck paging (five + More) still works with the longer list (group sensibly if needed, e.g. Sketch-based / Modify / Pattern / Plane).

## Final deliverable: images of the dock panels

1. Finish `tests/dock_panels_render.gd` (software render under Xvfb, same recipe as `tests/design_table_render.gd`: `TABLE_RENDER_DIR=/tmp/dock xvfb-run -a "$GODOT" --path . --script res://tests/dock_panels_render.gd`).
   For every tool (all Sketch, Constrain, Feature, Modify tools, including the old ones), activate it with the fake backend, open the sketch/picks it needs, and save one PNG of the console with the dock panel showing that tool's settings, plus one close-up of the panel. Name files `NN_category_tool.png`.
2. Also save the "before" images from Step 0 (old options row) for Extrude, Fillet, Mirror.
3. Make a contact sheet (a grid of all panels) if an image library is available; otherwise send the individual files.
4. **Send the images to John with `SendUserFile`** (`display: render`, status proactive), with a one-line caption each or one per group. State clearly they are software renders, not headset views, and where the colours and layout look weak, as notes for the reorganisation.
5. Commit the render test (not the PNGs unless small) and describe how to regenerate them in `docs/design-table.md`.

## Verification summary

- Every phase: VR `tests/ci.sh` green against `tests/expected_false.txt`; new tests registered; BE pytest for backend changes (run if the backend env exists, otherwise written and flagged); FA widget tests likewise.
- Render checks: `tests/ci_render.sh` plus the new render tests.
- Real-backend: `tests/ci_e2e.sh` / the `tests/e2e_*.gd` files named above if a backend can run.
- Final report: a table per phase of what ran (headless / software render / real backend / flutter / not run), commits pushed, docs updated, remaining risks (headset-unverified, Quest performance, backend/Flutter not runnable if so).

## Out of scope

Quest hardening, mate parity, shared storage, dock layout / human-factors redesign (John's next step, after the images), sketch-step redo, headset-feel tuning.
