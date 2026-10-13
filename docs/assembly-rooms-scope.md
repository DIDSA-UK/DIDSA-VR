# Assembly Rooms: scope

Status: scoping (scope > plan > implement). Written from a design conversation plus a read of
`README.md` and `docs/design-table-brief.md`. **No source code was read**; every statement about
internals below is an inference to be confirmed by the plan phase's audit (see "Plan-phase tasks").

## 1. What it is

An **Assembly Room** is a finite volume of space that behaves like the world, but holds a
different assembly. Analogy: a browser tab.

- The **design table is for parts; the room is for assemblies**: sub-assemblies at any level of the
  tree, or any other assembly opened side by side for comparison.
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
| Table vs room | Table = parts. Room = sub-assemblies / other assemblies. Table stays separate. |
| Concurrent rooms | Multiple rooms in v1. **Cap 4**, held in one setting (`max_rooms`, user adjustable). |
| Overlap | **No overlapping rooms.** Spawn and wall-drag refuse or push apart. |
| Nesting | **No rooms inside rooms.** Sub-assemblies at **all levels** can be opened in rooms in the world. |
| Wall shape | Oriented box, axis-aligned in room space, movable as a whole by a grab handle. |
| Minimum size | A **new room is at least a 3 m cube**, and at least fit-to-contents + margin if larger. (A separate, smaller minimum applies to later wall-dragging; value TBD, ~0.5 m.) |
| Shared definition | Editing in a room edits the shared definition: all instances update. |
| "Make unique" | Is a **Save as...** path: write the room's assembly to a new file/part and re-point *that one instance* at it. Others keep the old definition. |
| Aesthetics | Functionality first. Purely aesthetic or heavy effects are individually optional in Settings. PCVR is the baseline target; Quest is not a constraint on v1. |
| Persistence | Room layout (bounds, scale, position, colour) is session/settings state, **not** stored in `.didsa`. A room is a view construct, which keeps native files cross-compatible with the flat app. |

## 3. Room lifecycle and entry

A room can exist **empty** (like the design table, which is summoned first). Ways in:

1. **Tree button**: a **Room** button on a sub-assembly row (like the existing **Table** button on
   parts). Spawns a room and loads that sub-assembly in one step.
2. **Summon room** from the wrist tablet, then carry an item in.
3. **Carry / send**: grip an item and carry it, or push it with A/B while gripped, into a room
   volume. While the item's centre is inside a room that can accept it, **cubic corner chevrons at
   the item's bounding-box corners** (and a brightened wall) show that releasing will *send it to
   the room*. Release loads it.
   - Occupied room: chevrons show a "busy" state and release is a no-op (swap via the console).
   - Dropping outside every room leaves the item as-is.
4. **Files > Open in room** for any assembly file (side-by-side comparison).

Spawn placement: a free spot in front of the user, outside other rooms and preferring to be outside
the loaded model's bounding volume; room boxes are never placed overlapping.

Opening scale: content is fitted to roughly 70% of the room's volume (the same idea as the table's
"scales to fit"), with a **1:1** button on the console. The 3 m minimum is the volume, not a scale.

## 4. Picking a sub-assembly (open UX)

Today picking is at part level. Rooms need a way to grab a *group*. Proposed vocabulary: **corner
brackets on a bounding box mean "this is a group"** (the same shape as the drop cue and the
resize brackets).

1. **Widen selection (primary).** While hovering or holding a part, a **left-trigger click widens
   the selection one level** up the occurrence path (part > sub-assembly > parent ... up to, not
   including, the root). A breadcrumb (`Bolt < Bracket < Drive unit`) shows on the right-wrist tip
   panel and corner brackets appear on the group's bounding box. Clicking again keeps widening; past
   the top it wraps to the part. Left trigger is currently unassigned.
   Works mid-carry: grip a part, widen, and the whole sub-assembly (one occurrence transform) comes
   with you.
2. **Tree (reliable).** Tapping a sub-assembly row selects it as a group (today it says it has no
   geometry of its own). Grip then moves the group.
3. **Pick-level filter (precision).** Parts / Sub-assemblies / Top-level toggle on the tool wheel or
   tablet, equivalent to a CAD selection filter.
4. Optional dwell-to-widen, off by default (risk of accidents).

Inside a room the root is the room's assembly, so "top-level" resets and mates operate on the
room's own top-level occurrences (matches the README: mates pick top-level occurrences of the
loaded root).

Needs: mesh nodes carrying their occurrence path (confirm in audit).

## 5. World preview ("push changes to world")

Hiding the world copy while editing loses context. Proposal, for **both table and room**:

**World copy states** per edited definition: *Hidden* (current) / *Ghost original* / *Preview*.

