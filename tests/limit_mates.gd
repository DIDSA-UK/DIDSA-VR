extends SceneTree
## Limit mates in the VR mates tool (DIDSA-CAD M9), no backend: the types on the tablet and the wheel, the pure helpers (bounds, ranges, texts), the create payload (the
## range, and only it), when Create is allowed, the preview's reading of the current value (a fake backend), the list rows and Range action, and the drag's stop:
## `_limit_stop` scales a limit-blind projection back to the bound, exactly where the range ends, for one member and for a train, and leaves a pose inside the
## range alone. The golden vectors (every limit vector to 1e-9) are in tests/local_retraction.gd.
## Run: "$GODOT" --headless --path . --script res://tests/limit_mates.gd  (see tests/README.md)

const MatesTool := preload("res://scripts/mates_tool.gd")
const TabletPages := preload("res://scripts/ui/tablet_pages.gd")
const WheelFlows := preload("res://scripts/ui/wheel_flows.gd")
const Se3 := preload("res://scripts/motion/se3.gd")
const Local := preload("res://scripts/motion/local_retraction.gd")
const FIXTURE := "res://tests/fixtures/motion_vectors.json"


class FakePreviewTool extends "res://scripts/mates_tool.gd":
	var answer := {}
	var requests: Array = []

	func _api_request(method: int, path: String, body_dict) -> Dictionary:
		requests.append({"method": method, "path": path, "body": body_dict})
		if path.contains("preview-mate-solve"):
			return {"ok": true, "code": 200, "json": answer, "error": ""}
		return {"ok": false, "code": 404, "json": {}, "error": "404"}


