extends RefCounted
## What an occurrence tree is a tree OF (C6, docs/feature-tree-review-2026-11-11.md R1): the Part at its root, the world nodes a row stands for, and the
## actions its bottom bar adds to the ones every tree has (Model.actions_for). The view (occurrence_tree_view.gd) is one component; a window gives it a scope.
##
##   World        the Assembly Tree window: root main.current_root_part_id(), nodes RoomRegistry.world_parts (main.tree_row_nodes), adds Room; it remembers
##                its open rows per document (spec section 12) and dims what is outside an open room (B8).
##   Table PARTS  the design table's PARTS tab: the world's root and nodes, adds Table and Bring (and keeps Room and Delete: the review's B5). It neither
##                remembers rows (the world tree owns the document's entry: two windows writing one entry would undo each other) nor shows room context
##                (as before C6).
##   Room         C7 (the room's own Part and RoomRegistry.parts_in_room).
##
## The parts of a scope that need no scene are static and pure (table_actions), tested in tests/tree_c6.gd.

const GroupIndex := preload("res://scripts/group_index.gd")
const Model := preload("res://scripts/tree/occurrence_tree_model.gd")

const WORLD := "world"
const TABLE := "table"

var kind := WORLD
var offers_room := true ## the bar's Room / Close room (Model.actions_for's room_text)
var room_context := true ## rows outside an open room are dimmed, the inside ones wear the rail (B8)
var remembers_rows := true ## the open rows are stored and restored per document (B7)
var table ## design_table.gd, for the Table scope
var index_builds := 0 ## how many times room_below_index walked the world (a test reads it: once per rebuild, not once per row)


static func world() -> RefCounted:
	return load("res://scripts/tree/occurrence_tree_scope.gd").new()


static func for_table(p_table) -> RefCounted:
	var s = load("res://scripts/tree/occurrence_tree_scope.gd").new()
	s.kind = TABLE
	s.table = p_table
	s.room_context = false
	s.remembers_rows = false
	return s


func bar_prompt() -> String:
	## The bar's line while no row is selected.
	if kind == TABLE:
		return "Select a part to put it on the table or bring it to you; or to Fix, Hide, Isolate, Rename or Delete it."
	return "Select a row to Fix, Hide, Isolate, Rename or Delete it."


# --- the world this scope's rows stand for --------------------------------------------------------------------------------------------------------------------

func root_part_id(main) -> String:
	return str(main.current_root_part_id()) if main != null and main.has_method("current_root_part_id") else ""


func row_nodes(main, path: Array) -> Array:
	## The world's parts a row stands for (its own node, every part under a sub-assembly, the whole world for the root).
	return main.tree_row_nodes(path) if main != null and main.has_method("tree_row_nodes") else []


func select_row(main, path: Array, label: String) -> Dictionary:
	return main.select_tree_row(path, label) if main != null and main.has_method("select_tree_row") else {"ok": false, "kind": "none", "count": 0}


func row_hidden(main, path: Array) -> bool:
	return main != null and main.has_method("tree_row_hidden") and main.tree_row_hidden(path)


func set_row_visible(main, path: Array, vis: bool, label: String) -> void:
	if main != null and main.has_method("set_tree_row_visible"):
		main.set_tree_row_visible(path, vis, label)


func isolate_row(main, path: Array, label: String) -> void:
	if main != null and main.has_method("isolate_tree_row"):
		main.isolate_tree_row(path, label)


func room_below_index(main, root: String, room_parts: Array) -> Dictionary:
	## C6 (10.8 VR leftover 1): which rows have a placement of an open room's Part BELOW them, read once from the world's own nodes (each leaf carries the Parts its
	## path resolves to, group_index.gd `group_parts`), so it is known for a closed row whose children were never fetched. {parts, known: {row key: true} (a leaf
	## of the world lies under that row), below: {row key: true}}. One walk over the world per call (nodes x depth); the view asks once per rebuild.
	index_builds += 1
	var known := {}
	var below := {}
	for n in row_nodes(main, []):
		if not is_instance_valid(n) or not n.has_meta("group_path") or not n.has_meta("group_parts") or str(n.get_meta("group_root", "")) != root:
			continue
		var p: Array = n.get_meta("group_path")
		var parts: Array = n.get_meta("group_parts")
		var deepest := -1 # (the deepest place on the leaf's path that resolves to a room's Part: every row above that place has the room below it)
		for i in parts.size():
			if room_parts.has(str(parts[i])):
				deepest = i
		for k in range(1, p.size() + 1):
			var key := Model.path_key(p.slice(0, k))
			known[key] = true
			if deepest >= k:
				below[key] = true
	return {"parts": room_parts.duplicate(), "known": known, "below": below}


