# `main.gd` split audit (P0)

Part of P0 of DIDSA-CAD `docs/mates-storage-sessions-plan-2026-11-12.md` ("P0. Scope and three spikes"). Written 2026-11-18 from
`main` at `095ad2f`. **Read and counted only: no code was changed, and nothing was built, exported or run on a headset or phone.**
The session protocol it serves is DIDSA-CAD `docs/live-sessions-scope.md`; the spikes are in [`live-sessions-spikes.md`](live-sessions-spikes.md).

The question (plan, P0): which of `scripts/main.gd`'s lines are **viewing** (scene, glb, environment, clip) and which are **Quest
input**, and what a **view-only build** (the phone observer, D8: same project, a second Android export) must not load.

## 1. The count

`scripts/main.gd` is **2,865 lines** (`wc -l`), not the 2,457 the plan quotes (the file has grown since 12 Nov). It has 217 functions.

**How it was counted.** Every line belongs to the function it sits in, from its `func` line to the line before the next `func`, so
the blank lines, comments and the odd `const` between two functions count with the one above (this moves a category by a dozen lines
at most). Each function was put in one category by reading it. The 147 lines of declarations before `_ready()` and the 78 lines of
`_ready()` itself were classified line by line by what they name. Five categories, because most of the file is neither viewing nor input:

| Category | Lines | Share | What it is |
|---|---:|---:|---|
| **Viewing** (scene, glb, environment, clip, render settings) | **587** | 20% | Fetch / parse / show the glb, swap a part's mesh, unload, place the model, visibility, the section clip and view modes set-up, environment and passthrough scenes, MSAA / render scale / foveation / shadows, graphics overrides |
| **Quest input and the XR rig** | **368** | 13% | `_start_xr`, the desktop camera, the two-hand model, the tool wheel, wrist tablet, popup keyboard, face-highlight wiring, selection through `RightController`, the tree-row select / isolate paths, group dead-zone, the perf readout (it draws on the tablet) |
| **Editing tools** (presenter only) | **326** | 11% | Mates, drive, measure, appearance and scenes tool set-up, Assembly Rooms and their settings, the design table, new assembly / blank part, stale mates, hidden features |
| **Files, import, storage and servers** | **1,322** | 46% | Native open / compose / references, STEP / IGES / STL / OBJ import, project folder and All files access, server projects (cloud), secrets and the server list, unsaved changes and discard, save |
| **App shell** | **252** | 9% | Settings getters / setters (theme, sound, haptics, reduce motion), the landing, windows (tree, calculator, images, browser), status text |
| (blank lines in the declarations and `_ready`) | 10 | | |
| **Total** | **2,865** | | |

So the file is **not** mostly input: hand input lives in `controller.gd` (1,548 lines) and `two_hand_model.gd` (423). Nearly half of
`main.gd` is the file and server plumbing a view-only build has no use for.

`_ready()` (78 lines) alone: viewing 9, Quest input 24, editing 15, files and servers 12, shell 16, blank 2. It builds **every**
subsystem unconditionally, which is the first thing a split has to change.

### Viewing (587 lines), by function

`_show_model` 70, `swap_part_mesh` 39, `reload_world_model` 33, `_on_mesh_completed` 29, `mesh_from_glb` 29, `unload_model` 28,
`_blank_out` 26, `load_glb_file` 22, `_apply_graphics_overrides` 21, `_set_all_visibility` 17, `_get_mesh_result` 17, `_claim_load` 14,
`current_root_part_id` 14, `_http_error_text` 13, `_make_picks_double_sided` 13, `reverse_visibility` 12, `passthrough_status` 12,
`_fetch_mesh` 12, `set_render_scale` 9, `_add_section_tool` 8, `set_foveation_level` 8, `_all_descendants` 8, `_add_view_modes` 7,
`place_model` 7, `foveation_level` 7, `_arena_parts` 6, and 13 four- or five-line getters / setters (shadows, MSAA, scenes, hide / show
all), plus 38 declaration lines and 9 lines of `_ready`.

### Quest input and the XR rig (368 lines), by function

