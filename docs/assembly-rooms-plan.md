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

## R1: a fixed room you can open a sub-assembly into

Goal: tree "Room" button on a sub-assembly row opens a 3 m room, with that sub-assembly's meshes inside it, clipped, with the world
clipped around it. No wall dragging, no console yet.

1. `scripts/room/room.gd`: a `Node3D` per room: content root, `RoomVolume`, scale, close. Mirrors the replace/reset sequence in
   `main.gd._show_model`, but for its own root. Registers with `RoomRegistry`, tags parts with `RoomClip.assign`.
2. Fetch a sub-assembly's mesh by part id (`GET /parts/{sub_id}/assembly-mesh.glb`) and tag it with `MeshIdentity` as now.
3. Seed handling: hide (or ghost) the world's copy of the opened occurrence while the room is open; restore on close.
4. Call `RoomClip.reconcile` once a frame from `main.gd._process` while rooms exist, over `_arena_parts()`.
5. Propagate `room_slot` to edge lines and highlight overlays (`view_modes.gd`, `face_highlight.gd`).
6. Wire `LaserPick`/grip filters for the design-table path if its picks can meet room parts (check `table_editor.gd`).
7. Tests: room open/close restores the world; headless like `tests/section_tool.gd`; a render check with real glTF nodes.
8. Settings: `max_rooms`.

## R2 to R5

As in the scope document, section 11. Each needs the previous; R3 (per-room tool and undo scoping, group selection) is the
largest piece and should get its own plan once R1 has shown how much of `main.gd` has to move.

## Immediate next steps

1. Run the R0 clip on a headset or PCVR with 1, 4 and 8 rooms and a real assembly; record GPU ms (Settings > Display already shows it).
2. If it is too slow, spike the stencil variant behind the same registry API (nothing above the shader changes).
3. Start R1 once the cost is known to be acceptable.
