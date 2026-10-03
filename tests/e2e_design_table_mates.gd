extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY). The stale-mates cycle against the real solver:
## two copies of a plate stacked by a real coincident mate (one grounded); one is edited on the design table (a boss on its top
## face); both instances are flagged and no longer steered by the mate; the second is knocked out of place; and "Enforce mates"
## re-solves for real. Whether the mate's faces survive the edit is the backend's business (DIDSA-CAD names them by index and has
## no persistent naming yet), so BOTH outcomes are accepted here — what is checked is that the cycle is consistent either way:
## re-solved and flags cleared with the part back on the stack, or flags kept with a reason on the button.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_design_table_mates.gd  (needs secrets.cfg and a running backend)

const SketchSession := preload("res://scripts/design_table/sketch_session.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const DirtyMates := preload("res://scripts/design_table/dirty_mates.gd")

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


func build_stack() -> Dictionary:
	## A fresh document: an assembly of two copies of a plate, stacked by a real coincident mate (the first grounded).
	await req(HTTPClient.METHOD_POST, "/document/new")
	var asm_id: String = (await req(HTTPClient.METHOD_POST, "/document/parts", {"name": "Stack"}))["json"]["id"]
	var plate_id: String = (await req(HTTPClient.METHOD_POST, "/document/parts", {"name": "Plate"}))["json"]["id"]
	var s0 := SketchSession.new(Callable(api, "request"))
	s0.owner_part_id = plate_id
	await s0.open_sketch({"fixed": "XY"})
	s0.set_tool("rectangle")
	await s0.tap({"uv": Vector2(0, 0)})
	await s0.tap({"uv": Vector2(40, 30)})
	await PartFeatures.new(Callable(api, "request")).extrude(plate_id, s0.feature_id, true, 0.0, 10.0, [])
	for occ in [["occ1", [0, 0, 0], true], ["occ2", [100, 0, 0], false]]:
		await req(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences" % asm_id, {"id": occ[0], "resolved_part_id": plate_id, "fixed": occ[2],
			"transform": {"translation": occ[1], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}})
	var glb: Dictionary = await api.fetch_bytes("/document/parts/%s/assembly-mesh.glb?quality=0.5" % asm_id)
	main._resolved_part_id = asm_id
	main._show_model(glb["bytes"], "", 0.001)
	var by_occ := {}
	for n in get_nodes_in_group("grabbable_parts"):
		by_occ[str(n.get_meta("occurrence_id"))] = n
	var top := face_with_normal(by_occ["occ1"], Vector3(0, 0, 1))
	var bottom := face_with_normal(by_occ["occ2"], Vector3(0, 0, -1))
	var mate: Dictionary = await req(HTTPClient.METHOD_POST, "/document/parts/%s/mates" % asm_id, {"type": "coincident", "flipped": false, "allow_rotation": true,
		"references": [
			{"occurrence_id": "occ1", "subshape_ref": {"body_id": top["body_id"], "shape_type": "face", "index": top["index"]}},
			{"occurrence_id": "occ2", "subshape_ref": {"body_id": bottom["body_id"], "shape_type": "face", "index": bottom["index"]}}]})
	var solved: Dictionary = await req(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences/occ2/solve" % asm_id)
	glb = await api.fetch_bytes("/document/parts/%s/assembly-mesh.glb?quality=0.5" % asm_id)
	main._show_model(glb["bytes"], "", 0.001)
	by_occ.clear()
	for n in get_nodes_in_group("grabbable_parts"):
		by_occ[str(n.get_meta("occurrence_id"))] = n
	await main._mates_tool.refresh_state(asm_id)
	return {"asm": asm_id, "plate": plate_id, "ok": mate["ok"] and solved["ok"], "one": by_occ["occ1"], "two": by_occ["occ2"], "top": top, "bottom": bottom}



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

	# ===== A: a boss on the mated top face renumbers it
	var a := await build_stack()
	var asm_id: String = a["asm"]
	var plate_id: String = a["plate"]
	var one: MeshInstance3D = a["one"]
	var two: MeshInstance3D = a["two"]
	var top: Dictionary = a["top"]
	var stacked_z: float = two.transform.origin.z
	print("SMOKE A: a real coincident mate stacks the second plate 10 mm on the first, and the mates tool sees it steering: ", a["ok"] and absf(stacked_z - 10.0) < 0.05 and main._mates_tool.is_mated(two) and main._mates_tool.is_constrained(two))
	table.open()
	table.seat(one)
	for i in 600:
		if ed.state == "pick_plane":
			break
		await process_frame
	var face := face_with_normal(table.table_copy, Vector3(0, 0, 1))
	await ed.begin_sketch({"face": {"body_id": face["body_id"], "index": face["index"]}})
	table.manager.activate("circle")
	var c := SketchMath.to_sheet(table.table_copy.get_aabb().get_center(), ed.session.plane)
	await ed.session.tap({"uv": c, "id": ""})
	await ed.session.tap({"uv": c + Vector2(5, 0), "id": ""})
	table.manager.activate("extrude")
	ed.options["depth"] = 5.0
	await ed.apply_feature()
	print("SMOKE A: a boss is added to the first plate's top; both instances are flagged and stop being steered by the mate: ", ed.feature_stack.size() == 1 and one.get_aabb().size.z > 14.9 and DirtyMates.is_dirty(one) and DirtyMates.is_dirty(two) and not main._mates_tool.is_constrained(two))
	print("SMOKE A: the edit is seen to have renumbered the faces the mate was made on: ", table.mate_drift.size() == 1)
	await ed.undo()
	print("SMOKE A: taking the edit back brings the real faces back, and the warning goes with them: ", ed.feature_stack.is_empty() and table.mate_drift.is_empty() and one.get_aabb().size.z < 10.1)
	table.manager.activate("circle")
	await ed.begin_sketch({"face": {"body_id": face["body_id"], "index": face["index"]}})
	c = SketchMath.to_sheet(table.table_copy.get_aabb().get_center(), ed.session.plane)
	await ed.session.tap({"uv": c, "id": ""})
	await ed.session.tap({"uv": c + Vector2(5, 0), "id": ""})
	table.manager.activate("extrude")
	await ed.apply_feature()
	print("SMOKE A: making the edit again brings the warning back: ", table.mate_drift.size() == 1)
	table.close()
	two.transform = Transform3D(two.transform.basis, two.transform.origin + Vector3(30, 20, 40))
	main._mates_tool.persist_pose(two)
	await create_timer(0.6).timeout
	print("SMOKE A: closing the table hands the plate back with the Enforce button over it: ", table.enforce_button.is_showing() and table.enforce_button.target == one)
	await table.enforce_mates()
	var mates_now: Dictionary = await req(HTTPClient.METHOD_GET, "/document/parts/%s/mates" % asm_id)
	print("SMOKE A: Enforce turns that mate OFF on the backend rather than solving it against the wrong faces: ", mates_now["ok"] and mates_now["json"].size() == 1 and bool(mates_now["json"][0]["suppressed"]))
	print("SMOKE A: ...says so on the button, clears the stale flags, and leaves the plate where it was (not dragged somewhere wrong): ", table.enforce_button.message().contains("turned off") and DirtyMates.dirty_nodes(self).is_empty() and absf(two.transform.origin.z - 50.0) < 0.05)

	var offered: bool = table.remake_plan.size() == 1 and table.enforce_button.button().text.begins_with("Remake")
	print("SMOKE A: the turned-off mate is OFFERED for remaking (its top face is still there, just renumbered): ", offered)
	var old_mate_id: String = str(mates_now["json"][0]["id"])
	await table.remake_mates()
	await create_timer(0.8).timeout
	var after_remake: Dictionary = await req(HTTPClient.METHOD_GET, "/document/parts/%s/mates" % asm_id)
	var fresh: Dictionary = after_remake["json"][0] if after_remake["ok"] and (after_remake["json"] as Array).size() == 1 else {}
	print("SMOKE A: remaking makes ONE new live mate on the backend (the old one deleted), same type, not suppressed: ", not fresh.is_empty() and str(fresh["id"]) != old_mate_id and not bool(fresh["suppressed"]) and str(fresh["type"]) == str(mates_now["json"][0]["type"]))
	print("SMOKE A: ...and the solver puts the knocked plate back on the stack (z back to 10): ", absf(two.transform.origin.z - 10.0) < 0.1, " ", two.transform.origin.z)

	# ===== B: an edit that leaves the mated faces alone (a fillet on a vertical edge)
	var b := await build_stack()
	var one_b: MeshInstance3D = b["one"]
	var two_b: MeshInstance3D = b["two"]
	table.open()
	table.seat(one_b)
	for i in 600:
		if ed.state == "pick_plane":
			break
		await process_frame
	var topo: Dictionary = table.table_copy.get_meta("topology")
	var body_id: String = topo.keys()[0]
	var vertical := -1
	for index in (topo[body_id]["edge_kinds"] as Dictionary):
		var pts: PackedVector3Array = topo[body_id]["edges"][index]
		if topo[body_id]["edge_kinds"][index] == "line" and absf(pts[0].x - pts[pts.size() - 1].x) < 0.01 and absf(pts[0].y - pts[pts.size() - 1].y) < 0.01:
			vertical = int(index)
			break
	table.manager.activate("fillet")
	ed.edges = [{"kind": "edge", "body_id": body_id, "index": vertical, "key": TopologyPick.entity_key("edge", body_id, vertical)}]
	ed.options["radius"] = 2.0
	await ed.apply_feature()
	var kept_faces: bool = table.mate_drift.is_empty()
	print("SMOKE B: a fillet on a vertical edge is applied: ", ed.feature_stack.size() == 1 and DirtyMates.is_dirty(two_b))
	print("SMOKE B: (the real backend ", "kept" if kept_faces else "renumbered", " the mated top and bottom faces)")
	table.close()
	two_b.transform = Transform3D(two_b.transform.basis, two_b.transform.origin + Vector3(30, 20, 40))
	main._mates_tool.persist_pose(two_b)
	await create_timer(0.6).timeout
	await table.enforce_mates()
	var mates_b: Dictionary = await req(HTTPClient.METHOD_GET, "/document/parts/%s/mates" % b["asm"])
	var suppressed_b: bool = mates_b["ok"] and mates_b["json"].size() == 1 and bool(mates_b["json"][0]["suppressed"])
	if kept_faces:
		print("SMOKE B: with the faces unchanged Enforce re-solves the real mate, clears the flags, and the knocked plate returns to the stack: ", not suppressed_b and DirtyMates.dirty_nodes(self).is_empty() and absf(two_b.transform.origin.z - 10.0) < 0.1, " z=", two_b.transform.origin.z)
	else:
		print("SMOKE B: with the faces renumbered the mate is turned off, as in A: ", suppressed_b and DirtyMates.dirty_nodes(self).is_empty())
	quit()
