extends SceneTree
## Tree B6: the Assembly Tree window draws only the rows on screen (a pool of row controls re-used as the list scrolls).
##   1. a 2,000-row open level creates no more controls than the pool (visible rows plus a margin), not one per row; the scroll bar is still the whole list's
##   2. scrolling moves the window over the list: every drawn row shows its own row (name, hint, tint, dimming, selection) and nothing of the row the control showed before
##   3. reveal of a row 4 deep (the world selected a part inside nested sub-assemblies) opens the rows above it and scrolls it into view, drawn
##   4. a refresh in place keeps the scroll position and the pool size
## NOT covered: how it looks or feels (tests/assembly_tree_render.gd and tools/assembly_tree_render_check, under Mesa), or the headset.
## Run: "$GODOT" --headless --path . --script res://tests/assembly_tree_pool.gd  (see tests/README.md)

const Model := preload("res://scripts/tree/occurrence_tree_model.gd")
const LEAVES := 1990

var main
var window
var fetches := 0


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func node(id: String, path: Array, kind: String, name: String, status: String, children: Array, suppressed: bool = false) -> Dictionary:
	return {
		"occurrence_id": id, "path": path, "external_ref": null, "ref_part_id": "P" + id, "resolved_part_id": "P" + id, "part_name": name, "name_override": null,
		"kind": kind, "fixed": false, "hidden": false, "suppressed": suppressed, "color": null,
		"constraint": {"status": status, "dof": 2, "rigid_set": null, "broken_mates": 0, "near_mates": 0},
		"feature_count": 0, "placements": 1, "cycle": false, "truncated": false, "status_failed": false, "mates": null, "patterns": null, "problems": null, "children": children,
	}


func tree() -> Dictionary:
	## Root > a1 > b1 > c1 > d1 > 1,990 leaves (distinct names so nothing folds): every 7th over-constrained (an error: red, hint "over"), every 11th suppressed.
	var leaves: Array = []
	for i in LEAVES:
		var id := "l%04d" % i
		var status := "over_constrained" if i % 7 == 3 else ("fully_constrained" if i % 5 == 0 else "under_constrained")
		leaves.append(node(id, ["a1", "b1", "c1", "d1", id], "part", "Leaf %04d" % i, status, [], i % 11 == 4))
	var d1 := node("d1", ["a1", "b1", "c1", "d1"], "assembly", "Deep", "under_constrained", leaves)
	var c1 := node("c1", ["a1", "b1", "c1"], "assembly", "Third", "under_constrained", [d1])
	var b1 := node("b1", ["a1", "b1"], "assembly", "Second", "under_constrained", [c1])
	var a1 := node("a1", ["a1"], "assembly", "First", "under_constrained", [b1])
	return {
		"part_id": "R", "part_name": "Big rig", "kind": "assembly", "feature_count": 0, "status_included": true,
		"mates": {"count": 0, "suppressed": 0, "broken": 0, "near": 0, "held": 0, "lost": 0}, "patterns": {"count": 0, "suppressed": 0},
		"problems": {"missing": 0, "cycles": 0, "broken": 0, "over_constrained": 0, "near": 0}, "children": [a1], "truncated": false, "node_count": LEAVES + 4,
		"max_depth": 32, "max_nodes": 10000, "truncated_depth": false, "truncated_nodes": false, "status_failed": false, "status_incomplete": false,
	}


func answer(method: int, path: String, _body) -> Dictionary:
	if method == HTTPClient.METHOD_GET and path.begins_with("/parts/R/assembly-tree"):
		fetches += 1
		return {"ok": true, "json": tree(), "error": ""}
	if method == HTTPClient.METHOD_GET and path == "/parts/R":
		return {"ok": true, "json": {"name": "Big rig"}, "error": ""}
	return {"ok": false, "json": null, "code": 404, "error": "404"}


func open_chain() -> void:
	for p in [["a1"], ["a1", "b1"], ["a1", "b1", "c1"], ["a1", "b1", "c1", "d1"]]:
		(Model.find_row(window._tree, p))["expanded"] = true


