extends SceneTree
## Assembly Rooms R3, minimise / restore ("snow globe") and the shared two-press delete-selected: a minimised room is a 0.4 m cube hovering at 0.9 m, untouchable,
## its handles and console put away; restore brings it back exactly, and is refused while another room occupies its space. Headless; the backend is the fake document.
## Run: "$GODOT" --headless --path . --script res://tests/room_minimise.gd  (see tests/README.md)

const Room := preload("res://scripts/room/room.gd")
const RoomActions := preload("res://scripts/room/room_actions.gd")
const RoomEdit := preload("res://scripts/room/room_edit.gd")
const RoomManager := preload("res://scripts/room/room_manager.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const FakeApi := preload("res://tests/fake_room_api.gd")
const CommandStack := preload("res://scripts/command_stack.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")


func _initialize() -> void:
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)

	# --- a stand-in main with a user (head and hands), the shared undo stack, a selection, the fake document
	var main_script := GDScript.new()
	main_script.source_code = "extends Node3D\nvar command_stack\nvar _mates_tool\nvar quality := 0.5\nvar include_hidden := false\nvar tier := \"\"\nvar selected\nfunc current_selected_part():\n\treturn selected\nfunc current_root_part_id() -> String:\n\treturn \"R\"\nfunc mark_dirty() -> void:\n\tpass\nfunc refresh_assembly_tree() -> void:\n\tpass\nfunc reload_world_model(_d: bool = true) -> bool:\n\treturn true\n"
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
	fake.occurrences = {
		"R": [fake.row("s1", "S"), fake.row("s2", "S"), fake.row("b0", "B")],
		"S": [fake.row("k1", "K"), fake.row("k2", "K")],
		"K": [fake.row("kb", "B")],
		"B": [],
	}
	var manager := RoomManager.new()
	main.add_child(manager)
	manager.setup(main, null)
	manager.edit = RoomEdit.new(fake)
	await process_frame

	var glb := RoomManagerTest.new().glb_for([
		{"pos": Vector3(-200, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "k1"},
		{"pos": Vector3(200, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "k2"},
	])
	var room = manager.open_from_bytes(glb, "S", "Sub")
	manager.activate(room)
	for i in 4:
		await process_frame
	var before_xform: Transform3D = room.volume.xform
	var before_half: Vector3 = room.volume.half
	var before_content: Transform3D = room.content_root.global_transform
	var probe: Vector3 = room.content_root.global_transform * Vector3(0.3, 0.1, -0.2)
	var rel_probe: Vector3 = before_xform.affine_inverse() * probe

	print("SMOKE restoring a room that is not minimised does nothing: ", room.restore() == false)
	print("SMOKE minimise succeeds once, a second call is a no-op: ", room.minimise() == true and room.minimise() == false and room.minimised)
	var longest: float = 2.0 * maxf(room.volume.half.x, maxf(room.volume.half.y, room.volume.half.z))
	print("SMOKE the minimised room's longest side is 0.4 m: ", absf(longest - 0.4) < 0.001)
	print("SMOKE ...hovering with its underside at 0.9 m, over the same spot: ", absf((room.volume.xform.origin.y - room.volume.half.y) - 0.9) < 0.001 and absf(room.volume.xform.origin.x - before_xform.origin.x) < 0.001 and absf(room.volume.xform.origin.z - before_xform.origin.z) < 0.001)
	print("SMOKE ...in proportion (same box shape): ", absf(room.volume.half.x / room.volume.half.y - before_half.x / before_half.y) < 0.001)
	var now_rel: Vector3 = room.volume.xform.affine_inverse() * (room.content_root.global_transform * Vector3(0.3, 0.1, -0.2))
	var f: float = 0.4 / longest * 0.0 + longest / (2.0 * maxf(before_half.x, maxf(before_half.y, before_half.z)))
	print("SMOKE the content shrank with the walls (a content point keeps its place in the box, scaled): ", now_rel.distance_to(rel_probe * f) < 0.001)
	print("SMOKE it can't be touched: not interactive, handles and console put away: ", not room.interactive and not room.handles.enabled and not room.console.is_open())
	print("SMOKE the registry's clip box follows the shrink: ", RoomRegistry.rooms[0].half.distance_to(room.volume.half) < 0.0001)

	room.restore()
	print("SMOKE restore brings back the exact box and content pose: ", not room.minimised and room.volume.xform.is_equal_approx(before_xform) and room.volume.half.is_equal_approx(before_half) and room.content_root.global_transform.is_equal_approx(before_content))
	print("SMOKE ...and touchability, handles and console: ", room.interactive and room.handles.enabled and room.console.is_open())

	# --- restore refused while another room sits in the old space
	room.minimise()
	var xf := Transform3D(Basis(), before_xform.origin + Vector3(before_half.x + 1.0, 0, 0))
	var other_box := RoomVolume.make(xf, Vector3(3, 3, 3))
	RoomRegistry.add_room(other_box)
	print("SMOKE restore is refused while another room occupies the old space: ", room.restore() == false and room.minimised)
	RoomRegistry.remove_room(other_box)
	print("SMOKE ...and works once it is gone: ", room.restore() == true and not room.minimised)

	# --- the manager wrappers and the shared delete
	manager.minimise_room(room)
	print("SMOKE the manager minimises and restores: ", room.minimised)
	manager.restore_room(room)
	print("SMOKE ...restores: ", not room.minimised)

	var r0: Dictionary = await manager.delete_selected_press()
	print("SMOKE delete-selected with nothing selected does nothing: ", r0.get("status") in ["none", "unavailable"])
	print("SMOKE the delete label is a plain Delete selected part when idle: ", manager.delete_selected_label().begins_with("Delete"))
	quit(0)
