# Trees in the VR client: review and recommendations (2026-11-11)

The owner asked for a review of the VR client's trees ("feature trees are foundational, and we've neglected them"), with
three things they like as the direction: **select a row and the part is selected in the world** (a good visual cue), **the
actions in a bar at the bottom of the window**, and **trees in rooms and at the table as well as in the world**. This doc
reviews what exists and recommends a plan. It replaces the tree part of `vr-feedback-2026-11-11-plan.md` (V-7 now points here).
Code was read on branch `ccr-dec7d67f-ipq5rn`. Nothing was run.

**Decided by the owner (11 Nov):** Fix / Float is done from the tree (not the mates wheel). **Hide in the tree is view-only**: it
never writes the backend's `hidden` flag and is not saved.

---

## 1. What exists

| Tree | Code | Where it shows | Root | Rows | Actions |
|---|---|---|---|---|---|
| **World Assembly Tree** | `scripts/assembly_tree_window.gd` (375 lines) | A floating window (0.28 x 0.34 m), opened from the tablet | `main.current_root_part_id()` | The root, then each occurrence, fetched one level at a time (GET `/parts/{id}/occurrences`); Part names filled in | Tap a name: select the part. **Room** and **Delete** (two presses, names the mates that would go) on every row |
| **Table tree, PARTS tab** | `scripts/design_table/table_tree_window.gd` (extends the one above) | Docked at the left of the design table's console | The **world's** root (same as above) | Same rows | **Table** (put the part on the table) and **Bring** (move it in front of you) on every row. Room and Delete are gone (the subclass replaces `_add_row_actions`) |
| **Table tree, BUILD tab** | the same file + `build_tree.gd` (pure) + `table_build.gd` | Same window | The Part on the table | Every feature in build order (icon, "Extrude 2", a one-line summary, hidden / rolled back / broken-reference state), an eye on each row, group eyes (Sketches, Bodies, Surfaces, 3D curves, Planes), a Bodies list | Select a row: an **action strip under the row**: Edit, Fix (a broken reference), Lines, Hide / Show, Roll back / forward, Delete (two presses). The selection also drives the table's selection drawer |
| **Rooms** | none | | | | A room has a **console** (`room/room_console.gd`: scale, walls, "used N times", the world copy, delete the selected part, close) but **no tree** |

For comparison, the flat app's assembly tree (`DIDSA-CAD client/lib/viewport3d/assembly_tree_panel.dart`) has three sections
(**Components**, **Mates**, **Patterns**), a highlighted selected row, a state icon per row (pin = fixed, lock = fully constrained,
open lock + DOF = under-constrained, warning = over-constrained, from GET `/parts/{id}/constraint-status`), instance names that tell
pattern copies apart, and a context menu (Edit alone, Focus, Move / Rotate, Hide, Isolate, Fix / Float, Mate, Pattern, Rename,
Appearance, Delete).

## 2. What is good and worth keeping

- **The BUILD tab is the model to copy.** It already does what the owner wants for features: a selected row, its actions in one
  place, state written on the row (hidden, rolled back, a broken reference in amber), dimmed rows, an eye per row, 52-60 px row
  height, icons, theme styling. The occurrence trees should look and behave like it.
- Lazy loading with a refresh token (a slow fetch can't overwrite a newer one); real Part names instead of ids.
- Delete asks twice and says how many mates go with it.
- The table PARTS tab's **Table** and **Bring** are good, VR-specific actions (no need to walk to a part to work on it).

## 3. Problems found

Bugs (confirmed by reading the code):

| # | Problem | Where |
|---|---|---|
| B1 | **A row under a repeated sub-assembly selects the wrong part.** `main.select_part_by_occurrence_id` takes the first visible node whose `occurrence_id` meta matches. That meta is the occurrence id **within its own Part** (`mesh_identity.gd` from the glb extras, `mesh_export.py`), so both placements of a sub-assembly carry the same child ids. The row under the second placement selects the part in the first. | `main.gd` ~793 |
| B2 | **The root row selects an arbitrary body** (it should select the whole assembly: owner, 11 Nov). The root row's id is `""`; the root's own bodies and every pattern copy also have `occurrence_id == ""`, so tapping the root selects whichever comes first. | same |
| B3 | **Delete on a nested row edits a shared Part silently.** It deletes the occurrence from the sub-assembly's Part, which changes every placement of that sub-assembly; the room console says "used N times" for exactly this reason, the tree does not. | `assembly_tree_window.gd` `_on_delete_pressed` |
| B4 | **Refresh throws the tree away.** `mark_stale()` sets `_tree = []`; every refresh collapses everything you had expanded. | `mark_stale`, `_refresh_root` |
| B5 | **The table PARTS tab lost Room and Delete** by overriding `_add_row_actions` (probably by design for space, but nothing replaced them). | `table_tree_window.gd` `_add_row_actions` |

Missing (compared with any desktop CAD tree, and with the flat app):

- **No state on the rows.** `OccurrenceResponse` already sends `fixed`, `hidden`, `suppressed` and unresolved files
  (`resolved_part_id == null`, shown today as "Occurrence 1a2b3c4d" with no hint); constraint status is never read.
- **No selection in the tree.** The selected row is not highlighted; selecting in the world does not show in the tree (the
  controller has no selection signal); a **sub-assembly row can't be selected** at all ("expand it and select one of its own
  parts"), although the world can now select a whole sub-assembly (`controller.select_group_level`).
- **Repeated parts look the same** (three "Bolt" rows); the flat app names instances.
- **No Patterns and no Mates** in the tree; the root's own bodies don't appear.
- **Goes stale** after a mate, a fix, a move, a delete in the world or a room edit (only `mark_stale()` on load / add, or Refresh).
- **Small targets.** The world tree's rows are default-height buttons with ">" / "v" text expanders and per-row buttons crowding a
  480 px row; the BUILD tab's rows are 52-60 px with icons.
- **No room tree.**
- **Two different looks.** The occurrence rows (plain buttons) and the BUILD rows (`ButtonRail`, icons, selected style) don't match.

## 4. Recommendations

### R1. One tree component, three scopes (the structural change)

Today there is one occurrence tree class, used as-is in the world and subclassed at the table, and nothing in rooms. Make it one
component with a **scope**:

| Scope | Root Part | The nodes a row resolves to | Actions it adds |
|---|---|---|---|
| World | `main.current_root_part_id()` | `RoomRegistry.world_parts(tree)` | Room |
| Room | the room's Part | `RoomRegistry.parts_in_room(tree, room_id)` | (none extra; edits write to the room's Part, as the room already does) |
| Table, PARTS tab | the world's root | the world's parts | Table, Bring |

