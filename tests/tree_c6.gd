extends SceneTree
## Tree C6: the one occurrence tree component with scopes (scripts/tree/occurrence_tree_view.gd, occurrence_tree_scope.gd), the design table's PARTS tab on it, and
## 10.8's VR leftovers 1-3. Full scene (main.tscn, the design table) against a small fake backend; a stub session observer for leftover 3.
##   1. the PARTS tab reads the tree call (as the World tree does) and has Find; Find and the grouping switch hide on the BUILD tab; it does not store open rows
##   2. its bottom bar offers Table / Bring / Fix / Hide / Isolate / Rename / Room / Delete for a placed part, Table first; the rows carry no inline buttons
##   3. on a sub-assembly row Table and Bring are greyed with the reason in the hint; Table seats the part found by PATH; then Table reads "it is on the table";
##      Hide from the PARTS bar hides the part; a row with nothing in the arena is greyed with its reason; the pure rule (Scope.table_actions) for the root and a
##      closed table
##   4. the PARTS tab's Find words go with another document and stay across Save As (main.gd tells it as it tells the World tree); its bar follows the seat while
##      PARTS shows (a part lifted off the table can be taken again)
##   5. leftover 1: the per-level fallback, a room open on a Part below a CLOSED row whose children were never fetched: the row is the way to it (not dimmed),
##      from the world's nodes; a closed row the world cannot answer for stays dimmed and the bar says why
##   6. leftover 2: apply_theme binds again only the rows on screen; the pool's margin rows are bound again when a scroll or a taller list brings them on
##   7. leftover 3: a model that fails to show leaves no old revision behind: the new document's first events are not taken as old, and its next change shows it as
##      a new document (title, revision), not as a re-read of the old one
## NOT covered: the headset; how the bar looks (the render check's PARTS-tab picture: tools/assembly_tree_render_check/, scenario p).
## Run: "$GODOT" --headless --path . --script res://tests/tree_c6.gd  (see tests/README.md)

const Model := preload("res://scripts/tree/occurrence_tree_model.gd")
const Scope := preload("res://scripts/tree/occurrence_tree_scope.gd")

var main
var table
var tree
var box: MeshInstance3D
var cyl: MeshInstance3D
var calls: Array = []
var root_id := "R"


class FakeRooms extends Node:
	signal rooms_changed
	var parts: Array = []

	func open_part_ids() -> Array:
		return parts.duplicate()

	func is_open_for(part_id: String) -> bool:
		return parts.has(part_id)

	func is_placing_for(_part_id: String) -> bool:
		return false

	func edit_api():
		return null


class FakeMain extends Node:
	var shown: Array = []

	func say(_text: String) -> void:
		pass

	func session_show_model(_bytes: PackedByteArray, same_document: bool = false) -> bool:
		shown.append(same_document)
		return true

	func session_apply_place(_place) -> void:
		pass

	func swap_part_mesh(_nodes: Array, _bytes: PackedByteArray) -> void:
		pass


class FakeRows extends Node:
	var nodes: Array = []
	var reads := 0

	func tree_row_nodes(_path: Array) -> Array:
		reads += 1
		return nodes


class FakeClient extends Node:
	var snapshot := {}


