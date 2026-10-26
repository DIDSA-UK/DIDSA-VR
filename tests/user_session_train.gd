extends SceneTree
## A person using the gear train demo in VR, real backend, fake-tracker input (see tests/helpers/vr_user.gd): scales it up with both hands, picks the crank's
## hole with the Drive tool from the wheel, pushes the stick and watches the readout, stops, undoes; then drives the rack by a straight edge, and tries the refusals
## (the fixed plate, a flat face). Pictures to USER_SHOTS_DIR under xvfb-run.
## Run: USER_SHOTS_DIR=/tmp/shots xvfb-run -a "$GODOT" --path . --script res://tests/user_session_train.gd   (needs secrets.cfg and a running backend)
## Picture / exploration test: not in ci.sh or ci_render.sh. Every SMOKE line should be true.

const VrUser := preload("res://tests/helpers/vr_user.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")

var main
var mt
var user
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


func get_json(path: String) -> Variant:
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_GET, path, null)
	return result["json"] if result["ok"] else null


func stored() -> Dictionary:
	var out := {}
	for o in await get_json("/parts/%s/occurrences" % owner_id):
		var axis: Array = o["transform"]["rotation_axis"]
		out[str(o["id"])] = {"turn": float(o["transform"]["rotation_angle_degrees"]) * (1.0 if float(axis[2]) >= 0.0 else -1.0), "t": o["transform"]["translation"]}
	return out


