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
##   B7 (tree call only): Find narrows the tree (names, ":tokens", unknown tokens) without touching the open rows and clearing it reveals the selection; Collapse and To selection;
##     the open rows are remembered per document and restored when it is opened again, never for a document nobody touched or one with no file, never over rows the person
##     changed first, and a tree answer that arrives late for the previous document is dropped
## It runs twice: against a fake backend that serves GET /parts/{id}/assembly-tree (A5: one call for the whole tree, then ?status=true merged in; no per-level
## /occurrences reads), and against one that answers 404 to it (an older backend: the per-level fallback). Every check holds in both modes.
## NOT covered: how any of it looks or feels in the headset (the pulse, the bar's reach and size).
## Run: "$GODOT" --headless --path . --script res://tests/occurrence_tree_actions.gd  (see tests/README.md)

const Model := preload("res://scripts/tree/occurrence_tree_model.gd")
const MatesTool := preload("res://scripts/mates_tool.gd")

var main
var hand
var window
var calls: Array = []
var occurrences := {}
var notfound_once := false ## the next tree call answers 404 "Part not found" (a backend that has the call)
var status_fails := false ## the ?status=true call fails
var null_children := false ## part nodes carry "children": null
var truncated := false
var mode := "tree" ## "tree": the fake serves the tree call; "404": it does not
var hold_tree := false ## the tree call waits (the answer is made when it is asked, delivered when this clears)
var tree_name := "Rig" ## the root's name in the tree answers: tells one document's answer from another's
const PART_NAMES := {"R": "Rig", "S": "Drive", "K": "Bracket", "B": "Bolt"}
const TOP_STATUS := {"s1": {"status": "fixed", "dof": 0}, "s2": {"status": "under_constrained", "dof": 2}}


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
	if method == HTTPClient.METHOD_GET and bits.size() == 2 and bits[1].begins_with("assembly-tree"):
		if mode == "404":
			return {"ok": false, "json": null, "code": 404, "detail": "Not Found", "error": "{ \"detail\": \"Not Found\" }"} # (the framework's answer for an unknown route)
		if notfound_once:
			notfound_once = false
			return {"ok": false, "json": null, "code": 404, "detail": "Part not found", "error": "{ \"detail\": \"Part not found\" }"}
		if status_fails and bits[1].contains("status=true"):
			return {"ok": false, "json": null, "code": 0, "error": ""}
		var resp := tree_response(bits[1].contains("status=true"))
		resp["part_name"] = tree_name
		while hold_tree:
			await process_frame # (a slow answer: made now, delivered when hold_tree clears)
		return {"ok": true, "json": resp, "error": ""}
	if method == HTTPClient.METHOD_GET and bits.size() == 2 and bits[1] == "occurrences":
		return {"ok": true, "json": occurrences.get(bits[0], []), "error": ""}
	if method == HTTPClient.METHOD_GET and bits.size() == 2 and bits[1] == "constraint-status":
		return {"ok": true, "json": {"s1": {"status": "fixed", "dof": 0}, "s2": {"status": "under_constrained", "dof": 2}} if bits[0] == "R" else {}, "error": ""}
	if method == HTTPClient.METHOD_GET and bits.size() == 1:
		return {"ok": true, "json": {"name": PART_NAMES.get(bits[0], bits[0])}, "error": ""}
	if method == HTTPClient.METHOD_PATCH:
		var pb := path.trim_prefix("/parts/").split("/") # (a rename is kept, so a refresh that follows it still shows it)
		if pb.size() == 3 and body is Dictionary and body.has("name_override"):
			for o in occurrences.get(pb[0], []):
				if o["id"] == pb[2]:
					o["name_override"] = body["name_override"] if str(body["name_override"]) != "" else null
		return {"ok": true, "json": {}, "error": ""}
	return {"ok": false, "json": null, "error": "404"}


