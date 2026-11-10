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
2. **Put a part on it**, any of three ways:
   * **New part** (the **+** in the tree window's header, or the tablet's Table page): an empty part, named Part 1, Part 2..., appears on
     the table. Nothing is drawn yet, so the only things to pick are the three reference planes; pick one, sketch, extrude. The part is
     placed on the assembly (to your right and a little further off) the moment it is made, so when it comes off the table it is
     where it will stay. If the table already holds a part, that one goes back where it came from first; if no assembly is loaded,
     an empty one is started first. A part that never got a feature is **discarded** (its placement is removed) when it leaves the table or
     the table closes, rather than left as an invisible empty part. Taking its first feature back (Undo) turns it blank again.
   * **carry** a part (grip) over the slab and let go — the part in the arena stays where it was, hidden, and a copy appears on
     the table, scaled to fit and floating above the slab; or
   * in the **tree** at the table's left, press **Table** on a part's row (no carrying). **Bring** on a row moves that part to a
     spot in front of you instead (an ordinary, undoable move).
   A part that is mated and has its mates enforced is steered by a live solve while you carry it, so **Relax all mates first**, or
   use the tree.
3. **Pick a sketch plane:** aim at a flat face (it lights up) or at one of the three faint reference planes (XY blue, XZ green,
   YZ red) drawn through the part, and pull the trigger. The part turns to stand that plane up **60 degrees from the slab** (x to your right, y
   away and up; the console already leans back 22 degrees, so in the room the sheet is nearly upright: `sketch_tilt_degrees` on the table
   is the one number to change if 60 degrees from horizontal was meant), floats a little higher so the sheet's lower edge clears the slab,
   and a translucent **sketch sheet** appears on it. The chosen face stays lit. The turn is a short tween (instant with Reduce motion).
