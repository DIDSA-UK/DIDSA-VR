extends SceneTree
## Tree B6 fix round: the design table's PARTS tab uses the same row pool, and its scroll box is not the window's scroll_target while the Build tab shows.
##   1. Table pressed on a row ~100 (the part is seated, the window switches to Build) and back to Parts: the rows are drawn, at the same place
##   2. a reveal while Build shows lays out the parts list's own scroll box, not the Build list's, and the revealed row is drawn when Parts shows again
##   3. a press that went down on a row and is released after its control was re-bound to another row acts on nothing (selection, expansion)
##   4. a Mates folder line wears its count after the label; the inline Table / Bring buttons are freed when a line leaves the pool
## NOT covered: the headset. Run: "$GODOT" --headless --path . --script res://tests/assembly_tree_pool_tab.gd  (see tests/README.md)

var main
var table


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func drawn_names() -> Array:
	var out: Array = []
	for line in table.tree.visible_lines():
		out.append((line.get_child(2) as Button).text)
	return out


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	table = main.design_table
	main._show_model(FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb"), "", 0.001)
	await process_frame
	for p in get_nodes_in_group("grabbable_parts"):
		p.set_meta("owner_part_id", "ASM")
	table.open()
	await frames(3)
	var win = table.tree
	var kids: Array = []
	for i in 150:
		var id := "occ_%03d" % i
		if i == 100:
			id = "occ_box"
		kids.append({"id": id, "path": [id], "name": "Part %03d" % i if i != 100 else "Box", "named": true, "resolved_part_id": "PART_%03d" % i, "children": null, "expanded": false})
	win._tree = [{"id": "", "path": [], "name": "Asm", "named": true, "resolved_part_id": "ASM", "expanded": true, "children": kids}]
	win._rebuild_rows()
	await frames(3)
	var step: float = win.ROW_HEIGHT + win.ROW_SEPARATION
	check("(setup) 151 rows listed, only the pool's controls exist (%d)" % win.pool_size(), win.row_count() == 151 and win.pool_size() < 40)

	# --- 1. Table from row ~100 and back
	win._rows_scroll.scroll_vertical = int(98 * step)
	await frames(2)
	var tables: Array = []
	for b in win._viewport.find_children("*", "Button", true, false):
		if (b as Button).text == "Table" and not (b as Button).disabled:
			tables.append(b)
	check("1. row 100 (Box, in the arena) is drawn with an enabled Table button (%d enabled)" % tables.size(), tables.size() == 1)
	(tables[0] as Button).pressed.emit()
	await frames(2)
	check("1. Table seats the part and the window shows Build", table.seated != null and win.current_tab() == "build" and win.scroll_target == win._build_scroll)
	win._rebuild_rows() # (something redraws the parts list while Build shows)
	await frames(1)
	win.show_tab("parts")
	await frames(2)
	var names: Array = drawn_names()
	check("1. back on Parts the rows are drawn, at the same place (%d rows, first %s, scroll %d)" % [names.size(), str(names[0]) if names.size() > 0 else "-", win._rows_scroll.scroll_vertical], names.size() > 8 and win._rows_scroll.scroll_vertical == int(98 * step) and "Box" in names)

	# --- 2. reveal while Build shows
	table.return_part()
	await frames(2)
	win.show_tab("build")
	await frames(2)
	var build_before: int = win._build_scroll.scroll_vertical
	win._rows_scroll.scroll_vertical = 0
	win._rebuild_rows()
	await win._reveal(["occ_149"])
	await frames(2)
	check("2. a reveal while Build shows does not scroll the Build list (%d -> %d) and scrolls the parts list (%d)" % [build_before, win._build_scroll.scroll_vertical, win._rows_scroll.scroll_vertical], win._build_scroll.scroll_vertical == build_before and win._rows_scroll.scroll_vertical > 5000)
	win.show_tab("parts")
	await frames(2)
	check("2. ...and the revealed row is drawn when Parts shows again", "Part 149" in drawn_names() and win._row_controls.has("occ_149"))

	# --- 3. a press across a re-bind
	win._rows_scroll.scroll_vertical = 0
	await frames(2)
	win._selected = []
	win._has_selected = false
	var line: HBoxContainer = win.visible_lines()[3]
	var first_name: String = (line.get_child(2) as Button).text
	(line.get_child(2) as Button).button_down.emit()
	(line.get_child(1) as Button).button_down.emit()
	win._rows_scroll.scroll_vertical = int(60 * step) # (every control is bound to another row)
	await frames(2)
	check("3. (setup) the control the press went down on now shows another row", (line.get_child(2) as Button).text != first_name)
	(line.get_child(2) as Button).pressed.emit()
	(line.get_child(1) as Button).pressed.emit()
	await frames(2)
	check("3. the release acts on nothing: no selection, no row expanded", not win._has_selected and win.visible_lines().size() > 0 and not bool((win._tree[0]["children"] as Array)[int(win._first) + 3].get("expanded", false)))
	var fresh: HBoxContainer = win.visible_lines()[2]
	(fresh.get_child(2) as Button).button_down.emit()
	(fresh.get_child(2) as Button).pressed.emit()
	await frames(1)
	check("3. a press and release on the same row still selects it", win._has_selected)

	# --- 4. folder bubble order, extras freed
	win._resp = {}
	win._descs.append({"kind": "folder", "srow": {"key": "#mates", "kind": "mates_folder", "label": "Mates", "count": 5, "depth": 1, "bubble": {"count": 2, "level": "error"}}})
	win._rows_scroll.scroll_vertical = int(win._rows_scroll.get_v_scroll_bar().max_value)
	win._layout_pool(true)
	await frames(1)
	var folder_line = null
	for l in win.visible_lines():
		if (l.get_meta("folder") as Label).visible:
			folder_line = l
	check("4. a Mates folder line wears its count after the label ([label, bubble])", folder_line != null and folder_line.get_child(3) == folder_line.get_meta("folder") and folder_line.get_child(4) == folder_line.get_meta("bubble") and (folder_line.get_meta("bubble") as Label).text == "2")
	win._rebuild_rows()
	win._rows_scroll.scroll_vertical = 0
	await frames(2)
	var normal: HBoxContainer = win.visible_lines()[2]
	check("4. a row line has its bubble in front of the folder label again", normal.get_child(3) == normal.get_meta("bubble"))
	var spare_before: int = win._spare.size()
	win._rows_box.get_parent().size = Vector2(win._rows_box.get_parent().size.x, 120) # (a short list: the pool shrinks)
	win._layout_pool(true)
	await frames(1)
	var extras := 0
	for l in win._spare:
		extras += l.get_child_count() - win.LINE_BASE
	check("4. lines that leave the pool carry no inline buttons (%d spare, %d extras)" % [win._spare.size(), extras], extras == 0)
	quit(0)
