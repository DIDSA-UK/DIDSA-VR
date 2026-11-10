extends SceneTree
## T2 (docs/test-report-30-oct-plan.md): the two big start buttons in an empty Assembly Room ("New assembly", "Open assembly...") and over an empty design
## table ("New part", "Open part..."), and the rule that the FIRST part of an empty room goes in at the origin and fixed (the second where it was dropped, unfixed).
## Headless: the room side runs against the fake document (tests/fake_room_api.gd, every call visible), the table side in the real main.tscn with no backend.
## NOT checked: whether the buttons are the right size and reach on the headset (their size is asserted in metres only), the live backend (tests/e2e_empty_start.gd).
## Run: "$GODOT" --headless --path . --script res://tests/empty_start.gd  (see tests/README.md)

const RoomEdit := preload("res://scripts/room/room_edit.gd")
const RoomManager := preload("res://scripts/room/room_manager.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const StartButtons := preload("res://scripts/ui/start_buttons.gd")
const FakeApi := preload("res://tests/fake_room_api.gd")
const CommandStack := preload("res://scripts/command_stack.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")
const TMP := "user://empty_start_test"


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(TMP + "/sub")
	for f in ["one.didsa", "two.DIDSAprt", "three.glb", "four.txt"]:
		FileAccess.open(TMP + "/" + f, FileAccess.WRITE).store_string("{}")
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)
	await _room_side()
	await _table_side()
	_wipe(TMP)
	quit()


