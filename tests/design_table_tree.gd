extends SceneTree
## The assembly tree docked at the design table's left (scripts/design_table/table_tree_window.gd): it opens and closes with the
## table, sits at the slab's left turned in towards it, and its bottom bar gives every placed part that is in the arena a "Table" action (puts
## it on the table without carrying it) and a "Bring" action (moves it in front of you, undoably); for parts that aren't in the arena
## and the assembly's own root row they are greyed (C6: they were inline buttons on every row before); the table refuses a second part, a part with no
## backend identity, and a mated part held by its mates. Rows are fed in directly (the tree's own backend calls are the component's, tested elsewhere).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_tree.gd  (see tests/README.md)

var main
var table


func bar(text: String, path: Array) -> Button:
	## C6: Table and Bring are in the bottom bar of the selected row.
	table.tree._selected = path
	table.tree._has_selected = true
	table.tree._rebuild_bar()
	for b in table.tree._bar_buttons.get_children():
		if (b as Button).text == text:
			return b
	return null


func find_buttons(text: String) -> Array:
	var out: Array = []
	for b in table.tree._viewport.find_children("*", "Button", true, false):
		if (b as Button).text == text:
			out.append(b)
	return out


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	var cam: XRCamera3D = origin.get_node("XRCamera3D")
	cam.position = Vector3(0, 1.6, 0)
	origin.get_node("RightController").position = Vector3(1.0, 1.5, 1.0)
	table = main.design_table
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(bytes, "", 0.001)
	await process_frame
	var box: MeshInstance3D = null
	var cyl: MeshInstance3D = null
	for p in get_nodes_in_group("grabbable_parts"):
		p.set_meta("owner_part_id", "ASM")
		if p.get_meta("occurrence_id", "") == "occ_box":
			box = p
		else:
			cyl = p

	print("SMOKE the table has a tree, closed with it: ", table.tree != null and not table.tree.is_open())
	table.open()
	await process_frame
	print("SMOKE opening the table opens the tree: ", table.tree.is_open() and table.tree.visible)
	var local: Vector3 = table.to_local(table.tree.global_position)
	print("SMOKE ...docked at the slab's left, beside it, turned in towards it: ", local.x < -table.slab_size.x * 0.5 and absf(table.tree.rotation_degrees.y - table.tree.dock_yaw_degrees) < 0.1)
	print("SMOKE ...it is a child of the console, so it travels with it: ", table.tree.get_parent() == table)
	table.tree._tree = [{"id": "", "path": [], "name": "Asm", "named": true, "resolved_part_id": "ASM", "expanded": true, "children": [
		{"id": "occ_box", "path": ["occ_box"], "name": "Box", "named": true, "resolved_part_id": "PART_BOX", "children": null, "expanded": false},
		{"id": "occ_cyl", "path": ["occ_cyl"], "name": "Cylinder", "named": true, "resolved_part_id": "PART_CYL", "children": null, "expanded": false},
		{"id": "occ_gone", "path": ["occ_gone"], "name": "Elsewhere", "named": true, "resolved_part_id": "PART_X", "children": null, "expanded": false}]}]
	table.tree._rebuild_rows()
	await process_frame
	print("SMOKE the rows carry no inline Table / Bring buttons (C6: they are in the bottom bar): ", find_buttons("Table").is_empty() and find_buttons("Bring").is_empty())
	var tables := [bar("Table", ["occ_box"]), bar("Table", ["occ_cyl"]), bar("Table", ["occ_gone"]), bar("Table", [])]
	var brings := [bar("Bring", ["occ_box"]), bar("Bring", ["occ_cyl"]), bar("Bring", ["occ_gone"]), bar("Bring", [])]
	print("SMOKE every row's bar offers Table and Bring, greyed for the assembly's own root row: ", not tables.has(null) and not brings.has(null) and tables[3].disabled and brings[3].disabled)
	print("SMOKE ...enabled for parts in the arena, disabled for one that isn't: ", not tables[0].disabled and not tables[1].disabled and tables[2].disabled and brings[2].disabled)

	# --- Table
	bar("Table", ["occ_box"]).pressed.emit()
	await process_frame
	print("SMOKE Table puts that part on the table without carrying it: ", table.seated == box and box.has_meta("on_table") and not box.visible)
	print("SMOKE ...and the row's actions now read as taken: ", bar("Table", ["occ_box"]).disabled)
	bar("Table", ["occ_cyl"]).pressed.emit()
	await process_frame
	print("SMOKE a second part is refused while the table is full, with the reason on the tree: ", table.seated == box and table.tree._status_label.text.contains("already holds"))
	print("SMOKE node_for_occurrence skips a part that is on the table: ", table.node_for_occurrence("occ_box") == null and table.node_for_occurrence("occ_cyl") == cyl)
	table.return_part()
	cyl.set_meta("owner_part_id", "")
	print("SMOKE a part with no backend identity is refused: ", table.seat_node(cyl).contains("no part behind it") and table.seated == null)
	cyl.set_meta("owner_part_id", "ASM")

	# --- Bring
	var before: Transform3D = cyl.global_transform
	var forward := -cam.global_transform.basis.z
	forward.y = 0.0
	var message: String = table.bring_part(cyl)
	var centre: Vector3 = cyl.global_transform * cyl.get_aabb().get_center()
	var ahead := centre - cam.global_position
	print("SMOKE Bring moves the part to a spot in front of you, below eye level: ", message.begins_with("Brought") and ahead.dot(forward.normalized()) > 0.4 and ahead.y < 0.0)
	print("SMOKE ...as an undoable move that leaves its orientation alone: ", main.command_stack.can_undo() and cyl.global_transform.basis.is_equal_approx(before.basis))
	main.command_stack.undo()
	print("SMOKE ...and undo puts it back: ", cyl.global_transform.is_equal_approx(before))
	main._mates_tool.relaxed = false
	main._mates_tool.backend_url = "http://x"
	main._mates_tool.api_key = "k"
	main._mates_tool._current_owner_part_id = "ASM"
	main._mates_tool._mated_ids = {"occ_cyl": true}
	print("SMOKE a part held by enforced mates won't be pulled out of them: ", table.bring_part(cyl).contains("held by its mates"))
	main._mates_tool.backend_url = ""
	main._mates_tool.api_key = ""

	# --- closing
	table.close()
	print("SMOKE closing the table puts the tree away too: ", not table.tree.is_open())
	table.open()
	print("SMOKE ...and opening it again brings the tree back: ", table.tree.is_open())
	table.close()
	quit()
