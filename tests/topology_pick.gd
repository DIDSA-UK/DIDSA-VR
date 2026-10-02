extends SceneTree
## Measure picks an EDGE or VERTEX when the laser is on one, not just a face (scripts/topology_pick.gd; the
## glb's per-Body topology extras, mesh_identity.gd; the highlight, face_highlight.gd; the pick,
## measure_tool.gd). Full scene (main.tscn, no backend), driven through the real import path with
## tests/fixtures/topology_box_cylinder.glb, a glb produced by DIDSA-CAD's own `encode_assembly_glb` from real
## OCCT shapes (a 100 mm box and a 30 mm x 100 mm cylinder, see tests/fixtures/README.md): the laser ray is real
## (physics against the imported trimesh), so this also proves the edge/vertex coordinates sit in the same frame
## as the triangles the ray hits. Covers: the topology reaching the part (12 edges / 8 vertices / 6 face
## boundaries), face centre -> face, near an edge -> that edge, near a corner -> that vertex, the cylinder's
## circular edge, the reach being an angle (shrinks up close) and capped by the part size, only the hit face's
## own edges being candidates, hover and pick highlights drawn as tube / ball, picks sending the right
## SubShapeRef (raw index, shape_type edge/vertex), Mates staying face-only, a part with no topology getting the
## face, and a third Measure pick starting afresh.
## Run: "$GODOT" --headless --path . --script res://tests/topology_pick.gd  (see tests/README.md)

const TopologyPick := preload("res://scripts/topology_pick.gd")

var main
var r: XRController3D
var fh


func frames(n: int = 3) -> void:
	for i in n:
		await process_frame
		await physics_frame


func aim_at(world_target: Vector3, from: Vector3) -> void:
	r.global_transform = Transform3D(Basis.looking_at((world_target - from).normalized(), Vector3.UP), from)


func part_by_occurrence(occ: String) -> MeshInstance3D:
	for p in get_nodes_in_group("grabbable_parts"):
		if p.get_meta("occurrence_id", "") == occ:
			return p
	return null


