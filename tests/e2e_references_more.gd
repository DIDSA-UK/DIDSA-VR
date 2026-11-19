extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): the more kinds of reference, for real.
## A new part, a 60 x 40 rectangle extruded 20 mm, a circle (radius 6) drawn on its top face and cut 10 mm deep: a hole. Then a sketch on the top face again:
##   * the hole's rim is a circular edge in the plane: snapping a line to its centre makes ONE construction circle on the rim (convert-entities/edge) with
##     a pinned centre (a "circle_centre" external reference, which the backend lists), the line starts on that centre, and a second use makes no second circle;
##   * Dimension on the rim picks that circle and offers radius 6 / diameter 12 as DRIVEN candidates; keeping one sends nothing to the backend;
##   * a snap to the middle of the top face's 60 mm edge makes a new point held at the middle by an at-midpoint constraint (solved by the real backend),
##     and a snap along the edge holds a point on it by a point-on-line constraint (solved: the point is exactly on the edge);
##   * a driven distance between the hole's centre and the edge's pinned line is offered only as a driven candidate.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_references_more.gd
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
	ed.preview_enabled = false

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

	# the hole: a circle on the top face, cut 10 mm down
	await ed.begin_sketch({"face": top_face(node)})
	var s = ed.session
	table.manager.activate("circle")
	# A sketch on a face now starts at the face's bottom-left corner (the flat app's default), not its centre: the hole goes 10, 5 off the face's centre (30, 20, 20).
	var face_centre: Vector2 = SketchMath.to_sheet(Vector3(30, 20, 20), s.plane)
	await s.tap({"uv": face_centre + Vector2(10, 5)}) # (off the sketch's own origin, which is a snap of its own)
	await s.tap({"uv": face_centre + Vector2(16, 5)})
	table.manager.activate("extrude")
	ed.options["boss"] = false
	ed.options["depth"] = 10.0
	await ed.apply_feature()

	# a new sketch on the top face, which now has the hole in it
	await ed.begin_sketch({"face": top_face(node)})
	s = ed.session
	var refs = ed.part_refs
	print("SMOKE the new sketch sees one circular edge in its plane (the hole's rim): ", s.references_ok and refs != null and refs.circles.size() == 1)
	var rim: Dictionary = refs.edges[refs.circles[0]]
	var centre_uv: Vector2 = rim["circle"]["c"]
	print("SMOKE ...radius 6: ", absf(float(rim["circle"]["r"]) - 6.0) < 0.01 and rim["circle"]["full"])

	# --- the centre: a line starts on it
	var snap: Dictionary = SnapResolver.resolve(centre_uv + Vector2(0.5, 0.5), s, 3.0, true, [], null, refs)
	print("SMOKE aiming near the hole's centre snaps to it as a circle centre: ", snap["kind"] == "centre" and (snap["uv"] as Vector2).distance_to(centre_uv) < 0.01)
	s.set_tool("line")
	await s.tap({"uv": snap["uv"], "id": "", "ref": snap["ref"]})
	await s.tap({"uv": centre_uv + Vector2(15, 5), "id": ""})
	print("SMOKE the line is made, the rim is a construction circle in the sketch (one), the line starts on a pinned point at the hole's centre: ", s.lines.size() == 1 and s.circles.size() == 1 and s.circles.values()[0]["construction"])
	var centre_id: String = s.circles.values()[0]["c"]
	print("SMOKE ...the centre is a pinned point at the hole's centre (the backend says locked): ", s.point_locked.get(centre_id, false) and s.points[centre_id].distance_to(centre_uv) < 0.01 and s.lines.values()[0]["a"] == centre_id)
	var listed: Dictionary = await ed._call(HTTPClient.METHOD_GET, "/document/parts/%s/features/sketch/%s/external-references" % [ed.part_id, s.feature_id], null)
	var centre_rows: Array = (listed["json"] as Array).filter(func(row): return row.get("kind") == "circle_centre") if listed["ok"] else []
	print("SMOKE the backend lists that point as a circle_centre reference of the hole's edge, status ok: ", centre_rows.size() == 1 and centre_rows[0]["point_id"] == centre_id and centre_rows[0]["status"] == "ok")
	table.manager.deactivate()
	table.manager.activate("circle")
	await s.tap({"uv": SnapResolver.resolve(centre_uv + Vector2(0.4, 0.2), s, 3.0, true, [], null, refs)["uv"], "id": centre_id})
	await s.tap({"uv": centre_uv + Vector2(-9, 0), "id": ""})
	print("SMOKE a second shape on the same centre makes no second circle on the rim: ", s.circles.size() == 2 and s.circles.values().filter(func(c): return c["construction"]).size() == 1)
	table.manager.deactivate()

	# --- Dimension on the rim: a driven radius
	s.set_tool("dimension")
	var rim_pick: Dictionary = refs.pick(centre_uv + Vector2(-6.0, 0.0), 1.5, ["circle"]) # the rim is the part's own (the sketch's helper circle on it is hidden): picked through the part, found again by the session
	var picked: Dictionary = await s.select(rim_pick if not rim_pick.is_empty() else {})
	var keys: Array = s.ghosts.map(func(g): return g["key"])
	print("SMOKE picking the hole's circle offers radius and diameter as driven candidates, 6 and 12: ", picked["ok"] and keys == ["diameter", "radius"] and s.ghosts.all(func(g): return bool(g.get("driven", false))) and absf(float(s.ghost("radius")["value"]) - 6.0) < 0.01, " ", keys)
	var constraints_before: int = s.constraints.size()
	var kept: Dictionary = await s.confirm_ghost("diameter", 0.0)
	print("SMOKE keeping the diameter shows (⌀12) and adds no constraint to the sketch: ", kept["ok"] and s.dimension_items().filter(func(i): return i.get("driven", false))[0]["text"] == "(⌀12)" and s.constraints.size() == constraints_before)

	# --- the middle of the top face's 60 mm edge, and along it
	var long_edge: Dictionary = {}
	for e in refs.edges:
		if float(e["depth"]) < 0.01 and e["kind"] == "line" and absf(((e["a"] as Vector2) - (e["b"] as Vector2)).length() - 60.0) < 0.1:
			long_edge = e
			break
	var mid_uv: Vector2 = ((long_edge["a"] as Vector2) + (long_edge["b"] as Vector2)) * 0.5
	var mid_snap: Dictionary = SnapResolver.resolve(mid_uv + Vector2(1.0, 1.0), s, 3.0, true, [], null, refs)
	print("SMOKE aiming near the middle of the 60 mm top edge snaps to its midpoint: ", mid_snap["kind"] == "edge_midpoint" and (mid_snap["uv"] as Vector2).distance_to(mid_uv) < 0.01)
	s.set_tool("point")
	# along the edge first (a point-on-line constraint is one the solver always accepts)
	var along_uv: Vector2 = (long_edge["a"] as Vector2).lerp(long_edge["b"], 0.2)
	var along_snap: Dictionary = SnapResolver.resolve(along_uv + Vector2(0.6, 0.6), s, 3.0, true, [], null, refs)
	await s.tap({"uv": along_snap["uv"], "id": "", "ref": along_snap["ref"]})
	var on_line := ""
	for cid in s.constraints:
		if str(s.constraints[cid].get("type", "")) == "point_on_line":
			on_line = str(s.constraints[cid]["point_id"])
	print("SMOKE a snap along the edge holds a new point ON it with a point-on-line constraint (solved, exactly where aimed): ", along_snap["kind"] == "edge_point" and on_line != "" and s.converged and s.points[on_line].distance_to(along_snap["uv"]) < 0.05, " ", s.points.get(on_line, "-"), " vs ", along_snap["uv"])
	# the middle, in a sketch that already holds a converted hole: the backend used to report a redundancy and distrust the at-midpoint (R-A); the converted
	# circle no longer carries a redundant radius constraint, so it is held. (The session still takes a refused one back out completely: see _point_on_reference.)
	var points_before: int = s.points.size()
	var constraints_now: int = s.constraints.size()
	await s.tap({"uv": mid_snap["uv"], "id": "", "ref": mid_snap["ref"]})
	var held_here: bool = s.constraints.size() == constraints_now + 1 and s.points.size() == points_before + 1
	print("SMOKE an at-midpoint in a sketch that already holds a converted hole is now held (solved, not taken back): ", held_here and s.converged, " held=", held_here)

	# --- the hole's centre and the edge's pinned line: nothing to drive, a driven distance
	s.set_tool("dimension")
	await s.select({"kind": "point", "id": centre_id})
	var edge_pick: Dictionary = refs.pick(mid_uv + Vector2(10, 0.5), 2.0, ["line"])
	await s.select(edge_pick)
	var pinned_keys: Array = s.ghosts.map(func(g): return g["key"])
	print("SMOKE the hole's centre and the part's edge (both pinned) offer their distance as a driven candidate only: ", pinned_keys.has("perpendicular") and s.ghosts.all(func(g): return bool(g.get("driven", false))), " ", pinned_keys)
	# a clean sketch on the same face: the middle is held by the real backend's at-midpoint
	await ed.finish_sketch()
	await ed.begin_sketch({"face": top_face(node)})
	s = ed.session
	refs = ed.part_refs
	long_edge = {}
	for e in refs.edges:
		if float(e["depth"]) < 0.01 and e["kind"] == "line" and absf(((e["a"] as Vector2) - (e["b"] as Vector2)).length() - 60.0) < 0.1:
			long_edge = e
			break
	mid_uv = ((long_edge["a"] as Vector2) + (long_edge["b"] as Vector2)) * 0.5
	mid_snap = SnapResolver.resolve(mid_uv + Vector2(1.0, 1.0), s, 3.0, true, [], null, refs)
	s.set_tool("point")
	await s.tap({"uv": mid_snap["uv"], "id": "", "ref": mid_snap["ref"]})
	var at_mid := ""
	for cid in s.constraints:
		if str(s.constraints[cid].get("type", "")) == "at_midpoint":
			at_mid = str(cid)
	var mid_point: String = str(s.constraints[at_mid]["point_id"]) if at_mid != "" else ""
	print("SMOKE in a sketch without the hole the real backend holds a new point at the edge's middle with an at-midpoint constraint (solved): ", at_mid != "" and s.converged and s.points.has(mid_point) and s.points[mid_point].distance_to(mid_uv) < 0.05, " ", s.points.get(mid_point, "-"), " vs ", mid_uv)
	s.set_tool("select")

	quit()
