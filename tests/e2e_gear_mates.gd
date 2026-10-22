extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): the GEAR, RACK AND PINION and SCREW mates (gears-and-motion plan M5) made with the real mates tool on
## tests/data/gear_pair.didsa (tests/data/make_gear_fixture.py: a fixed plate with two holes 60 mm apart, gear A of 20 teeth and gear B of 40 teeth, module 2,
## each concentric to its hole and flat on the plate, NO gear mate). A gear mate made with the value left empty reads back r = 0.5 and the sense the backend's
## default rule gives for the two axes as they resolve; a `mate-motion` request with gear A turned 90 degrees about the plate's normal answers with gear B
## turned 45 degrees the OPPOSITE way about the same normal, both still on their holes; the commit is stored; Reverse turns B the same way; picks that are not
## axes are refused before anything is sent; a rack and pinion and a screw are made and deleted (the motion of those is tested in the backend).
## Run: "$GODOT" --headless --path . --script res://tests/e2e_gear_mates.gd  (needs secrets.cfg and a running backend)

var main
var mt
var owner_id := ""
var url := ""
var key := ""


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


func face_of_kind(part: Node3D, kind: String) -> int:
	## A triangle of a face the backend calls `kind` ("cylinder", "plane"): what try_pick takes.
	var topology: Dictionary = part.get_meta("topology")
	var face_ids: Array = part.get_meta("face_ids")
	var body_ids: Array = part.get_meta("body_ids")
	for body in topology:
		var kinds: Array = (topology[body] as Dictionary).get("face_kinds", [])
		for t in face_ids.size():
			var f := int(face_ids[t])
			if str(body_ids[t]) == str(body) and f >= 0 and f < kinds.size() and str(kinds[f]) == kind:
				return t
	return -1


func line_edge_of(part: Node3D) -> Dictionary:
	var topology: Dictionary = part.get_meta("topology")
	for body in topology:
		var kinds: Dictionary = (topology[body] as Dictionary).get("edge_kinds", {})
		for index in kinds:
			if str(kinds[index]) == "line":
				return {"kind": "edge", "body_id": str(body), "index": int(index)}
	return {}


func get_json(path: String) -> Variant:
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_GET, path, null)
	return result["json"] if result["ok"] else null


func z_turn(transform: Dictionary) -> float:
	## The turn of a pose about world z, signed (degrees).
	var axis: Array = transform["rotation_axis"]
	return float(transform["rotation_angle_degrees"]) * (1.0 if float(axis[2]) >= 0.0 else -1.0)


func axis_direction(part: Node3D, triangle: int) -> Vector3:
	## The resolved axis direction of the face (the backend's own measure) in the assembly's frame: no occurrence here is rotated.
	var ref: Dictionary = mt.MeshIdentity.occurrence_ref_for(part)
	var sub: Dictionary = mt.MeshIdentity.subshape_ref_for_hit(part, triangle)
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_POST, "/parts/%s/measure" % owner_id, {"refs": [{"occurrence_id": ref["occurrence_id"], "subshape_ref": sub}]})
	var d: Array = result["json"]["axis"]["direction"] if result["ok"] and result["json"].get("axis") != null else [0, 0, 0]
	return Vector3(d[0], d[1], d[2]).normalized()


func motion(occurrence_id: String, wish: Variant, commit := false, reference: Variant = null) -> Dictionary:
	var body := {"transform": wish, "commit": commit, "include_constraint_model": true}
	if reference != null:
		body["reference"] = reference
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_POST, "/parts/%s/occurrences/%s/mate-motion" % [owner_id, occurrence_id], body)
	return result["json"] if result["ok"] and result["json"] is Dictionary else {}


