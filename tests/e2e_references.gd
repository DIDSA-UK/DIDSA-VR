extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): the part's own corners and edges as
## references in a sketch. A new part, a 60 x 40 rectangle extruded 20 mm; a sketch on its top face; a line is started on the top-right corner
## (the part's vertex becomes ONE pinned point, no Convert / Fix / Construction steps), then the Dimension tool picks a part EDGE directly and a distance
## from that edge to the line's free end is typed in. Then the part is changed upstream (the base rectangle made 30 mm wider): the pinned corner follows it,
## the dimension still holds and the sketch is not flagged as having lost a reference.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_references.gd
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


func vertex_at(part: Node3D, p: Vector3) -> Dictionary:
	## The part's vertex at a 3D position, as the references list has it ({body, index, uv}).
	var topology: Dictionary = part.get_meta("topology")
	for body_id in topology:
		for index in topology[body_id]["vertices"]:
			if (topology[body_id]["vertices"][index] as Vector3).distance_to(p) < 0.01:
				return {"body": str(body_id), "index": int(index)}
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

	# --- a sketch on the top face may use the part's own corners and edges
	await ed.begin_sketch({"face": top_face(node)})
	var s = ed.session
	var refs = ed.part_refs
	print("SMOKE a new sketch on the top face of the real part may use the part's corners and edges: ", s.references_ok and refs != null and refs.vertices.size() >= 4 and refs.edges.size() >= 4)
	var corner := vertex_at(node, Vector3(60, 40, 20))
	var corner_uv := Vector2.ZERO
	for v in refs.vertices:
		if v["body"] == corner.get("body") and int(v["index"]) == int(corner.get("index", -1)):
			corner_uv = v["uv"]
	var snap: Dictionary = preload("res://scripts/design_table/snap_resolver.gd").resolve(corner_uv + Vector2(0.5, 0.5), s, 3.0, true, [], null, refs)
	print("SMOKE aiming near that corner snaps to it as a reference to the part's vertex: ", snap["kind"] == "vertex" and snap["ref"]["index"] == corner["index"])

	# --- a line started on the corner: ONE pinned point, nothing else to do
	s.set_tool("line")
	var points_before: int = s.points.size()
	await s.tap({"uv": snap["uv"], "id": "", "ref": snap["ref"]})
	var free_end: Vector2 = corner_uv + Vector2(-25, -10)
	await s.tap({"uv": free_end, "id": ""})
	var ref_id := ""
	for id in s.points:
		if s.point_locked.get(id, false) and not s.is_origin(id):
			ref_id = id
	print("SMOKE the line starts on a pinned point at the part's corner (is_locked on the backend), made by the one tap: ", s.lines.size() == 1 and ref_id != "" and s.points[ref_id].distance_to(corner_uv) < 0.01 and s.points.size() == points_before + 2)
	var line: Dictionary = s.lines.values()[0]
	var free_id: String = line["b"] if line["a"] == ref_id else line["a"]

	# --- dimension straight from a part edge
	var edge_mid := Vector2.ZERO
	var edge_pick: Dictionary = {}
	for e in refs.edges:
		var a: Vector2 = e["a"]
		var b: Vector2 = e["b"]
		if float(e["depth"]) < 0.01 and absf((a - b).length() - 60.0) < 0.1:
			edge_pick = refs.pick((a + b) * 0.5 + Vector2(0.2, 0.2), 2.0, ["line"])
			edge_mid = (a + b) * 0.5
			break
	print("SMOKE a 60 mm edge of the top face is picked as a line from the part: ", edge_pick.get("kind") == "line" and edge_pick["ref"]["kind"] == "edge")
	s.set_tool("dimension")
	var picked: Dictionary = await s.select(edge_pick)
	print("SMOKE picking it makes it a pinned construction line in the sketch in one go: ", picked["ok"] and s.selection.size() == 1 and s.lines.size() == 2 and bool(s.lines[s.selection[0]["id"]]["construction"]))
	await s.select({"kind": "point", "id": free_id})
	var keys: Array = s.ghosts.map(func(g): return g["key"])
	print("SMOKE with the line's free end also picked, a distance from the part's edge to it is offered: ", keys.has("point_line"), " ", keys)
	var confirmed: Dictionary = await s.confirm_ghost("point_line", 12.0)
	var distance_before: float = Geometry2D.get_closest_point_to_segment(s.points[free_id], refs.pick(edge_mid, 2.0, ["line"])["ref"]["a"], refs.pick(edge_mid, 2.0, ["line"])["ref"]["b"]).distance_to(s.points[free_id])
	print("SMOKE typing 12 is accepted and solved by the real backend, and the free end is 12 mm from the part's edge: ", confirmed["ok"] and s.converged and absf(distance_before - 12.0) < 0.05, " ", distance_before)
	var constraints_before: int = s.constraints.size()

	# --- the part changes upstream: the base rectangle 30 mm wider. The corner follows, the dimension holds.
	var base_sketch_id := str(table.build.features[0].get("sketch_id", ""))
	var pts: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/sketch/sketches/%s/points" % base_sketch_id, null)
	var moved := 0
	if pts["ok"]:
		for p in pts["json"]:
			if absf(float(p["x"]) - 60.0) < 0.001:
				var patched: Dictionary = await ed._call(HTTPClient.METHOD_PATCH, "/sketch/sketches/%s/points/%s" % [base_sketch_id, p["id"]], {"x": 90.0, "y": float(p["y"])})
				moved += 1 if patched["ok"] else 0
	await ed._call(HTTPClient.METHOD_POST, "/sketch/sketches/%s/solve-and-refresh" % base_sketch_id, null)
	await ed.refresh_geometry()
	await s.refresh(true)
	var features: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/document/parts/%s/features" % ed.part_id, null)
	var lost := false
	if features["ok"]:
		for f in features["json"]:
			if str(f["id"]) == s.feature_id:
				lost = bool(f.get("has_lost_reference", false))
	print("SMOKE the part is now 90 mm wide (two base corners moved): ", moved == 2 and absf(node.get_aabb().size.x - 90.0) < 0.5 or absf(node.get_aabb().size.y - 90.0) < 0.5 or absf(node.get_aabb().size.z - 90.0) < 0.5)
	var xs: Array = (node.get_meta("topology").values()[0]["vertices"] as Dictionary).values().map(func(v): return (v as Vector3).x)
	var new_width: float = xs.max() - xs.min()
	print("SMOKE the pinned corner followed the part's corner to its new place (it is now at x = 90): the sketch's plane is centred on the face, which also moved 15 mm, so the corner is 15 mm further out on the sheet: ", absf(new_width - 90.0) < 0.01 and absf(s.points[ref_id].distance_to(corner_uv) - 15.0) < 0.05, " ", s.points[ref_id].distance_to(corner_uv))
	print("SMOKE the sketch is not flagged as having lost a reference, the dimension is still there and the free end is still 12 mm from the (unmoved) edge: ", not lost and s.constraints.size() >= constraints_before and s.converged)
	quit()
