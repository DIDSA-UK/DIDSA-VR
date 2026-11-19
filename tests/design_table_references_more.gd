extends SceneTree
## More kinds of reference (scripts/design_table/part_references.gd, snap_resolver.gd, sketch_session.gd): the centre and rim of a circular edge (a hole or
## boss in the sketch plane), the midpoint of a part edge and the nearest point along one as snaps, and a driven (reference-only) dimension between two
## pinned things. FAKE backend (tests/helpers/fake_cad.gd) and the box-and-cylinder fixture (tests/fixtures/topology_box_cylinder.glb: a 100 mm box and a
## cylinder of radius 30 on the origin, 100 high, its bottom rim on the XY plane).
## Pure: circular edges are only the ones in the sketch plane; their centre and radius; what a pick at a rim or a centre means; edge midpoints; snap order.
## Scene: snapping to a hole's centre makes ONE pinned construction circle on the rim (convert-entities/edge) whose centre the shape starts on, reused the
## second time; picking the rim with Dimension makes it usable and offers radius / diameter as DRIVEN candidates; a driven dimension is kept without
## touching the backend, drawn in brackets, and taken back by undo; a snap to an edge's midpoint / along it makes a pinned line and a new point held on it
## by an at-midpoint / point-on-line constraint.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_references_more.gd  (see tests/README.md)

