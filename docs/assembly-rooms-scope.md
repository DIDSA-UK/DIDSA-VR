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
| Dropping into an occupied room | **Adds the item to the tree of the assembly in that room** (a new instance; the source is untouched). A novel way to add parts. |
| Concurrent rooms | Multiple rooms in v1. **Cap 4**, held in one setting (`max_rooms`, user adjustable). |
| Overlap | **No overlapping rooms.** Spawn and wall-drag refuse or push apart. |
| Nesting | **No rooms inside rooms.** Sub-assemblies at **all levels** can be opened in rooms in the world. |
| Wall shape | Oriented box, axis-aligned in room space, movable as a whole by a grab handle. |
| Minimum size | A **new room is at least a 3 m cube**, larger if fit-to-contents needs it. A separate, smaller minimum applies to later wall-dragging (value TBD, ~0.5 m). |
| Shared definition | Editing in a room edits the shared definition: all instances update. The console shows the instance count ("used 4x"); adding to or editing a definition with more than one instance asks first (edit shared / Save as...). |
| "Make unique" | A **Save as...** path: write the room's assembly to a new file/part and re-point *that one instance* at it. Others keep the old definition. |
| Picking a group (grip) | Grip latches, right trigger cycles the level, leaving the dead zone commits. |
| Picking a group (laser) | Trigger **hold** opens an assembly-level breadcrumb; hover a level, release to select. |
| Dead zone | Shown as a faint, soft-edged sphere (optional in settings). |
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
   - **Occupied room: "add"** (distinct glyph, e.g. a plus at the chevrons): release adds a new
     *instance* of the item to the tree of the room's assembly, at the pose where it was released.
     The original stays where it was.
   - Dropping outside every room leaves the item as-is.
4. **Files > Open in room** / **Files > Add** (the existing add-component path) targeting the focused
   room, for any assembly or part file.
5. **Grab from a tablet thumbnail** (section 3.1).

Spawn placement: a free spot in front of the user, outside other rooms and preferring to be outside
the loaded model's bounding volume; room boxes are never placed overlapping.

Opening scale: content is fitted to roughly 70% of the room's volume (the same idea as the table's
"scales to fit"), with a **1:1** button on the console. The 3 m minimum is the volume, not a scale.

Carrying across a boundary: the carried item is at world scale until it enters a room, then eases to
that room's scale as it crosses the wall (so you see what it will be at once dropped). The inserted
instance is always real-size in definition terms; room scale is only a display transform.

### 3.1 Drop payloads and tablet thumbnails

Generalise "something you can carry and drop" into a **payload** (a world occurrence, a sub-assembly
occurrence, a file, a part/definition id) with a lightweight **proxy** shown in the hand (thumbnail
card or bounding box) and a set of **drop targets** (room, world, design table) that each decide
"open", "add" or "refuse". Rooms, the Files list, and the (currently unbuilt) pull-a-row-out-of-the-tree
all use the same mechanism.

- **Tablet thumbnail grab**: the Files list shows a thumbnail per file; grip a thumbnail (with the
  laser on it, or the hand on it) to pull a proxy out of the tablet, carry it, and drop it where you
  want: in a room (adds it to the tree at that pose, or opens it if the room is empty), in the world
  (adds a top-level occurrence there), or on the table (new part).
- On drop the real file loads in the background; the proxy stays as a placeholder bounding box with a
  progress cue, then swaps for the real geometry.
- Thumbnails: source TBD (backend render, client-side render cached under `user://`, or an icon and
  name fallback). Fallback must exist so the feature does not depend on thumbnails.
- Conflict to handle: a laser-grip on a panel currently carries the whole panel
  (`_try_grab_panel_at_distance`); a thumbnail tile has to claim the grip before that.

## 4. Picking a sub-assembly

Today picking is at part level. Rooms need a way to grab or select a *group*. Vocabulary: **corner
brackets on a bounding box mean "this is a group"** (the same shape as the drop cue and the resize
brackets). Group membership comes from the occurrence tree (see "Data prerequisite").

