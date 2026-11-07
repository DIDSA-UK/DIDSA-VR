extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): the SKETCH ORIGIN (DIDSA-CAD sketch origin, 3a/3d). A 60 x 40 x 20 box; a sketch opened on its top face asks the backend
## for "origin": "auto" and gets the face's bottom-left corner as its origin (as the flat app's New Sketch on Face does): the backend's sketch-feature row carries
## the stored origin and where it landed (`resolved_origin`), the session's plane starts there (a corner of the face, the one with the smallest y then x in the plane's
## own axes), and a point tapped at sheet (0, 0) is that corner in the part's frame. A sketch on a reference plane has no origin (its row says so), whatever the
## backend's version: an older backend, with no `origin` key at all, is the same as none.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_origin.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")


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
	for i in bodies.size():
		var plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(part, str(bodies[i]), int(part.get_meta("face_ids")[i])))
		if not plane.is_empty() and plane["n"].dot(Vector3(0, 0, 1)) > 0.99 and plane["origin"].z > best_z:
			best_z = plane["origin"].z
			best = {"body_id": str(bodies[i]), "index": int(part.get_meta("face_ids")[i])}
	return best


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	var main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	var table = main.design_table
	table.configure_backend(main.backend_url, main.api_key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor
	ed.preview_enabled = false
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var node: MeshInstance3D = table.seated

	await ed.begin_sketch({"fixed": "XY"})
	var base_feature: String = ed.session.feature_id
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": Vector2(0, 0)})
	await ed.session.tap({"uv": Vector2(60, 40)})
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 20.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var rows: Array = (await ed.features.list_features(ed.part_id))["features"]
	var base_row := {}
	for r in rows:
		if str(r.get("id", "")) == base_feature:
			base_row = r
	print("SMOKE a sketch on a reference plane has no origin (null or no key, either is the plane's own): ", not base_row.is_empty() and base_row.get("origin") == null and base_row.get("resolved_origin") == null and ed.session == null)

	var face := top_face(node)
	await ed.begin_sketch({"face": face})
	var plane: Dictionary = ed.session.plane
	var sketch_feature: String = ed.session.feature_id
	rows = (await ed.features.list_features(ed.part_id))["features"]
	var row := {}
	for r in rows:
		if str(r.get("id", "")) == sketch_feature:
			row = r
	var resolved: Variant = row.get("resolved_origin")
	print("SMOKE the backend's row for the face sketch stores an origin and says where it landed: ", row.get("origin") is Dictionary and resolved is Array and (resolved as Array).size() == 3, " ", resolved)
	var corners := [Vector3(0, 0, 20), Vector3(60, 0, 20), Vector3(60, 40, 20), Vector3(0, 40, 20)]
	var on_face := false
	var best := Vector3.INF
	var best_key := Vector2(INF, INF)
	for c in corners:
		var d: Vector3 = c - Vector3(0, 0, 20) # the axes only: the face plane's own origin cancels in the ordering
		var key := Vector2(d.dot(plane["y"]), d.dot(plane["x"]))
		if key.x < best_key.x - 0.000001 or (absf(key.x - best_key.x) <= 0.000001 and key.y < best_key.y):
			best_key = key
			best = c
		if (plane["origin"] as Vector3).is_equal_approx(c):
			on_face = true
	print("SMOKE the session's plane starts at a corner of the top face, the bottom-left one in the plane's own axes: ", on_face and (plane["origin"] as Vector3).is_equal_approx(best), " ", plane["origin"], " expected ", best)
	print("SMOKE ...the same place the backend resolved: ", resolved is Array and (plane["origin"] as Vector3).is_equal_approx(Vector3(float(resolved[0]), float(resolved[1]), float(resolved[2]))))
	table.manager.activate("point")
	await ed.session.tap({"uv": Vector2(0, 0)})
	var made_points: int = ed.session.points.size()
	print("SMOKE a point tapped at sheet (0, 0) is that corner in the part's frame: ", made_points >= 1 and SketchMath.from_sheet(Vector2.ZERO, ed.session.plane).is_equal_approx(best), " points ", made_points)
	quit()
