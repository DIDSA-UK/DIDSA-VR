# Design table: known gaps and what became of them

What the design table (milestone 2) did not do, or did not do well, as of the first headset session, and where each stands now. Each gap has an
ID, what was wrong, how it was closed (or why it is accepted), and its **status**. Testing-related gaps (the headset has barely been used, Quest 2
is unmeasured, DIDSA-VR has no CI, the flat app's own UI has not opened a VR-saved file) are tracked in `docs/design-table.md` ("Performance",
"Not built / known gaps") and not repeated here.

**Everything marked Closed is closed in code and tests (headless, and against a real backend where it touches one). None of it has been seen in a
headset**, so numbers that depend on feel (the 60 degree tilt, the sheet size, line weight, grip pan / zoom, the one-hand turn) are called out below.

## Feedback from the first headset session

| ID | What was found | How it was closed | Status |
|---|---|---|---|
| N1 | Edges are not drawn on any 3D model in VR. | View modes **Shaded / Shaded + edges / Wireframe** (Tablet > View > Display), edges from the backend's own B-rep topology (a sharp-angle fallback for bare models), saved setting. See `docs/design-table.md` "View modes". | Closed. Unverified: one-pixel lines may be faint on a Quest (fallback: ribbons). |
| N2a | The sketch sits flat on the table, which is awkward. | The sketch plane stands up **60 degrees from the slab** on sketch start (animated; instant with Reduce motion), the part floats a little higher so the sheet clears the slab; Reset and Fit restore it. | Closed. **Assumption to check on a headset:** "60 degrees" is measured from the slab (the console already leans 22 degrees, so the room sees about 82 degrees from horizontal). `sketch_tilt_degrees` is the one number to change if 60 degrees from horizontal was meant. |
| N2b | Points can only be dropped on a small area; no grid. | A fixed **0.8 x 0.4 m** sheet (`sheet_window_m`) with a faint 1-2-5 grid that re-spaces as the part is zoomed. | Closed. Unverified: the sheet size. |
| N2c | The sketch origin is not a snap point; nothing can be constrained to it or dimensioned from it. | The backend's real origin point is read when a sketch opens (it is created lazily) and used like any point: snap kind "origin", Coincident, a dimension can start or end at it. Checked against the real backend. | Closed. |
| N2d | Sketch entities cannot be selected; no contextual menu. | A **Select** tool (on by default when a sketch opens) and a menu in the options row of what applies to the selection, ported from the flat app's selection matrix, plus Fix / Construction / Delete. Every option checked against the real constraint schemas. | Closed. |
| N2e | The sketch canvas cannot be panned or zoomed. | One grip anywhere on the sheet pans, two hands zoom (to 8x), because the sheet is rigid with the part; with the sketch rules below (locked tilt, release holds the part over the slab, the whole sheet is the grab zone, Part: Locked / Free, Fit). | Closed. Unverified: how the grips feel. |
| N3 | The corner handle for dragging the table bigger is hard to find. | A small bright point on each corner of the slab's rectangle. | Closed. |

### Sketch mode and the grips (the rules the pan / zoom follows)

The sketch sheet is a child of the part's table copy, so **moving or scaling the part moves and scales the sheet**. That is why one-hand grip = pan and
two-hand spread = zoom already work on a sketch. A separate canvas zoom (content sliding over a fixed part) was rejected: the sketch would no longer line
up with the part under it (snapping to part vertices, sketching on a face, extruding to the part's shape). While a sketch is open:

1. The pose is **locked to the tilt**: two hands scale and move only (no turn), the stick does not spin or tip, Reset restores. **Part: Locked / Free**
   on the deck unlocks turning.
2. Letting go beyond the slab does **not** send the real part back to the arena (that would end the sketch); it is held back over the slab.
3. A grip inside the sheet's physical rectangle takes it, not only one near the part's bounding sphere.
4. The scale limit rises to 8x while sketching (the Settings limit is for everyday handling).

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

1. **A headset session** to check everything marked unverified above (the 60 degree reading, the sheet, grips, edge weight, the save folder).
2. G14 / G16 sub-assemblies (needs a nested assembly to build against).
3. G8's remainder: Pattern, then Sweep / Loft / booleans / direct edit, more sketch tools, a preview before Apply, redo.
4. G11's Planes / Surfaces / Curves sections; G15 carrying a mated part.