func member_pose(answer: Dictionary, occurrence_id: String) -> Dictionary:
	for m in answer.get("members", []):
		if str(m["occurrence_id"]) == occurrence_id:
			return m["transform"]
	return {}


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	var secrets_path := "user://e2e_gear_mates_secrets.cfg"
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
	var plate := part_of("plate")
	print("SMOKE the fixture loads: a fixed plate and two floating gears, no mates yet: ", gear_a != null and gear_b != null and plate != null and mt.is_fixed(plate) and not mt.is_fixed(gear_a) and (await get_json("/parts/%s/mates" % owner_id) as Array).size() == 4)
	var tri_a := face_of_kind(gear_a, "cylinder")
	var tri_b := face_of_kind(gear_b, "cylinder")
	print("SMOKE each gear has a round face (its bore) the backend names a cylinder: ", tri_a >= 0 and tri_b >= 0)

	# --- picks that are not axes are refused, before anything is sent
	mt.set_active(true)
	mt.mate_type = "gear"
	var flat := face_of_kind(gear_a, "plane")
	var calls_before := 0
	mt.try_pick(gear_a, flat)
	print("SMOKE a flat face is refused as the axis of a gear mate, with the reason: ", mt.picked_labels().is_empty() and mt.status_text().contains("needs an axis"), " ", mt.status_text())
	print("SMOKE ...the prompt asks for a round face, a circular edge or a straight edge: ", mt.status_text().length() > 0)

	# --- the gear mate: two axis picks, the value left empty (Auto)
	mt.try_pick(gear_a, tri_a)
	mt.try_pick(gear_b, tri_b)
	print("SMOKE two axis picks are ready to create (Auto value, nothing to type): ", mt.can_create() and mt.mate_value == 0.0 and not mt.build_create_payload().has("value"))
	await wait_for(func() -> bool: return mt.preview_coupler_value > 0.0, 600)
	print("SMOKE the preview brings the ratio the backend read from the teeth (20 / 40 = 0.5) and shows no ghost: ", absf(mt.preview_coupler_value - 0.5) < 1e-9 and not mt.preview_visible(), " ", mt.preview_coupler_value)
	print("SMOKE ...the status line says turning one will turn the other and where the ratio came from: ", mt.status_text().contains("Turning one part will turn the other") and mt.status_text().contains("1 : 2"), " ", mt.status_text())
	var created: Dictionary = await mt.create_mate()
	print("SMOKE create_mate with the value left empty succeeds: ", created["ok"], " ", created["error"])
	await mt.refresh_mates(owner_id)
	var gear_mate := {}
	for m in mt.mates:
		if str(m["type"]) == "gear":
			gear_mate = m
	var d_a: Vector3 = await axis_direction(gear_a, tri_a)
	var d_b: Vector3 = await axis_direction(gear_b, tri_b)
	var expect_flip: bool = (-signf(d_a.dot(d_b))) > 0.0 # two external gears: k = -c
	print("SMOKE the stored mate is r = 0.5 with the default sense the rule gives for the resolved axes: ", not gear_mate.is_empty() and absf(float(gear_mate["value"]) - 0.5) < 1e-9 and bool(gear_mate["secondary_flip"]) == expect_flip, " ", gear_mate, " dot ", d_a.dot(d_b))
	print("SMOKE creating it moved nothing (both gears still where the fixture put them): ", (await get_json("/parts/%s/occurrences" % owner_id) as Array).filter(func(o): return str(o["id"]) in ["gear-a", "gear-b"]).all(func(o): return absf(z_turn(o["transform"])) < 1e-6))

	# --- turn A 90 degrees about the plate normal: B turns 45 the opposite way
	var occs: Array = await get_json("/parts/%s/occurrences" % owner_id)
	var start := {}
	for o in occs:
		start[str(o["id"])] = o["transform"]
	var wish: Dictionary = (start["gear-a"] as Dictionary).duplicate(true)
	wish["rotation_axis"] = [0, 0, 1]
	wish["rotation_angle_degrees"] = 90.0
	var answer := await motion("gear-a", wish)
	var pose_a := member_pose(answer, "gear-a")
	var pose_b := member_pose(answer, "gear-b")
	print("SMOKE the motion contract for a coupled pair: converged, group DOF 1, no analytic model (the clients keep projecting): ", bool(answer.get("converged", false)) and int(answer.get("dof", -1)) == 1 and answer.get("constraint_model") == null, " dof ", answer.get("dof"))
	print("SMOKE gear A turned 90 degrees about the plate normal gives gear B 45 degrees the OPPOSITE way about the same normal (0.5 degrees): ", not pose_b.is_empty() and absf(z_turn(pose_a) - 90.0) < 0.5 and absf(z_turn(pose_b) + 45.0) < 0.5, " A ", z_turn(pose_a), " B ", z_turn(pose_b))
	var on_holes := true
	for pair in [[pose_a, start["gear-a"]], [pose_b, start["gear-b"]]]:
		for i in 3:
			on_holes = on_holes and absf(float(pair[0]["translation"][i]) - float(pair[1]["translation"][i])) < 1e-3
	print("SMOKE both gears are still on their holes: ", on_holes)

	# --- commit, reload: kept
	await motion("gear-a", wish, true)
	var after: Array = await get_json("/parts/%s/occurrences" % owner_id)
	var stored_b := 0.0
	var stored_a := 0.0
	for o in after:
		if str(o["id"]) == "gear-b":
			stored_b = z_turn(o["transform"])
		if str(o["id"]) == "gear-a":
			stored_a = z_turn(o["transform"])
	print("SMOKE the committed poses are stored (A 90, B -45): ", absf(stored_a - 90.0) < 0.5 and absf(stored_b + 45.0) < 0.5, " ", stored_a, " ", stored_b)

	await mt._adopt_backend_poses(owner_id, "gear turn") # the parts on screen go where the commit put them (an edit saves the shown pose first)

	# --- Reverse (the sense flips): the same turn of A now turns B the same way
	var reversed: Dictionary = await mt.update_mate(owner_id, str(gear_mate["id"]), {"secondary_flip": not bool(gear_mate["secondary_flip"])})
	print("SMOKE editing the mate's sense (Reverse) is accepted and moves nothing: ", reversed["ok"], " ", reversed["error"])
	var back_start := {}
	for o in await get_json("/parts/%s/occurrences" % owner_id):
		back_start[str(o["id"])] = o["transform"]
	var wish2: Dictionary = (back_start["gear-a"] as Dictionary).duplicate(true)
	wish2["rotation_axis"] = [0, 0, 1]
	wish2["rotation_angle_degrees"] = 100.0 # +10 degrees more than where A stands
	var answer2 := await motion("gear-a", wish2)
	var b_now := z_turn(member_pose(answer2, "gear-b"))
	print("SMOKE after Reverse a further +10 degrees on A turns B +5 degrees (the same way, half as far): ", absf((b_now - stored_b) - 5.0) < 0.2, " ", b_now - stored_b)

	# --- value edit
	var edited: Dictionary = await mt.update_mate(owner_id, str(gear_mate["id"]), {"value": 2.0})
	await mt.refresh_mates(owner_id)
	var edited_mate := {}
	for m in mt.mates:
		if str(m["type"]) == "gear":
			edited_mate = m
	print("SMOKE editing the ratio to 2 is accepted: ", edited["ok"] and absf(float(edited_mate["value"]) - 2.0) < 1e-9, " ", edited["error"])
	print("SMOKE the tool's list text for it reads 1 : 0.5: ", mt.coupler_value_text("gear", edited_mate["value"]) == "1 : 0.5")
	var removed: bool = await mt.delete_mate(owner_id, str(gear_mate["id"]))
	print("SMOKE the gear mate deletes: ", removed)

	# --- rack and pinion: the rack's side must be a straight edge
	mt.clear_picks()
	mt.mate_type = "rack_pinion"
	mt.try_pick(gear_a, tri_a)
	mt.try_pick(gear_b, tri_b)
	print("SMOKE a round face is refused as the rack side of a rack and pinion mate: ", mt.picked_labels().size() == 1 and mt.status_text().contains("straight edge"), " ", mt.status_text())
	var edge := line_edge_of(plate)
	mt.try_pick(plate, 0, edge)
	print("SMOKE ...a straight edge of the plate is accepted: ", mt.picked_labels().size() == 2 and not edge.is_empty())
	var rack_made: Dictionary = await mt.create_mate()
	await mt.refresh_mates(owner_id)
	var rack_mate := {}
	for m in mt.mates:
		if str(m["type"]) == "rack_pinion":
			rack_mate = m
	print("SMOKE a rack and pinion mate with its travel typed... left empty and no rack feature in the plate: the backend asks for the value", not rack_made["ok"] and str(rack_made["error"]).length() > 0, " ", rack_made["error"])
	mt.mate_value = 62.832
	rack_made = await mt.create_mate()
	await mt.refresh_mates(owner_id)
	for m in mt.mates:
		if str(m["type"]) == "rack_pinion":
			rack_mate = m
	print("SMOKE ...typed 62.832 mm per turn it is made, and reads back that value: ", rack_made["ok"] and not rack_mate.is_empty() and absf(float(rack_mate["value"]) - 62.832) < 1e-9, " ", rack_made["error"])
	if not rack_mate.is_empty():
		await mt.delete_mate(owner_id, str(rack_mate["id"]))

	# --- screw: the lead is required
	mt.clear_picks()
	mt.mate_type = "screw"
	mt.try_pick(gear_a, tri_a)
	mt.try_pick(gear_b, tri_b)
	print("SMOKE a screw cannot be created without its lead, and the status says so: ", not mt.can_create() and mt.status_text().contains("lead"), " ", mt.status_text())
	mt.mate_value = 2.0
	var screw_made: Dictionary = await mt.create_mate()
	await mt.refresh_mates(owner_id)
	var screw_mate := {}
	for m in mt.mates:
		if str(m["type"]) == "screw":
			screw_mate = m
	print("SMOKE ...with a lead of 2 it is made right-handed by default (sense True) with that value: ", screw_made["ok"] and not screw_mate.is_empty() and float(screw_mate["value"]) == 2.0 and bool(screw_mate["secondary_flip"]), " ", screw_made["error"])
	print("SMOKE ...and its list text reads lead 2 mm: ", mt.coupler_value_text("screw", 2.0) == "lead 2 mm")
	quit()
