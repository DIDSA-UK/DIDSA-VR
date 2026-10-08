# Implementation plan: references, dimensioning and modelling depth

2026-10-08. Turns the decisions in `docs/scope-references-and-dimensioning.md` and `docs/scope-modelling-depth.md` into ordered steps. Repos: **BE** = DIDSA-CAD
`backend/`, **FA** = DIDSA-CAD `client/` (flat app), **VR** = this repo. Sizes are relative effort (S = a session or less, M = a few, L = a project). Do not open pull requests
unless asked.

## Ground rules

- Every step ships with its tests; nothing counts as done on a code read alone.
- Backend and flat-app changes to a shared schema or the native file ship together with the VR change that uses them (decision: keep the apps in step).
- Headless and real-backend tests prove mechanics only. Nothing is "felt" until a headset session; those sessions are gates, listed below.
- Check first (Step 0) what can actually be run in the working environment (Godot headless, Python backend, Flutter). Any step that cannot be run there says so in its result.

## Step 0: baseline (S)

1. Run the existing suites and record the results: BE `pytest` (needs `pythonocc-core`; the repo's CI image has it), VR `tests/ci.sh` (headless) and, where a backend is available, `tests/ci_e2e.sh`, FA `flutter test`.
2. Write down what could not be run and why. Fix nothing yet.
**Exit:** a recorded baseline, so later failures can be told from regressions.

## Phase 1: backend defects (S, BE then VR)

**1.1 At-midpoint next to a converted hole (R-A).**
- BE: write the failing pytest first (sketch on a face with a hole, `convert-entities/edge` on the rim, then `at_midpoint` on a pinned construction line; expect converged). Then fix: stop creating the provisional radius `distance` constraint when the circle is Fixed; if that is not enough, extend `_residual_verified_convergence` for `at_midpoint`. Files: `app/sketch/solver.py`, `app/sketch/constraints.py`, convert-entities code in `app/document/router.py`.
- VR: flip the pinned expectation in `tests/e2e_references_more.gd`; keep the take-back path only if some cause remains.
**Exit:** midpoint snapping works in a sketch that holds a converted hole, against the real backend.

**1.2 Idempotent `convert-entities/edge` (R-E).**
- BE: return the existing Circle or Arc for the same edge instead of adding another; test that two calls give one entity.
- VR: remove the remembered-answer workaround in `sketch_session.gd` once the route is idempotent, but only after the test above passes.
**Exit:** repeated picks never stack circles.

## Phase 2: silent, robust references (R-C) (M-L)

Goal: centres, edges and vertices all usable in sketches, linking mechanism silent, robustness the acceptance bar.

**2.1 BE: mark reference entities.** Add a reference flag to the entities the convert-entities routes create (points, lines, circles, arcs); include it in responses and in the native format (additive, so older clients ignore it). Files: `app/sketch/models.py`, `schemas.py`, `app/document/native_format.py`. Tests: round trip through save and load.

**2.2 BE: `convert-entities/face`.** Planar face perpendicular to the sketch plane gives a pinned construction line; a revolved face with its axis perpendicular gives a live centre (a `circle_centre`-style reference). Reuse the signature and OCCT-history machinery from Session A. Idempotent. Tests for each face kind, and for lost / moved flagging after an upstream edit.

**2.3 BE: cleanup of unused references.** When the last dimension or constraint on a reference is removed, remove the helper entity (or provide the data so the client can). Test it, including Undo.

**2.4 FA: honour the flag.** Draw reference entities quietly, keep them out of selection and delete, use the face route in the picking flow. Files: `client/lib/sketch/sketch_controller.dart`, `sketch_canvas.dart`, `sketch_constraint_overlay.dart`. Widget tests per `docs/flutter-widget-test-lessons.md`.

**2.5 VR: use the flag and the face route.** `part_references.gd` gains face entries; `snap_resolver.gd` gets a "face axis" kind; `sketch_session.gd` (`ensure_reference`) handles silent references and cleanup; `sketch_view.gd` and `sketch_selection.gd` filter reference entities from drawing and selection while highlighting the part's own geometry. Tests: extend `tests/design_table_references*.gd` and `tests/e2e_references*.gd`.

**2.6 Robustness suite.** One test per item: (1) follows or flags after an upstream edit; (2) no duplicates; (3) survives save, reopen and the flat app; (4) no orphans, Undo restores; (5) a failed reference leaves nothing half-made; (6) hidden or rolled-back features and reopened earlier sketches resolve correctly.
**Exit:** all six pass, plus the blind-hole scenario in the scope doc works end to end.

## Phase 3: persistent reference dimensions (R-B) (M, BE + FA + VR together)

**3.1 BE:** a `reference_dimensions` list on the Sketch (`{id, kind, refs}`), create / edit / delete routes, a calculated value in the sketch response, native-format round trip (additive). The solver is untouched. Tests: value follows the part after an upstream edit; old-format files load.
**3.2 FA:** draw them in brackets in both sketch renderings (`sketch_canvas.dart` and `sketch_constraint_overlay.dart` must not drift: share the drawing code or test both); a way to create and delete one.
**3.3 VR:** replace the editor-only bracketed dimension in `sketch_session.gd` with the routes; Undo continues to work; `dimension_layout.gd` draws them as today.
**Exit:** a reference dimension made in VR survives closing and reopening the sketch, saving and opening the file, and shows in the flat app, and the reverse.

## Phase 4: re-attach for every feature (R-D) (M, BE then VR)

**4.1 BE:** let the PATCH route of Fillet, Chamfer, Pattern, Mirror, Shell and Create Plane accept a replacement reference and re-measure its signature, clearing the flag; add whole-edge re-attach to the sketch re-attach route. Tests per feature, including `test_reference_identity.py` style cases.
**4.2 VR:** a Fix action on a flagged Build row (`build_tree.gd`, `table_build.gd`) that enters a pick mode matching the reference kind (edge, face, axis), reusing `PartFeatures.edge_ref` and `face_ref`, then PATCH and rebuild. Test: `tests/e2e_references_lost.gd` extended to a chamfer.
**Exit:** move a fillet onto a chamfer's corner, see the chamfer flagged, pick a new edge, flag clears.

## Phase 5: modelling foundations, M0 (M-L, VR)

**5.1 Per-feature interface.** Extract a small interface (options, picks needed, create and PATCH payloads, optional preview) and move Extrude, Revolve, Fillet, Chamfer, Shell and Mirror onto it one at a time. `table_editor.gd` loses its `match` routing. No behaviour change; existing tests stay green after each move.
**5.2 Docked properties panel.** A panel like the tree window that shows all of the active tool's settings, driven by the interface's option list. Replaces the deck's options row. First version matches today's controls; its layout, space and colour get the human-factors pass as a separate step (Phase 8).
**5.3 Body pick.** Laser picks a whole body on the table copy, with a highlight, for Boolean, Merge, Split and Pattern. Files: `scripts/laser_pick.gd`, the highlight code.
**5.4 Pick a profile or line from an earlier sketch.** Needed by Loft, Sweep and Pattern direction. Build tree row for a finished sketch exposes its profiles and lines to the laser.
**5.5 Preview plumbing, both mechanisms.** (a) Coarse-preview call for Pattern and Loft, rendered as a translucent body, nothing persisted. (b) Eager create + PATCH for the rest, with Cancel deleting the feature. Includes a Quest mesh-size budget check as a test.
**5.6 Redo for features.** Redo stack alongside `feature_stack`: undo keeps the create payload, redo resends it (new id), any new action clears it; Build-tree edits reapply the new value.
**Exit:** the six existing features run through the interface and panel; undo then redo of an Extrude works; a translucent preview shows for a fillet.

## Phase 6: new features in decided order (VR, each against the real backend)

| Step | Feature | Notes | Exit |
|---|---|---|---|
| 6.1 | Create Plane | Offset from a plane or face first | Make a plane, sketch on it |
| 6.2 | Loft | Two or more sections on planes; coarse-preview; Build-tree edit | Two-section loft, edited |
| 6.3 | Sweep | Path in one sketch, profile in another | A swept pipe |
| 6.4 | Pattern, Boolean, Merge, Split | Check `mate_health.gd` / `dirty_mates.gd` against added and consumed bodies | Made and edited; mates flagged correctly |
| 6.5 | Trim, Offset; Modify category (Move / Delete Face, Move / Scale / Delete Body) | New category on the deck | Trim a rectangle; move a face on an imported STEP part |
| 6.6 | Ellipse, Spline, Text (and ellipse edges as references, R-F) | Text needs the full keyboard and a font choice | Each draws, dimensions and extrudes |

Each feature also: a Build-tree row with Edit, a headless test on the fake backend, a real-backend e2e test, a check that the flat app opens a VR-saved file with it, and an entry in `tests/e2e_ci_list.txt` where appropriate.

## Phase 7: headset gates (needs a headset; John)

- **After Phase 2:** does the silent behaviour feel right; tune snap and pick radii, reference colours and weights (R-G constants).
- **After Phase 5:** is the docked panel reachable and readable; Quest frame time and mesh size with a preview showing.
- **After 6.2 / 6.3:** Loft and Sweep workflow feel.
Prepare a one-page checklist before each session. Findings go back into the gap list.

## Phase 8: dock layout and human factors (VR, needs its own scoping first)

Audit the panel from Phase 5.2 against headset findings; scope a layout, use of space and colour pass (reach and reading distance, grouping, target size and contrast, colour meaning and colour-blind safety); then rebuild. Write the scope doc before any code.

## Sequencing and parallel work

- Phase 1 first; it is small and unblocks Phase 2.
- Phases 2 to 4 are the references stream. Phase 5 is the modelling stream; it has no dependency on Phases 2 to 4 and can run in parallel if there is capacity.
- Phase 6 follows Phase 5. Phase 8 follows the first headset session after Phase 5.
- Not in this plan: Quest hardening, mate parity, shared storage (separate roadmap items, each needing its own scoping).

## Risks

- Everything is unproven on a Quest; headset gates may change priorities.
- Shared schema and native-file changes (Phases 2 and 3) touch two apps: all changes are additive so older clients ignore them, but the flat app must be updated in the same pass.
- `table_editor.gd` refactor (5.1) touches the most-used code; move one feature at a time and keep tests green.
- Quest performance for previews and large glb refetches is unmeasured.
