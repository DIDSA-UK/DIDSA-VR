extends SceneTree
## Assembly Rooms R3, summoning a room by laser: aim the right laser at the floor, a ghost of the room follows (red where it would overlap another room), the
## trigger drops it there facing you, B cancels, the mesh loads while you aim, the trigger is the room's and not a part select while placing, and with no laser
## to aim (no headset) it opens in front as before. Headless; the laser is a stand-in hand with a pose, the buttons are the controller's own signals.
## Run: "$GODOT" --headless --path . --script res://tests/room_laser_placement.gd  (see tests/README.md)

const RoomPlacement := preload("res://scripts/room/room_placement.gd")
const RoomManager := preload("res://scripts/room/room_manager.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomEdit := preload("res://scripts/room/room_edit.gd")
const FakeApi := preload("res://tests/fake_room_api.gd")
const CommandStack := preload("res://scripts/command_stack.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")


func aim(hand: Node3D, from: Vector3, at: Vector3) -> void:
	hand.global_transform = Transform3D(Basis.looking_at((at - from).normalized(), Vector3.UP), from)


func _initialize() -> void:
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)

	# --- the maths
	var from := Vector3(0, 1.4, 0)
	var down: Variant = RoomPlacement.floor_hit(from, Vector3(0, -1, -1).normalized())
	print("SMOKE a laser pointing down and forward meets the floor where the geometry says (1.4 m ahead for a 45 degree drop): ", down != null and (down as Vector3).is_equal_approx(Vector3(0, 0, -1.4)))
	print("SMOKE pointing level, up, or at a floor further than 15 m, there is no spot: ", RoomPlacement.floor_hit(from, Vector3(0, 0, -1)) == null and RoomPlacement.floor_hit(from, Vector3(0, 1, -1).normalized()) == null and RoomPlacement.floor_hit(from, Vector3(0, -0.05, -1).normalized()) == null)
	var t := RoomPlacement.transform_at(Vector3(4, 0, -6), Vector3(0, 1.6, 0), Vector3(3, 3, 3))
	print("SMOKE a room placed on a floor point is centred over it, standing on the floor: ", t.origin.is_equal_approx(Vector3(4, 1.5, -6)))
	print("SMOKE ...and turned to face the user (its front looks away from them): ", (t.basis * Vector3(0, 0, -1)).is_equal_approx(Vector3(4, 0, -6).normalized()))

	# --- a stand-in main with a right hand and an initialised "XR interface"
	var xr_script := GDScript.new()
	xr_script.source_code = "extends RefCounted\nfunc is_initialized() -> bool:\n\treturn true\n"
	xr_script.reload()
	var main_script := GDScript.new()
	main_script.source_code = "extends Node3D\nvar command_stack\nvar _mates_tool\nvar xr_interface\nvar quality := 0.5\nvar include_hidden := false\nvar tier := \"\"\nfunc mark_dirty() -> void:\n\tpass\nfunc refresh_assembly_tree() -> void:\n\tpass\nfunc reload_world_model(_d: bool = true) -> bool:\n\treturn true\n"
	main_script.reload()
	var main := Node3D.new()
	main.set_script(main_script)
	root.add_child(main)
	main.command_stack = CommandStack.new()
	var xr = xr_script.new()
	var origin := XROrigin3D.new()
	origin.name = "XROrigin3D"
	main.add_child(origin)
	var right := XRController3D.new()
	right.name = "RightController"
	right.tracker = &"right_hand"
	right.set_script(load("res://scripts/controller.gd"))
	right.command_stack = main.command_stack
	origin.add_child(right)
	var fake := FakeApi.new()
	var bytes := RoomManagerTest.new().glb_for([{"pos": Vector3(0, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "k1"}])
	fake.glb = bytes
	var manager := RoomManager.new()
	main.add_child(manager)
	manager.setup(main, null)
	manager.edit = RoomEdit.new(fake)
	manager.configure_backend("http://127.0.0.1:1", "key")
	var messages: Array[String] = []
	manager.status.connect(func(m: String) -> void: messages.append(m))
	await process_frame

	# --- no laser to aim (no XR): the old way, in front of the user
	await manager.begin_placement("S", "Sub")
	var in_front = manager.room_for_part("S")
	print("SMOKE with no XR interface there is no ghost and no placement: the room just opens in front of the user (the desktop preview): ", not manager.is_placing_for("S") and in_front != null and in_front.global_position.z < -1.0 and absf(in_front.global_position.y - 1.5) < 0.001 and right.get_meta("room_placing", false) == false)
	manager.close_all()
	main.xr_interface = xr

	# --- begin: the ghost, the hand's laser belongs to the room
	manager.begin_placement("S", "Sub", "R", "s1")
	await process_frame
	print("SMOKE summoning starts a placement: the Part shows as placing (its button reads Cancel) and a ghost exists, hidden until the laser meets the floor: ", manager.is_placing_for("S") and manager.is_open_for("S") and manager._placing["ghost"] != null and not (manager._placing["ghost"] as Node3D).visible)
	print("SMOKE ...the right hand's laser is the room's now: a trigger does not select a part: ", right.get_meta("room_placing") == true and (func() -> bool:
		right._on_button_pressed("trigger_click")
		return right.selected_node == null).call())
	aim(right, Vector3(0, 1.4, 0), Vector3(3, 0, -5))
	await process_frame
	var ghost: Node3D = manager._placing["ghost"]
	print("SMOKE aiming at the floor puts the ghost over that point, standing on it: ", ghost.visible and absf(ghost.global_position.x - 3.0) < 0.01 and absf(ghost.global_position.z + 5.0) < 0.01 and absf(ghost.global_position.y - 1.5) < 0.001)
	print("SMOKE ...and it looks valid (the room's own colour) on clear floor: ", ghost.is_valid_spot())
	aim(right, Vector3(0, 1.4, 0), Vector3(0, 3, -5))
	await process_frame
	print("SMOKE aiming up hides it again, and there is nothing to drop: ", not ghost.visible and manager._placing["spot"] == null)
	messages.clear()
	right.button_pressed.emit("trigger_click")
	print("SMOKE a trigger with nothing aimed at the floor is refused with the reason, and placing carries on: ", manager.is_placing_for("S") and messages.size() > 0 and messages.back().contains("can't go there"))

	# --- an occupied spot is red and refuses
	var blocker := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(3, 1.5, -5)), Vector3(3, 3, 3))
	RoomRegistry.add_room(blocker)
	aim(right, Vector3(0, 1.4, 0), Vector3(3.5, 0, -5))
	await process_frame
	print("SMOKE aiming where the room would overlap another turns the ghost red, with no spot: ", ghost.visible and not ghost.is_valid_spot() and manager._placing["spot"] == null)
	messages.clear()
	right.button_pressed.emit("trigger_click")
	print("SMOKE ...and the trigger there is refused: ", manager.is_placing_for("S") and RoomRegistry.room_count() == 1 and messages.back().contains("overlap"))
	RoomRegistry.remove_room(blocker)

	# --- cancel with B
	right.button_pressed.emit("by_button")
	print("SMOKE B cancels: no placement, the ghost is gone, the hand's laser is its own again: ", not manager.is_placing_for("S") and right.get_meta("room_placing") == false and RoomRegistry.room_count() == 0)
	await process_frame
	print("SMOKE ...and a trigger afterwards selects parts as normal (the controller's own handler runs): ", (func() -> bool:
		right._on_button_pressed("trigger_click")
		return true).call())

	# --- place and drop: the mesh has loaded while aiming
	manager.begin_placement("S", "Sub", "R", "s1")
	for i in 6:
		await process_frame
	aim(right, Vector3(0, 1.4, 0), Vector3(-4, 0, -6))
	await process_frame
	right.button_pressed.emit("trigger_click")
	for i in 6:
		await process_frame
	var room = manager.room_for_part("S")
	print("SMOKE the trigger drops the room where the ghost was: it opens there (standing on the floor, facing the user) and the placement is over: ", room != null and absf(room.global_position.x + 4.0) < 0.01 and absf(room.global_position.z + 6.0) < 0.01 and absf(room.global_position.y - 1.5) < 0.001 and not manager.is_placing_for("S") and right.get_meta("room_placing") == false)
	print("SMOKE ...ready as a world within the world (its state read and its parts touchable) once opened: ", room != null and room.interactive)
	manager.close_all()
	await process_frame

	# --- the trigger before the mesh has arrived: the room opens as soon as it does
	fake.glb = PackedByteArray() # the fake fetch answers "not ready" ... then we let it through
	var slow_api = FakeApi.new()
	slow_api.glb = bytes
	manager.edit = RoomEdit.new(slow_api)
	manager.begin_placement("S", "Sub")
	aim(right, Vector3(0, 1.4, 0), Vector3(2, 0, -5))
	await process_frame
	right.button_pressed.emit("trigger_click") # (the fake answers at once, so by now it may have loaded: both orders end the same)
	for i in 8:
		await process_frame
	print("SMOKE dropping before or after the mesh arrives ends the same way: the room opens at the chosen spot: ", manager.room_for_part("S") != null and absf(manager.room_for_part("S").global_position.x - 2.0) < 0.01)
	manager.close_all()

	# --- the tree button: a second press while placing gives up
	manager.begin_placement("S", "Sub")
	await process_frame
	manager.toggle_room("S", "Sub")
	print("SMOKE pressing Room again while placing cancels the placement: ", not manager.is_placing_for("S") and right.get_meta("room_placing") == false)

	# --- the limit is checked before aiming
	RoomRegistry.set_max_rooms(1)
	RoomRegistry.add_room(RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(30, 1.5, 0)), Vector3(3, 3, 3)))
	messages.clear()
	manager.begin_placement("T", "T")
	await process_frame
	print("SMOKE at the room limit there is no ghost, just the message: ", not manager.is_placing_for("T") and messages.size() > 0 and messages.back().contains("limit"))
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)
	quit()
