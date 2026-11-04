# Test report on the 30 Oct build: fix plan

The owner tested the 30 Oct 2026 build on the Quest and sent five items (4 Nov 2026). This doc is the plan for the session that will build them.
Each item says what the code does now (with the file to start from), what to build, how to test it, and anything the owner still has to decide.
**Final, 4 Nov 2026: every owner decision is recorded below; nothing is left to ask before building.** Nothing in here has been built yet. Do the items in order, T1 to T6. They do not depend on each other, except that T2 uses the folder from T1 for **Open...**, and T6 builds on the no-tool hover and
selection from T5.

| # | Report | Size | Owner decision needed first? |
|---|---|---|---|
| T1 | Unclear where the app stores files; project folder on first run; change it in Settings | M | Decided 4 Nov: **B + C** |
| T2 | Clear "new / open" path on an empty room and an empty design table; first part fixed at the origin | M | Decided 4 Nov: rooms say *assembly*, the table says *part*; same files |
| T3 | Selecting a mate on the tablet highlights the two mated entities | S | No |
| T4 | Sketch canvas at the front edge of the table, hinged there, tilted back a little | S-M | No: start at 15° back from vertical; a Settings switch lets the owner compare |
| T5 | Sketch lines, dimensions and constraints selectable, for editing and deleting; hover highlight everywhere on the table | M-L | Decided 4 Nov: selectable with no tool chosen; hover on faces and edges too |
| T6 | Contextual options for a selection on the design table, with breadcrumbs (added 4 Nov) | L | Decided 4 Nov: a fixed-size drawer on the front of the slab, clear of the deck, with Close; owner to judge on the headset |

---

## T1. Storage: which folder, a project folder on first run, and changing it

**DONE (4 Nov 2026), headless only.** Built as planned: `scripts/project_folder.gd`, `scripts/ui/folder_chooser.gd`, the launcher's `folder` page (the first-run card), Settings > Project folder, the Files header, `manage_external_storage` in the preset, `tests/project_folder.gd`. Differences from the plan: the first-run card is a launcher page (the launcher is where the landing's cards live), not a separate card; step 1 (the headset checks) is a checklist in `android-build.md` because it needs the owner. **Not checked:** everything about Horizon OS (see the checklist), the permission page, and how the chooser feels with the laser.

**Report:** "It's not clear which folder the app is using for storage. Does the Quest have the same storage restrictions as the Android client? Should a project
folder be set on app open if one is not set? With an option to change folder in options? What are the options?"

### What the code does now

- Files are looked for in `res://models`, `user://models` and the Settings **Project folder** if set (`main.gd` `list_model_files()`, `native_search_dirs()`).
- A save goes to the project folder, else `user://models` (`main.gd` `snapshot_path()`), and the status line spells out the full path (`saved_location_text()`).
- The project folder is a typed absolute path (Settings > Project folder, `tablet_pages.gd` `_build_settings_folder()` / `_on_set_project_folder_pressed()`,
  a keyboard). Nothing checks that the folder exists, is readable or is writable. Nothing asks for it on first run.
- Other files in `user://`: `settings.cfg`, `graphics.cfg`, `servers.cfg`, `recent.cfg`.
- The Android export preset asks for no storage permission (`tools/android/export_presets.cfg.example`).
- The flat app on Android uses the **Storage Access Framework** (SAF): the user picks a folder in the system picker and the app keeps a persistent
  `content://` grant (DIDSA-CAD `client/lib/storage/saf_storage_service.dart`, `project_root.dart`), because Android 10+ scoped storage blocks plain paths.

### Answer to the questions

- **Same restrictions?** Yes. Horizon OS is Android, so scoped storage applies to the VR app just as it does to the flat app on a phone. A path such as
  `/storage/emulated/0/Documents/DIDSA` typed into Settings can be read only if the app created those files itself, or has *All files access*.
  (Not checked on the headset yet; T1 step 1 checks it.)
- **Where `user://` is on the Quest:** a code comment in `saved_location_text()` says `Android/data/<app>/files`, which the Quest Files app can show. Godot 4
  may instead use internal storage (`/data/data/<app>/files`), which no file browser can see. **Not verified.** The launcher's Servers page already prints
  `OS.get_user_data_dir()`, so the first step is to read it on the headset.
