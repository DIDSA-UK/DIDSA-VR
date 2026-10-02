extends SceneTree
## Two related real-headset fixes, both in controller.gd:
## 1. The laser now shortens to whatever it's actually hitting (a part, or a
##    UI panel via the "ui_hit_distance" meta wrist_tablet.gd/popup_keyboard.gd
##    set) instead of always drawing at its fixed laser_length regardless —
##    real-headset feedback: aiming at the wrist tablet, the laser visibly
##    passed straight through it.
## 2. The LEFT controller no longer laser-selects parts (laser_select_enabled
##    = false, set by main.gd) — real-headset feedback: selecting with the
##    left trigger blocked left-hand locomotion, since locomotion.gd backs
##    off the left thumbstick while left_controller.is_manipulating() (i.e.
##    while it has a selected_node). Left grip-grab is untouched. The right
##    hand is unaffected by either change and still selects normally.
## Instantiates main.tscn (NO backend) with a generated multi-part .glb, same
## technique tools_tab.gd/section_tab.gd already use.
## Run: "$GODOT" --headless --path . --script res://tests/laser_and_left_hand.gd

var main
var l: XRController3D
var r: XRController3D

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg" # no backend => no network
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	l.position = Vector3(-0.3, 1.0, 0)
	r.position = Vector3(0.3, 1.0, 0)
	for i in 4:
		await process_frame

	print("SMOKE laser_select_enabled defaults true (controller.gd is hand-agnostic): ", r.laser_select_enabled == true)
	print("SMOKE main.gd wires the left hand's laser_select_enabled off: ", l.laser_select_enabled == false)

	# a real 2-box .glb, same technique tools_tab.gd/section_tab.gd use
	var scene := Node3D.new()
	for i in 2:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = Vector3(0.15, 0.15, 0.15)
		mi.mesh = bm; mi.name = "Part%d" % i
		mi.position = Vector3(i * 0.8, 1.0, -1.0)
		scene.add_child(mi)
	var gd := GLTFDocument.new(); var gs := GLTFState.new()
	gd.append_from_scene(scene, gs)
	DirAccess.make_dir_recursive_absolute("user://models")
	gd.write_to_filesystem(gs, "user://models/laser_test.glb")
	main.load_glb_file("user://models/laser_test.glb")
	await process_frame
	var parts: Array = main.get_tree().get_nodes_in_group("grabbable_parts")
	print("SMOKE loaded parts: ", parts.size())

	# --- laser length: full by default, nothing in the way
	r.rotation_degrees.x = -20 # aim up and away from everything, including the ground
	await physics_frame; await physics_frame
	print("SMOKE laser at full length with nothing hit: ", is_equal_approx(r._laser_mesh.height, r.laser_length))

	# --- laser shortens to a real part hit (RIGHT hand — laser-select still active there)
	r.position = parts[0].global_position + Vector3(0, 0, 2.0)
	r.look_at(parts[0].global_position, Vector3.UP)
	await physics_frame; await physics_frame
	var expected_part_distance: float = r.global_position.distance_to(parts[0].global_position)
	print("SMOKE laser shortens to a real part hit: ", r._laser_mesh.height < r.laser_length and absf(r._laser_mesh.height - expected_part_distance) < 0.1)

	# --- laser returns to full length once nothing's hit again
	r.rotation_degrees.x = -20
	r.position = Vector3(0.3, 1.0, 0)
	await physics_frame; await physics_frame
	print("SMOKE laser returns to full length once the part hit is gone: ", is_equal_approx(r._laser_mesh.height, r.laser_length))

	# --- laser shortens to the wrist tablet, via the ui_hit_distance meta
	var tab = l.get_node("WristTablet")
	var cam: XRCamera3D = origin.get_node("XRCamera3D")
	cam.position = Vector3(0, 1.6, 0.07); cam.rotation_degrees.x = -90
	r.rotation_degrees.x = -90
	r.position = Vector3(l.position.x + tab.target_position.x, 1.5, l.position.z + tab.target_position.z)
	for i in 3:
		await physics_frame
	r.button_pressed.emit("trigger_click"); await physics_frame; r.button_released.emit("trigger_click"); await physics_frame
	print("SMOKE tablet opened: ", tab.is_open())
	await create_timer(0.5).timeout
	# aim at the bullseye's own former spot is now the open panel's Modes tab; either way ui_hover should be true and shorten the laser
	for i in 3:
		await physics_frame
	var ui_distance: float = r.get_meta("ui_hit_distance", -1.0)
	print("SMOKE right laser shortens to the tablet via ui_hit_distance: ", ui_distance >= 0.0 and is_equal_approx(r._laser_mesh.height, ui_distance))
	tab.close_tablet()
	r.rotation_degrees.x = -20
	r.position = Vector3(0.3, 1.0, 0)
	await physics_frame; await physics_frame
	print("SMOKE laser returns to full length once off the tablet: ", is_equal_approx(r._laser_mesh.height, r.laser_length))

	# --- LEFT hand: aiming and pulling the trigger at a part no longer selects it
	l.position = parts[1].global_position + Vector3(0, 0, 2.0)
	l.look_at(parts[1].global_position, Vector3.UP)
	await physics_frame; await physics_frame
	l.button_pressed.emit("trigger_click")
	await physics_frame
	print("SMOKE left trigger no longer selects a part: ", l.selected_node == null)
	l.button_released.emit("trigger_click")
	await physics_frame

	# --- RIGHT hand: unaffected, trigger-select still works exactly as before
	r.position = parts[1].global_position + Vector3(0, 0, 2.0)
	r.look_at(parts[1].global_position, Vector3.UP)
	await physics_frame; await physics_frame
	r.button_pressed.emit("trigger_click")
	await physics_frame
	print("SMOKE right trigger still selects a part as before: ", r.selected_node == parts[1])
	r.button_released.emit("trigger_click")
	await physics_frame
	r.selected_node = null # deselect for cleanliness (direct assign — no laser aimed at nothing to trigger a real deselect here)

	# --- LEFT hand: grip-grab is untouched — still grabs a part fine
	l.position = parts[0].global_position
	await physics_frame; await physics_frame
	l.button_pressed.emit("grip_click")
	await physics_frame
	print("SMOKE left grip still grabs a part (untouched by the select change): ", l.held_node == parts[0])
	l.button_released.emit("grip_click")
	await physics_frame

	# --- left-hand locomotion is never blocked, since selected_node never gets set there
	print("SMOKE left hand never reports is_manipulating() from plain select (locomotion.gd's own gate stays clear): ", l.is_manipulating() == false)

	DirAccess.remove_absolute("user://models/laser_test.glb")
	quit()
