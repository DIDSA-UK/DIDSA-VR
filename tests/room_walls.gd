extends SceneTree
## Assembly Rooms R3, the walls (scripts/room/room.gd, shaders/room_walls.gdshader), the logic that needs no pixels: the grid keeps a round real-world step
## whatever the room's scale (cells 0.25 to 0.625 m wide on screen), the glass is on by default and off with the setting, the walls follow a changed box, the
## grid reveal follows the hands, a held face can be lit, and the manager applies the setting to open and new rooms. (tests/room_walls_render.gd draws it.)
## Run: "$GODOT" --headless --path . --script res://tests/room_walls.gd  (see tests/README.md)

const Room := preload("res://scripts/room/room.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomManager := preload("res://scripts/room/room_manager.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")


func _initialize() -> void:
	RoomRegistry.clear()
	# --- the grid step
	print("SMOKE at 1:1 the grid is 500 mm (0.5 m cells), at 21:1 it is 20 mm (0.42 m), at 1:20 it is 5 m: ", Room.grid_step_mm(0.001) == 500.0 and Room.grid_step_mm(0.021) == 20.0 and Room.grid_step_mm(0.00005) == 5000.0)
	var all_ok := true
	var last := 0.0
	for exponent in range(-60, 20): # scales from 1:1000 to 100:1
		var s := 0.001 * pow(10.0, exponent / 10.0)
		var cell := Room.grid_step_mm(s) * s
		if cell < 0.25 - 0.0001 or cell >= 0.6251:
			all_ok = false
	print("SMOKE whatever the room's scale the grid cell on screen stays between 0.25 and 0.625 m: ", all_ok)
	var steps_round := true
	for s in [0.001, 0.0037, 0.021, 0.3, 0.00002]:
		var step := Room.grid_step_mm(s)
		var mantissa := step / pow(10.0, floorf(log(step) / log(10.0)))
		steps_round = steps_round and (absf(mantissa - 1.0) < 0.001 or absf(mantissa - 2.0) < 0.001 or absf(mantissa - 5.0) < 0.001)
	print("SMOKE ...and the step is always a round one (1, 2 or 5 times a power of ten): ", steps_round)

	# --- a room's walls
	var glb := RoomManagerTest.new().glb_for([{"pos": Vector3.ZERO, "size": Vector3(100, 100, 100), "owner": "S", "occ": "k1"}])
	var holder := Node3D.new()
	root.add_child(holder)
	var room := Room.new()
	room.build(glb, Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -3)), Vector3(3, 3, 3), "S", "Sub")
	holder.add_child(room)
	var slot := RoomRegistry.add_room(room.volume)
	room.register(slot)
	await process_frame
	var glass: MeshInstance3D = room.get_node("Glass")
	var wire: MeshInstance3D = room.get_node("Walls")
	print("SMOKE a room has both: the thin wireframe and the glass box, glass on by default: ", wire != null and glass != null and glass.visible and (glass.mesh as BoxMesh).size.is_equal_approx(Vector3(3, 3, 3)))
	room.set_glass(false)
	print("SMOKE glass off leaves the wireframe (the room is still marked), glass on brings it back: ", not glass.visible and wire.visible and (func() -> bool:
		room.set_glass(true)
		return glass.visible).call())
	var mat: ShaderMaterial = glass.material_override
	print("SMOKE the glass wears the room's colour and knows its size: ", (mat.get_shader_parameter("tint") as Color).is_equal_approx(room.colour) and (mat.get_shader_parameter("half_size") as Vector3).is_equal_approx(Vector3(1.5, 1.5, 1.5)))
	print("SMOKE the grid step is set for the room's scale, in metres (round mm times metres per mm): ", absf(float(mat.get_shader_parameter("grid_step")) - Room.grid_step_mm(room.content_scale) * room.content_scale) < 0.0001 and room.grid_text().begins_with("grid "))

	# --- the box changes (a wall drag): the walls follow
	room.volume.half = Vector3(2.0, 1.0, 0.75)
	room.apply_volume()
	print("SMOKE after the box changes the glass and its shader follow it: ", (glass.mesh as BoxMesh).size.is_equal_approx(Vector3(4, 2, 1.5)) and (mat.get_shader_parameter("half_size") as Vector3).is_equal_approx(Vector3(2.0, 1.0, 0.75)))
	room.volume.half = Vector3(1.5, 1.5, 1.5)
	room.apply_volume()

	# --- the grid follows the hands, in the room's frame, and the scale
	room.update_reveal([Vector3(0, 1.5, -3) + Vector3(1.0, 0.0, 0.5), Vector3(100, 100, 100)])
	var a: Vector3 = mat.get_shader_parameter("hand_a")
	print("SMOKE the reveal is told where the hands are in the room's own frame: ", a.is_equal_approx(Vector3(1.0, 0.0, 0.5)))
	room.content_root.scale = Vector3.ONE * 0.021
	room.update_reveal([])
	print("SMOKE ...and the grid step follows the room's scale when a gesture changes it (no call needed): ", absf(float(mat.get_shader_parameter("grid_step")) - 20.0 * 0.021) < 0.0001)
	room.set_active_face(4)
	print("SMOKE a face can be lit while a drag holds it, and several at once (a corner moves three faces): ", int(mat.get_shader_parameter("active_faces")) == 16 and (func() -> bool:
		room.set_active_faces(0b010101)
		return int(mat.get_shader_parameter("active_faces")) == 21).call())

	# --- the manager's setting reaches open and new rooms
	RoomRegistry.clear()
	room.queue_free()
	await process_frame
	var main_script := GDScript.new()
	main_script.source_code = "extends Node3D\nvar command_stack\nvar _mates_tool\nvar quality := 0.5\nvar include_hidden := false\nvar tier := \"\"\n"
	main_script.reload()
	var main := Node3D.new()
	main.set_script(main_script)
	root.add_child(main)
	var manager := RoomManager.new()
	main.add_child(manager)
	manager.setup(main, null)
	manager.glass = false
	var a_room = manager.open_from_bytes(glb, "S", "Sub")
	print("SMOKE a room opened while the setting is off has no glass: ", not a_room.get_node("Glass").visible)
	manager.set_glass(true)
	print("SMOKE ...and turning the setting on shows it on the open room: ", a_room.get_node("Glass").visible)
	manager.close_all()
	RoomRegistry.clear()
	quit()