- **Project folder on first run:** yes, recommended. Ask once (the first time the app needs to save or open, or on the landing's first run), then keep it.
- **Change it in Settings:** yes. Keep the Settings page, but replace the typed path with the same chooser.

### The options (decided 4 Nov 2026: **B + C**)

| Option | How it works | For | Against |
|---|---|---|---|
| A. App folder only | Everything in `user://`; no choice | Nothing to build | Possibly invisible to the Files app; gone on uninstall; no way to bring in files from the flat app |
| **B. Shared `Documents/DIDSA` (recommended to start)** | On first run make `Documents/DIDSA` (`OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)`) and use it as the project folder. No permission needed for files the app creates | Visible in the Quest Files app and over USB; survives uninstall; small change | Files put there by **another** app (USB copy, the flat app) may not be readable without option C |
| C. B plus *All files access* | Add `MANAGE_EXTERNAL_STORAGE` to the export preset; a Settings button sends the user to the system page to grant it; then any folder works and the current path-based code is unchanged | Opens files copied in by USB or the flat app; fine for a sideloaded APK | A Store listing would need justification; one more system page for the user |
| D. SAF folder picker, like the flat app | A small Kotlin Godot Android plugin for the picker and `content://` I/O | Same model as the flat app; works with cloud providers | Needs a native plugin (CLAUDE.md allows only the Vendors plugin, so the owner would have to allow it); every `DirAccess`/`FileAccess` call in `main.gd`, `native_compose.gd`, `file_lookup.gd`, `file_index.gd` would go through a new storage layer. Large |

**Decision (owner, 4 Nov 2026): B + C.** `Documents/DIDSA` by default, and *All files access* offered in Settings. D is not being built.

### Build (for B + C)

1. **Check on the headset first** (ask the owner): what the launcher's Servers page shows for `OS.get_user_data_dir()`; whether a file saved to
   `Documents/DIDSA` shows in the Quest Files app; whether a file copied there over USB can be opened without C. Write the answers in `docs/android-build.md`.
2. New `scripts/project_folder.gd` (pure static functions, testable): `default_folder()` (Documents/DIDSA, falling back to `user://models`), `probe(path)` ->
   `{exists, readable, writable, error}` (make the folder, write and delete a small temp file).
3. **First run:** if `app_settings.project_folder` is empty when the landing opens, show a one-time card on the landing (`scripts/landing/`): *"Your projects
   will be saved in Documents/DIDSA"* with **Use this**, **Choose another...** and **Keep in app storage**. Store the choice (an empty string never means
   "not asked": add a `files/folder_asked` flag to `app_settings.gd`).
4. **Folder chooser** (Settings > Project folder and the first-run card): a laser list of folders built with `DirAccess` (up, into, **New folder**, **Use this
   folder**), starting at Documents. Keep "type a path" as a secondary button (network mounts). Each pick goes through `probe()`; a folder that cannot be
   written is refused with the reason.
5. Settings page shows the **full** real path (globalised, not `user://`), whether it can be written, and how many model files it holds.
6. **C:** `permissions/manage_external_storage=true` in `tools/android/export_presets.cfg.example` (check `tests/android_config.gd`), and a Settings button
   *Allow opening files from other apps* that calls `OS.request_permissions()` / opens the system page; show the current state.
7. Saves and the Files page say which folder they use (Files header: *"Project folder: Documents/DIDSA"*).
8. Docs: `docs/android-build.md` (the permission and what it is for), `README.md` controls section, `status.md`.

**Tests:** headless test of `project_folder.gd` (`probe` on a temp folder, a missing folder, a read-only folder), of the first-run flag, and that `snapshot_path()`
uses the new default. Add to `tests/run_all.sh` and `tests/README.md`. The permission and the Files-app view can only be checked on the headset: say so.

---

## T2. Empty room and empty design table: clear "new / open" path; first part fixed at the origin

