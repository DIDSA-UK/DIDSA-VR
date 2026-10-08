# Scope: references and dimensioning (design table)

Scoping pass, 2026-10-08. Covers open items 2-5 of `docs/design-table-gaps.md` ("Open items at a glance") plus the small related
backend defects named in `docs/handover-references-overhaul.md` ("Session B result"). Nothing here is built. The roadmap entry
is in DIDSA-CAD `docs/roadmap.md` ("DIDSA-VR: next-work candidates").

**Read first:** `docs/design-table-gaps.md` (R1 / R2), `docs/handover-references-overhaul.md`, DIDSA-CAD `docs/reference-identity-design.md`.

## Where it stands

Already closed (code and tests, not seen in a headset): the part's corners, straight edges, circular edges in the sketch plane,
edge midpoints and along-edge points are implicit references; the backend tracks each reference by signature and OCCT history and
flags it lost / moved; the Build row, the status line and the sketch show the flags; Fix / Keep re-attach a sketch's points.

What is left falls into seven pieces. Four need backend work, so they come first in the order below.

| ID | Piece | Repo | Size |
|---|---|---|---|
| R-A | At-midpoint refused in a sketch holding a converted hole (gap item 2) | backend | S |
| R-B | Driven (reference-only) dimensions that persist (gap item 3) | backend + VR + flat app | M |
| R-C | Centres, edges, vertices and face axes as seamless sketch references, robust (gap item 4) | backend + VR | M-L |
| R-D | Re-attach for non-sketch features, and one-call edge re-attach (gap item 5) | backend + VR | M |
| R-E | `convert-entities/edge` is not idempotent | backend | S |
| R-F | Ellipse edges seen along the normal are drawn but not offered (gap item 4, second half) | VR (+ backend if Ellipse lands) | S, but waits on modelling depth |
| R-G | Headset tuning of the named constants | VR | S, needs a headset |

Sizes are relative effort (S = a session or less, M = a few sessions, L = a project), not calendar estimates.

## R-A: at-midpoint refused next to a converted hole

**Defect.** After `convert-entities/edge` makes the pinned circle for a hole rim, `solve-and-refresh` reports `result_code` 5 (a redundancy).
`at_midpoint` is not in the backend's redundancy-safe allowlist, so `converged` is distrusted and the constraint is refused. VR takes the
constraint and its point back out and says so (`tests/e2e_references_more.gd` pins this).

**Likely cause (unproven).** The converted circle is Fixed and also keeps its provisional radius `distance` constraint, which py-slvs reads as redundant.

**Options.**
1. Do not create the radius `distance` constraint when the circle is Fixed (removes the redundancy at the source). Preferred: it also helps any
   other constraint that is not on the allowlist.
2. Let `at_midpoint` through when the residual check holds (`_residual_verified_convergence`; the roadmap says extend it per type, same pattern).

**Work.** Reproduce in a backend pytest first (steps are in the handover), then fix. VR: flip the pinned expectation in `e2e_references_more.gd`
and remove the take-back path only if the fix removes every cause.
**Done when:** midpoint snap works in a sketch that already holds a converted hole, against the real backend.

## R-B: driven dimensions that persist

**Problem.** Two pinned things (two corners, an edge and a corner, a hole and the origin) cannot be driven by a dimension, so VR offers a *reference
dimension* in brackets. It lives in the editor only and is gone when the sketch closes. The flat app has the same limitation.

**Two designs.**

| | A: a flag on the constraint | B: a separate list of reference dimensions |
|---|---|---|
| Shape | `driven: bool` on Distance / Angle / radius constraints; the solver skips them and reports a measured value | `reference_dimensions` on the Sketch: `{id, kind, refs}`; value computed on read |
| Solver | Touched: must be excluded from the build and from redundancy counting | Untouched |
| Old clients opening a new file | **Hazard:** a client that ignores the flag would enforce the dimension and could over-constrain or move a sketch | Safe: an unknown list is ignored |
| Native file | Needs a format-version decision | Additive list |
| Flat app | Draw brackets; add a toggle | Draw brackets; same |

**Decided (John, 2026-10-08): B.** It avoids touching the solver and cannot corrupt a sketch in an older client.

**Work (B).** Backend: model, CRUD routes, native-format round trip, a measured value in the sketch response, tests. VR: replace the editor-only driven
dimension in `sketch_session.gd` with calls to the new routes; keep Undo. Flat app: draw them and add a way to create one (a separate pass in the
DIDSA-CAD repo; the two apps must show the same thing).
**Done when:** a reference dimension made in VR survives closing and reopening the sketch, saving and opening the file, and shows in the flat app.

## R-C: every part feature usable in a sketch, silently and robustly

**Requirement (John, 2026-10-08).** Centres, edges and vertices must all be usable inside sketches. The mechanism that links the sketch to the part (the pinned points, lines
and circles, the references behind them) should be **silent**: to the user a dimension or constraint goes *to the edge, point or centre itself*, not to a projection
of it. **Robustness is the key quality**, ahead of reach.

This is for the **sketcher**. Mate references are a separate item (see item 4 in the roadmap section).

**Where it stands.** Corners, straight edges, circular edges lying in the sketch plane, hole centres, edge midpoints and along-edge points already work with no Convert step.
What is not silent or not complete:

1. **Visible plumbing.** The pinned points, construction lines and circles the session makes (`ensure_reference`) are ordinary sketch entities. They appear in the drawing and
   in Select's menu, so the user sees the machinery.
2. **Not covered:** a cylindrical or conical face whose axis is perpendicular to the sketch plane when its rim is not in the plane (a blind hole seen from the top face); the
   extreme (silhouette) lines of a curved face; ellipse edges (R-F).
