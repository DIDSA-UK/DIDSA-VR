extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): what happens to a sketch's reference to the
## part's corner when the part is edited UPSTREAM of the sketch in a way that changes its topology (DIDSA-CAD's reference-identity work, 2026-10-06), and
## how the design table shows and mends it. A 60 x 40 x 20 box; one of its vertical edges filleted; a sketch (on the XY plane, after the fillet) with a line
## from the box's corner at (60, 40). Then the fillet is moved (a PATCH of its edge) to another edge:
##   * to the vertical edge at (0, 40), nowhere near the corner: the reference FOLLOWS (the same corner, nothing flagged);
##   * to the vertical edge at (60, 40), the very corner: the corner is consumed, the backend FLAGS it lost (never rebinds it to another corner), reopening
##     the sketch shows the point as lost (status line, the point marked, Fix offered), the Build row carries the note, and re-picking a corner of the new
##     shape re-attaches the same point (the line stays on it) and clears the flag.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_references_lost.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")

var main
var table
var ed


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func vertical_edge_at(topology: Dictionary, x: float, y: float) -> Dictionary:
	## {body, index} of the straight edge of the box that stands at (x, y), in `topology` (a part's body id -> edges / vertices).
	for body_id in topology:
		var edges: Dictionary = topology[body_id]["edges"]
		for index in edges:
			var pts: PackedVector3Array = edges[index]
			if pts.size() >= 2 and absf(pts[0].x - x) < 0.01 and absf(pts[0].y - y) < 0.01 and absf(pts[pts.size() - 1].x - x) < 0.01 and absf(pts[pts.size() - 1].y - y) < 0.01 and absf(pts[0].z - pts[pts.size() - 1].z) > 1.0:
				return {"body": str(body_id), "index": int(index)}
	return {}


func sketch_row(feature_id: String) -> Dictionary:
	var listed: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/document/parts/%s/features" % ed.part_id, null)
	if listed["ok"]:
		for f in listed["json"]:
			if str(f["id"]) == feature_id:
				return f
	return {}