func tree_nodes(part: String, prefix: Array, with_status: bool) -> Array:
	var out: Array = []
	for o in occurrences.get(part, []):
		var resolved = o.get("resolved_part_id")
		var is_assembly: bool = resolved != null and occurrences.has(resolved)
		var node_path: Array = prefix + [o["id"]]
		var constraint = TOP_STATUS.get(o["id"]) if with_status and part == "R" and resolved != null else null
		out.append({
			"occurrence_id": o["id"], "path": node_path, "external_ref": null, "ref_part_id": resolved, "resolved_part_id": resolved,
			"part_name": PART_NAMES.get(resolved, resolved) if resolved != null else null, "name_override": o.get("name_override"),
			"kind": "missing" if resolved == null else ("assembly" if is_assembly else "part"),
			"fixed": bool(o.get("fixed", false)), "hidden": bool(o.get("hidden", false)), "suppressed": bool(o.get("suppressed", false)), "color": null,
			"constraint": {"status": constraint["status"], "dof": constraint["dof"], "rigid_set": null, "broken_mates": 0, "near_mates": 0} if constraint != null else null,
			"feature_count": 0 if resolved != null else null, "placements": 1, "cycle": false, "truncated": false, "status_failed": false,
			"mates": {"count": 0, "suppressed": 0, "broken": 0, "near": 0, "held": 0, "lost": 0} if is_assembly and with_status else ({"count": 0, "suppressed": 0, "broken": null, "near": null, "held": null, "lost": null} if is_assembly else null),
			"patterns": {"count": 0, "suppressed": 0} if is_assembly else null,
			"problems": {"missing": 0, "cycles": 0, "broken": 0, "over_constrained": 0, "near": 0} if is_assembly and with_status else null,
			"children": tree_nodes(str(resolved), node_path, with_status) if is_assembly else (null if null_children else []),
		})
	return out


func tree_response(with_status: bool) -> Dictionary:
	return {
		"part_id": "R", "part_name": "Rig", "kind": "assembly", "feature_count": 0, "status_included": with_status,
		"mates": {"count": 0, "suppressed": 0, "broken": 0, "near": 0, "held": 0, "lost": 0}, "patterns": {"count": 0, "suppressed": 0},
		"problems": {"missing": 0, "cycles": 0, "broken": 0, "over_constrained": 0, "near": 0},
		"children": tree_nodes("R", [], with_status), "truncated": false, "node_count": 0, "max_depth": 32, "max_nodes": 10000,
		"truncated_depth": truncated, "truncated_nodes": false, "status_failed": false, "status_incomplete": false,
	}


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
	await run_mode("tree")
	await run_mode("404")
	quit(0)


func run_mode(which: String) -> void:
	mode = which
	calls = []
	print("--- fake backend mode: ", which)
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
	if mode == "tree":
		var tree_calls: Array = calls.filter(func(c): return str(c["path"]).contains("/assembly-tree"))
		check("A5: the tree is one call for the structure, then one with ?status=true; no per-level /occurrences read at all", tree_calls.size() == 2 and not str(tree_calls[0]["path"]).contains("status") and str(tree_calls[1]["path"]).ends_with("?status=true") and calls.filter(func(c): return str(c["path"]).ends_with("/occurrences")).is_empty())
		check("A5: the missing file is its own state (a red warning), and the root row is open and does not collapse", rows[2]["state"] == "missing" and rows[2]["missing"] and window._tree[0]["expanded"])
	else:
		check("an older backend: the 404 is remembered and the tree is read a level at a time (occurrences + constraint-status)", window._endpoint_missing and window._resp.is_empty() and calls.filter(func(c): return str(c["path"]).ends_with("/occurrences")).size() >= 1 and calls.filter(func(c): return str(c["path"]) == "/parts/R/constraint-status").size() >= 1)

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

	if mode == "tree":
		# --- A5: grouping (4 or more identical siblings fold into one row), the switch, and what a refresh keeps
		occurrences["R"].append({"id": "extra2", "resolved_part_id": "B"})
		occurrences["R"].append({"id": "extra3", "resolved_part_id": "B"})
		window.request_refresh()
		for i in 80:
			await process_frame
		var spec := Model.visible_rows(window._resp, window._spec_open_keys(), window._grouping(), [])
		var group_rows := spec.filter(func(r): return r["kind"] == "group")
		check("A5: four Bolts at one level fold into one 'Bolt x4' row (grouping is on by default), the rest of the level stays", group_rows.size() == 1 and group_rows[0]["label"] == "Bolt x4" and group_rows[0]["count"] == 4 and spec.filter(func(r): return r["key"] == "s1").size() == 1)
		window._set_grouping(false)
		spec = Model.visible_rows(window._resp, window._spec_open_keys(), window._grouping(), [])
		check("A5: the switch turns grouping off: the four are listed one by one, and the setting is what main saved", spec.filter(func(r): return r["kind"] == "group").is_empty() and not main.tree_grouping())
		window._set_grouping(true)
		spec = Model.visible_rows(window._resp, window._spec_open_keys(), window._grouping(), []) # (rebuilt after the switch: the list from before it has no group)
		check("...and on again: the setting is saved and the four fold into one row again", main.tree_grouping() and spec.filter(func(r): return r["kind"] == "group").size() == 1)
		window._open_groups.clear()
		await window._reveal(["extra3"])
		check("a reveal of a row inside a group opens that group (its key is #group:<first member>)", window._open_groups.has("#group:b0") and Model.visible_rows(window._resp, window._spec_open_keys(), true, []).any(func(r): return r["key"] == "extra3"))
		window._on_row_selected(Model.find_row(window._tree, ["extra3"]))
		check("a member of a group still selects by its own path", window._has_selected and window._selected == ["extra3"])
		await extra_checks()
		await b7_checks()
	main.queue_free()
	await frames(3)


