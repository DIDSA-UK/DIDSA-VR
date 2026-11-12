extends SceneTree
## V-7 / phase T1: the Assembly Tree against a world with TWO placements of one sub-assembly (a fake backend answers the window's requests; the mates tool's own
## requests are answered by a recording stand-in), the full scene (scenes/main.tscn), no real backend.
##   tree -> world: a child row under the SECOND placement selects the second's part, not the first's (B1); a sub-assembly row selects the whole group; the root row
##     selects every part as one group (B2); pressing the selected row again clears it; a row with nothing on screen says so
##   world -> tree: selecting a nested part in the world expands the rows above it, marks its row and scrolls to it
##   rows: instance names "Drive <1>" / "Drive <2>", the state icon from the constraint status and the fixed flag, a missing file's amber row
##   bar: Fix / Float PATCHes the occurrence on its parent Part, updates the state at any depth, one undo step; Hide / Show and Isolate are view-only and undoable
##        (the backend's `hidden` flag is never written); Rename PATCHes name_override, undoably; Delete on a nested row warns that it edits every placement (B3)
##   refresh keeps what was expanded and the selection (B4); and a fix made from the tree makes the V-1 refusal fire on a grip
## NOT covered: how any of it looks or feels in the headset (the pulse, the bar's reach and size).
## Run: "$GODOT" --headless --path . --script res://tests/occurrence_tree_actions.gd  (see tests/README.md)

const Model := preload("res://scripts/tree/occurrence_tree_model.gd")
const MatesTool := preload("res://scripts/mates_tool.gd")

var main
var hand
var window
var calls: Array = []
var occurrences := {}


class FakeMates extends "res://scripts/mates_tool.gd":
	var patches: Array = []

	func _api_request(method: int, path: String, body_dict) -> Dictionary:
		if method == HTTPClient.METHOD_PATCH:
			patches.append({"path": path, "body": body_dict})
			return {"ok": true, "code": 200, "json": {}, "error": ""}
		return {"ok": false, "code": 404, "json": {}, "error": "404"}


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func answer(method: int, path: String, body) -> Dictionary:
	calls.append({"method": method, "path": path, "body": body})
	var bits := path.trim_prefix("/parts/").split("/")
	if method == HTTPClient.METHOD_GET and bits.size() == 2 and bits[1] == "occurrences":
		return {"ok": true, "json": occurrences.get(bits[0], []), "error": ""}
	if method == HTTPClient.METHOD_GET and bits.size() == 2 and bits[1] == "constraint-status":
		return {"ok": true, "json": {"s1": {"status": "fixed", "dof": 0}, "s2": {"status": "under_constrained", "dof": 2}} if bits[0] == "R" else {}, "error": ""}
	if method == HTTPClient.METHOD_GET and bits.size() == 1:
		return {"ok": true, "json": {"name": {"R": "Rig", "S": "Drive", "K": "Bracket", "B": "Bolt"}.get(bits[0], bits[0])}, "error": ""}
	if method == HTTPClient.METHOD_PATCH:
		return {"ok": true, "json": {}, "error": ""}
	return {"ok": false, "json": null, "error": "404"}


