extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): the gear train demo (demo/assemblies/gear_train/Gear_train.didsa, gears-and-motion plan M8). Opened as a file, it has
## its three coupler mates (pinion to gear, rack and pinion, crank to pinion) and `mate-motion` with the crank turned 90 degrees answers with the pinion turned the
## same 90 degrees, the 40-tooth gear 45 degrees the opposite way, the rack slid a quarter of its travel per turn (about 31.4 mm) along x only, and the plate and guide
## still. A second request from the new anchor keeps going. The rack also has a travel limit (M9): it may slide 40 mm one way and only 6 mm the other,
## so the crank turned the way that slides it 31.4 mm gets all of it, and turned the other way the rack stops at 6 mm and the whole train stops with it.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_gear_train.gd  (needs secrets.cfg and a running backend)

var main
var mt
var owner_id := ""


func wait_for(pred: Callable, frames := 1800) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func z_turn(transform: Dictionary) -> float:
	var axis: Array = transform["rotation_axis"]
	return float(transform["rotation_angle_degrees"]) * (1.0 if float(axis[2]) >= 0.0 else -1.0)


func get_json(path: String) -> Variant:
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_GET, path, null)
	return result["json"] if result["ok"] else null


func motion(occurrence_id: String, wish: Variant, reference: Variant = null) -> Dictionary:
	var body := {"transform": wish, "commit": false, "include_constraint_model": true}
	if reference != null:
		body["reference"] = reference
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_POST, "/parts/%s/occurrences/%s/mate-motion" % [owner_id, occurrence_id], body)
	return result["json"] if result["ok"] and result["json"] is Dictionary else {}


func pose_of(answer: Dictionary, occurrence_id: String) -> Dictionary:
	for m in answer.get("members", []):
		if str(m["occurrence_id"]) == occurrence_id:
			return m["transform"]
	return {}


func basis_of(transform: Dictionary) -> Basis:
	var axis: Array = transform["rotation_axis"]
	return Basis(Vector3(axis[0], axis[1], axis[2]).normalized(), deg_to_rad(float(transform["rotation_angle_degrees"])))


func turned_since(start: Dictionary, now: Dictionary) -> Dictionary:
	## How a part has turned from its start pose, in the WORLD: {"axis": unit Vector3 (signed so the angle is positive), "deg": the angle}.
	var q := Quaternion(basis_of(now) * basis_of(start).inverse())
	var angle := q.get_angle()
	var axis := q.get_axis() if angle > 1e-9 else Vector3.ZERO
	return {"axis": axis, "deg": rad_to_deg(angle)}


