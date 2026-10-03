# The design table (milestone 2)

A floating, tilted console you summon in front of you in the arena. **One part** is edited on it: you pick a flat face or a
reference plane, sketch on it with the laser (points snap to what's already there, values are typed on the numeric pad), and add
features. The wrist tablet still owns the world (scale, view, hide, mates, environment); the table owns authoring one part.

The brief it was built from is saved as [`design-table-brief.md`](design-table-brief.md) (a brainstorm export, not live-synced).
This page is what was decided and built, what the code turned out to say, and what is not here yet. Status log:
`docs/status.md`, "2026-10-03 — Milestone 2".

## Using it

1. **Summon it:** wrist tablet → **Assembly → Table → Summon table**. It appears in front of you, below eye level, leaning back like
   a drafting table. "Bring it to me" recalls it; the **X** on the deck (or Dismiss on the tablet) puts it away.
2. **Put a part on it**, either way:
   * **carry** a part (grip) over the slab and let go — the part in the arena stays where it was, hidden, and a copy appears on
     the table, scaled to fit and floating above the slab; or
   * in the **tree** at the table's left, press **Table** on a part's row (no carrying). **Bring** on a row moves that part to a
     spot in front of you instead (an ordinary, undoable move).
   A part that is mated and has its mates enforced is steered by a live solve while you carry it, so **Relax all mates first**, or
   use the tree.
3. **Pick a sketch plane:** aim at a flat face (it lights up) or at one of the three faint reference planes (XY blue, XZ green,
   YZ red) drawn through the part, and pull the trigger. The part turns to lie with that plane flat on the table (x to your right,
   y away from you) and a translucent **sketch sheet** appears on it. The chosen face stays lit.
4. **Sketch.** Pick a category on the deck, then a tool. The laser meets the sheet; pull the trigger to place points.
   * **Snap** (on the deck, on by default) snaps to existing points, the part's own corners on that plane, line midpoints, spots on a
     line or circle, and pulls a line within 4° of horizontal/vertical onto the axis (adding the constraint). Off: the cursor is free.
   * **Dimension:** pick a line (length), a circle or arc (radius, diameter), two points (distance, horizontal, vertical), two
     parallel lines (distance), two other lines (angle) or a point and a line. The candidates float on the sheet; **point at one
     and pull the trigger** to open the numeric pad, type, confirm. Typing over a value that already exists changes it.
   * **Constraints:** pick the line(s) / point(s) under the laser.
   * A constraint the rest of the sketch can't satisfy is taken straight back out.
5. **Add a feature** (Feature category → **Extrude**, **Fillet**, **Chamfer**; settings appear in the row under the tools):
   * **Extrude:** Boss or Cut, Flip, New body, Depth (numeric pad), then **Apply**. A boss grows out of the face you sketched on; a
     cut goes into the part.
   * **Fillet / Chamfer:** pull the trigger on edges (each pull adds or removes one; they light up), set the size, **Apply**.
   The new shape appears on the table **and on every other placed instance of that part in the arena**.
6. **Undo** (deck): takes back sketch steps first, then the features made on the table. (Undo only — like the flat sketcher, no redo.)
7. **Handle it on the table** (all of this is on the table's copy and **independent of the world**: the real part, the model and
   the arena's scale are never touched):
   * **Grip** the part (one hand) to **move** it; it follows your hand 1:1 (through the same steadiness filter as an arena part).
   * **Grip it with both hands** to **turn and scale** it: it moves with the midpoint between your hands, turns as the line between
     them swings, and grows or shrinks as you spread or close them (0.4x to 3x its fitted size). The second hand may grip anywhere
     over the table. Letting go of one hand carries on one-handed without a jump.
   * The **right stick** spins it about the slab's up axis (left/right) and tips it (up/down); **A** pulls it nearer to your hand
     and **B** pushes it farther, never off the slab or through it.
   * **Reset** (deck) puts it back in the middle of the slab at its fitted size, with the sketch plane flat (or the way it went on, before
     a plane is chosen).
   The sketch sheet, plane squares and drawing are children of the part, so they move, turn and scale with it.
   **How you know the table has the controls:** it is automatic, with no button. The table is **engaged** while a hand grips the part or
   the right laser is on the part or its sketch sheet (not on the deck). Then the slab's frame **glows brighter**, a **TABLE ACTIVE** chip
   shows on the deck, and the right hand gets a small haptic tick as it comes and goes (a quarter-second of grace so it doesn't flicker
   at the part's edge). Only while engaged do the right stick and A / B belong to the table, so they never also turn you, teleport you
   or spin a selected arena part. It is the same rule that makes the stick scroll a window while the laser is on it.
8. **Leave the table:**
   * **Let go over the slab:** it stays on the table.
   * **Carry it off the slab and let go:** the real part goes back to the arena **where you let go**, at the arena's scale and in the
     orientation it had when it went on (a normal move: undoable, saved). While you carry it past the slab the frame turns **amber**
     and the status line says letting go will send it back. A part held by enforced mates goes back where it came from instead.
   * **To arena** (deck): the real part goes back **exactly where it came from**, nothing moved.
   * Closing the table does the same as To arena.
9. **Edited parts have stale mates.** Every instance of an edited part gets a **warning badge** and stops being steered by its mates.
   When one is put down (or handed back), an **Enforce mates** button floats over it. See below.
10. **Save:** Files tab → **Save as new file** writes the whole session as a new `.didsa` the flat app can open.

## The deck

Five category slots, six tool slots, as in your sketch. Names are DIDSA-CAD's own, in the flat app's order (taken from its sketch
speed dial, constraint ribbon and feature picker); a category with more than six tools shows five and a **More** slot that pages.

| Category | Tools now | Not built yet (the flat app has them) |
|---|---|---|
| **Sketch** | Line, Rectangle, Circle, Arc, Polygon, Point | Slot, Ellipse, Ellipse Arc, Spline, Text; Trim, Offset, Convert, Pattern |
| **Constrain** | Dimension, Horizontal, Vertical, Parallel, Perpendicular, Coincident | Equal, Collinear, Concentric, Tangent, Fix |
| **Feature** | Extrude, Fillet, Chamfer | Revolve, Sweep, Loft, Plane, Shell, Mirror, Pattern, Merge/Subtract/Common/Split, the surfacing and direct-edit tools |

The deck has room for two more categories (the concept art's five); **Modify** (direct edit) and **Inspect** (Measure, Section) are
the natural ones and are not built. The deck is data (`table_tools.gd`), so adding a tool is one registration plus its behaviour.
There is no AI category: the repo has no hook for it.

## What the code said about the brief

| Brief question | Answer |
|---|---|
| **1. Mate / dirty logic — reusable?** | There was **no dirty flag anywhere** (VR, Flutter, backend). The backend stores a mate's face as an *index* into the part's current shape and re-resolves it only when it solves. So the dirty logic is new, client-side (`dirty_mates.gd`), and it needed a second thing the brief didn't foresee: see "Stale mates" below. Enforcing reuses the existing per-occurrence solve (`mates_tool.enforce_all`; the backend has no bulk endpoint). |
| **2. Typed dimensions** | `main.open_keyboard_for(initial, callback, {title})` — the numeric pad returns a raw `String`; the caller parses and validates. The table accepts only plain numbers, rejects zero and below, pre-fills with `"%.2f"` of the current value (mm; degrees for angles), as the flat app does. |
| **3. Native files** | VR could read them and **could not write them**. It can now (`save_native_snapshot`). Two traps found on the way: the backend drops the flat app's `hidden_feature_ids` / `section_planes` (kept and written back), and Godot reads every JSON number as a float, so re-serialising a file writes `rotation_quarter_turns: 0.0`, which the backend then crashes on (also fixed in Open and Add, see below). |
| **4. Where does edit state live?** | The backend is **not stateless**: it holds an in-memory document and sketch store per session (`"default"` for VR), and edits take effect there immediately; only *files* are client-owned. A part's source of truth is its backend definition. Every instance shares it, so one edit changes every placed copy. A node's `owner_part_id` is the *assembly holding the occurrence*, not the part (the glb doesn't name the part), so the table looks the part up through the owner's occurrences. |
| **5. Quest 2 limits** | **Nothing about Quest 2 is recorded anywhere, and it still isn't measured.** See "Performance". |
| **6. Real tool names; more than six** | The table above. Paging via `tool_pager.gd`. |

## How it works

| Piece | Where | What it does |
|---|---|---|
| Console | `design_table.gd` | Slab, deck, handle, theme, seating, sending the part back, Reset, the Enforce plumbing. Joins the `design_tables` and `diegetic_panels` groups so `controller.gd` asks it about seating, gripping the part and its handle. |
| Handling the part | `table_manip.gd`, `table_pose.gd` | Grips (one hand moves, two turn and scale), the right stick and A / B, the "engaged" rule and its tell. `table_pose.gd` is pure maths in the console's own frame (two-hand step, stick turn, nudge, clamps) so it is unit-tested. Gripping sets a `table_part_held` meta on the hand, which `two_hand_model.gd` reads so the grip doesn't also drag the world; `controller.gd` hands the table its grips first (`_try_grab_table`, `_try_release`) and asks it who owns the stick (`is_manipulating`). |
| Deck UI | `table_ui.gd` | Category row, paged tool row, an options row, status line with the TABLE ACTIVE chip, Snap / Reset / To arena / Undo / Close. Pure 2D `Control`s in the shared theme (`ButtonRail`, per-category accent, `FxOverlay`), so it also runs in a plain window. |
| Tool data | `table_tools.gd`, `tool_pager.gd` | Uses the wrist tablet's own `TabletRegistry` + `ToolManager`: one active tool across categories. |
| Editing session | `table_editor.gd` | The state machine (pick plane → sketch → features), the laser hover and the shared `ui_hover` claim, tool routing, the options row, applying features, refreshing geometry, undo. |
| Sketch logic | `sketch_session.gd` | No scene: the backend sketch, the local copy of it, each tool's calls, selection, dimension candidates, undo. Takes an `api` Callable, so tests give it a fake. |
| Sketch drawing | `sketch_view.gd`, `plane_markers.gd` | The sheet, entities as constant-width ribbons (bright core over a dark edge so they read on a white part and on the slab), cursor, rubber band, dimension labels; the three plane squares. Built only when the sketch changes. |
| Snapping | `snap_resolver.gd` | Pure. |
| Plane maths | `sketch_math.gd`, `table_seat.gd` | Pure: fixed-plane bases (XZ's x is −X, as the backend), turning any plane flat on the table, ray→sheet, fit scale. |
| Backend line | `cad_api.gd`, `part_features.gd` | A serial HTTP queue (one request in flight, in order) and thin Extrude / Fillet / Chamfer / delete calls. |
| Stale mates | `dirty_mates.gd`, `mate_health.gd`, `enforce_button.gd` | See below. |
| Tree | `table_tree_window.gd` | The existing Assembly Tree window docked at the slab, with Table and Bring on each row. |
| Shared picking | `scripts/laser_pick.gd` | The ray loop and "what would a pick take here", now used by `controller.gd` (select, hide, Mates, Measure) and the table. |

**A copy, not a reparent.** The arena's parts sit under a scaled root (`assembly_root`) whose frame the mates tool, pose saving, hide
and section all assume. Rescaling or reparenting a node onto the table would break all of them. So putting a part on the table hides the
arena node (untouched) and shows a scaled **copy** (own collider on a private physics layer, not in `grabbable_parts`, so no arena tool
ever sees it). The copy is what you edit; the real node comes back when the part leaves the table. The user's own scale lives on the copy's **pivot**
(not the copy), so the sketch sheet, plane squares and drawing, which are children of the copy, follow it; the snap, pick and label
radii use `effective_scale()` (fitted scale x the user's scale). Hide-all / show-all / reverse / isolate skip the node that's
on the table.

**One request at a time.** The backend's single in-memory document races under overlapping calls and a sketch's calls build on each
other (a point must exist before the line that uses it), so every call waits its turn.

**The backend call sequence** (all existing endpoints), for a sketch on a face then an extrude:

```
GET  parts/{owner}/occurrences                      -> which part is this node? (and: refuse an assembly)
POST parts/{part}/create-plane-features             offset_face on the picked face   (a reference plane needs none)
POST parts/{part}/features/sketch                   {plane_feature_id} | {plane:"XY"}
POST sketch/sketches/{s}/points|lines|rectangles|circles|arcs|polygons
POST sketch/sketches/{s}/constraints                distance (typed value), horizontal, parallel, ...
PATCH sketch/sketches/{s}/constraints/{c}           {value}   (an existing dimension, or a circle's provisional radius)
POST sketch/sketches/{s}/solve-and-refresh          after every change; the solved points are the truth
GET  sketch/sketches/{s}/export                     when entities changed
POST parts/{part}/extrude-features                  boss/cut, start/end distance along the face normal, target bodies
GET  parts/{part}/assembly-mesh.glb                 the new shape, put on the table copy AND every arena instance
```

## Stale mates (the part the brief didn't see coming)

A mate names its faces by **index** into the part's current shape. After an edit the indices are renumbered, and nothing tells you.
A real run against the real solver: a plate stacked on another by a coincident mate; a boss added to the mated top face turned
"face 5, the top" into "face 5, the +X side" and "face 4, the bottom" into the −X side. **Enforce mates reported success and did
nothing**, because it had quietly joined two side faces. (A fillet on a vertical edge renumbered them too.) So:

1. **Flag.** After an edit, every arena instance of the part gets a warning badge and the `mates_dirty` meta. A flagged part is not
   steered by its mates and is not an anchor others are solved against (`mates_tool.gd` checks the meta), so it moves freely.
2. **Check.** `mate_health.gd` records, before the first edit, what each mate's face looks like (outward normal, offset along it),
   and after every change recomputes which mates now name a *different* face. Face **area is ignored** (a boss changes a face's area
   but not the plane a mate needs). The record is relative to the *first* sight, so **undoing the edit brings the old faces back and
   clears the warning** — confirmed against the real backend.
3. **Enforce.** The button appears over a flagged part when it's put down (or handed back when the table closes). It **suppresses**
   (not deletes) every mate whose face changed — `PATCH …/mates/{id} {suppressed: true}`, reversible and saved in the file — then
   re-solves the rest, clears the flags only if everything could be met, and says on the button what it turned off ("Remake them from
   Assembly > Mates"). A failed solve keeps the flags and says why.

Limits: the flags live on the nodes, so a reload forgets them (a reload re-reads the mates fresh, but a mate that already names the
wrong face stays wrong — which is why the suppression, being saved, matters). Only the top-level assembly's mates are checked and
enforced (`enforce_all` works on the root). Non-planar faces are compared loosely (kind, centroid, area).

## Saving

Files tab → **Save as new file**: `GET /document/export/native` (the whole session) written next to the Settings project folder, or
`user://models`, under `<opened file>-vr-<time>.didsa` — never over the file you opened. It is the flat app's **bundle** shape, which
it opens directly (`isBundleShapedNativeFile`). The backend's text is written **as it came** (with the flat app's own extra keys
appended), because Godot would turn every integer into a float. Not done: per-part project files with `external_ref` paths stamped
(the flat app's Save All) — a multi-file project saves as one bundle.

**Open and Add used to re-serialise the parsed file** (`JSON.stringify(parsed)`), writing integers as floats. For a file with sketches
that made the backend crash when it rendered the assembly. They now send the file's own text. (Found because the first thing a user
does with a saved snapshot is open it.)

## Performance

Measured, not guessed — with the limits of what a cloud sandbox can measure (`tests/design_table_perf.gd`; **script time only, no GPU,
no headset, nothing from Quest 2**). The repo's one on-device figure is that a Quest 3 runs GDScript about 2.5–3.7× slower than a desktop
(`docs/local-retraction-benchmark.md`), against its rule of ≤ 1.5 ms p95 of added script work per frame.

| What | Desktop | At Quest 3 ×3.7 |
|---|---|---|
| Table + editor per frame, part on the table, laser on it (a physics ray) | ~0.06 ms | ~0.2 ms |
| ...with the laser on a **150-entity** sketch (snap search over 300 points / 150 lines is ~0.1 ms of it) | ~0.13–0.17 ms | ~0.5–0.6 ms |
| Rebuilding the drawing of that 150-entity sketch (only when the sketch **changes**) | ~5.5 ms | ~20 ms (a two-frame hitch) |

A typical sketch is a few dozen entities (well under 1 ms to rebuild). The rebuild is the obvious thing to optimise if a big sketch
hitches on a headset.

Rendering cost is **unmeasured**. What the table adds: about 30 mesh nodes, **two SubViewports** while open (the deck 1600×400, the tree
446×583), plus the Enforce button's 533×240 while shown. The deck re-renders every frame only while the laser is on it or something
changed in the last second, otherwise a few times a second (the tablet's rule); the tree renders every frame while open like the other
windows. The table copy has its own trimesh collider (the same cost as an arena part, once). Quest 2 specifically (a geometry budget for
the part / tree / sketch overlay) would need a device; the levers if it's tight are the tree's SubViewport, the ribbons' triangle count
and the glb `quality` the table fetches (0.5).

## Not built / known gaps

* The tool list above (Revolve, the rest of Sketch / Constrain / Feature, Modify, Inspect, AI).
* **Editing an existing sketch**, or showing the part's existing sketches: v1 starts a new sketch on each pick. The tree's feature mode
  (origin planes, plane features, sketches) is not built; the tree shows the assembly.
* **Dragging a row out of the tree** onto the table or into the world: the laser freezes the pointer while the trigger is held
  (`laser_surface.gd`), so a drag would need its own gesture. Rows have buttons instead.
* **Sub-assemblies:** the table edits one *part*. An assembly of other parts is refused with a message.
* **Persisted dirty flags**, and a bulk "enforce" or mate-health endpoint on the backend (DIDSA-CAD roadmap's reference-drift idea). The
  client-side check above covers planar faces well and others loosely.
* **A feature preview** before Apply, and editing a feature's values afterwards (only Undo).
* **Not handled on the table yet:** turning with a single hand's wrist (deliberately two-handed, like the world's one-hand drag), rolling about the line between two hands (the stick spins about the slab instead), and snapping a turned part back to the nearest face. Where the **engaged** threshold sits (the laser has to pass within 1.4 x the part's bounding sphere, or be on the sheet), the 90 deg/s stick rate and the A / B speed are guesses until someone tries them.
* **On a headset:** nothing here has been seen in a headset. The laser, the grips and the layout are tested with simulated
  controllers and rendered once in software; the feel (deck size, tilt, snap radius, ghost label hit radius) needs a session with a
  real controller.
* The multiplayer, Bluetooth pen, other headsets, environments, app windows and network storage items from the brief remain out of scope.

## Testing

Headless, in `tests/run_all.sh`: `design_table_logic` (pager, registry, plane maths, snapping, seat numbers, the pose maths), `design_table_scene`
(summon, deck clicks, seat, move / two-hand turn and scale / stick / A-B / engaged tell / Reset, send back to the arena, To arena, close, handle), `sketch_session` (the sketch calls against a fake backend,
`tests/helpers/fake_cad.gd`), `design_table_editing` (the real laser end to end), `design_table_tree`, `design_table_mates`,
`design_table_save`, `mate_health`. Local only (a running backend, `secrets.cfg`): **`e2e_design_table`** (a plate built through the
session, placed twice, edited on the table, saved, reopened) and **`e2e_design_table_mates`** (the real solver). Rendering and timing:
`design_table_render`, `design_table_perf`. See `tests/README.md` for what each line should say, and `docs/status.md` "How this has been
worked on" for standing up a throwaway backend.