**DONE (4 Nov 2026), headless + render + live backend; not on the headset.** Built: `scripts/ui/start_buttons.gd` (one window used in both places: the room's, a child of the room on the user's side; the table's, a child of the table above the slab), `room_edit.gd` (`is_empty_room()`, `add_new_part()`, the first-part rule in `add_file()` and `add_copy()`), `room_manager.gd` (`new_part_in_room()`, `update_start_buttons()`, `open_file_picker()`, New room starting an assembly), the console's *New assembly / Open assembly...* row, `design_table.gd` (`open_part_file()`), `main.gd` (`add_component_to_world()`), and the folder chooser's files mode. **Corrections to the plan:** (1) the backend already grounds the first occurrence of an empty Part and `add_file()` already placed it at the origin; what was missing was the explicit rule for `add_copy()` (it used the drop pose) and the explicit `fixed: true`, now sent in every path. (2) An empty Part has no mesh, so "the room is empty" is decided by asking the backend for the room Part's occurrences, not by the room's nodes. (3) *New assembly* in a room does **not** open the design table on the new part: the table seats only the world's own parts (`node_for_occurrence()` skips a room's copy), so it cannot be opened on a part inside a room. Follow-up: let the table take a part from a room (it would need the room frame's pose handling and the world preview). (4) An old test (`room_edit.gd`) expected the first file added to an empty Part at the pose asked for; it now expects the origin. **What the owner should try:** the size and reach of the four buttons, whether the list under *Open...* is easy with the laser, and whether *New assembly* (an empty sub-assembly) is what was meant by "a new subassembly" in an empty room.

**Report:** "A newly opened empty room with no subassembly in it should have a clear path to create a new subassembly in it into which parts can then be
added. The first part added should come in fixed at the origin by default. More parts can then be added from the console. I'm thinking: large *New part*
and *Open part* buttons floating on an empty design table. Large *New Assembly* and *Open Assembly* floating buttons in an empty assembly room."

### What the code does now

- **Room:** Rooms page > **New room** (`room_manager.gd` `new_room()`) makes an empty sub-assembly Part on the root and starts placement. It refuses with a status
  line if no assembly is loaded. Once placed, the room is empty and its console (`room_console.gd` `_build_content()`) has scale, walls, world preview,
  delete and close: **no way to add anything**. Parts get in by carrying an arena part in (a copy) or Files > Add while standing in the room.
- **First part:** the backend grounds the first occurrence of an empty Part. `room_edit.gd` `add_file()` keeps that, but places the part **where it was
  dropped**, not at the origin. `add_copy()` sends the drop pose. The flat app sets `fixed: isFirstOccurrence` (DIDSA-CAD `client/lib/assembly/add_component.dart`).
- **Design table:** an empty table shows the slab only. **New part** is on the tree's **+** and the tablet's Table page (`design_table.gd`, "New part").
  There is no **Open part**: a part gets onto the table only by carrying it there from the arena.

### Build

1. **Floating start buttons**, one small scene used in both places (`scripts/ui/start_buttons.gd`): two large laser buttons (about 0.30 x 0.12 m each, the
   theme's accent, a short line of help under them) on a `LaserSurface`, hidden as soon as the space holds anything.
2. **Empty room** (room has no occurrences; listen for the room's parts changing):
   - **Decided (owner, 4 Nov 2026):** assembly files and part files are the same native files (`.didsa` / `.DIDSAprt`); only the words differ, because rooms
     are for assemblies. So the room's buttons are **New assembly** and **Open assembly...**, and the table's are **New part** and **Open part...**. Behind them
     the actions are the same:
     - **New assembly**: a new empty Part as an occurrence in the room's Part, at the origin and fixed (step 3). The design table opens on it, so it can be
       drawn on or have parts added to it.
     - **Open assembly...**: the T1 folder list, filtered to native and model files, then `room_manager.add_file_to_room()`.
   - When there is no assembly loaded at all, **New room** on the Rooms page should start one (`NewDocument.start_assembly()`) instead of refusing.
3. **First part fixed at the origin:** in `room_edit.gd`, when the room's Part has no occurrences, add the first part at the identity transform and with
   `fixed: true` (both `add_file()` and `add_copy()`, and the New part path). A toast says *"First part: fixed at the room's origin"*. Later parts are placed
   where they are dropped, unfixed, as now.
4. **Room console:** add **New assembly** and **Open assembly...** rows (the same actions as step 2, for a room that already has parts), so "more parts from the console" works.
5. **Empty design table:** the same two big buttons, **New part** (the existing New part) and **Open part...** (pick a part file: add it to the assembly
   beside the table with `add-component`, then seat it on the table as if carried there). Hide them while a part is seated.

**Tests:** headless: the buttons show only when the room / table is empty and hide after the first add. Live backend (`e2e_rooms.gd` or a new `e2e_empty_start.gd`,
add to `tests/e2e_ci_list.txt`): New room in an empty session starts an assembly; the first part added to a room has identity transform and `fixed: true`;
the second does not. Render test for the button layout under Xvfb. Size and reach of the buttons can only be judged on the headset.

---

## T3. Selecting a mate on the tablet highlights its two entities

**Report:** "Selecting a mate from the tablet should highlight the two entities that are mated (faces, edges, vertices etc.). This is a candidate for the
Flutter client too."

### What the code does now

- The Mates page list (`tablet_pages.gd` `_mates_rows()`) gives each mate a title, a subtitle and action buttons. Rows cannot be selected
  (`side_panel_ui.gd` `_build_row()` has only the action buttons).
- `face_highlight.gd` `set_picks(entries)` lights up faces, edges and vertices in the pick colours, given `{part, kind, body_id, index, key}`
  (`TopologyPick.entity_key()` builds the key).
- **The flat app already does this** (DIDSA-CAD `part_screen.dart` `_onMateTap()`, test report item 5): a mate row tap feeds each reference's
  `subshape_ref` into the shared highlight set; plane/point refs are skipped. Nothing to do in DIDSA-CAD.

### Build

1. `side_panel_ui.gd`: a row can be selected (a tap on its body, not its buttons) when the row has `"selectable": true`; emit `row_selected(id)`; draw the
   selected row in the accent colour; tap again to clear.
2. `mates_tool.gd`: `highlight_mate(mate_id)`: for each reference, find the arena node by `occurrence_id` (the room's copy too, if open), map
   `subshape_ref {body_id, shape_type, index}` to an entity (`kind` = face / edge / vertex, key from `TopologyPick.entity_key()`), skip `midplane`,
   `plane_ref`, `point_ref` sides (for a Width mate light its four faces instead: the references carry them), and call `set_picks()` with colour slots 0 and 1.
   Clear it when the tool's own picking starts, when the page changes, and on `invalidate`.
3. Also pulse the two parts' outlines briefly (the existing selection outline) so a mate between hidden faces can still be found; and if a part is out of
   view, say so in the status line ("Bracket is behind you").

**Tests:** headless: a fake mate with a face and an edge reference lights two entities with the right keys; a plane_ref side is skipped; clearing works.
Add to `tests/run_all.sh`. Live-backend: a coincident mate made in `e2e_*`, then selected, gives two highlight nodes.

---

## T4. Sketch canvas at the front of the table

**Report:** "On the design table, the sketch canvas should be at the front of the table (hinged at the front edge, tilted back slightly) so when the user is
standing in a comfortable position to select tools, the canvas is close."

### What the code does now

`design_table.gd`: while a sketch is open, the part turns so the sketch plane stands `sketch_tilt_degrees` (60) up from the slab, about the slab's x axis, and
floats at the **middle** of the slab at least `sketch_hover_height` (0.26 m) up (`orient_to_plane()`, `sketch_rotation()`, `reset_pose()`). The sheet is a
fixed 0.80 x 0.40 m window (`sheet_window_m`) anchored on the part (`_set_window_anchor()`). The whole console also leans back 22° (`lean_degrees`), the slab is
0.60 x 0.40 m and the tool deck is in front of the slab (`deck_gap`, `deck_lean_degrees`).

### Build

1. Put the sheet's **lower edge on the slab's front edge** (console +Z, beside the deck), and tilt it back from the vertical by a new
   `sketch_lean_back_degrees` (start at 15°; i.e. about 75° up from the slab). The sketch's centre is then at `z = slab_size.y / 2 - (h/2)·cos(tilt)`,
   `y = (h/2)·sin(tilt)` plus a small clearance, h = `sheet_window_m.y`. Change `orient_to_plane()`, `reset_pose()` and the Fit button to use this anchor
   rather than the slab's middle.
2. Keep the part's zoom and slide behaviour: the window stays put at the front edge; one hand still slides the part under it.
3. Make sure the sheet does not cover the tool deck, the Properties panel or the tree panel from the user's eye (the deck sits just below the hinge). If the
   sheet's lower edge would hide the deck's top row, raise the hinge by a few centimetres rather than move the deck.
4. Settings > Table: a choice row *Sketch sheet: Front (hinged) / Middle* and the lean angle (10° / 15° / 25°), saved in `app_settings.gd`, so the owner can
   compare on the headset.

**Tests:** headless: with a sketch open, the sheet's lower edge lies on the slab's front edge (to 5 mm) and its angle to the slab is 90° - lean; Reset and Fit
keep it there. Render test screenshot from the standing eye point. Comfort can only be judged on the headset.

---

## T5. Sketch items selectable: lines, dimensions, constraints

**Report:** "Items in sketches (lines, dimensions, constraints, etc.) are not selectable. They should be, to allow editing and deletion to modify the sketches."

### What the code does now

- There **is** a Select tool (`table_tools.gd`, `table_editor.gd` `SELECT_TOOL`, `sketch_session.gd` `select()` / `toggle_select()` / `delete_selection()`,
  menu in `sketch_selection.gd`) that picks points, lines, circles, arcs, ellipses, splines and text, and offers Delete, Construction, Fix and constraints.
  It is not the default tool when a sketch opens. **Owner, 4 Nov 2026:** *"I expected to be able to select lines, dimensions etc without needing to open a
  tool."* So selection must work with no tool chosen, not only inside a Select tool.
- **Dimensions and constraint glyphs are `Label3D`s** (`sketch_view.gd` `_labels`, `_constraint_labels`) with no picking at all: they cannot be selected,
  edited or deleted. The only way to change a dimension value is the Build tree.
- The flat app selects constraints and dimensions (`sketch_screen.dart`, `SelectionKind.constraint`), with delete and edit.
- **Hover highlight (checked 4 Nov):** `table_editor.gd` `_process()` returns at once when `state == "idle"`, so with no tool chosen nothing under the laser is
  lit, on the sketch or on the part. In a sketch, hover works only with Select, a constraint tool, Dimension, Trim/Offset or Revolve (`nearest_entity()` then
  `sketch_view.gd` `rebuild(session, selection, hover)`). A drawing tool lights only the snap cursor, a part edge it would snap to and the entity an inferred
  relationship would hold to. Faces / edges / vertices of the part light only inside a feature's pick state (`_hover_faces()`, `_hover_edges()`... through
  `face_highlight.gd` `set_hover_entity()`). Dimension and constraint labels never light. And in `rebuild()` an entity is lit when it is selected **or**
  hovered, in the same warn colour, so "about to pick" and "picked" look alike.

### Build

1. **No tool means select.** When a sketch opens, and whenever a drawing or constraint tool is finished or put down (B, or pressing its button again), the
   sketch is in a no-tool state in which the trigger on a line, point, curve, dimension or constraint selects it and the options appear (the current
   Select tool's behaviour). Drop the separate Select button from the deck, or keep it only as "put the tool down". Hover lights what the laser would pick in
   every state, so it is clear what is selectable. Status line with no tool: *"Pull the trigger on anything in the sketch to change or delete it, or pick a
   tool to draw."* Check that a tool-less trigger on empty sheet clears the selection and does not start drawing.
2. **Geometry picking check:** a headless test that lays out a line and aims a laser ray at its middle on the tilted sheet, through the real
   `table_editor.gd` path (not `session.select()` directly), and gets it selected. If that fails, that is the bug; fix the hit radius / plane
   projection. Make the pick radius scale with zoom so it is a constant few millimetres in the world.
3. **Dimensions and constraints as pickable items:** each label gets a hit rectangle on the sheet (its layout already has a position and size,
   `dimension_layout.gd`). `nearest_entity()` (or a new `nearest_annotation()`) checks them first when the laser is within the label. A pick adds
   `{kind: "dimension" | "constraint", id}` to the selection; hover lights the label (theme accent), selected stays lit.
4. **Menu** (`sketch_selection.gd`):
   - 1 dimension: **Edit value** (number pad, `PUT`/`PATCH` the constraint's value, as `table_editor.gd` `dimension_typed()` does for a new one),
     **Driven / Driving** if the backend supports it (check `backend-api-notes.md`), **Delete**.
   - constraints (1 or more): **Delete**.
   - mixed with geometry: **Delete** only (deletes the constraints, then the geometry with `delete_cascade()`).
5. Also: **double-pull on a dimension** opens the number pad straight away (the common case). Undo must take back an edited value and a deleted constraint
   (use the sketch's existing `PUT .../state` undo).
6. **Hover in the no-tool state.** Remove the early return for `"idle"` in `table_editor.gd` `_process()` (keep it for a closed table / no part). With no tool
   chosen, every frame:
   - in a sketch: the nearest line, point, curve, text, **dimension label or constraint glyph** under the laser lights (`nearest_entity()` plus the new label
     hit test from step 3);
   - on the part (no sketch open): the **face, edge or vertex** under the laser lights, with the same reach rules as the feature pick states (`TopologyPick.pick()`,
     edges and vertices win when the laser is close to them, as `_hover_edges()` / `_hover_vertices()` already decide), through
     `face_highlight.set_hover_entity(table._right, table.table_copy, entity)`;
   - the laser claims `ui_hover` as now, so the arena never also reacts. Keep the cost down: run the part's topology hit only when the ray hits the copy's
     bounds, and reuse the per-part triangle cache `face_highlight.gd` already keeps.
   A trigger on what is lit selects it (sketch: as step 1; on the part: the selection T6 acts on). A trigger on empty space clears the selection.
7. **Hover looks different from selected.** Selected keeps the warn/accent colour, solid. Hover is a lighter, thinner version (sketch: the line's own colour
   lightened plus a faint glow; labels: an outline in the accent; part entities: `face_highlight.gd`'s hover material at lower alpha, picks stay solid).
   Something both hovered and selected shows as selected. Pass hover and selection separately to `sketch_view.gd` `rebuild()` and give it a `"hover"` style
   distinct from `"selected"`.
8. Update the Select tool help text in `table_tools.gd` and `docs/design-table.md`.

**Tests:** headless (`sketch_selection` vectors): menus for 1 dimension, 2 constraints, constraint + line. Fake-backend: Edit value sends the right body;
Delete of a constraint leaves its geometry. Live backend (`e2e_sketch_select.gd`, add to `tests/e2e_ci_list.txt`): make a line with a Length, select the
dimension, change it, the line's length follows; delete a Horizontal, it is gone. Headless hover tests: with no tool, a ray at a line lights it with the
hover style, not the selected one; a ray at a dimension label lights the label; with no sketch open, a ray at a face and then near one of its edges lights the
face, then the edge; the idle state never lights anything once the table is closed. How easy the labels are to hit with a laser, and whether the hover style
reads well against the selected one, can only be judged on the headset.

---

## T6. Contextual options and breadcrumbs on the design table (added 4 Nov 2026)

**Request:** "When the user selects something on a model on the design table, contextual options are offered. Instead of selecting a tool from the menu,
the user selects the thing they want to change: an edge offers Fillet, Chamfer; a face offers New sketch on face, Move face; a sketch offers Edit sketch,
Extrude, Revolve, etc. Breadcrumbs in the same place." The flat app has both, as a reference, not a complete list.

### What exists to build on

- **Flat app** (DIDSA-CAD `client/lib/viewport3d/`): `selection_actions.dart` `contextActionsFor()` is a pure table from a selection to actions, with
  disabled-with-reason entries; `selection_context_panel.dart` shows the breadcrumb row above the action row in one panel (it used to float over the
  viewport and was moved because it covered things); `selection_breadcrumbs.dart` builds entity -> body -> component (no feature tier: the backend has no
  per-face feature history); `feature_context_menu.dart` is the menu for a feature / sketch row (Extrude, Revolve, Sweep, Sketch orientation, Extrude surface,
  Pattern, Mirror, Merge / Subtract / Common / Split, Show / Hide, Delete).
- **VR:** every feature tool is chosen from the deck first, then picks (`table_editor.gd` states `pick_faces`, `pick_edges`, `pick_vertices`, `pick_bodies`,
  `pick_curves`, `pick_sketch`), and a finished sketch can already be a **seed** for Extrude / Revolve / Loft (`seed_sketch`, `seed_sketches`). The deck has an
  options row (`table_ui.gd` `_options_row`) and the Properties window has a selection list and options (`table_props_window.gd`). The arena has an
  assembly-level breadcrumb on a held trigger (`scripts/group_breadcrumb.gd`), drawn as a themed Control in a SubViewport: reuse its look.

### Where it goes (recommendation)

A **selection drawer**: a panel that rises out of the **front of the slab itself**, inside the slab's outline, centred left to right on the slab's front edge,
a few millimetres above the glass and tipped up about 15° towards the user.

- **Fixed size (owner, 4 Nov): 0.40 m wide x 0.11 m deep**, the same at every slab size, so it always looks and reads the same. It fits the smallest slab
  (`table_resize.gd` `min_size` 0.50 x 0.30 m). Layout at that size: the breadcrumb row on top; under it up to four action buttons (about 0.08 m each), then
  **More** and the **X**. A breadcrumb chain too long for the row keeps its first and last rungs and folds the middle into "...", which opens the rest.
  Make the size one constant (`DRAWER_SIZE`) so it can be tuned after the owner tries it.

- **It must never cover the tool deck (owner, 4 Nov).** The deck sits only `deck_gap` (0.05 m) in front of the slab, so a drawer *between* slab and deck
  would overlap it. The drawer therefore never reaches past the slab's front edge, and the deck does not move when the drawer opens (controls that shift
  under the laser are worse than a smaller drawer). When the slab is resized (`table_resize.gd`) it stays centred on the front edge at its fixed size; it moves with the console when that is carried.
  The Properties and tree windows are also left clear. **Test:** from the standing eye point (the table's summon pose), the drawer's on-screen rectangle
  does not intersect any deck button, the Properties window or the tree window, at the smallest and largest slab sizes, with the drawer open and while a
  sketch is open.
- If the part sits low over the front strip, it is lifted by the drawer's height while the drawer is open, so the drawer never cuts through the part.
- **Close:** an **X** at the drawer's right end. It clears the selection and closes the drawer (one meaning for "close": nothing stays selected out of
  sight). B on the right controller does the same.
- **A trigger on empty space clears the selection** and closes the drawer: on the table that is a pull that hits no part entity, no sketch item and no UI
  (the slab's glass, the air round the part). A pull on the deck, a window or the drawer itself never clears it. A pull out in the arena, past the table,
  clears the table's selection too (and does whatever it does in the arena now).

- **Top row: breadcrumbs.** **Middle: the action buttons**, large (a laser target of at least 4 x 4 cm), the most likely action first and in the accent of
  its deck group (Create blue, Refine amber, Modify violet), a **More** button for the rest. Disabled actions stay, greyed, with their reason on hover
  (the flat app's rule: explain, don't hide).
- It **slides out** (about 150 ms, ease-out, and a soft click) when something is selected and slides back when the selection is cleared, so the user sees it
  arrive; nothing appears near the part, so the part is never covered. A thin leader line from the drawer's left end to the selected entity, fading after a
  second, links the two for a first-time user.
- **Why here:** it is where the hand already is (just above the deck), it covers neither the deck nor the model or the sketch sheet, it does not drift with the laser, and
  the user learns one place for "what can I do with this". A menu at the hit point (a radial or a pop-up) feels quick on a flat screen, but in VR it covers
  the very thing selected, moves with every pick and is awkward to reach on a far side of the part. If the owner wants a quicker path later, a held trigger
  could pop the same first three actions at the hit point, as the arena's breadcrumb does; not in this pass.
- **With T4:** the sketch sheet's hinge is at the slab's front edge too. While a sketch is open the drawer carries the **sketch** selection's options (T5's
  menu moves here from the Properties window, so there is one place for options), and the sheet's hinge moves back to the drawer's back edge (so the sheet
  stands behind the drawer, still close to the user). T4's hinge is then "the front of the slab, behind the drawer", not the slab's very edge.
- The Properties window keeps the tool's own fields (radius, distance...) once an action has started; the drawer hides while a tool runs and comes back when it
  finishes or is cancelled.

### What each selection offers (start list; not exhaustive)

A new pure `scripts/design_table/selection_actions.gd`, a port of the flat app's table (unit-tested the same way), returning `{id, text, group, enabled, reason}`:

| Selection | Actions (first is the default) |
|---|---|
| 1+ edges, one body | **Fillet**, Chamfer, Create plane (1 edge: normal to edge) |
| edges on two bodies | Fillet / Chamfer disabled: "Pick edges on one body" |
| 1 planar face | **New sketch on face**, Extrude face (if the backend has it; else leave out), Move face, Create plane (offset), Fillet / Chamfer (its edges), Shell (open this face), Delete face |
| 1 curved face | Move face, Fillet / Chamfer, Delete face (no sketch or plane: not planar, as the flat app learned) |
| 2 faces | Create plane (midplane), Move faces, Delete faces; 2+ faces: Shell (open these) |
| 1 vertex | Create plane (with an edge or face added); a lone vertex: "Pick an edge or face as well" hint |
| edge + vertex / face + vertex | the flat app's Create plane combinations |
| a body (from the breadcrumb) | Move body, Scale body, Mirror, Pattern, Shell, Delete body |
| a finished sketch (a pick on its lines with no sketch open, or its Build row) | **Edit sketch**, Extrude, Revolve, Sweep (as profile), Loft (start sections), Delete; Extrude disabled with "No closed shape" if it has none |
| a feature (from the breadcrumb or the Build tree) | **Edit**, Roll back to here, Suppress / Unsuppress, Delete |
| a surface body's face | Fillet / Chamfer / Shell left out (no solid), as the flat app does |

Choosing an action **starts the existing tool with the selection already picked** (generalise the seed: `begin_tool(id, seed_entities)` that enters the tool's
pick state with `face_highlight.set_set()` / picks pre-filled, so the user can still add or remove picks, then Apply). Nothing new is built in the backend.
Gaps found (an action the flat app has that VR has no tool for) go in `design-table-gaps.md`, not into this pass.

### Breadcrumbs

- For a part entity: **Face 12 > Body 1 > made by Extrude 2 > Part "Bracket"**. Taking a rung selects that level and the drawer's actions change (Body: body
  actions; feature: feature actions; part: Return to arena, Appearance, Properties).
- **What the backend can tell (checked in DIDSA-CAD, 4 Nov):**
  - **Face -> body: yes, already on the client.** Every face of the part's mesh carries its `body_id` (`mesh_identity.gd`: the part's `face_ids` /
    `body_ids` metas; every `subshape_ref` has `body_id`). No backend call.
  - **Body -> the feature that created it: yes, by the backend's naming rule.** A body's id *is* the id of the feature that created it (Extrude, Revolve,
    Sweep, Import, ...), with a `#N` suffix when one operation made several solids (a multi-profile boss, a cut that splits a body, Mirror / Pattern copies).
    The backend's own lookup is `backend/app/document/graph.py` `base_feature_id()` (strip `#N`) and `body_ids_for_feature_id()`. Port the one-line rule to
    VR (and add it to `backend-api-notes.md` with that reference), then find the feature in the part's feature list (the Build tree already has it) for its
    name. **Caveat:** this is the feature that *created* the body, not the last one that changed it: after a Cut, Fillet or Shell on it the body keeps its
    creator's id, and when bodies are merged the survivor keeps one of their ids. So the rung reads "made by Extrude 2", not "Extrude 2".
  - **Face -> the feature that created that particular face** (e.g. the face a Fillet made): the backend has the machinery (`reference_history.py`, OCCT
    history, `lineage_for(body_id, index, "face")` returns a `LineageOrigin` with `feature_id`), but it is used internally for sketch references only, rebuilds
    the part with recording on (the slow path), and has **no route**. Not in this pass. If wanted later it is a DIDSA-CAD change (a
    `GET .../parts/{id}/faces/{body}/{index}/origin` or a per-face `feature_ids` array in the mesh metadata), and the flat app's breadcrumb could use it too
    (its feature rung is missing for the same reason).
- For a sketch entity (a sketch open): **Line 4 > Sketch 2 > Part "Bracket"**. For a selected dimension / constraint: **Length 40 mm > Sketch 2 > Part**.
- Several entities selected: the first rung reads **"3 edges"**; the rungs above it appear only if they are shared.
- Rungs are laser buttons, the selected rung lit. Same Control-in-SubViewport drawing as `group_breadcrumb.gd`, so the theme reaches it.

### Build steps

1. `selection_actions.gd` (pure) and its tests, ported from the flat app's cases plus the sketch / feature rows above.
2. `selection_breadcrumbs.gd` (pure): the chain for a selection.
3. The table's selection model for the no-tool state (T5 step 6 makes the hover; this keeps a list of picked part entities, multi-select by pulling on
   more, a pull on a selected one drops it).
4. `selection_drawer.gd`: the drawer node on the console (under the slab's front edge), breadcrumb row and action row, slide in / out, `LaserSurface`.
   Hide it while a tool runs and while the table is moved.
5. `begin_tool(id, seed)` in `table_editor.gd`: Fillet / Chamfer from edges, Move / Delete face and Shell from faces, New sketch on face from a face (the existing
   pick-plane path with the face already chosen), Extrude / Revolve / Loft / Sweep from a sketch (the existing seed), Edit sketch, Edit / Delete / Suppress feature
   through the Build tree's existing actions.
6. T5's sketch menu moves from the Properties window into the drawer.
7. Docs: `docs/design-table.md` (selection-first editing), `status.md`, the tablet's table help.

**Tests:** headless: the action table (every row above, plus disabled reasons), the breadcrumb chains, that choosing Fillet with two edges selected enters
`pick_edges` with both edges already picked, that the drawer shows only with a selection and hides while a tool runs. Live backend (`e2e_table_context.gd`, add to
`tests/e2e_ci_list.txt`): select an edge, Fillet, Apply, the part has the fillet; select a planar face, New sketch on face, the sketch is on that face.
Render test of the drawer layout from the standing eye point. Whether the drawer is the right place, and whether it feels quicker than the deck, only the owner
can say on the headset.

---

## For the implementing session

- Read `CLAUDE.md`, `docs/status.md`, `docs/backend-api-notes.md` and `tests/README.md` first. Branch per the session's instructions.
- One commit per item (T1...T6), each with its tests passing (`tests/ci.sh`; `tests/ci_render.sh` and `tests/ci_e2e.sh` where the item adds to them).
- Update `docs/status.md` (a row or open item per item) and this doc (mark each item done, and what was **not** checked on the headset).
- Do not write "works on the headset". List what the owner should try on the next APK, per item.
