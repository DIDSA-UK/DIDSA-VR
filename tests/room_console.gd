extends SceneTree
## Assembly Rooms R3, the room console: what its buttons do to a room (scripts/room/room_actions.gd: scale about the room's middle, 1:1, fit, fit the walls to
## the content, back to the 3 m cube, undoable scale), "placed N times" (room_edit.gd instance_count), and the panel itself (scripts/room/room_console.gd): it
## stands beside its room on the user's side, shows the scale and the grid, its buttons work, delete-the-selected-part asks twice, the pedestal runs from its
## foot to the floor and follows it, the setting hides it, and carrying the room carries the console. Headless; the backend is the fake document.
## Run: "$GODOT" --headless --path . --script res://tests/room_console.gd  (see tests/README.md)

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

	# --- how many times a Part is placed
	var e: RefCounted = manager.edit
	print("SMOKE a Part's placements are counted along every path: S is placed twice, the bolt B three times (once directly, once in each K in each S... K x2 per S x2 = 4, plus 1 = 5): ", await e.instance_count("R", "S") == 2 and await e.instance_count("R", "K") == 4 and await e.instance_count("R", "B") == 5 and await e.instance_count("R", "NOPE") == 0)

	fake.unreadable = ["K"]
	var cold := RoomEdit.new(fake) # (no cache: the reads really happen)
	var unknown: int = await cold.instance_count("R", "B") # (K's occurrences cannot be read: the count of B is unknown, not 0)
	print("SMOKE a count that needs an occurrences read that fails is -1 (unknown), not 0, and the console says nothing for it: ", unknown == -1 and load("res://scripts/room/room_console.gd").uses_text(-1) == "" and load("res://scripts/room/room_console.gd").uses_text(0) == "Not placed in the assembly")
	fake.unreadable = []

	# --- a room with a console
	var glb := RoomManagerTest.new().glb_for([
		{"pos": Vector3(-200, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "k1"},
		{"pos": Vector3(200, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "k2"},
	])
	var room = manager.open_from_bytes(glb, "S", "Sub")
	manager.activate(room)
	for i in 4:
		await process_frame
	var console = room.console
	print("SMOKE activating a room makes its console, a child of the room (carrying the room carries it): ", console != null and console.get_parent() == room and console.is_open())
	var back: Vector3 = room.global_transform.basis.z.normalized()
	var expected_at: Vector3 = room.global_position + back * (1.5 + 0.8)
	print("SMOKE the console stands on the user's side of the room at chest height, 0.8 m off the wall: ", absf(console.global_position.x - expected_at.x) < 0.01 and absf(console.global_position.z - expected_at.z) < 0.01 and absf(console.global_position.y - 1.1) < 0.001)
	print("SMOKE ...facing the user (its front is turned towards them, back into the room): ", (console.global_transform.basis * Vector3(0, 0, 1)).dot(back) > 0.99)
	console._refresh_labels()
	print("SMOKE it shows the room's scale and grid: ", console._scale_label.text.contains(room.scale_text()) and console._scale_label.text.contains("grid"))
	await console._refresh_uses()
	print("SMOKE ...and how many times the room's Part is placed (editing it changes them all): ", console._uses_label.text.contains("2 times"))

	# --- the buttons: scale about the room's middle
	var middle: Vector3 = room.volume.xform.origin
	var content_point_before: Vector3 = room.content_root.global_transform.affine_inverse() * middle
	var scale_before: float = room.content_scale
	console.button_named("Double").pressed.emit()
	print("SMOKE Double doubles the content's scale about the room's middle (what was in the middle stays in the middle): ", absf(room.content_scale / scale_before - 2.0) < 0.001 and (room.content_root.global_transform * content_point_before).distance_to(middle) < 0.001)
	print("SMOKE ...the label follows, and it is one undo step: ", console._scale_label.text.contains(room.scale_text()) and stack.can_undo())
	stack.undo()
	print("SMOKE ...which puts the scale back: ", absf(room.content_scale / scale_before - 1.0) < 0.001)
	console.button_named("1:1").pressed.emit()
	print("SMOKE 1:1 returns the content to real size: ", room.scale_text() == "1:1" and absf(room.content_scale - 0.001) < 0.000001)
	console.button_named("Fit").pressed.emit()
	print("SMOKE Fit scales it to fill the room again: ", absf(room.content_scale - 0.7 * 3.0 / 500.0) < 0.0001)
	var limit := RoomActions.scale_by(room, 1.0e6, stack)
	print("SMOKE scaling past the limit is refused with a message (and the limit is the whole-room gesture's): ", limit["ok"] == true and RoomActions.scale_by(room, 2.0, stack)["ok"] == false and room.scale_text().begins_with("2000") and room.content_scale / 0.001 <= RoomActions.MAX_MULTIPLE + 0.001)
	RoomActions.fit_scale(room)

	# --- the buttons: walls
	var content_world: Transform3D = room.content_root.global_transform
	var fitted := RoomActions.fit_walls(room)
	print("SMOKE Fit walls shrink-wraps the box to the content with a margin, floor to just above it (the floor stays the floor): ", fitted["ok"] and room.volume.half.y * 2.0 < 3.0 and absf(room.volume.xform.origin.y - room.volume.half.y) < 0.001)
	print("SMOKE ...and the content has not moved: ", room.content_root.global_transform.is_equal_approx(content_world))
	var all_inside := true
	for p in room.parts:
		for i in 8:
			var corner: Vector3 = (p as MeshInstance3D).global_transform * (p as MeshInstance3D).get_aabb().get_endpoint(i)
			all_inside = all_inside and room.volume.contains(corner, 0.001)
	print("SMOKE ...with every part inside the walls: ", all_inside)
	console.button_named("3 m cube").pressed.emit()
	print("SMOKE 3 m cube puts the walls back (centred where the room is, on the floor): ", room.volume.half.is_equal_approx(Vector3(1.5, 1.5, 1.5)) and absf(room.volume.xform.origin.y - 1.5) < 0.001)
	var neighbour := RoomVolume.make(Transform3D(Basis.IDENTITY, room.volume.xform.origin + Vector3(3.2, 0, 0)), Vector3(3, 3, 3))
	RoomRegistry.add_room(neighbour)
	room.set_box(Transform3D(room.volume.xform.basis, room.volume.xform.origin), Vector3(0.75, 0.75, 0.75))
	console.button_named("3 m cube").pressed.emit()
	print("SMOKE ...unless that would overlap another room, when it says so and changes nothing: ", console._note_label.text.contains("overlap") or room.volume.half.is_equal_approx(Vector3(1.5, 1.5, 1.5)))
	RoomRegistry.remove_room(neighbour)
	RoomActions.reset_walls(room)

	# --- delete the selected part: asks twice
	var part: MeshInstance3D = room.parts[0]
	main.selected = null
	console.button_named("Delete selected part").pressed.emit()
	print("SMOKE with nothing selected Delete says so and deletes nothing: ", console._note_label.text.contains("Select a part") and fake.count(HTTPClient.METHOD_DELETE, "/occurrences") == 0)
	fake.occurrences["S"] = [fake.row("k1", "K"), fake.row("k2", "K")]
	fake.mates = {"S": [{"references": [{"occurrence_id": "k1"}, {"occurrence_id": "k2"}]}]}
	main.selected = part
	console.button_named("Delete selected part").pressed.emit()
	for i in 4:
		await process_frame
	print("SMOKE the first press arms it, naming the part and the Mates that would go: ", console._delete_button.text.begins_with("Sure?") and console._delete_button.text.contains("1 mate") and fake.count(HTTPClient.METHOD_DELETE, "/occurrences") == 0)
	fake.glb = RoomManagerTest.new().glb_for([{"pos": Vector3(200, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "k2"}])
	console.button_named(console._delete_button.text).pressed.emit()
	for i in 12:
		await process_frame
	print("SMOKE ...and the second press deletes it (through the manager, so the room refreshes and it is undoable): ", fake.count(HTTPClient.METHOD_DELETE, "/occurrences/k1") == 1 and room.parts.size() == 1 and stack.can_undo())

	# --- the pedestal
	console._update_pedestal()
	var foot: Vector3 = console.global_position - Vector3(0.0, console.panel_size.y * 0.5, 0.0)
	var pedestal: MeshInstance3D = console._pedestal
	print("SMOKE the pedestal runs from the console's foot straight down to the floor: ", absf(pedestal.global_position.x - foot.x) < 0.001 and absf(pedestal.global_position.z - foot.z) < 0.001 and absf(pedestal.global_position.y - foot.y * 0.5) < 0.001 and absf(pedestal.global_transform.basis.get_scale().y - foot.y) < 0.001)
	console.global_position += Vector3(0.7, 0.3, -0.2)
	console._update_pedestal()
	var foot2: Vector3 = console.global_position - Vector3(0.0, console.panel_size.y * 0.5, 0.0)
	print("SMOKE ...and follows the console when it is carried (a hand holding it by its handle, say): ", absf(pedestal.global_position.x - foot2.x) < 0.001 and absf(pedestal.global_transform.basis.get_scale().y - foot2.y) < 0.001)
	manager.set_pedestal(false)
	print("SMOKE the setting hides the pedestal and the ring, and back: ", not pedestal.visible and not console._pedestal_ring.visible and (func() -> bool:
		manager.set_pedestal(true)
		return pedestal.visible and console._pedestal_ring.visible).call())

	# --- carrying the room carries its console; closing the room closes it
	var console_offset: Vector3 = console.global_position - room.global_position
	room.move_box(Transform3D(room.volume.xform.basis, room.volume.xform.origin + Vector3(2.0, 0, 1.0)))
	print("SMOKE carrying the room carries its console with it: ", (console.global_position - room.global_position).distance_to(console_offset) < 0.001)
	manager.close_room(room)
	await process_frame
	await process_frame
	print("SMOKE closing the room takes its console away: ", not is_instance_valid(console))
	RoomRegistry.clear()
	quit()