func crank_wish(start: Dictionary, degrees: float) -> Dictionary:
	var wish: Dictionary = (start["crank"] as Dictionary).duplicate(true)
	wish["rotation_axis"] = [0, 0, 1]
	wish["rotation_angle_degrees"] = degrees
	# the crank's origin is its corner, not its hole: turn it about the pinion's axis (through (50, 55)), moving the origin round with it
	var centre := Vector2(50.0, 55.0)
	var t: Array = (start["crank"] as Dictionary)["translation"]
	var turned := (Vector2(float(t[0]), float(t[1])) - centre).rotated(deg_to_rad(degrees)) + centre
	wish["translation"] = [turned.x, turned.y, float(t[2])]
	return wish


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	var secrets_path := "user://e2e_gear_train_secrets.cfg"
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
	var mates: Array = await get_json("/parts/%s/mates" % owner_id)
	var kinds := {}
	for m in mates:
		kinds[str(m["type"])] = int(kinds.get(str(m["type"]), 0)) + 1
	print("SMOKE the demo has four gear mates (two spur, one rigid, one bevel) and a rack and pinion mate, plus its plain mates: ", kinds.get("rack_pinion", 0) == 1 and kinds.get("concentric", 0) == 5 and kinds.get("coincident", 0) == 7 and kinds.get("limit_distance", 0) == 1 and kinds.get("gear", 0) == 4, " ", kinds)
	var start := {}
	for o in await get_json("/parts/%s/occurrences" % owner_id):
		start[str(o["id"])] = o["transform"]
	var answer := await motion("crank", crank_wish(start, -90.0)) # the way the rack has room for (40 mm): the whole quarter turn
	print("SMOKE turning the crank 90 degrees converges, one degree of freedom for the whole train: ", bool(answer.get("converged", false)) and int(answer.get("dof", -1)) == 1, " dof ", answer.get("dof"))
	var crank := pose_of(answer, "crank")
	var pinion := pose_of(answer, "pinion")
	var gear := pose_of(answer, "gear")
	var rack := pose_of(answer, "rack")
	print("SMOKE the pinion turns with the crank (90 degrees, same way): ", not pinion.is_empty() and absf(z_turn(pinion) - z_turn(crank)) < 0.5 and absf(absf(z_turn(pinion)) - 90.0) < 0.5, " ", z_turn(pinion))
	print("SMOKE the 40-tooth gear turns half as far the opposite way: ", not gear.is_empty() and absf(z_turn(gear) + 0.5 * z_turn(pinion)) < 0.5, " ", z_turn(gear))
	var slid: Array = []
	if not rack.is_empty():
		for i in 3:
			slid.append(float(rack["translation"][i]) - float((start["rack"] as Dictionary)["translation"][i]))
	# the bevel pair (20 teeth to 20 teeth, crossed axes): bevel A is rigid with the 40-tooth gear (the same turn about the shaft, world z), bevel B turns with A
	# at 1 : 1 about the CROSSED axis, world x
	var bevel_a := pose_of(answer, "bevel_a")
	var bevel_b := pose_of(answer, "bevel_b")
	var turn_a := turned_since(start["bevel_a"], bevel_a) if not bevel_a.is_empty() else {"axis": Vector3.ZERO, "deg": 0.0}
	var turn_b := turned_since(start["bevel_b"], bevel_b) if not bevel_b.is_empty() else {"axis": Vector3.ZERO, "deg": 0.0}
	print("SMOKE bevel A turns with the 40-tooth gear: the same 45 degrees about the shaft (world z): ", absf(float(turn_a["deg"]) - 45.0) < 0.1 and absf(absf((turn_a["axis"] as Vector3).z) - 1.0) < 1e-6, " ", turn_a)
	print("SMOKE bevel B turns 1 : 1 with A, 45 degrees about world x (a crossed axis, not parallel to the shaft): ", absf(float(turn_b["deg"]) - 45.0) < 0.1 and absf(absf((turn_b["axis"] as Vector3).x) - 1.0) < 1e-6, " ", turn_b)
	var apex_b: Array = bevel_b["translation"] if not bevel_b.is_empty() else [0, 0, 0]
	print("SMOKE bevel B stays on its axis (its origin, the apex, did not move): ", absf(float(apex_b[0]) - float(start["bevel_b"]["translation"][0])) < 1e-6 and absf(float(apex_b[1]) - float(start["bevel_b"]["translation"][1])) < 1e-6 and absf(float(apex_b[2]) - float(start["bevel_b"]["translation"][2])) < 1e-6, " ", apex_b, " from ", start["bevel_b"]["translation"])
	var per_turn := PI * 2.0 * 20.0 # module 2, 20 teeth: pitch circumference
	print("SMOKE the rack slid a quarter of 125.66 mm along x only: ", slid.size() == 3 and absf(absf(slid[0]) - per_turn / 4.0) < 0.1 and absf(slid[1]) < 1e-6 and absf(slid[2]) < 1e-6, " ", slid)
	var still := true
	for id in ["plate", "guide"]:
		if not pose_of(answer, id).is_empty():
			still = false
	print("SMOKE the fixed plate and guide are not in the answer: ", still)
	# the other way the rack has only 6 mm: a quarter turn the other way asks for 31.4 mm, the limit stops the rack at 6 and the pinion and gear with it
	var stopped := await motion("crank", crank_wish(start, 90.0))
	var stopped_rack := pose_of(stopped, "rack")
	var stopped_pinion := pose_of(stopped, "pinion")
	var stopped_gear := pose_of(stopped, "gear")
	var slid_x := float(stopped_rack["translation"][0]) - float((start["rack"] as Dictionary)["translation"][0]) if not stopped_rack.is_empty() else 0.0
	print("SMOKE turned the other way the rack stops at its limit (6 mm, not 31.4): ", bool(stopped.get("converged", false)) and absf(slid_x - 6.0) < 0.01, " ", slid_x)
	var pinion_turn := z_turn(stopped_pinion) if not stopped_pinion.is_empty() else 0.0
	print("SMOKE the pinion and gear stop with the rack (6 mm of 125.66 per turn = 17.19 degrees; the gear half of it the other way): ", absf(pinion_turn - 360.0 * 6.0 / (PI * 2.0 * 20.0)) < 0.05 and not stopped_gear.is_empty() and absf(z_turn(stopped_gear) + 0.5 * pinion_turn) < 0.05, " ", pinion_turn)
	print("SMOKE the answer carries a version-6 constraint model for the clients' per-frame stop: ", int((stopped.get("constraint_model", {}) as Dictionary).get("version", 0)) == 6)
	quit()
