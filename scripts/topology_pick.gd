extends RefCounted
## Measure tool picking: turns "the laser hit this triangle of this part, at this point" into the thing a
## pick should take, a CAD VERTEX, EDGE or FACE (in that order of priority), as a backend SubShapeRef-ready
## entity. The backend's glb carries each Body's real edges, vertices and per-face boundary edges
## (mesh_identity.gd's "topology" meta, DIDSA-CAD's `_topology_extras`); a ray only ever hits a face, so edges
## and vertices are found by nearness: of the HIT FACE'S OWN boundary edges (and their end vertices), the one
## within a small reach of the hit point wins. Only the hit face's edges are candidates, so a vertex or edge
## on the far side of a thin part can never be picked by accident.
##
## The reach is an angle, not a distance: about the width of the laser's tip on screen (so it feels the same
## near and far), floored so it can still be done up close and capped by the size of the part so a small part
## is never all edges.
##
## Entity = {kind: "face"|"edge"|"vertex", body_id, index (the SubShapeRef index), face_index (the hit
## triangle), key ("kind:body:index")}. A part with no topology data (or no face identity) just gets the face.

const MeshIdentity := preload("res://scripts/mesh_identity.gd")

const REACH_PER_METRE := 0.025 ## world metres of reach per metre of hit distance (~1.4 degrees)
const REACH_MIN := 0.004 ## metres
const REACH_MAX := 0.03 ## metres
const PART_SIZE_FRACTION := 0.15 ## never more than this fraction of the part's middle dimension
const EDGE_REACH_FRACTION := 0.7 ## an edge needs the laser a bit closer than a vertex does


static func entity_key(kind: String, body_id: String, index: int) -> String:
	## A face's key is the plain "body:index" (face_highlight.gd's original key); edges and vertices are prefixed.
	if kind == "face":
		return "%s:%d" % [body_id, index]
	return "%s:%s:%d" % [kind, body_id, index]


static func face_entity(part: Node3D, face_index: int) -> Dictionary:
	var ref := MeshIdentity.subshape_ref_for_hit(part, face_index)
	if ref.is_empty():
		return {}
	return {"kind": "face", "body_id": str(ref["body_id"]), "index": int(ref["index"]), "face_index": face_index,
		"key": entity_key("face", str(ref["body_id"]), int(ref["index"]))}


static func reach_for(part: MeshInstance3D, hit_distance: float) -> float:
	## World-space reach for a hit this far from the laser.
	var reach := clampf(hit_distance * REACH_PER_METRE, REACH_MIN, REACH_MAX)
	if part != null and part.mesh != null:
		var size: Vector3 = part.get_aabb().size * part.global_transform.basis.get_scale()
		var dims := [size.x, size.y, size.z]
		dims.sort()
		reach = minf(reach, maxf(float(dims[1]) * PART_SIZE_FRACTION, 0.0005))
	return reach


static func pick(part: Node3D, face_index: int, world_point: Vector3, world_reach: float, mates_only: bool = false) -> Dictionary:
	## The entity a pick at `world_point` (on triangle `face_index` of `part`) takes. {} if the part has no face
	## identity at all. `mates_only`: only edges a mate can use (straight / circular) are candidates.
	var face := face_entity(part, face_index)
	if face.is_empty() or not part.has_meta("topology"):
		return face
	var body: Dictionary = (part.get_meta("topology") as Dictionary).get(face["body_id"], {})
	var face_edges: Array = body.get("face_edges", [])
	var face_id: int = face["index"]
	if face_id < 0 or face_id >= face_edges.size():
		return face
	var scale: float = maxf(part.global_transform.basis.get_scale().x, 0.000001)
	var local: Vector3 = part.global_transform.affine_inverse() * world_point
	var reach := world_reach / scale

	var edges: Dictionary = body["edges"]
	var best_edge := -1
	var best_edge_d := INF
	var best_vertex := -1
	var best_vertex_d := INF
	var vertices: Dictionary = body["vertices"]
	var vertex_at: Dictionary = body["vertex_at"]
	for edge_index in (face_edges[face_id] as PackedInt32Array):
		var pts: PackedVector3Array = edges.get(edge_index, PackedVector3Array())
		if pts.size() < 2:
			continue
		if mates_only and not _edge_mateable(body, edge_index):
			continue
		var d := INF
		for i in range(0, pts.size() - 1, 2):
			d = minf(d, local.distance_to(Geometry3D.get_closest_point_to_segment(local, pts[i], pts[i + 1])))
		if d < best_edge_d:
			best_edge_d = d
			best_edge = edge_index
		for end_point in [pts[0], pts[pts.size() - 1]]:
			var vertex_index: int = vertex_at.get(MeshIdentity.quantise(end_point), -1)
			if vertex_index >= 0:
				var dv := local.distance_to(vertices[vertex_index])
				if dv < best_vertex_d:
					best_vertex_d = dv
					best_vertex = vertex_index

	if best_vertex >= 0 and best_vertex_d <= reach:
		return {"kind": "vertex", "body_id": face["body_id"], "index": best_vertex, "face_index": face_index,
			"key": entity_key("vertex", face["body_id"], best_vertex)}
	if best_edge >= 0 and best_edge_d <= reach * EDGE_REACH_FRACTION:
		return {"kind": "edge", "body_id": face["body_id"], "index": best_edge, "face_index": face_index,
			"key": entity_key("edge", face["body_id"], best_edge)}
	return face