func local_to_world(part: Node3D, local: Vector3) -> Vector3:
	return part.global_transform * local


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	r = main.get_node("XROrigin3D/RightController")
	fh = main.face_highlight
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	var ok: bool = main._show_model(bytes, "", 0.001)
	await frames(3)
	var box := part_by_occurrence("occ_box")
	var cyl := part_by_occurrence("occ_cyl")
	print("SMOKE the backend glb loads two parts through the real import path: ", ok and box != null and cyl != null)

	# ---- the topology reaches the part, converted
	var topo: Dictionary = box.get_meta("topology", {})
	var box_body: Dictionary = topo.get("body_box", {})
	print("SMOKE the part carries its Body's topology: 12 edges, 8 vertices, 6 face boundaries: ", (box_body.get("edges", {}) as Dictionary).size() == 12 and (box_body.get("vertices", {}) as Dictionary).size() == 8 and (box_body.get("face_edges", []) as Array).size() == 6)
	print("SMOKE ...every box face is bounded by 4 edges: ", (box_body["face_edges"] as Array).all(func(f): return (f as PackedInt32Array).size() == 4))
	var cyl_body: Dictionary = (cyl.get_meta("topology", {}) as Dictionary).get("body_cyl", {})
	print("SMOKE the cylinder has 3 edges (two circles + seam), 2 vertices, 3 faces: ", (cyl_body.get("edges", {}) as Dictionary).size() == 3 and (cyl_body.get("vertices", {}) as Dictionary).size() == 2 and (cyl_body.get("face_edges", []) as Array).size() == 3)

	# ---- aim from far along +Z at the box's +Z face (local z = 100 mm => world z = -0.9, box spans x 0..0.1, y 1..1.1)
	var face_z := -0.9
	var origin_far := Vector3(0.05, 1.05, 1.0)
	r.measure_tool_active = true
	main._measure_tool.set_active(true)

	aim_at(Vector3(0.05, 1.05, face_z), origin_far)
	await frames(3)
	var hit_face: Dictionary = r._raycast_part(r.global_position, -r.global_transform.basis.z, 10.0)
	print("SMOKE the real ray hits the imported box: ", hit_face.get("part") == box)
	var e_centre: Dictionary = r._measure_entity(hit_face)
	print("SMOKE the middle of a face picks the FACE: ", e_centre.get("kind") == "face" and str(e_centre.get("key", "")).begins_with("body_box:"))

	aim_at(Vector3(0.05, 1.098, face_z), origin_far) # 2 mm in from the top edge of that face
	await frames(3)
	var hit_edge: Dictionary = r._raycast_part(r.global_position, -r.global_transform.basis.z, 10.0)
	var e_edge: Dictionary = r._measure_entity(hit_edge)
	print("SMOKE within a few mm of an edge picks that EDGE: ", e_edge.get("kind") == "edge" and e_edge.get("body_id") == "body_box")
	var edge_pts: PackedVector3Array = TopologyPick.edge_points(box, "body_box", int(e_edge.get("index", -1)))
	var edge_len := 0.0
	for i in range(0, edge_pts.size() - 1, 2):
		edge_len += edge_pts[i].distance_to(edge_pts[i + 1])
	print("SMOKE ...and it is the top edge of the +Z face (100 mm long, at local y=100, z=100, the very same frame as the mesh): ", absf(edge_len - 100.0) < 0.01 and edge_pts[0].y > 99.99 and edge_pts[0].z > 99.99)

	aim_at(Vector3(0.098, 1.098, face_z), origin_far) # 2.8 mm from the top-right corner
	await frames(3)
	var hit_vertex: Dictionary = r._raycast_part(r.global_position, -r.global_transform.basis.z, 10.0)
	var e_vertex: Dictionary = r._measure_entity(hit_vertex)
	var vp = TopologyPick.vertex_point(box, "body_box", int(e_vertex.get("index", -1)))
	print("SMOKE within a few mm of a corner picks that VERTEX (it wins over the edges meeting there): ", e_vertex.get("kind") == "vertex" and vp != null and (vp as Vector3).is_equal_approx(Vector3(100, 100, 100)))

	# ---- the reach is an angle, and capped by the part
	var near_reach := TopologyPick.reach_for(box, 0.3)
	var far_reach := TopologyPick.reach_for(box, 1.9)
	print("SMOKE the reach grows with distance (an angle, so it feels the same near and far): ", near_reach < far_reach)
	print("SMOKE ...is capped by the part's size (a 10 cm part never gets more than 15% of its middle dimension): ", far_reach <= 0.1 * TopologyPick.PART_SIZE_FRACTION + 0.0001)
	var small := MeshInstance3D.new()
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE * 0.02
	small.mesh = cube
	root.add_child(small)
	print("SMOKE ...so a 2 cm part keeps most of its faces pickable even from far away: ", TopologyPick.reach_for(small, 3.0) <= 0.02 * TopologyPick.PART_SIZE_FRACTION + 0.0001)
	small.free()

	# ---- only the hit face's own edges are candidates: with an absurd reach from the face centre the nearest
	# thing is a corner of THAT face (local z = 100), never one of the four on the far side (z = 0)
	var face_only: Dictionary = TopologyPick.pick(box, int(hit_face["face_index"]), local_to_world(box, Vector3(50, 50, 100)), 0.2)
	var face_only_point = TopologyPick.vertex_point(box, "body_box", int(face_only.get("index", -1)))
	print("SMOKE a huge reach from the face centre only considers that face's own corners (never the far side): ", face_only.get("kind") == "vertex" and face_only_point != null and absf((face_only_point as Vector3).z - 100.0) < 0.001)

	# ---- hover highlight: tube for an edge, ball for a vertex, face as before
	aim_at(Vector3(0.05, 1.098, face_z), origin_far)
	await frames(3)
	var hover_edge: MeshInstance3D = fh.hover_node(r)
	print("SMOKE hovering an edge draws a tube along it (a child of the part, ~100 mm long, no face lit): ", hover_edge != null and hover_edge.name == "EdgeHighlight" and hover_edge.get_parent() == box and hover_edge.mesh.get_aabb().size.length() > 99.0 and str(fh.hover_key(r)).begins_with("edge:body_box:"))
	aim_at(Vector3(0.098, 1.098, face_z), origin_far)
	await frames(3)
	var hover_vertex: MeshInstance3D = fh.hover_node(r)
	print("SMOKE hovering a corner draws a ball on it: ", hover_vertex != null and hover_vertex.name == "VertexHighlight" and hover_vertex.position.is_equal_approx(Vector3(100, 100, 100)) and str(fh.hover_key(r)).begins_with("vertex:body_box:"))
	aim_at(Vector3(0.05, 1.05, face_z), origin_far)
	await frames(3)
	var hover_face: MeshInstance3D = fh.hover_node(r)
	print("SMOKE hovering a face lights the face (2 triangles) as before: ", hover_face != null and hover_face.name == "FaceHighlight" and str(fh.hover_key(r)).begins_with("body_box:"))

	# ---- picks: real trigger pulls send the right SubShapeRef and keep the entity lit
	var mt = main._measure_tool
	aim_at(Vector3(0.05, 1.098, face_z), origin_far)
	await frames(3)
	r._on_button_pressed("trigger_click")
	await frames(2)
	var ref0: Dictionary = mt._picks[0]["subshape_ref"] if mt._picks.size() >= 1 else {}
	print("SMOKE picking near an edge sends an EDGE ref (raw index): ", ref0.get("shape_type") == "edge" and ref0.get("body_id") == "body_box" and int(ref0.get("index", -1)) >= 0 and int(ref0["index"]) < 12 and int(ref0["index"]) == int(e_edge["index"]))
	print("SMOKE ...the pick is labelled with what it is: ", mt.picked_labels()[0].ends_with("(edge)"))
	var picks_now: Array = fh.pick_nodes()
	print("SMOKE ...and the edge stays lit (cyan tube): ", picks_now.size() == 1 and picks_now[0].get_meta("highlight_kind") == "edge")
	aim_at(Vector3(0.098, 1.098, face_z), origin_far)
	await frames(3)
	r._on_button_pressed("trigger_click")
	await frames(2)
	var ref1: Dictionary = mt._picks[1]["subshape_ref"] if mt._picks.size() >= 2 else {}
	print("SMOKE a second pick near a corner sends a VERTEX ref: ", ref1.get("shape_type") == "vertex" and ref1.get("body_id") == "body_box" and int(ref1["index"]) == int(e_vertex["index"]))
	var picks_two: Array = fh.pick_nodes()
	print("SMOKE ...both picks stay lit, an edge tube and a vertex ball: ", picks_two.size() == 2 and picks_two[0].get_meta("highlight_kind") == "edge" and picks_two[1].get_meta("highlight_kind") == "vertex")
	aim_at(Vector3(0.05, 1.05, face_z), origin_far)
	await frames(3)
	r._on_button_pressed("trigger_click")
	await frames(2)
	var ref2: Dictionary = mt._picks[0]["subshape_ref"] if mt._picks.size() >= 1 else {}
	print("SMOKE a third pick starts afresh, and a face centre still picks the FACE: ", mt._picks.size() == 1 and ref2.get("shape_type") == "face" and fh.pick_nodes().size() == 1 and fh.pick_nodes()[0].get_meta("highlight_kind") == "face")
	mt.clear_picks()
	await frames(2)

	# ---- the cylinder's circular edge (a many-segment polyline)
	var cyl_origin := Vector3(0.3, 1.05, 1.0)
	# the cylinder's axis is local +Z (100 mm), radius 30 mm: its top rim is the circle at local z=100
	aim_at(local_to_world(cyl, Vector3(0.0, 30.0 - 1.0, 100.0)), cyl_origin) # 1 mm inside the rim, a quarter turn from the seam vertex (which would win up close)
	await frames(3)
	var hit_cyl: Dictionary = r._raycast_part(r.global_position, -r.global_transform.basis.z, 10.0)
	var e_cyl: Dictionary = r._measure_entity(hit_cyl)
	var rim_pts: PackedVector3Array = TopologyPick.edge_points(cyl, str(e_cyl.get("body_id", "")), int(e_cyl.get("index", -1)))
	print("SMOKE near the cylinder's rim picks the circular EDGE (a polyline of many segments): ", hit_cyl.get("part") == cyl and e_cyl.get("kind") == "edge" and rim_pts.size() >= 16)
	print("SMOKE ...and it is the top rim, at local z = 100: ", absf(rim_pts[0].z - 100.0) < 0.01 and absf(Vector2(rim_pts[0].x, rim_pts[0].y).length() - 30.0) < 0.05)

	# ---- Mates picks what a mate can use: corners, straight / circular edges, planar / cylindrical faces
	mt.set_active(false)
	r.measure_tool_active = false
	r.mates_tool_active = true
	var mates = main._mates_tool
	mates.set_active(true)
	aim_at(Vector3(0.05, 1.098, face_z), origin_far)
	await frames(3)
	print("SMOKE with Mates on, hovering near a straight edge lights that EDGE (a mate can use it): ", str(fh.hover_key(r)).begins_with("edge:body_box:") and fh.hover_node(r).get_meta("highlight_kind") == "edge")
	aim_at(Vector3(0.098, 1.098, face_z), origin_far)
	await frames(3)
	print("SMOKE ...and a corner lights that VERTEX: ", str(fh.hover_key(r)).begins_with("vertex:body_box:"))
	aim_at(Vector3(0.05, 1.05, face_z), origin_far)
	await frames(3)
	print("SMOKE ...and a planar face lights the face: ", str(fh.hover_key(r)).begins_with("body_box:") and fh.hover_node(r).get_meta("highlight_kind") == "face")
	aim_at(Vector3(0.05, 1.098, face_z), origin_far)
	await frames(3)
	r._on_button_pressed("trigger_click")
	await frames(2)
	var mate_ref: Dictionary = mates._picks[0]["subshape_ref"] if mates._picks.size() >= 1 else {}
	print("SMOKE a Mates pick near an edge sends an EDGE ref (raw index), and keeps it lit: ", mate_ref.get("shape_type") == "edge" and mate_ref.get("body_id") == "body_box" and fh.pick_nodes().size() == 1 and fh.pick_nodes()[0].get_meta("highlight_kind") == "edge")
	mates.clear_picks()
	# the cylinder: a circular rim is a mate axis, the cylindrical wall too
	aim_at(local_to_world(cyl, Vector3(0.0, 30.0 - 1.0, 100.0)), cyl_origin)
	await frames(3)
	print("SMOKE the cylinder's circular rim is offered to Mates (it is a concentric axis): ", str(fh.hover_key(r)).begins_with("edge:body_cyl:"))
	var cyl_faces: Array = cyl_body["face_kinds"]
	print("SMOKE the backend's face kinds reach the part (cylinder: 2 planes + 1 cylinder): ", cyl_faces.count("plane") == 2 and cyl_faces.count("cylinder") == 1)
	var cyl_edge_kinds: Dictionary = cyl_body["edge_kinds"]
	print("SMOKE ...and edge kinds (2 circles + the seam line): ", cyl_edge_kinds.values().count("circle") == 2 and cyl_edge_kinds.values().count("line") == 1)
	# an edge a mate cannot use is never offered to Mates, but Measure still can: fake an "other" kind on that edge
	var rim_index := int(e_cyl["index"])
	(cyl_body["edge_kinds"] as Dictionary)[rim_index] = "other"
	await frames(3)
	print("SMOKE an edge that is neither straight nor circular is NOT offered to Mates (the face under it is, as a face): ", not str(fh.hover_key(r)).begins_with("edge:"))
	var for_measure := TopologyPick.pick(cyl, int(hit_cyl["face_index"]), hit_cyl["point"], 0.009)
	print("SMOKE ...while Measure can still measure it: ", for_measure.get("kind") == "edge" and int(for_measure["index"]) == rim_index)
	(cyl_body["edge_kinds"] as Dictionary)[rim_index] = "circle"
	# a face a mate cannot use (not a plane / cylinder) is rejected with a reason, never silently
	var cap_face := TopologyPick.face_entity(cyl, int(hit_cyl["face_index"]))
	(cyl_body["face_kinds"] as Array)[int(cap_face["index"])] = "other" # pretend the top cap is a surface a mate cannot use
	var unmateable := TopologyPick.is_mateable(cyl, cap_face)
	print("SMOKE a face that is not a plane or cylinder is not mateable: ", not unmateable)
	aim_at(local_to_world(cyl, Vector3(0.0, 0.0, 100.0)), cyl_origin)
	await frames(3)
	r._on_button_pressed("trigger_click")
	await frames(2)
	print("SMOKE ...and a Mates pick on it is refused with a reason, nothing picked: ", mates._picks.is_empty() and mates.status_text().begins_with("A mate can only use"))
	main._mates_tool.set_active(false)
	r.mates_tool_active = false
	await frames(2)

	# ---- a part with no topology gets the face, and one with no identity gets nothing
	var plain := box.duplicate()
	plain.remove_meta("topology")
	root.add_child(plain)
	var plain_entity: Dictionary = TopologyPick.pick(plain, int(hit_edge["face_index"]), local_to_world(box, Vector3(50, 100, 100)), 0.05)
	print("SMOKE a part with no topology data (an older backend) still picks the face: ", plain_entity.get("kind") == "face")
	var bare := box.duplicate()
	bare.remove_meta("face_ids")
	bare.remove_meta("topology")
	root.add_child(bare)
	print("SMOKE a part with no face identity gets no entity at all: ", TopologyPick.pick(bare, 0, Vector3.ZERO, 0.05).is_empty())
	plain.free()
	bare.free()

	main.queue_free()
	await process_frame
	quit()
