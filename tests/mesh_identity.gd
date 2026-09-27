extends SceneTree
## Milestone 4: `assembly-mesh.glb` now carries occurrence/face identity as
## plain glTF `extras` (DIDSA-CAD's `app.document.mesh_export.
## encode_assembly_glb` - node extras `{owner_part_id, occurrence_id}`,
## primitive extras `{face_ids, body_ids}` parallel to its triangles). This
## proves the CLIENT half of that contract, hand-building a glb byte-for-byte
## in the same shape (no backend needed - the backend side is covered by its
## own pytest suite in DIDSA-CAD: `test_mesh_export.py`,
## `test_assembly_mesh_glb.py`, `test_merged_body_mesh_data.py`):
##
## - `GLTFState.json` round-trips `extras` intact through `append_from_buffer`.
## - `GLTFState.get_scene_node(i)` correctly maps a glTF json node index to
##   the MeshInstance3D `generate_scene()` built for it (confirmed empirically
##   - not documented anywhere obvious - see this project's own scratch
##   investigation, not committed).
## - A real physics ray hit's own `face_index` matches the original,
##   unindexed triangle order 1:1 for a mesh that came through this exact
##   GLTFDocument/create_trimesh_collision path (confirmed against a
##   standard-winding synthetic box: every one of its 6 faces hit correctly
##   from outside, `face_index` landing on the expected triangle every time -
##   Godot's own PrimitiveMesh generators, e.g. BoxMesh, do NOT necessarily
##   share this winding, which is why this test builds a real glb rather than
##   using one).
## - `mesh_identity.gd`'s `tag_scene()`/`subshape_ref_for_hit()`/
##   `occurrence_ref_for()` turn that into a real SubShapeRef/occurrence ref.
##
## Run: "$GODOT" --headless --path . --script res://tests/mesh_identity.gd

const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const _GLTF_COMPONENT_TYPE_FLOAT := 5126
const _GLTF_MODE_TRIANGLES := 4
const _GLTF_TARGET_ARRAY_BUFFER := 34962


func _pad4(bytes: PackedByteArray, pad_byte: int) -> PackedByteArray:
	var remainder := bytes.size() % 4
	if remainder == 0:
		return bytes
	var padded := bytes.duplicate()
	for _i in (4 - remainder):
		padded.append(pad_byte)
	return padded


