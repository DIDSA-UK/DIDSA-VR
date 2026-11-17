extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY; needs DIDSA_NO_LANDING=1 and tools/start_backend.sh). N1c (DIDSA-CAD plan
## `mates-storage-sessions-plan-2026-11-12.md`): VR shows and trusts the mate reference state the backend (N1b) now reports.
## A: a box mated on a plate (coincident: its bottom on the plate's top); a fillet on a box edge in the design table renumbers the box's faces. The backend
##    follows the face and says so (`followed_references`, once); VR reads that from the listing it takes after the edit: no drift warning, nothing for Enforce
##    to suppress, the mate stays on (not suppressed), the box is knocked away and comes back upright on the plate.
## B: a pin mated in one of a plate's two holes; that hole is deleted (its sketch circle). The backend holds the mate (it would bind the twin hole): VR shows it
##    held (a note, Confirm), Enforce says it left the mate out (X-Held-Mates) and moves nothing, Confirm takes the twin hole and the pin goes there.
## Run: DIDSA_NO_LANDING=1 "$GODOT" --headless --path . --script res://tests/e2e_mate_reference_follow.gd  (needs secrets.cfg and a running backend)

const SketchSession := preload("res://scripts/design_table/sketch_session.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const DirtyMates := preload("res://scripts/design_table/dirty_mates.gd")
const RefState := preload("res://scripts/mate_reference_state.gd")

var main
var table
var api
var ed


func req(method: int, path: String, body = null) -> Dictionary:
	return await api.request(method, path, body)


func face_with_normal(part: MeshInstance3D, want: Vector3) -> Dictionary:
	var best := {}
	var best_d := -INF
	var seen := {}
	var bodies: Array = part.get_meta("body_ids")
	for i in bodies.size():
		var key := "%s:%d" % [bodies[i], int(part.get_meta("face_ids")[i])]
		if seen.has(key):
			continue
		seen[key] = true
		var plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(part, str(bodies[i]), int(part.get_meta("face_ids")[i])))
		if plane.is_empty() or plane["n"].dot(want) < 0.99:
			continue
		var d: float = plane["origin"].dot(want)
		if d > best_d:
			best_d = d
			best = {"body_id": str(bodies[i]), "index": int(part.get_meta("face_ids")[i]), "plane": plane}
	return best


func rect_part(name: String, x: float, y: float, z: float) -> String:
	var part_id: String = (await req(HTTPClient.METHOD_POST, "/document/parts", {"name": name}))["json"]["id"]
	var s0 := SketchSession.new(Callable(api, "request"))
	s0.owner_part_id = part_id
	await s0.open_sketch({"fixed": "XY"})
	s0.set_tool("rectangle")
	await s0.tap({"uv": Vector2(0, 0)})
	await s0.tap({"uv": Vector2(x, y)})
	await PartFeatures.new(Callable(api, "request")).extrude(part_id, s0.feature_id, true, 0.0, z, [])
	return part_id


func show_assembly(asm_id: String) -> Dictionary:
	var glb: Dictionary = await api.fetch_bytes("/document/parts/%s/assembly-mesh.glb?quality=0.5" % asm_id)
	main._resolved_part_id = asm_id
	main._show_model(glb["bytes"], "", 0.001)
	var by_occ := {}
	for n in get_nodes_in_group("grabbable_parts"):
		by_occ[str(n.get_meta("occurrence_id"))] = n
	return by_occ


func box_on_plate() -> Dictionary:
	## A fresh document: a 40 x 40 x 10 plate (grounded) and a 10 x 10 x 10 box above it, the box's bottom face mated on the plate's top and solved.
	await req(HTTPClient.METHOD_POST, "/document/new")
	var asm_id: String = (await req(HTTPClient.METHOD_POST, "/document/parts", {"name": "Stack"}))["json"]["id"]
	var plate_id: String = await rect_part("Plate", 40, 40, 10)
	var box_id: String = await rect_part("Box", 10, 10, 10)
	await req(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences" % asm_id, {"id": "plate", "resolved_part_id": plate_id, "fixed": true,
		"transform": {"translation": [0, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}})
	await req(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences" % asm_id, {"id": "box", "resolved_part_id": box_id, "fixed": false,
		"transform": {"translation": [15, 15, 25], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}})
	var by_occ := await show_assembly(asm_id)
	var plate_top := face_with_normal(by_occ["plate"], Vector3(0, 0, 1))
	var box_bottom := face_with_normal(by_occ["box"], Vector3(0, 0, -1))
	var mate: Dictionary = await req(HTTPClient.METHOD_POST, "/document/parts/%s/mates" % asm_id, {"type": "coincident", "flipped": false, "allow_rotation": true,
		"references": [
			{"occurrence_id": "box", "subshape_ref": {"body_id": box_bottom["body_id"], "shape_type": "face", "index": box_bottom["index"]}},
			{"occurrence_id": "plate", "subshape_ref": {"body_id": plate_top["body_id"], "shape_type": "face", "index": plate_top["index"]}}]})
	var solved: Dictionary = await req(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences/box/solve" % asm_id)
	by_occ = await show_assembly(asm_id)
	await main._mates_tool.refresh_state(asm_id)
	await main._mates_tool.refresh_mates(asm_id)
	return {"asm": asm_id, "plate_part": plate_id, "box_part": box_id, "ok": mate["ok"] and solved["ok"], "plate": by_occ["plate"], "box": by_occ["box"], "mate_id": str(mate["json"]["id"]),
		"bottom_index": int(box_bottom["index"])}


func upright(node: Node3D) -> bool:
	## The box's own bottom (local -Z) still faces down.
	return (node.transform.basis * Vector3(0, 0, -1)).normalized().dot(Vector3(0, 0, -1)) > 0.999


func mate_by_id(asm_id: String, mate_id: String) -> Dictionary:
	var listed: Dictionary = await req(HTTPClient.METHOD_GET, "/document/parts/%s/mates" % asm_id)
	for m in listed["json"]:
		if str(m["id"]) == mate_id:
			return m
	return {}


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg — this test needs a running local backend, see tests/README.md")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var url := str(cfg.get_value("backend", "url"))
	var key := str(cfg.get_value("backend", "api_key"))
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0, 1.6, 0)
	main.get_node("XROrigin3D/RightController").position = Vector3(1.0, 1.5, 1.0)
	table = main.design_table
	table.configure_backend(url, key)
	main._mates_tool.configure_backend(url, key)
	api = table.api
	ed = table.editor
	var mates_tool = main._mates_tool

	# ===== A: a fillet renumbers the box's faces; the backend follows, VR trusts it
	var a := await box_on_plate()
	var asm_id: String = a["asm"]
	var box: MeshInstance3D = a["box"]
	var mate_id: String = a["mate_id"]
	print("SMOKE A: the box is mated on the plate by a real coincident mate, upright, 10 mm up: ", a["ok"] and absf(box.transform.origin.z - 10.0) < 0.05 and upright(box) and mates_tool.mates.size() == 1)
	var first: Dictionary = mates_tool.mates[0]
	print("SMOKE A: a fresh mate carries the new fields and nothing to report (held false, no lists): ", RefState.has_server_state(first) and not bool(first["held"]) and (first["followed_references"] as Array).is_empty() and (first["lost_references"] as Array).is_empty() and RefState.note_for(first)["kind"] == "")
	var index_before := int(first["references"][0]["subshape_ref"]["index"])
	table.open()
	table.seat(box)
	for i in 600:
		if ed.state == "pick_plane":
			break
		await process_frame
	var topo: Dictionary = table.table_copy.get_meta("topology")
	var body_id: String = topo.keys()[0]
	var verticals: Array = []
	for index in (topo[body_id]["edge_kinds"] as Dictionary):
		var pts: PackedVector3Array = topo[body_id]["edges"][index]
		if topo[body_id]["edge_kinds"][index] == "line" and absf(pts[0].x - pts[pts.size() - 1].x) < 0.01 and absf(pts[0].y - pts[pts.size() - 1].y) < 0.01:
			verticals.append(int(index))
	table.manager.activate("fillet")
	ed.edges = [{"kind": "edge", "body_id": body_id, "index": verticals[0], "key": TopologyPick.entity_key("edge", body_id, verticals[0])}]
	ed.options["radius"] = 2.0
	await ed.apply_feature()
	var after_edit: Dictionary = mates_tool.mates[0]
	var index_after := int(after_edit["references"][0]["subshape_ref"]["index"])
	print("SMOKE A: a fillet on a vertical edge of the box is applied (a real design-table edit): ", ed.feature_stack.size() == 1 and DirtyMates.is_dirty(box))
	print("SMOKE A: the premise: the edit renumbered the box's bottom face (the mate's index moved from %d to %d), so the old local check would have flagged it: " % [index_before, index_after], index_after != index_before)
	print("SMOKE A: the listing after the edit says the backend followed that reference (first listing: followed_references, a reason, held false, status ok): ", RefState.followed_paths(after_edit) == ["references[0].subshape_ref"] and RefState.reason(after_edit, "references[0].subshape_ref") != "" and not bool(after_edit["held"]) and str(after_edit["status"]) == "ok", " ", after_edit.get("followed_references"), " ", after_edit.get("reference_reasons"))
	print("SMOKE A: ...and the tablet row has an info line for it (note kind followed): ", RefState.note_for(after_edit)["kind"] == "followed")
	print("SMOKE A: there is no drift warning (the local check stood aside for the followed reference): ", table.mate_drift.is_empty() and not table.status().contains("different faces"), " ", table.status())
	var relisted: Dictionary = await mate_by_id(asm_id, mate_id)
	print("SMOKE A: the next listing is clean (followed is reported once) and the stored index is the new one: ", (relisted["followed_references"] as Array).is_empty() and int(relisted["references"][0]["subshape_ref"]["index"]) == index_after)
	await mates_tool.refresh_mates(asm_id)
	print("SMOKE A: ...yet VR still shows the news after that second listing (it kept the note until it is dismissed): ", RefState.is_followed(mates_tool.mates[0]))
	table.close()
	box.transform = Transform3D(box.transform.basis, box.transform.origin + Vector3(30, 20, 40))
	mates_tool.persist_pose(box)
	await create_timer(0.6).timeout
	await table.enforce_mates()
	var listed_after: Dictionary = await mate_by_id(asm_id, mate_id)
	print("SMOKE A: Enforce suppresses nothing: the mate is still on the backend, not suppressed, status ok, not held: ", not listed_after.is_empty() and not bool(listed_after["suppressed"]) and str(listed_after["status"]) == "ok" and not bool(listed_after["held"]))
	print("SMOKE A: ...it re-solved the real mate and cleared the flags (no 'turned off' message, no Remake offer): ", DirtyMates.dirty_nodes(self).is_empty() and not table.enforce_button.message().contains("turned off") and table.remake_plan.is_empty())
	print("SMOKE A: ...and the knocked box is back on the plate, 10 mm up, upright (not turned over onto its top): ", absf(box.transform.origin.z - 10.0) < 0.1 and upright(box), " z=", box.transform.origin.z)
	print("SMOKE A: Enforce left no mate out (an answer with no held_mate_ids): ", mates_tool.left_out_mate_ids.is_empty())

	# ===== B: a deleted hole with a twin: held; Enforce says it left the mate out; Confirm takes the twin
	await req(HTTPClient.METHOD_POST, "/document/new")
	var asm_b: String = (await req(HTTPClient.METHOD_POST, "/document/parts", {"name": "PinStack"}))["json"]["id"]
	var plate_b: String = (await req(HTTPClient.METHOD_POST, "/document/parts", {"name": "HolePlate"}))["json"]["id"]
	var sketch: Dictionary = (await req(HTTPClient.METHOD_POST, "/document/parts/%s/features/sketch" % plate_b, {"plane": "XY"}))["json"]
	var sketch_id: String = str(sketch["sketch_id"])
	var corner_ids: Array = []
	for xy in [[0, 0], [40, 0], [40, 20], [0, 20]]:
		corner_ids.append(str((await req(HTTPClient.METHOD_POST, "/sketch/sketches/%s/points" % sketch_id, {"x": xy[0], "y": xy[1]}))["json"]["id"]))
	for i in 4:
		await req(HTTPClient.METHOD_POST, "/sketch/sketches/%s/lines" % sketch_id, {"start_point_id": corner_ids[i], "end_point_id": corner_ids[(i + 1) % 4]})
	var circle_ids := {}
	for x in [10.0, 30.0]:
		var centre: Dictionary = await req(HTTPClient.METHOD_POST, "/sketch/sketches/%s/points" % sketch_id, {"x": x, "y": 10.0})
		var circle: Dictionary = await req(HTTPClient.METHOD_POST, "/sketch/sketches/%s/circles" % sketch_id, {"center_point_id": centre["json"]["id"], "radius": 3.0, "angle": 0.0})
		circle_ids[x] = str(circle["json"]["id"])
	await req(HTTPClient.METHOD_POST, "/document/parts/%s/extrude-features" % plate_b, {"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []})
	var pin_b: String = (await req(HTTPClient.METHOD_POST, "/document/parts", {"name": "Pin"}))["json"]["id"]
	var s1 := SketchSession.new(Callable(api, "request"))
	s1.owner_part_id = pin_b
	await s1.open_sketch({"fixed": "XY"})
	s1.set_tool("circle")
	await s1.tap({"uv": Vector2(0, 0)})
	await s1.tap({"uv": Vector2(3, 0)})
	await PartFeatures.new(Callable(api, "request")).extrude(pin_b, s1.feature_id, true, 0.0, 20.0, [])
	await req(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences" % asm_b, {"id": "plate", "resolved_part_id": plate_b, "fixed": true, "transform": {"translation": [0, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}})
	await req(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences" % asm_b, {"id": "pin", "resolved_part_id": pin_b, "fixed": false, "transform": {"translation": [31, 12, -5], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}})
	var by_b := await show_assembly(asm_b)
	var pin_face := {}
	var pin_node: MeshInstance3D = by_b["pin"]
	var pin_bodies: Array = pin_node.get_meta("body_ids")
	for i in pin_bodies.size():
		var fid := int(pin_node.get_meta("face_ids")[i])
		var kinds: Array = (pin_node.get_meta("topology") as Dictionary)[str(pin_bodies[i])].get("face_kinds", [])
		if fid < kinds.size() and str(kinds[fid]) == "cylinder":
			pin_face = {"body_id": str(pin_bodies[i]), "index": fid}
			break
	var hole_face := {}
	var plate_node: MeshInstance3D = by_b["plate"]
	var best_dx := INF
	var plate_bodies: Array = plate_node.get_meta("body_ids")
	var seen_faces := {}
	for i in plate_bodies.size():
		var fid2 := int(plate_node.get_meta("face_ids")[i])
		var kinds2: Array = (plate_node.get_meta("topology") as Dictionary)[str(plate_bodies[i])].get("face_kinds", [])
		if seen_faces.has(fid2) or fid2 >= kinds2.size() or str(kinds2[fid2]) != "cylinder":
			continue
		seen_faces[fid2] = true
		var tris := TopologyPick.face_triangles(plate_node, str(plate_bodies[i]), fid2)
		var cx := 0.0
		for v in tris:
			cx += v.x
		cx /= maxf(1.0, float(tris.size()))
		if absf(cx - 30.0) < best_dx:
			best_dx = absf(cx - 30.0)
			hole_face = {"body_id": str(plate_bodies[i]), "index": fid2}
	var mate_b: Dictionary = await req(HTTPClient.METHOD_POST, "/document/parts/%s/mates?solve=group&occurrence_id=pin" % asm_b, {"type": "concentric", "flipped": false, "allow_rotation": true,
		"references": [
			{"occurrence_id": "pin", "subshape_ref": {"body_id": pin_face["body_id"], "shape_type": "face", "index": pin_face["index"]}},
			{"occurrence_id": "plate", "subshape_ref": {"body_id": hole_face["body_id"], "shape_type": "face", "index": hole_face["index"]}}]})
	by_b = await show_assembly(asm_b)
	await mates_tool.refresh_state(asm_b)
	await mates_tool.refresh_mates(asm_b)
	var pin: MeshInstance3D = by_b["pin"]
	print("SMOKE B: a pin is mated concentric in the plate's x-30 hole and sits there: ", mate_b["ok"] and absf(pin.transform.origin.x - 30.0) < 0.05, " x=", pin.transform.origin.x)
	var del: Dictionary = await req(HTTPClient.METHOD_DELETE, "/sketch/sketches/%s/circles/%s" % [sketch_id, circle_ids[30.0]])
	await mates_tool.refresh_mates(asm_b)
	var held_mate: Dictionary = mates_tool.mates[0]
	var held_note := RefState.note_for(held_mate)
	print("SMOKE B: the x-30 hole is deleted (its twin at x 10 remains): the mate is HELD by the backend, reason given, nothing lost: ", del["ok"] and RefState.is_held(held_mate) and not RefState.is_lost(held_mate) and RefState.held_paths(held_mate) == ["references[1].subshape_ref"], " ", held_mate.get("reference_reasons"))
	print("SMOKE B: ...the tablet would say 'Check this mate' with a reason: ", held_note["kind"] == "held" and str(held_note["text"]).begins_with("Check this mate"), " ", held_note["text"])
	var pin_x_before := pin.transform.origin.x
	var outcome: Dictionary = await mates_tool.enforce_all(asm_b)
	print("SMOKE B: Enforce says it left the mate out (X-Held-Mates on its solve): ", outcome.get("held_mate_ids", []) == [str(mate_b["json"]["id"])] and mates_tool.status_text().contains("left out"), " ", mates_tool.status_text())
	print("SMOKE B: ...and moved the pin nowhere (it was not solved onto the twin hole): ", absf(pin.transform.origin.x - pin_x_before) < 0.05 and absf(pin.transform.origin.x - 10.0) > 1.0, " x=", pin.transform.origin.x)
	var confirmed: Dictionary = await mates_tool.confirm_references(asm_b, str(mate_b["json"]["id"]))
	var after_confirm: Dictionary = await mate_by_id(asm_b, str(mate_b["json"]["id"]))
	print("SMOKE B: Confirm (PATCH confirm_references) takes the bound face and lifts the hold: ", confirmed["ok"] and not bool(after_confirm["held"]) and (after_confirm["moved_references"] as Array).is_empty(), " ", confirmed.get("error", ""))
	by_b = await show_assembly(asm_b)
	await mates_tool.refresh_state(asm_b)
	await mates_tool.refresh_mates(asm_b)
	print("SMOKE B: ...and the mate is in the solve again: the pin is in the twin hole at x 10, the row has no note: ", absf(by_b["pin"].transform.origin.x - 10.0) < 0.1 and RefState.note_for(mates_tool.mates[0])["kind"] == "", " x=", by_b["pin"].transform.origin.x)
	quit()
