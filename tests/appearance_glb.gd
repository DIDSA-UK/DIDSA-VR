extends SceneTree
## Headless, no network: a REAL assembly-mesh.glb from DIDSA-CAD whose Part has one body painted (tests/fixtures/appearance_split.glb,
## two 10 mm boxes, the second #E63946 at opacity 0.5; regenerate with tests/fixtures/make_appearance_split_glb.py). Such a mesh comes
## as one indexed primitive per look. Checks, through the exact GLTFDocument / tag_scene / create_trimesh_collision path main.gd uses:
## Godot makes one surface per primitive with the backend's material (the colour as picked: the backend writes it linear and the
## importer turns it back; see-through as alpha with a depth pre-pass), mesh_identity.gd joins the primitives' face ids in surface
## order so every triangle's id matches its own surface, and a laser hit on the painted box names the painted body.
## Run: "$GODOT" --headless --path . --script res://tests/appearance_glb.gd

const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const FIXTURE := "res://tests/fixtures/appearance_split.glb"

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _initialize() -> void:
	var bytes := FileAccess.get_file_as_bytes(FIXTURE)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	_check(doc.append_from_buffer(bytes, "", state) == OK, "the backend's glb parses")
	var json: Dictionary = state.json
	var primitives: Array = json["meshes"][0]["primitives"]
	_check(primitives.size() == 2 and primitives.all(func(p) -> bool: return p.has("indices")), "a part with one body painted is two indexed primitives")
	var painted_body := ""
	var painted_prim := -1
	for i in primitives.size():
		if primitives[i].has("material"):
			painted_prim = i
			painted_body = str(primitives[i]["extras"]["body_ids"][0])
	var scene := doc.generate_scene(state)
	var part: MeshInstance3D = scene.get_child(0) if scene.get_child_count() > 0 and scene.get_child(0) is MeshInstance3D else scene as MeshInstance3D
	MeshIdentity.tag_scene(state, scene)
	root.add_child(scene)
	await process_frame
	_check(part != null and part.mesh.get_surface_count() == 2, "Godot makes one surface per primitive")
	var m := part.mesh.surface_get_material(painted_prim) as StandardMaterial3D
	_check(m != null and m.albedo_color.is_equal_approx(Color(Color.html("#E63946"), 0.5)) and m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS,
		"the painted surface wears the picked colour at half opacity, alpha with a depth pre-pass (%s)" % (str(m.albedo_color) if m != null else "none"))
	var plain := part.mesh.surface_get_material(1 - painted_prim) as StandardMaterial3D
	_check(plain == null or (plain.albedo_color.is_equal_approx(Color.WHITE) and plain.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED), "the other surface wears the importer's plain default, as an unpainted part always has (%s)" % (str(plain.albedo_color) + " r" + str(plain.roughness) + " m" + str(plain.metallic) if plain != null else "none"))
	var face_ids: Array = part.get_meta("face_ids", [])
	var body_ids: Array = part.get_meta("body_ids", [])
	var tri_count: int = part.mesh.get_faces().size() / 3
	_check(face_ids.size() == tri_count and body_ids.size() == tri_count and part.has_meta("topology"), "the joined face ids cover every triangle in get_faces() order, and the topology is read")
	var offset := 0
	var per_surface_ok := true
	for s in part.mesh.get_surface_count():
		var count: int = (part.mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		var expect_painted := s == painted_prim
		for t in range(offset, offset + count):
			if (str(body_ids[t]) == painted_body) != expect_painted:
				per_surface_ok = false
		offset += count
	_check(per_surface_ok and offset == tri_count, "every triangle's body id is its own surface's (painted body in the painted surface)")
	part.create_trimesh_collision()
	await physics_frame
	await physics_frame
	var space := part.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(35.0, 5.0, 60.0), Vector3(35.0, 5.0, -60.0)))
	var ref := MeshIdentity.subshape_ref_for_hit(part, int(hit.get("face_index", -1))) if not hit.is_empty() else {}
	_check(not ref.is_empty() and str(ref["body_id"]) == painted_body, "a laser hit on the painted box names the painted body (%s)" % str(ref))
	var hit2 := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(5.0, 5.0, 60.0), Vector3(5.0, 5.0, -60.0)))
	var ref2 := MeshIdentity.subshape_ref_for_hit(part, int(hit2.get("face_index", -1))) if not hit2.is_empty() else {}
	_check(not ref2.is_empty() and str(ref2["body_id"]) != painted_body, "...and a hit on the other box names the other body")
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