func settle(occ: String, key: String, start: Dictionary, min_change: float) -> Dictionary:
	## Waits for the committed poses (a round trip after letting go) until `occ` has changed by min_change.
	var now := {}
	for i in 100:
		now = await stored()
		var a = now[occ][key]
		var b = start[occ][key]
		var change: float = absf(float(a) - float(b)) if key == "turn" else (Vector3(a[0], a[1], a[2]) - Vector3(b[0], b[1], b[2])).length()
		if change > min_change:
			return now
		await user.frames(10)
	return now


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	secrets.save("user://user_session_train_secrets.cfg")
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "user://user_session_train_secrets.cfg"
	main.native_file_path = "res://demo/assemblies/gear_train/Gear_train.didsa"
	root.add_child(main)
	await process_frame
	var loaded: bool = await wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed"), 3600)
	print("SMOKE the gear train opens: ", loaded and main.status_text.begins_with("Loaded "), " ", main.status_text)
	mt = main._mates_tool
	owner_id = main.current_root_part_id()
	await mt.refresh_state(owner_id)
	user = VrUser.new(self, main)
	user.shots_dir = OS.get_environment("USER_SHOTS_DIR")
	await user.frames(5)
	var labels := []
	for n in root.get_tree().get_nodes_in_group("grabbable_parts"):
		labels.append(mt.part_label(n))
	labels.sort()
	print("SMOKE every part has a readable name (no Mesh N): ", labels == ["Bearing block", "Bevel gear A", "Bevel gear B", "Crank handle", "Gear (40 teeth)", "Pinion (20 teeth)", "Plate", "Rack", "Rack guide"], " ", labels)

	var s0: float = main.assembly_root.scale.x
	var s1: float = await user.spread_hands_until(s0 * 6.0)
	print("SMOKE two-handed spread scales the train up: ", s1 > s0 * 4.5, " ", s1 / s0)
	var plate := part_of("plate")
	var crank := part_of("crank")
	user.frame_camera(plate.global_position + plate.get_aabb().get_center() * plate.global_transform.basis.get_scale().x, 1.3, 0.1)
	await user.shot("train_scaled")

	# --- Drive from the wheel, the crank's hole
	var ok: bool = await user.wheel_pick("drive")
	var drive = main.drive_tool
	print("SMOKE the wheel's Drive wedge: ", ok and drive.active)
	var aimed: bool = await user.aim_into_round_face(crank)
	await user.click("right", "trigger_click")
	print("SMOKE the laser in the crank's hole picks the crank to turn: ", aimed and drive.part == crank and drive.kind == "spin", " ", drive.status_text())
	await user.shot("crank_picked")
	var start := await stored()
	# stick LEFT and half way: the way the rack has 40 mm of room (to the right it has 6 and the limit stops it); 70 frames at about 15 rpm is about 25 mm of it
	user.stick("right", Vector2(-0.5, 0.0))
	var reading := ""
	for i in 70:
		await physics_frame
		if i == 55:
			reading = drive.status_text()
	await user.shot("crank_running")
	user.stick("right", Vector2.ZERO)
	await user.frames(4)
	print("SMOKE the readout lists the crank, pinion, gear and the sliding rack, named, with rates: ", reading.contains("Crank handle") and reading.contains("Pinion") and reading.contains("Gear (40") and reading.contains("Rack") and reading.contains("mm/s") and not reading.contains("Mesh"), " ", reading)
	var now := await settle("crank", "turn", start, 20.0)
	var turn: float = float(now["crank"]["turn"]) - float(start["crank"]["turn"])
	print("SMOKE stored: the pinion turned with the crank, the gear half as far the other way: ", absf((float(now["pinion"]["turn"]) - float(start["pinion"]["turn"])) - turn) < 1.0 and absf((float(now["gear"]["turn"]) - float(start["gear"]["turn"])) + turn / 2.0) < 1.0, " crank ", turn)
	var slid: float = float(now["rack"]["t"][0]) - float(start["rack"]["t"][0])
	print("SMOKE ...and the rack slid 125.66 mm per turn along x only: ", absf(absf(slid) - 125.6637 * absf(turn) / 360.0) < 0.5 and absf(float(now["rack"]["t"][1]) - float(start["rack"]["t"][1])) < 1e-6, " slid ", slid)
	print("SMOKE the plate and guide did not move: ", now["plate"]["t"] == start["plate"]["t"] and now["guide"]["t"] == start["guide"]["t"])

	# --- the wheel's Undo takes the whole drive back in one step
	await user.wheel_pill()
	ok = await user.wheel_pick("undo")
	var back := await settle("crank", "turn", now, 20.0)
	print("SMOKE the wheel's Undo puts the whole train back with ONE step: ", ok and absf(float(back["crank"]["turn"]) - float(start["crank"]["turn"])) < 0.5 and absf(float(back["rack"]["t"][0]) - float(start["rack"]["t"][0])) < 0.01, " crank ", back["crank"]["turn"])

	# --- A keeps it running with the stick at rest, B stops it (the real A / B buttons)
	ok = await user.wheel_pick("drive")
	await user.aim_into_round_face(crank)
	await user.click("right", "trigger_click")
	user.stick("right", Vector2(0.575, 0.0))
	for i in 10:
		await physics_frame
	user.stick("right", Vector2.ZERO)
	await user.click("right", "ax_button", 2)
	for i in 20:
		await physics_frame
	print("SMOKE A keeps the drive running at 15 rpm with the stick at rest: ", drive.running and drive.keep and absf(drive.speed - 15.0) < 0.01, " ", drive.status_text())
	await user.click("right", "by_button", 2)
	for i in 4:
		await physics_frame
	print("SMOKE B stops it: ", not drive.running and drive.speed == 0.0 and not drive.keep)
	var kept := await settle("crank", "turn", back, 5.0)
	print("SMOKE the run's poses are stored (the crank turned a little, the pinion with it): ", absf(float(kept["crank"]["turn"]) - float(back["crank"]["turn"])) > 5.0 and absf((float(kept["pinion"]["turn"]) - float(back["pinion"]["turn"])) - (float(kept["crank"]["turn"]) - float(back["crank"]["turn"]))) < 1.0)

	# --- a hand taking a part while the stick is driving: the run stops, the hand has it
	user.stick("right", Vector2(1.0, 0.0))
	for i in 10:
		await physics_frame
	var grab_at: Vector3 = (part_of("gear") as Node3D).global_transform * Vector3(0.0, 0.0, 12.0) # the big gear's middle, just above its face
	var inv: Transform3D = user.origin.global_transform.affine_inverse()
	user.set_hand("left", Transform3D(Basis.IDENTITY, inv * grab_at))
	await user.frames(3)
	user.press("left", "grip_click")
	await user.frames(4)
	print("SMOKE a hand gripping a part while the stick drives stops the drive (the hand and the stick never both steer): ", not drive.running and user.hand("left").held_node != null, " ", user.hand("left").held_node)
	user.stick("right", Vector2.ZERO)
	user.release("left", "grip_click")
	await user.frames(6)
	await settle("crank", "turn", kept, 0.0)

	# --- Relax mates (the sandbox): Drive says so instead of "no mates"
	ok = await user.wheel_pick(["all_tools", "mates"])
	ok = await user.wheel_pick("mate_relax")
	print("SMOKE the Mates ring's Relax wedge relaxes the mates: ", mt.relaxed)
	ok = await user.wheel_pick(["all_tools", "drive"])
	await user.aim_into_round_face(crank)
	await user.click("right", "trigger_click")
	print("SMOKE with the mates relaxed Drive refuses the crank and says why: ", drive.part == null and drive.status_text().contains("relaxed"), " ", drive.status_text())
	await user.wheel_pill()
	ok = await user.wheel_pick(["return_parts"]) if false else true
	await mt.set_relaxed(false)
	print("SMOKE Return parts puts the mates back: ", not mt.relaxed)
	ok = await user.wheel_pick("drive")

	# --- the refusals: a flat face of the plate, then a straight edge of the (grounded) plate
	ok = await user.wheel_pick("drive")
	var flat_point: Vector3 = plate.global_transform * Vector3(150.0, 90.0, 10.0)
	user.aim("right", flat_point + Vector3(0.0, 0.0, 0.35), flat_point)
	await user.frames(3)
	await user.click("right", "trigger_click")
	print("SMOKE the laser on the plate's flat top is refused and nothing is picked: ", drive.part == null and drive.status_text().begins_with("Pick a round face to turn it"), " ", drive.status_text())
	await user.shot("flat_refused")
	var edge_point: Vector3 = plate.global_transform * Vector3(170.0, 45.0, 10.0) # the middle of the plate's right-hand top edge
	user.aim("right", edge_point + Vector3(0.0, 0.0, 0.35), edge_point)
	await user.frames(3)
	await user.click("right", "trigger_click")
	print("SMOKE a straight edge of the grounded plate is refused, by name: ", drive.part == null and drive.status_text().contains("Plate") and drive.status_text().contains("grounded"), " ", drive.status_text())
	await user.shot("plate_refused")

	# --- slide the rack along a straight edge of its own
	var rack := part_of("rack")
	var rack_edge: Dictionary = rack_long_edge(rack)
	user.aim("right", rack_edge["point"] + Vector3(0.0, 0.0, 0.3), rack_edge["point"])
	await user.frames(3)
	await user.click("right", "trigger_click")
	print("SMOKE the laser on a long straight edge of the rack picks it to slide: ", drive.part == rack and drive.kind == "slide", " ", drive.status_text())
	await user.shot("rack_picked")
	var before := await stored()
	user.stick("right", Vector2(1.0, 0.0))
	var slide_reading := ""
	for i in 60:
		await physics_frame
		if i == 45:
			slide_reading = drive.status_text()
	user.stick("right", Vector2.ZERO)
	await user.frames(4)
	print("SMOKE sliding the rack reads out its mm/s and the turning parts: ", slide_reading.contains("Rack 50 mm/s") and slide_reading.contains("Pinion") and slide_reading.contains("rpm"), " ", slide_reading)
	var after := await settle("rack", "t", before, 5.0)
	var moved: float = float(after["rack"]["t"][0]) - float(before["rack"]["t"][0])
	var pinion_turn: float = float(after["pinion"]["turn"]) - float(before["pinion"]["turn"])
	print("SMOKE stored: the rack moved and the pinion turned by 360 degrees per 125.66 mm: ", absf(moved) > 5.0 and absf(absf(pinion_turn) - 360.0 * absf(moved) / 125.6637) < 1.0, " rack ", moved, " pinion ", pinion_turn)
	quit()


func rack_long_edge(part: Node3D) -> Dictionary:
	## A straight edge of the rack along x, at least 20 mm long, on its top face: the midpoint in the world.
	var topology: Dictionary = part.get_meta("topology")
	for body in topology:
		var edges: Dictionary = (topology[body] as Dictionary).get("edges", {})
		var kinds: Dictionary = (topology[body] as Dictionary).get("edge_kinds", {})
		for index in edges:
			var pts: PackedVector3Array = edges[index]
			if pts.size() >= 2 and str(kinds.get(index, "")) == "line":
				var d := pts[pts.size() - 1] - pts[0]
				if d.length() >= 20.0 and absf(d.normalized().x) > 0.999 and absf(pts[0].z - 10.0) < 0.01:
					return {"point": part.global_transform * ((pts[0] + pts[pts.size() - 1]) / 2.0 + Vector3(0.0, 0.4, 0.0))} # 0.4 mm in from the edge, on the rack (the guide shares the edge)
	return {}