const Fake := preload("res://tests/helpers/fake_cad.gd")
const PartReferences := preload("res://scripts/design_table/part_references.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const SnapResolver := preload("res://scripts/design_table/snap_resolver.gd")
const SketchSession := preload("res://scripts/design_table/sketch_session.gd")
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


func part_named(occurrence: String) -> MeshInstance3D:
	for p in get_nodes_in_group("grabbable_parts"):
		if p.get_meta("occurrence_id", "") == occurrence:
			return p
	return null


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
	table.sketch_sheet_front = false # this test pins the older middle-of-the-slab sheet at 60 degrees (the "Middle" setting); the front-hinged sheet is tests/sketch_sheet_front.gd
	table.surface.settle_seconds = 0.0
	ed = table.editor
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(bytes, "", 0.001)
	await frames(3)
	var box := part_named("occ_box")
	var cyl := part_named("occ_cyl")
	# the fixture's cylinder stands on the origin, which is a snap of its own: move its topology (not its mesh; the references only read the topology) 50 right and 30 up
	var shift := Vector3(50, 30, 0)
	var moved := {}
	for body_id in cyl.get_meta("topology"):
		var body: Dictionary = (cyl.get_meta("topology")[body_id] as Dictionary).duplicate(true)
		for index in body["edges"]:
			var pts := PackedVector3Array()
			for p in (body["edges"][index] as PackedVector3Array):
				pts.append(p + shift)
			body["edges"][index] = pts
		for index in body["vertices"]:
			body["vertices"][index] = (body["vertices"][index] as Vector3) + shift
		var vertex_at := {}
		for key in body["vertex_at"]:
			vertex_at[(key as Vector3i) + Vector3i((shift * 100.0).round())] = body["vertex_at"][key]
		body["vertex_at"] = vertex_at
		moved[body_id] = body
	cyl.set_meta("topology", moved)
	var hole := Vector2(50, 30)
	var owner_id := str(box.get_meta("owner_part_id", ""))
	if owner_id == "":
		owner_id = "ASM"
		for p in get_nodes_in_group("grabbable_parts"):
			p.set_meta("owner_part_id", owner_id)

	# --- pure: the cylinder's rims
	var bottom := {"origin": Vector3.ZERO, "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}
	var refs: RefCounted = PartReferences.build(cyl.get_meta("topology"), bottom)
	print("SMOKE seen along the plane at the bottom the cylinder has ONE circular edge in the plane (its bottom rim; the top rim lies on the same spot but off the plane): ", refs.circles.size() == 1 and refs.edges[refs.circles[0]]["index"] == 2)
	var rim: Dictionary = refs.edges[refs.circles[0]]
	print("SMOKE its circle is found from the polyline: centre at (50, 30), radius 30, a whole circle: ", (rim["circle"]["c"] as Vector2).distance_to(hole) < 0.001 and absf(float(rim["circle"]["r"]) - 30.0) < 0.001 and rim["circle"]["full"])
	var top := {"origin": Vector3(0, 0, 100), "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}
	var top_refs: RefCounted = PartReferences.build(cyl.get_meta("topology"), top)
	print("SMOKE on the plane at the top it is the top rim, index 0: ", top_refs.circles.size() == 1 and top_refs.edges[top_refs.circles[0]]["index"] == 0)
	var middle := {"origin": Vector3(0, 0, 50), "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}
	var mid_refs: RefCounted = PartReferences.build(cyl.get_meta("topology"), middle)
	print("SMOKE on a plane between them neither rim is in the plane: both are drawn as reference lines but none can be picked as a circle: ", mid_refs.circles.is_empty() and mid_refs.edges.size() >= 1 and mid_refs.nearest_circular(hole + Vector2(30, 0), 3.0).is_empty())
	var centre: Dictionary = refs.nearest_centre(hole + Vector2(2, 1), 5.0)
	print("SMOKE the centre of the rim is found near it and nowhere else: ", int(centre["index"]) == 2 and (centre["uv"] as Vector2).distance_to(hole) < 0.001 and refs.nearest_centre(hole + Vector2(10, 10), 5.0).is_empty())
	var at_rim: Dictionary = refs.pick(hole + Vector2(21.0, 21.5), 3.0, ["point", "line", "circle", "arc"])
	print("SMOKE a pick on the rim is a CIRCLE entity with a circle_edge reference (not a line): ", at_rim["kind"] == "circle" and at_rim["id"] == "" and at_rim["ref"]["kind"] == "circle_edge" and int(at_rim["ref"]["index"]) == 2 and at_rim["ref"]["full"])
	var at_centre: Dictionary = refs.pick(hole + Vector2(1, 1), 3.0, ["point", "line", "circle", "arc"])
	print("SMOKE a pick at the centre is a POINT entity with a circle_centre reference: ", at_centre["kind"] == "point" and at_centre["ref"] == {"kind": "circle_centre", "body": "body_cyl", "index": 2})
	print("SMOKE a line-only tool does not take the rim, a point-only tool takes the centre: ", refs.pick(hole + Vector2(21.0, 21.5), 3.0, ["line"]).is_empty() and refs.pick(hole + Vector2(1, 1), 3.0, ["point"])["ref"]["kind"] == "circle_centre")
	var box_refs: RefCounted = PartReferences.build(box.get_meta("topology"), bottom)
	var mid: Dictionary = box_refs.nearest_midpoint(Vector2(52, 2), 5.0)
	print("SMOKE the midpoint of the box's bottom edge (0,0)-(100,0) is found near it, with the edge's end vertices: ", (mid["uv"] as Vector2).is_equal_approx(Vector2(50, 0)) and int(mid["a_vertex"]) >= 0 and int(mid["b_vertex"]) >= 0 and box_refs.nearest_midpoint(Vector2(20, 20), 5.0).is_empty())

	# an arc (a rounded corner, a quarter of a circle of radius 20 about (5, 5)): a circular edge with two different ends, so an Arc, not a whole circle
	var arc_pts := PackedVector3Array()
	var steps := 12
	for i in steps:
		var a0 := deg_to_rad(90.0 * float(i) / float(steps))
		var a1 := deg_to_rad(90.0 * float(i + 1) / float(steps))
		arc_pts.append(Vector3(5.0 + 20.0 * cos(a0), 5.0 + 20.0 * sin(a0), 0.0))
		arc_pts.append(Vector3(5.0 + 20.0 * cos(a1), 5.0 + 20.0 * sin(a1), 0.0))
	var arc_topology := {"b": {"edges": {7: arc_pts}, "edge_kinds": {7: "circle"}, "vertices": {1: arc_pts[0], 2: arc_pts[arc_pts.size() - 1]},
		"vertex_at": {Vector3i((arc_pts[0] * 100.0).round()): 1, Vector3i((arc_pts[arc_pts.size() - 1] * 100.0).round()): 2}}}
	var arc_refs: RefCounted = PartReferences.build(arc_topology, bottom)
	var arc_pick: Dictionary = arc_refs.pick(Vector2(5.0 + 14.5, 5.0 + 14.5), 3.0, ["point", "line", "circle", "arc"])
	print("SMOKE a quarter circle is a circular edge too: its centre (5, 5), radius 20, NOT a whole circle: a pick on it is an ARC entity (an Arc in the sketch), a tool that takes only circles does not pick it: ", arc_refs.circles.size() == 1 and arc_pick["kind"] == "arc" and not arc_pick["ref"]["full"] and (arc_pick["ref"]["c"] as Vector2).distance_to(Vector2(5, 5)) < 0.001 and absf(float(arc_pick["ref"]["r"]) - 20.0) < 0.001 and arc_refs.pick(Vector2(19.5, 19.5), 3.0, ["circle"]).is_empty())

	# --- pure: snap order (a fake session that only has what the resolver reads)
	var fake_session := SketchSession.new()
	fake_session.references_ok = true
	var snap_centre := SnapResolver.resolve(hole + Vector2(2, 1), fake_session, 5.0, true, [], null, refs)
	print("SMOKE a snap near a hole's centre is the centre, as a circle_centre reference: ", snap_centre["kind"] == "centre" and (snap_centre["uv"] as Vector2).distance_to(hole) < 0.001 and snap_centre["ref"] == {"kind": "circle_centre", "body": "body_cyl", "index": 2})
	var snap_mid := SnapResolver.resolve(Vector2(52, 2), fake_session, 5.0, true, [], null, box_refs)
	print("SMOKE a snap near the middle of a part edge is that midpoint, as an edge_midpoint reference to the edge: ", snap_mid["kind"] == "edge_midpoint" and (snap_mid["uv"] as Vector2).is_equal_approx(Vector2(50, 0)) and snap_mid["ref"]["kind"] == "edge_midpoint" and snap_mid["ref"]["edge"]["kind"] == "edge")
	var snap_along := SnapResolver.resolve(Vector2(30, 1.5), fake_session, 5.0, true, [], null, box_refs)
	print("SMOKE a snap near an edge, away from its ends and its middle, lands on the edge: an edge_point reference at the nearest spot: ", snap_along["kind"] == "edge_point" and (snap_along["uv"] as Vector2).is_equal_approx(Vector2(30, 0)))
	var snap_rim := SnapResolver.resolve(hole + Vector2(21.0, 21.5), fake_session, 5.0, true, [], null, refs)
	print("SMOKE a snap on a hole's rim lands on the rim (an edge_point on a circle_edge): ", snap_rim["kind"] == "edge_point" and snap_rim["ref"]["edge"]["kind"] == "circle_edge" and absf((snap_rim["uv"] as Vector2).distance_to(hole) - 30.0) < 0.01)
	print("SMOKE with references off, or the snap switched off, none of them: ", SnapResolver.resolve(hole + Vector2(2, 1), fake_session, 5.0, false, [], null, refs)["kind"] == "free")
	fake_session.references_ok = false
	print("SMOKE ...references off: ", SnapResolver.resolve(hole + Vector2(2, 1), fake_session, 5.0, true, [], null, refs)["kind"] == "free")

	# --- scene: the box first (edge midpoint / along an edge)
	fake = Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.mesh_bytes = bytes
	fake.origin = true
	fake.vertex_positions = {"body_box:5": Vector2(100, 0), "body_box:1": Vector2(0, 0)}
	fake.edge_vertices_for = func(b: String, e: int) -> Array:
		for x in ed.part_refs.edges:
			if x["body"] == b and int(x["index"]) == e:
				return [x["a_vertex"], x["b_vertex"]]
		return [-1, -1]
	ed.api = fake
	table.open()
	table.seat(box)
	await settle(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	await frames(3)
	table.manager.activate("line")
	await aim_uv(Vector2(52, 2))
	print("SMOKE aiming a drawing tool near the middle of the part's bottom edge snaps the cursor to it as an edge midpoint (and lights the edge): ", ed._snap["kind"] == "edge_midpoint" and (ed._snap["uv"] as Vector2).is_equal_approx(Vector2(50, 0)) and ed.view._refs_hover.mesh != null)
	await pull()
	await aim_uv(Vector2(60, 70))
	await pull()
	await settle(func() -> bool: return not calls_to("POST /sketch/sketches/sk1/lines").is_empty() and not ed.session.busy)
	var line_calls := calls_to("POST /sketch/sketches/sk1/lines")
	var constraint_calls := calls_to("POST /sketch/sketches/sk1/constraints")
	var host_line: String = ""
	for e in fake.entities:
		if e["type"] == "line" and e["construction"]:
			host_line = e["id"]
	var mid_constraint: Dictionary = constraint_calls[0][1] if not constraint_calls.is_empty() else {}
	print("SMOKE a line started there makes the edge a pinned construction line, a NEW point held at its middle by an at-midpoint constraint, and the line starts on that point: ", calls_to("convert-entities/edge").size() == 1 and host_line != "" and mid_constraint.get("type") == "at_midpoint" and mid_constraint.get("line_id") == host_line and line_calls.size() == 1 and line_calls[0][1]["start_point_id"] == mid_constraint.get("point_id"))
	var new_point: String = str(mid_constraint.get("point_id", ""))
	print("SMOKE ...at the middle of the edge, and it is a free point of the sketch (not pinned: the constraint holds it): ", fake.points.has(new_point) and (fake.points[new_point] as Vector2).is_equal_approx(Vector2(50, 0)) and not fake.pinned.has(new_point))
	table.manager.deactivate()

	table.manager.activate("point")
	await aim_uv(Vector2(52, 2))
	await frames(2)
	print("SMOKE aiming at the middle again finds the point that is already there: no second one is offered as a new snap: ", ed._snap["kind"] == "point" and ed._snap["id"] == new_point)
	table.manager.deactivate()
	table.manager.activate("point")
	await aim_uv(Vector2(30, 1.5))
	print("SMOKE aiming near the edge elsewhere snaps along it: ", ed._snap["kind"] == "edge_point" and (ed._snap["uv"] as Vector2).is_equal_approx(Vector2(30, 0)))
	await pull()
	await settle(func() -> bool: return calls_to("POST /sketch/sketches/sk1/constraints").size() == 2 and not ed.session.busy)
	var along: Dictionary = calls_to("POST /sketch/sketches/sk1/constraints").back()[1]
	print("SMOKE a point placed there is held on the pinned line by a point-on-line constraint (the same pinned line, no second one made): ", along.get("type") == "point_on_line" and along.get("line_id") == host_line and calls_to("convert-entities/edge").size() == 1 and fake.entities.filter(func(e): return e["type"] == "line" and e["construction"]).size() == 1 and (fake.points[along["point_id"]] as Vector2).is_equal_approx(Vector2(30, 0)))
	table.manager.deactivate()
	table.close()

	# --- scene: the cylinder (a hole's centre and rim, a driven dimension)
	fake = Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.mesh_bytes = bytes
	fake.origin = true
	fake.edge_circles = {"body_cyl:2": {"c": hole, "r": 30.0, "full": true}}
	ed.api = fake
	table.open()
	table.seat(cyl)
	await settle(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	await frames(3)
	print("SMOKE the cylinder's bottom rim is a reference circle in this sketch: ", ed.part_refs != null and ed.part_refs.circles.size() == 1)
	table.manager.activate("line")
	await aim_uv(hole + Vector2(2, 1))
	print("SMOKE aiming a drawing tool near the hole's centre snaps to it as its centre: ", ed._snap["kind"] == "centre" and ed._snap["ref"]["kind"] == "circle_centre")
	await pull()
	await aim_uv(Vector2(90, 70))
	await pull()
	await settle(func() -> bool: return not calls_to("POST /sketch/sketches/sk1/lines").is_empty() and not ed.session.busy)
	var converts := calls_to("convert-entities/edge")
	print("SMOKE the line starts on the centre: ONE convert-entities/edge of the rim (a construction circle, centre pinned to the hole), no vertex converts, and no free point made for the start: ", converts.size() == 1 and converts[0][1] == {"body_id": "body_cyl", "edge_index": 2, "construction": true, "reference": true} and calls_to("convert-entities/vertex").is_empty() and calls_to("POST /sketch/sketches/sk1/lines")[0][1]["start_point_id"] == fake.ref_points["body_cyl:c2"])
	print("SMOKE ...the circle came into the sketch as a construction circle with a pinned centre: ", ed.session.circles.size() == 1 and ed.session.circles.values()[0]["construction"] and ed.session.point_locked.get(fake.ref_points["body_cyl:c2"], false))
	table.manager.deactivate()
	table.manager.activate("circle")
	await aim_uv(hole + Vector2(1.5, 0.5))
	await pull()
	await aim_uv(hole + Vector2(-8, 6))
	await pull()
	await settle(func() -> bool: return not calls_to("POST /sketch/sketches/sk1/circles").is_empty() and not ed.session.busy)
	print("SMOKE the centre is reused for a second shape (no second convert): ", calls_to("convert-entities/edge").size() == 1 and calls_to("POST /sketch/sketches/sk1/circles")[0][1]["center_point_id"] == fake.ref_points["body_cyl:c2"])
	table.manager.deactivate()

	table.manager.activate("dimension")
	await aim_uv(hole + Vector2(-28.3, -10.3)) # on the rim, away from the sketch's own shapes (a sketch shape under the laser wins over the part's)
	print("SMOKE with Dimension on, aiming at the rim picks the hole's circle (a reference helper now: it is the part's rim that is picked, and the helper the centre snap made is found for it): ", ed._hover_entity.get("kind") == "circle" and str(ed._hover_entity.get("ref", {}).get("kind", "")) == "circle_edge")
	await pull()
	await settle(func() -> bool: return not ed.session.selection.is_empty() and not ed.session.busy)
	var keys: Array = ed.session.ghosts.map(func(g): return g["key"])
	print("SMOKE it is already there from the centre snap (no second circle) and offers radius and diameter, as DRIVEN candidates (it is pinned, nothing a dimension says could move it): ", ed.session.selection[0]["kind"] == "circle" and calls_to("convert-entities/edge").size() == 1 and keys == ["diameter", "radius"] and ed.session.ghosts.all(func(g): return bool(g.get("driven", false))) and absf(float(ed.session.ghost("radius")["value"]) - 30.0) < 0.01)
	var constraints_before := calls_to("POST /sketch/sketches/sk1/constraints").size()
	var kept: Dictionary = await ed.session.confirm_ghost("diameter", 0.0)
	var items: Array = ed.session.dimension_items()
	print("SMOKE keeping the diameter stores a reference dimension on the backend (POST .../reference-dimensions, diameter of the circle), shows it in brackets, measured (60), and adds NO constraint: ", kept["ok"] and ed.session.ref_dims.size() == 1 and fake.reference_dimensions.size() == 1 and calls_to("POST /sketch/sketches/sk1/reference-dimensions")[0][1]["kind"] == "diameter" and calls_to("POST /sketch/sketches/sk1/constraints").size() == constraints_before and calls_to("PATCH").is_empty() and items.size() == 1 and items[0]["text"] == "(⌀60)" and items[0]["driven"])
	print("SMOKE ...and the view draws it (a label on the sheet, in brackets): ", ed.view.label_texts().has("(⌀60)"))
	var undone: bool = await ed.session.undo()
	print("SMOKE undo takes the reference dimension back (a DELETE on the backend): ", undone and ed.session.ref_dims.is_empty() and fake.reference_dimensions.is_empty() and ed.session.dimension_items().is_empty())
	# two pinned things: the hole's centre and the origin
	await aim_uv(hole + Vector2(1.5, 0.5))
	await pull()
	await settle(func() -> bool: return not ed.session.selection.is_empty() and not ed.session.busy)
	await aim_uv(Vector2(0, 0))
	await pull()
	await settle(func() -> bool: return ed.session.selection.size() == 2 and not ed.session.busy)
	var pinned_keys: Array = ed.session.ghosts.map(func(g): return g["key"])
	print("SMOKE two pinned points (the hole's centre and the origin) offer their distance only as driven candidates: ", pinned_keys.has("linear") and ed.session.ghosts.all(func(g): return bool(g.get("driven", false))))
	table.manager.deactivate()
	table.close()

	# --- scene: Dimension picks a rim that is NOT in the sketch yet: the circle is made on the way (one convert), radius and diameter offered as driven
	fake = Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.mesh_bytes = bytes
	fake.origin = true
	fake.edge_circles = {"body_cyl:2": {"c": hole, "r": 30.0, "full": true}}
	ed.api = fake
	table.open()
	table.seat(cyl)
	await settle(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	await frames(3)
	table.manager.activate("dimension")
	await aim_uv(hole + Vector2(21.0, 21.5))
	print("SMOKE aiming Dimension at a rim that is not in the sketch yet picks it from the part (a circle with a circle_edge reference, lit on the view): ", ed._hover_entity.get("kind") == "circle" and ed._hover_entity["ref"]["kind"] == "circle_edge" and ed.view._refs_hover.mesh != null)
	await pull()
	await settle(func() -> bool: return not ed.session.selection.is_empty() and not ed.session.busy)
	print("SMOKE the pick made the circle on the way, with ONE convert-entities/edge, and offers its radius (30) as a driven candidate: ", calls_to("convert-entities/edge").size() == 1 and ed.session.selection[0]["kind"] == "circle" and ed.session.ghosts.size() == 2 and ed.session.ghost("radius").get("driven", false) and absf(float(ed.session.ghost("radius")["value"]) - 30.0) < 0.01)
	var label_uv: Vector2 = ed.view._ghost_text_uv["radius"]
	await aim_uv(label_uv)
	await pull()
	await settle(func() -> bool: return not ed.session.ref_dims.is_empty() or not ed.session.busy)
	print("SMOKE pulling the trigger on a driven candidate keeps it (in brackets, R30) with no constraint call: ", ed.session.ref_dims.size() == 1 and calls_to("POST /sketch/sketches/sk1/constraints").is_empty() and ed.session.dimension_items()[0]["text"] == "(R30)")
	table.manager.deactivate()
	table.close()

	# --- sketches that used to be refused: something hidden, and a reopened sketch that is not the last feature
	fake = Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.mesh_bytes = bytes
	fake.filtered_mesh_bytes = bytes # (the fixture has one shape; what is checked is WHICH fetch was made and that its topology is used)
	fake.origin = true
	fake.sketch_plane = "XY"
	fake.points = {"pA": Vector2(0, 0), "pB": Vector2(40, 0)}
	fake.entities = [{"type": "line", "id": "lnA", "start_point_id": "pA", "end_point_id": "pB", "construction": false}]
	fake.feature_rows = {"PART_BOX": [
		{"type": "sketch", "id": "sk1", "sketch_id": "s1", "plane_feature_id": null, "locked": true, "has_lost_reference": false},
		{"type": "extrude", "id": "ex1", "sketch_feature_id": "sk1", "extrude_type": "boss", "start_distance": 0.0, "end_distance": 12.0, "target_body_ids": [], "locked": true},
		{"type": "sketch", "id": "sk2", "sketch_id": "s2", "plane_feature_id": null, "locked": true, "has_lost_reference": false},
		{"type": "extrude", "id": "ex2", "sketch_feature_id": "sk2", "extrude_type": "boss", "start_distance": 0.0, "end_distance": 5.0, "target_body_ids": [], "locked": true},
		{"type": "fillet", "id": "fl1", "edge_refs": [{"body_id": "ex2", "shape_type": "edge", "index": 0}], "radius": 2.0, "locked": false},
	]}
	table.api = fake
	ed.api = fake
	table.open()
	table.seat(box)
	await settle(func() -> bool: return table.build.features.size() == 5)
	fake.calls.clear()
	var reopened: bool = await ed.reopen_sketch("sk2")
	await settle(func() -> bool: return ed.part_refs != null)
	var path_used := ""
	for c in fake.calls:
		if str(c[0]).contains("assembly-mesh.glb"):
			path_used = str(c[0])
	print("SMOKE reopening a sketch that is NOT the last feature now gets the part's corners and edges: the part is fetched as the sketch saw it, with everything after it (the extrude and the fillet) left out, and only its topology is used: ", reopened and ed.session.references_ok and ed.part_refs != null and path_used.contains("rollback_excluded_feature_ids=ex2") and path_used.contains("rollback_excluded_feature_ids=fl1") and not path_used.contains("hidden_feature_ids") and not path_used.contains("sk2") and not path_used.contains("=ex1"))
	print("SMOKE ...the table's own picture was not touched (the same mesh is on the copy): ", table.table_copy.mesh == box.mesh)
	await ed.session.ensure_reference({"kind": "vertex", "body": "body_box", "index": 5})
	print("SMOKE ...and a reference from it is made as usual (the backend resolves the index at that point of the history, which is the topology the corner was read from): ", calls_to("convert-entities/vertex").size() == 1 and calls_to("convert-entities/vertex")[0][1] == {"body_id": "body_box", "vertex_index": 5, "reference": true})
	var last_sketch_calls := calls_to("assembly-mesh.glb").size()
	ed.end_sketch()
	table.build.select("ex2")
	table.build.toggle_hidden_selected()
	await frames(3)
	fake.calls.clear()
	await ed.begin_sketch({"fixed": "XY"})
	await settle(func() -> bool: return ed.part_refs != null)
	path_used = ""
	for c in fake.calls:
		if str(c[0]).contains("assembly-mesh.glb"):
			path_used = str(c[0])
	print("SMOKE with a feature hidden in the Build tree a new sketch on the part gets references too: the whole part's topology is fetched (nothing hidden, nothing rolled back, the backend ignores hiding), the table shows the hidden view as before: ", ed.session.references_ok and ed.part_refs != null and path_used.contains("assembly-mesh.glb") and not path_used.contains("hidden_feature_ids") and not path_used.contains("rollback_excluded"))
	ed.end_sketch()

	# --- lost and moved references (the backend's answer after an upstream edit): shown in the editor, re-picked, kept
	fake = Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.mesh_bytes = bytes
	fake.filtered_mesh_bytes = bytes
	fake.origin = true
	fake.sketch_plane = "XY"
	fake.points = {"pL": Vector2(100, 0), "pM": Vector2(0, 0), "pOK": Vector2(0, 100)}
	fake.pinned = {"pL": true, "pM": true, "pOK": true}
	fake.entities = []
	fake.reference_rows = [
		{"point_id": "pM", "body_id": "body_box", "kind": "vertex", "vertex_index": 1, "status": "potentially_moved", "reason": "unique_fingerprint_far", "method": "signature", "candidates": []},
		{"point_id": "pL", "body_id": "body_box", "kind": "vertex", "vertex_index": 5, "status": "lost", "reason": "consumed_by_fl1", "method": "", "candidates": []},
		{"point_id": "pOK", "body_id": "body_box", "kind": "vertex", "vertex_index": 3, "status": "ok", "reason": "", "method": "index", "candidates": []},
	]
	fake.feature_rows = {"PART_BOX": [
		{"type": "sketch", "id": "sk1", "sketch_id": "s1", "plane_feature_id": null, "locked": true, "has_lost_reference": true, "lost_reference_point_ids": ["pL"], "moved_reference_point_ids": ["pM"], "followed_reference_point_ids": [], "reference_reasons": {"pL": "consumed_by_fl1"}},
		{"type": "extrude", "id": "ex1", "sketch_feature_id": "sk1", "extrude_type": "boss", "start_distance": 0.0, "end_distance": 12.0, "target_body_ids": [], "locked": true},
		{"type": "fillet", "id": "fl1", "edge_refs": [{"body_id": "ex1", "shape_type": "edge", "index": 0}], "radius": 2.0, "locked": false, "has_lost_reference": false, "lost_references": [], "moved_references": ["edge_refs[0]"], "followed_references": []},
	]}
	table.api = fake
	ed.api = fake
	table.open()
	table.seat(box)
	table.build.clear() # (the part never really left in this test: read its features afresh, as seating it for the first time does)
	await table.build.reload()
	await settle(func() -> bool: return table.build.features.size() == 3)
	var BuildTree := preload("res://scripts/design_table/build_tree.gd")
	print("SMOKE the Build tree's notes say what is wrong with each row: a sketch's lost and moved points, another feature's moved reference, nothing for a healthy one: ", BuildTree.reference_note(table.build.features[0]) == "1 lost, 1 may have moved" and BuildTree.reference_note(table.build.features[2]) == "reference may have moved" and BuildTree.reference_note(table.build.features[1]) == "" and BuildTree.reference_note({"has_lost_reference": true}) == "lost reference" and BuildTree.reference_note({"lost_reference_point_ids": ["a", "b"]}) == "2 lost references")
	print("SMOKE the sketch's Build row carries the note, in the warning colour (and so does the fillet's): ", table.tree._build_rows.find_children("*", "Button", true, false).any(func(b): return str(b.text).begins_with("Sketch 1") and str(b.text).contains("1 lost, 1 may have moved")) and table.tree._build_rows.find_children("*", "Button", true, false).any(func(b): return str(b.text).begins_with("Fillet 1") and str(b.text).contains("reference may have moved")))
	print("SMOKE the status line names them when the list is read (once): ", table.ui.status_text().begins_with("Build tree: Sketch 1: 1 lost, 1 may have moved; Fillet 1: reference may have moved"), " ", table.ui.status_text())
	fake.calls.clear()
	await ed.reopen_sketch("sk1")
	await settle(func() -> bool: return ed.part_refs != null)
	var sess = ed.session
	print("SMOKE reopening it reads which of its points are the part's references and how each is doing: ", calls_to("/external-references").size() == 1 and sess.reference_status("pL") == "lost" and sess.reference_status("pM") == "potentially_moved" and sess.reference_status("pOK") == "ok" and sess.reference_status("nothing") == "ok")
	print("SMOKE the flagged ones are listed lost first, and the status line carries a warning with the counts: ", sess.flagged_references().map(func(r): return r["point_id"]) == ["pL", "pM"] and sess.reference_warning().contains("1 lost, 1 may have moved") and ed._sketch_hint().begins_with("Reference to the part: 1 lost, 1 may have moved"))
	print("SMOKE the Select tool, with nothing picked, offers Fix (and Keep for the moved one) in the options row: ", table.ui._options.map(func(o): return o["id"]) == ["refs_fix", "refs_keep"] and str(table.ui._options[0]["text"]) == "Fix 2 reference(s)")
	print("SMOKE the view marks the two flagged points (the drawing has more in it than without them): ", ed.view._geo.mesh != null)
	await ed.on_option("refs_fix")
	print("SMOKE Fix starts on the lost point and says what to do (and why it was lost): ", ed.repick_point == "pL" and ed.view.repick_point == "pL" and table.ui.status_text().contains("Lost (2 to do)") and table.ui.status_text().contains("consumed by fl1") and table.ui._options.map(func(o): return o["id"]) == ["refs_next", "refs_cancel"])
	table.manager.deactivate()
	table.manager.activate("select")
	await aim_uv(Vector2(98, 1.5))
	print("SMOKE while re-picking, aiming near a corner of the part picks that corner (only corners and hole centres count, not the sketch's own things): ", ed._hover_entity.get("ref", {}) == {"kind": "vertex", "body": "body_box", "index": 5})
	await pull()
	await settle(func() -> bool: return not fake.reattached.is_empty() and not ed.session.busy)
	print("SMOKE the trigger re-attaches the lost point to that corner: one reattach call naming the point, the body and the vertex: ", fake.reattached == [["pL", "body_box", 5]])
	print("SMOKE ...and the walk goes on to the next flagged point (here the moved one still stands in the fake's answer, so it is next): ", ed.repick_point in ["pM", ""])
	ed._stop_repick()
	await ed.on_option("refs_keep")
	await settle(func() -> bool: return not fake.confirmed.is_empty())
	print("SMOKE Keep confirms the potentially moved point with the backend (and only that one): ", fake.confirmed == ["pM"])
	var wrong: Dictionary = await sess.reattach("pM", {"kind": "circle_centre", "body": "body_cyl", "index": 2})
	print("SMOKE a corner-following point refuses a hole as its replacement (and the other way round), with a reason and nothing sent: ", not wrong["ok"] and str(wrong["message"]).contains("corner") and fake.reattached.size() == 1)
	ed.end_sketch()
	table.close()
	quit()