### 4.1 Grip: latch, cycle, commit (right hand)

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

**Dead zone**

- Purpose: a part must not move relative to its siblings while the user is choosing what to grab.
- Applies **only** to grabs of a part that has an ancestor below the root; a top-level part grabs
  exactly as today.
- **Translation only**, default about 2 cm of hand travel (settings: Off / Small / Medium). There is
  deliberately no rotation threshold: clicking the trigger twists the wrist, and a rotation limit
  would commit by accident. The part does not rotate while latched either; the rotation difference
  is absorbed at commit.
- **Shown as a faint sphere with soft edges** centred on the latch point, radius equal to the dead
  zone, so you can see your hand marker is still inside it. It brightens slightly as the hand nears
  the edge, and fades out on commit. Unlit, alpha falling off towards the edge (no screen
  texture); optional in settings.
- The hand travel inside the zone is dropped by **rebasing the grab offset at commit**, so nothing
  jumps; the steadiness filter is reset at commit.
- Nothing is sent to the mate solver, and no backend call is made, until commit
  (`mates_tool.constrain_drag` only starts after it).
- v1: cycling is only possible inside the dead zone. After commit, release and re-grab to change
  level. (A later version could allow widening mid-carry by reverting the child to its pre-grab pose.)

**Conflict with the tool wheel (verified in `controller.gd`).** The right hand's trigger + grip
pressed within 250 ms (`wheel_window_ms`) open the tool wheel; the first press of that pair has already
begun a grab/select, and `cancel_for_wheel()` undoes it. Resolution:

- Keep the chord as is. A trigger click 250 ms or more after the grip is a cycle click. Because the
  part has not moved during the latch, a chord that cancels a just-begun grab is also cleaner.
- Today a trigger press while the grip holds a part falls through to laser `_try_select()`. While a
  grip is latched, the trigger must be consumed by the cycle logic instead.
- Risk: a user who presses both quickly gets the wheel. If that proves annoying, suppress the chord
  when the hand is touching a nested part.

### 4.2 Laser: hold-for-breadcrumb (right hand)

For a part that has ancestors below the root:

- **Tap** the trigger (release within about 250 ms): selects the part exactly as today (and a tap on
  the already-selected part deselects). For nested parts the select/deselect action therefore fires on
  *release*; top-level parts still act on press.
- **Hold** the trigger: a **breadcrumb of assembly levels** opens at the hit point, billboarded to the
  user and offset to one side so it does not cover the part, with constant apparent size so it is
  readable at the laser's 8 m range. One chip per level (part, parent, ..., top-level assembly).
- **Aim the laser at a chip**: the laser stops on the breadcrumb (the existing `ui_hit_distance`
  convention) and that level's bounding box lights up with corner brackets in the scene, previewing
  the scope.
- **Release over a chip** to select that level. Release over nothing keeps the part-level selection
  (or cancels, if it was a deselect).
- Deep trees: the right thumbstick scrolls the breadcrumb, as it does other panels.
- The chosen level also applies to the laser tools that act on a part: **Shoot hide** (hide a whole
  sub-assembly), **Paint** (colour a group; the Colours tab already has a "whole group" option) and
  selection. It does not apply to **Mates / Measure**, which pick faces, edges and vertices.

### 4.3 Other routes

