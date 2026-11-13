extends SceneTree
## M4 (DIDSA-CAD docs/mates-storage-sessions-plan-2026-11-12.md, "A better first guess"), no backend (a fake answers the preview): until the
## user picks a type, the first preview of a new pair of picks asks the backend for the type (`type: "auto"`) and the tool starts on the
## suggestion (one request: the answer is the preview of that type); no suggestion (or an older backend that refuses "auto") previews the
## type shown, as before; a type set by hand stays (no more asking) until the tool is switched on again; Peg in hole is a type (tablet label,
## wheel label and hint); the laser's hit point is sent as `pick_points`, local to the picked occurrence in mm.
## NOT covered: the real backend's rule (DIDSA-CAD backend tests), the tablet's buttons on a headset, how the suggestion reads.
## Run: "$GODOT" --headless --path . --script res://tests/mates_suggested_type.gd  (see tests/README.md)

const MatesTool := preload("res://scripts/mates_tool.gd")
const TabletPages := preload("res://scripts/ui/tablet_pages.gd")
const WheelFlows := preload("res://scripts/ui/wheel_flows.gd")


class FakeTool extends "res://scripts/mates_tool.gd":
	var bodies: Array = []
	var answers := {} ## request type -> answer (Dictionary), or "refuse"

	func _api_request(_method: int, path: String, body) -> Dictionary:
		if path.contains("preview-mate-solve"):
			bodies.append(body.duplicate(true))
			var answer = answers.get(str(body.get("type", "")), {"converged": false})
			if answer is String and answer == "refuse":
				return {"ok": false, "code": 422, "json": {"detail": [{"type": "literal_error"}]}, "error": "422"}
			return {"ok": true, "code": 200, "json": answer, "error": ""}
		return {"ok": false, "code": 404, "json": {}, "error": "404"}

	func types_sent() -> Array:
		return bodies.map(func(b) -> String: return str(b.get("type", "")))


