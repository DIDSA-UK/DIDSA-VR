extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): limit mates (DIDSA-CAD M9) in the VR drag, on the gear train demo (demo/assemblies/gear_train/Gear_train.didsa).
## The rack has a travel limit: it may slide 40 mm one way and 6 mm the other. The Drive tool turns the pinion at full stick through the real mates tool's
## constrained-drag loop, the way that slides the rack towards its 6 mm end: on EVERY frame once the backend's motion model is in, the rack sits at or inside
## that end (the projector alone would carry it 56 mm on and the next anchor pop it back), it reaches the end smoothly (no frame moves it more than 1.5 mm), the
## run is flagged as stopped by the limit, and the stored poses are the stopped ones (rack 6 mm, pinion 17.19 degrees, gear half of it the other way). Turning
## back the other way then moves the rack off the stop on the first frame (the Drive tool's wish does not wind up past a stop) and on to the 40 mm end.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_limit.gd  (needs secrets.cfg and a running backend)

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


func stored() -> Dictionary:
	var out := {}
	for o in await get_json("/parts/%s/occurrences" % owner_id):
		out[str(o["id"])] = o["transform"]
	return out


func run_drive(drive, pinion: Node3D, rack: Node3D, stick: float, frames: int) -> Dictionary:
	## `frames` ticks of 1/90 s at `stick`; returns {"max"/"min": the largest / smallest rack x shown (mm), "x": the last, "step": the largest move between two frames,
	## "limit_frames": how many frames were stopped by a limit}.
	var seen := {"max": -1e9, "min": 1e9, "x": 0.0, "step": 0.0, "first_step": 0.0, "limit_frames": 0, "readout": ""}
	await wait_for(func() -> bool: return not mt.has_drag(pinion), 1800) # the previous run's commit has landed and its drag is over
	drive.feed(Vector2(stick, 0.0), false, false)
	drive.tick(1.0 / 90.0)
	await wait_for(func() -> bool: return mt.drag_model_ready(pinion), 1800)
	var last := rack.global_position.x * 1000.0 # metres in the world, millimetres in the backend
	for i in frames:
		drive.feed(Vector2(stick, 0.0), false, false)
		drive.tick(1.0 / 90.0)
		await process_frame
		var x := rack.global_position.x * 1000.0
		seen["max"] = maxf(seen["max"], x)
		seen["min"] = minf(seen["min"], x)
		seen["step"] = maxf(seen["step"], absf(x - last))
		if i == 0:
			seen["first_step"] = x - last
		last = x
		seen["x"] = x
		if mt.drag_at_limit(pinion):
			seen["limit_frames"] += 1
			seen["readout"] = drive.readout_text()
	drive.feed(Vector2.ZERO, false, false)
	drive.tick(1.0 / 90.0)
	return seen


func rack_x_stored(wanted: float) -> float:
	## The stored rack x once it is within 0.2 mm of `wanted` (the commit is a round trip), else the last value read.
	var x := 0.0
	for i in 200:
		x = float(((await stored())["rack"] as Dictionary)["translation"][0])
		if absf(x - wanted) < 0.2:
			break
		for j in 10:
			await process_frame
	return x


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	var secrets_path := "user://e2e_limit_secrets.cfg"
	secrets.save(secrets_path)
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = secrets_path
	main.native_file_path = "res://demo/assemblies/gear_train/Gear_train.didsa"
	root.add_child(main)
	await process_frame
	var loaded: bool = await wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"), 3600)
	if not loaded or not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: the gear train demo did not load - status: ", main.status_text)
		quit(1)
		return
	mt = main._mates_tool
	owner_id = main.current_root_part_id()
	await mt.refresh_state(owner_id)
	var pinion := part_of("pinion")
	var rack := part_of("rack")
	var start := await stored()
	var rack_start_x: float = float((start["rack"] as Dictionary)["translation"][0])

	var drive = main.drive_tool
	drive.set_active(true)
	drive.set_physics_process(false) # this test makes the ticks itself
	var tri := cylinder_triangle(pinion)
	drive.try_pick(pinion, tri, TopologyPick.face_entity(pinion, tri))
	print("SMOKE the Drive tool takes the pinion's bore as a spin axis: ", drive.part == pinion and drive.kind == "spin", " ", drive.status_text())

	# Stick right slides the rack towards its SHORT (6 mm) end; 120 frames at 30 rpm is 160 degrees = 56 mm, far past it
	var undo_before: int = main.command_stack.history_labels().size()
	var short_end := rack_start_x + 6.0
	var short_run := await run_drive(drive, pinion, rack, 1.0, 120)
	print("SMOKE on every frame the rack stays inside the 6 mm end (the projector alone would carry it 56 mm): ", float(short_run["max"]) <= short_end + 0.05, " past the end: ", float(short_run["max"]) - short_end)
	print("SMOKE the rack reaches the end: ", float(short_run["max"]) >= short_end - 0.05, " ", float(short_run["max"]) - short_end)
	print("SMOKE the run is smooth: no frame moves the rack more than 1.5 mm (a pop at an anchor would): ", float(short_run["step"]) < 1.5, " largest step ", short_run["step"])
	print("SMOKE the frames at the end are flagged as stopped by the limit: ", int(short_run["limit_frames"]) > 20, " ", short_run["limit_frames"])
	print("SMOKE the Drive readout says so while it is stopped: ", str(short_run["readout"]).contains("at its limit"), " ", short_run["readout"])
	var stored_short := await rack_x_stored(short_end)
	var after := await stored()
	var turn := z_turn(after["pinion"])
	print("SMOKE the stored rack is at the 6 mm end, the pinion 17.19 degrees and the gear half of it the other way: ", absf(stored_short - short_end) < 0.2 and absf(absf(turn) - 17.1886) < 0.3 and absf(z_turn(after["gear"]) + 0.5 * turn) < 0.3, " ", stored_short - short_end, " ", turn)
	print("SMOKE the whole run is ONE undo step: ", main.command_stack.history_labels().size() == undo_before + 1, " ", main.command_stack.history_labels().size() - undo_before)

	# Stick left: off the stop at once (the wish did not wind up past it), and all the way to the 40 mm end, never past it
	var long_end := rack_start_x - 40.0
	var long_run := await run_drive(drive, pinion, rack, -1.0, 150)
	print("SMOKE turned back the other way the rack comes off the stop at the first frame (nothing wound up): ", float(long_run["first_step"]) < -0.5, " ", long_run["first_step"])
	print("SMOKE it runs on to the 40 mm end and never passes it: ", float(long_run["min"]) >= long_end - 0.05 and float(long_run["min"]) <= long_end + 0.05, " past the end: ", long_end - float(long_run["min"]))
	print("SMOKE that run is smooth too: ", float(long_run["step"]) < 1.5, " largest step ", long_run["step"])
	var stored_long := await rack_x_stored(long_end)
	print("SMOKE the stored rack is at the 40 mm end: ", absf(stored_long - long_end) < 0.2, " ", stored_long - long_end)
	drive.set_active(false)
	quit()
