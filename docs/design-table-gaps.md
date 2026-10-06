# Design table: known gaps and what became of them

What the design table (milestone 2) did not do, or did not do well, as of the first headset session, and where each stands now. Each gap has an
ID, what was wrong, how it was closed (or why it is accepted), and its **status**. Testing-related gaps (the headset has barely been used, Quest 2
is unmeasured, DIDSA-VR has no CI, the flat app's own UI has not opened a VR-saved file) are tracked in `docs/design-table.md` ("Performance",
"Not built / known gaps") and not repeated here.

**Everything marked Closed is closed in code and tests (headless, and against a real backend where it touches one). None of it has been seen in a
headset**, so numbers that depend on feel (the 60 degree tilt, the sheet size, line weight, grip pan / zoom, the one-hand turn) are called out below.

## Open items at a glance (read this first)

Everything else in this file is history and detail. This is the one list of what is still open, as of 2026-10-06. Items marked **backend** live in DIDSA-CAD.

| # | Open item | Where | Detail |
|---|---|---|---|
| 1 | **References silently rebind** when an upstream edit changes the part's topology (5 of 7 probes; `has_lost_reference` stays false). Needs a geometric signature, then OCCT `Modified()` / `Generated()` history, and a flag instead of a silent rebind. | **backend** (+ both clients show the flag) | R2 below; `DIDSA-CAD/docs/roadmap.md` "Reference drift"; `DIDSA-CAD/backend/tests/test_reference_follows_upstream_topology_change.py` (xfail = the wanted behaviour) |
| 2 | **The flat app's referencing flow is the old, explicit one** (Dimension mode ghost picks, a separate Convert mode). Make it implicit like the VR table: aim at a part corner or edge in any tool and the reference is made on demand. | flat app (`client/lib/sketch`) | `docs/handover-references-overhaul.md` |
| 3 | **The part is not clipped to the sketch window**: zoomed right in (up to 200x) it fills the room. | VR | N2e / "Sketch mode and the grips" item 6 |
| 4 | References **not yet** for: circular edges (a hole's centre / radius), an edge's midpoint or along it, faces; a driven (reference) dimension between two pinned things; sketches on a part with something hidden or rolled back, or a reopened sketch that is not the last feature. | VR (some need the backend: arcs come from `convert-entities/edge`) | R1 below |
| 5 | **Nothing has been seen in a headset**: the 60 degree tilt, window size and zoom range, grip pan / zoom feel, reference line weight and colours (`REF_*` in `sketch_view.gd`), line / text weights, edge weight, the Quest save folder. | VR | "Everything marked Closed" note above |
| 6 | Sub-assemblies: mates through them (G14), New part inside one (G16), carrying a mated part (G15, a workaround exists). | VR (+ backend nested solve) | the tables below |
| 7 | Modelling depth (G8): Pattern, Sweep, Loft, booleans, direct edit; sketch tools Ellipse, Spline, Text, Point, Trim, Offset; a preview before Apply; redo. Build tree sections for Planes / Surfaces / Curves (G11). | VR | the tables below |

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
6. Labels show while their middle is inside the window. **Not done:** the part's own mesh is not clipped to the window (zoomed right in it fills the room).

### Dimensioning to the part's own geometry (R1) and how far references can be trusted (R2)

**R1, closed (first cut).** Dimensioning to existing edges and corners used to be missing (only the corners of the face you sketched on snapped, to a free point
with no link). Now the part's vertices and straight edges, projected onto the sketch plane, are references everywhere (`part_references.gd`): snap, pick and
dimension go straight to them, and the session makes the pinned point / construction line on demand (`convert-entities/vertex`, idempotent; an edge is the two
points and a construction line, reused if already there). Still open: circular edges (a hole's centre / radius), midpoint and along-edge snaps, faces, a driven
(reference) dimension between two pinned things, and sketches on a part with something hidden or rolled back.

**R2, a known limit of the backend (found by experiment, not yet fixed).** A reference is `body_id` + a raw OCCT vertex index, resolved when the sketch is
solved. Edits that keep the part's topology (a changed extrude depth, base-sketch dimensions, a fillet radius) are followed correctly, with no flag. An upstream
edit that changes the topology (moving which edge a fillet rounds, adding one) renumbers the vertices, and the reference then **silently binds to a different
corner**: in the probe 5 of 7 such edits did, with `has_lost_reference` false. The fix is a geometric signature stored with each reference and checked on every
refresh (and, better, OCCT's `Modified()` / `Generated()` history), so a renumbered vertex is found again by where it was and a reference that cannot be found
is flagged, never rebound. That is in the DIDSA-CAD backend and is recorded in its roadmap ("Reference drift"); it has not been started here.

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

See "Open items at a glance" at the top. The order: 1 (backend references), 2 (flat app flow), 3 (clip the part), 4 (more reference kinds), then a headset session
(5) before anything is tuned, then 6 and 7.
