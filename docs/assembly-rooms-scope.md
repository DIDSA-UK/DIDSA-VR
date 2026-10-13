# Assembly Rooms: scope

Status: scoping complete except the items in section 12; next is the plan phase, starting with the R0
spike. Written from a design conversation plus a read of `README.md`, `docs/design-table-brief.md`,
`scripts/controller.gd`, `scripts/clip_globals.gd` and `scripts/mesh_identity.gd`. `main.gd` and the
design-table scripts have **not** been read yet; statements about them are inference.

## 1. What it is

An **Assembly Room** is a finite volume of space that behaves like the world, but holds a
different assembly. Analogy: a browser tab.

- **The design table is for modelling; the room is for assembling.** A part file is the same kind of
  file as an assembly file, so a room accepts *any* file or occurrence as its root: a sub-assembly at
  any level, a single part (to which other parts can then be added to make an assembly), or another
  assembly opened side by side for comparison.
- Geometry from outside is clipped and does not intrude on the room; geometry inside is not shown
  outside the room volume.
- Room bounds are draggable. A room has its own scale (a display transform only).
- A room has its own **room console** (a bespoke control panel), not a second wrist tablet.

### Architectural stance

**The world is Room 0**: the same `Room` class with unbounded bounds. A room owns its origin,
scale, volume, undo stack, tool state, section planes and loaded root part. The design table is a
specialised single-part room and may converge on this later (not in scope now). Do not build a third
parallel mechanism next to the world and the table.

## 2. Decisions (settled)

| Topic | Decision |
|---|---|
| Table vs room | Table = modelling a part. Room = assembling. Table stays separate. |
| Root of a room | Any part/assembly file or occurrence. A part opened in a room can have parts added to it. |
| Concurrent rooms | Multiple rooms in v1. **Cap 4**, held in one setting (`max_rooms`, user adjustable). |
| Overlap | **No overlapping rooms.** Spawn and wall-drag refuse or push apart. |
| Nesting | **No rooms inside rooms.** Sub-assemblies at **all levels** can be opened in rooms in the world. |
| Wall shape | Oriented box, axis-aligned in room space, movable as a whole by a grab handle. |
| Minimum size | A **new room is at least a 3 m cube**, larger if fit-to-contents needs it. A separate, smaller minimum applies to later wall-dragging (value TBD, ~0.5 m). |
| Shared definition | Editing in a room edits the shared definition: all instances update. The console shows the instance count ("used 4x"); adding to or editing a definition with more than one instance asks first (edit shared / Save as...). |
| "Make unique" | A **Save as...** path: write the room's assembly to a new file/part and re-point *that one instance* at it. Others keep the old definition. |
| Aesthetics | Functionality first. Purely aesthetic or heavy effects are individually optional in Settings. PCVR is the baseline target; Quest is not a constraint on v1. |
| Persistence | Room layout (bounds, scale, position, colour) is session/settings state, **not** stored in `.didsa`. A room is a view construct, which keeps native files cross-compatible with the flat app. |
| Changed parts in preview | Preview tints changed parts differently from unchanged ones. |

## 3. Room lifecycle and entry

A room can exist **empty** (like the design table, which is summoned first). Ways in:

1. **Tree button**: a **Room** button on any sub-assembly row (like the existing **Table** button on
   parts). Spawns a room and loads that sub-assembly in one step.
2. **Summon room** from the wrist tablet, then carry an item in.
3. **Carry / send**: grip an item and carry it, or push it with A/B while gripped, into a room
   volume. While the item's centre is inside a room that can accept it, **cubic corner chevrons at
   the item's bounding-box corners** (and a brightened wall) show what release will do:
   - **Empty room: "open"**: release loads the item as the room's root.
   - **Occupied room: "add"** (distinct glyph, e.g. a plus at the chevrons): release inserts a new
     *instance* of the item into the room's assembly (the original stays where it was). *Proposed;
     confirm.* This is how a part opened in a room becomes an assembly.
   - Dropping outside every room leaves the item as-is.
4. **Files > Open in room** / **Files > Add** (the existing add-component path) targeting the focused
   room, for any assembly or part file.

Spawn placement: a free spot in front of the user, outside other rooms and preferring to be outside
the loaded model's bounding volume; room boxes are never placed overlapping.

Opening scale: content is fitted to roughly 70% of the room's volume (the same idea as the table's
"scales to fit"), with a **1:1** button on the console. The 3 m minimum is the volume, not a scale.

## 4. Picking a sub-assembly: widen selection with a dead zone

Today picking is at part level. Rooms need a way to grab a *group*. Vocabulary: **corner brackets on
a bounding box mean "this is a group"** (the same shape as the drop cue and the resize brackets).

### Gesture (right hand)

1. **Grip** on a part that sits inside a sub-assembly: the grab **latches** but the part does *not*
   move yet (dead zone, below). The part shows the usual cyan grip highlight.
