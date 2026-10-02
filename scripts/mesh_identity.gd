extends RefCounted
## Milestone 4 (mates/colours/sections/measurements): correlates each glTF
## node's generated Godot scene node with the backend identity
## `assembly-mesh.glb` now carries in plain JSON `extras` - `occurrence_id`/
## `owner_part_id` per node, `face_ids`/`body_ids` per triangle (see
## DIDSA-CAD's `app.document.mesh_export.AssemblyGlbInstance`/
## `encode_assembly_glb` docstrings for the wire shape and the empty-
## occurrence_id convention). Stored as plain node metadata, the same
## convention `controller.gd` already uses for "held"/"selected".
##
## `face_ids`/`body_ids` are read back via a raycast hit's own `face_index`
## (`PhysicsDirectSpaceState3D.intersect_ray`'s result key) - confirmed
## (headless, against a real backend-format glb through the exact
## GLTFDocument/create_trimesh_collision path main.gd uses) to match the
## original unindexed triangle order 1:1, so `face_ids[face_index]` is
## always the right OCCT face for whichever triangle the ray actually hit.
## Godot's own PrimitiveMesh generators (e.g. BoxMesh, used by several
## synthetic tests) do NOT necessarily share this same winding - this only
## holds for a mesh that came through GLTFDocument's own import.
##
## No `GLTFDocumentExtension` needed for the extras themselves - `GLTFState.
## json` is a plain, already-parsed Dictionary. `GLTFState.get_scene_node()`
## looked like the obvious way to map a json node index to its generated
## Node, but empirically (headless, see tests/mesh_identity.gd) it only
## returns a live object *during* `generate_scene()` itself - called after,
## from ordinary script code, it returns an already-freed instance every
## time. So instead: `assembly-mesh.glb`'s own nodes are always flat, one
## per placed instance, with no parent/child nesting at all
## (`encode_assembly_glb`'s own `"scenes": [{"nodes": list(range(len(nodes)))}]`
## - no node ever has a "children" key) - confirmed (same headless test) that
## `generate_scene()` preserves that order 1:1 in `scene.get_children()` for
## exactly this flat shape, so plain index correlation works with no
## GLTFDocumentExtension anywhere. This does NOT generalize to an arbitrary
## glTF file with real node hierarchy/skinning - only to this backend's own
## deliberately-flat assembly-mesh.glb shape.

static func tag_scene(gltf_state: GLTFState, scene: Node) -> void:
	var json: Dictionary = gltf_state.json
	var json_nodes: Array = json.get("nodes", [])
	var json_meshes: Array = json.get("meshes", [])
	var scene_children := scene.get_children()
	var topology_cache := {}
	for i in mini(json_nodes.size(), scene_children.size()):
		var node_json: Dictionary = json_nodes[i]
		var scene_node := scene_children[i]
		if not (scene_node is MeshInstance3D):
			continue

		var extras: Dictionary = node_json.get("extras", {})
		scene_node.set_meta("occurrence_id", extras.get("occurrence_id", ""))
		scene_node.set_meta("owner_part_id", extras.get("owner_part_id", ""))

		var mesh_index = node_json.get("mesh")
		if mesh_index == null or mesh_index < 0 or mesh_index >= json_meshes.size():
			continue
		var primitives: Array = json_meshes[mesh_index].get("primitives", [])
		if primitives.is_empty():
			continue
		var prim_extras: Dictionary = primitives[0].get("extras", {})
		if prim_extras.has("face_ids"):
			# JSON round-trips every number as float - re-cast to int here (once,
			# at tag time) rather than at every later subshape_ref_for_hit() call,
			# and so a request built from this always sends a real JSON integer,
			# not e.g. "index": 3.0.
			var face_ids: Array = prim_extras["face_ids"]
			var face_ids_int: Array = []
			for fid in face_ids:
				face_ids_int.append(int(fid))
			scene_node.set_meta("face_ids", face_ids_int)
			scene_node.set_meta("body_ids", prim_extras["body_ids"])
			if prim_extras.has("topology"):
				if not topology_cache.has(mesh_index): # instances of one mesh share one converted copy
					topology_cache[mesh_index] = _convert_topology(prim_extras["topology"])
				scene_node.set_meta("topology", topology_cache[mesh_index])


static func _convert_topology(raw: Dictionary) -> Dictionary:
	## The glb's per-Body real edges / vertices / face boundaries (DIDSA-CAD's `_topology_extras`), turned into
	## what picking needs once, at tag time: per body_id
	##   edges        {SubShapeRef index -> PackedVector3Array of segment endpoints (consecutive pairs), part-local}
	##   vertices     {SubShapeRef index -> Vector3, part-local}
	##   vertex_at    {quantised point (0.01 units) -> vertex index}, to find the vertex at an edge's end
	##   face_edges   [face id -> PackedInt32Array of edge indices on that face's boundary]
	## Indices are the backend's raw SubShapeRef indices (NOT the dense drawing ids), so they can be sent
	## straight back to /measure.
	var out := {}
	for body_id in raw:
		var body: Dictionary = raw[body_id]
		var edges := {}
		for e in body.get("edges", []):
			var flat: Array = e["s"]
			var pts := PackedVector3Array()
			for i in range(0, flat.size() - 2, 3):
				pts.append(Vector3(float(flat[i]), float(flat[i + 1]), float(flat[i + 2])))
			edges[int(e["i"])] = pts
		var vertices := {}
		var vertex_at := {}
		for v in body.get("vertices", []):
			var p: Array = v["p"]
			var point := Vector3(float(p[0]), float(p[1]), float(p[2]))
			vertices[int(v["i"])] = point
			vertex_at[quantise(point)] = int(v["i"])
		var face_edges: Array = []
		for f in body.get("face_edges", []):
			var ids := PackedInt32Array()
			for e in f:
				ids.append(int(e))
			face_edges.append(ids)
		out[str(body_id)] = {"edges": edges, "vertices": vertices, "vertex_at": vertex_at, "face_edges": face_edges}
	return out


static func quantise(point: Vector3) -> Vector3i:
	return Vector3i((point * 100.0).round())


static func subshape_ref_for_hit(part: Node3D, face_index: int) -> Dictionary:
	## Turns a raycast hit's face_index into a real
	## SubShapeRef{body_id, shape_type, index} the backend's Mate/Measure
	## endpoints understand. Empty Dictionary if `part` carries no face
	## identity at all (a bare local .glb with no backend behind it, or the
	## backend's own placeholder-box mesh) or `face_index` is out of range
	## (-1, Godot's own "not a concave/trimesh hit" value).
	if face_index < 0 or not part.has_meta("face_ids"):
		return {}
	var face_ids: Array = part.get_meta("face_ids")
	var body_ids: Array = part.get_meta("body_ids")
	if face_index >= face_ids.size():
		return {}
	return {"body_id": body_ids[face_index], "shape_type": "face", "index": face_ids[face_index]}


static func occurrence_ref_for(part: Node3D) -> Dictionary:
	## {owner_part_id, occurrence_id} for POST .../mates or .../measure -
	## empty Dictionary if `part` was never tagged at all (no backend
	## identity behind it, e.g. a bare local .glb).
	if not part.has_meta("occurrence_id"):
		return {}
	return {"owner_part_id": part.get_meta("owner_part_id"), "occurrence_id": part.get_meta("occurrence_id")}