func leaf(owner: String, occ: String, path: Array, parts: Array, at: Vector3) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(0.1, 0.1, 0.1)
	m.mesh = b
	m.set_meta("owner_part_id", owner)
	m.set_meta("occurrence_id", occ)
	m.set_meta("group_path", path)
	m.set_meta("group_parts", parts)
	m.set_meta("group_names", parts.map(func(p): return {"S": "Drive", "K": "Bracket", "B": "Bolt"}.get(p, p)))
	m.set_meta("group_root", "R")
	m.add_to_group("grabbable_parts")
	main.assembly_root.add_child(m)
	m.position = at
	return m


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	hand = main.get_node("XROrigin3D/RightController")
	main._resolved_part_id = "R"
	occurrences = {
		"R": [{"id": "s1", "resolved_part_id": "S", "fixed": true}, {"id": "s2", "resolved_part_id": "S"}, {"id": "gone", "resolved_part_id": null}, {"id": "b0", "resolved_part_id": "B"}],
		"S": [{"id": "k1", "resolved_part_id": "K"}],
		"K": [{"id": "kb", "resolved_part_id": "B"}],
	}
	# the world: two placements of the drive, each a bracket holding a bolt, and a top-level bolt
	var bolt1 := leaf("K", "kb", ["s1", "k1", "kb"], ["S", "K", "B"], Vector3(0, 1, -1))
	var bolt2 := leaf("K", "kb", ["s2", "k1", "kb"], ["S", "K", "B"], Vector3(1, 1, -1))
	var bolt2b := leaf("K", "kb2", ["s2", "k1", "kb2"], ["S", "K", "B"], Vector3(1.3, 1, -1))
	var top := leaf("R", "b0", ["b0"], ["B"], Vector3(3, 1, -1))
	window = main._assembly_tree_window
	window.request_hook = Callable(self, "answer")
	window.backend_url = "http://example.invalid"
	window.api_key = "k"
	window.open()
	await frames(6)

	# --- rows
	var rows: Array = window._tree[0]["children"]
	check("the root row is the assembly and its children are the placed occurrences", window._tree[0]["name"] == "Rig" and rows.size() == 4)
	check("two placements of one Part are told apart: Drive <1>, Drive <2>", rows[0]["name"] == "Drive <1>" and rows[1]["name"] == "Drive <2>" and rows[3]["name"] == "Bolt")
	check("the state icon: pin from the constraint status 'fixed', open lock for under-constrained, a warning for a missing file, none for a free part", Model.state_icon(rows[0]) == "pin" and Model.state_icon(rows[1]) == "lock_open" and Model.state_icon(rows[2]) == "warning" and Model.state_icon(rows[3]) == "")
	check("the status was read once for the level", calls.filter(func(c): return str(c["path"]) == "/parts/R/constraint-status").size() >= 1)

	# --- tree -> world
	await window._expand_row(rows[0])
	await window._expand_row(rows[1])
	await window._expand_row(rows[1]["children"][0])
	await frames(2)
	var second_bolt_row: Dictionary = Model.find_row(window._tree, ["s2", "k1", "kb"])
	check("the nested rows exist under each placement with their own paths", not second_bolt_row.is_empty() and second_bolt_row["path"] == ["s2", "k1", "kb"])
	window._on_row_selected(second_bolt_row)
	check("B1: a bolt row under the SECOND drive selects the second drive's bolt, not the first's", hand.selected_node == bolt2 and hand.selected_node != bolt1)
	window._on_row_selected(second_bolt_row)
	check("pressing the selected row again clears the selection", hand.selected_node == null and not window._has_selected)
	var drive_row: Dictionary = rows[1]
	window._on_row_selected(drive_row)
	check("a sub-assembly row selects all of it as one group: both bolts of the second drive, not the first's", hand._sel_group != null and hand._sel_group.members.size() == 2 and hand._sel_group.members.has(bolt2) and hand._sel_group.members.has(bolt2b) and not hand._sel_group.members.has(bolt1) and hand.selected_group_prefix() == ["s2"])
	window._on_row_selected(drive_row)
	window._on_row_selected(window._tree[0])
	check("B2: the root row selects the whole assembly as one group: every part of the world", hand._sel_group != null and hand._sel_group.members.size() == 4 and hand.selected_group_prefix() == [])
	window._on_row_selected(window._tree[0])
	check("...and pressing the root row again clears it", hand.selected_node == null)
	window._on_row_selected(rows[2])
	check("a row with nothing on screen says so instead of selecting something", hand.selected_node == null and window._status_label.text.contains("Nothing of"))
	window._has_selected = false

	# --- world -> tree
	for r in rows:
		r["expanded"] = false
	window._rebuild_rows()
	hand.select_external(bolt1, bolt1.global_position)
	await frames(6)
	var first_bolt_row: Dictionary = Model.find_row(window._tree, ["s1", "k1", "kb"])
	check("world -> tree: selecting a nested part expands the rows above it and marks its row", window._has_selected and window._selected == ["s1", "k1", "kb"] and bool(rows[0]["expanded"]) and not first_bolt_row.is_empty() and window._row_controls.has("s1/k1/kb"))
	hand._clear_selection()
	await frames(3)
	check("...and clearing it in the world clears the mark", not window._has_selected)

	# --- the bar: view-only hide and isolate, undoable
	window._on_row_selected(first_bolt_row)
	var hide_label: String = (Model.actions_for(first_bolt_row, {"has_nodes": true, "hidden": false}) as Array)[1]["label"]
	main.set_tree_row_visible(["s1", "k1", "kb"], false, "Bolt")
	check("Hide is view-only: the node is hidden, no request went to the backend, the hidden row reads hidden", hide_label == "Hide" and not bolt1.visible and bolt2.visible and main.tree_row_hidden(["s1", "k1", "kb"]) and calls.filter(func(c): return c["method"] != HTTPClient.METHOD_GET).is_empty())
	main.command_stack.undo()
	check("...and one undo step shows it again", bolt1.visible)
	main.isolate_tree_row(["s2"], "Drive <2>")
	check("Isolate keeps only what the row stands for", bolt2.visible and not bolt1.visible and not top.visible)
	main.command_stack.undo()
	check("...and undoes in one step", bolt1.visible and top.visible)
	hand._clear_selection()

	# --- Fix / Float (the mates tool, a recording stand-in), at depth, undoable; and the grip refusal that follows (V-1)
	var mates := FakeMates.new()
	mates.command_stack = main.command_stack
	mates.backend_url = "http://example.invalid"
	mates.api_key = "k"
	main.add_child(mates)
	await process_frame
	mates._nested_states["K"] = {"occurrences": {"kb": {"fixed": false}}, "mated": {}}
	var changed: bool = await mates.toggle_fixed_occurrence("K", "kb", "Bolt")
	check("Fix PATCHes the occurrence on ITS PARENT Part (a nested row: the sub-assembly's own Part) and records it", changed and mates.patches.size() == 1 and mates.patches[0]["path"] == "/parts/K/occurrences/kb" and mates.patches[0]["body"] == {"fixed": true} and mates.group_fixed("K", "kb"))
	main.command_stack.undo()
	await frames(4)
	check("one undo step floats it again (a second PATCH)", mates.patches.size() == 2 and mates.patches[1]["body"] == {"fixed": false} and not mates.group_fixed("K", "kb"))
	main.command_stack.redo()
	await frames(4)
	check("...and redo fixes it", mates.group_fixed("K", "kb") and mates.patches.size() == 3)
	hand.mates_tool = mates
	check("V-1 after a fix at depth 3, a grip on that bolt's level is refused with the 'Part is fixed' words", hand.refusal_for({"depth": 3, "prefix": ["s1", "k1", "kb"], "label": "Bolt"}, bolt1).get("short", "").begins_with("Part is fixed"))
	mates.set_occurrence_fixed("K", "kb", false, "Bolt", false)

	# --- Rename
	await window._apply_rename(rows[3], "R", "b0", "Cap screw", "")
	var rename_call: Dictionary = calls.filter(func(c): return c["method"] == HTTPClient.METHOD_PATCH).back()
	check("Rename PATCHes name_override on the parent Part and the row shows the new name", rename_call["path"] == "/parts/R/occurrences/b0" and rename_call["body"] == {"name_override": "Cap screw"} and rows[3]["name"] == "Cap screw")
	main.command_stack.undo()
	await frames(4)
	var undo_call: Dictionary = calls.filter(func(c): return c["method"] == HTTPClient.METHOD_PATCH).back()
	check("...and undo sets it back (an empty override clears it)", undo_call["body"] == {"name_override": ""})

	# --- Delete warns about every placement for a nested row (B3)
	var nested_row := Model.find_row(window._tree, ["s1", "k1", "kb"])
	check("Delete on a nested row warns that it edits every placement of its assembly (B3)", Model.delete_warning(nested_row, 2) != "" and Model.delete_warning(rows[3], 5) == "")

	# --- B4: a refresh keeps what was expanded and the selection
	window._on_row_selected(Model.find_row(window._tree, ["s2", "k1", "kb"]))
	occurrences["R"].append({"id": "extra", "resolved_part_id": "B"})
	window.request_refresh()
	for i in 80:
		await process_frame
	check("B4: after a change the open rows stay open, the new row appears, the selection stays", window._tree[0]["children"].size() == 5 and bool(Model.find_row(window._tree, ["s2"])["expanded"]) and not Model.find_row(window._tree, ["s2", "k1", "kb"]).is_empty() and window._has_selected and window._selected == ["s2", "k1", "kb"])
	quit(0)