func _tagged_part(owner: String, occurrence: String, body: String, name: String) -> Node3D:
	var part := Node3D.new()
	part.name = name
	part.set_meta("owner_part_id", owner)
	part.set_meta("occurrence_id", occurrence)
	part.set_meta("face_ids", [0])
	part.set_meta("body_ids", [body])
	part.set_meta("topology", {body: {"face_kinds": ["plane"], "edge_kinds": {}}})
	return part


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	var types: Array = MatesTool.MATE_TYPES
	print("SMOKE the limits are mate types, listed last: ", MatesTool.LIMIT_TYPES == ["limit_distance", "limit_angle"] and types.slice(types.size() - 2) == MatesTool.LIMIT_TYPES)
	print("SMOKE the tablet and the wheel have a label (and the wheel a hint) for them: ", TabletPages.MATE_TYPE_LABELS.slice(types.size() - 2) == ["Limit distance", "Limit angle"] and MatesTool.LIMIT_TYPES.all(func(t: String) -> bool: return WheelFlows.MATE_TYPE_LABELS.has(t) and WheelFlows.MATE_TYPE_HINTS.has(t)))
	print("SMOKE type labels: ", MatesTool.type_label("limit_distance") == "Limit distance" and MatesTool.type_label("limit_angle") == "Limit angle")

	# --- pure helpers
	var ok_bound := MatesTool.parse_limit_bound("limit_distance", " 12.5 ")
	var empty_bound := MatesTool.parse_limit_bound("limit_distance", "")
	print("SMOKE a bound is a number, or empty for none; an angle stays within 180: ", ok_bound["ok"] and ok_bound["value"] == 12.5 and empty_bound["ok"] and empty_bound["value"] == null and not MatesTool.parse_limit_bound("limit_distance", "x")["ok"] and \
		MatesTool.parse_limit_bound("limit_angle", "-180")["ok"] and not MatesTool.parse_limit_bound("limit_angle", "190")["ok"] and MatesTool.parse_limit_bound("limit_distance", "-250")["ok"])
	print("SMOKE a range needs a bound, and min <= max: ", MatesTool.limit_range_error(null, null) != "" and MatesTool.limit_range_error(5.0, null) == "" and MatesTool.limit_range_error(null, 30.0) == "" and \
		MatesTool.limit_range_error(5.0, 30.0) == "" and MatesTool.limit_range_error(30.0, 5.0).contains("above") and MatesTool.limit_range_error(5.0, 5.0) == "")
	print("SMOKE range texts: ", MatesTool.limit_range_text("limit_distance", 0.0, 30.0) == "0 mm to 30 mm" and MatesTool.limit_range_text("limit_distance", 5.0, null) == "min 5 mm" and \
		MatesTool.limit_range_text("limit_angle", null, 110.5) == "max 110.5°" and MatesTool.limit_range_text("limit_angle", null, null) == "" and MatesTool.limit_now_text("limit_distance", 20.0) == "Now 20 mm." and MatesTool.limit_now_text("limit_angle", null) == "")

	# --- the tool: picks, payload, can_create, status
	var part_a := _tagged_part("root", "occ-a", "body-a", "Block")
	var part_b := _tagged_part("root", "occ-b", "body-b", "Stop")
	var tool := MatesTool.new()
	tool.set_active(true)
	tool.mate_type = "limit_distance"
	tool.try_pick(part_a, 0)
	tool.try_pick(part_b, 0)
	print("SMOKE two picks but no range: Create is refused and the status asks for it: ", tool.picked_labels().size() == 2 and not tool.can_create() and tool.status_text().contains("range"))
	tool.limit_min = 5.0
	var payload: Dictionary = tool.build_create_payload()
	print("SMOKE a minimum alone is a one-sided limit: it can be created and the payload carries only that bound: ", tool.can_create() and payload["type"] == "limit_distance" and payload["limit_min"] == 5.0 and not payload.has("limit_max") and not payload.has("value") and (payload["references"] as Array).size() == 2)
	tool.limit_max = 30.0
	payload = tool.build_create_payload()
	print("SMOKE both bounds are sent: ", payload["limit_min"] == 5.0 and payload["limit_max"] == 30.0 and tool.status_text().contains("stops it at the bound"))
	tool.limit_min = 40.0
	print("SMOKE an inverted range cannot be created: ", not tool.can_create())
	tool.limit_min = null
	tool.limit_max = null
	tool.mate_type = "limit_angle"
	print("SMOKE changing the type clears the range: ", tool.limit_min == null and tool.limit_max == null)
	tool.limit_min = -20.0
	tool.limit_max = 50.0
	tool.mate_type = "distance"
	print("SMOKE ...and a distance mate has no range in its payload: ", not tool.build_create_payload().has("limit_min") and not tool.build_create_payload().has("limit_max"))

	# --- the preview brings the current value (a fake backend)
	var fake := FakePreviewTool.new()
	root.add_child(fake)
	await process_frame
	fake.backend_url = "http://example.invalid"
	fake.set_active(true)
	fake.mate_type = "limit_distance"
	fake.answer = {"converged": true, "transform": {"translation": [0, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0},
		"members": [{"occurrence_id": "occ-b", "transform": {"translation": [0, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}}], "limit_value": 20.0}
	fake.limit_min = 5.0
	fake.try_pick(part_a, 0)
	fake.try_pick(part_b, 0)
	await _frames(10)
	print("SMOKE the preview was asked with the range and its current value was read: ", fake.requests.any(func(r: Dictionary) -> bool: return str(r["path"]).contains("preview-mate-solve") and r["body"]["type"] == "limit_distance" and r["body"]["limit_min"] == 5.0) and fake.preview_limit_value == 20.0)
	print("SMOKE no ghost is drawn (a limit places nothing) and the status says where the parts are now: ", not fake.preview_visible() and fake.status_text().contains("Now 20 mm"))

	# --- the tablet's rows and the Range action
	var pages := TabletPages.new()
	pages._mates_tool = tool
	tool.mates = [{"id": "m1", "type": "limit_distance", "references": [], "limit_min": 0.0, "limit_max": 30.0, "limit_value": 20.0, "value": null},
		{"id": "m2", "type": "limit_angle", "references": [], "limit_min": null, "limit_max": 110.0, "limit_value": 12.5, "value": null}]
	var rows: Array = pages._mates_rows()
	var labels0: Array = (rows[0]["actions"] as Array).map(func(a: Dictionary) -> String: return str(a["label"]))
	print("SMOKE a limit row is titled by its type, shows its range and where it is now, and offers Range (not Value or a flip): ", rows[0]["title"] == "Limit distance" and str(rows[0]["subtitle"]) == "0 mm to 30 mm, now 20 mm" and \
		labels0.has("Range") and labels0.has("Delete") and not labels0.has("Value") and not labels0.has("Supplement") and str(rows[1]["subtitle"]) == "max 110°, now 12.5°")

	# --- the drag's stop: _limit_stop on a state with a limit model and a (limit-blind) projection
	var doc = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var by_id := {}
	for c in doc["cases"]:
		by_id[c["id"]] = c
	var slider_in: Dictionary = by_id["local-limit-distance-stops-at-min"]["input"]
	var model = Local.try_parse(slider_in["model"], 8)
	var refs: Array = (slider_in["poses"] as Array).map(func(p): return Se3.pose_from_json(p))
	var state := {"limits": model, "members": model.member_ids, "hyst": {"active": {"refs": refs}}, "at_limit": false}
	var drag := MatesTool.new()
	# a projection 8 mm along (gap 12, inside [5, 30]): untouched
	var inside: Array = [Se3.make_pose([refs[0]["t"][0] + 8.0, refs[0]["t"][1], refs[0]["t"][2]], refs[0]["r"])]
	var shown: Array = drag._limit_stop(state, inside, true)
	print("SMOKE a projection inside the range is left alone: ", absf(shown[0]["t"][0] - inside[0]["t"][0]) < 1e-12 and not state["at_limit"])
	# a projection 40 mm along (gap -20): stopped at the bound, 15 mm along (gap 5), flagged
	var far: Array = [Se3.make_pose([refs[0]["t"][0] + 40.0, refs[0]["t"][1], refs[0]["t"][2]], refs[0]["r"])]
	shown = drag._limit_stop(state, far, true)
	print("SMOKE a projection past the stop is stopped exactly at the bound (15 mm along, gap 5), and flagged: ", absf(shown[0]["t"][0] - (refs[0]["t"][0] + 15.0)) < 1e-4 and state["at_limit"], " ", shown[0]["t"][0] - refs[0]["t"][0])
	var other_end: Array = [Se3.make_pose([refs[0]["t"][0] - 40.0, refs[0]["t"][1], refs[0]["t"][2]], refs[0]["r"])]
	shown = drag._limit_stop(state, other_end, true)
	print("SMOKE ...and the same at the other end (gap 30, 10 mm back): ", absf(shown[0]["t"][0] - (refs[0]["t"][0] - 10.0)) < 1e-4 and state["at_limit"])
	shown = drag._limit_stop(state, far, false)
	state["at_limit"] = false
	drag._limit_stop(state, far, false)
	print("SMOKE only the frame being shown is recorded (an anchor's peek must not flip the flag): ", not state["at_limit"])
	var no_model := {"limits": null, "members": model.member_ids, "hyst": {"active": {"refs": refs}}, "at_limit": false}
	print("SMOKE without a limit model nothing is touched: ", absf(drag._limit_stop(no_model, far, true)[0]["t"][0] - far[0]["t"][0]) < 1e-12)
	var other_group := {"limits": model, "members": ["someone-else"], "hyst": {"active": {"refs": refs}}, "at_limit": false}
	print("SMOKE a model of another group is not applied: ", absf(drag._limit_stop(other_group, far, true)[0]["t"][0] - far[0]["t"][0]) < 1e-12)

	# a hinge: the leaf swung -80 (value +80 above the maximum 50) stops at the bound, 50 degrees the other way
	var hinge_in: Dictionary = by_id["local-limit-angle-stops-at-max"]["input"]
	var hinge_model = Local.try_parse(hinge_in["model"], 8)
	var hinge_refs: Array = (hinge_in["poses"] as Array).map(func(p): return Se3.pose_from_json(p))
	var swung: Array = (hinge_in["wishes"] as Array).map(func(p): return Se3.pose_from_json(p))
	var hinge_state := {"limits": hinge_model, "members": hinge_model.member_ids, "hyst": {"active": {"refs": hinge_refs}}, "at_limit": false}
	shown = drag._limit_stop(hinge_state, swung, true)
	var value: float = hinge_model._limit_row(hinge_model._mates[hinge_model._mates.size() - 1], shown)[0]
	print("SMOKE a swing past the hinge limit stops at the bound (value 50 degrees): ", absf(value - 50.0) < 1e-3 and hinge_state["at_limit"], " ", value)

	# the whole gear train (4 members, the shape of the demo): the cheap stop works for any number of members - no solve, so no per-frame cost to speak of
	var train := _train_model()
	var train_model = Local.try_parse(train["model"], 8)
	var train_refs: Array = (train["poses"] as Array).map(func(p): return Se3.pose_from_json(p))
	var train_state := {"limits": train_model, "members": train_model.member_ids, "hyst": {"active": {"refs": train_refs}}, "at_limit": false}
	var carried: Array = []
	for p in train_refs:
		carried.append(Se3.make_pose([p["t"][0] + 40.0, p["t"][1], p["t"][2]], p["r"]))
	var started := Time.get_ticks_usec()
	shown = drag._limit_stop(train_state, carried, true)
	var micros := Time.get_ticks_usec() - started
	print("SMOKE four members: carried 40 mm on, they stop together at the 6 mm bound: ", absf(shown[0]["t"][0] - (train_refs[0]["t"][0] + 6.0)) < 1e-3 and absf(shown[3]["t"][0] - (train_refs[3]["t"][0] + 6.0)) < 1e-3 and train_state["at_limit"])
	print("SMOKE BENCH the stop on four members: ", micros, " us (a headset frame is 11000 us) ", micros < 20000)

	for n in [part_a, part_b]:
		n.free()
	tool.free()
	drag.free()
	fake.queue_free()
	quit()


func _train_model() -> Dictionary:
	## Four members that all slide along x together (a stand-in for the gear train's group): each flat on a plate and a guide, the first one's +x end limited to a gap of
	## [-1000, 6] mm from a plate edge at x = 100 (so it may go 6 mm on from where it starts, gap 0 at the start -> value -> start x + 6).
	var flat_a := {"member": 0, "point": [0.0, 0.0, 0.0], "direction": [0.0, 0.0, -1.0], "plane": {"origin": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, -1.0]}}
	var plate := {"member": -1, "point": [0.0, 0.0, 0.0], "direction": [0.0, 0.0, 1.0], "plane": {"origin": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0]}, "frozen": {"r": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], "t": [0.0, 0.0, 0.0]}}
	var mates: Array = []
	for m in 4:
		var a: Dictionary = flat_a.duplicate(true)
		a["member"] = m
		mates.append({"type": "coincident", "value": null, "allow_rotation": true, "alignment": -1, "side": 1, "perp": 1, "a": a, "b": plate})
	var end_a := {"member": 0, "point": [10.0, 0.0, 0.0], "direction": [1.0, 0.0, 0.0], "plane": {"origin": [10.0, 0.0, 0.0], "normal": [1.0, 0.0, 0.0]}}
	var edge := {"member": -1, "point": [100.0, 0.0, 0.0], "direction": [1.0, 0.0, 0.0], "plane": {"origin": [100.0, 0.0, 0.0], "normal": [1.0, 0.0, 0.0]}, "frozen": {"r": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], "t": [0.0, 0.0, 0.0]}}
	# the first member sits at x = 10 (its +x end at 20), so the gap (20 - 100) . 1 = -80 now; the range [-1000, -74] lets it go 6 mm on
	mates.append({"type": "limit_distance", "id": "end", "min": -1000.0, "max": -74.0, "a": end_a, "b": edge})
	var poses: Array = []
	for m in 4:
		poses.append({"translation": [10.0 + 20.0 * m, 0.0, 0.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0})
	return {"model": {"version": 6, "members": ["pinion", "gear", "rack", "crank"], "mates": mates}, "poses": poses}