class StubObserver extends "res://scripts/session/session_observer.gd":
	var fetch_ok := true
	var fetches := 0

	func _fetch_glb(_part_id: String, _model: Dictionary) -> Dictionary:
		fetches += 1
		await Engine.get_main_loop().process_frame
		return {"ok": fetch_ok, "changed": true, "bytes": PackedByteArray([1, 2, 3]), "error": "boom"}

	func _index() -> void:
		pass

	func _apply_visibility(_arg: bool = false) -> void:
		pass

	func _apply_section() -> void:
		pass


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func until(condition: Callable, seconds: float = 4.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not condition.call() and Time.get_ticks_msec() < end:
		await process_frame
	return condition.call()


func node(id: String, part: String, name: String, children: Array, prefix: Array) -> Dictionary:
	return {
		"occurrence_id": id, "path": prefix + [id], "external_ref": null, "ref_part_id": part, "resolved_part_id": part, "part_name": name, "name_override": null,
		"kind": "assembly" if not children.is_empty() else "part", "fixed": false, "hidden": false, "suppressed": false, "color": null, "constraint": null,
		"feature_count": 0, "placements": 1, "cycle": false, "truncated": false, "status_failed": false, "mates": null, "patterns": null, "problems": null, "children": children,
	}


func tree_answer(with_status: bool) -> Dictionary:
	# Sub (s1) holding the box and the cylinder (the fixture's two bodies), and a part with nothing in the arena.
	var children := [
		node("s1", "SUB", "Sub", [node("occ_box", "PART_BOX", "Box", [], ["s1"]), node("occ_cyl", "PART_CYL", "Cylinder", [], ["s1"])], []),
		node("occ_gone", "PART_X", "Elsewhere", [], []),
	]
	return {
		"part_id": root_id, "part_name": "Rig", "kind": "assembly", "feature_count": 0, "status_included": with_status,
		"mates": {"count": 0, "suppressed": 0, "broken": 0, "near": 0, "held": 0, "lost": 0}, "patterns": {"count": 0, "suppressed": 0},
		"problems": {"missing": 0, "cycles": 0, "broken": 0, "over_constrained": 0, "near": 0},
		"children": children, "truncated": false, "node_count": 4, "max_depth": 32, "max_nodes": 10000,
		"truncated_depth": false, "truncated_nodes": false, "status_failed": false, "status_incomplete": false,
	}


func answer(method: int, path: String, _body) -> Dictionary:
	calls.append(path)
	if method == HTTPClient.METHOD_GET and path.begins_with("/parts/%s/assembly-tree" % root_id):
		return {"ok": true, "json": tree_answer(path.contains("status=true")), "error": ""}
	return {"ok": false, "json": null, "code": 404, "detail": "Not Found", "error": "404"}


func bar_texts(win) -> Array:
	return win._bar_buttons.get_children().map(func(b): return (b as Button).text)


func bar_button(win, text: String) -> Button:
	for b in win._bar_buttons.get_children():
		if (b as Button).text == text:
			return b
	return null


func select(win, path: Array) -> void:
	win._selected = path
	win._has_selected = true
	win._rebuild_bar()


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0, 1.6, 0)
	main._show_model(FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb"), "", 0.001)
	await process_frame
	main._resolved_part_id = "R"
	main._opened_native_path = "user://tree_c6.didsa"
	main._settings.tree_open_docs = []
	for p in get_nodes_in_group("grabbable_parts"):
		var occ := str(p.get_meta("occurrence_id", ""))
		var leaf := "PART_BOX" if occ == "occ_box" else "PART_CYL"
		p.set_meta("owner_part_id", "SUB")
		p.set_meta("group_root", "R")
		p.set_meta("group_path", ["s1", occ])
		p.set_meta("group_parts", ["SUB", leaf])
		if occ == "occ_box":
			box = p
		else:
			cyl = p
	table = main.design_table
	tree = table.tree
	tree.request_hook = Callable(self, "answer")
	tree.backend_url = "http://example.invalid"
	tree.api_key = "k"

	# --- 1. the PARTS tab on the tree call
	table.open()
	var loaded: bool = await until(func() -> bool: return tree._endpoint_active())
	check("1. (setup) the box and cylinder are indexed under s1", box != null and cyl != null)
	check("1. the PARTS tab reads the tree call, as the World tree does (%s)" % str(calls.slice(0, 2)), loaded and calls.has("/parts/R/assembly-tree") and not calls.any(func(c): return str(c).ends_with("/occurrences")))
	check("1. ...it has the World tree's Scope object with the Table kind", tree.scope.kind == Scope.TABLE and main._assembly_tree_window.scope.kind == Scope.WORLD)
	check("1. Find shows on PARTS; the grouping switch is the World tree's (one saved setting), not in the docked header", tree._find_button != null and tree._find_button.visible and not tree._fold_button.visible)
	tree.show_tab("build")
	check("1. ...Find hides on BUILD", not tree._find_button.visible and not tree._fold_button.visible)
	tree.show_tab("parts")
	check("1. ...and shows again on PARTS", tree._find_button.visible and not tree._fold_button.visible)
	var sub_row: Dictionary = Model.find_row(tree._tree, ["s1"])
	tree._open_touched = true
	await tree._expand_row(sub_row)
	tree._store_open_keys()
	await frames(2)
	check("1. opening a row on PARTS stores nothing (the World tree owns the document's remembered rows)", bool(sub_row["expanded"]) and main._settings.tree_open_keys("user://tree_c6.didsa") == null)
	check("1. ...the rows listed: root, Sub, Box, Cylinder, Elsewhere (%d)" % tree.row_count(), tree.row_count() == 5)

	# --- 2. the bar for a placed part
	select(tree, ["s1", "occ_cyl"])
	check("2. the PARTS bar offers Table / Bring / Fix / Hide / Isolate / Rename / Room / Delete for a placed part (%s)" % str(bar_texts(tree)), bar_texts(tree) == ["Table", "Bring", "Fix", "Hide", "Isolate", "Rename", "Room", "Delete"])
	check("2. ...Table and Bring enabled for a part in the arena", not bar_button(tree, "Table").disabled and not bar_button(tree, "Bring").disabled and not bar_button(tree, "Delete").disabled)
	var extras := 0
	for l in tree._pool:
		extras += l.get_child_count() - tree.LINE_BASE
	check("2. the rows carry no inline buttons (%d extra)" % extras, extras == 0)

	# --- 3. greyed with reasons; Table, Hide
	select(tree, ["s1"])
	check("3. on a sub-assembly row Table and Bring are greyed (%s)" % tree._bar_hint.text, bar_button(tree, "Table").disabled and bar_button(tree, "Bring").disabled)
	check("3. ...with the reason in the hint, said once for both", tree._bar_hint.text.contains("Table, Bring: a sub-assembly: take one of its parts"))
	select(tree, ["s1", "occ_box"])
	bar_button(tree, "Table").pressed.emit()
	await frames(2)
	check("3. Table seats the part the row stands for, found by its path", table.seated == box)
	tree.show_tab("parts")
	select(tree, ["s1", "occ_box"])
	check("3. ...then Table is greyed: it is on the table (%s)" % tree._bar_hint.text, bar_button(tree, "Table").disabled and tree._bar_hint.text.contains("Table, Bring: it is on the table"))
	table.return_part()
	await frames(1)
	select(tree, ["s1", "occ_cyl"])
	bar_button(tree, "Hide").pressed.emit()
	await frames(1)
	check("3. Hide from the PARTS bar hides the part in the view (undoably)", not cyl.visible and main.command_stack.can_undo())
	main.command_stack.undo()
	await frames(1)
	select(tree, ["occ_gone"])
	check("3. a row with nothing in the arena: Table greyed with its reason (%s)" % tree._bar_hint.text, bar_button(tree, "Table").disabled and tree._bar_hint.text.contains("nothing of it is in the arena"))
	var root_actions: Array = Scope.table_actions({"id": "", "path": []}, {"node": false})
	check("3. (pure) the root row: Table and Bring greyed, the assembly itself", not root_actions[0]["enabled"] and not root_actions[1]["enabled"] and str(root_actions[0]["why"]).contains("the assembly itself"))
	var closed: Array = Scope.table_actions({"id": "p", "path": ["p"]}, {"node": true, "open": false})
	check("3. (pure) a closed table greys Table, not Bring", not closed[0]["enabled"] and str(closed[0]["why"]) == "open the table first" and closed[1]["enabled"])
	# (the review's finding: a hidden part was told "nothing of it is in the arena")
	cyl.visible = false
	select(tree, ["s1", "occ_cyl"])
	check("3. a hidden part: Table greyed because it is hidden, not 'nothing of it is in the arena' (%s)" % tree._bar_hint.text, bar_button(tree, "Table").disabled and tree._bar_hint.text.contains("it is hidden: show it first") and not tree._bar_hint.text.contains("nothing of it"))
	cyl.visible = true
	select(tree, ["occ_gone"])
	select(tree, ["s1", "occ_cyl"])
	check("3. ...shown again, Table is back", not bar_button(tree, "Table").disabled)
	var hidden_actions: Array = Scope.table_actions({"id": "p", "path": ["p"]}, {"node": false, "hidden": true})
	check("3. (pure) a hidden row's reason names the hiding", not hidden_actions[0]["enabled"] and str(hidden_actions[0]["why"]) == "it is hidden: show it first" and str(hidden_actions[1]["why"]) == "it is hidden: show it first")
	# (the review's finding: the row's nodes are read once per bar, not once for the members and again inside table_node)
	var rows_main := FakeRows.new()
	rows_main.nodes = [cyl]
	tree.scope.extra_actions(rows_main, Model.find_row(tree._tree, ["s1", "occ_cyl"]))
	check("3. the bar reads the world's nodes for a row once (%d reads)" % rows_main.reads, rows_main.reads == 1)
	rows_main.free()
	# (the review's finding: opening or closing a room re-read the PARTS tree, which shows nothing about rooms)
	var reads_before := calls.size()
	tree._on_rooms_changed()
	await frames(40)
	check("3. a room opening or closing does not re-read the PARTS tree (%d requests)" % (calls.size() - reads_before), tree.scope.room_context == false and calls.size() == reads_before)
	tree.scope.room_context = true # (the same call on a tree that does show rooms is still re-read: the check is not vacuous)
	tree._on_rooms_changed()
	var re_read: bool = await until(func() -> bool: return calls.size() > reads_before)
	tree.scope.room_context = false
	check("3. ...while a tree with room context still is", re_read)

	# --- 4. a new document: Find's words on PARTS go (main.gd tells the PARTS tab as it tells the World tree; the review's finding)
	tree.set_query("box")
	check("4. (setup) Find on PARTS narrows the rows (%d listed)" % tree.row_count(), tree.current_query() == "box" and tree.row_count() < 5)
	main._opened_native_path = "user://tree_c6_saved_as.didsa"
	tree.note_document_changed("user://tree_c6.didsa")
	tree.mark_stale()
	check("4. after Save As (a new file key) the PARTS tab keeps its Find words, as the World tree does", tree.current_query() == "box")
	main._show_model(FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb"), "", 0.001)
	await frames(2)
	check("4. another document opened under the same file key: the PARTS tab's Find words go (main.gd's document_replaced, not the key)", tree.current_query() == "")
	for p in get_nodes_in_group("grabbable_parts"):
		var occ := str(p.get_meta("occurrence_id", ""))
		p.set_meta("owner_part_id", "SUB")
		p.set_meta("group_root", "R")
		p.set_meta("group_path", ["s1", occ])
		p.set_meta("group_parts", ["SUB", "PART_BOX" if occ == "occ_box" else "PART_CYL"])
		if occ == "occ_box":
			box = p
		else:
			cyl = p
	main._resolved_part_id = "R"
	await until(func() -> bool: return tree._endpoint_active())
	# --- 4b. the bar follows the seat while PARTS shows (the review's finding): a part lifted off the table can be taken again
	tree.show_tab("parts")
	select(tree, ["s1", "occ_box"])
	bar_button(tree, "Table").pressed.emit()
	await frames(2)
	tree.show_tab("parts")
	select(tree, ["s1", "occ_box"])
	var greyed_on: bool = bar_button(tree, "Table").disabled
	table.return_part()
	await frames(2)
	check("4. while PARTS shows, a part leaving the table turns Table on again in the bar (was greyed: %s)" % str(greyed_on), greyed_on and tree.current_tab() == "parts" and not bar_button(tree, "Table").disabled)
	# --- 4c. the root changed without the trees being told (an import that failed after main.gd set its root): the PARTS tab reads the new one on its next refresh
	calls.clear()
	root_id = "R2"
	main._resolved_part_id = "R2"
	tree.request_refresh()
	var reread: bool = await until(func() -> bool: return calls.has("/parts/R2/assembly-tree") and tree._root_part_id == "R2" and tree._endpoint_active())
	check("4. a root changed without mark_stale (a failed import) is read whole on the next refresh (the review's finding: %s)" % str(calls), reread)
	root_id = "R"
	main._resolved_part_id = "R"
	tree.mark_stale()
	await until(func() -> bool: return tree._endpoint_active())
	table.close()
	await frames(2)

	# --- 5. leftover 1: the way to a room below a closed, never-fetched row (the per-level fallback)
	var rooms := FakeRooms.new()
	main.room_manager = rooms
	var window = main._assembly_tree_window
	window.request_hook = func(_m, _p, _b): return {"ok": false, "json": null, "code": 500, "error": "down"}
	window.open()
	await frames(3)
	window._resp = {}
	window._root_part_id = "R"
	window._stale = false
	window._tree = [{"id": "", "path": [], "name": "Rig", "named": true, "resolved_part_id": "R", "expanded": true, "parent_part_id": "", "children": [
		{"id": "s1", "path": ["s1"], "name": "Sub", "named": true, "resolved_part_id": "SUB", "children": null, "expanded": false},
		{"id": "occ_gone", "path": ["occ_gone"], "name": "Elsewhere", "named": true, "resolved_part_id": "PART_X", "children": null, "expanded": false}]}]
	rooms.parts = ["PART_BOX"]
	window._rebuild_rows()
	await frames(1)
	var d_sub: Dictionary = window._descs[1]
	var d_gone: Dictionary = window._descs[2]
	check("5. a room on a Part below a closed row whose children were never fetched: the row is the way to it, not dimmed", bool(d_sub.get("room_way", false)) and not bool(d_sub.get("room_dim", true)))
	check("5. ...the root above it too", bool(window._descs[0].get("room_way", false)))
	window._tree[0]["expanded"] = false
	window._rebuild_rows()
	check("5. a collapsed root with the room's Part somewhere below is the way to it too (the review's finding)", bool(window._descs[0].get("room_way", false)) and not bool(window._descs[0].get("room_dim", true)))
	window._tree[0]["expanded"] = true
	window._rebuild_rows()
	var saved_parts: Array = []
	for p in [box, cyl]:
		saved_parts.append(p.get_meta("group_parts"))
		p.remove_meta("group_parts")
	window._rebuild_rows() # (a rebuild before the world is indexed: the index knows nothing)
	for i in 2:
		[box, cyl][i].set_meta("group_parts", saved_parts[i])
	select(window, ["s1"])
	check("5. the bar asks the world afresh: indexed after the last rebuild, Sub no longer reads 'can't tell' (%s)" % window._bar_hint.text, not window._bar_hint.text.contains("can't tell"))
	check("5. a closed row the world has nothing of stays dimmed", bool(d_gone.get("room_dim", false)) and not bool(d_gone.get("room_way", false)))
	select(window, ["occ_gone"])
	check("5. ...and the bar says why it cannot tell (%s)" % window._bar_hint.text, window._bar_hint.text.contains("can't tell whether the open room's part is inside"))
	select(window, ["s1"])
	check("5. a row the world can answer for says nothing of the kind", not window._bar_hint.text.contains("can't tell"))
	var kids_many: Array = window._tree[0]["children"].duplicate()
	for i in 200:
		kids_many.append({"id": "z%03d" % i, "path": ["z%03d" % i], "name": "Leaf %03d" % i, "named": true, "resolved_part_id": "PZ%d" % i, "children": null, "expanded": false})
	window._tree[0]["children"] = kids_many
	var builds_before: int = window.scope.index_builds
	window._rebuild_rows()
	check("5. 202 closed rows with a room open: the world is walked once for the rebuild, not once per row (%d walks)" % (window.scope.index_builds - builds_before), window.scope.index_builds - builds_before == 1)
	window._tree[0]["children"] = kids_many.slice(0, 2)
	rooms.parts = ["PART_X_ELSEWHERE"]
	window._rebuild_rows()
	check("5. a room on a Part nowhere below Sub: Sub is dimmed (the world's nodes answer no)", bool(window._descs[1].get("room_dim", false)) and not bool(window._descs[1].get("room_way", false)))
	rooms.parts = []
	window._has_selected = false
	window._rebuild_rows()

	# --- 6. leftover 2: apply_theme binds only the rows on screen
	var kids: Array = []
	for i in 120:
		kids.append({"id": "k%03d" % i, "path": ["k%03d" % i], "name": "Part %03d" % i, "named": true, "resolved_part_id": "P%d" % i, "children": null, "expanded": false})
	window._tree[0]["children"] = kids
	window._rebuild_rows()
	await frames(3)
	var step: float = window.ROW_HEIGHT + window.ROW_SEPARATION
	window._rows_scroll.scroll_vertical = int(40 * step)
	await frames(3)
	window.apply_theme()
	var shown: Vector2i = window._on_screen_range()
	var fresh := 0
	var stale := 0
	var wrong := 0
	for i in window._pool.size():
		var index: int = window._first + i
		var is_fresh: bool = int(window._pool[i].get_meta("theme_rev", -1)) == window._theme_rev
		var on_screen: bool = index >= shown.x and index <= shown.y
		fresh += 1 if is_fresh else 0
		stale += 0 if is_fresh else 1
		wrong += 1 if is_fresh != on_screen else 0
	check("6. apply_theme binds again only the rows on screen (%d bound, %d margin rows left, %d wrong)" % [fresh, stale, wrong], fresh > 0 and stale > 0 and wrong == 0)
	window._rows_scroll.scroll_vertical = int(42 * step)
	await frames(3)
	shown = window._on_screen_range()
	var resized_ok := true
	var stale_on_screen := 0
	for i in window._pool.size():
		var index: int = window._first + i
		if index >= shown.x and index <= shown.y and int(window._pool[i].get_meta("theme_rev", -1)) != window._theme_rev:
			stale_on_screen += 1
	check("6. ...a scroll binds the margin rows it brings on screen (%d left stale on screen)" % stale_on_screen, stale_on_screen == 0)
	var rows_h: float = floor(window._view_height() / step)
	window._rows_scroll.scroll_vertical = int(42.5 * step) # (half a row down: a list that grows by a third of a row then shows one more row without needing a bigger pool)
	window._rows_scroll.size = Vector2(window._rows_scroll.size.x, (rows_h + 0.3) * step)
	window._on_list_resized()
	window.apply_theme()
	var need_before: int = window._pool.size()
	var end_before: int = window._on_screen_range().y
	window._rows_scroll.size = Vector2(window._rows_scroll.size.x, (rows_h + 0.6) * step)
	window._on_list_resized()
	check("6. (setup) the list grew to show one more row with the same pool (%d -> %d rows to %d, pool %d -> %d)" % [end_before, window._on_screen_range().y, window._descs.size(), need_before, window._pool.size()], window._on_screen_range().y == end_before + 1 and window._pool.size() == need_before)
	shown = window._on_screen_range()
	for i in window._pool.size():
		var index: int = window._first + i
		if index >= shown.x and index <= shown.y and int(window._pool[i].get_meta("theme_rev", -1)) != window._theme_rev:
			resized_ok = false
	check("6. ...and so does a list that grows without a scroll (the review's finding)", resized_ok)
	window.close()

	# --- 7. leftover 3: the observer's revision across a model that fails to show
	var fake := FakeMain.new()
	var obs := StubObserver.new()
	obs.main = fake
	obs.active = true
	obs.model_source = {"kind": "backend", "root_part_id": "OLD", "path": ""}
	root.add_child(fake)
	root.add_child(obs)
	obs.loaded_rev = 40 # (the old document had come a long way)
	obs.fetch_ok = false
	obs._on_model({"source": {"kind": "backend", "root_part_id": "NEW", "path": ""}, "title": "New", "rev": 0})
	await frames(3)
	check("7. (setup) the new model failed to show", obs.last_error == "boom" and obs.model_source.get("root_part_id") == "NEW")
	check("7. no revision of the old document is left to compare the new one's events with (loaded_rev %d)" % obs.loaded_rev, obs.loaded_rev == 0)
	obs.fetch_ok = true
	var before := obs.fetches
	obs._queue_doc(5, [], true)
	await frames(3)
	check("7. a change to the model that never showed is not fetched into the old one's scene (the review's finding: %d fetches, shown %s)" % [obs.fetches - before, str(fake.shown)], obs.fetches == before and fake.shown.is_empty())
	obs._on_model({"source": {"kind": "backend", "root_part_id": "NEW2", "path": ""}, "title": "Next", "rev": 3})
	await until(func() -> bool: return not obs._loading)
	obs._queue_doc(4, [], true)
	await until(func() -> bool: return not obs._busy and obs.fetches >= before + 2)
	check("7. the next model shows, and its own revision 4 (after 3) is fetched as usual (%s)" % str(fake.shown), obs._model_shown and obs.title == "Next" and fake.shown == [false, true] and obs.loaded_rev == 4)
	obs.queue_free()
	fake.queue_free()

	# --- 8. the review's finding: a resume (the WebSocket dropped and came back) after a model that failed to show tries to show it again
	var fake2 := FakeMain.new()
	var obs2 := StubObserver.new()
	var hub := FakeClient.new()
	obs2.main = fake2
	obs2.client = hub
	obs2.active = true
	obs2.model_source = {"kind": "backend", "root_part_id": "OLD", "path": ""}
	root.add_child(fake2)
	root.add_child(hub)
	root.add_child(obs2)
	obs2.fetch_ok = false
	obs2._on_model({"source": {"kind": "backend", "root_part_id": "NEW", "path": ""}, "title": "New", "rev": 0})
	await frames(3)
	check("8. (setup) the model failed to show on a transient error", obs2.last_error == "boom" and not obs2._model_shown and fake2.shown.is_empty())
	hub.snapshot = {"model": {"kind": "backend", "root_part_id": "NEW", "path": "", "title": "New", "rev": 7}, "rev": 7}
	obs2.fetch_ok = true
	var fetches_before := obs2.fetches
	obs2._on_welcomed({}, true) # (the same model as the failed one: _model_differs is false)
	await until(func() -> bool: return not obs2._loading)
	check("8. the resume fetched the model again and it is on show (%d fetches, shown %s, loaded_rev %d)" % [obs2.fetches - fetches_before, str(fake2.shown), obs2.loaded_rev], obs2._model_shown and obs2.fetches == fetches_before + 1 and fake2.shown == [false] and obs2.loaded_rev == 7 and obs2.title == "New")
	obs2._queue_doc(8, [], true)
	await until(func() -> bool: return not obs2._busy and obs2.fetches >= fetches_before + 2)
	check("8. ...and a later change to it is applied, not dropped (%d fetches)" % (obs2.fetches - fetches_before), obs2.fetches >= fetches_before + 2 and obs2.loaded_rev == 8)
	# a resume while a model is still loading does not start a second load
	obs2._loading = true
	obs2._model_shown = false
	var fetches_mid := obs2.fetches
	obs2._on_welcomed({}, true)
	await frames(2)
	check("8. a resume while a load is still going starts no second one", obs2.fetches == fetches_mid)
	obs2._loading = false
	obs2.queue_free()
	hub.queue_free()
	fake2.queue_free()
	quit()
