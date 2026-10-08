extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): the blind hole, end to end (phase 2 of
## docs/implementation-plan.md). A new part, a 60 x 40 rectangle extruded 20 mm, a circle (radius 6) drawn on the top face and cut 10 mm deep: a BLIND hole,
## open at the top, whose rim is 20 mm above the base. A sketch on the BASE plane (XY) then has no circular edge in its plane at all (the hole is a
## cylindrical wall seen end-on), so the hole is reached through its FACE: a snap near the hole's axis, a live centre.
##   * the references see no circle in the plane but one round face whose axis is at the hole's centre;
##   * a line started there makes ONE live centre (the backend lists it as a circle_centre reference) flagged as a reference helper: not drawn as a sketch point,
##     not offered for selection; asking for the same face again gives the same point (no duplicate);
##   * a driven distance from the axis to the sketch origin is offered and kept without anything sent to the backend;
##   * the part is edited upstream (the hole moved): the live centre follows;
##   * Undo of the line leaves no helper behind (the backend cleans it up); the sketch, closed and reopened, still knows what is a helper;
##   * a face that is not usable (the plate's top, parallel to the sketch) is refused with a reason and leaves nothing half made.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_references_face.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const SnapResolver := preload("res://scripts/design_table/snap_resolver.gd")

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

	# the blind hole: a circle on the top face (10, 5), radius 6, cut 10 mm down from the top
	await ed.begin_sketch({"face": top_face(node)})
	var hole_session = ed.session
	table.manager.activate("circle")
	await hole_session.tap({"uv": Vector2(10, 5)})
	await hole_session.tap({"uv": Vector2(16, 5)})
	var hole_plane: Dictionary = hole_session.plane
	var hole_xy: Vector3 = SketchMath.from_sheet(Vector2(10, 5), hole_plane) # where the hole is in the part's frame: the top face's own plane has its own origin and axes
	var hole_xy_moved: Vector3 = SketchMath.from_sheet(Vector2(15, 5), hole_plane)
	var hole_at := Vector2(hole_xy.x, hole_xy.y) # ...and so on the base plane (XY, the same frame)
	var hole_at_moved := Vector2(hole_xy_moved.x, hole_xy_moved.y)
	var hole_sketch_id: String = hole_session.sketch_id
	var hole_centre_id: String = str(hole_session.circles.values()[0]["c"])
	var hole_rim_id: String = str(hole_session.circles.values()[0]["p"])
	table.manager.activate("extrude")
	ed.options["boss"] = false
	ed.options["depth"] = 10.0
	await ed.apply_feature()

	# a sketch on the BASE plane: the hole's rim is 20 mm above it, so it is a round wall seen end-on
	await ed.begin_sketch({"fixed": "XY"})
	var s = ed.session
	var refs = ed.part_refs
	var wall_faces: Array = refs.faces.filter(func(f): return f["kind"] == "face_axis")
	print("SMOKE the base sketch sees no circular edge in its plane, and one round face whose axis is the hole's centre: ", s.references_ok and refs.circles.is_empty() and wall_faces.size() == 1 and (wall_faces[0]["c"] as Vector2).distance_to(hole_at) < 0.05, " ", wall_faces.size())
	var snap: Dictionary = SnapResolver.resolve(hole_at + Vector2(0.4, 0.3), s, 3.0, true, [], null, refs)
	print("SMOKE aiming near that point snaps to it as the hole's face axis: ", snap["kind"] == "face_axis" and (snap["uv"] as Vector2).distance_to(hole_at) < 0.05 and snap["ref"]["kind"] == "face_axis")

	s.set_tool("line")
	await s.tap({"uv": snap["uv"], "id": "", "ref": snap["ref"]})
	await s.tap({"uv": Vector2(10, 10), "id": ""})
	var axis_id: String = str(s.lines.values()[0]["a"]) if s.lines.size() == 1 else ""
	print("SMOKE the line is made and starts on a pinned point at the axis, which is a reference helper (the backend says so): ", s.lines.size() == 1 and axis_id != "" and s.point_locked.get(axis_id, false) and s.is_reference(axis_id) and s.points[axis_id].distance_to(hole_at) < 0.05)
	var listed: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/document/parts/%s/features/sketch/%s/external-references" % [ed.part_id, s.feature_id], null)
	var centre_rows: Array = (listed["json"] as Array).filter(func(row): return row.get("kind") == "circle_centre") if listed["ok"] else []
	print("SMOKE the backend lists it as a circle_centre reference, status ok, and there is exactly one: ", centre_rows.size() == 1 and centre_rows[0]["point_id"] == axis_id and centre_rows[0]["status"] == "ok")
	print("SMOKE no sketch point or shape of its own is offered for it (picking near it finds only the user's line, never the helper): ", s.nearest_entity(hole_at, 1.0, ["point"]).is_empty() and s.nearest_entity(hole_at + Vector2(0.2, 0.1), 1.0, ["line"])["kind"] == "line")
	var again: Dictionary = await s.ensure_reference(snap["ref"])
	var count_after: int = (await ed._call(HTTPClient.METHOD_GET, "/document/parts/%s/features/sketch/%s/external-references" % [ed.part_id, s.feature_id], null))["json"].size()
	print("SMOKE asking for the same face again gives the same point and makes no duplicate: ", again["ok"] and again["id"] == axis_id and count_after == (listed["json"] as Array).size(), " ", count_after)

	# a driven distance from the axis to the sketch origin
	s.set_tool("dimension")
	await s.select({"kind": "point", "id": "", "ref": snap["ref"], "uv": snap["uv"]})
	await s.select({"kind": "point", "id": s.origin_id})
	var keys: Array = s.ghosts.map(func(g): return g["key"])
	print("SMOKE the axis and the origin (both pinned) offer their distance as a driven candidate only: ", keys.has("linear") and s.ghosts.all(func(g): return bool(g.get("driven", false))), " ", keys)

	# the part is edited upstream: the hole moves 5 mm along x; the live centre follows
	# every point of the hole's circle (centre, radius point and the four cardinal points) moves five along x: the sketch's own origin stays
	var hole_pts: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/sketch/sketches/%s/points" % hole_sketch_id, null)
	for p in hole_pts["json"]:
		if absf(float(p["x"])) < 0.0001 and absf(float(p["y"])) < 0.0001:
			continue # the sketch's origin
		await ed._call(HTTPClient.METHOD_PATCH, "/sketch/sketches/%s/points/%s" % [hole_sketch_id, p["id"]], {"x": float(p["x"]) + 5.0, "y": float(p["y"])})
	await ed._call(HTTPClient.METHOD_POST, "/sketch/sketches/%s/solve-and-refresh" % hole_sketch_id, null)
	await ed.refresh_geometry()
	await ed._call(HTTPClient.METHOD_GET, "/document/parts/%s/features" % ed.part_id, null) # reading the features refreshes every sketch's references against the new part
	await s.refresh(true)
	await s.load_references()
	print("SMOKE after the hole is moved upstream the live centre follows it (five along the face's x axis) and is not flagged: ", s.points[axis_id].distance_to(hole_at_moved) < 0.05 and s.reference_status(axis_id) in ["ok", "followed", ""], " ", s.points.get(axis_id, "-"), " ", s.reference_status(axis_id))

	# Undo the line: the helper goes with it
	var undone: bool = await s.undo()
	await s.refresh(true)
	print("SMOKE Undo of the line takes it back and the helper with it: nothing orphaned is left in the sketch: ", undone and s.lines.is_empty() and not s.points.has(axis_id) and s.reference_ids.is_empty(), " ", s.reference_ids.keys())
	var made_again: Dictionary = await s.ensure_reference(snap["ref"])
	print("SMOKE ...and asking again after the undo makes the centre afresh (a live one, at the hole's new place): ", made_again["ok"] and s.is_reference(str(made_again["id"])) and s.points[str(made_again["id"])].distance_to(hole_at_moved) < 0.05)

	# closed and reopened
	s.set_tool("line")
	await s.tap({"uv": s.points[str(made_again["id"])], "id": str(made_again["id"])})
	await s.tap({"uv": Vector2(10, 10), "id": ""})
	var feature_id: String = s.feature_id
	await ed.finish_sketch()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var reopened: bool = await ed.reopen_sketch(feature_id)
	await wait_for(func() -> bool: return ed.session != null and not ed.session.busy)
	s = ed.session
	print("SMOKE reopened, the sketch still knows which of its things are helpers (the live centre is one, drawn quietly, not selectable): ", reopened and s.reference_ids.size() >= 1 and s.nearest_entity(hole_at_moved, 1.0, ["point"]).is_empty())

	# a face that cannot be used: the plate's top is parallel to the sketch plane
	var top: Dictionary = top_face(node)
	var points_before: int = s.points.size()
	var refused: Dictionary = await s.ensure_reference({"kind": "face_line", "body": top["body_id"], "index": top["index"]})
	print("SMOKE a face parallel to the sketch plane is refused with a reason and nothing is made: ", not refused["ok"] and str(refused["message"]).contains("square") and s.points.size() == points_before, " ", refused["message"])
	quit()
