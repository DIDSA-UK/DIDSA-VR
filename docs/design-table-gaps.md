# Design table: known gaps and the plan to close them

What the design table (milestone 2) does not do, or does not do well, as of the first headset session. Each gap has an ID, what happens
today, and the phase that closes it (or why it is accepted). Update the **Status** column as gaps close. Testing-related gaps (the
headset has barely been used, Quest 2 is unmeasured, DIDSA-VR has no CI, the flat app's own UI has not opened a VR-saved file) are tracked
in `docs/design-table.md` ("Performance", "What isn't built") and not repeated here.

Phases: **1** quick wins from the first session, **2** the sketcher, **3** work loss and integration, **4** editing depth, **5** assemblies and
mates, **6** table handling.

## Feedback from the first headset session

| ID | What was found | Closed by | Status |
|---|---|---|---|
| N1 | Edges are not drawn on any 3D model in VR. | Phase 1: view modes **Shaded / Shaded + edges / Wireframe** (Tablet > View > Display), edges from the backend's own topology. | see Status log |
| N2a | The sketch sits flat on the table, which is awkward. | Phase 1: tilt up 60° (from the slab) on sketch start; animation checked. | see Status log |
| N2b | Points can only be dropped on a small area; no grid. | Phase 2: a large fixed-size sheet with a faint grid. | see Status log |
| N2c | The sketch origin is not a snap point; nothing can be constrained to it or dimensioned from it. | Phase 2: the backend's real origin point is read and used like any point. | see Status log |
| N2d | Sketch entities cannot be selected; no contextual menu. | Phase 2: a **Select** tool (default on sketch start) and a menu of what applies to the selection, as in the flat app's sketcher. | see Status log |
| N2e | The sketch canvas cannot be panned or zoomed. | Phase 2: one-hand grip pans, two-hand grip zooms (the sheet is rigid with the part, so this moves / scales both); sketch lock rules below. | see Status log |
| N3 | The corner handle for dragging the table bigger is hard to find (the curved edge hides it). | Phase 1: a small bright point at each corner. | see Status log |

## Gaps found while building it

### Work loss
| ID | Gap | Closed by |
|---|---|---|
| G1 | **New assembly** and STEP / STL / OBJ import replace the backend's in-memory document. Only New assembly has a (two-press) guard and nothing knows whether there are unsaved edits. | Phase 3: a dirty flag and a "Save first?" warning. |
| G2 | VR shares the backend's `"default"` session with the flat app. If both use one backend, a VR import / new assembly replaces what the flat app has open. | Phase 3: VR sends its own `X-Document-Session`; work moves between the apps by file. Changes how the two share a backend: confirm before shipping. |
| G3 | The Save location on a Quest (`user://models`) is assumed to be writable and visible to the Files tab. | Phase 3: show the real path, hint. |

### Dependencies and file format
| ID | Gap | Closed by |
|---|---|---|
| G4 | Hide / Show and Roll back need DIDSA-CAD's 2026-10-03 `assembly-mesh.glb` params; an older backend silently ignores them. | Phase 3: probe the backend's OpenAPI once and disable the buttons with a message. |
| G5 | VR saves the flat app's legacy **whole-session bundle** shape only, not its one-file-per-part Project shape. | Accepted (document); revisit if asked. |
| G6 | Hidden feature ids are saved (the flat app's `hidden_feature_ids`); stale-mate flags are not. | Phase 3: saved as an extra the flat app ignores. |

### Editing
| ID | Gap | Closed by |
|---|---|---|
| G7 | An existing sketch cannot be reopened; every plane pick starts a new sketch. | Phase 4: reopen from its Build row. |
| G8 | Only 6 sketch tools, 6 constraints, and Extrude / Fillet / Chamfer: no Revolve, Sweep, Loft, Mirror, Pattern, Modify, Inspect; no preview before Apply; no redo. | Phase 4, one feature at a time. |
| G9 | Cascade delete cannot be undone. | Accepted (as in the flat app; the "Sure?" step names what goes). |
| G10 | A normal part that loses all its geometry (cascade delete) keeps its last mesh in the arena. | Phase 4: blank it like a new part. |
| G11 | The Build tree has no Planes / Surfaces / Curves sections; Edit covers only extrude / fillet / chamfer values. | Phase 4. |
| G12 | A sketch row in the Build tree only lights its plane. | Phase 4 (with G7). |

### Assemblies and mates
| ID | Gap | Closed by |
|---|---|---|
| G13 | After an edit, mates whose face changed are turned off and must be remade by hand. | Phase 5: offer to remake on the equivalent face. |
| G14 | Only top-level mates are checked and enforced (not through sub-assemblies). | Phase 5. |
| G15 | A mated, enforced part cannot be carried onto the table (use the tree's Table button). | Phase 5. |
| G16 | Sub-assemblies are refused; New part only makes a child of the root; parts cannot be renamed. | Phase 5. |

### Table handling
| ID | Gap | Closed by |
|---|---|---|
| G17 | A part sent back to the arena uses its original orientation, not the turn it has on the table. | Phase 6: a choice. |
| G18 | No one-hand turn; scale is clamped to 0.4-3x. | Phase 6 (scale max is raised while sketching, Phase 2). |
| G19 | The slab size is not remembered; the deck stays 0.6 m wide whatever the slab size. | Phase 6. |

## Sketch mode and the grips (the rules the Phase 2 pan / zoom follows)

The sketch sheet is a child of the part's table copy, so **moving or scaling the part moves and scales the sheet**. That is why one-hand
grip = pan and two-hand spread = zoom already work on a sketch. A separate canvas zoom (content sliding over a fixed part) was rejected:
the sketch would no longer line up with the part under it (snapping to part vertices, sketching on a face, extruding to the part's shape).
While a sketch is open:

1. The pose is **locked to the tilt**: two hands scale and move only (no turn), the stick does not spin or tip, Reset restores. A deck toggle
   **Part: Locked / Free** unlocks turning.
2. Letting go beyond the slab does **not** send the real part back to the arena (it would kill the sketch); the part is held over the slab.
3. A grip inside the sheet's physical rectangle takes it, not only one near the part's bounding sphere.
4. The scale limit rises to 8x while sketching.

## Status log
Closed gaps are recorded in `docs/status.md` with the commit; this table's right-hand column is updated when each closes.
