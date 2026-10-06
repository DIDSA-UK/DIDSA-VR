extends SceneTree
## The part's own vertices and edges as references in a sketch (scripts/design_table/part_references.gd, and the snap / pick / session plumbing around it),
## with the FAKE backend (tests/helpers/fake_cad.gd) and the real-winding box-and-cylinder fixture (tests/fixtures/topology_box_cylinder.glb).
## Pure part: the box's corners and edges projected onto a plane, the nearest-to-the-plane one kept where several land on the same spot, look-ups.
## Scene part: aiming near a corner of the part snaps to it; a line started on it makes ONE pinned point (convert-entities/vertex) and a second
## use of the same corner makes none; the Dimension tool picks a part EDGE directly (two pinned points and a construction line, no convert / fix /
## construction steps), offers nothing for a thing that is already pinned, and a distance from the part's edge to a sketch point reaches the
## backend as a constraint on the pinned line; a sketch that was not made on the whole part's geometry gets no references.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_references.gd  (see tests/README.md)

const Fake := preload("res://tests/helpers/fake_cad.gd")
const PartReferences := preload("res://scripts/design_table/part_references.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const SnapResolver := preload("res://scripts/design_table/snap_resolver.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var ed
var r: XRController3D
var fake


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func aim(from: Vector3, to: Vector3) -> void:
	var dir := (to - from).normalized()
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	r.global_transform = Transform3D(Basis.looking_at(dir, up), from)
	await frames(3)


func pull() -> void:
	r.button_pressed.emit("trigger_click")
	await frames(2)
	r.button_released.emit("trigger_click")
	await frames(2)


func settle(pred: Callable, n := 200) -> bool:
	for i in n:
		if pred.call():
			return true
		await process_frame
	return false


func calls_to(fragment: String) -> Array:
	return fake.calls.filter(func(c): return c[0].contains(fragment))


func aim_uv(uv: Vector2) -> void:
	var copy: Node3D = table.table_copy
	var plane: Dictionary = ed.session.plane
	var world: Vector3 = copy.global_transform * SketchMath.from_sheet(uv, plane)
	var normal: Vector3 = (copy.global_transform.basis * (plane["n"] as Vector3)).normalized()
	await aim(world + normal * 0.45 + Vector3(0, 0, 0.12), world)


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	r = origin.get_node("RightController")
	origin.get_node("LeftController").position = Vector3(-0.5, 1.0, -0.2)
	r.position = Vector3(1.0, 1.5, 1.0)
	table = main.design_table
	table.surface.settle_seconds = 0.0
	ed = table.editor
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(bytes, "", 0.001)
	await frames(3)
	var box: MeshInstance3D = null
	for p in get_nodes_in_group("grabbable_parts"):
		if p.get_meta("occurrence_id", "") == "occ_box":
			box = p
	var owner_id := str(box.get_meta("owner_part_id", ""))
	if owner_id == "":
		owner_id = "ASM"
		for p in get_nodes_in_group("grabbable_parts"):
			p.set_meta("owner_part_id", owner_id)

	# --- pure: the box seen along the XY plane at the bottom (z = 0) and along the plane at the top (z = 100)
	var topology: Dictionary = box.get_meta("topology")
	var bottom := {"origin": Vector3.ZERO, "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}
	var refs: RefCounted = PartReferences.build(topology, bottom)
	print("SMOKE the box's 8 corners and 12 edges seen along the plane are 4 corners and 4 edges (the other corners and edges lie exactly under them, the verticals are points): ", refs.vertices.size() == 4 and refs.edges.size() == 4)
	var at_corner: Dictionary = refs.nearest_vertex(Vector2(98, 1.5), 5.0)
	print("SMOKE of two corners that land on the same spot the one ON the plane is kept (vertex 5, at (100, 0, 0), not vertex 4 at height 100): ", int(at_corner["index"]) == 5 and absf(float(at_corner["depth"])) < 0.001 and at_corner["body"] == "body_box")
	var top := {"origin": Vector3(0, 0, 100), "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}
	print("SMOKE ...and on the plane at the top it is vertex 4: ", int(PartReferences.build(topology, top).nearest_vertex(Vector2(98, 1.5), 5.0)["index"]) == 4)
	print("SMOKE nothing is found beyond the radius: ", refs.nearest_vertex(Vector2(50, 50), 5.0).is_empty() and refs.nearest_edge(Vector2(50, 50), 5.0).is_empty())
	var edge: Dictionary = refs.nearest_edge(Vector2(50, 2), 5.0)
	print("SMOKE an aim near the bottom edge finds that edge with its two end corners (0,0) and (100,0): ", not edge.is_empty() and edge["kind"] == "line" and ((edge["a"] as Vector2).is_equal_approx(Vector2.ZERO) or (edge["b"] as Vector2).is_equal_approx(Vector2.ZERO)) and int(edge["a_vertex"]) >= 0 and int(edge["b_vertex"]) >= 0 and int(edge["a_vertex"]) != int(edge["b_vertex"]))
	var picked: Dictionary = refs.pick(Vector2(98, 1.5), 5.0, ["point", "line"])
	print("SMOKE a pick at a corner gives a POINT entity (a corner beats the edge it is on), with no id yet and a reference to the vertex: ", picked["kind"] == "point" and picked["id"] == "" and picked["ref"] == {"kind": "vertex", "body": "body_box", "index": 5})
	var picked_edge: Dictionary = refs.pick(Vector2(50, 2), 5.0, ["point", "line"])
	print("SMOKE a pick on an edge gives a LINE entity with a reference to the edge and its end vertices: ", picked_edge["kind"] == "line" and picked_edge["ref"]["kind"] == "edge" and picked_edge["ref"].has("a_vertex"))
	print("SMOKE only the kinds asked for are picked (a line-only tool does not take a corner): ", refs.pick(Vector2(98, 1.5), 5.0, ["line"])["kind"] == "line")

	# --- the scene: a sketch on the XY plane of the box
	fake = Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.mesh_bytes = bytes
	fake.origin = true
	fake.vertex_positions = {"body_box:5": Vector2(100, 0), "body_box:1": Vector2(0, 0)}
	ed.api = fake
	table.open()
	table.seat(box)
	await settle(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	await frames(3)
	print("SMOKE a new sketch on the whole part may use the part's own corners and edges, and shows them (quietly) under the sketch: ", ed.session.references_ok and ed.part_refs != null and ed.view._refs_node.mesh != null)

	table.manager.activate("line")
	await aim_uv(Vector2(98.0, 1.5))
	print("SMOKE aiming a drawing tool near a corner of the part snaps the cursor onto it, as a reference to that vertex (and lights it): ", ed._snap["kind"] == "vertex" and ed._snap.get("ref", {}) == {"kind": "vertex", "body": "body_box", "index": 5} and (ed._snap["uv"] as Vector2).is_equal_approx(Vector2(100, 0)) and ed.view._refs_hover.mesh != null)
	await pull()
	await aim_uv(Vector2(60, 70))
	await pull()
	var drew: bool = await settle(func() -> bool: return not calls_to("/lines").is_empty() and not ed.session.busy)
	var convert: Array = calls_to("convert-entities/vertex")
	print("SMOKE a line started on the corner makes ONE pinned point for it (no convert / fix / construction steps) and starts the line there: ", drew and convert.size() == 1 and convert[0][1] == {"body_id": "body_box", "vertex_index": 5} and calls_to("/lines")[0][1]["start_point_id"] == fake.ref_points["body_box:5"])
	print("SMOKE ...the point is pinned (the backend says locked), so the sketch cannot drag it away from the part: ", ed.session.point_locked.get(fake.ref_points["body_box:5"], false))
	table.manager.deactivate()
	table.manager.activate("circle")
	await aim_uv(Vector2(99.0, 0.5))
	await pull()
	await aim_uv(Vector2(70, -30))
	await pull()
	await settle(func() -> bool: return not calls_to("/circles").is_empty() and not ed.session.busy)
	print("SMOKE using the same corner again reuses its point: no second convert, and the circle is centred on it: ", calls_to("convert-entities/vertex").size() == 1 and calls_to("/circles")[0][1]["center_point_id"] == fake.ref_points["body_box:5"])
	table.manager.deactivate()

	# --- dimensioning straight from the part's edge: no steps first
	table.manager.activate("dimension")
	await aim_uv(Vector2(40.0, 2.0))
	print("SMOKE with Dimension on, aiming at an edge of the part picks it (a line, from the part) and lights it: ", ed._hover_entity.get("kind") == "line" and ed._hover_entity.get("ref", {}).get("kind") == "edge" and ed.view._refs_hover.mesh != null)
	await pull()
	var made: bool = await settle(func() -> bool: return not ed.session.selection.is_empty() and not ed.session.busy)
	print("SMOKE the pick makes the edge usable in one go: its two end corners as pinned points (one of them is the corner from before, so only one convert) and a construction line between them, nothing else: ", made and calls_to("convert-entities/vertex").size() == 2 and calls_to("/lines").size() == 2 and calls_to("/lines")[1][1].get("construction", false) == true and ed.session.selection.size() == 1 and ed.session.selection[0]["kind"] == "line")
	print("SMOKE ...and since both its ends are pinned to the part nothing could be driven by a dimension on the edge alone: its length is offered only as a DRIVEN (reference) one: ", ed.session.ghosts.size() == 1 and bool(ed.session.ghosts[0].get("driven", false)))
	# now the free end of the drawn line: a distance from the part's edge to it
	var free_end: Vector2 = Vector2(60, 70)
	await aim_uv(free_end)
	await pull()
	await settle(func() -> bool: return not ed.session.ghosts.is_empty())
	var keys: Array = ed.session.ghosts.map(func(g): return g["key"])
	print("SMOKE then the sketch's own point (the line's free end) offers the distance from the part's edge to it: ", keys == ["point_line"] or keys.has("point_line"), " ", keys)
	var edge_line: String = ed.session.selection[0]["id"] if ed.session.selection[0]["kind"] == "line" else ed.session.selection[1]["id"]
	var res: Dictionary = await ed.session.confirm_ghost("point_line", 70.0)
	var dim: Array = calls_to("/constraints")
	print("SMOKE typing 70 reaches the backend as a point-to-line distance on the pinned edge line: ", res["ok"] and not dim.is_empty() and dim.back()[1]["type"] == "point_line_distance" and dim.back()[1]["line_id"] == edge_line and absf(float(dim.back()[1].get("distance", dim.back()[1].get("value", 70.0))) - 70.0) < 0.001)
	table.manager.deactivate()

	# --- a sketch that is not on the geometry the backend would use gets no references
	ed.session.references_ok = false
	var denied: Dictionary = await ed.session.ensure_reference({"kind": "vertex", "body": "body_box", "index": 3})
	print("SMOKE with references off, asking for one is refused with a reason and nothing is sent: ", not denied["ok"] and str(denied["message"]).contains("can't use") and calls_to("convert-entities/vertex").size() == 2)
	table.close()
	quit()