2. **Right trigger click** (while the grip is held) **widens the candidate one level**: part, then its
   sub-assembly, then the parent, ... up to but not including the root, then wraps back to the part.
   Haptic tick per step; corner brackets on the candidate's bounding box; a breadcrumb
   (`Bolt < Bracket < Drive unit`) on the right-wrist tip panel.
3. **Move the hand out of the dead zone** to **commit**: the candidate (part or whole sub-assembly,
   which is one occurrence transform) follows the hand from then on. Brackets go solid and a haptic
   click confirms.
4. Releasing inside the dead zone commits nothing and pushes no undo step.

### Dead zone

- Purpose: a part must not move relative to its siblings while the user is choosing what to grab.
- Applies **only** to grabs of a part that has an ancestor below the root; a top-level part grabs
  exactly as today.
- Default about 2 cm of hand travel or about 10 degrees of rotation (settings: Off / Small / Medium).
  The hand travel inside the zone is dropped by **rebasing the grab offset at commit**, so nothing
  jumps; the steadiness filter is reset at commit.
- Nothing is sent to the mate solver, and no backend call is made, until commit
  (`mates_tool.constrain_drag` only starts after it).
- v1: cycling is only possible inside the dead zone. After commit, release and re-grab to change
  level. (A later version could allow widening mid-carry by reverting the child to its pre-grab pose.)

### Conflict with the tool wheel (verified in `controller.gd`)

The right hand's **trigger + grip pressed within 250 ms (`wheel_window_ms`) open the tool wheel**;
the first press of that pair has already begun a grab/select, and `cancel_for_wheel()` undoes it.
Resolution:

- Keep the chord as is. A trigger click **250 ms or more after the grip** is a cycle click.
  Because the part hasn't moved during the dead zone, a chord that cancels a just-begun grab is also
  now cleaner.
- Today a trigger press while the grip holds a part falls through to laser `_try_select()`. While a
  grip is latched, the trigger must be consumed by the cycle logic instead.
- Risk: a user who presses both quickly gets the wheel. If that proves annoying, suppress the chord
  when the hand is touching a nested part.

### Other routes