Files (suggested): `scripts/tree/occurrence_tree_model.gd` (**pure**: rows from the API, paths, names, state, which actions a row
gets and why one is greyed; unit-tested), `scripts/tree/occurrence_tree_view.gd` (the rows and the bottom bar, styled like the BUILD
rows), and the scope as a small object the window is given. `assembly_tree_window.gd` becomes the World window on top of it;
`table_tree_window.gd` keeps its BUILD tab and uses the component for PARTS; rooms get one (R6).

### R2. Rows that say what state things are in

One line per row: indent · expander icon (not ">" / "v" text) · **state icon** · name · (nothing else; the actions are in the bar).
- **State icon**, same rules as the flat app: pin (fixed), lock (fully constrained), open lock (under-constrained; the DOF in the
  hint), warning (over-constrained), none for a free, unmated part. One GET `/parts/{part}/constraint-status` per expanded level;
  fall back to the `fixed` flag if it fails. Add `pin`, `lock_open`, `warning` to `ui/ui_icons.gd` (`lock`, `eye`, `eye_off` exist).
- **Hidden**: dimmed, with an eye-off (view-only, see R4). **Suppressed**: dimmed and marked. **Missing file**: amber "missing file:
  name.didsa" (and a way to the References page that already exists for relinking).
- **Instance names** for repeats: "Bolt <1>", "Bolt <2>" (SOLIDWORKS style), counted per parent; pattern copies as the flat app
  names them ("Bolt [Pattern 1 #3]").
- Row height 52-60 px and the BUILD tab's styles (`ButtonRail`, `tokens.selected_box`), so all trees look the same.

### R3. Selection, both ways, with a visual cue