func wrong_rows() -> int:
	## How many drawn rows do not show exactly their own row: name, hint, tint, dimming, selection, bubble, indent.
	var wrong := 0
	var lines: Array = window.visible_lines()
	var first: int = window._first
	for i in lines.size():
		var d: Dictionary = window._descs[first + i]
		var row: Dictionary = d["row"]
		var nb: Button = lines[i].get_child(2)
		var red: bool = Model.state_level(str(row["state"])) == "error"
		var ok: bool = nb.text.begins_with(str(row["name"]))
		ok = ok and (nb.text.contains("· over") == (str(row["state"]) == "over_constrained" and not bool(row.get("suppressed", false)))) # (a hint appears only on the row it belongs to)
		ok = ok and ((nb.get_theme_color("font_color") == window.tokens.danger) == red)
		ok = ok and (nb.modulate.a < 0.9) == bool(row.get("suppressed", false))
		ok = ok and nb.button_pressed == (window._has_selected and window._selected == row["path"])
		ok = ok and int(round((lines[i].get_child(0) as Control).custom_minimum_size.x / 24.0)) == int(d["depth"])
		ok = ok and not (lines[i].get_child(3) as Control).visible # (no leaf wears a bubble)
		if not ok:
			wrong += 1
	return wrong


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main._resolved_part_id = "R"
	window = main._assembly_tree_window
	window.request_hook = Callable(self, "answer")
	window.backend_url = "http://example.invalid"
	window.api_key = "k"
	window.open()
	await frames(8)
	check("(setup) the window read the tree: root and the first sub-assembly are listed", window.row_count() == 2 and fetches >= 1)

	var nodes_before := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	open_chain()
	window._rebuild_rows()
	await frames(3)
	var rows: int = window.row_count()
	var nodes_after := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var scroll: ScrollContainer = window.scroll_target
	var step: float = window.ROW_HEIGHT + window.ROW_SEPARATION

	# --- 1. the pool
	check("1. the open chain lists 1,995 rows (root, 4 sub-assemblies, 1,990 leaves) (%d)" % rows, rows == LEAVES + 5)
	var pool: int = window.pool_size()
	var wanted_max: int = int(ceil(window._view_height() / step)) + 1 + 2 * window.POOL_MARGIN
	check("1. ...but only the pool's controls exist: %d, no more than the visible rows plus a margin (%d), not one per row" % [pool, wanted_max], pool > 0 and pool <= wanted_max and pool < 60)
	check("1. ...the list holds the pool's lines and three stand-ins (%d children)" % window._rows_box.get_child_count(), window._rows_box.get_child_count() <= pool + 3)
	check("1. ...2,000 rows added fewer than 300 nodes to the scene (%d; one control per row would be about %d)" % [nodes_after - nodes_before, rows * 5], nodes_after - nodes_before < 300)
	var bar: ScrollBar = scroll.get_v_scroll_bar()
	check("1. the scroll bar still spans the whole list (max %d, the list is %d px)" % [int(bar.max_value), int(rows * step - window.ROW_SEPARATION)], absf(bar.max_value - (rows * step - window.ROW_SEPARATION)) < 2.0)
	check("1. the drawn rows are the top of the list", window._first == 0 and window.visible_lines().size() > 8 and wrong_rows() == 0)

	# --- 2. scrolling: every drawn row shows its own row, none keeps what the control showed before
	var bad := 0
	var shifts := 0
	var seen_first := {}
	for target in [1, 7, 8, 9, 40, 41, 500, 499, 498, 1200, 1990, 1993, 700, 3, 0]:
		scroll.scroll_vertical = int(target * step)
		await frames(1)
		bad += wrong_rows()
		seen_first[window._first] = true
		shifts += 1
	check("2. after %d scroll jumps (forward, back, short and long) every drawn row shows its own row: %d wrong" % [shifts, bad], bad == 0 and window.pool_size() == pool)
	scroll.scroll_vertical = int(bar.max_value)
	await frames(2)
	var lines: Array = window.visible_lines()
	check("2. at the end of the list the last row is drawn and the pool is the same size", (window._descs[window._first + lines.size() - 1] as Dictionary)["row"]["name"] == "Leaf 1989" and window.pool_size() == pool and wrong_rows() == 0)
	var seen_over := false
	for line in lines:
		if (line.get_child(2) as Button).text.contains("· over"):
			seen_over = true
	check("2. (the fixture has errors in view, so the red rows were really checked)", seen_over)

	# --- 2b. selection and the hint follow the row, not the control
	var picked := ["a1", "b1", "c1", "d1", "l0003"]
	window._selected = picked
	window._has_selected = true
	scroll.scroll_vertical = 0
	window._rebuild_rows()
	await frames(2)
	var marked := 0
	for round in 3:
		for target in [0, 4, 300, 4]:
			scroll.scroll_vertical = int(target * step)
			await frames(1)
			for line in window.visible_lines():
				if (line.get_child(2) as Button).button_pressed:
					marked += 1
	check("2. only the selected row is marked, wherever it is drawn (%d sightings in 3 rounds of 4 stops, 3 of which have it in view; never a second one)" % marked, marked == 9 and wrong_rows() == 0)

	# --- 3. reveal of a row 4 deep
	window._selected = []
	window._has_selected = false
	for p in [["a1", "b1", "c1", "d1"], ["a1", "b1", "c1"], ["a1", "b1"], ["a1"]]:
		(Model.find_row(window._tree, p))["expanded"] = false
	window._rebuild_rows()
	scroll.scroll_vertical = 0
	await frames(3)
	check("3. (setup) every sub-assembly closed: two rows listed", window.row_count() == 2)
	var target_path := ["a1", "b1", "c1", "d1", "l1500"]
	await window._reveal(target_path)
	await frames(2)
	var ctrl = window._row_controls.get(Model.path_key(target_path))
	check("3. the row 4 deep is drawn after the reveal (the four sub-assemblies above it opened, %d rows)" % window.row_count(), window.row_count() == LEAVES + 5 and ctrl != null and is_instance_valid(ctrl))
	var view := Rect2(scroll.global_position, scroll.size)
	var in_view: bool = ctrl != null and view.encloses(Rect2((ctrl as Control).global_position, (ctrl as Control).size))
	check("3. ...scrolled into view (scroll %d of %d; row at y %d, list %d to %d)" % [scroll.scroll_vertical, int(bar.max_value), int((ctrl as Control).global_position.y) if ctrl != null else -1, int(view.position.y), int(view.end.y)], scroll.scroll_vertical > 50000 and in_view)
	check("3. ...showing its own name, and no other drawn row is out of place", ctrl != null and ((ctrl as Control).get_child(2) as Button).text.begins_with("Leaf 1500") and wrong_rows() == 0 and window.pool_size() == pool)

	# --- 4. a refresh in place
	var before_scroll: int = scroll.scroll_vertical
	var before_fetches := fetches
	window.request_refresh()
	for i in 90:
		await process_frame
		if fetches > before_fetches and not window._busy:
			break
	await frames(6)
	check("4. a refresh in place re-reads the tree and keeps the place in the list (%d -> %d) and the pool (%d)" % [before_scroll, scroll.scroll_vertical, window.pool_size()], fetches > before_fetches and absi(scroll.scroll_vertical - before_scroll) < 2 and window.pool_size() == pool and window.row_count() == LEAVES + 5 and wrong_rows() == 0)
	quit(0)