- **Tree**: tapping a sub-assembly row selects it as a group (today it reports "no geometry of its
  own"). Grip then moves the group.
- **Pick-level filter** (Parts / Sub-assemblies / Top-level) on the tool wheel or tablet, for laser
  picking. The laser path has no widen gesture of its own yet (open question).
- Inside a room the root is the room's assembly, so "top-level" resets there; mates operate on the
  room's top-level occurrences (README: mates pick top-level occurrences of the loaded root).

### Data prerequisite (verified in `mesh_identity.gd`)

`assembly-mesh.glb` nodes are **flat, one per placed instance, with only `occurrence_id` and
`owner_part_id` metadata and no hierarchy**. Group membership therefore has to come from the
occurrence tree (`GET /parts/{id}/occurrences`, already used lazily by the tree window), which must be
fetched fully and cached to map a leaf `occurrence_id` to its ancestor path. Moving a group means
moving every leaf node of that group by the same delta on the client and persisting the
*sub-assembly occurrence's* transform on the backend. Confirm whether the flat glb contains nested
leaves with baked transforms.

## 5. World preview ("push changes to world")

Hiding the world copy while editing loses context. For **both table and room**:

**World copy states** per edited definition: *Hidden* (current) / *Ghost original* / *Preview*.

- **Preview** re-instantiates the edited definition at each world instance's *placed (mated)
  transform*, in a **preview colour** distinct from existing highlight colours (cyan hover, pale
  yellow select, orange second mate pick are taken; default violet/magenta). Parts changed by the
  edit are tinted differently from unchanged ones. Mesh resources are shared, so the cost is extra
  transforms, not extra geometry.
- **Push** is an explicit button ("Show in world"), plus an **auto-update** option. Transform-only
  edits are cheap and can be live; re-tessellated feature edits depend on the backend and are
  throttled.
- If an edit made an instance's mates stale, the preview shows at the last-solved transform with a
  warning chip; the existing Enforce mates flow resolves it.
- A thin tether line from room to world instance, and a "fly to instance" action, show which copy
  you are looking at.
- Not available for a room whose root is not an instance in the world (greyed).
- Implement as **one shared service** keyed by definition id, subscribed to definition-change events,
  used by table and room.
- Possible follow-up: interference highlighting where the preview intersects neighbours.

## 6. Walls and look

- Box edges are always drawn. Face grids fade in by proximity to the hand/ray and fully while
  dragging.
- Fake glass (fresnel edge glow, faint tint, grid) rather than true blur: a real blur needs a
  screen-texture copy, which is costly and awkward in stereo. Reuse the existing glass edge-glow and
  `infinite_grid.gdshader` approach.
- Grid spacing follows room scale (600 mm at 1:1 becomes 60 mm at 10:1), which also communicates
  scale.
- Each room has a colour shared by its wall tint, tab chip and console.
- Clipped solids look hollow (as with sections). Fit-to-contents on open avoids parts straddling
  walls.
- Resize: grip handles at face centres, two hands drag opposite faces; **Fit to contents**; resizing
  never scales content.
- Parts carried past a wall are clipped and **snap back on release**. v1 never changes membership by
  crossing a wall.

## 7. Room console

- A small panel built on `diegetic_panel`, **grab-movable**, holding room-only controls: scale,
  1:1, bounds / fit, clip mode (Hide / Ghost / Preview), world preview push, grid, instance count,
  Save as..., close / return.
- **Pedestal**: a faint, ghostly projection from the console down to the ground (gradient-alpha
  column plus a floor ring, ground = world floor). Purely aesthetic, non-intrusive, optional.
- The console sits outside the volume and must not be clipped by any room.
- The **wrist tablet stays single** and retargets to the focused room. Mates / Measure / Sections /
  Undo / Colours act on that room, with a room chip in its status bar.
- **Focus rule**: the room containing the hand origin / laser hit owns input (cf. TABLE ACTIVE).
  Locomotion stays in world space. Scale pivots on the room centre, never the user's head; vignette
  on scale changes.

## 8. Settings (optional / cost-bearing)

`max_rooms` (default 4) · grab dead zone · glass wall effect · proximity grid fade · pedestal · room
colours · chevron animation · preview pulse · default clip mode · auto-update world preview. Group the
aesthetic ones under the existing Settings > Appearance effects switch.

## 9. Findings from the code so far

- **A clip precedent exists.** `clip_globals.gd` registers global shader parameters for one section
  plane and one oriented box (`window_clip_origin/u/v/n/half`, used by the sketch window), shared via
  `shaders/clip_common.gdshaderinc`. Rooms need one box per room with both polarities (inside-only
  for room content, outside-of-all-rooms for world content). Global parameters are single values, so
  v1 can use fixed parameter sets for 4 rooms; making `max_rooms` freely adjustable needs the boxes
  packed into a small float texture (or similar). Decide in the spike.
- **Picking goes through `LaserPick.ray(...)` with a callback** (HIT / SKIP / BLOCK) and
  `_find_grab_target()` over the `grabbable_parts` group. Both are the places to add the "is the hit
  point inside the owning room" test.
- **Precedent for a spatial owner of input**: `_try_grab_table()` / `_table_owns_input()` in
  `controller.gd`; rooms follow the same pattern.
- Grip begins a hold immediately (`_begin_hold`) and `_update_held_part` moves the part every frame;
  the dead zone needs a "latched but not yet moving" state before this.
- The undo history is a single shared `command_stack` instance injected by `main.gd`; a room needs
  its own.

## 10. Risks

1. **Picking vs clipping**: shader clipping does not change collision, so every pick (laser, grip
   proximity, drop test) must test against the owning room's volume and continue the ray if outside.
2. **Clip technique and cost**: discard-style shader (extends the existing clip include) vs material
   stencil (Godot 4.5+; project is on 4.7). Spike both; world materials must test every room, so
   cost grows with `max_rooms`.
3. **Per-room state**: `main.gd` appears to own one model, one history, one section gizmo and one
   tool mode. These become per-room context (confirm by audit).
4. **Transparency sorting** between glass walls, the section disc and highlights.
5. **Measurements and typed values** stay in real millimetres regardless of room scale.
6. **Float precision**: room-local origin helps with large models.
7. **Backend sessions**: mates and meshes seem keyed by part id, so a sub-assembly Part should open
   as a second root, but rooms with unrelated files probably need their own document session
   (`X-Document-Session`; today everything lands in the "default" session). Confirm.
8. **Save as...** needs a way to create a part and re-point one occurrence; confirm the endpoint
   exists or is needed in DIDSA-CAD.
9. **Group moves**: moving a sub-assembly moves many flat nodes together and persists one
   occurrence transform (section 4).

## 11. Phasing and plan-phase tasks

- **R0 spike (first)**: multi-box clip (discard vs stencil) with both polarities; picking and grip
  respect the clip; headless test; performance check on a headset/PCVR. Alongside it, the
  `main.gd` singleton audit and a read of the design-table scripts.
- **R1**: tree "Room" button, fixed 3 m room, scale, grab handle, close; any part/assembly as root.
- **R2**: draggable walls, Fit, glass look, room colour, tabs, carry-to-room chevrons (open / add).
- **R3**: room console + pedestal, per-room tool/undo scoping, wrist-tablet retargeting, widen
  selection with dead zone, group moves.
- **R4**: multiple rooms (cap setting), minimise (snow-globe scale), world preview for table and
  room, dirty-mate propagation.
- **Later**: Save as..., cross-room part moves, mid-carry widen, in-context mating, per-room
  environment, multiplayer (a room per person).

## 12. Open questions

- Occupied-room drop = insert a new instance (proposed above): confirm.
- Does the laser path (trigger at a distance) also get a widen gesture, or are the tree and the
  pick-level filter enough?
- Wall-drag minimum size value.
- Whether the dead zone should be shown as a visible ring around the latch point.
