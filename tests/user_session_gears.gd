extends SceneTree
## A person using the gear features in VR, with the real backend and real (fake-tracker) input: opens the gear pair, makes a Gear mate with the laser and the tool wheel,
## turns a gear with the Drive tool and by hand, and looks at the readout. Pictures of each step go to USER_SHOTS_DIR when there is a renderer (xvfb-run).
## Run: USER_SHOTS_DIR=/tmp/shots xvfb-run -a "$GODOT" --path . --script res://tests/user_session_gears.gd   (needs secrets.cfg and a running backend)
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


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	secrets.save("user://user_session_secrets.cfg")
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "user://user_session_secrets.cfg"
	main.native_file_path = OS.get_environment("USER_SESSION_FILE") if OS.get_environment("USER_SESSION_FILE") != "" else "res://tests/data/gear_pair.didsa"
	root.add_child(main)
	await process_frame
	var loaded: bool = await wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed"), 3600)
	print("SMOKE the file opens: ", loaded and main.status_text.begins_with("Loaded "), " ", main.status_text)
	mt = main._mates_tool
	owner_id = main.current_root_part_id()
	await mt.refresh_state(owner_id)
	user = VrUser.new(self, main)
	user.shots_dir = OS.get_environment("USER_SHOTS_DIR")
	user.camera.position = Vector3(0.05, 1.45, -0.35) # a person standing a little back from the model, looking at it
	user.camera.look_at(Vector3(0.05, 1.03, -0.99))
	await user.frames(5)
	user.camera.position = Vector3(0.05, 1.22, -0.58)
	user.camera.look_at(Vector3(0.05, 1.03, -0.99))
	await user.shot("opened")
	var s0: float = main.assembly_root.scale.x
	var s1: float = await user.spread_hands_until(s0 * 8.0)
	print("SMOKE both grips on empty space and the hands pulled apart scale the model up (about 8x): ", s1 > s0 * 6.0, " ", s0, " -> ", s1)
	user.camera.look_at(main.assembly_root.global_position + Vector3(0, 0.1, 0))
	await user.shot("scaled_up")
	var gear_a := part_of("gear-a")
	var gear_b := part_of("gear-b")

	# --- Mates tool from the wheel, type Gear
	var ok: bool = await user.wheel_pick("mates")
	print("SMOKE the wheel's Mates wedge switches the Mates tool on: ", ok and main._tablet.manager.is_active("mates"))
	await user.shot("wheel_mates_on")
	ok = await user.wheel_pick(["mate_type", "type_gear"])
	print("SMOKE ...and the Type sub-wheel sets Gear: ", ok and mt.mate_type == "gear", " ", mt.mate_type)
	await user.shot("type_gear")
	main._tablet.open_tablet()
	main._tablet.ui.select_tool("mates")
	await user.frames(12)
	var toggles: Control = main._tablet.pages._mates_toggles_row
	print("SMOKE the tablet's Mates page hides Allow rotation / Minimal movement for a coupler type: ", toggles != null and not toggles.visible)
	await user.shot("tablet_gear")
	main._tablet.close_tablet()
	await user.frames(4)

	# --- point the laser at each gear's bore and pull the trigger
	var a_ok: bool = await pick_bore(gear_a)
	print("SMOKE the laser on gear A's bore picks it (the prompt now asks for the second): ", a_ok, " | ", mt.status_text())
	await user.shot("picked_a")
	var b_ok: bool = await pick_bore(gear_b)
	print("SMOKE ...and on gear B's: two picks, ready to create: ", b_ok and mt.can_create(), " | ", mt.status_text())
	var flip_entry: Array = main.get_node("WheelFlows").entries().filter(func(e: Dictionary) -> bool: return e["id"] == "mate_flip")
	print("SMOKE the wheel's Flip wedge reads Reverse for a gear mate (it has no ghost to flip): ", flip_entry.size() == 1 and flip_entry[0]["label"] == "Reverse", " ", flip_entry[0]["label"] if flip_entry.size() == 1 else "")
	await user.shot("picked_b")
	await wait_for(func() -> bool: return mt.preview_coupler_value > 0.0, 600)
	print("SMOKE the preview says Auto 1 : 2 and no ghost: ", absf(mt.preview_coupler_value - 0.5) < 1e-9, " ", mt.status_text())
	ok = await user.wheel_pick("mate_create")
	await wait_for(func() -> bool: return mt.mates.size() > 4, 600)
	await mt.refresh_mates(owner_id)
	var kinds := []
	for m in mt.mates:
		kinds.append(str(m["type"]))
	print("SMOKE Create on the wheel makes the gear mate: ", ok and kinds.has("gear"), " ", kinds)
	await user.shot("gear_mate_created")
	var gm := {}
	for m in mt.mates:
		if str(m["type"]) == "gear":
			gm = m
	var refs: Array = gm.get("references", [])
	print("SMOKE the mate's two references are round FACES (not the seam lines the laser snapped to): ", refs.size() == 2 and str(refs[0]["subshape_ref"]["shape_type"]) == "face" and str(refs[1]["subshape_ref"]["shape_type"]) == "face")

	# --- Mates off, Drive on from the wheel, pick gear A's bore, push the stick
	ok = await user.wheel_pick(["all_tools", "drive"])
	var drive = main.drive_tool
	print("SMOKE the wheel's Drive wedge switches Drive on (and Mates off): ", ok and drive.active and not mt.active, " ", main._tablet.manager.active_id)
	await user.shot("drive_on")
	var d_ok: bool = await pick_bore_for_drive(gear_a)
	print("SMOKE the laser on gear A's bore picks it to turn (not a slide along the seam): ", d_ok and drive.part == gear_a and drive.kind == "spin", " ", drive.status_text())
	await user.shot("drive_picked")
	var start := await stored_turns()
	user.stick("right", Vector2(1.0, 0.0))
	var statuses := []
	for i in 60:
		await physics_frame
		if i == 40:
			statuses.append(drive.status_text())
	user.stick("right", Vector2.ZERO)
	await user.frames(4)
	await user.shot("drive_running")
	print("SMOKE the readout while running names both gears and their rpm, no node names: ", statuses.size() == 1 and str(statuses[0]).contains("Gear A") and str(statuses[0]).contains("Gear B") and not str(statuses[0]).contains("Mesh"), " ", statuses)
	var turns := {}
	for i in 100:
		turns = await stored_turns()
		if absf(float(turns.get("gear-a", 0.0)) - float(start.get("gear-a", 0.0))) > 20.0:
			break
		await user.frames(10)
	var a_turn: float = float(turns.get("gear-a", 0.0)) - float(start.get("gear-a", 0.0))
	var b_turn: float = float(turns.get("gear-b", 0.0)) - float(start.get("gear-b", 0.0))
	print("SMOKE after stopping, the stored poses: gear A turned about 120 and gear B half as far the other way: ", absf(absf(a_turn) - 120.0) < 15.0 and absf(b_turn + a_turn / 2.0) < 3.0, " A ", a_turn, " B ", b_turn)
	print("SMOKE the whole drive is one undo step on the list: ", main.command_stack.can_undo(), " ", main.command_stack.undo_label())

	# --- Drive off, then turn the big gear by hand: grip it on its axis and twist the wrist 60 degrees
	await user.wheel_pill()
	print("SMOKE the pill under the ring (Clear tool) puts Drive away: ", not drive.active and main._tablet.manager.active_id == "")
	var before := await stored_turns()
	var info: Dictionary = user.round_face_target(gear_b)
	var axis: Vector3 = info["axis_dir"]
	var toward: Vector3 = axis if axis.dot(user.camera.global_position - (info["centre"] as Vector3)) > 0.0 else -axis
	var at: Vector3 = (info["centre"] as Vector3) + toward * 0.02
	var inv: Transform3D = user.origin.global_transform.affine_inverse()
	user.set_hand("right", Transform3D(Basis.IDENTITY, inv * at))
	await user.frames(4)
	user.press("right", "grip_click")
	await user.frames(4)
	var holder: Node3D = user.hand("right").held_node
	print("SMOKE the grip on gear B takes it (hand inside its bounds): ", holder == gear_b, " ", holder)
	await user.shot("grip_b")
	for k in 25:
		var twist := Basis(toward, deg_to_rad(2.4 * (k + 1)))
		user.set_hand("right", Transform3D(twist, inv * at))
		await physics_frame
		await physics_frame
	await user.frames(6)
	await user.shot("grip_b_twisted")
	user.release("right", "grip_click")
	await user.frames(6)
	var after := {}
	for i in 100:
		after = await stored_turns()
		if absf(float(after.get("gear-b", 0.0)) - float(before.get("gear-b", 0.0))) > 20.0:
			break
		await user.frames(10)
	var b2: float = float(after.get("gear-b", 0.0)) - float(before.get("gear-b", 0.0))
	var a2: float = float(after.get("gear-a", 0.0)) - float(before.get("gear-a", 0.0))
	print("SMOKE letting go stores gear B turned about 60 degrees and gear A twice as far the other way: ", absf(absf(b2) - 60.0) < 10.0 and absf(a2 + 2.0 * b2) < 5.0, " B ", b2, " A ", a2)
	quit()


func stored_turns() -> Dictionary:
	var out := {}
	var rows: Variant = await get_json("/parts/%s/occurrences" % owner_id)
	for o in rows:
		var axis: Array = o["transform"]["rotation_axis"]
		out[str(o["id"])] = float(o["transform"]["rotation_angle_degrees"]) * (1.0 if float(axis[2]) >= 0.0 else -1.0)
	return out


func get_json(path: String) -> Variant:
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_GET, path, null)
	return result["json"] if result["ok"] else null


func pick_bore(part: Node3D) -> bool:
	## A person aims the right hand's laser into the hole from above and pulls the trigger.
	if not await user.aim_into_round_face(part):
		return false
	var before: int = mt.picked_labels().size()
	await user.click("right", "trigger_click")
	return mt.picked_labels().size() == before + 1


func pick_bore_for_drive(part: Node3D) -> bool:
	await user.aim_into_round_face(part)
	await user.click("right", "trigger_click")
	return main.drive_tool.part == part
