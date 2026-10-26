extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): the Drive tool (gears-and-motion plan M7) on tests/data/gear_pair.didsa with the gear mate made (A 20 teeth, B 40
## teeth: r = 0.5). The tool picks gear A's bore, the stick is held at full deflection for 60 frames of 1/90 s (30 rpm, 120 degrees) through the real mates tool's
## constrained-drag loop, then the run stops: gear A has turned 120 degrees, gear B 60 degrees the OPPOSITE way about the same axis, both are still on their holes,
## the stored poses are the committed ones, and the whole run is ONE undo step.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_drive.gd  (needs secrets.cfg and a running backend)

const TopologyPick := preload("res://scripts/topology_pick.gd")

var main
var mt
var owner_id := ""


func wait_for(pred: Callable, frames := 1800) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func part_of(occurrence_id: String) -> MeshInstance3D:
	for n in main.get_tree().get_nodes_in_group("grabbable_parts"):
		if str(n.get_meta("occurrence_id", "")) == occurrence_id:
			return n
	return null


func cylinder_triangle(part: Node3D) -> int:
	var topology: Dictionary = part.get_meta("topology")
	var face_ids: Array = part.get_meta("face_ids")
	var body_ids: Array = part.get_meta("body_ids")
	for body in topology:
		var kinds: Array = (topology[body] as Dictionary).get("face_kinds", [])
		for t in face_ids.size():
			var f := int(face_ids[t])
			if str(body_ids[t]) == str(body) and f >= 0 and f < kinds.size() and str(kinds[f]) == "cylinder":
				return t
	return -1


func get_json(path: String) -> Variant:
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_GET, path, null)
	return result["json"] if result["ok"] else null


func z_turn(transform: Dictionary) -> float:
	var axis: Array = transform["rotation_axis"]
	return float(transform["rotation_angle_degrees"]) * (1.0 if float(axis[2]) >= 0.0 else -1.0)


func stored_turns() -> Dictionary:
	var out := {}
	for o in await get_json("/parts/%s/occurrences" % owner_id):
		out[str(o["id"])] = z_turn(o["transform"])
	return out


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	var secrets_path := "user://e2e_drive_secrets.cfg"
	secrets.save(secrets_path)
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = secrets_path
	main.native_file_path = "res://tests/data/gear_pair.didsa"
	root.add_child(main)
	await process_frame
	var loaded: bool = await wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"), 3600)
	if not loaded or not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: the gear fixture did not load - status: ", main.status_text)
		quit(1)
		return
	mt = main._mates_tool
	owner_id = main.current_root_part_id()
	await mt.refresh_state(owner_id)
	var gear_a := part_of("gear-a")
	var gear_b := part_of("gear-b")
	var tri_a := cylinder_triangle(gear_a)
	var tri_b := cylinder_triangle(gear_b)

	# the gear mate (Auto ratio: 0.5)
	mt.set_active(true)
	mt.mate_type = "gear"
	mt.try_pick(gear_a, tri_a)
	mt.try_pick(gear_b, tri_b)
	var created: Dictionary = await mt.create_mate()
	mt.set_active(false)
	print("SMOKE the gear mate is made on the fixture: ", created["ok"], " ", created["error"])
	await mt.refresh_mates(owner_id)
	await mt.refresh_state(owner_id)
	var undo_before: int = main.command_stack.history_labels().size()

	# pick gear A's bore with the Drive tool
	var drive = main.drive_tool
	drive.set_active(true)
	drive.set_physics_process(false) # this test makes the ticks itself, 1/90 s each
	var entity := TopologyPick.face_entity(gear_a, tri_a)
	drive.try_pick(gear_a, tri_a, entity)
	print("SMOKE the Drive tool takes gear A's bore as a spin axis: ", drive.part == gear_a and drive.kind == "spin", " ", drive.status_text())
	var start_a: Transform3D = gear_a.global_transform
	var axis_z: float = signf((start_a.basis * (drive._axis_local["dir"] as Vector3)).normalized().z)

	# 60 frames at full stick: the first one starts the drag, then the anchor has to arrive before the rest
	drive.feed(Vector2(1.0, 0.0), false, false)
	drive.tick(1.0 / 90.0)
	var ready: bool = await wait_for(func() -> bool: return mt.drag_model_ready(gear_a), 1800)
	print("SMOKE the first frame starts a constrained drag and the backend answers with its motion model: ", drive.running and ready)
	for i in 59:
		drive.feed(Vector2(1.0, 0.0), false, false)
		drive.tick(1.0 / 90.0)
		await process_frame
	var readout: String = drive.readout_text()
	print("SMOKE while running the readout shows the driven gear: ", readout.begins_with("gear-a") or readout.contains("30 rpm"), " ", readout)
	drive.feed(Vector2.ZERO, false, false)
	drive.tick(1.0 / 90.0)
	print("SMOKE letting the stick go ends the run: ", not drive.running)

	# the commit is a round trip: wait for the stored poses
	var turns := {}
	var expect_a := axis_z * 120.0
	for i in 200:
		turns = await stored_turns()
		if absf(float(turns.get("gear-a", 0.0)) - expect_a) < 2.0:
			break
		for j in 10:
			await process_frame
	print("SMOKE gear A is stored turned 120 degrees (+-2) about its axis: ", absf(float(turns.get("gear-a", 0.0)) - expect_a) < 2.0, " ", turns.get("gear-a"), " expected ", expect_a)
	print("SMOKE gear B is stored turned 60 degrees (+-2) the OPPOSITE way about the same axis: ", absf(float(turns.get("gear-b", 0.0)) + 0.5 * float(turns.get("gear-a", 0.0))) < 2.0, " ", turns.get("gear-b"))
	print("SMOKE the whole run is ONE undo step: ", main.command_stack.history_labels().size() == undo_before + 1, " ", main.command_stack.history_labels().size() - undo_before)
	var axis_point: Vector3 = drive._axis_local["origin"]
	print("SMOKE gear A turned about its bore: a point on the axis stayed where it was (1 mm): ", (gear_a.global_transform * axis_point).distance_to(start_a * axis_point) < 0.001)
	drive.set_active(false)
	quit()
