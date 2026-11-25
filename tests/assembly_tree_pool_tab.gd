extends SceneTree
## Tree B6 fix round: the design table's PARTS tab uses the same row pool, and its scroll box is not the window's scroll_target while the Build tab shows.
##   1. Table pressed on a row ~100 (the part is seated, the window switches to Build) and back to Parts: the rows are drawn, at the same place
##   2. a reveal while Build shows lays out the parts list's own scroll box, not the Build list's, and the revealed row is drawn when Parts shows again
##   3. a press that went down on a row and is released after its control was re-bound to another row acts on nothing (selection, expansion)
##   4. a Mates folder line wears its count after the label; no line carries inline buttons (C6: Table / Bring are in the bottom bar), in the pool or spare
## NOT covered: the headset. Run: "$GODOT" --headless --path . --script res://tests/assembly_tree_pool_tab.gd  (see tests/README.md)

var main
var table


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func mouse(at: Vector2, down: bool) -> void:
	## A real left-button press or release delivered to the panel's viewport (what the laser does), not pressed.emit().
	var move := InputEventMouseMotion.new()
	move.position = at
	move.global_position = at
	table.tree._viewport.push_input(move, true)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = down
	ev.position = at
	ev.global_position = at
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	table.tree._viewport.push_input(ev, true)


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
	check("(setup) 151 rows listed, only the pool's controls exist (%d)" % win.pool_size(), win.row_count() == 151 and win.pool_size() == int(ceil(win._view_height() / step)) + 1 + 2 * win.POOL_MARGIN)

	# --- 1. Table from row ~100 and back
	win._rows_scroll.scroll_vertical = int(98 * step)
	await frames(2)
	win._selected = ["occ_box"] # (C6: Table is in the bottom bar of the selected row)
	win._has_selected = true
	win._rebuild_rows()
	await frames(1)
	var tables: Array = []
	for b in win._viewport.find_children("*", "Button", true, false):
		if (b as Button).text == "Table" and not (b as Button).disabled:
			tables.append(b)
	check("1. row 100 (Box, in the arena) is drawn, selected, and the bar's Table is enabled (%d enabled)" % tables.size(), tables.size() == 1 and win._row_controls.has("occ_box") and win._bar_buttons.is_ancestor_of(tables[0]))
	(tables[0] as Button).pressed.emit()
	await frames(2)
	check("1. Table seats the part and the window shows Build", table.seated != null and win.current_tab() == "build" and win.scroll_target == win._build_scroll)
	win._rebuild_rows() # (something redraws the parts list while Build shows)
	await frames(1)
	win.show_tab("parts")
	await frames(2)
	var names: Array = drawn_names()
	var need: int = mini(win.row_count(), int(ceil(win._view_height() / step)) + 1 + 2 * win.POOL_MARGIN) # (C6: the bar of the selected row takes room, so the list is shorter than at the start and part of the pool is spare)
	check("1. back on Parts the rows are drawn, at the same place (%d rows for %d needed, first %s, scroll %d)" % [names.size(), need, str(names[0]) if names.size() > 0 else "-", win._rows_scroll.scroll_vertical], names.size() == need and win._rows_scroll.scroll_vertical == int(98 * step) and "Box" in names)

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

	# --- 3. a press across a re-bind, with real mouse events through the panel's viewport
	win._rows_scroll.scroll_vertical = 0
	await frames(2)
	win._selected = []
	win._has_selected = false
	var line: HBoxContainer = win.visible_lines()[3]
	var nb: Button = line.get_child(2)
	var path: Array = (win._descs[win._first + 3]["row"] as Dictionary)["path"]
	var spot := nb.get_global_rect().get_center()
	mouse(spot, true)
	win._layout_pool(true) # (a status answer: every control is bound again, to the row it already shows)
	await frames(1)
	mouse(spot, false)
	await frames(1)
	check("3. press, re-bind to the same row, release: it acts (selected, button shows it)", win._has_selected and win._selected == path and nb.button_pressed)
	win._selected = []
	win._has_selected = false
	win._rebuild_rows()
	await frames(2)
	for which in ["name", "arrow"]:
		nb = win.visible_lines()[3].get_child(2)
		var button: Button = nb if which == "name" else win.visible_lines()[3].get_child(1)
		var first_name: String = nb.text
		var status_before: String = win._status_label.text
		mouse(button.get_global_rect().get_center(), true)
		win._rows_scroll.scroll_vertical = int(60 * step) # (every control is bound to another row)
		await frames(2)
		check("3. (setup, %s) the control the press went down on now shows another row" % which, nb.text != first_name)
		mouse(button.get_global_rect().get_center(), false) # (released over the same control, which has scrolled with the list)
		await frames(2)
		var moved_row: Dictionary = win._descs[win._first + 3]["row"]
		check("3. press on the %s, re-bind to another row, release: nothing selected, nothing expanded, nothing said, and the name button shows its own row's state (not pressed)" % which, not win._has_selected and not nb.button_pressed and not bool(moved_row.get("expanded", false)) and win._status_label.text == status_before)
		win._rows_scroll.scroll_vertical = 0
		await frames(2)
	nb = win.visible_lines()[3].get_child(2)
	mouse(nb.get_global_rect().get_center(), true)
	mouse(nb.get_global_rect().get_center(), false)
	await frames(1)
	check("3. a press and release on the same row afterwards still selects it", win._has_selected and nb.button_pressed)

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
	win._has_selected = false # (C6: no selected row, so the bar is one line and the list is tall again before it is made short)
	win._selected = []
	win._rebuild_rows()
	await frames(2)
	var with_extras := 0
	for l in win.visible_lines():
		if l.get_child_count() > win.LINE_BASE:
			with_extras += 1
	var spare_before: int = win._spare.size()
	win._rows_scroll.size = Vector2(win._rows_scroll.size.x, 120) # (a short list: the pool shrinks)
	win._layout_pool(true) # (counted straight away: a layout pass of the real container would put the size back)
	var extras := 0
	for l in win._spare:
		extras += l.get_child_count() - win.LINE_BASE
	check("4. no line carries inline buttons, in the pool or after it left it (spare %d -> %d, %d lines in the pool had some, %d extras in spare)" % [spare_before, win._spare.size(), with_extras, extras], with_extras == 0 and win._spare.size() > spare_before and extras == 0)
	await frames(2)

	# --- 5. timing (not asserted): the parts list of 2,000 rows scrolled 10 rows a frame down and back; the frame includes the re-bind (run on value_changed),
	## the layout and, under a renderer, the draw. (Before C6 the parts list made new Table / Bring buttons on every re-bind; they are in the bar now.)
	var many: Array = []
	for i in 2000:
		many.append({"id": "m%04d" % i, "path": ["m%04d" % i], "name": "Many %04d" % i, "named": true, "resolved_part_id": "PM%d" % i, "children": null, "expanded": false})
	win._tree = [{"id": "", "path": [], "name": "Asm", "named": true, "resolved_part_id": "ASM", "expanded": true, "children": many}]
	win._rebuild_rows()
	await frames(3)
	var frames_n := 0
	var worst := 0
	var t0 := Time.get_ticks_usec()
	for pass_index in 2:
		for i in range(0, 2000, 10):
			var f0 := Time.get_ticks_usec()
			win._rows_scroll.scroll_vertical = int((i if pass_index == 0 else 2000 - i) * step)
			await process_frame
			worst = maxi(worst, Time.get_ticks_usec() - f0)
			frames_n += 1
	print("SMOKE TIMING PARTS tab sweep (%d rows, 10 rows a frame down and up): %d frames, %.1f ms a frame on average, worst %.1f ms" % [win.row_count(), frames_n, (Time.get_ticks_usec() - t0) / 1000.0 / frames_n, worst / 1000.0])
	quit(0)