func _part(owner: String, occurrence: String, name: String) -> Node3D:
	var part := Node3D.new()
	part.name = name
	part.set_meta("owner_part_id", owner)
	part.set_meta("occurrence_id", occurrence)
	part.set_meta("face_ids", [0, 1])
	part.set_meta("body_ids", ["b", "b"])
	part.set_meta("topology", {"b": {"face_kinds": ["plane", "plane"], "edge_kinds": {}}})
	part.add_to_group("grabbable_parts")
	return part


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _pose(x := 0.0) -> Dictionary:
	return {"translation": [x, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}


func _initialize() -> void:
	# an assembly root that carries mm -> m (as main.gd's does), the parts posed in mm under it
	var assembly_root := Node3D.new()
	assembly_root.scale = Vector3.ONE * 0.001
	root.add_child(assembly_root)
	var a := _part("root", "occ-a", "A")
	var b := _part("root", "occ-b", "B")
	b.transform = Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(100.0, 0.0, 0.0)) # turned 90 degrees about y, 100 mm along x
	assembly_root.add_child(a)
	assembly_root.add_child(b)
	var tool := FakeTool.new()
	root.add_child(tool)
	await process_frame
	tool.backend_url = "http://example.invalid"

	# --- the types
	var types: Array = MatesTool.MATE_TYPES
	print("SMOKE Peg in hole is a mate type, right after Concentric: ", types.slice(0, 3) == ["coincident", "concentric", "peg_in_hole"] and MatesTool.PEG_IN_HOLE_TYPE == "peg_in_hole")
	print("SMOKE ...with a tablet label in the same place, and a wheel label and hint: ", TabletPages.MATE_TYPE_LABELS.size() == types.size() and TabletPages.MATE_TYPE_LABELS[2] == "Peg in hole" and WheelFlows.MATE_TYPE_LABELS.get("peg_in_hole") == "Peg in hole" and WheelFlows.MATE_TYPE_HINTS.has("peg_in_hole"))
	print("SMOKE ...and its list name: ", MatesTool.type_label("peg_in_hole") == "Peg in hole")

	# --- a fresh tool asks for the type and starts on the suggestion
	tool.set_active(true)
	print("SMOKE switching the tool on leaves the type to the picks: ", not tool.type_chosen and tool.mate_type == "coincident")
	tool.answers = {"auto": {"converged": true, "suggested_type": "peg_in_hole", "transform": _pose(), "members": [{"occurrence_id": "occ-b", "transform": _pose(5.0)}]}}
	tool.try_pick(a, 0, {}, a.global_transform * Vector3(10.0, 2.0, 3.0))
	tool.try_pick(b, 1, {}, b.global_transform * Vector3(-4.0, 5.0, 6.0))
	await _frames(10)
	print("SMOKE the first preview of the picks sends type auto (and no value): ", tool.types_sent() == ["auto"] and not tool.bodies[0].has("value"))
	print("SMOKE the tool starts on the suggestion, from that one answer (no second request): ", tool.mate_type == "peg_in_hole" and tool.suggested_type == "peg_in_hole" and tool.bodies.size() == 1)
	print("SMOKE ...the suggestion is not the user's choice: ", not tool.type_chosen)
	print("SMOKE ...its ghost is shown and the status says it was suggested: ", tool.preview_visible() and tool.status_text().begins_with("Peg in hole, suggested from the picks"))
	print("SMOKE Create sends the suggested type: ", tool.build_create_payload()["type"] == "peg_in_hole")

	# --- pick points: where the laser landed, local to each occurrence, in mm
	var points: Array = tool.bodies[0].get("pick_points", [])
	var close := func(p, q: Array) -> bool: return p is Array and p.size() == 3 and absf(p[0] - q[0]) < 1e-3 and absf(p[1] - q[1]) < 1e-3 and absf(p[2] - q[2]) < 1e-3
	print("SMOKE the preview sends pick_points, one per pick, local mm (the turned part's too): ", points.size() == 2 and close.call(points[0], [10.0, 2.0, 3.0]) and close.call(points[1], [-4.0, 5.0, 6.0]))
	print("SMOKE ...and no view direction (that is the flat app's): ", not tool.bodies[0].has("view_direction"))
	print("SMOKE ...Create sends them too: ", tool.build_create_payload().get("pick_points", []).size() == 2)
	print("SMOKE a pick with no hit point sends no point: ", MatesTool.local_pick_point(a, Vector3.INF) == [] and MatesTool.local_pick_point(null, Vector3.ZERO) == [])

	# --- the user changes the type: it stays
	tool.answers = {"distance": {"converged": true, "transform": _pose(), "members": [{"occurrence_id": "occ-b", "transform": _pose(7.0)}]}}
	tool.mate_value = 4.0
	tool.mate_type = "distance"
	await _frames(10)
	print("SMOKE the user can change it: the next preview is their type: ", tool.type_chosen and tool.types_sent().back() == "distance" and tool.mate_type == "distance")
	print("SMOKE ...and the suggested note goes: ", not tool.status_text().contains("suggested"))
	tool.clear_picks()
	tool.mate_value = 4.0 # a distance typed for the new picks (M4.1 would otherwise measure them first: tests/mates_measured_distance.gd)
	var before := tool.bodies.size()
	tool.try_pick(a, 1)
	tool.try_pick(b, 0)
	await _frames(10)
	print("SMOKE a type set by hand stays for the next picks (no asking): ", tool.bodies.size() == before + 1 and tool.types_sent().back() == "distance" and tool.mate_type == "distance")
	print("SMOKE picks without hit points send no pick_points: ", not tool.bodies.back().has("pick_points"))

	# --- switched on again: asks again; no suggestion keeps the type and previews it
	tool.set_active(false)
	tool.set_active(true)
	tool.mate_value = 0.0
	tool.answers = {"auto": {"converged": false, "transform": null, "suggested_type": null}, "distance": {"converged": false}}
	before = tool.bodies.size()
	tool.try_pick(a, 0)
	tool.try_pick(b, 0)
	await _frames(10)
	print("SMOKE switched on again it asks again; with no suggestion it previews the type shown: ", tool.types_sent().slice(before) == ["auto", "distance"] and tool.mate_type == "distance" and tool.suggested_type == "")
	tool.request_preview()
	await _frames(10)
	print("SMOKE ...and does not ask again for the same picks: ", tool.types_sent().back() == "distance" and tool.types_sent().count("auto") == 2)

	# --- an older backend refuses "auto": the tool previews as before
	tool.set_active(false)
	tool.set_active(true)
	tool.mate_value = 4.0 # typed (as above)
	tool.answers = {"auto": "refuse", "distance": {"converged": true, "transform": _pose(), "members": [{"occurrence_id": "occ-b", "transform": _pose(9.0)}]}}
	before = tool.bodies.size()
	tool.try_pick(a, 0)
	tool.try_pick(b, 1)
	await _frames(10)
	print("SMOKE an older backend that refuses auto still gets the old preview: ", tool.types_sent().slice(before) == ["auto", "distance"] and tool.preview_visible() and tool.mate_type == "distance")

	# --- picks_key
	print("SMOKE the pair is identified by its references in order: ", MatesTool.picks_key([{"occurrence_id": "x", "subshape_ref": {"index": 1}}]) != MatesTool.picks_key([{"occurrence_id": "x", "subshape_ref": {"index": 2}}]))
	quit(0)