- **Tree → world**: a leaf row selects its node **by path** (`group_path` meta, `group_index.gd`: the occurrence ids from the scope's
  root down; fixes B1). A sub-assembly row selects the whole group (`select_group_level`; `GroupIndex.levels` builds the level).
  The root row selects the whole assembly as a group (owner's answer; fixes B2, which picked an arbitrary body).
- **World → tree**: add `signal selection_changed(node, level)` to `controller.gd` (emitted from `_set_selection`,
  `_clear_selection`, `select_group_level`). The tree expands the ancestors (fetching levels as needed), highlights the row and
  scrolls it into view (`scroll_target`). Debounce.
- **The visual cue in the world** (VR has a problem a monitor doesn't: the part may be behind you or far away):
  - on a tree selection, **pulse** the selection highlight once (bright, then the normal overlay), so the eye finds it;
  - if the part is outside the field of view or more than a few metres away, draw a thin **leader line** from the tree row's edge
    to the part for a second or two (the room's world-preview already draws lines; `mates_tool` draws sandbox lines);
  - a **Frame** action in the bar (turn / fly the view to it; the room console already has "fly to" for the world copy) for when
    the line isn't enough.
- Optional later: laser hover on a row pre-highlights the part; hovering a part lights its row.

### R4. Actions in a bar at the bottom of the window

A fixed bar at the bottom of the tree window (it never scrolls away and the rows don't jump), showing what the selected row can do;
a disabled action shows why in its hint (as the wheel's greyed wedges do).

| Action | Rows | Notes |
|---|---|---|
| **Fix / Float** | placed occurrences (not the root, not a pattern copy, not a missing file) | PATCH `{"fixed"}` on the row's parent Part; one undo step; generalise `mates_tool.toggle_fixed` to `(owner, occ, label)` and update the right state (`occurrences` / `_other_states` / `_nested_states`), then refresh mates |
| **Hide / Show** | any row | **View-only** (owner, 11 Nov): the world's existing undoable hide on every node under the row's path; never the backend flag |
| **Isolate** | any row | the existing isolate, by path |
| **Frame** | any row with nodes | see R3 |
| **Rename** | placed occurrences | popup keyboard; PATCH `name_override`; one undo step |
| **Room** (World scope) | sub-assemblies | the existing toggle; moved off the rows |
| **Table / Bring** (Table scope) | parts with geometry | the existing ones; moved off the rows |
| **Delete** | placed occurrences | two presses; "Sure? (n mates)", plus "**edits every placement (used N times)**" for a nested row (fixes B3) |

Later: **Mate** (start the Mates tool with this part as the first pick), **Appearance** (paint this row's level),
**Suppress / Unsuppress**.

**Consistency with the BUILD tab:** its action strip sits under the selected row, inline. Recommend moving it into the same bottom
bar, so every tree in the app works one way (select a row, act at the bottom). It's a small change to `_redraw_build`. If the owner
prefers the inline strip there, keep it, but then use it in the occurrence trees too: one pattern, not two.

### R5. Keep it current without losing your place

Refresh only the affected level, keeping what is expanded and what is selected (fixes B4), on: `mates_tool.mates_changed` /
`document_changed`, `room_manager.rooms_changed`, an add / delete, the tree's own actions, and a document load (full refresh). Keep the
Refresh button.

### R6. A tree for each room

Rooms are where sub-assemblies get edited, so they need the tree most. Give the room console a **Tree** button that opens a tree
window scoped to the room (R1), docked beside the console the way the table tree docks to the table, in the room's colour. Selection
works in the room's parts; Fix / Float, Rename, Delete write to the room's Part (which `room_edit.gd` and `mates_tool._other_states`
already handle for its mates and moves). The console's "delete the selected part" can stay as a shortcut.

### R7. Sections, as in the flat app (second pass)

Under each assembly row: **Mates** (each mate: type, the two parts, state; select → `mates_tool` highlight; Delete; later
Suppress / Edit) and **Patterns** (each component pattern, its copies under it). The root's own bodies as a **Bodies** row. This
is where the tree becomes the place to understand an assembly, not only to pick from it.

### R8. Small things

- The tree's status line is easy to miss: route its messages through the same `say()` toast as the tools (the V-1 fix).
- Search / filter by name (popup keyboard) once trees get long; the right stick already scrolls.
- Make the window taller (e.g. 0.28 x 0.42 m) for the bar; check readability at its open distance in the UI lab (F6).

## 5. Phasing

| Phase | Contents | Size |
|---|---|---|
| **T1** (= V-7 in the feedback plan; **built**, headless only: see that plan's Progress notes) | World tree: B1-B4 fixed, state icons (R2), selection both ways with the pulse (R3), the bottom bar with Fix / Float, Hide, Isolate, Rename, Room, Delete (R4), live refresh (R5), BUILD-tab styling | Medium-large |
| **T2** | The shared component (R1); the table PARTS tab moved onto it (Table / Bring in the bar, Room / Delete back); a tree per room (R6); the BUILD tab's actions in the bottom bar | Medium |
| **T3** | Mates and Patterns sections (R7), leader line and Frame (R3), hover linking, search | Medium |

T1 can be built inside `assembly_tree_window.gd` with the pure parts already in a separate model file, so T2 is a move, not a rewrite.

## 6. Tests

- Pure (`tests/assembly_tree_window.gd`, then a new `tests/occurrence_tree_model.gd`): row state from API rows; the icon per
  constraint state; instance names; the action list and greyed reasons per row kind (root, top-level, nested, pattern copy, missing
  file); path building.
- B1: two placements of one sub-assembly; selecting a child row under the second selects the second's node (fails today). B2: the
  root row selects every part of the scope as one group.
- World → tree: `selection_changed` for a nested part expands its ancestors and marks its row.
- Fix / Float on a nested row PATCHes the parent Part's occurrence, updates `_nested_states`, undo reverts it (fake backend).
- Refresh after a mate keeps the expanded rows and the selection.
- Room scope: selection resolves to the room's node, not the world's hidden copy.
- e2e (`tests/e2e_assembly_tree.gd`): fix from the tree, then a grip on that part is refused with the "Part is fixed" message.
- **Not testable headless:** readability, reach, the pulse and the leader line as seen in the headset.

## 7. Owner's answers (11 Nov)

1. Instance names: **"Bolt <2>"**.
2. BUILD tab: **yes**, its actions move to the bottom bar: one pattern everywhere.
3. Room tree: **a docked window** beside the console, like the table's tree.
4. Tapping the root row: **selects the whole assembly** (as a group: every part lights up, the stick and A / B move it as one, as a
   selected sub-assembly does; `select_group_level` with a level that holds every part of the scope). This replaces "selects nothing" in R3.