4. **Sketch.** A sketch opens with **Select** already on (see below); pick a category on the deck, then a tool to draw. The laser meets the
   sheet; pull the trigger to place points. The **sheet** is a fixed window in the world, **0.8 x 0.4 m** (`sheet_window_m`) however big the
   part is, with a faint **grid** (1-2-5 mm lines about 16 mm apart on screen, re-spaced as you zoom; the red u axis and green v axis through
   the origin; faded at the edge). The window is fixed in the world; the part and its sketch slide and scale together **under** it (**one grip slides the part, two hands zoom it**, below), so the part's edges and corners always line up with the sketch, and the same part can take a huge sketch or a tiny one. A line in the window's corner gives the grid spacing.
   * **The part's own corners, edges and holes are references.** Under the sketch the part's vertices and edges are drawn quietly, projected onto the
     sketch plane (a box seen from above is its 4 corners and 4 edges; where several land on one spot the one nearest the plane wins). Aim any tool near a
     **corner** and the cursor snaps to it; start a line, a circle or a corner there and it is a pinned point that follows the part. Aim Select, Dimension or a
     constraint tool at a **corner or a straight edge** and it is picked: it becomes a pinned point (or a pinned construction line between two) in the same
     tap, and a dimension to it is offered like any other: pick the edge, then your own point, point at the value, type it. There is no Convert, Fix or Make
     construction step first. More of what you can aim at (all only when the sketch may use the part's geometry):
       * **A hole or boss** (a circular edge lying in the sketch plane, or an arc of one such as a fillet's): snap to its **centre** (the cursor says "centre") and a
         pinned construction circle is made on the rim, its centre a live reference that follows the hole; the shape you are drawing starts on it. Aim Dimension at
         the **rim** to pick the circle: radius and diameter.
       * **The middle of an edge** ("edge_midpoint") and **somewhere along an edge or a rim** ("edge_point"): the edge becomes a pinned line, and a new point is made
         on it and held there by an at-midpoint / point-on-line constraint, so what you draw from it stays on the part's edge. (Next to a hole converted this way
         the at-midpoint used to be refused by the solver; fixed in the backend 2026-10-08, it is held. If the solver ever refuses one it is still taken straight
         back out with a message.)
       * **A face** (2026-10-08): a **blind hole** seen from its far side has no rim in the sketch plane, so its wall is the reference: snap near the hole's axis
         (the cursor says "face_axis") and a live centre is made (the backend's `convert-entities/face`: a `circle_centre` reference of one of the wall's circular
         edges, so it follows the hole and is flagged when the hole is gone). A flat face standing square to the sketch is a pinned line between its two extreme
         corners; it is offered only where no straight edge of the part is under the laser. Cones, spheres, ellipses and silhouette lines are not offered.
       * **A driven dimension.** Two things that are both pinned (two corners, an edge, a hole's circle, the origin) cannot be driven by a dimension, so pointing
         Dimension at them offers a **reference dimension** instead (label in brackets): point at it and it is kept as `(12.5)` in a quiet colour; it measures live
         and changes nothing. The backend stores it (a persistent **reference dimension**: kind and the entities measured, the value calculated on read, never seen by the solver), so it
         survives closing and reopening the sketch, saving and opening the file, and shows in the flat app; the value follows the part when the part is edited. Undo deletes it.
     The backend keeps each reference tied to its vertex or hole and says when it cannot find it again after an upstream edit (below). The references are the part as
     the backend resolves the sketch against it, which is the part at the sketch's place in the history: for a reopened sketch with features after it, or a part
     with something hidden or rolled back, the part is fetched again that way and only its topology is used (the picture on the table is unchanged).
     **Silent.** Everything the session makes to point at the part (a corner, an edge, a rim, a face) is flagged a **reference helper** by the backend
     (`reference: true` on the convert routes; `reference_ids` / `is_reference`). It is drawn only in the quiet reference blue (`REF_USED_COLOUR`, thin, no dots),
     is never offered by Select or the constraint tools and cannot be deleted, so a dimension feels attached to the part's own edge, corner or hole. When the last
     dimension or constraint on a helper goes (or the real line that stood on it), the backend removes it, so nothing orphaned is left; Undo of the thing that made it
     leaves nothing, and the same pick afterwards makes it afresh.
   * **Lost and moved references.** When the part is edited upstream of a sketch the backend re-finds each pinned corner or hole by signature and history. A reference it
     cannot find again is **lost**, one it found on weaker evidence **may have moved**; it never rebinds silently. The sketch's **Build row** carries the note (`lost
     reference`, `1 lost, 1 may have moved`; fillets and other features too), the status line names it, and when the sketch is open the flagged points are marked red
     (lost) or amber (may have moved) with a warning line. With nothing picked, **Select's options row offers Fix** and **Keep moved ones**: Fix walks the flagged points,
     lost first: point at the corner of the part (or the hole's centre) it should follow and pull the trigger; the point is re-attached and keeps everything built on it.
     Then Done rebuilds the part.
   * **The part is clipped to the sketch window** while a sketch is open (`sketch_clip.gd`): the part's copy, its edge lines and its overlays are cut to a box, the
     window's rectangle in the sketch plane and `SketchClip.DEPTH_M` (25 cm) either side of it, so zooming in to 200x does not fill the room. It is the section tool's
     shader and global-uniform scheme (`shaders/clip_common.gdshaderinc`) with a per-material switch, so the arena's parts are never clipped; colours, view modes and
     overlays work as before.
   * **The origin** is the backend's real origin point (read when the sketch opens; the backend makes it lazily). It is drawn as a bigger
     yellow marker and **snaps** like any point (kind "origin"): a line can start on it, a circle can be centred on it, a point can be made
     coincident to it, and a dimension can start or end at it. It can be selected and constrained but never deleted.
   * **How it is drawn** (`sketch_view.gd`, `dimension_layout.gd`), like an engineering drawing: the sketch's own geometry is a **heavy solid object line**; **construction
     lines** (a polygon's centre-to-corner lines, a rectangle's diagonals, a slot's centre line, anything made construction) are **thin and in a chain pattern** (long dash,
     gap, dot, gap); every circle has a **centre mark** (chain lines crossing at its centre); a typed **dimension** is drawn with **extension lines** (a small gap off the
     geometry, a little overshoot past the dimension line), a thin **dimension line** standing off the geometry on the side with room (outside the shape, not through other
     lines), **filled arrowheads** (outside, pointing in, when the dimension is too short to hold them), and its value written along the line, upright, **in the sketch plane**
     (not a sign turned to face you): 80 and 100 for a width and a height, a leader with **R25** for a radius, a line through the centre with the diameter sign for a diameter,
     an arc with arrowheads and **45 degrees** for an angle. The candidates offered for what you have selected are drawn the same way in yellow; point at the value to type it.
     A polygon's own corner angles and a circle's own structural constraints are not drawn as dimensions. `tests/sketch_style_render.gd` renders it to a PNG for a look.
   * **Select** (first slot of the Sketch row, on by default): pull on a point, line, circle or arc to select it (a point beats a line it is
     on); pull on a selected one's label area or empty sheet to let go (empty clears everything). Any number can be selected. **Two points on top of each other** cannot be told apart
     by sight: the status line says "2 points here", and a pull on a point that is already selected with another unselected one within a quarter of the pick radius of it picks that
     one, so pulling twice takes both. The **options
     row shows a menu of what applies**, ported from the flat app's selection matrix (`sketch_selection.gd`): one line: its Length (a
     dimension: the number pad opens), Horizontal, Vertical; a circle or arc: Radius, Diameter; two points: Coincident, **Merge**, Distance, Horizontal,
     Vertical; three or more points: **Merge**; a point and a line: On line, Midpoint, Distance; a point and a circle: On curve; two lines: Parallel, Perpendicular, Equal,
     Collinear, Distance or Angle; three or more lines: Equal, Collinear; two or more circles / arcs: Concentric, Equal radius (two arcs
     sharing an end: Tangent); a line and a circle: Tangent; anything: **Fix**, **Construction / Solid** (lines, circles, arcs), **Delete**
     (not the origin; not undoable, as in the flat app) and **Clear**. A menu longer than the six-button row shows five and **More**.
   * **Merge** (two or more points; not the origin, a circle's or ellipse's quadrant point, or two points of one shape) makes them ONE point, so one thing to drag, select and
     dimension instead of two and a constraint (`POST /sketch/sketches/{id}/points/merge`, see `backend-api-notes.md`). The point that stays is shown by a cyan ring and named
     on the status line before you press it: a pinned point, else the one with the most constraints (a rectangle corner over a loose line end), else the first picked; the others
     move onto it. The backend refuses what it cannot do in its own words (two points of one line, a dimension between them, a part feature using one...). Undo restores the
     whole sketch in place (`PUT .../state`, one step). Not built: Close gaps (merge every pair of points closer than the snap radius in one go).
   * **Slot:** pick the two end centres, then a third point; its distance from the line between them is the slot's half width.
   * **Snap** (on the deck, on by default) snaps to existing points, the part's own corners on that plane, line midpoints, and spots on a line, circle or arc
     (`snap_resolver.gd`; the reach is a size in the world, 12 mm, so it shrinks in sketch units as you zoom in). Off: the cursor is free, and Infer is off with it.
     What a snap makes (as in the flat app): a snap on the **origin** gives the shape a point of its own exactly on it, held by a coincident constraint (never the
     origin point itself); on a sketch line's **middle** a point held by an at-midpoint constraint (a point already there is reused); on a **line, circle or arc** a
     point held by point-on-line / point-on-circle. A line that ends on the first point of its run **closes** it: the run ends ("Closed.") and the next pull starts a new one.
     The end of a line is decided **where the ghost draws it**: a point near the raw aim wins (the run's first point before any other); otherwise the axis-snapped end is tested
     against the points again; a closing side still gets horizontal / vertical.
   * **Infer** (on the deck beside Snap, on by default, sticky for the table session: it stays as set across tools until switched back; a broken link when off, and the status
     line says "Infer off: nothing is added automatically"). On, the sketcher adds the relationship it infers while a line is drawn, in this order after a point, the part and a
     midpoint: **tangent** to a circle or arc (within 6 degrees), a **point on** a line, circle or arc (15 mm reach), the line's own **horizontal / vertical** (4 degrees),
     **collinear** with a line that leaves the start, **parallel / perpendicular** (4 degrees) to the segment the run is continuing or to a **woken** line: one of the last three
     lines the laser passed over in the last 5 seconds (lit faintly). Unlike the flat app, parallel / perpendicular are NOT tested against every line of the sketch (a laser
     shakes). The cursor shows the glyph (H, //, |_, co, T, on) where it applies, the line it is held to is lit, and the constraint is made after the line; if the solver will
     not take it only that constraint is taken back ("Couldn't keep it parallel: it conflicted.") and the line stays. A circle or arc **centre** placed 12 to 15 mm from another's
     centre is put on it and held **concentric**. **Alignment guides** (no constraint): a point placed within 6 mm of another point's x or y is pulled to it with a dashed green
     guide (sketch points and the origin; not circle / ellipse quadrant points, helpers or the line's own start; never on a tap that only measures). Off: none of this; the
     snaps stay but are position only (a plain point), and the part's edges snap by position only.
     The tolerances (6 degrees, 4 degrees, 15 mm, 6 mm) are first guesses, as is how the woken lines and guides look: not judged on a headset.
   * **Dimension:** pick a line (length), a circle or arc (radius, diameter), two points (distance, horizontal, vertical), two
     parallel lines (distance), two other lines (angle) or a point and a line. The candidates float on the sheet; **point at one
     and pull the trigger** to open the numeric pad, type, confirm. Typing over a value that already exists changes it.
   * **Constraints:** pick the line(s) / point(s) under the laser (or use Select and its menu).
   * A constraint the rest of the sketch can't satisfy is taken straight back out.
5. **Add a feature** (Feature category → **Extrude**, **Revolve**, **Fillet**, **Chamfer**, **Shell**, **Mirror**; settings appear in the row under the tools):
   * **Extrude:** Boss or Cut, Flip, New body, Depth (numeric pad), then **Apply**. A boss grows out of the face you sketched on; a
     cut goes into the part.
   * **Revolve:** draw a closed shape and a line to spin it about; press **Axis** and pull the trigger on that line (it lights), set Boss or Cut and
     the **Angle** (up to 360), **Apply**. The sketch stays live while you choose the axis.
   * **Fillet / Chamfer:** pull the trigger on edges (each pull adds or removes one; they light up), set the size, **Apply**.
   * **Shell:** pull the trigger on the faces to open (they light; faces of one body), set the **Wall** thickness and **Inward** or **Outward**, **Apply**.
   * **Mirror:** aim at a reference plane or a flat face and pull the trigger: every body of the part is reflected across it (**Fuse into one**
     joins them; the default keeps them separate). There is no Apply; it is one pull, taken back by Undo.
   The new shape appears on the table **and on every other placed instance of that part in the arena**.
   * **Done** (deck) leaves the open sketch. If it was changed the part is rebuilt from it (everything built on the sketch follows) and the part's
     mates are flagged like any edit; an untouched sketch just closes. A sketch is also spent by an Extrude, as before.
6. **Undo** (deck): takes back sketch steps first, then the features made on the table. (Features and Build-tree edits also have Redo; sketch steps do not, like the flat sketcher.)
7. **Handle it on the table** (all of this is on the table's copy and **independent of the world**: the real part, the model and
   the arena's scale are never touched):
   * **Grip** the part (one hand) to **move** it; it follows your hand 1:1 (through the same steadiness filter as an arena part).
   * **Grip it with both hands** to **turn and scale** it: it moves with the midpoint between your hands, turns as the line between
     them swings, and grows or shrinks as you spread or close them (0.4x to 3x its fitted size, or the Settings limit 2 / 3 / 5 / 8x). The second hand may grip anywhere
     over the table. Letting go of one hand carries on one-handed without a jump.
   * **One hand can turn it too, behind a modifier:** grip with the **left** hand and press the left stick: the part turns with your wrist, about your
     hand. (The right stick click is the world-scale pad, so the right hand has no such modifier.)
   * **With a sketch open** the sketch **window** stays where it is and the grips slide the part under it (**Part: Locked** on the deck, the default): one
     hand on the sheet **slides** the part (and its sketch) along the sketch plane, two hands **zoom** it about the point between them, from 1/50 to 200x. The part
     keeps its tilt, the stick does not spin or tip it, letting go beyond the slab holds the part back over the slab (that would end the sketch), and a grip
     anywhere on the sheet, not only near the part, takes it. The drawing is clipped to the window. **Fit** slides and zooms the part so the sketch fills most
     of the window. **Part: Free** gives the grips and the stick their ordinary part handling (move, turn, scale anywhere).
   * The **right stick** spins it about the slab's up axis (left/right) and tips it (up/down); **A** pulls it nearer to your hand
     and **B** pushes it farther, never off the slab or through it.
   * **Reset** (deck) puts it back in the middle of the slab at its fitted size, with the sketch plane flat (or the way it went on, before
     a plane is chosen).
   The sketch, plane squares and drawing are children of the part, so they move, turn and scale with it (the sketch window alone stays put).
   **How you know the table has the controls:** it is automatic, with no button. The table is **engaged** while a hand grips the part or
   the right laser is on the part or its sketch sheet (not on the deck). Then the slab's frame **glows brighter**, a **TABLE ACTIVE** chip
   shows on the deck, and the right hand gets a small haptic tick as it comes and goes (a quarter-second of grace so it doesn't flicker
   at the part's edge). Only while engaged do the right stick and A / B belong to the table, so they never also turn you, teleport you
   or spin a selected arena part. It is the same rule that makes the stick scroll a window while the laser is on it.
8. **Leave the table:**
   * **Let go over the slab:** it stays on the table.
   * **Carry it off the slab and let go:** the real part goes back to the arena **where you let go**, at the arena's scale and in the
     orientation it had when it went on, or, with the tablet's Table page set to **As turned**, in the turn you gave it on the table (a normal move: undoable, saved). While you carry it past the slab the frame turns **amber**
     and the status line says letting go will send it back. A part held by enforced mates goes back where it came from instead.
   * **To arena** (deck): the real part goes back **exactly where it came from**, nothing moved.
   * Closing the table does the same as To arena.
9. **Edited parts have stale mates.** Every instance of an edited part gets a **warning badge** and stops being steered by its mates.
   When one is put down (or handed back), an **Enforce mates** button floats over it. See below.
10. **Resize the slab:** it is a pane of glass (rounded corners, a rim that glows when the table is engaged) with a bracket hugging each
    corner, like the floating windows', and a **small bright point on each corner of the slab's rectangle** (the curved glass leaves nothing to aim at
    there). Aim at one (it brightens and the laser stops on it), hold the trigger and drag: the opposite corner stays put and the
    deck, handle and tree follow. 0.5 x 0.3 m to 1.4 x 1.0 m. The part keeps its place relative to the slab's middle. The **size is remembered**
    for the next launch, and the **tool deck is as wide as the slab** (0.6 m to 1 m).
11. **View modes** (wrist tablet > View > **Display**): **Shaded**, **Shaded + edges**, **Wireframe**, for every part in the arena and the table's copy.
    See "View modes" below.
12. **Save:** Files tab → **Save as new file** writes the whole session as a new `.didsa` the flat app can open, and says where (the full folder,
    not `user://`). See "Not losing work".

## The deck

Five category slots, six tool slots, as in your sketch. Names are DIDSA-CAD's own, in the flat app's order (taken from its sketch
speed dial, constraint ribbon and feature picker); a category with more than six tools shows five and a **More** slot that pages.

| Category | Tools now | Not built yet (the flat app has them) |
|---|---|---|
| **Sketch** | Select, Line, Rectangle, Circle, Arc, Polygon, Point, Slot, Ellipse, Ellipse Arc, Spline, Text, Trim, Offset (the row pages); Circle, Rectangle and Line each have more than one way (3 points / from centre / from middle) | Convert as a tool (references are made silently by aiming at the part instead), sketch Pattern / Mirror, offset of a whole chain, explode polygon / slot / rectangle, constrained drag, auto-constraint inference while drawing |
| **Constrain** | Dimension, Horizontal, Vertical, Parallel, Perpendicular, Coincident (the rest, Equal, Collinear, Concentric, Equal radius, Tangent, Point on line / curve / ellipse, Midpoint, Fix, are in Select's menu) | Spline tangent |
| **Feature** | Create: Extrude (both sides, thin wall, draft), Revolve, Loft (thin wall, guide curves), Sweep, Helix (taper, pitch segments), Plane (offset, middle, on corner, to edge, 3 corners). Refine: Fillet, Chamfer (angle, flip), Shell, Mirror. Modify: Pattern (skips, orientation), Boolean (Subtract / Common), Merge, Split. Gears (M2 of [`gears-and-motion-plan.md`](gears-and-motion-plan.md)): Gear (external / internal, helical, herringbone, bore), Rack, Bevel gear | The surfacing family, the intersection curve, gear chain / planetary / bevel pair (several gears in one part cannot be coupled or driven, plan D2); Extrude profile selection, Mirror / Pattern of features, Pattern ghost-tap skips, Planes from sketch lines / arcs / curves, plane Edit |
| **Modify** (direct edit) | Move Face (along the normal or X / Y / Z), Delete Face, Move Body (X / Y / Z), Scale Body, Delete Body | Move Face along a sketch line or by an XYZ shift, Move Body rotation and copy-along |

The deck has room for another category; **Inspect** (Measure, Section) is the natural one and is not built on the table (both exist on the wrist tablet).
The deck is data (`table_tools.gd`), so adding a tool is one registration plus its behaviour. The order the missing items will be built in is in
DIDSA-CAD `docs/roadmap.md` ("DIDSA-VR: parity gap review and rollout order").
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
| Console | `design_table.gd` | Slab, deck, handle, theme, seating, sending the part back, Reset, the Enforce plumbing. Joins the `design_tables` and `diegetic_panels` groups so `controller.gd` asks it about seating, gripping the part and its handle. **Moving the table:** grip the handle (the pill on the slab's front edge) with the hand on it, or, since 10 Nov 2026 (owner's report: needed when working seated), with the **laser on the pill** from anywhere, like a window's handle; the laser carry (`PanelHandle.laser_pill_only`, `keep_level`) keeps the slab's slope and turns it only about the vertical to stay towards you, A/X pulls it nearer and B/Y pushes it away; a laser on the glass never picks the table up (`tests/table_laser_grab.gd`). |
| Glass slab, resize | `shaders/table_glass.gdshader`, `table_resize.gd` | The slab is one flat plane drawn by a signed-distance shader (rounded corners, rim and glow in metres, so it stays crisp at any size; `slab_radius`, `slab_border`). `table_resize.gd` is the window-style corner drag: arc brackets, hover claims `ui_hover`, opposite corner fixed; `design_table.gd`'s `set_slab_size()` re-lays out the handle, deck and tree. The handle's halo is told the panel is see-through (`PanelHandle.set_hollow`). |
| Handling the part | `table_manip.gd`, `table_pose.gd` | Grips (one hand moves, two turn and scale), the right stick and A / B, the "engaged" rule and its tell. `table_pose.gd` is pure maths in the console's own frame (two-hand step, stick turn, nudge, clamps) so it is unit-tested. Gripping sets a `table_part_held` meta on the hand, which `two_hand_model.gd` reads so the grip doesn't also drag the world; `controller.gd` hands the table its grips first (`_try_grab_table`, `_try_release`) and asks it who owns the stick (`is_manipulating`). |
| Deck UI | `table_ui.gd` | Category row, paged tool row, an options row, status line with the TABLE ACTIVE chip, Snap / Reset / To arena / Undo / Close. Pure 2D `Control`s in the shared theme (`ButtonRail`, per-category accent, `FxOverlay`), so it also runs in a plain window. |
| Tool data | `table_tools.gd`, `tool_pager.gd` | Uses the wrist tablet's own `TabletRegistry` + `ToolManager`: one active tool across categories. |
| Editing session | `table_editor.gd` | The state machine (pick plane → sketch → features), the laser hover and the shared `ui_hover` claim, tool routing, the options row, applying features, refreshing geometry, undo. |
| Sketch logic | `sketch_session.gd` | No scene: the backend sketch, the local copy of it, each tool's calls, selection, dimension candidates, undo. Takes an `api` Callable, so tests give it a fake. |
| Sketch drawing | `sketch_view.gd`, `plane_markers.gd` | The sheet window and, in the sketch plane's own frame, entities as constant-width ribbons clipped by `sketch_lines.gdshader` (bright core over a dark edge so they read on a white part and on the slab), cursor, rubber band, dimension labels; the three plane squares. Built only when the sketch changes. |
| Snapping | `snap_resolver.gd` | Pure. Existing point, the origin, a corner or hole centre of the part, a midpoint (a sketch line's, or a part edge's), the nearest spot on a curve or a part edge / rim, axis inference. |
| The part's geometry as references | `part_references.gd` | Pure, grid-indexed: the part's vertices, straight edges and circular edges in the sketch plane (centre, radius, whole circle or arc), projected onto the sketch plane; look-ups for the laser (corner, centre, edge, rim, midpoint); faces (a flat face square to the plane as a line, a cylinder whose axis is square to it as an axis point) read from each face's boundary edges. `sketch_session.gd: ensure_reference` makes whatever is aimed at a pinned point / line / circle; `load_references` reads which of the sketch's points are references and how each is doing. |
| Clip to the sketch window | `sketch_clip.gd`, `clip_globals.gd`, `shaders/clip_common.gdshaderinc` | While a sketch is open the copy, its edge lines and its overlays are cut to a box (the window rectangle in the sketch plane, `DEPTH_M` either side). The section tool's shader and global-uniform scheme, with a per-material `window_clip` switch; `clip_globals.gd` registers the global parameters once for both. |
| Plane maths | `sketch_math.gd`, `table_seat.gd` | Pure: fixed-plane bases (XZ's x is −X, as the backend), turning any plane flat on the table, ray→sheet, fit scale. |
| Backend line | `cad_api.gd`, `part_features.gd` | A serial HTTP queue (one request in flight, in order) and thin Extrude / Fillet / Chamfer / delete calls. |
| Stale mates | `dirty_mates.gd`, `mate_health.gd`, `enforce_button.gd` | See below. |
| Tree (two tabs) | `table_tree_window.gd`, `table_build.gd`, `build_tree.gd` | The window docked at the slab's left has **Build | Parts** tabs. **Build** is the part on the table's own build tree (see "The Build tree" below); **Parts** is the assembly list (the existing Assembly Tree window) with Table and Bring on each row. `table_build.gd` holds the Build tab's state and actions, the window is only its view; `build_tree.gd` is pure (names, summaries, edit payloads, cascade preview). |
| Shared picking | `scripts/laser_pick.gd` | The ray loop and "what would a pick take here", now used by `controller.gd` (select, hide, Mates, Measure) and the table. |

**A copy, not a reparent.** The arena's parts sit under a scaled root (`assembly_root`) whose frame the mates tool, pose saving, hide
and section all assume. Rescaling or reparenting a node onto the table would break all of them. So putting a part on the table hides the
arena node (untouched) and shows a scaled **copy** (own collider on a private physics layer, not in `grabbable_parts`, so no arena tool
ever sees it). The copy is what you edit; the real node comes back when the part leaves the table. The user's own scale lives on the copy's **pivot**
(not the copy), so the sketch sheet, plane squares and drawing, which are children of the copy, follow it; the snap, pick and label
radii use the part's scale (`effective_scale()`). Hide-all / show-all / reverse / isolate skip the node that's
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
   re-solves the rest, clears the flags only if everything could be met, and says on the button what it turned off. A failed solve keeps
   the flags and says why.
4. **Remake** (second step, on the same button). For each turned-off mate whose faces all still exist in the new shape, `mate_health.gd` finds
   the face that is now **the same one** (same kind and, for a plane, the same direction at the same place; the biggest if an edit split it)
   and the button becomes **"Remake N mate(s)"**. Pressing it creates a new mate of the same type, value and flip on those faces (DIDSA-CAD never
   changes what a mate references, so it is a new mate), deletes the old turned-off one, and solves again. A mate with a face that is gone for good
   is not offered and has to be made by hand (Assembly > Mates). Checked against the real solver: the plate returns to the stack.

Limits: the flags live on the nodes and are saved as the VR-only `vr_stale_mates` extra (see "Not losing work"); a reload without them re-reads the
mates fresh, but a mate that already names the wrong face stays wrong, which is why the suppression, being saved, matters. Only the top-level
assembly's mates are checked and enforced (`enforce_all` works on the root; sub-assemblies are not walked). Non-planar faces are compared loosely
(kind, centroid, area).

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

* The tool list above (the "Not built yet" column: option depth, surfacing, curves, gears, Inspect, AI).
* **Editing an existing sketch** is now there (Build tree > a sketch row > Edit), except a sketch the flat app **flipped or turned** (refused with
  a message). The flat app's separate Planes / Surfaces / Curves sections are not built (planes are rows in the feature list; surfaces and curves
  are not shown).
* **Dragging a row out of the tree** onto the table or into the world: the laser freezes the pointer while the trigger is held
  (`laser_surface.gd`), so a drag would need its own gesture. Rows have buttons instead.
* **New part makes a child part only.** It is always a part placed on the root assembly; drawing directly on the root's own content, or
  placing a new part inside a sub-assembly, is not offered. It is also named automatically (renaming is not built).
  The list of everything still open, with its closing phase, is `docs/design-table-gaps.md`.
* **Sub-assemblies:** the table edits one *part*. An assembly of other parts is refused with a message.
* **Persisted dirty flags**, and a bulk "enforce" or mate-health endpoint on the backend (DIDSA-CAD roadmap's reference-drift idea). The
  client-side check above covers planar faces well and others loosely.
* **Redo of sketch steps** (features and Build-tree edits have Redo, and a translucent preview before Apply, Phase 5).
* **Not handled on the table yet:** rolling about the line between two hands (the stick spins about the slab instead), and snapping a turned part back to the nearest face. Where the **engaged** threshold sits (the laser has to pass within 1.4 x the part's bounding sphere, or be on the sheet), the 90 deg/s stick rate and the A / B speed are guesses until someone tries them.
* **On a headset:** nothing here has been seen in a headset. The laser, the grips and the layout are tested with simulated
  controllers and rendered once in software; the feel (deck size, tilt, snap radius, ghost label hit radius) needs a session with a
  real controller.
* The multiplayer, Bluetooth pen, other headsets, environments, app windows and network storage items from the brief remain out of scope.

## Testing

Headless, in `tests/run_all.sh`: `design_table_logic` (pager, registry, plane maths, snapping, seat numbers, the pose maths), `design_table_scene`
(summon, deck clicks, seat, move / two-hand turn and scale / stick / A-B / engaged tell / Reset, send back to the arena, To arena, close, handle), `sketch_session` (the sketch calls against a fake backend,
`tests/helpers/fake_cad.gd`), `design_table_editing` (the real laser end to end), `design_table_tree`, `design_table_mates`,
`design_table_save`, `mate_health`, `view_modes`, `work_loss`, `table_handling`, `design_table_references` and `design_table_references_more` (corners, edges, holes, midpoints, driven dimensions, the references of hidden / rolled-back parts and reopened sketches, lost and moved references), `design_table_reference_robustness` (faces, silent helpers, no duplicates, no orphans, a failed reference leaves nothing), `sketch_clip` (the window clip's logic). Local only (a running backend, `secrets.cfg`): **`e2e_design_table`** (a plate built through the
session, placed twice, edited on the table, saved, reopened) and **`e2e_design_table_mates`** (the real solver), **`e2e_sketch_select`** (the origin point and every Select menu option against the backend's real constraint schemas) `e2e_revolve` and `e2e_features` (Revolve, Shell and Mirror against the real feature schemas) and `e2e_build_tree` (which now also reopens a sketch, changes a dimension, presses Done and sees the rebuilt part), `e2e_references`, `e2e_references_more` (a hole's centre and rim, edge points, driven dimensions, an at-midpoint next to a hole), `e2e_references_face` (a blind hole's face axis end to end: live, silent, no duplicate, follows the hole, no orphan, survives reopen), `e2e_references_lost` (a fillet moved to another edge: the reference follows or is flagged, shown, re-picked) and `e2e_references_history` (a reopened non-last sketch, a hidden feature). Rendering and timing: `sketch_clip_render` and `sketch_clip_picture` (the window clip),
`design_table_render`, `design_table_perf`. See `tests/README.md` for what each line should say, and `docs/status.md` "How this has been
worked on" for standing up a throwaway backend.

## Selection-first editing: the selection drawer (T6)

With no tool chosen and no sketch open, the laser lights the face, edge or corner under it (T5) and **a pull selects it** (a second pull on a selected one drops it; more pulls add; a pull on empty space, **B**, or the drawer's **X** clears everything and closes the drawer; a pull on the deck or a window never clears it). The **selection drawer** (`selection_drawer.gd`) then slides out of the *front of the slab itself*: a fixed 0.40 x 0.11 m (`DRAWER_SIZE`, the same at every slab size), centred on the front edge, a few mm above the glass, tipped up 15 degrees, never past the slab's front edge, so it never covers the tool deck (which does not move) or the Properties and tree windows. Top row: the **breadcrumb** (`selection_breadcrumbs.gd`): *Face 12 > Body 1 > made by Extrude 2 > Part "Bracket"*; taking a rung selects that level and the actions change. The "made by" rung is the feature that CREATED the body (a body id is its creating feature's id, with a `#N` suffix stripped: `graph.py` `base_feature_id()`); it is not the last feature that touched it, and there is no rung for the feature that made one particular face (the backend has no route for that: a follow-up in DIDSA-CAD). Under it: up to four actions, the most likely first, in the colour of the deck group it belongs to (Create blue, Refine amber, Modify violet), then More and X; a disabled action stays with its reason (shown on the status line when the laser rests on it). `selection_actions.gd` is the pure table (a port of the flat app's `contextActionsFor`): an edge offers Fillet, Chamfer, Create plane; a flat face New sketch on face, Move face, Create plane, Fillet, Chamfer, Shell, Delete face; a body Move / Scale / Mirror / Pattern / Shell / Delete; a finished sketch (from its Build row) Edit sketch, Extrude, Revolve, Sweep, Loft; a feature Edit, Roll back to here, Suppress (not built), Delete; the Part rung Return to arena, Appearance (not built), Properties.
**Choosing an action starts the existing tool with the selection already picked** (`table_editor.gd` `begin_tool(id, seed)`: Fillet with the edges in `edges`, Shell with the faces in `faces`, Extrude from a sketch through the existing seed...), so picks can still be added or removed before Apply; the drawer hides while a tool runs. New sketch on face and Edit sketch / Edit / Delete / Roll back act directly. With a sketch open the drawer carries the sketch selection's options as well as the options row (the row is kept so the flows that already use it still work), and the sheet's hinge is behind the drawer, not at the slab's edge. `selection_first` (editor) turns the whole thing off: a pull on a flat face then starts a sketch on it as before.

## Selecting without a tool (T5)

With a sketch open the Select tool is on whenever no drawing tool is (putting a tool down turns it back on), so a pull on anything picks it: points, lines, curves, text, **dimension values** and **constraint letters** (`sketch_view.gd` keeps a hit rectangle for each label; `annotation_near()`). Labels are selected as *annotations* in the session (`sketch_session.gd` `annotations`), separate from the geometry selection, so a constraint and a line can be selected together. One dimension offers **Edit value** (the number pad; a quick second pull on a dimension opens it straight away), **Delete** and Clear; constraints and mixed selections offer **Delete** and Clear (the constraints go, then the geometry with what depends on it). Undo takes back an edited value (PATCH of the old one) and a deleted constraint (a POST of it again); deleting geometry still has no undo, as before. The flat app's Driven / Driving switch is not offered (no route in `backend-api-notes.md`).
What is under the laser lights *lighter* than what is picked: a hovered entity is its own colour pulled towards the accent, a hovered label has an accent outline, a hovered face / edge / corner of the part uses the highlighter's lower-alpha hover colour; selected stays the warning colour, solid. With no sketch open, the laser lights the face, edge or corner under it (`table_editor.gd` `hover_part_entity`, which T6's selection model will use).

## The sketch sheet at the front (T4)

While a sketch is open the sheet is hinged on the slab's front edge (its lower edge on the edge, `sheet_hinge_clearance` above the glass) and leans back `sketch_lean_back_degrees` (15 by default; 10 / 15 / 25 in Settings > Design table, with *Sketch sheet: Front (hinged) / Middle*, where Middle is the older floating sheet at 60 degrees), so it is close to a user standing at the tool deck. The part is slid along the sketch plane only; Reset and Fit put it back on the sheet's middle.

## Starting from nothing: New assembly and New part

**Start buttons (T2, 4 Nov 2026).** An open design table with no part on it floats two large buttons above the slab, **New part** and **Open part...** (`scripts/ui/start_buttons.gd`; the same panel shows in an empty Assembly Room as **New assembly** / **Open assembly...**: assembly files and part files are the same native files, only the words differ). They go the moment a part is seated and come back when it is taken off. **Open part...** lists native files (`folder_chooser.gd` in files mode, starting in the project folder); the file's Part is added to the assembly beside the table (`add-component`; a new assembly is started if none is loaded) and then seated as if carried there (`design_table.gd` `open_part_file()`, `main.gd` `add_component_to_world()`). Not built: the table opening on a part that lives inside a room (the table seats the world's own parts only; see the plan's T2 note).

* **New assembly** (wrist tablet > Files > **New assembly**, pressed twice within four seconds because it discards what is loaded): `POST
  /document/new` (a fresh, empty backend document) then one empty root part named Assembly, shown as an empty arena. Save first if you want
  the old one. It needs the backend (a bare local `.glb` has no document to start). STEP / STL / OBJ import now does the same
  `POST /document/new` first, so each import is a clean document; before, every import piled another part onto the same document and a
  later Save exported the pile.
* **New part**: `POST /document/parts` then `POST /document/parts/{root}/occurrences` with a client-made id (`occ_` + 16 random bytes), the new
  part as `resolved_part_id`, its name and its pose in the assembly's own millimetres (`new_document.gd`). The backend's glb gives an empty
  part no mesh at all (a mesh-less node), so there is nothing in the arena to seat; `Main.add_blank_part()` makes a hidden placeholder
  node tagged with the occurrence (flagged `blank` and `new_part`) and the table seats that through the normal path. While blank the copy
  is not drawn and has no collider (it only stands in for a 100 mm size and carries the plane squares and the sheet). The first feature's mesh
  replaces the placeholder (`swap_part_mesh`), the plane squares are rebuilt to fit, and the copy gets its collider; taking the feature back
  (an empty glb again) restores the placeholder (`_blank_out`).
* **Flat app compatibility.** The document is the backend's own, so nothing VR-specific is stored. `Document.add_part` makes the FIRST part
  created the root (what a saved file and the flat app open), which is why a new assembly creates the root first and every new part is a child
  occurrence of it. A saved session with more than one part is the flat app's "whole-session bundle", opened by a direct `import_native`; the
  occurrences carry `resolved_part_id` (not `external_ref`), exactly as Add component's already do. `tests/e2e_new_part.gd` checks the
  exported file (root first, the child with its sketch and extrude, one occurrence) and imports it back. **Not checked:** opening a VR-saved
  file in the flat app's own UI (no Flutter toolchain in the sandbox): worth doing once by hand.

## The Build tree

The tree beside the table is the part's **build tree**, the same list the flat app shows in its part design lens (`feature_tree_panel.dart`): every
feature that made the part on the table, in order, named by type and count ("Sketch 1", "Extrude 1", "Fillet 1"), with a second line (a sketch's
plane, "Boss 12 mm", "R 2 mm, 1 edge(s)") and the part's bodies underneath. It opens on the **Build** tab as soon as a part goes on the table and goes
back to **Parts** (the assembly list, for choosing a part) when the table empties. It is read from `GET /document/parts/{id}/features` whenever the
part changes. Tap a row to select it; a strip under it offers:

* **Select and light up:** an extrude lights the faces of the body it made, a fillet / chamfer its edges, a plane (or a sketch on a plane feature)
  its faces; a sketch on a reference plane just says so.
* **Edit** (extrude, revolve, shell, fillet, chamfer): the numeric pad opens on the current depth / angle / wall / radius / distance (on a sketch row: it reopens the sketch); the value goes to the backend as a PATCH (any
  feature, not only the last) and the part updates on the table and in the arena. The table's **Undo** puts the old value back.
* **Rename** (beside the title): the full keyboard opens on the part's name; confirming renames the part (`PATCH /document/parts/{id}`) and every placed instance.
* **Delete:** two presses ("Sure? Deleting Sketch 1 also removes Extrude 1, Fillet 1"); the backend's cascade deletes the feature, everything built
  on it and the sketches they owned. Not undoable (as in the flat app).
* **Hide / Show** and **Roll back / Roll forward:** change **only the table's copy**. The arena's real part always shows everything. Hide leaves a
  feature's body out of the picture (everything is still computed from the real history); Roll back to a row skips every later feature; adding a
  feature is refused while rolled back. Both reach the backend as the `hidden_feature_ids` / `rollback_excluded_feature_ids` query params of
  `assembly-mesh.glb`, which **needed a DIDSA-CAD change (2026-10-03)**: an older backend ignores them and shows no hiding. Hidden ids are the flat
  app's `hidden_feature_ids` file extra: a save writes them, a file that carries them shows them hidden. Rollback is not saved, like the flat app's.

Edit on a **sketch** row reopens that sketch (see "Sketch" above): the part turns to its plane, its points, lines and origin are read, and **Done** rebuilds the
part. A backend **older than DIDSA-CAD 2026-10-03** (its OpenAPI document lacks the glb's two parameters, asked once) gets Hide / Show and Roll back
**switched off** with a note, rather than buttons that claim to work and change nothing.

## View modes

Wrist tablet > View > **Display**: **Shaded**, **Shaded + edges**, **Wireframe** (the flat app's `ViewportRenderMode`), saved with the other settings. Edges are the
backend's **real B-rep edges**: `assembly-mesh.glb` already carries every body's edges in its `topology` extras and VR kept them for Measure and Mates; they are
drawn as one line mesh per part (built the first time an edge mode needs it and rebuilt only when the part's mesh changes), dark over faces and light alone, through a shader
(`edge_lines.gdshader`) that pulls the lines slightly towards you (so they are not buried in the surface) and honours the section tool's clip. Wireframe hides the faces
(`layers = 0`, so the part is still pickable and grabbable) and keeps the edges. A model with no topology (a bare local `.glb`) falls back to **sharp-angle edges (30 degrees)
extracted from the mesh**. A blank new part draws nothing in any mode. Lines are one pixel wide, which may be faint at a distance on a Quest: the fallback if so is
camera-facing ribbons (not built; decide on a headset).

## Not losing work

* **Unsaved changes.** The document counts as unsaved after anything a save would write (a move or mate on the undo stack, a design-table edit, hiding a feature, a
  new part, adding a component) until you save or load. Anything that **replaces** the document (Open, an import, New assembly) first says
  "you have unsaved changes: save first, or do it again within a few seconds to discard them"; the Files page shows "Unsaved changes" and where saves go.
* **Its own document session.** The backend keeps one in-memory document per `X-Document-Session`. VR now sends its own (`vr-` plus random hex per launch, or
  `document_session` under `[backend]` in `secrets.cfg`), through one header helper (`backend_session.gd`) that every call uses, so a VR import / New assembly /
  edit never replaces what the flat app has open on the same backend, and the other way round. **Work moves between the apps by file** (Save as new file, then open it
  in the flat app). This changes how the two apps share a backend: if you relied on them sharing one document, set the same `document_session` in both.
* **Saves say where they went.** The status line gives the folder in full. On a Quest, `user://models` is the app's own data folder.
* **Stale-mate flags** (the warning badges on parts whose mates need redoing) are saved as a VR-only extra, `vr_stale_mates` (occurrence ids); the flat app
  ignores keys it does not know, and opening that file flags those parts again.
* A normal part that loses its last solid in the Build tree goes blank in the arena (like a new part), instead of keeping the shape that is gone.

### Fix on a flagged feature (Phase 4)

A Build row flagged "lost" or "may have moved" for a fillet, chamfer, shell, mirror or pattern has Fix like a sketch. Fix rolls the part back to what the feature saw, you pick the replacement edge or face (the lost slot first), and Apply PATCHes the feature. Keep confirms the reference as it is. Tested with the fake and a real backend, not in a headset.

## Modelling foundations (Phase 5)

* **A feature is a class.** `scripts/design_table/features/feature_tool.gd` is the interface (`options`, `handle_option`, `on_activated`, `request`, `can_apply`, `finishes_sketch`, `preview_mode`, `preview_route`, `patch_body`, `done_text`); `feature_tools.gd` lists the tools by id; `table_tools.gd` stays the registry of what is on the deck. Extrude, Revolve, Fillet, Chamfer, Shell and Mirror are on it and `table_editor.gd` has no match arm for them any more (it asks the active tool). The create bodies come from `PartFeatures.*_request` (checked, `{ok, error, route, body}`), the same body a preview PATCHes and Redo resends. A new feature is one more file plus a line in `feature_tools.gd` and `table_tools.gd`.
* **The Properties panel** (`table_props_window.gd`, docked at the console's right like the tree is at its left) shows the active tool's name, its hint and all its settings from that option list, toggles grouped, Apply last. The deck's old options row is hidden when it is docked (`ui.options_sink`); `ui.option_button(id)` finds the panel's buttons. First version, today's controls and today's style: layout and colour are the next step. Regenerate the pictures with `tests/dock_panels_render.gd` (see "Pictures of every tool" below).
* **Body picks.** `Editor.start_body_picks(limit)`: the laser lights the whole body under it (`TopologyPick.body_entity`, key `solid:<body>`), a pull picks / un-picks it.
* **Picks from earlier sketches.** `Editor.start_curve_picks(limit)`: every finished sketch's lines, circles and arcs are read once, read-only (`sketch_picks.gd`), drawn on the part and offered to the laser (nearest within 12 mm of world reach); the Build row of a sketch has `Lines: on / off` while this runs. The pick is `{sketch_feature_id, sketch_id, entity_type, entity_id}`: a Loft section is its sketch feature, a Sweep path / Pattern direction is the backend's sketch entity ref. A flipped or turned sketch is left out (as reopening one is).
* **Preview.** Eager tools (every feature but Mirror): as soon as the tool has what it needs the feature is created, a setting change PATCHes it, no valid picks or another tool deletes it, Apply keeps it (a PATCH of the final settings, no second create). The part's own copy is NOT replaced while previewing (the picks stay valid); the result is fetched at quality 0.3 and drawn translucent (`feature_preview.gd`, lit, pushed out 0.25 mm so it does not z-fight). Coarse tools (`preview_mode() == "coarse"`: Pattern, Loft) POST the coarse-preview route and draw the body meshes; nothing is stored. A preview over **150,000 triangles** is not drawn and the user is told to Apply (`FeaturePreview.MAX_TRIANGLES`, checked in `tests/design_table_preview.gd`; measured on a desktop, not on a Quest). `ed.preview_enabled = false` turns it off.
* **Redo (features and Build-tree edits).** Undo keeps the create request; the deck's Redo sends it again (the feature gets a new id; Undo is last-in first-out so nothing depends on the old one). A Build-tree edit that was undone is redone with its new value. Any new feature or edit clears the redo stack. Sketch steps are not redone.

### Pictures of every tool

`TABLE_RENDER_DIR=/tmp/dock xvfb-run -a "$GODOT" --path . --script res://tests/dock_panels_render.gd` saves two PNGs per tool: `NN_category_tool.png` (the console) and `NN_category_tool_panel.png` (the Properties panel close-up, or the deck for a tool with no settings). `DOCK_MODE=before` saves the old options row for Extrude, Fillet and Mirror (`before_*.png`). Software (llvmpipe) renders at 1280x720, a layout check, not a headset view. `TABLE_RENDER_DIR` is not committed; `tests/preview_render.gd` (real backend) saves the translucent Fillet preview.

## The tools added in Phase 6

* **Feature row** (pages of five and More): Extrude, Revolve, Fillet, Chamfer, Shell, Mirror, **Plane**, **Loft**, **Sweep**, **Pattern**, **Boolean**, **Merge**, **Split**. **Sketch row** gains **Ellipse**, **Ellipse Arc**, **Spline**, **Text**, **Trim**, **Offset**. A new **Modify** category (violet): **Move Face**, **Delete Face**, **Move Body**, **Scale Body**, **Delete Body**. Every one has its settings in the Properties panel and its Build row (with Edit).
* **Making a loft or a sweep.** Draw each section's sketch on its own plane (Plane first), Done each; Loft: pick one line of each sketch (Build row `Lines: on / off` narrows it), Apply. Sweep: finish the path's sketch, draw the profile in a new sketch and leave it open, choose Sweep, pick the path's lines in order, Apply.
* **Pattern / Boolean / Split** pick whole bodies with the laser (a body lights as a whole); the "Pick" toggles in the panel say which kind of thing the next pull picks (body, sketch line, plane).
* **Edit** on a Build row of any of the new features opens its tool with the feature's values; Apply changes it as one Undo step.
* **Text** needs words typed on the full keyboard (Text button), a font from the backend's bundled list (Font steps through them), a height and a turn; the glyph outlines are drawn from the backend's.
* **Trim cannot be undone**; Offset can.
* **Ellipse edges** of the part (an elliptical hole's rim or boss in the sketch plane) are offered like circular ones and become a pinned reference ellipse; they do not follow an upstream change (R-F limit).

## Gears on the table (gears-and-motion plan M2)

The Feature tab's fourth group, **Gears** (green), holds **Gear**, **Rack** and **Bevel**. None needs a sketch: each makes one new body from its numbers (`gear-features`, `rack-features`, `bevel-gear-features`, always a Boss). They stand on the part's XY plane unless a plane, made plane or flat face is picked first (a pull with the tool active, or the **Plane** chip); the apex of a bevel gear is the plane's origin.

* **Gear** (`features/gear_tool.gd`): External / Internal, Module, Teeth, Width, Pressure (cycles 20 / 14.5 / 25), Helix (0 = straight, negative the other hand), Herringbone (greyed at helix 0), **Bore** (external only, 0 = none; a bore needs a root diameter of at least 1.1 times its size, the backend says `bore_too_large` otherwise), **Outer** (internal only, filled with `module * (teeth + 8)` when the tool is switched to Internal), Backlash, Root fillet, Shift (auto, or typed), **Mate teeth**. Under the settings two greyed lines give the pitch, tip and root diameters (the backend's `/document/gear/preview`, the standard-tooth formulas until it answers) and the **centre distance** to a partner gear of Mate teeth teeth (`m (z + N) / 2`, for an internal gear `m |z - N| / 2`): where the shaft holes go. The coarse preview (`gear-features/coarse-preview`, with the bore cut) shows it before Apply.
* **Rack** (`rack_tool.gd`): Module, Teeth, Width, Pressure, Backing height (auto = 2 x module), Backlash. No coarse preview exists for a rack, so it is an eager preview like Revolve.
* **Bevel** (`bevel_gear_tool.gd`): Module, Teeth, Width, Cone, Mate teeth with **Cone from mate** (`atan(z / z_mate)`, a 90 degree pair), Pressure, Spiral (0 = straight) with Left / Right, Bore. Coarse preview `bevel-gear-features/coarse-preview`.
* The numbers are typed on the popup keyboard like Extrude's depth (whole teeth only; a bore, fillet, backlash or spiral of 0 is allowed; a negative helix is the other hand). They are kept for the next gear. Edit on a Build row opens the same tool with the feature's values and PATCHes it (an Auto profile shift cannot replace a typed one: the backend keeps the last typed value).
* Tests: `design_table_gears` (fake backend) and `e2e_gears` (real backend). Not checked in a headset.