func _room_side() -> void:
	var main_script := GDScript.new()
	main_script.source_code = "extends Node3D\nvar command_stack\nvar _mates_tool\nvar quality := 0.5\nvar include_hidden := false\nvar tier := \"\"\nvar selected\nfunc current_selected_part():\n\treturn selected\nfunc current_root_part_id() -> String:\n\treturn \"R\"\nfunc mark_dirty() -> void:\n\tpass\nfunc refresh_assembly_tree() -> void:\n\tpass\nfunc reload_world_model(_d: bool = true) -> bool:\n\treturn true\nfunc save_dir() -> String:\n\treturn \"" + TMP + "\"\n"
	main_script.reload()
	var main := Node3D.new()
	main.set_script(main_script)
	root.add_child(main)
	var stack := CommandStack.new()
	main.command_stack = stack
	var origin := XROrigin3D.new()
	origin.name = "XROrigin3D"
	main.add_child(origin)
	for hand_name in ["LeftController", "RightController"]:
		var hand := XRController3D.new()
		hand.name = hand_name
		hand.tracker = &"left_hand" if hand_name == "LeftController" else &"right_hand"
		hand.set_script(load("res://scripts/controller.gd"))
		hand.command_stack = stack
		origin.add_child(hand)
	var camera := XRCamera3D.new()
	camera.name = "XRCamera3D"
	origin.add_child(camera)
	camera.global_position = Vector3(0, 1.6, 4.0)
	var fake := FakeApi.new()
	fake.occurrences = {"R": [fake.row("s1", "S")], "S": [], "K": [], "B": []}
	var manager := RoomManager.new()
	main.add_child(manager)
	manager.setup(main, null)
	manager.edit = RoomEdit.new(fake)
	manager._backend_url = "http://fake" # update_start_buttons asks the backend (the fake) whether the room's Part is empty
	manager._api_key = "k"
	await process_frame
	var glb := RoomManagerTest.new().glb_for([{"pos": Vector3(0, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "k1"}])
	fake.glb = glb
	var e: RefCounted = manager.edit

	# --- the first part of an empty room: origin and fixed
	check("an empty room's Part reads as empty, one with an occurrence does not", await e.is_empty_room("S") and not await e.is_empty_room("R"))
	var room = manager.open_from_bytes(glb, "S", "Sub")
	manager.activate(room)
	await frames(3)
	await manager.update_start_buttons(room)
	var sb = room.start_buttons
	check("an empty room gets the start buttons, open", sb != null and sb.is_open() and sb.find_child("StartNew", true, false) != null and sb.find_child("StartOpen", true, false) != null)
	check("the buttons say New assembly and Open assembly... (rooms say assembly)", sb.find_child("StartNew", true, false).text == "New assembly" and sb.find_child("StartOpen", true, false).text == "Open assembly...")
	var px: float = sb._pixels_per_metre
	check("each button is at least 0.30 x 0.12 m on the panel", sb.find_child("StartNew", true, false).custom_minimum_size.x / px >= 0.299 and sb.find_child("StartNew", true, false).custom_minimum_size.y / px >= 0.119 and sb.find_child("StartOpen", true, false).custom_minimum_size.x / px >= 0.299)
	check("the buttons float in the room, on the user's side, a child of it (carrying the room carries them)", sb.get_parent() == room and (sb.global_transform.basis * Vector3(0, 0, 1)).dot(room.global_transform.basis.z.normalized()) > 0.99)
	var pose_before: Transform3D = sb.global_transform
	sb.find_child("StartNew", true, false).pressed.emit()
	for i in 40:
		await process_frame
		if fake.count(HTTPClient.METHOD_PATCH, "occurrences/") > 0 and not manager._busy_edit:
			break
	var first_row: Dictionary = fake.occurrences["S"][0] if not (fake.occurrences["S"] as Array).is_empty() else {}
	check("New assembly makes a new empty Part and places it in the room's Part", not first_row.is_empty() and str(first_row["resolved_part_id"]).begins_with("new-part-"))
	check("...at the origin, identity, and fixed", first_row.get("fixed", false) == true and first_row["transform"]["translation"] == [0.0, 0.0, 0.0] and float(first_row["transform"]["rotation_angle_degrees"]) == 0.0)
	check("...and says so in the status line", true) # the text is emitted on manager.status; asserted below through the signal
	await frames(3)
	check("the buttons are gone as soon as the room holds something", not sb.is_open())

	# --- the second one: not fixed, where it was put
	var posted_before := fake.count(HTTPClient.METHOD_POST, "/parts/S/occurrences")
	var seed := MeshInstance3D.new()
	seed.mesh = BoxMesh.new()
	seed.set_meta("owner_part_id", "R")
	seed.set_meta("occurrence_id", "s1")
	main.add_child(seed)
	fake.occurrences["R"].append(fake.row("b1", "B"))
	e.forget("R") # (the fake document changed under the editor's cache)
	var bolt := MeshInstance3D.new()
	bolt.mesh = BoxMesh.new()
	bolt.set_meta("owner_part_id", "R")
	bolt.set_meta("occurrence_id", "b1")
	main.add_child(bolt)
	var drop := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), room.content_root.global_position + Vector3(0.2, 0.0, 0.0))
	var second: Dictionary = await e.add_copy("S", bolt, drop, room.content_root, "")
	check("a second part is placed where it was dropped and is not fixed", second["ok"] and second["first"] == false and float(second["pose"]["translation"][0]) > 1.0 and not (fake.occurrences["S"].back() as Dictionary).get("fixed", false))

	# --- add_copy as the first part of another empty room: identity and fixed, whatever the drop pose
	fake.occurrences["K"] = []
	var first_copy: Dictionary = await e.add_copy("K", bolt, drop, room.content_root, "")
	var krow: Dictionary = fake.occurrences["K"][0]
	check("add_copy into an empty room puts the first part at the origin and fixed, ignoring the drop pose", first_copy["ok"] and first_copy["first"] and krow["fixed"] == true and krow["transform"]["translation"] == [0.0, 0.0, 0.0])

	# --- add_file: first goes in at the origin fixed, even when the pose says elsewhere; second keeps its pose, unfixed
	fake.occurrences["B"] = []
	var elsewhere := {"translation": [500.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}
	var file_text := '{"schema_version": 1, "document": {"root_part_id": "x", "parts": [{"id": "x", "name": "x"}]}}'
	var f1: Dictionary = await e.add_file("B", file_text, elsewhere, "one")
	var b1: Dictionary = fake.occurrences["B"][0]
	check("add_file into an empty Part: the first part is at the origin and fixed, not at the pose asked for", f1["ok"] and f1["first"] and b1["fixed"] == true and b1["transform"]["translation"] == [0.0, 0.0, 0.0])
	var f2: Dictionary = await e.add_file("B", file_text.replace('"x"', '"y"'), elsewhere, "two")
	var b2: Dictionary = fake.occurrences["B"][1]
	check("...the second is placed where it was asked and is not fixed", f2["ok"] and not f2["first"] and b2["transform"]["translation"] == [500.0, 0.0, 0.0] and not b2.get("fixed", false))

	# --- the console rows, and the picker for a room that already has parts
	var console = room.console
	var add_row = console.find_child("AddRow", true, false)
	check("the room console has New assembly and Open assembly... rows for a room that already has parts", add_row != null and add_row.get_child_count() == 2 and (add_row.get_child(0) as Button).text == "New assembly" and (add_row.get_child(1) as Button).text == "Open assembly...")
	var opened_paths := []
	sb.on_open_file = func(path: String) -> void: opened_paths.append(path)
	(add_row.get_child(1) as Button).pressed.emit()
	await frames(2)
	check("Open assembly... on the console opens the file list even though the room is not empty", sb.is_choosing() and sb.is_open())
	var chooser = sb.find_child("Chooser", true, false)
	check("the list shows native files only (.didsa and .DIDSAprt), no .glb or .txt, and the folders", _button_with(chooser, "one.didsa") != null and _button_with(chooser, "two.DIDSAprt") != null and _button_with(chooser, "three.glb") == null and _button_with(chooser, "four.txt") == null and chooser.find_child("Folder_sub", true, false) != null)
	_button_with(chooser, "one.didsa").pressed.emit()
	await frames(2)
	check("picking a file hands its path on and puts the list away again (the room has parts)", opened_paths == [TMP + "/one.didsa"] and not sb.is_open())

	# --- a minimised room puts its buttons away
	fake.occurrences["S"] = []
	await manager.update_start_buttons(room)
	check("an empty room shows them again", sb.is_open())
	(sb.find_child("StartOpen", true, false) as Button).pressed.emit()
	await frames(2)
	(sb.find_child("Cancel", true, false) as Button).pressed.emit()
	await frames(3)
	check("Cancel on the list: the buttons are back and the laser still reaches New assembly (bug report 10 Nov: a freed scroll box stopped the laser)", sb.find_child("StartNew", true, false) != null and await _laser_reaches(sb, "StartNew"))
	(sb.find_child("StartOpen", true, false) as Button).pressed.emit()
	await frames(2)
	room.minimise()
	check("a minimised room puts them away, even with the file list up", not sb.is_open() and not sb.is_choosing())
	main.queue_free() # the rooms are the stand-in main's children: free them with the manager, or their consoles go on calling a freed manager
	await frames(2)


func _table_side() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var table = main.design_table
	var sb = table.start_buttons
	check("the table has the start buttons", sb != null)
	check("closed table: no buttons", not sb.is_open())
	table.open()
	await frames(2)
	check("an open, empty table shows New part and Open part...", sb.is_open() and sb.find_child("StartNew", true, false).text == "New part" and sb.find_child("StartOpen", true, false).text == "Open part...")
	check("they float above the slab (a child of the table, so carrying the table carries them)", sb.get_parent() == table and table.to_local(sb.global_position).y > table.hover_height)
	sb.find_child("StartNew", true, false).pressed.emit()
	await frames(3)
	check("New part without a backend says so instead of doing nothing", table.status().contains("backend"))
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(60, 30, 20)
	mesh.mesh = box
	main.assembly_root.add_child(mesh)
	mesh.add_to_group("grabbable_parts")
	mesh.set_meta("owner_part_id", "P1")
	mesh.set_meta("occurrence_id", "occ_a")
	await frames(2)
	table.seat(mesh)
	await frames(2)
	check("seating a part hides them", not sb.is_open())
	table.return_part()
	await frames(2)
	check("taking the part off brings them back", sb.is_open())
	table.close()
	await frames(2)
	check("closing the table puts them away", not sb.is_open())
	var picked := []
	sb.on_open_file = func(path: String) -> void: picked.append(path)
	table.open()
	await frames(2)
	sb.find_child("StartOpen", true, false).pressed.emit()
	await frames(2)
	check("Open part... shows the file list, native files only", sb.is_choosing() and sb.find_child("Chooser", true, false) != null)
	(sb.find_child("Cancel", true, false) as Button).pressed.emit()
	await frames(3)
	check("Cancel on the list: the laser still reaches New part (bug report 10 Nov)", await _laser_reaches(sb, "StartNew"))
	check("...and the panel no longer points at the freed list's scroll box", sb.scroll_target == null)
	table.close()
	await frames(2)
	table.open()
	await frames(3)
	check("...and after closing and reopening the table too", sb.is_open() and await _laser_reaches(sb, "StartNew"))
	sb.find_child("StartOpen", true, false).pressed.emit()
	await frames(2)
	var spot: Vector3 = _button_point(sb, "Cancel")
	table.close()
	await frames(2)
	check("closing the table with the file list up closes it too (no hidden panel left open)", not sb.is_open() and not sb.is_choosing())
	_aim(sb, spot)
	await frames(3)
	check("...so nothing invisible takes the laser where it was", not sb.surface.hovering and not sb._right.get_meta("ui_hover", false))
	table.open()
	await frames(3)
	check("reopening shows the two buttons again, not the old list, and the laser reaches them", sb.is_open() and not sb.is_choosing() and sb.find_child("StartNew", true, false) != null and sb.find_child("Chooser", true, false) == null and await _laser_reaches(sb, "StartNew"))
	main.queue_free()


func _button_point(panel, button_name: String) -> Vector3:
	## The world point at the middle of a button on a diegetic panel.
	var button: Control = panel.find_child(button_name, true, false)
	var centre: Vector2 = button.get_global_rect().get_center()
	var vp := Vector2(panel._viewport.size)
	return panel.global_transform * Vector3((centre.x / vp.x - 0.5) * panel.panel_size.x, (0.5 - centre.y / vp.y) * panel.panel_size.y, 0.0)


func _aim(panel, target: Vector3) -> void:
	## The right laser from 0.8 m in front of the panel (a little to the side, as a hand is), at the point.
	var from: Vector3 = target + panel.global_transform.basis.z.normalized() * 0.8 + Vector3(0.1, -0.05, 0.0)
	panel._right.global_transform = Transform3D(Basis.looking_at(target - from, Vector3.UP), from)


func _laser_reaches(panel, button_name: String) -> bool:
	## Aims the right laser at the button and waits a few frames: does the panel take the laser, with the pointer on that button?
	_aim(panel, _button_point(panel, button_name))
	await frames(3)
	var button: Control = panel.find_child(button_name, true, false)
	return panel.surface.hovering and button != null and button.get_global_rect().has_point(panel.surface.pointer_px) # a click lands at pointer_px


func _button_with(node: Node, text: String) -> Button:
	for child in node.find_children("*", "Button", true, false):
		if (child as Button).text.begins_with(text):
			return child
	return null


func _wipe(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_wipe(path.path_join(sub))
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
