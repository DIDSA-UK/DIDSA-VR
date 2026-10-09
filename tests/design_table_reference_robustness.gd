extends SceneTree
## Phase 2 of docs/implementation-plan.md, with the FAKE backend (tests/helpers/fake_cad.gd): the part's FACES as references (a flat face square to the sketch is
## a line, a round face with its axis square to it is a live centre: a blind hole whose rim is not in the plane), the references being SILENT (helpers the
## sketch hides from selection and snapping), and the robustness bar for them: (2) re-picking never makes a duplicate, (4) nothing orphaned is left behind and an Undo
## followed by the same pick makes the reference afresh, (5) a failed reference leaves nothing half made and says why. The other three bars are backend facts
## and are covered by the real-backend tests (backend/tests/test_reference_helpers.py, test_circle_centre_reference.py, DIDSA-VR tests/e2e_references_face.gd,
## e2e_references_lost.gd, e2e_references_history.gd): (1) follows or flags after an upstream edit, (3) survives save / reopen / the flat app, (6) hidden or rolled-back
## features and reopened earlier sketches.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_reference_robustness.gd  (see tests/README.md)

const Session := preload("res://scripts/design_table/sketch_session.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")
const PartReferences := preload("res://scripts/design_table/part_references.gd")
const SnapResolver := preload("res://scripts/design_table/snap_resolver.gd")

var fake
var s


func circle_pts(centre: Vector2, radius: float, z: float, n: int = 24) -> PackedVector3Array:
	## consecutive segment endpoints of a circle polyline, as the topology meta holds an edge
	var pts := PackedVector3Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		var b := TAU * float(i + 1) / float(n)
		pts.append(Vector3(centre.x + radius * cos(a), centre.y + radius * sin(a), z))
		pts.append(Vector3(centre.x + radius * cos(b), centre.y + radius * sin(b), z))
	return pts


func topology() -> Dictionary:
	## One body: a blind hole's wall (face 0, a cylinder, rims at z 10 and z 4, axis at (10, 5)), the plate's side at y = 0 (face 1, a plane square to the XY sketch,
	## with a notch so its boundary is not one straight edge), the plate's top (face 2, a plane parallel to the sketch) and a skewed wall (face 3, a plane tilted 45 degrees about the x axis, so it is not square to the sketch).
	var edges := {
		0: circle_pts(Vector2(10, 5), 6.0, 10.0),
		1: circle_pts(Vector2(10, 5), 6.0, 4.0),
		2: PackedVector3Array([Vector3(0, 0, 0), Vector3(40, 0, 0), Vector3(40, 0, 0), Vector3(40, 0, 20), Vector3(40, 0, 20), Vector3(0, 0, 20), Vector3(0, 0, 20), Vector3(0, 0, 0)]),
		3: PackedVector3Array([Vector3(0, 0, 20), Vector3(40, 0, 20), Vector3(40, 0, 20), Vector3(40, 30, 20), Vector3(40, 30, 20), Vector3(0, 30, 20), Vector3(0, 30, 20), Vector3(0, 0, 20)]),
		4: PackedVector3Array([Vector3(50, 0, 0), Vector3(60, 0, 0), Vector3(60, 0, 0), Vector3(60, 10, 10), Vector3(60, 10, 10), Vector3(50, 10, 10), Vector3(50, 10, 10), Vector3(50, 0, 0)]),
	}
	return {"body": {"edges": edges, "edge_kinds": {0: "circle", 1: "circle", 2: "line", 3: "line", 4: "line"}, "vertices": {}, "vertex_at": {},
		"face_edges": [PackedInt32Array([0, 1]), PackedInt32Array([2]), PackedInt32Array([3]), PackedInt32Array([4])], "face_kinds": ["cylinder", "plane", "plane", "plane"]}}


func fresh() -> void:
	fake = Fake.new()
	s = Session.new(Callable(fake, "handle"))
	s.owner_part_id = "P"
	await s.open_sketch({"fixed": "XY"})
	s.references_ok = true
	fake.calls.clear()


func calls_to(fragment: String) -> Array:
	return fake.calls.filter(func(c): return c[0].contains(fragment))


