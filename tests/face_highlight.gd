extends SceneTree
## Face-level highlighting for Mates and Measure (scripts/face_highlight.gd, wired by controller.gd/main.gd),
## full scene (main.tscn, no backend) with synthetic parts that carry real face identity (per-triangle
## face_ids/body_ids, like the backend's glb): with a tool on, the laser lights up ONLY the face it is on
## (the part's whole mesh is NOT tinted); moving to another face moves the highlight; aiming away clears it;
## a pick keeps its face lit (first cyan, second orange) until the picks clear; each hand hovers on its own;
## it follows the part and hides with it; Measure behaves the same; with no tool on, ordinary selection still
## tints the whole mesh; a part with no face identity is not highlighted at all.
## Run: "$GODOT" --headless --path . --script res://tests/face_highlight.gd  (see tests/README.md)

var main
var l: XRController3D
var r: XRController3D
var fh

func cube_part(parent: Node, pos: Vector3, tag: String, with_identity: bool = true) -> MeshInstance3D:
	# A 0.5 m cube from 6 quads (12 triangles, unindexed, outward, clockwise = front-facing in Godot). Face i owns triangles 2i and 2i+1.
	var h := 0.25
	var faces := [
		[Vector3(0, 0, 1), Vector3(-h, -h, h), Vector3(h, -h, h), Vector3(h, h, h), Vector3(-h, h, h)],   # +Z
		[Vector3(0, 0, -1), Vector3(h, -h, -h), Vector3(-h, -h, -h), Vector3(-h, h, -h), Vector3(h, h, -h)], # -Z
		[Vector3(0, 1, 0), Vector3(-h, h, h), Vector3(h, h, h), Vector3(h, h, -h), Vector3(-h, h, -h)],  # +Y
		[Vector3(0, -1, 0), Vector3(-h, -h, -h), Vector3(h, -h, -h), Vector3(h, -h, h), Vector3(-h, -h, h)], # -Y
		[Vector3(1, 0, 0), Vector3(h, -h, h), Vector3(h, -h, -h), Vector3(h, h, -h), Vector3(h, h, h)],  # +X
		[Vector3(-1, 0, 0), Vector3(-h, -h, -h), Vector3(-h, -h, h), Vector3(-h, h, h), Vector3(-h, h, -h)], # -X
	]
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var face_ids := []
	var body_ids := []
	var f := 0
	for q in faces:
		for tri in [[1, 3, 2], [1, 4, 3]]:
			for k in tri:
				verts.append(q[k])
				normals.append(q[0])
			face_ids.append(f)
			body_ids.append("body_" + tag)
		f += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.name = "Cube" + tag
	parent.add_child(m)
	m.position = pos
	m.add_to_group("grabbable_parts")
	m.create_trimesh_collision()
	m.set_meta("occurrence_id", "occ_" + tag)
	m.set_meta("owner_part_id", "root")
	if with_identity:
		m.set_meta("face_ids", face_ids)
		m.set_meta("body_ids", body_ids)
	return m

func frames(n: int = 3) -> void:
	for i in n:
		await process_frame
		await physics_frame

func aim(hand: XRController3D, from: Vector3, to: Vector3) -> void:
	hand.global_transform = Transform3D(Basis.looking_at((to - from).normalized(), Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.FORWARD), from)

