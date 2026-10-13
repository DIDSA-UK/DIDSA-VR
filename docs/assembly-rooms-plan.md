# Assembly Rooms: plan

Scope and decisions: [`assembly-rooms-scope.md`](assembly-rooms-scope.md). This file is the build plan and the
record of what each phase found. Phases are scope > plan > implement; R0 is implemented.

## R0: clip spike (done, headless- and software-render-confirmed; not on a headset)

### What was built

| Piece | File | What it does |
|---|---|---|
| Room box shader test | `shaders/clip_common.gdshaderinc` | A third clip next to the section plane and the sketch-window box. A material's `room_slot` says where it lives: `>= 0` a room (shown only inside that box), `-1` the world (hidden inside every box), `-2` (default) ignore rooms. Rooms arrive as one small float texture (`room_clip_tex`, one row per room), so the room count is not baked into the shader. `room_clip_count == 0` costs one comparison. |
| Globals | `scripts/clip_globals.gd` | Registers `room_clip_count` and the `room_clip_tex` sampler (16 rows x 4 texels RGBAF). |
| Volume | `scripts/room/room_volume.gd` | Oriented box maths: contains, overlap (separating axes), the 3 m spawn minimum and 0.5 m drag minimum. Scale in the transform is dropped (walls are never scaled). |
| Registry | `scripts/room/room_registry.gd` | Static list of rooms with stable slots, `max_rooms` cap (default 4, clamped to 16), no-overlap on add, `pack_image()` / `push()` for the shader, and `part_visible_at(part, point)` for picking. |
| Part wrapping | `scripts/room/room_clip.gd` | `assign`/`release`/`reconcile`: puts parts under `section_clip.gdshader` with their colour and slot, and gives them their own material back. |
| Picking | `scripts/laser_pick.gd`, `scripts/controller.gd` | `LaserPick.ray` takes an optional point filter (a cut-away spot is skipped like a hidden part); the controller's laser and `_find_grab_target` use it. No rooms: behaviour unchanged. |
| Section tool | `scripts/section_tool.gd` | `_wrap` adopts a part already wearing the clip material instead of replacing it (which would lose its slot and colour). |
| Tests | `tests/room_clip.gd` (36 headless checks), `tests/room_clip_render.gd` (real shader, Xvfb + Mesa) | Registered in `run_all.sh` / `ci_render.sh`. |

### Results

- **The texture-based clip works with the real shader** on the project's renderer (Godot 4.7.2, Mobile, under Mesa software
  rendering): two rooms at once, a room that moves (texture updated in place), a removed room (world comes back through the hole,
  its orphaned content disappears), a part that ignores rooms, and a return to normal with no rooms.
- **Picking respects the clip**: a laser through a cut-away world wall picks the room part behind it; a room part outside its walls
  cannot be picked; a grip cannot take a cut-away part; with no rooms the old behaviour is identical.
- **The cap is a setting**, not baked in: the shader loops to `room_clip_count` (max 16).

### Not verified (needs a headset / GPU)

- **Performance on Quest or a PCVR GPU.** Software rendering says nothing about cost. The world pays a loop over the rooms per
  fragment; the room content pays one lookup. Measure with rooms at 1, 4 and 8 on the target hardware.
- **The stencil alternative was not spiked** (Godot 4.5+ material stencil). The discard approach is correct and cheap to read, but
  discard defeats early-z on tile-based GPUs; if the headset measurement is bad, try stencil: write a mask per room, test it in world
  and room materials.
