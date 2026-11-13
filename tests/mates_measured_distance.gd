extends SceneTree
## M4.1 (DIDSA-CAD docs/mates-storage-sessions-plan-2026-11-12.md), no backend (a fake answers the preview): a Distance with nothing typed for
## the current picks asks the backend to measure (`measure_value`, no value) and is previewed where the parts are; `mate_value` starts on the
## measured distance from that one answer (no second request) and is not counted as typed; the picks are measured once; a typed value wins
## and stays; new picks are measured again; an angle is never measured; an older backend (no `measured_value` in its answer) gets the old
## preview with the value shown. NOT covered: the real backend's measurement (DIDSA-CAD backend tests), the wheel's keyboard on a headset.
## Run: "$GODOT" --headless --path . --script res://tests/mates_measured_distance.gd  (see tests/README.md)


class FakeTool extends "res://scripts/mates_tool.gd":
	var bodies: Array = []
	var old_backend := false

	func _api_request(_method: int, path: String, body) -> Dictionary:
		if not path.contains("preview-mate-solve"):
			return {"ok": false, "code": 404, "json": {}, "error": "404"}
		bodies.append(body.duplicate(true))
		var pose := {"translation": [0, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}
		if body.get("measure_value", false) and not old_backend:
			return {"ok": true, "code": 200, "json": {"converged": true, "measured_value": 17.401, "transform": pose, "members": [{"occurrence_id": "occ-b", "transform": pose}]}, "error": ""}
		if not body.has("value"):
			return {"ok": true, "code": 200, "json": {"converged": false}, "error": ""}
		return {"ok": true, "code": 200, "json": {"converged": true, "transform": pose, "members": [{"occurrence_id": "occ-b", "transform": pose}]}, "error": ""}

	func last() -> Dictionary:
		return bodies.back()


func _part(occurrence: String, name: String) -> Node3D:
	var part := Node3D.new()
	part.name = name
	part.set_meta("owner_part_id", "root")
	part.set_meta("occurrence_id", occurrence)
	part.set_meta("face_ids", [0, 1])
	part.set_meta("body_ids", ["b", "b"])
	part.set_meta("topology", {"b": {"face_kinds": ["plane", "plane"], "edge_kinds": {}}})
	part.add_to_group("grabbable_parts")
	return part


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	var a := _part("occ-a", "A")
	var b := _part("occ-b", "B")
	root.add_child(a)
	root.add_child(b)
	var tool := FakeTool.new()
	root.add_child(tool)
	await process_frame
	tool.backend_url = "http://example.invalid"
	tool.set_active(true)
	tool.mate_type = "distance" # chosen first, as on the wheel; nothing typed yet

	tool.try_pick(a, 0)
	tool.try_pick(b, 1)
	await _frames(10)
	print("SMOKE a Distance with nothing typed asks to measure, with no value: ", tool.bodies.size() == 1 and tool.last().get("measure_value") == true and not tool.last().has("value"))
	print("SMOKE ...the value starts on the measured distance from that one answer: ", is_equal_approx(tool.mate_value, 17.401) and tool.measured_value == 17.401 and tool.bodies.size() == 1)
	print("SMOKE ...which is not counted as typed: ", not tool.value_typed)
	print("SMOKE ...the ghost is shown and the status says where it came from: ", tool.preview_visible() and tool.status_text().begins_with("Distance 17.401 mm: where the parts are now"))
	print("SMOKE ...and Create sends that distance: ", is_equal_approx(float(tool.build_create_payload().get("value", -1.0)), 17.401) and not tool.build_create_payload().has("measure_value"))

	tool.request_preview()
	await _frames(10)
	print("SMOKE the picks are measured once (the next preview sends the value): ", not tool.last().has("measure_value") and is_equal_approx(float(tool.last()["value"]), 17.401))

	tool.mate_value = 6.0
	await _frames(10)
	print("SMOKE a typed value wins and is the user's: ", tool.value_typed and float(tool.last()["value"]) == 6.0 and not tool.last().has("measure_value") and not tool.status_text().contains("where the parts are now"))

	tool.clear_picks()
	tool.try_pick(a, 1)
	tool.try_pick(b, 0)
	await _frames(10)
	print("SMOKE new picks are measured again (the typed value was for the last mate): ", tool.last().get("measure_value") == true and is_equal_approx(tool.mate_value, 17.401))

	tool.mate_type = "angle"
	await _frames(10)
	print("SMOKE an angle is never measured: ", not tool.last().has("measure_value") and tool.last().get("type") == "angle")

	# an older backend ignores measure_value: no measured_value in its answer -> the old preview, with the value shown
	tool.mate_type = "distance"
	tool.clear_picks()
	tool.old_backend = true
	var before := tool.bodies.size()
	tool.try_pick(a, 0)
	tool.try_pick(b, 1)
	await _frames(10)
	var sent := tool.bodies.slice(before)
	print("SMOKE an older backend: one measuring request, then the old preview with the value shown: ", sent.size() == 2 and sent[0].get("measure_value") == true and sent[1].has("value") and not sent[1].has("measure_value") and tool.preview_visible())
	quit(0)
