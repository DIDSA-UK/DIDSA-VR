extends SceneTree
## The coupler mates in the VR mates tool (gears-and-motion plan M5), no backend: the types on the tablet and the wheel, the pick rules (an axis, the
## rack's a straight edge), the create payloads (Auto = no value, a typed value, the screw's lead), Reverse / Left-hand measured from the backend's
## default sense, the value texts and parse rules, and the preview's reading of the ratio (a fake backend).
## Run: "$GODOT" --headless --path . --script res://tests/gear_mates.gd  (see tests/README.md)

const MatesTool := preload("res://scripts/mates_tool.gd")
const TabletPages := preload("res://scripts/ui/tablet_pages.gd")
const WheelFlows := preload("res://scripts/ui/wheel_flows.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")


class FakePreviewTool extends "res://scripts/mates_tool.gd":
	var answer := {}
	var requests: Array = []

	func _api_request(method: int, path: String, body_dict) -> Dictionary:
		requests.append({"method": method, "path": path, "body": body_dict})
		if path.contains("preview-mate-solve"):
			return {"ok": true, "code": 200, "json": answer, "error": ""}
		return {"ok": false, "code": 404, "json": {}, "error": "404"}


func _tagged_part(owner: String, occurrence: String, body: String, face_kinds: Array, edge_kinds: Dictionary, name: String) -> Node3D:
	## Faces 0..n-1 (one triangle each in meta), with the backend's kinds in the topology meta.
	var part := Node3D.new()
	part.name = name
	part.set_meta("owner_part_id", owner)
	part.set_meta("occurrence_id", occurrence)
	var ids := []
	var bodies := []
	for i in face_kinds.size():
		ids.append(i)
		bodies.append(body)
	part.set_meta("face_ids", ids)
	part.set_meta("body_ids", bodies)
	part.set_meta("topology", {body: {"face_kinds": face_kinds, "edge_kinds": edge_kinds}})
	return part


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	# --- the types
	var types: Array = MatesTool.MATE_TYPES
	print("SMOKE the mates tool lists the three couplers after the others: ", types.slice(types.size() - 3) == ["gear", "rack_pinion", "screw"] and MatesTool.COUPLER_TYPES == ["gear", "rack_pinion", "screw"])
	print("SMOKE the tablet has a label for every type, in the same order: ", TabletPages.MATE_TYPE_LABELS.size() == types.size() and TabletPages.MATE_TYPE_LABELS.slice(types.size() - 3) == ["Gear", "Rack and pinion", "Screw"])
	print("SMOKE the wheel has a label and a hint for every type: ", types.all(func(t: String) -> bool: return WheelFlows.MATE_TYPE_LABELS.has(t) and WheelFlows.MATE_TYPE_HINTS.has(t)))
	print("SMOKE type labels: ", MatesTool.type_label("rack_pinion") == "Rack and pinion" and MatesTool.type_label("gear") == "Gear" and MatesTool.type_label("screw") == "Screw" and MatesTool.type_label("concentric") == "Concentric")

	# --- pick rules
	print("SMOKE axis kinds are read from the backend's kinds: ", true)
	var gear_a := _tagged_part("root", "occ-a", "body-a", ["plane", "cylinder", "other"], {0: "line", 1: "circle", 2: "other"}, "Gear A")
	var gear_b := _tagged_part("root", "occ-b", "body-b", ["plane", "cylinder", "other"], {0: "line", 1: "circle", 2: "other"}, "Gear B")
	var plain := _tagged_part("root", "occ-c", "body-c", ["plane"], {}, "Block")
	var unknown := Node3D.new()
	unknown.set_meta("owner_part_id", "root")
	unknown.set_meta("occurrence_id", "occ-u")
	unknown.set_meta("face_ids", [0])
	unknown.set_meta("body_ids", ["body-u"])
	print("SMOKE axis_kind: ", TopologyPick.axis_kind(gear_a, {"kind": "face", "body_id": "body-a", "index": 1}) == "cylinder" and TopologyPick.axis_kind(gear_a, {"kind": "face", "body_id": "body-a", "index": 0}) == "plane" and
		TopologyPick.axis_kind(gear_a, {"kind": "edge", "body_id": "body-a", "index": 0}) == "line" and TopologyPick.axis_kind(gear_a, {"kind": "edge", "body_id": "body-a", "index": 1}) == "circle" and
		TopologyPick.axis_kind(gear_a, {"kind": "vertex", "body_id": "body-a", "index": 0}) == "vertex" and TopologyPick.axis_kind(unknown, {"kind": "face", "body_id": "body-u", "index": 0}) == "")
	print("SMOKE coupler_rejection: a round face, a circular edge and a straight edge pass; a flat face, a corner and an odd curve do not; the rack side must be a line; an unknown kind passes: ",
		MatesTool.coupler_rejection("gear", 0, "cylinder") == "" and MatesTool.coupler_rejection("gear", 1, "circle") == "" and MatesTool.coupler_rejection("screw", 0, "line") == "" and
		MatesTool.coupler_rejection("gear", 0, "plane").contains("needs an axis") and MatesTool.coupler_rejection("gear", 0, "vertex") != "" and MatesTool.coupler_rejection("gear", 0, "other") != "" and
		MatesTool.coupler_rejection("rack_pinion", 0, "cylinder") == "" and MatesTool.coupler_rejection("rack_pinion", 1, "line") == "" and MatesTool.coupler_rejection("rack_pinion", 1, "cylinder").contains("straight edge") and
		MatesTool.coupler_rejection("gear", 0, "") == "")

	var tool := MatesTool.new()
	tool.set_active(true)
	tool.mate_type = "gear"
	print("SMOKE the prompts ask for an axis (and the rack's second for a straight edge): ", tool.status_text().contains("round face") and tool.status_text().contains("first part"))
	tool.try_pick(gear_a, 0) # a flat face
	print("SMOKE a flat face is refused with the reason and not picked: ", tool.picked_labels().is_empty() and tool.status_text().contains("needs an axis"))
	tool.try_pick(gear_a, 1)
	print("SMOKE a round face is picked: ", tool.picked_labels() == ["Gear A"])
	tool.try_pick(gear_b, 1)
	print("SMOKE two axes complete a gear mate and it can be created with no value (Auto): ", tool.picked_labels().size() == 2 and tool.can_create())

	# --- payloads
	var payload: Dictionary = tool.build_create_payload()
	print("SMOKE the Auto payload is a gear mate of two references with no value and no sense: ", payload["type"] == "gear" and (payload["references"] as Array).size() == 2 and not payload.has("value") and not payload.has("secondary_flip") and not payload.has("alignment"))
	tool.mate_value = 0.5
	print("SMOKE a typed ratio is sent: ", tool.build_create_payload()["value"] == 0.5)
	tool.mate_secondary_flip = 1
	print("SMOKE a chosen sense is sent (and only then): ", tool.build_create_payload()["secondary_flip"] == true)
	tool.mate_type = "screw"
	print("SMOKE changing the type to a coupler of another kind forgets the value and the sense: ", tool.mate_value == 0.0 and tool.mate_secondary_flip == -1)
	print("SMOKE a screw with no lead cannot be created, and the status asks for it: ", not tool.can_create() and tool.status_text().contains("lead"))
	tool.mate_value = 2.0
	print("SMOKE ...with a lead it can, and the payload is a screw with value 2: ", tool.can_create() and tool.build_create_payload()["type"] == "screw" and tool.build_create_payload()["value"] == 2.0)
	tool.mate_type = "distance"
	print("SMOKE going back to a distance forgets the lead: ", tool.mate_value == 0.0)
	tool.mate_type = "rack_pinion"
	print("SMOKE a rack and pinion's second pick must be a straight edge: ", tool.status_text() != "" and tool.picked_labels().size() == 2)
	tool.clear_picks()
	tool.try_pick(gear_a, 1)
	tool.try_pick(gear_b, 1)
	print("SMOKE ...a round face is refused as the rack side: ", tool.picked_labels() == ["Gear A"] and tool.status_text().contains("straight edge"))
	tool.try_pick(gear_b, 0, {"kind": "edge", "body_id": "body-b", "index": 0})
	print("SMOKE ...a straight edge is accepted: ", tool.picked_labels() == ["Gear A", "Gear B"] and (tool.build_create_payload()["references"][1]["subshape_ref"]["shape_type"] == "edge"))

	# --- labels and values
	print("SMOKE the sense control is Reverse (gear, rack and pinion) or Left-hand (screw): ", MatesTool.secondary_flip_label("gear") == "Reverse" and MatesTool.secondary_flip_label("rack_pinion") == "Reverse" and MatesTool.secondary_flip_label("screw") == "Left-hand" and MatesTool.secondary_flip_label("distance") == "Flip side")
	print("SMOKE value texts: ", MatesTool.coupler_value_text("gear", 0.5) == "1 : 2" and MatesTool.coupler_value_text("gear", 2.0) == "1 : 0.5" and MatesTool.coupler_value_text("rack_pinion", 62.832) == "62.832 mm per turn" and
		MatesTool.coupler_value_text("screw", 2) == "lead 2 mm" and MatesTool.coupler_value_text("distance", 5) == "" and MatesTool.coupler_value_text("gear", null) == "" and MatesTool.coupler_value_text("gear", 0.0) == "")
	print("SMOKE value prompts: ", MatesTool.value_prompt("gear").begins_with("Ratio") and MatesTool.value_prompt("rack_pinion").begins_with("Travel per turn") and MatesTool.value_prompt("screw").begins_with("Lead") and MatesTool.value_prompt("angle").begins_with("Angle"))
	print("SMOKE parse_value for couplers: above zero; empty is Auto for gear and rack and pinion (a new mate) and an error for a screw or an edit: ",
		MatesTool.parse_value("gear", "0.5")["value"] == 0.5 and not MatesTool.parse_value("gear", "0")["ok"] and not MatesTool.parse_value("gear", "-2")["ok"] and not MatesTool.parse_value("screw", "abc")["ok"] and
		MatesTool.parse_value("gear", "")["ok"] and MatesTool.parse_value("gear", "")["value"] == 0.0 and MatesTool.parse_value("rack_pinion", "")["ok"] and not MatesTool.parse_value("screw", "")["ok"] and not MatesTool.parse_value("gear", "", false)["ok"] and
		MatesTool.parse_value("distance", "5")["ok"] and not MatesTool.parse_value("distance", "-1")["ok"])

	# --- Reverse is relative to the default sense; the preview brings the ratio (a fake backend)
	var fake := FakePreviewTool.new()
	root.add_child(fake)
	await process_frame # (a node is inside the tree only after the first frame of a --script run)
	fake.backend_url = "http://example.invalid"
	fake.set_active(true)
	fake.mate_type = "gear"
	fake.answer = {"converged": true, "transform": {"translation": [0, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}, "members": [{"occurrence_id": "occ-b", "transform": {"translation": [0, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}}],
		"controls": ["secondary_flip"], "resolved": {"alignment": null, "secondary_flip": true}, "alternatives": [], "coupler_value": 0.5}
	fake.try_pick(gear_a, 1)
	fake.try_pick(gear_b, 1)
	await _frames(10)
	print("SMOKE the preview was asked for the coupler and its answer was read: ", fake.requests.any(func(r: Dictionary) -> bool: return str(r["path"]).contains("preview-mate-solve") and r["body"]["type"] == "gear") and fake.preview_coupler_value == 0.5 and fake.branch_controls == ["secondary_flip"])
	print("SMOKE no ghost is drawn for a coupler, and the status says what it does and where the ratio is from: ", not fake.preview_visible() and fake.status_text().contains("Turning one part will turn the other") and fake.status_text().contains("1 : 2"))
	print("SMOKE the default sense (True) is the base: Reverse reads off at first (the raw flag is on): ", fake.shown_secondary_flip() == 1 and not fake.flip_is_on() and fake.branch_text().contains("Reverse: off"))
	fake.toggle_secondary_flip()
	print("SMOKE pressing Reverse sends the other sense and reads on: ", fake.mate_secondary_flip == 0 and fake.flip_is_on() and fake.branch_text().contains("Reverse: on"))
	fake.toggle_secondary_flip()
	print("SMOKE pressing it again goes back to the default and reads off: ", fake.mate_secondary_flip == 1 and not fake.flip_is_on())
	fake.answer["resolved"] = {"secondary_flip": false}
	fake.answer["coupler_value"] = 3.0
	fake.mate_type = "screw"
	fake.try_pick(gear_a, 1)
	fake.try_pick(gear_b, 1)
	fake.mate_value = 2.0
	await _frames(10)
	print("SMOKE a screw reads Left-hand relative to its default (a new default replaces the old base): ", fake.branch_text().contains("Left-hand: off") and fake.preview_coupler_value == 3.0)

	for n in [gear_a, gear_b, plain, unknown]:
		n.free()
	tool.free()
	fake.queue_free()
	quit()