func move_fillet(fillet_id: String, edge: Dictionary) -> bool:
	var r: Dictionary = await ed._call(HTTPClient.METHOD_PATCH, "/document/parts/%s/fillet-features/%s" % [ed.part_id, fillet_id], {"edge_refs": [PartFeatures.edge_ref(str(edge["body"]), int(edge["index"]))]})
	await ed.refresh_geometry()
	return bool(r["ok"])


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
	ed = table.editor

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

	# a fillet on the vertical edge at (0, 0)
	var first_edge := vertical_edge_at(node.get_meta("topology"), 0, 0)
	var fillet: Dictionary = await ed.features.fillet(ed.part_id, [PartFeatures.edge_ref(str(first_edge["body"]), int(first_edge["index"]))], 3.0)
	print("SMOKE a fillet is made on the vertical edge at (0, 0): ", fillet["ok"])
	await ed.refresh_geometry()
	# (a fillet names its edges as they are on the body BEFORE it: the box as the extrude left it, so the edges to move it to are read from that)
	await table.build.reload()
	var rows: Array = table.build.features
	var pristine: Dictionary = await ed._fetch_reference_topology(BuildTree.rolled_back_ids(rows, table.build.index_of(str(rows[1]["id"]))))

	# a sketch after it, with a line from the corner at (60, 40)
	await ed.begin_sketch({"fixed": "XY"})
	var s = ed.session
	var refs = ed.part_refs
	var corner: Dictionary = refs.nearest_vertex(Vector2(60, 40), 1.0)
	print("SMOKE the sketch sees the corner at (60, 40): ", s.references_ok and not corner.is_empty())
	s.set_tool("line")
	await s.tap({"uv": corner["uv"], "id": "", "ref": {"kind": "vertex", "body": corner["body"], "index": corner["index"]}})
	await s.tap({"uv": Vector2(30, 20), "id": ""})
	var point_id := ""
	for id in s.points:
		if s.point_locked.get(id, false) and not s.is_origin(id) and s.points[id].distance_to(corner["uv"]) < 0.01:
			point_id = id
	var sketch_feature_id: String = s.feature_id
	print("SMOKE a line starts on a pinned point at that corner: ", s.lines.size() == 1 and point_id != "")
	ed.end_sketch()
	await table.build.reload()

	# --- the fillet moves to a far edge: the corner is followed, nothing is flagged
	var far_edge := vertical_edge_at(pristine, 0, 40)
	print("SMOKE the fillet moves to the vertical edge at (0, 40): ", await move_fillet(str(fillet["id"]), far_edge))
	var row: Dictionary = await sketch_row(sketch_feature_id)
	print("SMOKE the backend follows the corner: nothing lost, nothing flagged as moved: ", not row.is_empty() and not bool(row.get("has_lost_reference", true)) and (row.get("lost_reference_point_ids", ["x"]) as Array).is_empty() and (row.get("moved_reference_point_ids", ["x"]) as Array).is_empty(), " ", row.get("reference_reasons"))
	await table.build.reload()
	await ed.reopen_sketch(sketch_feature_id)
	s = ed.session
	print("SMOKE reopening it: the point is still pinned at (60, 40) and reported ok, no warning in the status line: ", s != null and s.reference_status(point_id) == "ok" and s.points.has(point_id) and s.points[point_id].distance_to(Vector2(60, 40)) < 0.5 and s.reference_warning() == "" and s.flagged_references().is_empty(), " ", s.points.get(point_id))
	ed.end_sketch()

	# --- the fillet moves onto the corner itself: flagged lost
	var corner_edge := vertical_edge_at(pristine, 60, 40)
	print("SMOKE the fillet moves to the vertical edge at (60, 40), the corner itself: ", await move_fillet(str(fillet["id"]), corner_edge))
	row = await sketch_row(sketch_feature_id)
	print("SMOKE the backend flags it: has_lost_reference, this point, the reason naming the fillet: ", bool(row.get("has_lost_reference", false)) and (row.get("lost_reference_point_ids", []) as Array) == [point_id] and str((row.get("reference_reasons", {}) as Dictionary).get(point_id, "")) == "consumed_by_%s" % str(fillet["id"]), " ", row.get("reference_reasons"))
	await table.build.reload()
	var build_row: Dictionary = table.build.row(sketch_feature_id)
	print("SMOKE the sketch's Build row says so, and the status line names the sketch: ", BuildTree.reference_note(build_row) == "lost reference" and table.ui._status_label.text.contains("lost reference"), " ", BuildTree.reference_note(build_row), " | ", table.ui._status_label.text)
	var reopened: bool = await ed.reopen_sketch(sketch_feature_id)
	s = ed.session
	print("SMOKE reopening shows the point as lost, with a warning (it is flagged, not moved onto another corner), and Select offers Fix: ", reopened and s.reference_status(point_id) == "lost" and s.reference_warning().contains("1 lost") and ed._sketch_hint().begins_with("Reference to the part: 1 lost") and table.ui._options.map(func(o): return o["id"]) == ["refs_fix"])
	print("SMOKE ...and the pinned point is where it was (the line still there, not dragged onto some other corner of the new shape): ", s.points.has(point_id) and s.lines.size() == 1)
	await ed.on_option("refs_fix")
	print("SMOKE Fix starts on that point: ", ed.repick_point == point_id and ed.view.repick_point == point_id)

	# --- re-pick: the nearest corner of the new shape to where it was
	var replacement: Dictionary = ed.part_refs.nearest_vertex(Vector2(60, 40), 8.0)
	print("SMOKE a corner of the new shape is within reach of the old spot (the fillet leaves one 3 mm along an edge): ", not replacement.is_empty() and replacement["uv"].distance_to(Vector2(60, 40)) > 0.5, " ", replacement.get("uv"))
	table.manager.deactivate()
	table.manager.activate("select")
	ed._hover_entity = {"kind": "point", "id": "", "ref": {"kind": "vertex", "body": replacement["body"], "index": replacement["index"]}, "uv": replacement["uv"]}
	await ed._do_repick()
	print("SMOKE re-attaching works against the real backend: the point is now at the replacement corner, nothing is flagged any more, the line is still on the point: ", s.points[point_id].distance_to(replacement["uv"]) < 0.05 and s.flagged_references().is_empty() and s.reference_status(point_id) == "ok" and s.lines.size() == 1 and ed.repick_point == "", " ", s.points[point_id], " vs ", replacement["uv"])
	row = await sketch_row(sketch_feature_id)
	print("SMOKE the backend agrees: the sketch has no lost reference now: ", not bool(row.get("has_lost_reference", true)), " ", row.get("lost_reference_point_ids"))
	ed.end_sketch()

	# --- a rounded corner is an arc: in a new sketch the fillet's arc on the bottom face (now at the corner (60, 40): radius 3 about (57, 37)) is picked
	await ed.begin_sketch({"fixed": "XY"})
	s = ed.session
	refs = ed.part_refs
	var arc_pick: Dictionary = refs.pick(Vector2(57.0 + 2.1213, 37.0 + 2.1213), 0.8, ["point", "line", "circle", "arc"])
	print("SMOKE the fillet's rounded corner is a circular edge that is only part of a circle: a pick on it is an ARC entity, radius 3 about (57, 37): ", refs.circles.size() == 1 and arc_pick.get("kind") == "arc" and (arc_pick["ref"]["c"] as Vector2).distance_to(Vector2(57, 37)) < 0.05 and absf(float(arc_pick["ref"]["r"]) - 3.0) < 0.05, " ", arc_pick.get("kind"))
	s.set_tool("dimension")
	var arc_made: Dictionary = await s.select(arc_pick)
	var arc_centre: String = s.arcs.values()[0]["c"] if s.arcs.size() == 1 else ""
	print("SMOKE picking it makes ONE construction arc with a pinned centre (convert-entities/edge on a partial circular edge), and offers radius 3 as a driven candidate: ", arc_made["ok"] and s.arcs.size() == 1 and arc_centre != "" and s.point_locked.get(arc_centre, false) and s.points[arc_centre].distance_to(Vector2(57, 37)) < 0.05 and s.ghosts.size() == 2 and bool(s.ghosts[0].get("driven", false)) and absf(float(s.ghosts[0]["value"]) - 3.0) < 0.05, " ", s.ghosts.map(func(g): return [g["key"], g["value"]]))
	ed.end_sketch()
	quit()