`_add_tool_wheel` 36, `select_tree_row` 30, `_process` 30 (the perf readout on the tablet), `_add_face_highlight` 22,
`select_part_by_occurrence_id` 19, `set_tree_row_visible` 18, `_start_xr` 15, `_push_visibility_command` 15, `tree_row_nodes` 14,
`isolate_tree_row` 14, `_spawn_desktop_camera` 13, `isolate_selected` 13, `_add_popup_keyboard` 12, `open_keyboard_for` 11,
`_on_right_stick_click` 9, `_add_two_hand_model` 8, `_add_wrist_tablet` 7, `current_selected_part` 7, `_on_scale_typed` 6, and the
group dead-zone and wheel settings (35 lines), plus 9 declaration lines and 24 lines of `_ready` (the controllers' wiring).

## 2. Why the viewing lines cannot be lifted out as they are

The viewing functions call straight into the tools. A view-only build that loads only them would fail at the first load:

1. **`_show_model`** (the one path every model takes) calls `_appearance_tool.forget`, `scenes_tool.forget`, `room_manager.on_model_replaced`,
   `command_stack.clear`, `design_table.on_model_replaced`, `_mates_tool.clear_picks` and `refresh_state`, `_section_tool.reset`, two
   tree windows' `mark_stale`, both controllers' `reset_interaction`, `_two_hand.set_real_life_scale`, `landing.on_model_shown`,
   `room_manager.index_world`, `restore_stale_mates` and `mark_clean`. `unload_model`, `swap_part_mesh` and `reload_world_model` do the same.
2. **`create_trimesh_collision()` on every mesh** in `_show_model`: needed for the laser (and later the drone cursor), but a cost in load
   time and memory on a phone. The Cardboard spike measures load with and without it.
3. **Visibility pushes undo steps** (`_push_visibility_command` → `command_stack`) and scopes through `room_manager.scope_parts`
   (`_arena_parts`). An observer's visibility comes from the stream, and its own-view hide (P4) must not touch the presenter's history.
4. **Selection belongs to the controller**: `select_part_by_occurrence_id` and `select_tree_row` call `$XROrigin3D/RightController`.
5. **`view_modes.gd` preloads `room/room_clip.gd`** (and through it `room_registry.gd`): Assembly Rooms code inside the view layer.
6. **`section_tool.gd` is the clip and the hand gizmo in one** and preloads `two_hand_model.gd`. The clip itself is `clip_globals.gd`,
   `clip_look.gd` and `shaders/section_clip*.gdshader`: a world-space plane set as a global shader uniform. An observer needs only that.
7. **The backend client always sends the key**: `backend_session.gd` `headers(api_key, ...)` adds `X-API-Key` and `X-Document-Session`.
   An observer has neither; it sends `X-View-Token` (scope doc, section 5).
8. **`set_render_scale` and the foveation functions assume OpenXR** properties (`render_target_size_multiplier`, `foveation_level`); with
   Godot's built-in `MobileVRInterface` the equivalent is `oversample`.
9. **`project.godot`'s `.android` overrides** (Meta passthrough, spatial entities, marker tracking) apply to **every** Android export,
   the phone's included; and `xr/openxr/enabled=true` has no override. The phone preset needs its own custom feature tag (for example
   `phone`) with `xr/openxr/enabled.phone=false` and the `.android` ones set back to false, and the OpenXR Vendors plugin must be off
   in that preset. Whether Godot 4.7 honours a custom-tag override of `xr/openxr/enabled` at start-up is **not verified**: the Cardboard
   spike checks it first.

## 3. What a view-only build must not load

From `scenes/main.tscn`, the literal `preload` / `load` closure reaches **179 of the 186 scripts** in `scripts/` (**56,455 lines**),
plus 16 shaders. There are no `class_name` scripts and no script loaded by a computed path, so this closure is the whole
of it. The columns: the script's own lines, then its closure (everything it pulls in; closures overlap, so they do not add up).