- **Preview** re-instantiates the edited definition at each world instance's *placed (mated)
  transform*, in a **preview colour** distinct from existing highlight colours (cyan, pale yellow
  and orange are taken; default violet/magenta). Mesh resources are shared, so cost is extra
  transforms, not extra geometry.
- **Push** is an explicit button ("Show in world"), plus an **auto-update** option. Transform-only
  edits (moving parts) are cheap and can be live; re-tessellated feature edits depend on the backend
  round trip and are throttled.
- If an edit made an instance's mates stale, the preview shows at the last-solved transform with a
  warning chip. The existing Enforce mates flow resolves it.
- A thin tether line from room to world instance, and a "fly to instance" action, tell the user which
  copy they are looking at.
- Not available for an "other assembly" room that is not an instance in the world (greyed).
- Implement as **one shared service** (e.g. keyed by definition id, subscribed to definition-change
  events) so table and room use the same mechanism.
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
- Parts carried past a wall are clipped and **snap back on release**. v1 never changes assembly
  membership by crossing a wall (a later explicit "move to parent" action may).

## 7. Room console

- A small panel built on `diegetic_panel`, **grab-movable**, holding room-only controls: scale,
  1:1, bounds / fit, clip mode (Hide / Ghost / Preview), world preview push, grid, instance count
  ("used 4x" so edits to a shared definition are not a surprise), Save as..., close / return.
- **Pedestal**: a faint, ghostly projection from the console down to the ground (a gradient-alpha
  column plus a floor ring, ground = world floor). Purely aesthetic, non-intrusive; optional.
- The console sits outside the volume and must not be clipped by any room.
- The **wrist tablet stays single** and retargets to the focused room. Mates / Measure / Sections /
  Undo / Colours act on that room, with a room chip in its status bar.
- **Focus rule**: the room containing the hand origin / laser hit owns input (cf. TABLE ACTIVE).
  Locomotion stays in world space. Scale pivots on the room centre, never the user's head; vignette on
  scale changes.

## 8. Settings (optional / cost-bearing)

`max_rooms` (default 4) · glass wall effect · proximity grid fade · pedestal · room colours ·
chevron animation · preview pulse · default clip mode · auto-update world preview. Group the
aesthetic ones under the existing Settings > Appearance effects switch.

## 9. Risks

1. **Picking vs clipping.** Ray tests hit real geometry; a shader clip does not change that. Every
   pick (laser, grip proximity, drop test) must test the hit point against the owning room's volume
   and continue the ray if outside.
2. **Clip technique and cost.** Discard-style shader (extends `section_clip.gdshader`) vs material
   stencil (Godot 4.5+, project is 4.7). Spike both. World materials must test every room volume;
   cost grows with `max_rooms`.
3. **Per-room state.** Main appears to own a single model, one shared undo history, one section
   gizmo and one global tool mode. These need to become per-room context.
4. **Transparency sorting** between glass walls, section disc and highlights.
5. **Measurements and typed values** must stay in real millimetres regardless of room scale.
6. **Float precision**: room-local origin helps with large models.
7. **Backend sessions.** Mates and meshes seem keyed by part id (`/parts/{id}/mates`,
   `assembly-mesh.glb`), so a sub-assembly Part should open as a second root, but "other assemblies"
   from different files probably need their own document session (`X-Document-Session`). Confirm.
8. **Save as...** needs a way to create a part and re-point one occurrence; confirm the endpoint
   exists or is needed in DIDSA-CAD.

## 10. Phasing (proposed)

- **R0 spike**: box clip (discard vs stencil), picking respects clip, singleton audit.
- **R1**: tree "Room" button, fixed 3 m room, scale, grab handle, close.
- **R2**: draggable walls, Fit, glass look, room colour, tabs, carry-to-room chevrons.
- **R3**: room console + pedestal, per-room tool/undo scoping, wrist-tablet retargeting, widen
  selection.
- **R4**: multiple rooms (cap setting), minimise (snow-globe scale), world preview for table and
  room, dirty-mate propagation.
- **Later**: Save as..., cross-room part moves, in-context mating, per-room environment, multiplayer
  (a room per person).

## 11. Plan-phase tasks

1. Audit single-instance assumptions in `main.gd` and friends (model, history, tool modes, section
   gizmo).
2. Read how the design table isolates its part from the world, to reuse it.
3. Confirm sub-assembly data (occurrence path on meshes, mesh by sub-assembly part id, mates scope).
4. Confirm backend needs for document sessions and Save as...
5. Run the R0 spike on a real headset/PCVR.

## 12. Open questions

- Drop of a *loose part* into a room: refuse, or open as a one-part assembly?
- Value of the wall-drag minimum size.
- Whether Preview should also colour changed parts differently from unchanged ones.