func _pack_vec3_array(vecs: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	for v: Vector3 in vecs:
		buf.put_float(v.x)
		buf.put_float(v.y)
		buf.put_float(v.z)
	return buf.data_array


func _build_glb(gltf_json: Dictionary, bin_data: PackedByteArray) -> PackedByteArray:
	## Mirrors DIDSA-CAD's `mesh_export.py::encode_assembly_glb`'s own
	## container-level byte layout exactly (magic/version/chunk headers),
	## just assembled in GDScript instead of Python.
	var json_bytes := _pad4(JSON.stringify(gltf_json).to_utf8_buffer(), 0x20)
	var bin_bytes := _pad4(bin_data, 0x00)

	var buf := StreamPeerBuffer.new()
	buf.put_data("glTF".to_utf8_buffer())
	buf.put_u32(2)
	buf.put_u32(12 + 8 + json_bytes.size() + 8 + bin_bytes.size())
	buf.put_u32(json_bytes.size())
	buf.put_u32(0x4E4F534A)
	buf.put_data(json_bytes)
	buf.put_u32(bin_bytes.size())
	buf.put_u32(0x004E4942)
	buf.put_data(bin_bytes)
	return buf.data_array


func _standard_winding_box_triangles(centre: Vector3) -> Array:
	## 12 triangles (2 per face, 6 faces), standard CCW-front winding as seen
	## from outside each face - the same convention confirmed (real OCCT
	## tessellation, DIDSA-CAD backend) to match what the real backend
	## actually emits. Returns [positions: Array[Vector3], normals: Array[Vector3]].
	var s := 1.0
	var faces := [
		[Vector3(1, 0, 0), [Vector3(s, -s, -s), Vector3(s, s, -s), Vector3(s, s, s), Vector3(s, -s, s)]],
		[Vector3(-1, 0, 0), [Vector3(-s, -s, s), Vector3(-s, s, s), Vector3(-s, s, -s), Vector3(-s, -s, -s)]],
		[Vector3(0, 1, 0), [Vector3(-s, s, -s), Vector3(-s, s, s), Vector3(s, s, s), Vector3(s, s, -s)]],
		[Vector3(0, -1, 0), [Vector3(-s, -s, s), Vector3(-s, -s, -s), Vector3(s, -s, -s), Vector3(s, -s, s)]],
		[Vector3(0, 0, 1), [Vector3(-s, -s, s), Vector3(s, -s, s), Vector3(s, s, s), Vector3(-s, s, s)]],
		[Vector3(0, 0, -1), [Vector3(s, -s, -s), Vector3(-s, -s, -s), Vector3(-s, s, -s), Vector3(s, s, -s)]],
	]
	var positions: Array = []
	var normals: Array = []
	for face in faces:
		var normal: Vector3 = face[0]
		var corners: Array = face[1]
		for tri in [[0, 1, 2], [0, 2, 3]]:
			for idx in tri:
				positions.append(centre + corners[idx])
				normals.append(normal)
	return [positions, normals]


func _initialize() -> void:
	var box_a: Array = _standard_winding_box_triangles(Vector3.ZERO)
	var box_b: Array = _standard_winding_box_triangles(Vector3.ZERO)
	var positions_a: Array = box_a[0]
	var normals_a: Array = box_a[1]
	var positions_b: Array = box_b[0]
	var normals_b: Array = box_b[1]
	var face_ids: Array = []
	for tri_index in (positions_a.size() / 3):
		face_ids.append(tri_index / 2) # 2 triangles per face, dense per-face id
	var body_ids: Array = []
	for _i in face_ids.size():
		body_ids.append("body-1")

	var bin_data := PackedByteArray()
	var pos_a_bytes := _pack_vec3_array(positions_a)
	var norm_a_bytes := _pack_vec3_array(normals_a)
	var pos_b_bytes := _pack_vec3_array(positions_b)
	var norm_b_bytes := _pack_vec3_array(normals_b)
	var offsets := {"pos_a": 0, "norm_a": pos_a_bytes.size()}
	bin_data.append_array(pos_a_bytes)
	bin_data.append_array(norm_a_bytes)
	offsets["pos_b"] = bin_data.size()
	bin_data.append_array(pos_b_bytes)
	offsets["norm_b"] = bin_data.size()
	bin_data.append_array(norm_b_bytes)

	var buffer_views := [
		{"buffer": 0, "byteOffset": offsets["pos_a"], "byteLength": pos_a_bytes.size(), "target": _GLTF_TARGET_ARRAY_BUFFER},
		{"buffer": 0, "byteOffset": offsets["norm_a"], "byteLength": norm_a_bytes.size(), "target": _GLTF_TARGET_ARRAY_BUFFER},
		{"buffer": 0, "byteOffset": offsets["pos_b"], "byteLength": pos_b_bytes.size(), "target": _GLTF_TARGET_ARRAY_BUFFER},
		{"buffer": 0, "byteOffset": offsets["norm_b"], "byteLength": norm_b_bytes.size(), "target": _GLTF_TARGET_ARRAY_BUFFER},
	]
	var accessors := [
		{"bufferView": 0, "componentType": _GLTF_COMPONENT_TYPE_FLOAT, "count": positions_a.size(), "type": "VEC3"},
		{"bufferView": 1, "componentType": _GLTF_COMPONENT_TYPE_FLOAT, "count": normals_a.size(), "type": "VEC3"},
		{"bufferView": 2, "componentType": _GLTF_COMPONENT_TYPE_FLOAT, "count": positions_b.size(), "type": "VEC3"},
		{"bufferView": 3, "componentType": _GLTF_COMPONENT_TYPE_FLOAT, "count": normals_b.size(), "type": "VEC3"},
	]
	var gltf_json := {
		"asset": {"version": "2.0"},
		"scene": 0,
		"scenes": [{"nodes": [0, 1]}],
		"nodes": [
			{
				"mesh": 0, "translation": [0.0, 0.0, 0.0],
				"extras": {"owner_part_id": "root-part", "occurrence_id": ""},
			},
			{
				"mesh": 1, "translation": [5.0, 0.0, 0.0],
				"extras": {"owner_part_id": "root-part", "occurrence_id": "occ-child-1"},
			},
		],
		"meshes": [
			{"primitives": [{
				"attributes": {"POSITION": 0, "NORMAL": 1}, "mode": _GLTF_MODE_TRIANGLES,
				"extras": {"face_ids": face_ids, "body_ids": body_ids},
			}]},
			{"primitives": [{
				"attributes": {"POSITION": 2, "NORMAL": 3}, "mode": _GLTF_MODE_TRIANGLES,
				"extras": {"face_ids": face_ids, "body_ids": body_ids},
			}]},
		],
		"buffers": [{"byteLength": bin_data.size()}],
		"bufferViews": buffer_views,
		"accessors": accessors,
	}

	var glb_bytes := _build_glb(gltf_json, bin_data)

	var gltf_document := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	var parse_error := gltf_document.append_from_buffer(glb_bytes, "", gltf_state)
	print("SMOKE parses without error: ", parse_error == OK)

	# --- extras round-trip through GLTFState.json intact
	var json: Dictionary = gltf_state.json
	print("SMOKE node 0 extras round-trip: ", json["nodes"][0]["extras"] == {"owner_part_id": "root-part", "occurrence_id": ""})
	print("SMOKE node 1 extras round-trip: ", json["nodes"][1]["extras"] == {"owner_part_id": "root-part", "occurrence_id": "occ-child-1"})
	var round_tripped_face_ids: Array = json["meshes"][0]["primitives"][0]["extras"]["face_ids"]
	var round_tripped_as_int: Array = []
	for fid in round_tripped_face_ids: # JSON round-trips every number as float - see mesh_identity.gd's own note
		round_tripped_as_int.append(int(fid))
	print("SMOKE primitive face_ids round-trip: ", round_tripped_as_int == face_ids)

	var scene := gltf_document.generate_scene(gltf_state)
	var root := Node3D.new()
	root.add_child(scene)
	get_root().add_child(root)

	MeshIdentity.tag_scene(gltf_state, scene)

	var mesh_instances: Array = []
	var stack: Array = [scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			mesh_instances.append(n)
		stack.append_array(n.get_children())
	print("SMOKE two MeshInstance3D nodes found: ", mesh_instances.size() == 2)

	var root_content: MeshInstance3D = null
	var child_occurrence: MeshInstance3D = null
	for m in mesh_instances:
		if m.get_meta("occurrence_id", "") == "":
			root_content = m
		else:
			child_occurrence = m
	print("SMOKE root content tagged occurrence_id='': ", root_content != null and MeshIdentity.occurrence_ref_for(root_content) == {"owner_part_id": "root-part", "occurrence_id": ""})
	print("SMOKE placed occurrence tagged with its real id: ", child_occurrence != null and MeshIdentity.occurrence_ref_for(child_occurrence) == {"owner_part_id": "root-part", "occurrence_id": "occ-child-1"})

	# --- a real ray hit resolves to the right SubShapeRef
	for m in mesh_instances:
		m.create_trimesh_collision()
	await process_frame
	await process_frame

	var space_state := root.get_world_3d().direct_space_state
	# child_occurrence sits at x=5; its +X face is at x=6.
	var query := PhysicsRayQueryParameters3D.create(Vector3(16.0, 0.0, 0.0), Vector3(5.0, 0.0, 0.0))
	var result := space_state.intersect_ray(query)
	var hit_part: Node3D = result.get("collider").get_parent() if result.get("collider") is StaticBody3D else null
	print("SMOKE ray hits the placed occurrence's +X face: ", hit_part == child_occurrence)
	var ref := MeshIdentity.subshape_ref_for_hit(hit_part, result.get("face_index", -1)) if hit_part else {}
	# +X is face 0 in _standard_winding_box_triangles's own face order.
	print("SMOKE hit resolves to a real SubShapeRef (body-1, face, 0): ", ref == {"body_id": "body-1", "shape_type": "face", "index": 0})

	var untagged := Node3D.new()
	print("SMOKE subshape_ref_for_hit on an untagged part is empty: ", MeshIdentity.subshape_ref_for_hit(untagged, 0) == {})
	untagged.free()
	root.queue_free()
	quit()
