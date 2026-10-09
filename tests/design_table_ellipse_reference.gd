extends SceneTree
## ELLIPSE EDGES as references (reference-overhaul R-F, Phase 6.6): the part's references see a full elliptical edge lying in the sketch plane (kind "ellipse" in the mesh's edge kinds):
## its centre, radii and major-axis angle are fitted from the polyline (covariance of an evenly spread ellipse), a pick on it is an ELLIPSE entity carrying an `ellipse_edge` reference,
## a tilted ellipse (not in the plane) and a circle reported as an ellipse are not offered; the session makes it with ONE convert-entities/edge call (reference true) and reads
## the sketch in; the same edge again makes nothing new; a reference ellipse is not picked as itself, not dimensioned, and drawn quietly.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_ellipse_reference.gd  (see tests/README.md)

const PartReferences := preload("res://scripts/design_table/part_references.gd")
const SketchSession := preload("res://scripts/design_table/sketch_session.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")


func ellipse_points(c: Vector2, a: float, b: float, angle: float, z: float, steps: int) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in steps:
		var t0 := TAU * float(i) / float(steps)
		var t1 := TAU * float(i + 1) / float(steps)
		for t in [t0, t1]:
			var local := Vector2(a * cos(t), b * sin(t)).rotated(angle)
			pts.append(Vector3(c.x + local.x, c.y + local.y, z))
	return pts


func _initialize() -> void:
	var plane := {"origin": Vector3.ZERO, "n": Vector3(0, 0, 1), "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0)}
	var pts := ellipse_points(Vector2(12, -7), 30.0, 10.0, deg_to_rad(25.0), 0.0, 48)
	var topology := {"b": {"edges": {4: pts}, "edge_kinds": {4: "ellipse"}, "vertices": {1: pts[0]}, "vertex_at": {Vector3i((pts[0] * 100.0).round()): 1}}}
	var refs: RefCounted = PartReferences.build(topology, plane)
	var e: Dictionary = refs.edges[0] if not refs.edges.is_empty() else {}
	var fit: Dictionary = e.get("ellipse", {})
	print("SMOKE a full elliptical edge in the sketch plane is fitted: centre (12, -7), radii 30 and 10, major axis 25 degrees: ", refs.ellipse_edges.size() == 1 and (fit["c"] as Vector2).distance_to(Vector2(12, -7)) < 0.05 and absf(float(fit["a"]) - 30.0) < 0.1 and absf(float(fit["b"]) - 10.0) < 0.1 and absf(rad_to_deg(float(fit["angle"])) - 25.0) < 0.5, " ", fit)
	var on_rim: Vector2 = Vector2(12, -7) + Vector2(30.0 * cos(1.0), 10.0 * sin(1.0)).rotated(deg_to_rad(25.0))
	var pick: Dictionary = refs.pick(on_rim, 2.0, ["point", "line", "circle", "arc", "ellipse"])
	print("SMOKE a pick near its rim is an ELLIPSE entity with an ellipse_edge reference to that edge: ", pick.get("kind", "") == "ellipse" and pick["ref"]["kind"] == "ellipse_edge" and pick["ref"]["body"] == "b" and pick["ref"]["index"] == 4, " ", pick)
	print("SMOKE ...a tool that does not take ellipses does not pick it: ", refs.pick(on_rim, 2.0, ["line", "circle", "arc"]).is_empty())
	var tilted := PackedVector3Array()
	for p in pts:
		tilted.append(Vector3(p.x, p.y, p.x * 0.2)) # tilted out of the plane
	var tilted_refs: RefCounted = PartReferences.build({"b": {"edges": {4: tilted}, "edge_kinds": {4: "ellipse"}, "vertices": {1: tilted[0]}, "vertex_at": {Vector3i((tilted[0] * 100.0).round()): 1}}}, plane)
	print("SMOKE an elliptical edge NOT in the sketch plane is not offered: ", tilted_refs.ellipse_edges.is_empty())
	var round_pts := ellipse_points(Vector2.ZERO, 10.0, 10.0, 0.0, 0.0, 48)
	var round_refs: RefCounted = PartReferences.build({"b": {"edges": {4: round_pts}, "edge_kinds": {4: "ellipse"}, "vertices": {1: round_pts[0]}, "vertex_at": {Vector3i((round_pts[0] * 100.0).round()): 1}}}, plane)
	print("SMOKE ...nor is one whose radii are equal (that is a circle): ", round_refs.ellipse_edges.is_empty())
	# --- the session
	var fake := Fake.new()
	fake.origin = true
	fake.edge_ellipses = {"b:4": {"c": Vector2(12, -7), "a": 30.0, "b": 10.0}}
	var s := SketchSession.new(Callable(fake, "request"))
	s.owner_part_id = "P"
	s.feature_id = "F"
	s.sketch_id = "sk1"
	s.references_ok = true
	var made: Dictionary = await s.ensure_reference(pick["ref"])
	var calls: Array = fake.calls.filter(func(c): return String(c[0]).ends_with("/convert-entities/edge"))
	print("SMOKE ensure_reference makes the ellipse with ONE convert-entities/edge call (reference true, construction true): ", made["ok"] and calls.size() == 1 and calls[0][1] == {"body_id": "b", "edge_index": 4, "construction": true, "reference": true}, " ", calls)
	print("SMOKE ...the sketch is read in: the ellipse is in the model, flagged as a reference, its centre pinned: ", s.ellipses.has(made["id"]) and s.is_reference(made["id"]) and s.point_locked.get(s.ellipses[made["id"]]["c"], false))
	var again: Dictionary = await s.ensure_reference(pick["ref"])
	print("SMOKE the same edge again answers with the same ellipse and makes no second one: ", again["ok"] and again["id"] == made["id"] and s.ellipses.size() == 1)
	print("SMOKE a reference ellipse is not picked as itself by the laser's nearest search: ", s.nearest_entity(on_rim, 5.0, ["ellipse"]).is_empty())
	s.set_tool("dimension")
	await s.select({"kind": "ellipse", "id": made["id"]})
	print("SMOKE ...and offers no dimension (its size is the part's): ", s.ghosts.is_empty())
	var bad: Dictionary = await s.ensure_reference({"kind": "ellipse_edge", "body": "b", "index": 99})
	print("SMOKE an edge the backend refuses comes back as a failure with a reason: ", not bad["ok"] and String(bad["message"]).begins_with("Couldn't use that edge"))
	quit()