3. **Idempotence:** `convert-entities/edge` stacks duplicate circles (R-E).

**Design.**
- *Silent:* mark every entity the session creates as a reference with a flag the sketch view and Select respect. Draw it quietly, or not at all, and show the highlight on the **part's own**
  corner, edge or centre. A reference entity cannot be selected on its own, deleted or moved, but it can be dimensioned and constrained to through the part's feature. A dimension
  label attaches to the part's geometry. If the user deletes the dimension or constraint, an unused reference is cleaned up so nothing orphaned is left behind.
- *Complete:* add the face cases through a `convert-entities/face` route: a planar face perpendicular to the plane gives a pinned line; a revolved face with its axis perpendicular gives
  a live centre (a `circle_centre`-style reference). Signature and OCCT history already cover faces (Session A).
- *Robust* (the acceptance bar, each with a test):
  1. The reference follows an upstream edit that keeps the topology; it is flagged lost or moved, never silently rebound, when it does not (existing behaviour; keep the tests green).
  2. Re-picking the same thing never makes a duplicate (idempotent routes, R-E).
  3. Closing and reopening a sketch, saving and opening the file, and opening it in the flat app all preserve the reference and the dimension to it.
  4. No orphans: deleting the last dimension or constraint on a reference removes the helper entity; Undo restores it.
  5. A failure to make a reference (solver refusal, backend error) leaves no half-made entities and tells the user plainly.
  6. Hidden or rolled-back features and reopened earlier sketches resolve against the right version of the part (existing behaviour; keep the tests green).

**Work.** Backend: `convert-entities/face`, the reference flag on entities, R-E. VR: `part_references.gd` gains face entries, `snap_resolver.gd` a "face axis" kind, `sketch_session.gd` the
silent-reference handling, `sketch_view.gd` and `sketch_selection.gd` the filtering. Flat app: honour the flag when drawing.
**Done when:** with the sketch on the top face of a plate with a blind hole, snapping to the hole's axis and dimensioning to it works, shows no helper geometry, and survives edit, save, reopen and
the flat app; and all six robustness tests pass.

## R-D: re-attach for non-sketch features, and one-call edge re-attach

**Problem.** A fillet, chamfer, pattern, mirror, shell or create-plane with a `lost_references` / `moved_references` flag shows it on its Build row, but only
sketches can be mended from the table. An edge reference is two vertex references, re-picked one at a time.

**Backend.** (1) A re-attach / confirm route per non-sketch Feature type, taking the same `SubShapeRef` payload as create (it is the PATCH the feature
already has, plus clearing the flag); simplest is to let the existing PATCH accept a replacement ref and re-measure the signature. (2) Accept a whole edge in the sketch re-attach
route so one pick mends both corners.
**VR.** Reuse the Fix walk (`Select > Fix` for sketches): a **Fix** button on a flagged Build row enters a pick mode that matches the ref kind (edge for fillet / chamfer,
face for shell / create-plane, edge or axis for pattern), the laser pick reuses `PartFeatures.edge_ref` / `face_ref`, then PATCH and rebuild.
**Done when:** move a fillet to the corner a chamfer references, see it flagged lost on the chamfer's row, pick a new edge, see the flag clear and the part rebuild.

## R-E: idempotent `convert-entities/edge`

Every call adds a new Circle (the centre point is reused). VR works around this by remembering its answer and reading `GET .../external-references` on reopen.
Make the route idempotent per edge, as `convert-entities/vertex` is. Small backend change plus test; then VR's remembered-answer workaround can go.

## R-F: ellipses

A circular edge seen at an angle is an ellipse in the sketch plane: drawn, not offered. Fixing it needs the Ellipse entity in VR (see
`docs/scope-modelling-depth.md`), so do it with that, not before.

## R-G: headset tuning

No code until a headset session. Named constants to look at: `sketch_tilt_degrees`, `sheet_window_m`, `REF_*` in `sketch_view.gd`, `LOST_COLOUR` /
`MOVED_COLOUR`, line and edge weights, `SketchClip.DEPTH_M` / `MARGIN_M`, snap and pick radii. Prepare a one-page checklist so the session is quick.

## Order of work

1. **R-A and R-E** (small backend defects; R-E is also a robustness requirement of R-C).
2. **R-C**, backend then VR, against the robustness bar above.
3. **R-B** (reference dimensions that persist; it uses the same reference mechanism, so after R-C).
4. **R-D** (re-attach for every feature).
5. **R-G headset session** as soon as a build exists; it tunes sizes and colours and checks that the silent behaviour feels right.
6. **R-F** with Ellipse.

## Tests

- Backend pytest for each backend change, including a repro for R-A written first.
- VR: extend `tests/design_table_references*.gd` (fake backend) and `tests/e2e_references*.gd` (real backend, local only). R-D reuses the pattern of
  `tests/e2e_references_lost.gd` (move a fillet, read the flags).
- Flat app (R-B): client widget tests; the repo's note on running them is `docs/flutter-widget-test-lessons.md`.

## Risks

- Everything here is headless-verified only; a headset session may change what matters.
- R-B changes the file or schema shared by both apps; it needs the flat-app side in the same release or the apps will disagree.
- Quest performance of the reference overlay on large parts is unmeasured (`part_references.gd` is grid-indexed, but nothing has been timed on-device).

## Decisions

Decided (John, 2026-10-08):
1. R-B: a separate list of reference dimensions, not a `driven` flag.
2. R-C: build it, covering centres, edges and vertices; silent to the user and robust above all.
3. R-B: the flat-app change ships in the same pass, so the two apps stay in step.
