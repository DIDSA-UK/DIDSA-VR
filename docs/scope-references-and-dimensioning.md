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
| R-C | Faces as references (gap item 4) | backend + VR | M |
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

**Recommendation: B.** It avoids touching the solver and cannot corrupt a sketch in an older client. This is a decision for John (see the end).

**Work (B).** Backend: model, CRUD routes, native-format round trip, a measured value in the sketch response, tests. VR: replace the editor-only driven
dimension in `sketch_session.gd` with calls to the new routes; keep Undo. Flat app: draw them and add a way to create one (a separate pass in the
DIDSA-CAD repo; the two apps must show the same thing).
**Done when:** a reference dimension made in VR survives closing and reopening the sketch, saving and opening the file, and shows in the flat app.

## R-C: faces as references

**First question: what is actually missing?** Edges of a face that stands perpendicular to the sketch plane already project to the line the face
shows edge-on, so "dimension to that wall" mostly works today through its edges. The real gaps, to be confirmed on a headset before building:

1. **A cylindrical or conical face whose axis is perpendicular to the sketch plane**, where the rim is not in the sketch plane (a blind hole seen from the top
   face, a boss on a lower level). The axis projects to a centre point. Today only circular edges lying *in* the sketch plane count.
2. **The extreme (silhouette) lines of a curved face**, e.g. the tangent edge of a cylinder seen from the side.
3. **A planar face as a "point on" target** (put a point on the face's plane or its centre).

**Backend work.** A `convert-entities/face` route beside `vertex` and `edge`: planar face perpendicular to the plane gives a pinned construction line;
a revolved face with axis perpendicular gives a pinned centre point (a `circle_centre`-style live reference). Signature and OCCT history already cover
faces (Session A), so the re-find and lost / moved machinery is reusable. The route must be idempotent (see R-E).
VR work: `part_references.gd` gains face entries (needs face data in the glb or from the topology endpoint the edges use), `snap_resolver.gd` gets a "face axis"
kind, `sketch_session.gd: ensure_reference` calls the new route.
**Done when:** with the sketch on the top face of a plate with a blind hole, snapping to the hole's axis and dimensioning to it works and follows an upstream edit.

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

1. **R-A and R-E** (small backend defects; unblock clean behaviour for everything after).
2. **R-G headset session**, in parallel, because it decides whether R-C is needed and what its priority is.
3. **R-B** (the most visible gap for a user: dimensions to existing geometry that do not stick).
4. **R-D** (completes the "flagged, never silent" promise for every feature).
5. **R-C** only if the headset session shows the face cases matter.
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

## Decisions for John

1. R-B: separate list of reference dimensions (recommended) or a `driven` flag on the constraint?
2. R-C: build it now, or wait for a headset session to show whether edge-on projection is enough?
3. R-B needs a flat-app change. Is that in scope for the same pass, or does VR ship first behind a backend capability check?
