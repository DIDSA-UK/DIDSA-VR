# Design table: known gaps and what became of them

What the design table (milestone 2) did not do, or did not do well, as of the first headset session, and where each stands now. Each gap has an
ID, what was wrong, how it was closed (or why it is accepted), and its **status**. Testing-related gaps (the headset has barely been used, Quest 2
is unmeasured, CI covers only the headless suite (no backend, no headset), the flat app's own UI has not opened a VR-saved file) are tracked in `docs/design-table.md` ("Performance",
"Not built / known gaps") and not repeated here.

**Everything marked Closed is closed in code and tests (headless, and against a real backend where it touches one). None of it has been seen in a
headset**, so numbers that depend on feel (the 60 degree tilt, the sheet size, line weight, grip pan / zoom, the one-hand turn) are called out below.

## Open items at a glance (read this first)

Everything else in this file is history and detail. This is the one list of what is still open, as of 2026-10-06 (end of Session B). Items marked **backend** live in DIDSA-CAD.

| # | Open item | Where | Detail |
|---|---|---|---|
| 1 | **Nothing has been seen in a headset**: the 60 degree tilt, window size and zoom range, grip pan / zoom feel, reference line weight and colours (`REF_*` in `sketch_view.gd`), the flagged-point colours (`LOST_COLOUR` / `MOVED_COLOUR`), line / text weights, edge weight, the Quest save folder, and the clip box (`SketchClip.DEPTH_M`, `MARGIN_M`: how deep either side of the sketch plane the part survives, and whether the cut shows well). All are named constants. | VR | "Everything marked Closed" note below |
| 2 | ~~At-midpoint is refused in a sketch that already holds a converted hole~~ **Closed 2026-10-08 (R-A).** The cause was redundancy: a converted circle was pinned in every point and still carried its radius and cardinal-point constraints (and `add_fixed_constraint` listed the radius point twice), which py-slvs reports as `result_code` 5, after which `converged` was distrusted for any constraint outside the allowlist. The backend now drops those constraints; the sketch solves with `result_code` 0 and the at-midpoint is held (`tests/e2e_references_more.gd`, real backend). The session still takes a refused point back out completely as a safety net. | **backend**, done | `docs/status.md` 2026-10-08 |
| 3 | ~~A driven (reference-only) dimension lasts only while the sketch is open~~ **Closed 2026-10-08 (R-B).** Decided design B: a separate `reference_dimensions` list on the sketch (`{id, kind (distance / horizontal / vertical / radius / diameter / angle), refs}`), the value calculated on read, so the solver is untouched and an older client simply ignores the list. Routes `POST / GET / PATCH / DELETE .../reference-dimensions`, the values in the solve-and-refresh bundle, the export and the native file (additive). VR stores what Dimension keeps on the backend (`keep_driven`), draws it in brackets from the backend's value, Undo deletes it; the flat app draws it in brackets in both renderings and makes / removes it from the Dimension bar. Real-backend test `e2e_reference_dimensions.gd`: survives closing and reopening the sketch, follows the part (60 becomes 90 when the part is made 30 mm wider), is in the native export and VR's saved file and survives opening it again. The flat app opening a **VR-saved file in its UI** has not been run (no device). | VR + **backend** + flat app, done | `docs/status.md` 2026-10-08 |
| 4 | **Faces as references: done for the two shapes that matter (2026-10-08, R-C); the rest is open.** A flat face square to the sketch plane (a line seen edge-on) and a cylinder whose axis is square to it (a hole's wall, including a **blind** hole whose rim is not in the plane) are references now: `convert-entities/face` in the backend, a `face_axis` snap and pick in VR, the live centre following the hole and flagged when it is gone. The references are **silent**: the pinned helpers are flagged by the backend (`reference_ids`, `is_reference`), drawn in the quiet reference blue, never offered for selection or deletion, and cleaned up when nothing depends on them. **Still open:** cones and spheres seen square on (the backend supports a cone; VR does not offer it), silhouette lines of a curved face, an ellipse seen along the normal (R-F, with the Ellipse tool); in the flat app a face has no picking UI yet (`SketchController.ensureReferenceFace` and the API call are there and tested, the ghost-face picking is not wired). | VR + backend + flat app | R1 below |
| 5 | **Re-attach is one corner at a time** (an edge is two vertex references, re-picked one by one, as in the flat app), and only sketches have a re-attach route: a fillet / chamfer / pattern with a lost or moved reference is flagged on its Build row but cannot be mended from the table. | VR + **backend** (a re-attach route for non-sketch Features, listed in the handover as still open) | R2 below |
| 6 | Sub-assemblies: mates through them (G14), New part inside one (G16), carrying a mated part (G15, a workaround exists). | VR (+ backend nested solve) | the tables below |
| 7 | Modelling depth (G8): Pattern, Sweep, Loft, booleans, direct edit; sketch tools Ellipse, Spline, Text, Trim, Offset (Point is already built); a preview before Apply; redo. Build tree sections for Planes / Surfaces / Curves (G11). | VR | the tables below; scoped in `docs/scope-modelling-depth.md` |

**Closed since the last version of this list (all in code and tests, none in a headset):** the references drift in the backend (DIDSA-CAD, Session A: a geometric signature, OCCT history, `has_lost_reference` and a "moved" state, a re-attach route) and the flat app's implicit referencing (Session A); the part clipped to the sketch window (N2e / "Sketch mode and the grips" item 6); circular edges as references (centre snap, rim pick, radius / diameter), an edge's midpoint and the nearest point along it as snaps, and driven dimensions between pinned things (R1); references for a part with something hidden or rolled back and for a reopened sketch that is not the last feature (R1); lost / moved references shown on the Build row, in the status line, on the sketch, with Fix / Keep (R2).

Accepted, not open: G5 (legacy bundle save shape only), G9 (cascade delete cannot be undone).

## Feedback from the first headset session

| ID | What was found | How it was closed | Status |
|---|---|---|---|
| N1 | Edges are not drawn on any 3D model in VR. | View modes **Shaded / Shaded + edges / Wireframe** (Tablet > View > Display), edges from the backend's own B-rep topology (a sharp-angle fallback for bare models), saved setting. See `docs/design-table.md` "View modes". | Closed. Unverified: one-pixel lines may be faint on a Quest (fallback: ribbons). |
| N2a | The sketch sits flat on the table, which is awkward. | The sketch plane stands up **60 degrees from the slab** on sketch start (animated; instant with Reduce motion), the part floats a little higher so the sheet clears the slab; Reset and Fit restore it. | Closed. **Assumption to check on a headset:** "60 degrees" is measured from the slab (the console already leans 22 degrees, so the room sees about 82 degrees from horizontal). `sketch_tilt_degrees` is the one number to change if 60 degrees from horizontal was meant. |
| N2b | Points can only be dropped on a small area; no grid. | A fixed **0.8 x 0.4 m** sheet (`sheet_window_m`) with a faint 1-2-5 grid that re-spaces as the part is zoomed. | Closed. Unverified: the sheet size. |
| N2c | The sketch origin is not a snap point; nothing can be constrained to it or dimensioned from it. | The backend's real origin point is read when a sketch opens (it is created lazily) and used like any point: snap kind "origin", Coincident, a dimension can start or end at it. Checked against the real backend. | Closed. |
| N2d | Sketch entities cannot be selected; no contextual menu. | A **Select** tool (on by default when a sketch opens) and a menu in the options row of what applies to the selection, ported from the flat app's selection matrix, plus Fix / Construction / Delete. Every option checked against the real constraint schemas. | Closed. |
| N2e | The sketch canvas cannot be panned or zoomed. | The **sketch window** is a fixed 0.8 x 0.4 m rectangle in the sketch plane, anchored in the world (the console); the part and its sketch slide and scale together **under** it, so the part's edges and corners always line up with the sketch. One grip slides the part in the plane, two hands zoom it about the point between them (1/50 to 200x while a sketch is open), the drawing is clipped to the window. Tried twice: first the window moved with the part (the frame got dragged around); then a separate canvas zoom independent of the part (a mistake: it broke the registration that dimensioning to part geometry needs, and was replaced). | Closed. Unverified: how the grips feel. |
| N3 | The corner handle for dragging the table bigger is hard to find. | A small bright point on each corner of the slab's rectangle. | Closed. |

### Sketch mode and the grips (the rules the pan / zoom follows)

The sketch is a child of the part's table copy, so it always moves, turns and scales **with the part**: the part's edges and corners stay exactly under
the sketch's coordinates (sketch mm = part mm), which is what dimensioning to existing geometry needs. What is fixed is the **window**: a rectangle in the
sketch plane, anchored in the console when the sketch opens (`design_table.window_anchor`), 0.8 x 0.4 m of world whatever the zoom. Panning and
zooming slide and scale the part under it, so it works as a viewport, and the drawing is clipped to it by `sketch_lines.gdshader`. While a sketch is open:

1. With **Part: Locked** (the default) the grips slide the part **along the sketch plane** (whatever would move it off the plane is taken back out,
   `pin_sketch_plane`) and two hands zoom it about the point between them; nothing turns, the stick does not spin or tip it, Reset restores the tilt.
   **Part: Free** gives the part its ordinary move / turn / scale back, anywhere.
2. Letting go beyond the slab does **not** send the real part back to the arena (that would end the sketch); it is held back over the slab.
3. A grip inside the window's rectangle takes the part, not only one near its bounding sphere.
4. The zoom range is 1/50 to 200x (everyday handling: 0.4 to 3x, or the Settings limit); Fit slides and zooms the part so the sketch fills the window.
5. The snap, pick and dimension-label reaches are sizes in the world, so zoomed out they span many sketch mm and zoomed in few.
6. Labels show while their middle is inside the window. **The part is clipped to the window** (`sketch_clip.gd`): its copy, its edge lines and its hover / selection overlays are discarded outside a box, the window's rectangle in the sketch plane with `DEPTH_M` (0.25 m) either side, by the same shaders and global-uniform scheme as the section tool (`shaders/clip_common.gdshaderinc`, shared by `section_clip`, `edge_lines` and `highlight_clip`; a per-material `window_clip` switch picks what is clipped, so the arena's parts never are). Colour (a flat override or the glTF surfaces' own albedo), view modes and overlays keep working; the cut shows the inside of the part darker, as the section tool's does. A very tall part is cut at `DEPTH_M` below the plane as well as above it. Checked in a software render (`tests/sketch_clip_render.gd`, `sketch_clip_picture.gd`), not in a headset; `DEPTH_M` and `MARGIN_M` are the numbers that depend on feel.

### Dimensioning to the part's own geometry (R1) and how far references can be trusted (R2)

**R1, closed.** Dimensioning to existing edges and corners used to be missing (only the corners of the face you sketched on snapped, to a free point
with no link). Now the part's geometry, projected onto the sketch plane, is reference geometry everywhere (`part_references.gd`): snap, pick and
dimension go straight to it, and the session makes the pinned point / construction line / circle on demand (`sketch_session.gd: ensure_reference`), so
there is no convert / fix / construction step. What counts:

* **Corners** (a pinned point, `convert-entities/vertex`, idempotent) and **straight edges** (two pinned points and a pinned construction line, reused if there).
* **Circular edges in the sketch plane** (a hole or boss, or an arc of one, such as a fillet's): snapping near the **centre** (kind "centre") or picking it
  makes a pinned construction circle (or arc) on the rim with `convert-entities/edge`; its centre is a live `circle_centre` reference (DIDSA-CAD, Session A:
  it follows the hole when the part changes and is flagged when it is gone), the shape starts on it, and a second use reuses it (the answer is remembered and
  read back from `GET .../external-references` when the sketch is reopened, since the route adds a new circle on every call). Aim Dimension / Select at the
  **rim** and the circle is picked: radius and diameter are offered (as driven candidates, below).
* **The middle of a straight edge** (snap kind "edge_midpoint") and **the nearest point along an edge or a rim** ("edge_point"): the edge is made a pinned
  line (or circle) and a NEW point is made on it and held there by an `at_midpoint` / `point_on_line` / `point_on_circle` constraint; the midpoint's point is
  reused if the edge already has one. If the solver will not accept the constraint (see open item 2: `at_midpoint` in a sketch that already has a converted
  hole) it and its point are taken straight back out with a message.
* **A driven (reference-only) dimension** between pinned things. Nothing a dimension says could move two pinned corners, a pinned edge, a hole's circle or the
  origin, so the candidates for them are marked **driven**: pointing at one keeps it as a dimension in brackets, `(12.5)`, `(R30)`, in a quieter colour; it
  measures live from where the things are, sends nothing to the backend (it has no driven constraint) and lasts as long as the sketch is open (Undo takes it
  back). Open item 3.
* **Which part geometry.** The references have to be the geometry the backend resolves the sketch against, which is the part as it stood at the sketch's
  place in the history. For a sketch that is the last thing built, with nothing hidden or rolled back, that is the table's own copy. Otherwise (something hidden
  or rolled back, or a reopened sketch with features after it) the part is fetched again with `rollback_excluded_feature_ids` for everything after the sketch
  and only its topology is used (`table_editor.gd: _load_references`); the picture on the table does not change, so with a hidden feature the part's corners
  shown under the sketch are the ones the sketch sees, and the status line says so. A backend without the Build tree's glb parameters offers none.
* **Faces (R-C, 2026-10-08).** A flat face square to the sketch plane and a cylinder with its axis square to it are references (`part_references.gd`: read from each face's boundary edges; `convert-entities/face`; the session's `ensure_reference` kinds `face_line` and `face_axis`). A blind hole seen from its far side now has a centre to snap to and dimension. Everything the session makes to point at the part (corners, edges, rims, faces) is flagged `reference: true`, so it is a **helper**: drawn quietly (`REF_USED_COLOUR`), not selectable, not deletable, removed by the backend when its last dimension or constraint goes. Cones and ellipses are not offered.

Checked with the fake backend (`design_table_references.gd`, `design_table_references_more.gd`) and the real one (`e2e_references.gd`, `e2e_references_more.gd`,
`e2e_references_lost.gd`, `e2e_references_history.gd`).

**R2, fixed in the backend (Session A, 2026-10-06), shown here.** A reference is `body_id` + a raw OCCT index, and used to **silently bind to a different corner** when
an upstream edit changed the topology (5 of 7 probes). DIDSA-CAD now stores a geometric signature with each reference, re-finds it by signature and OCCT
history, follows it where it can, and **flags** it where it cannot (`has_lost_reference`, `lost_reference_point_ids`, `moved_reference_point_ids` ("potentially
moved": bound on weaker evidence), `followed_reference_point_ids`, `reference_reasons`; per point `GET .../external-references`; `.../reattach`, `.../confirm`).
The design table shows it:

* the **Build row** carries a note (`lost reference`, `2 lost references`, `reference may have moved`, `1 lost, 1 may have moved`; sketches count point ids, other
  features their reference paths) in the warning colour, and the status line names the sketches and features when the list is read;
* a **sketch** shows the flagged points in red (lost) and amber (may have moved) and a warning ("Reference to the part: 1 lost, 1 may have moved.") in the
  status line while it is open;
* with nothing picked, **Select's options row offers Fix** (and **Keep moved ones**): Fix walks the flagged points, lost first; point at the corner of the part
  (or the centre of the hole) the point should follow and pull the trigger and the point is re-attached (`reattach`: it keeps its id, so every line and
  dimension on it stays); Keep confirms the moved ones (`confirm`). A corner-following point refuses a hole and the other way round. Then press Done to
  rebuild the part from the sketch.

`tests/e2e_references_lost.gd` moves a fillet to another edge against the real backend: to an edge away from the corner the reference follows (nothing flagged);
onto the corner itself it is flagged lost (`consumed_by_<fillet>`), shown, and re-picked. Not done: a re-attach for non-sketch features (open item 5), showing the
backend's `candidates` for an ambiguous reference (the re-pick is free: aim at any corner).

## Gaps found while building it

### Work loss
| ID | Gap | How it was closed | Status |
|---|---|---|---|
| G1 | **New assembly** and STEP / STL / OBJ import replace the backend's in-memory document with no knowledge of unsaved edits. | A dirty flag (set by a part move or solve, a design-table edit, hide / show, a new part, a mate, a colour, adding a component; cleared by save and load) makes Open, import and New assembly warn first ("save first, or do it again within a few seconds to discard"); the Files page says what is unsaved. | Closed. |
| G2 | VR shared the backend's `"default"` session with the flat app: a VR import / New assembly replaced what the flat app had open. | VR sends its own `X-Document-Session` (random per launch, or fixed in `secrets.cfg`), through one header helper every call uses; work moves between the apps by file. | Closed. **A change in how the two apps share a backend: confirm it suits you.** |
| G3 | The Save location on a Quest was assumed to be writable and visible. | Saves report the real folder, and the Files page shows where saves go. | Closed. Unverified on a headset: that the folder is visible to the Files app. |

### Dependencies and file format
| ID | Gap | How it was closed | Status |
|---|---|---|---|
| G4 | Hide / Show and Roll back need DIDSA-CAD's 2026-10-03 `assembly-mesh.glb` params; an older backend silently ignored them. | The backend's OpenAPI document is read once; without the params the two buttons are off and the tree says why. | Closed. |
| G5 | VR saves the flat app's legacy **whole-session bundle** shape only, not its one-file-per-part Project shape. | Documented. | Accepted (revisit if asked). |
| G6 | Hidden feature ids were saved but stale-mate flags were not. | Saved as the VR-only extra `vr_stale_mates`, restored on open. | Closed. |

### Editing
| ID | Gap | How it was closed | Status |
|---|---|---|---|
| G7 | An existing sketch could not be reopened. | Build tree > a sketch row > **Edit** reopens it (entities and origin read, nothing made); **Done** rebuilds the part so what is built on it follows. Against the real backend a dimension change reached the extrude and fillet. A sketch the flat app **flipped or turned** is refused. | Closed (with that exception). |
| G8 | Only 6 sketch tools, 6 constraints, Extrude / Fillet / Chamfer; no preview, no redo. | **Revolve, Shell and Mirror** and the **Slot** sketch tool added (against the real backend), the rest of the constraints are in Select's menu. Not built: Sweep, Loft, Pattern, booleans, direct edit, Ellipse / Spline / Text / Trim / Offset, a preview before Apply, redo. | **Partly closed.** |
| G9 | Cascade delete cannot be undone. | As in the flat app; the "Sure?" step names what goes. | Accepted. |
| G10 | A normal part that loses all its geometry keeps its last mesh in the arena. | It goes blank like a new part. | Closed. |
| G11 | The Build tree has no Planes / Surfaces / Curves sections; Edit covers only extrude / fillet / chamfer. | Edit now also covers revolve angle, shell wall and (on a sketch) reopens it. Sections are not built (planes are rows in the feature list). | **Partly closed.** |
| G12 | A sketch row only lit its plane. | Edit reopens it (with G7). | Closed. |

### Assemblies and mates
| ID | Gap | How it was closed | Status |
|---|---|---|---|
| G13 | After an edit, mates whose face changed were turned off and had to be remade by hand. | The Enforce button becomes **"Remake N mate(s)"** when the face still exists under a new number: a new mate on that face, the old deleted, then a solve. Checked against the real solver. A mate with a face gone for good is still made by hand. | Closed. |
| G14 | Only top-level mates are checked and enforced (not through sub-assemblies). | | **Open.** Needs a sub-assembly to test against and the backend's nested solve behaviour. |
| G15 | A mated, enforced part cannot be carried onto the table. | Not changed: use the tree's Table button, or Relax all mates first. | **Open** (a workaround exists). |
| G16 | Sub-assemblies are refused; New part only makes a child of the root; parts cannot be renamed. | **Rename** added (Build tab). Sub-assemblies and New part inside one are not. | **Partly closed.** |

### Table handling
| ID | Gap | How it was closed | Status |
|---|---|---|---|
| G17 | A part sent back to the arena used its original orientation, not the turn it has on the table. | Tablet > Table: **Original turn / As turned**. | Closed. |
| G18 | No one-hand turn; scale clamped to 0.4-3x. | One hand turns the part with the wrist while the **left** stick is pressed (the right stick click is the world-scale pad, so the right hand has no modifier); the zoom limit is a setting (2 / 3 / 5 / 8x; a sketch always allows 8x). | Closed. Unverified: how the modifier feels. |
| G19 | The slab size was not remembered; the deck stayed 0.6 m wide whatever the slab size. | The size is saved when a corner drag ends and restored at start; the deck is as wide as the slab (0.6 to 1 m). | Closed. |

## What is left, in the order it would be worth doing

See "Open items at a glance" at the top. The order: a headset session (1) before anything is tuned (the clip depth, the flagged colours and the reference weights
among the numbers), then the backend's solver for 2 and driven constraints for 3, then 4, 5, 6 and 7.