func settle() -> void:
	for i in 80:
		await process_frame


func extra_checks() -> void:
	## Review fixes of A5: Fix / Float shows at once and survives a failed status call; a "Part not found" is not "an older backend"; a missing route falls back on a
	## refresh and the flag clears with the document; a node with "children": null; the status failure's words.
	var row_s2: Dictionary = Model.find_row(window._tree, ["s2"])
	check("(before) the under-constrained row wears the open lock", Model.state_icon(row_s2) == "lock_open" and row_s2["state"] == "under_constrained")
	var real_mates = main._mates_tool
	var mates := FakeMates.new()
	mates.command_stack = main.command_stack
	mates.backend_url = "http://example.invalid"
	mates.api_key = "k"
	main.add_child(mates)
	await process_frame
	mates._nested_states["R"] = {"occurrences": {"s2": {"fixed": false}}, "mated": {}}
	main._mates_tool = mates
	await window._on_bar_action("fix", row_s2, {})
	row_s2 = Model.find_row(window._tree, ["s2"])
	check("Fix on an under-constrained row: its icon is the pin at once (before any refresh)", row_s2["state"] == "fixed" and Model.state_icon(row_s2) == "pin")
	occurrences["R"][1]["fixed"] = true # (the server now says so too)
	status_fails = true
	truncated = true
	await settle()
	row_s2 = Model.find_row(window._tree, ["s2"])
	check("...and with the status call failing afterwards it stays a pin (the old status is not carried over a changed flag)", row_s2["state"] == "fixed" and Model.state_icon(row_s2) == "pin")
	check("the status failure says why (a reason even when the error is empty) and keeps the truncation note", window._status_label.text.contains("Constraint states unavailable: no answer") and window._status_label.text.contains("cut off"))
	status_fails = false
	truncated = false
	main._mates_tool = real_mates
	mates.queue_free()

	null_children = true
	window.request_refresh()
	await settle()
	var leaf_node: Dictionary = (window._resp["children"] as Array)[3]
	check("a node with \"children\": null is read as no children (rows, bubbles and the walk all cope)", leaf_node["children"] is Array and (leaf_node["children"] as Array).is_empty() and window._tree[0]["children"].size() >= 4 and Model.visible_rows(window._resp, [], true, []).size() > 4)
	null_children = false

	notfound_once = true
	window._stale = true
	await window._refresh_root()
	check("a 404 'Part not found' is an answer, not an older backend: the call is still used and the failure is shown", not window._endpoint_missing and window._status_label.text.contains("Part not found") and window._fold_button.visible)
	await window._refresh_root()
	check("...and the next refresh reads the tree normally", not window._endpoint_missing and not window._resp.is_empty() and not window._stale)

	mode = "404"
	occurrences["R"].append({"id": "late", "resolved_part_id": "B"})
	window.request_refresh()
	await settle()
	check("the route going missing mid-session: the refresh falls back to the per-level read and the new row still arrives", window._endpoint_missing and window._resp.is_empty() and not Model.find_row(window._tree, ["late"]).is_empty())
	check("...and the Fold x4 button is hidden while the fallback is in use", not window._fold_button.visible)
	mode = "tree"
	window.mark_stale()
	await settle()
	check("a new document clears the flag: the tree call is used again and the button is back", not window._endpoint_missing and not window._resp.is_empty() and window._fold_button.visible)


# --- B7: Find, Collapse, To selection, remembered open rows ----------------------------------------------------------------------------------------------------------