static func _edge_mateable(body: Dictionary, edge_index: int) -> bool:
	var kind: String = (body.get("edge_kinds", {}) as Dictionary).get(edge_index, "")
	return kind == "" or kind == "line" or kind == "circle" # no kind (an older backend): let the solver decide


static func is_mateable(part: Node3D, entity: Dictionary) -> bool:
	## Can a mate use this entity? A vertex always; an edge if straight or circular; a face if planar or
	## cylindrical. Unknown (an older backend with no kinds) counts as yes: the solver then has the last word.
	if entity.is_empty():
		return false
	var kind := str(entity.get("kind", "face"))
	if kind == "vertex":
		return true
	var body: Dictionary = {}
	if part != null and part.has_meta("topology"):
		body = (part.get_meta("topology") as Dictionary).get(str(entity.get("body_id", "")), {})
	if kind == "edge":
		return _edge_mateable(body, int(entity.get("index", -1)))
	var face_kinds: Array = body.get("face_kinds", [])
	var face_id := int(entity.get("index", -1))
	if face_id < 0 or face_id >= face_kinds.size():
		return true
	return str(face_kinds[face_id]) in ["plane", "cylinder"]


static func edge_points(part: Node3D, body_id: String, index: int) -> PackedVector3Array:
	## Part-local segment endpoints (consecutive pairs) of one edge, for drawing its highlight.
	if part == null or not part.has_meta("topology"):
		return PackedVector3Array()
	var body: Dictionary = (part.get_meta("topology") as Dictionary).get(body_id, {})
	return (body.get("edges", {}) as Dictionary).get(index, PackedVector3Array())


static func vertex_point(part: Node3D, body_id: String, index: int) -> Variant:
	## Part-local position of one vertex (null if unknown).
	if part == null or not part.has_meta("topology"):
		return null
	var body: Dictionary = (part.get_meta("topology") as Dictionary).get(body_id, {})
	return (body.get("vertices", {}) as Dictionary).get(index)


static func face_triangles(part: Node3D, body_id: String, face_id: int) -> PackedVector3Array:
	## The corner points (three per triangle, part-local, in the mesh's own winding) of one CAD face, from the same
	## per-triangle face identity the picking ray uses. Empty if the part carries none.
	if not (part is MeshInstance3D) or (part as MeshInstance3D).mesh == null or not part.has_meta("face_ids"):
		return PackedVector3Array()
	var faces := (part as MeshInstance3D).mesh.get_faces()
	var face_ids: Array = part.get_meta("face_ids")
	var body_ids: Array = part.get_meta("body_ids")
	var out := PackedVector3Array()
	for t in mini(mini(face_ids.size(), body_ids.size()), faces.size() / 3):
		if int(face_ids[t]) == face_id and str(body_ids[t]) == body_id:
			out.append(faces[t * 3])
			out.append(faces[t * 3 + 1])
			out.append(faces[t * 3 + 2])
	return out


static func is_planar_face(part: Node3D, body_id: String, face_id: int) -> bool:
	## True if the backend says the face is a plane. An older backend sends no kinds: then the face counts as
	## planar if its triangles all face the same way.
	if part != null and part.has_meta("topology"):
		var body: Dictionary = (part.get_meta("topology") as Dictionary).get(body_id, {})
		var kinds: Array = body.get("face_kinds", [])
		if face_id >= 0 and face_id < kinds.size():
			return str(kinds[face_id]) == "plane"
	var tris := face_triangles(part, body_id, face_id)
	if tris.size() < 3:
		return false
	var first := Vector3.ZERO
	for i in range(0, tris.size() - 2, 3):
		var n := (tris[i + 2] - tris[i]).cross(tris[i + 1] - tris[i])
		if n.length() < 0.0000001:
			continue
		n = n.normalized()
		if first == Vector3.ZERO:
			first = n
		elif first.dot(n) < 0.999:
			return false
	return first != Vector3.ZERO