| Must not load | Own | Closure | Why |
|---|---:|---:|---|
| `controller.gd` (both hands, on `XRController3D` nodes in `main.tscn`) | 1,548 | 3,491 | All hand input: grab, laser, tools, groups. A phone has no tracked controllers; P5 maps a gamepad instead |
| `locomotion.gd` (on `XROrigin3D` in `main.tscn`) | 174 | 174 | Reads the XR controllers' sticks. Replace with a gamepad mover |
| `two_hand_model.gd` | 423 | 469 | Whole-model move / turn / scale; an observer uses the presenter's place (scope LS-6) |
| `ui/wrist_tablet.gd`, `ui/tablet_pages.gd` | 487 + 2,072 | 13,461 | The wrist tablet and every page; pulls in most of the app |
| `ui/tool_wheel.gd`, `ui/wheel_flows.gd` | 832 + 622 | 1,369 / 1,293 | Right-hand radial menu |
| `popup_keyboard.gd` | 613 | 1,581 | Hand-typed keyboard |
| `face_highlight.gd` | 370 | 1,115 | Laser hover / picks for mates and measure (P4's drone cursor may bring a lighter one back) |
| `mates_tool.gd`, `drive_tool.gd` | 3,699 + 362 | 6,561 / 735 | Editing |
| `measure_tool.gd`, `measure_dimensions.gd` | 226 + 145 | 419 | Calls the backend's measure routes, which a view token cannot (P4 must make an observer's measure client-side or leave it out) |
| `design_table/design_table.gd` | 1,508 | **29,632** | The design table and everything under it |
| `room/room_manager.gd` | 1,147 | 11,988 | Assembly Rooms (not mirrored in v1) |
| `scenes_tool.gd`, `appearance_tool.gd` | 707 + 577 | 1,156 / 1,299 | Editing; their effect reaches observers as poses, visibility and refetched looks |
| `section_tool.gd` | 441 | 1,032 | The hand gizmo. Keep only the clip (below) |
| `assembly_tree_window.gd`, `calculator_window.gd`, `image_viewer_window.gd`, `browser_window.gd` | 725 + 119 + 166 + 441 | | Windows driven by the laser; the tree reads `/parts/{id}`, which a token cannot |
| `cloud/cloud_manager.gd`, `cloud/cloud_paths.gd`, `project_save.gd`, `native_compose.gd`, `project_folder.gd`, `thumbnail_store.gd`, `landing/recent_file.gd`, `design_table/dirty_mates.gd`, `design_table/new_document.gd` | | 3,037 (cloud) | Files and storage: an observer never opens, imports or saves a file (scope section 7) |
| `landing/landing.gd` | 285 | 3,286 | The Quest landing; its QR scanner uses OpenXR marker tracking. The phone gets its own small join screen |
| `landing/server_store.gd`, `server_probe.gd`, `server_address.gd` | 154 + 44 + 165 | | An observer has no server list: the hub hands it the backend address and a token |
| `command_stack.gd`, `group_index.gd` | 90 + 256 | | Undo (editing) and sub-assembly selection (P4 may bring `group_index` back for the breadcrumb) |
| The OpenXR Vendors plugin and OpenXR itself | | | Off in the phone preset (section 2, point 9) |

**What it keeps (the viewing core):** `mesh_identity.gd`, `environment_manager.gd` (its passthrough branch unused), `view_modes.gd` with
`edge_overlay.gd`, `clip_globals.gd`, `clip_look.gd`, `app_settings.gd`, `ui/ui_themes.gd`, `graphics_overrides.gd`,
`backend_session.gd` (with a token variant), and the grid, edge and section-clip shaders: **16 files, 1,389 lines** by the same closure,
of which `room/room_clip.gd` and `room/room_registry.gd` come only through `view_modes.gd` (point 5) and should be cut. Plus `main.gd`'s
587 viewing lines once the calls in section 2 are gone, and the new pieces P2 / P5 write: the session client, the avatars, the phone
camera rig and the gamepad input.

## 4. The split this points to (for P2 and P5; not done here)

1. **Move the viewing lines into `scripts/view/model_view.gd`**: load bytes into a tagged scene under `AssemblyRoot`, swap a part's
   mesh, unload, apply a pose table and a hidden list, place the model, set the clip plane. It **emits signals** (`model_replaced`,
   `part_mesh_swapped`, `model_unloaded`) instead of calling the tools; `main.gd` connects the tools to them. This is the change that
   makes everything else possible, and it is a pure refactor the existing headless and render suites guard (they drive `main.tscn`).
2. **P2 (Quest observer)** runs the full app with the role deciding which tools exist (the plan: "the same app; the role decides").
   The session client hooks in at: `poses` from `controller.gd`'s grab and `_sync_pose` and from the mates glide; `visibility` from
   the hide / isolate paths above; `section` from `section_tool.gd`; `place` from `two_hand_model.gd`; `doc_changed` wherever
   `reload_world_model` / `swap_part_mesh` run today (they are already the "the document changed under the world" points).
3. **P5 (phone)** gets its own main scene, `scenes/viewer.tscn` + `scripts/viewer.gd`, that loads only the viewing core, the session
   client, the phone rig and gamepad input, and an export preset with the `phone` feature tag. Nothing in section 3's table is
   preloaded from it, so it is not loaded (the scripts may still be in the APK unless the preset's export filter excludes them; that is
   a size question, not a correctness one).

## 5. Not verified

- The categories are a reading, not a measurement; a different reader would move a few dozen lines between "viewing" and "input"
  (the tree-row and visibility functions sit on that line).
- No view-only scene was built, so it is not shown that the viewing core runs without the rest.
- Whether a custom feature tag can switch OpenXR off for one Android preset in Godot 4.7: the Cardboard spike's first step.