static func room_below_in(index: Dictionary, path: Array) -> int:
	## From room_below_index: 1 = a room's Part is below the row at `path`, 0 = no, -1 = the world cannot say (nothing of the row is on screen with a path: not
	## indexed, left out of the mesh, suppressed).
	var key := Model.path_key(path)
	if (index.get("below", {}) as Dictionary).has(key):
		return 1
	return 0 if (index.get("known", {}) as Dictionary).has(key) else -1


# --- Table / Bring (the Table scope) --------------------------------------------------------------------------------------------------------------------------

func extra_actions(main, row: Dictionary) -> Array:
	## The actions this scope puts in front of the shared ones, [{id, label, enabled, why}] as Model.actions_for.
	if kind != TABLE:
		return []
	var path: Array = row.get("path", [])
	var members := row_nodes(main, path) if not path.is_empty() else []
	return table_actions(row, {
		"node": table_node(main, path) != null,
		"on_table": on_table(path),
		"members": members.size(),
		"open": table != null and bool(table.get("_open")),
	})


static func table_actions(row: Dictionary, ctx: Dictionary) -> Array:
	## Pure. `ctx`: {node: bool (one body of its own in the arena that can be taken), on_table: bool (it is the part on the table now), members: int (world parts
	## under the row), open: bool (the table is open)}. Table and Bring work on one part with geometry; a greyed one says why.
	var path: Array = row.get("path", [])
	var why := ""
	if path.is_empty() or str(row.get("id", "")) == "":
		why = "the assembly itself can't be taken"
	elif bool(ctx.get("on_table", false)):
		why = "it is on the table"
	elif bool(row.get("missing", false)):
		why = "its file is missing"
	elif not bool(ctx.get("node", false)):
		var children = row.get("children")
		var sub: bool = int(ctx.get("members", 0)) > 1 or (children is Array and not (children as Array).is_empty())
		why = "a sub-assembly: take one of its parts" if sub else "nothing of it is in the arena"
	var table_why := why if why != "" or bool(ctx.get("open", true)) else "open the table first"
	return [
		{"id": "table", "label": "Table", "enabled": table_why == "", "why": table_why},
		{"id": "bring", "label": "Bring", "enabled": why == "", "why": why},
	]


func table_node(main, path: Array) -> Node3D:
	## The one arena part a row stands for that can be taken to the table or brought (visible, not held, not in a room, not already on the table), found by PATH
	## (a part inside the second placement of a sub-assembly is not the one inside the first). A world without paths (not indexed yet) falls back to the occurrence
	## id, which is unique only among the root's own parts.
	if table == null or path.is_empty():
		return null
	var nodes := row_nodes(main, path)
	var exact: Array = nodes.filter(func(n) -> bool: return is_instance_valid(n) and n is MeshInstance3D and n.has_meta("group_path") and GroupIndex.path_of(n) == path and _takeable(n))
	if exact.size() == 1:
		return exact[0]
	if not exact.is_empty():
		return null
	var any_indexed := nodes.any(func(n) -> bool: return is_instance_valid(n) and n.has_meta("group_path"))
	if path.size() == 1 and not any_indexed:
		return table.node_for_occurrence(str(path[0]))
	return null


func on_table(path: Array) -> bool:
	var seated = table.get("seated") if table != null else null
	if seated == null or not is_instance_valid(seated) or path.is_empty():
		return false
	if seated.has_meta("group_path"):
		return GroupIndex.path_of(seated) == path
	return path.size() == 1 and str(seated.get_meta("occurrence_id", "")) == str(path[0])


static func _takeable(n: Node3D) -> bool:
	return n.visible and not n.has_meta("on_table") and not n.has_meta("room_id") and not n.get_meta("held", false)
