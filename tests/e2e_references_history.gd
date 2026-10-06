extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): a REOPENED sketch that is not the last
## feature gets the part's corners and edges as the backend resolves them, which is the part as it stood at that sketch (everything built after it left out).
## A 60 x 40 x 20 box; a sketch on its top face with a circle (radius 5 at (30, 20) from the face's origin), extruded as a 10 mm boss (a stud: its bottom rim
## lies exactly in the top face's plane, so the FULL part has a circular edge there that the sketch, at its place in the history, has not got yet). Reopening
## the sketch: the references come from the glb fetched with the extrude left out, so the stud's rim is not offered, the box's corners are, and a corner
## made into a reference lands where the box's corner really is. With the stud's extrude hidden in the Build tree a NEW sketch on the top face is not
## refused either.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_references_history.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const PartReferences := preload("res://scripts/design_table/part_references.gd")

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

	# the stud: a circle on the top face, a 10 mm boss
	await ed.begin_sketch({"face": top_face(node)})
	var stud_sketch: String = ed.session.feature_id
	table.manager.activate("circle")
	await ed.session.tap({"uv": Vector2(10, 5)})
	await ed.session.tap({"uv": Vector2(15, 5)})
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["new_body"] = false
	ed.options["depth"] = 10.0
	await ed.apply_feature()
	await table.build.reload()
	var full_topology: Dictionary = node.get_meta("topology")
	var plane_origin_z := 20.0
	var full_refs: RefCounted = PartReferences.build(full_topology, {"origin": Vector3(0, 0, plane_origin_z), "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)})
	print("SMOKE the FULL part has a circular edge in the top face's plane (the stud's rim): ", full_refs.circles.size() == 1)

	# reopen the stud's sketch: NOT the last feature
	print("SMOKE the stud's sketch is not the last feature: ", table.build.index_of(stud_sketch) >= 0 and table.build.index_of(stud_sketch) < table.build.features.size() - 1)
	var reopened: bool = await ed.reopen_sketch(stud_sketch)
	await wait_for(func() -> bool: return ed.part_refs != null)
	var s = ed.session
	var refs = ed.part_refs
	print("SMOKE it reopens and gets references (it used to be refused): ", reopened and s.references_ok and refs != null)
	print("SMOKE they are the part as it stood at the sketch: the box's top corners are there and the stud's rim is NOT (it does not exist yet at that point): ", refs.vertices.size() >= 4 and refs.circles.is_empty())
	var corner: Dictionary = refs.nearest_vertex(Vector2(60, 40), 40.0)
	var made: Dictionary = await s.ensure_reference({"kind": "vertex", "body": corner["body"], "index": corner["index"]})
	var corner_point: Vector2 = s.points.get(made["id"], Vector2(-999, -999))
	print("SMOKE a corner taken from them is made a reference by the backend at the box's real corner (the index means the same corner to the backend as to the table): ", made["ok"] and corner_point.distance_to(corner["uv"]) < 0.05, " ", corner_point, " vs ", corner["uv"])
	ed.end_sketch()

	# something hidden: the stud's extrude hidden in the Build tree, a new sketch on the part
	var stud_extrude := ""
	for row in table.build.features:
		if row["type"] == "extrude" and row.get("sketch_feature_id", "") == stud_sketch:
			stud_extrude = str(row["id"])
	table.build.select(stud_extrude)
	table.build.toggle_hidden_selected()
	await wait_for(func() -> bool: return table.build.is_hidden(stud_extrude))
	await ed.refresh_view()
	var new_open: bool = await ed.begin_sketch({"fixed": "XY"})
	await wait_for(func() -> bool: return ed.part_refs != null)
	print("SMOKE with the stud hidden in the Build tree a new sketch still gets the part's references (it used to be refused): ", new_open and ed.session.references_ok and ed.part_refs != null)
	ed.end_sketch()
	quit()