func tri_count(node: MeshInstance3D) -> int:
	return (node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3

func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	fh = main.face_highlight
	print("SMOKE main builds the face highlighter and hands it to both controllers: ", fh != null and l.face_highlight == fh and r.face_highlight == fh)
	var a := cube_part(main.assembly_root, Vector3(0, 1, -1.5), "A")
	var b := cube_part(main.assembly_root, Vector3(1.0, 1, -1.5), "B")
	var bare := cube_part(main.assembly_root, Vector3(-1.0, 1, -1.5), "bare", false)
	await frames(3)

	# ---- ordinary selection (no tool): the whole mesh still tints
	r.global_position = Vector3(0, 1, 0)
	aim(r, Vector3(0, 1, 0), a.global_position)
	await frames(3)
	print("SMOKE with no tool on, hovering still tints the whole part (ordinary selection) and no face highlight appears: ", a.material_overlay != null and fh.hover_node(r) == null)

	# ---- Mates on: only the face lights up
	r.mates_tool_active = true
	l.mates_tool_active = true
	main._mates_tool.set_active(true)
	await frames(3)
	var key_front: String = fh.hover_key(r)
	var node_front: MeshInstance3D = fh.hover_node(r)
	print("SMOKE with Mates on, the laser lights up the face under it (the +Z face, 2 triangles), not the whole part: ", key_front == "body_A:0" and node_front != null and tri_count(node_front) == 2 and a.material_overlay == null)
	print("SMOKE ...the highlight is a child of the part, so it follows it everywhere: ", node_front.get_parent() == a and node_front.name == "FaceHighlight")
	var v0: Vector3 = (node_front.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array)[0]
	print("SMOKE ...lifted a hair off the surface so it doesn't z-fight (but not floating): ", v0.z > 0.25 and v0.z < 0.26)
	a.position += Vector3(0.0, 0.3, 0.0)
	await frames(1)
	print("SMOKE ...and moves with the part: ", node_front.global_position.is_equal_approx(a.global_position))
	a.position -= Vector3(0.0, 0.3, 0.0)
	await frames(2)

	# ---- another face
	aim(r, Vector3(0, 2.2, -1.5), a.global_position)
	await frames(3)
	var old_gone: bool = (not is_instance_valid(node_front)) or node_front.is_queued_for_deletion()
	print("SMOKE aiming at the top face moves the highlight to that face (old one released): ", fh.hover_key(r) == "body_A:2" and tri_count(fh.hover_node(r)) == 2 and old_gone)
	aim(r, Vector3(0, 1, 0), Vector3(0, 1, 3))
	await frames(3)
	print("SMOKE aiming at nothing clears the highlight: ", fh.hover_key(r) == "" and fh.hover_node(r) == null)

	# ---- picks stay lit
	aim(r, Vector3(0, 1, 0), a.global_position)
	await frames(3)
	r._on_button_pressed("trigger_click")
	await frames(2)
	var picks: Array = fh.pick_nodes()
	print("SMOKE a Mates pick keeps its face lit (one pick node, 2 triangles, first-pick cyan): ", picks.size() == 1 and tri_count(picks[0]) == 2 and (picks[0].material_override as ShaderMaterial).get_shader_parameter("colour") == fh.PICK_COLOURS[0])
	print("SMOKE ...and the hover layer sits over it (hovering the same face still shows): ", fh.hover_key(r) == "body_A:0")
	aim(r, Vector3(1.0, 1, 0), b.global_position)
	await frames(3)
	r._on_button_pressed("trigger_click")
	await frames(2)
	picks = fh.pick_nodes()
	print("SMOKE the second pick is lit too, in a different colour (orange): ", picks.size() == 2 and (picks[1].material_override as ShaderMaterial).get_shader_parameter("colour") == fh.PICK_COLOURS[1])
	print("SMOKE ...each on its own part: ", picks[0].get_parent() == a and picks[1].get_parent() == b)
	main._mates_tool.clear_picks()
	await frames(2)
	print("SMOKE clearing the picks clears their highlights: ", fh.pick_nodes().is_empty())
	aim(r, Vector3(0, 1, 0), a.global_position)
	await frames(3)
	r._on_button_pressed("trigger_click")
	await frames(2)
	print("SMOKE ...and switching the tool off clears a pick highlight too: ", fh.pick_nodes().size() == 1)
	r.mates_tool_active = false
	l.mates_tool_active = false
	main._mates_tool.set_active(false)
	await frames(3)
	print("SMOKE with the tool off no pick highlight and no face hover remain, and ordinary whole-part hover is back: ", fh.pick_nodes().is_empty() and fh.hover_node(r) == null and a.material_overlay != null)

	# ---- hide with the part
	r.measure_tool_active = true
	l.measure_tool_active = true
	main._measure_tool.set_active(true)
	await frames(3)
	print("SMOKE Measure highlights the hovered face the same way: ", fh.hover_key(r) == "body_A:0" and tri_count(fh.hover_node(r)) == 2 and a.material_overlay == null)
	a.visible = false
	await frames(2)
	print("SMOKE a hidden part shows no highlight (it is hidden with it, and the laser passes through): ", fh.hover_node(r) == null or not fh.hover_node(r).is_visible_in_tree())
	a.visible = true
	await frames(3)

	# ---- two hands, each its own hover
	aim(l, Vector3(1.0, 1, 0), b.global_position)
	aim(r, Vector3(0, 1, 0), a.global_position)
	await frames(3)
	print("SMOKE each hand has its own hover (left on part B, right on part A at once): ", fh.hover_key(l) == "body_B:0" and fh.hover_key(r) == "body_A:0" and fh.hover_node(l) != fh.hover_node(r))
	aim(l, Vector3(1.0, 1, 0), Vector3(1.0, 1, 3))
	await frames(3)
	print("SMOKE ...and one hand leaving clears only its own: ", fh.hover_key(l) == "" and fh.hover_key(r) == "body_A:0")

	# ---- no identity: nothing to pick, nothing to light
	aim(r, Vector3(-1.0, 1, 0), bare.global_position)
	await frames(3)
	print("SMOKE a part with no face identity gets no highlight at all (not the whole mesh either): ", fh.hover_node(r) == null and bare.material_overlay == null)

	# ---- Measure picks
	aim(r, Vector3(0, 1, 0), a.global_position)
	await frames(3)
	r._on_button_pressed("trigger_click")
	await frames(2)
	print("SMOKE a Measure pick keeps its face lit: ", fh.pick_nodes().size() == 1)
	main._measure_tool.clear_picks()
	r.measure_tool_active = false
	l.measure_tool_active = false
	main._measure_tool.set_active(false)
	await frames(2)
	print("SMOKE Measure off: all highlights gone: ", fh.pick_nodes().is_empty() and fh.hover_node(r) == null)
	quit()
