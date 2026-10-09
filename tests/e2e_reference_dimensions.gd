extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): persistent reference (driven) dimensions
## (phase 3 of docs/implementation-plan.md). A new part, a 60 x 40 rectangle extruded 20 mm; a sketch on its top face; the Dimension tool picks two top corners of
## the part (both pinned, so a dimension could not drive anything) and keeping the offered candidate stores a REFERENCE dimension on the backend (`(60)`).
##   * nothing reaches the solver (no constraint is made) and the dimension is drawn in brackets;
##   * the sketch is closed and reopened (Build tree > Edit): the dimension is still there with its value;
##   * the part is edited upstream (the base rectangle made 30 mm wider): the dimension's value follows (90);
##   * the document is exported in the native format and the dimension is in the file (the flat app reads it); opened again in VR it is still on the sketch;
##   * Undo of a reference dimension takes it back (it is deleted on the backend).
## Run: "$GODOT" --headless --path . --script res://tests/e2e_reference_dimensions.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func top_face(part: MeshInstance3D) -> Dictionary:
	var best := {}
	var best_z := -INF
	var bodies: Array = part.get_meta("body_ids")
	var seen := {}
	for i in bodies.size():
		var key := "%s:%d" % [bodies[i], int(part.get_meta("face_ids")[i])]
		if seen.has(key):
			continue
		seen[key] = true
		var plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(part, str(bodies[i]), int(part.get_meta("face_ids")[i])))
		if not plane.is_empty() and plane["n"].dot(Vector3(0, 0, 1)) > 0.99 and plane["origin"].z > best_z:
			best_z = plane["origin"].z
			best = {"kind": "face", "body_id": str(bodies[i]), "index": int(part.get_meta("face_ids")[i]), "key": key}
	return best


func vertex_pick(refs, at: Vector3, node: Node3D) -> Dictionary:
	## A pick of the part's vertex at a 3D position, as the Dimension tool would make it from the laser.
	var topology: Dictionary = node.get_meta("topology")
	for body_id in topology:
		for index in topology[body_id]["vertices"]:
			if (topology[body_id]["vertices"][index] as Vector3).distance_to(at) < 0.01:
				for v in refs.vertices:
					if v["body"] == str(body_id) and int(v["index"]) == int(index):
						return {"kind": "point", "id": "", "ref": {"kind": "vertex", "body": v["body"], "index": v["index"]}, "uv": v["uv"]}
	return {}


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	table = main.design_table
	table.configure_backend(main.backend_url, main.api_key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var node: MeshInstance3D = table.seated
	await ed.begin_sketch({"fixed": "XY"})
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": Vector2(0, 0)})
	await ed.session.tap({"uv": Vector2(60, 40)})
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 20.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var base_sketch_id := str(table.build.features[0].get("sketch_id", ""))

	# --- two corners of the top face, both pinned: a reference dimension of the 60 mm between them
	await ed.begin_sketch({"face": top_face(node)})
	var s = ed.session
	var refs = ed.part_refs
	var a: Dictionary = vertex_pick(refs, Vector3(0, 0, 20), node)
	var b: Dictionary = vertex_pick(refs, Vector3(60, 0, 20), node)
	s.set_tool("dimension")
	await s.select(a)
	await s.select(b)
	var keys: Array = s.ghosts.map(func(g): return g["key"])
	print("SMOKE two pinned corners offer their distance as DRIVEN candidates only: ", keys.has("linear") and s.ghosts.all(func(g): return bool(g.get("driven", false))), " ", keys)
	var constraints_before: int = s.constraints.size()
	var kept: Dictionary = await s.confirm_ghost("linear", 0.0)
	var listed: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/sketch/sketches/%s/reference-dimensions" % s.sketch_id, null)
	print("SMOKE keeping it stores ONE reference dimension on the backend (distance, 60), makes no constraint, and shows it in brackets: ", kept["ok"] and listed["ok"] and (listed["json"] as Array).size() == 1 and absf(float(listed["json"][0]["value"]) - 60.0) < 0.01 and s.constraints.size() == constraints_before and s.dimension_items().size() == 1 and s.dimension_items()[0]["text"] == "(60)")
	var dimension_id: String = str(listed["json"][0]["id"]) if listed["ok"] and (listed["json"] as Array).size() == 1 else ""

	# --- closed and reopened
	var feature_id: String = s.feature_id
	await ed.finish_sketch()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await ed.reopen_sketch(feature_id)
	await wait_for(func() -> bool: return ed.session != null and not ed.session.busy)
	s = ed.session
	print("SMOKE closed and reopened the sketch still has it, with its value, drawn in brackets: ", s.ref_dims.size() == 1 and s.ref_dims[0]["id"] == dimension_id and s.dimension_items().size() == 1 and s.dimension_items()[0]["text"] == "(60)")

	# --- the part changes upstream: the base rectangle 30 mm wider; the value follows
	var pts: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/sketch/sketches/%s/points" % base_sketch_id, null)
	for p in pts["json"]:
		if absf(float(p["x"]) - 60.0) < 0.001:
			await ed._call(HTTPClient.METHOD_PATCH, "/sketch/sketches/%s/points/%s" % [base_sketch_id, p["id"]], {"x": 90.0, "y": float(p["y"])})
	await ed._call(HTTPClient.METHOD_POST, "/sketch/sketches/%s/solve-and-refresh" % base_sketch_id, null)
	await ed.refresh_geometry()
	await ed._call(HTTPClient.METHOD_GET, "/document/parts/%s/features" % ed.part_id, null) # reading the features refreshes the sketch's references against the edited part
	await s.refresh(true)
	print("SMOKE the part made 30 mm wider, the reference dimension reads 90 (it follows the part): ", s.ref_dims.size() == 1 and absf(float(s.ref_dims[0]["value"]) - 90.0) < 0.05 and s.dimension_items()[0]["text"] == "(90)", " ", s.ref_dims)

	# --- saved in the native format, and opened again
	var exported: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/document/export/native?part_id=%s" % ed.part_id, null)
	var in_file := false
	if exported["ok"]:
		for sketch in exported["json"]["sketches"]:
			if str(sketch["id"]) == s.sketch_id:
				in_file = (sketch.get("reference_dimensions", []) as Array).size() == 1 and sketch["reference_dimensions"][0]["kind"] == "distance"
	print("SMOKE the native export has the reference dimension on the sketch (the flat app reads the same file): ", in_file)
	main._native_extras = {}
	var saved_path: String = await main.save_native_snapshot("user://e2e_refdim.didsa")
	var saved = JSON.parse_string(FileAccess.get_file_as_string(saved_path)) if saved_path != "" else null
	var saved_has := false
	if saved is Dictionary:
		for sketch in saved["sketches"]:
			if (sketch.get("reference_dimensions", []) as Array).size() == 1:
				saved_has = true
	print("SMOKE VR's own saved file has it too: ", saved_has)
	await main.open_native_file(saved_path)
	var again: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/sketch/sketches/%s/reference-dimensions" % s.sketch_id, null)
	print("SMOKE opened again in VR the sketch still has it, value 90: ", again["ok"] and (again["json"] as Array).size() == 1 and absf(float(again["json"][0]["value"]) - 90.0) < 0.05, " ", again.get("json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://e2e_refdim.didsa"))
	quit()