func _initialize() -> void:
	var plane := {"origin": Vector3.ZERO, "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}
	var refs: RefCounted = PartReferences.build(topology(), plane)

	# --- faces seen along the sketch plane
	var axes: Array = refs.faces.filter(func(f): return f["kind"] == "face_axis")
	var lines: Array = refs.faces.filter(func(f): return f["kind"] == "face_line")
	print("SMOKE a cylinder with its axis square to the plane is a face axis at the hole's centre (10, 5), radius 6, although neither rim is in the plane: ", axes.size() == 1 and (axes[0]["c"] as Vector2).distance_to(Vector2(10, 5)) < 0.05 and absf(float(axes[0]["r"]) - 6.0) < 0.05 and axes[0]["index"] == 0)
	print("SMOKE a flat face square to the plane is a face line between its two extremes (0, 0) and (40, 0): ", lines.size() == 1 and lines[0]["index"] == 1 and ((lines[0]["a"] as Vector2).distance_to(Vector2(0, 0)) < 0.01 and (lines[0]["b"] as Vector2).distance_to(Vector2(40, 0)) < 0.01 or (lines[0]["a"] as Vector2).distance_to(Vector2(40, 0)) < 0.01 and (lines[0]["b"] as Vector2).distance_to(Vector2(0, 0)) < 0.01))
	print("SMOKE a face parallel to the plane (the top) and a face at an angle are neither: ", refs.faces.filter(func(f): return f["index"] == 2 or f["index"] == 3).is_empty())
	var sideways := PartReferences.build(topology(), {"origin": Vector3.ZERO, "x": Vector3(1, 0, 0), "y": Vector3(0, 0, 1), "n": Vector3(0, -1, 0)})
	print("SMOKE the same cylinder seen from the side (its axis in the plane) is no face axis, and the same part has no empty-handed reference set: ", sideways.faces.filter(func(f): return f["kind"] == "face_axis").is_empty() and not sideways.is_empty())
	print("SMOKE a part with no face data gets no faces and builds as before: ", PartReferences.build({"b": {"edges": {}, "edge_kinds": {}, "vertices": {}, "vertex_at": {}}}, plane).faces.is_empty())

	# --- looking them up
	var near_axis: Dictionary = refs.nearest_face_axis(Vector2(10.5, 5.4), 2.0)
	print("SMOKE aiming near the axis finds it, and nothing further than the radius: ", not near_axis.is_empty() and near_axis["body"] == "body" and near_axis["index"] == 0 and refs.nearest_face_axis(Vector2(30, 30), 2.0).is_empty())
	var picked: Dictionary = refs.pick(Vector2(10.4, 5.2), 2.0, ["point"])
	print("SMOKE a pick for a point there is the face axis (a point with a face_axis reference): ", picked["kind"] == "point" and picked["ref"]["kind"] == "face_axis" and picked["ref"]["index"] == 0)
	var along: Dictionary = refs.pick(Vector2(20, 0.4), 2.0, ["line"])
	print("SMOKE a pick for a line near the flat face's line, with no straight edge of the part there, is the face line: ", along["kind"] == "line" and along["ref"]["kind"] == "face_line" and along["ref"]["index"] == 1)
	await fresh()
	var snap: Dictionary = SnapResolver.resolve(Vector2(10.4, 5.3), s, 3.0, true, [], null, refs)
	print("SMOKE the snap resolver offers the face axis as its own snap kind, with the reference: ", snap["kind"] == "face_axis" and snap["ref"]["kind"] == "face_axis" and (snap["uv"] as Vector2).distance_to(Vector2(10, 5)) < 0.05)

	# --- making them (silent)
	fake.face_axes = {"body:0": Vector2(10, 5)}
	fake.face_lines = {"body:1": [0, 1]}
	fake.vertex_positions = {"body:0": Vector2(0, 0), "body:1": Vector2(40, 0)}
	var made: Dictionary = await s.ensure_reference(snap["ref"])
	var face_calls := calls_to("convert-entities/face")
	print("SMOKE asking for the face axis is ONE convert-entities/face call, flagged as a reference: ", made["ok"] and face_calls.size() == 1 and face_calls[0][1] == {"body_id": "body", "face_index": 0, "construction": true, "reference": true})
	print("SMOKE ...it is a pinned point at the axis and a helper: ", s.points.has(made["id"]) and s.point_locked.get(made["id"], false) and s.is_reference(made["id"]) and s.points[made["id"]].distance_to(Vector2(10, 5)) < 0.01)
	print("SMOKE ...no shape was made for it (a centre only) and nothing was said: ", s.lines.is_empty() and s.circles.is_empty() and s.arcs.is_empty())
	var again: Dictionary = await s.ensure_reference(snap["ref"])
	print("SMOKE (robustness 2) the same face again gives the same point and the backend keeps one: ", again["ok"] and again["id"] == made["id"] and fake.reference_ids.size() == 1 and fake.points.size() == 1) # the one axis point (this fake has no origin point)
	print("SMOKE ...and the helper is not offered as a sketch point to pick, nor snapped to as one: ", s.nearest_entity(Vector2(10, 5), 1.0, ["point"]).is_empty() and SnapResolver.resolve(Vector2(10, 5), s, 3.0, true, [], null, null)["kind"] == "free")
	var flat: Dictionary = await s.ensure_reference(along["ref"])
	print("SMOKE a flat face gives a pinned construction line between its two corners, a helper with helper end points, none offered for selection: ", flat["ok"] and s.lines.has(flat["id"]) and s.is_reference(flat["id"]) and s.lines[flat["id"]]["construction"] and s.is_reference(s.lines[flat["id"]]["a"]) and s.nearest_entity(Vector2(20, 0.1), 1.0, ["line"]).is_empty())

	# --- robustness 4: nothing orphaned; undo; again
	await fresh()
	fake.face_axes = {"body:0": Vector2(10, 5)}
	var centre: Dictionary = await s.ensure_reference({"kind": "face_axis", "body": "body", "index": 0})
	s.set_tool("line")
	await s.tap({"uv": Vector2(10, 5), "id": str(centre["id"])})
	await s.tap({"uv": Vector2(30, 20), "id": ""})
	print("SMOKE a line started on the helper holds it (the helper is not pruned while a real line stands on it): ", s.lines.size() == 1 and s.points.has(centre["id"]))
	var undone: bool = await s.undo()
	print("SMOKE (robustness 4) Undo of the line leaves no helper behind (the backend cleans up what nothing depends on): ", undone and s.lines.is_empty() and not s.points.has(centre["id"]) and not fake.points.has(centre["id"]) and not fake.reference_ids.has(centre["id"]))
	fake.face_made.clear()
	var back: Dictionary = await s.ensure_reference({"kind": "face_axis", "body": "body", "index": 0})
	print("SMOKE ...and the same pick afterwards makes the reference afresh, usable at once: ", back["ok"] and s.points.has(back["id"]) and s.is_reference(back["id"]) and s.points[back["id"]].distance_to(Vector2(10, 5)) < 0.01)

	# --- robustness 5: a failed reference
	await fresh()
	var said := []
	s.status.connect(func(t): said.append(t))
	var points_before: int = s.points.size()
	var refused: Dictionary = await s.ensure_reference({"kind": "face_line", "body": "body", "index": 3})
	print("SMOKE (robustness 5) a face that cannot be used is refused with a reason in the user's words, and nothing was made: ", not refused["ok"] and str(refused["message"]).contains("isn't square") and s.points.size() == points_before and s.lines.is_empty() and fake.points.size() == points_before and fake.reference_ids.is_empty(), " ", refused["message"])
	fake.fail = "convert-entities/vertex"
	var failed_vertex: Dictionary = await s.ensure_reference({"kind": "vertex", "body": "body", "index": 5})
	print("SMOKE ...a corner the backend refuses leaves nothing behind either: ", not failed_vertex["ok"] and str(failed_vertex["message"]) != "" and s.points.size() == points_before and fake.reference_ids.is_empty())
	fake.fail = "convert-entities/edge"
	var failed_rim: Dictionary = await s.ensure_reference({"kind": "circle_edge", "body": "body", "index": 0})
	print("SMOKE ...and so does a hole's rim: ", not failed_rim["ok"] and s.circles.is_empty() and s.points.size() == points_before and fake.reference_ids.is_empty())
	var failed_edge: Dictionary = await s.ensure_reference({"kind": "edge", "body": "body", "index": 2, "a_vertex": 0, "b_vertex": 1})
	print("SMOKE ...and a straight edge (ONE call: no corner is left without its line): ", not failed_edge["ok"] and s.lines.is_empty() and s.points.size() == points_before and fake.reference_ids.is_empty())
	fake.fail = ""

	# --- every convert the session makes asks for a helper
	await fresh()
	fake.vertex_positions = {"body:0": Vector2(0, 0), "body:1": Vector2(40, 0)}
	fake.edge_vertices_for = func(b: String, e: int) -> Array: return [0, 1]
	fake.edge_circles = {"body:0": {"c": Vector2(10, 5), "r": 6.0, "full": true}}
	await s.ensure_reference({"kind": "vertex", "body": "body", "index": 0})
	await s.ensure_reference({"kind": "edge", "body": "body", "index": 2, "a_vertex": 0, "b_vertex": 1, "a": Vector2(0, 0), "b": Vector2(40, 0)})
	await s.ensure_reference({"kind": "circle_edge", "body": "body", "index": 0})
	var all_flagged := true
	for c in fake.calls:
		if c[0].contains("convert-entities") and not (c[1] is Dictionary and bool((c[1] as Dictionary).get("reference", false))):
			all_flagged = false
	print("SMOKE every vertex, edge, rim and face the session converts asks for a reference helper: ", all_flagged and calls_to("convert-entities").size() >= 3)
	var edge_a: Dictionary = await s.ensure_reference({"kind": "edge", "body": "body", "index": 2, "a_vertex": 0, "b_vertex": 1, "a": Vector2(0, 0), "b": Vector2(40, 0)})
	var rim_a: Dictionary = await s.ensure_reference({"kind": "circle_edge", "body": "body", "index": 0})
	print("SMOKE (robustness 2) the same edge and the same rim again make no second line and no second circle: ", s.lines.size() == 1 and s.circles.size() == 1 and edge_a["ok"] and rim_a["ok"])
	quit()