func press_arrow(key: String) -> bool:
	## A press on the row's chevron, through the control the window drew for it. False when the row has no control on screen.
	for line in window.visible_lines():
		var d: Dictionary = line.get_meta("desc", {})
		if d.is_empty():
			continue
		var line_key := str(d["srow"]["key"]) if str(d["kind"]) != "row" else Model.path_key((d["row"] as Dictionary).get("path", []))
		if line_key == key:
			await window._on_line_arrow(line)
			return true
	return false


func listed_keys() -> Array:
	return window._descs.map(func(d): return str(d["srow"]["key"]) if str(d["kind"]) != "row" else Model.path_key((d["row"] as Dictionary).get("path", [])))


func b7_checks() -> void:
	var settings = main._settings
	settings.tree_open_docs = {}
	var doc_a := "user://b7_doc_a.didsa"
	var doc_b := "user://b7_doc_b.didsa"
	main._opened_native_path = doc_a
	window.mark_stale()
	await settle()
	check("B7: a document with a file is keyed by it, and a tree nobody touched stores nothing", window._doc_key == doc_a and settings.tree_open_keys(doc_a) == null and settings.tree_open_docs.is_empty())
	window._set_grouping(false) # (the rows below are easier to name one by one)
	check("B7: the chevron presses reach rows on screen (the pool is drawn)", window.visible_lines().size() > 3)
	await press_arrow("s2")
	await press_arrow("s2/k1")
	check("B7: opening rows stores them, in the spec's order", settings.tree_open_keys(doc_a) == ["s2", "s2/k1"])
	await press_arrow("s2")
	check("B7: closing a row stores that too (its open child keeps its key, so reopening the parent brings it back)", settings.tree_open_keys(doc_a) == ["s2/k1"])
	await press_arrow("s2")
	check("...and opening it again brings the child back as it was", settings.tree_open_keys(doc_a) == ["s2", "s2/k1"])

	# --- the document is opened again: its rows come back, the selection is not touched
	window._has_selected = true
	window._selected = ["b0"]
	window.mark_stale()
	await settle()
	check("B7: opened again, the remembered rows are open and nothing else; the selection is left as it was", bool(Model.find_row(window._tree, ["s2"])["expanded"]) and bool(Model.find_row(window._tree, ["s2", "k1"])["expanded"]) and not bool(Model.find_row(window._tree, ["s1"])["expanded"]) and window._restored_any)
	check("B7: a restore alone writes nothing (the entry is as it was)", settings.tree_open_keys(doc_a) == ["s2", "s2/k1"])

	# --- Find
	var before_open: Array = window._spec_open_keys()
	window.set_query(":missing")
	var keys := listed_keys()
	check("B7: ':missing' lists the root and the missing row only", keys == ["", "gone"] and window.current_query() == ":missing" and window._query_box.visible)
	check("B7: the query shows under the title with the match count", window._query_label.text.contains(":missing") and window._query_hint.text.contains("1 match"))
	window.set_query("zzz")
	check("B7: no match: the root alone, and the hint says so", listed_keys() == [""] and window._query_hint.text.contains("No matches"))
	window.set_query("bolt :foo")
	keys = listed_keys()
	check("B7: a name term lists the matches and what is above them (the closed s1 and s2 show open because a Bolt is below them), not the rest", keys.has("s1/k1/kb") and keys.has("s1") and keys.has("s1/k1") and keys.has("b0") and not keys.has("gone") and not keys.has("s1/k1/") and window._tree[0]["children"].size() > 4)
	check("...an unknown token is named in the hint and left out of the matching", window._query_hint.text.contains("Unknown filter :foo"))
	check("B7: the filter did not change the open rows (nor what was stored)", window._spec_open_keys() == before_open and settings.tree_open_keys(doc_a) == ["s2", "s2/k1"])
	var shown_before := listed_keys()
	await press_arrow("s1")
	check("B7: the chevrons are inert while a filter is on", listed_keys() == shown_before and window._spec_open_keys() == before_open)
	window.set_query(":errors")
	check("B7: ':errors' without constraint states loaded finds only what the spec lists (the missing file), and says the states are still loading when they are", listed_keys() == ["", "gone"])
	window.clear_query()
	check("B7: clearing the filter gives the open rows again, the same as before", window.current_query() == "" and not window._query_box.visible and window._spec_open_keys() == before_open and listed_keys().has("s2/k1/kb") and not listed_keys().has("s1/k1"))

	# --- Select a row under a filter, clear the filter: the row is revealed
	window.collapse_all()
	check("B7: Collapse closes every row (the root stays) and stores that", window._spec_open_keys().is_empty() and settings.tree_open_keys(doc_a) == [] and listed_keys().size() == window._tree[0]["children"].size() + 1)
	window.set_query("bolt")
	window._selected = ["s1", "k1", "kb"]
	window._has_selected = true
	window.clear_query()
	await settle()
	check("B7: a row selected while the filter was on is revealed when it is cleared", listed_keys().has("s1/k1/kb") and settings.tree_open_keys(doc_a) == ["s1", "s1/k1"])
	window.collapse_all()
	window._selected = ["s2", "k1", "kb"]
	window._has_selected = true
	await window.expand_to_selection()
	check("B7: To selection opens what is above the selected row, and stores it", listed_keys().has("s2/k1/kb") and settings.tree_open_keys(doc_a) == ["s2", "s2/k1"])
	window._has_selected = false
	window.collapse_all()
	await window.expand_to_selection()
	check("B7: To selection with nothing selected says so and opens nothing", window._spec_open_keys().is_empty() and window._status_label.text.contains("Nothing selected"))

	# --- Save As: the remembered rows follow the file
	await press_arrow("s1")
	check("(before Save As) one row open", settings.tree_open_keys(doc_a) == ["s1"])
	var doc_c := "user://b7_doc_c.didsa"
	main._opened_native_path = doc_c
	window.note_document_changed()
	check("B7: after Save As the open rows are stored under the new file too", window._doc_key == doc_c and settings.tree_open_keys(doc_c) == ["s1"])

	# --- a late answer for the previous document is dropped, and its rows are not applied to the new one
	settings.tree_open_docs = {}
	settings.set_tree_open_keys(doc_a, ["s2"])
	settings.set_tree_open_keys(doc_b, ["s1"])
	main._opened_native_path = doc_a
	tree_name = "Old"
	hold_tree = true
	window.mark_stale()
	await frames(3) # (document A's request is in flight and waiting)
	main._opened_native_path = doc_b
	tree_name = "New"
	window.mark_stale()
	await frames(3)
	hold_tree = false
	await settle()
	check("B7: the answer for the document that was left is dropped: the tree is the new document's", window._resp.get("part_name", "") == "New" and window._tree[0]["name"] == "New")
	check("...the new document's rows are restored, not the old one's, and the old one's entry is untouched", bool(Model.find_row(window._tree, ["s1"])["expanded"]) and not bool(Model.find_row(window._tree, ["s2"])["expanded"]) and settings.tree_open_keys(doc_a) == ["s2"] and settings.tree_open_keys(doc_b) == ["s1"])

	# --- the same with the window closed while the old answer is in flight (nothing starts a newer load until it is opened again)
	tree_name = "Old2"
	hold_tree = true
	window.mark_stale()
	await frames(3)
	window.close()
	main._opened_native_path = doc_a
	window.mark_stale() # (closed: no new request)
	hold_tree = false
	await settle()
	check("B7: a tree answer that lands after the document changed under a closed window is dropped too (nothing shown, still stale)", window._tree.is_empty() and window._stale and window._resp.is_empty())
	tree_name = "Rig"
	window.open()
	await settle()
	check("...and opening the window loads the new document, with its rows restored", window._tree[0]["name"] == "Rig" and bool(Model.find_row(window._tree, ["s2"])["expanded"]))
	main._opened_native_path = doc_b

	# --- rows the person changed before the first answer are not overwritten by a restore
	tree_name = "Rig"
	hold_tree = true
	window.mark_stale()
	await frames(3)
	window._open_touched = true # (what the chevron, Collapse, To selection and a viewport pick set)
	hold_tree = false
	await settle()
	check("B7: a restore never overwrites what the person changed before the first answer", not bool(Model.find_row(window._tree, ["s1"])["expanded"]) and settings.tree_open_keys(doc_b) == ["s1"])

	# --- a session with no file keeps nothing
	main._opened_native_path = ""
	window.mark_stale()
	await settle()
	var docs_before: int = settings.tree_open_docs.size()
	await press_arrow("s1")
	window.collapse_all()
	check("B7: a document with no file key stores nothing and restores nothing", window._doc_key == "" and settings.tree_open_docs.size() == docs_before and not settings.tree_open_docs.has(""))
	main._opened_native_path = ""
	window._set_grouping(true) # (the switch is saved with the settings: leave it as the other checks expect)