- **Tree**: tapping a sub-assembly row selects it as a group (today it reports "no geometry of its
  own"). Grip then moves the group.
- Inside a room the root is the room's assembly, so "top-level" resets there; mates operate on the
  room's top-level occurrences (README: mates pick top-level occurrences of the loaded root).

### 4.4 Data and code prerequisites

- `assembly-mesh.glb` nodes are **flat, one per placed instance, with only `occurrence_id` and
  `owner_part_id` metadata and no hierarchy** (`mesh_identity.gd`). Group membership has to come from
  the occurrence tree (`GET /parts/{id}/occurrences`, already used lazily by the tree window), fetched
  fully and cached to map a leaf `occurrence_id` to its ancestor path. Confirm whether the flat glb
  contains nested leaves with baked transforms.
- Moving a group means moving every leaf node of that group by the same delta on the client and
  persisting the *sub-assembly occurrence's* transform on the backend.
- `controller.gd` assumes a selected or held thing is a single `MeshInstance3D` (`selected_node`,
  `held_node`, `part_centre` via `get_aabb()`, `_pivot_local`, thumbstick rotate, A/B nudge). A group
  needs a **selection target abstraction** (a proxy node or small class that applies a transform delta
  to all members and reports a union bounding box) so the same grip/rotate/nudge code works on groups.

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
  crossing a wall. (Dropping a *new* item into a room via section 3 is the sanctioned way in.)

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

`max_rooms` (default 4) · grab dead zone (Off / Small / Medium) · dead-zone sphere · glass wall
effect · proximity grid fade · pedestal · room colours · chevron animation · preview pulse · default
clip mode · auto-update world preview · file thumbnails. Group the aesthetic ones under the existing
Settings > Appearance effects switch.

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
- The trigger's select path (`_try_select`) acts on press; the laser breadcrumb needs
  press/hold/release handling for nested parts (section 4.2).
- Panels already claim the laser via the `ui_hover` / `ui_hit_distance` meta; the breadcrumb and a
  thumbnail tile reuse this.
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
4. **Transparency sorting** between glass walls, the section disc, highlights and the dead-zone
   sphere.
5. **Measurements and typed values** stay in real millimetres regardless of room scale.
6. **Float precision**: room-local origin helps with large models.
7. **Backend sessions**: mates and meshes seem keyed by part id, so a sub-assembly Part should open
   as a second root, but rooms with unrelated files probably need their own document session
   (`X-Document-Session`; today everything lands in the "default" session). Confirm.
8. **Save as...** needs a way to create a part and re-point one occurrence; confirm the endpoint
   exists or is needed in DIDSA-CAD.
9. **Group moves and group selection** (section 4.4).
10. **Drop-to-add backend support**: confirm `POST /parts/{id}/add-component` can take a placement
    transform (or whether a follow-up PATCH is needed), and that an added occurrence can be removed
    for undo. Large files take time to load: proxy placeholder.
11. **Thumbnails**: no known source yet; fallback icon required.

## 11. Phasing and plan-phase tasks

- **R0 spike (first)**: multi-box clip (discard vs stencil) with both polarities; picking and grip
  respect the clip; headless test; performance check on a headset/PCVR. Alongside it, the
  `main.gd` singleton audit and a read of the design-table scripts.
- **R1**: tree "Room" button, fixed 3 m room, scale, grab handle, close; any part/assembly as root.
- **R2**: draggable walls, Fit, glass look, room colour, tabs, carry-to-room chevrons (open / add,
  carrying world items into rooms; scale easing across the wall).
- **R3**: room console + pedestal, per-room tool/undo scoping, wrist-tablet retargeting, group
  selection (grip cycle with dead-zone sphere, laser breadcrumb, selection target abstraction), group
  moves.
- **R4**: multiple rooms (cap setting), minimise (snow-globe scale), world preview for table and
  room, dirty-mate propagation.
- **R5**: payload system: tablet file thumbnails, pull rows out of the tree, drop onto room / world /
  table with placeholder proxies.
- **Later**: Save as..., cross-room part moves, mid-carry widen, in-context mating, per-room
  environment, multiplayer (a room per person).

## 12. Open questions

- Carrying a world item into an occupied room copies it (original stays). Should there be a way to
  *move* it instead (for example holding a button), or is copy-only right for v1?
- Thumbnail source (backend render, client render cached locally, or icon fallback only for v1).
- Wall-drag minimum size value.
- Whether the breadcrumb should open at the hit point (proposed) or at the hand.