- Edge lines (`edge_lines.gdshader`) and hover / selection overlays (`highlight_clip.gdshader`) include the same clip code but are
  separate nodes with their own materials, so they do not yet get a `room_slot`. Needed in R1 (view_modes.gd and face_highlight.gd
  copy the part's slot, the way they already copy the sketch-window switch).
- Transparency sorting with glass walls (R2).

### Audit findings (main.gd and neighbours)

- **One model**: `assembly_root` (a single `Node3D`, mm->m scale 0.001 at `spawn_position`) holds the whole loaded glTF.
  `_show_model` replaces everything under it, clears the single `command_stack`, resets the section tool, marks the tree windows
  stale and resets both hands. A room therefore needs its own root node, its own `command_stack`, and its own copy of that
  replace/reset sequence.
- **Global part registry**: all 24 uses of the `grabbable_parts` group (controller, mates, view modes, ...) assume one flat arena.
  `main.gd._arena_parts()` filters `on_table`. Rooms keep parts in the same group (so grip and laser work unchanged, filtered by
  `RoomRegistry`) but each part carries its `room_slot`; per-room operations (hide all, isolate, mates refresh) filter by it.
- **Whole-model gestures** (`two_hand_model.gd`) move and scale `assembly_root`. In a room the same gesture must act on that room's
  content root (focus rule: the room containing the hand), and room scale pivots on the room centre.
- **Mates** use `_resolved_part_id` (the loaded root part) and top-level occurrences of it; a room needs its own root part id, and
  probably its own document session (`X-Document-Session`) when its root comes from an unrelated file.
- **Tools are singletons** on `main.gd` (`_mates_tool`, `_measure_tool`, `_colour_tool`, `_section_tool`): one section gizmo, one
  tool mode. Per-room state means either one tool instance per room or tool state keyed by the focused room.
- **Design table** (`design_table.gd`) reaches into `_main.assembly_root` directly for seating; it keeps working on the world and is
  not changed.
- **Occurrence tree**: `assembly-mesh.glb` is flat, leaf instances only, with `occurrence_id` / `owner_part_id`; group membership
  comes from `GET /parts/{id}/occurrences`.

## R1: a fixed room you can open a sub-assembly into (done, headless- and software-render-confirmed; not on a headset)

Goal: a **Room** button on an Assembly Tree row opens that Part in a 3 m room in front of you, with the content scaled to fit, clipped
to the walls, and the world clipped around it. A viewer for now: no wall dragging, no console, no editing inside the room.

### What was built

| Piece | File | What it does |
|---|---|---|
| Room | `scripts/room/room.gd` | A `Node3D` at the box's centre holding the Part's own `assembly-mesh.glb` (parsed and identity-tagged exactly like the world's), a coloured wireframe for the walls, and a `content_root` carrying the room's scale. Opens fitted to 70% of the room on its tightest axis, content middle at the room middle. `scale_text()` ("4.2:1"). |
| Manager | `scripts/room/room_manager.gd` | Fetches a Part's mesh, opens/closes/toggles rooms, hides the world's copy while a room is open and restores it on close, reconciles the clip every frame while rooms exist, closes everything when the world's model is replaced. Respects the `max_rooms` limit with a message. |
| Placement | `scripts/room/room_placement.gd` | In front of the user on the floor, turned to their heading (flattened), clear of every other room; tries along the user's sides and further out; null if nothing is clear. |
| Per-instance slot | `shaders/clip_common.gdshaderinc`, `scripts/room/room_clip.gd` | `room_slot` is now an `instance uniform` (set on the MeshInstance3D), so a part's faces, its **edge lines** and its **hover / pick overlays** all carry it without separate materials. `view_modes.gd` and `face_highlight.gd` sync it. |
| Tree button | `scripts/assembly_tree_window.gd` | Rows get a **Room** button (reads **Close room** while open). Not on the root row. Rows now know their parent Part (how the world's copy is found). |
| Setting | `scripts/app_settings.gd`, `scripts/main.gd`, `scripts/ui/tablet_pages.gd` | `max_rooms` persisted; Settings > Display > Max rooms (1, 2, 3, 4, 6, 8). |
| Tests | `tests/room_manager.gd` (29 headless), `tests/room_render.gd` (real shader), extended `tests/assembly_tree_window.gd` | Registered in `run_all.sh` / `ci_render.sh`. |

### Decisions made while building (please check)

- **How the world's copy is found.** The backend walks the whole tree and tags every node with its *immediate parent Part* (`owner_part_id`)
  and the Occurrence that placed it (`router.py`, `_walk_assembly_glb_instances`). So the nodes to hide are those owned by the opened
  Part or any Part nested in it, plus its own geometry (owner = its parent, occurrence = the one opened). If the **same Part is placed more
  than once, all its placements are hidden** while a room is open: a room edits the shared definition, and the later Preview feature
  shows the instances updated. Distinguishing individual instances would need the JSON endpoint's `occurrence_path`.
- **Room parts are in `room_parts`, not `grabbable_parts`**, and have no collision, so R1 is a viewer. This is a temporary guard, not a
  design choice: the room is meant to be a world within the world with the same manipulation. What actually blocks parity (checked in
  the code, and corrected from an earlier, overstated note that said a move would "write a wrong pose"):
  `mates_tool.persist_pose` only saves a part that `is_managed()` says is a top-level occurrence of the single loaded root Part
  (`_current_owner_part_id`). A room part's owner is the room's Part, so a move would be **refused silently: shown, but never saved**
  (a save, which exports the backend's document, would lose it). Nothing is corrupted. The save path itself is right for a room: in a
  room glb the room's Part is the root, so a child's node transform is exactly the owner-relative transform the backend stores.
  What is missing is that the tools hold ONE root (`_current_owner_part_id`, `occurrences`, `mates`) instead of the focused room's.
  See "R2: interaction parity" below.
- **The room is always the 3 m cube** and the content is scaled to fit it (so a 100 mm part opens at about 21:1, a 12 m assembly at about
  1:6). The spawn size rule `max(3 m, content + margin)` is in `RoomVolume.spawn_size`, but content is always fitted, so it never grows.
- **Close from the Assembly Tree** (button toggle) for now; the room console that will own Close, scale and bounds is R3.

### Not done / not verified

- On a headset: placement comfort, the wall wireframe's visibility, the clip cost (still the R0 open item).
- Real backend round trip (`tests/e2e_*` style): the mesh fetch reuses `main.gd._get_mesh_result`, but opening a room against a live backend
  was not run here. The DIDSA-CAD backend source was read (not run).
- Walls are a plain wireframe; the glass look, proximity grid, room colour on tabs and corner brackets are R2.
- Wall dragging, scale control, grab handle for the room: R2/R3.
- `Show all` (Tools tab) will re-show the hidden world copy under an open room; harmless but untidy.
- The design table's tree has no Room button (its `_add_row_actions` is its own).

## R2: interaction parity (next; replaces the old R2 to R5 ordering)

The room is a world within a world: grab to move, two-hand to turn and scale, A/B to send and retrieve, select, hide, undo, all inside it. Do
this before the glass look and wall dragging, because it decides how the rest is built.

1. **Parts become grabbable in rooms** (join `grabbable_parts` with collision). Picking and gripping already respect the walls (R0).
2. **Persistence per room**: `mates_tool` (and colour / measure) take the owner Part from the part itself, not a single global: a top-level
   occurrence of ITS room's root is managed; nested ones stay unmanaged exactly as in the world today.
3. **Whole-room gestures**: `TwoHandModel` already takes any root node, so each room gets its own instance on `content_root` (own scale
   limits). A grip on empty space goes to the room containing the hand, else to the world (a focus filter on `_hand_free`); one hand
   moves the content, two hands move / turn / scale it about their midpoint. Room scale is therefore the content scale.
4. **Room-scoped group operations**: Hide all / Show all / Reverse / Isolate, undo, tool modes act on the focused room.
5. **Send / retrieve** across the wall: the drop-to-add flow from the scope document, plus parts pushed out of the walls clipping and
   snapping back.
6. Mates, Colours, Sections, Measure per room (the focused room's root).

Then the old R2 (draggable walls, grab handle, scale control, glass look, tabs), R3 remainder (console, group selection), R4 and R5 as in
the scope document, section 11.

## Earlier R2 to R5 notes


As in the scope document, section 11 (R2 now also takes: the room grab handle, wall dragging, the scale control, the tab list). Each needs the previous; R3 (per-room tool and undo scoping, group selection) is the
largest piece and should get its own plan once R1 has shown how much of `main.gd` has to move.

## Immediate next steps

1. Run the R0 clip on a headset or PCVR with 1, 4 and 8 rooms and a real assembly; record GPU ms (Settings > Display already shows it).
2. If it is too slow, spike the stencil variant behind the same registry API (nothing above the shader changes).
3. Try R1 on a headset: open a sub-assembly from the Assembly Tree, walk round the room, close it; report what feels wrong (size, distance,
   wall visibility) before R2 builds on it.
