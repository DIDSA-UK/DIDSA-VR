extends RefCounted
## Building the line geometry for a part's edges: pure functions, no scene tree, so tests can pin them (tests/view_modes.gd).
##
## The real thing: the backend's own B-rep edges. assembly-mesh.glb carries them per body in the primitive extras (`topology`, read into
## the node's "topology" meta by mesh_identity.gd): body id -> {edges: {index: PackedVector3Array of consecutive segment endpoints}}.
## They are what the flat app draws in Shaded + edges and Wireframe. A model with no topology (a bare local .glb) falls back to
## SHARP-ANGLE edges found from the mesh itself (a boundary edge, or one where two faces meet at more than ANGLE_DEGREES): approximate,
## and capped in size.

const ANGLE_DEGREES := 30.0
const MAX_TRIANGLES := 200000 ## the mesh fallback is skipped beyond this (it runs on the main thread, once)


static func lines_from_topology(topology: Dictionary) -> PackedVector3Array:
	## Every edge of every body as one flat list of segment endpoints (pairs), in the part's own frame.
	var out := PackedVector3Array()
	for body_id in topology:
		var edges: Dictionary = (topology[body_id] as Dictionary).get("edges", {})
		for index in edges:
			out.append_array(edges[index] as PackedVector3Array)
	return out


static func lines_from_mesh(mesh: Mesh, angle_degrees: float = ANGLE_DEGREES) -> PackedVector3Array:
	## Sharp-angle and boundary edges of a triangle mesh, welded by position. Empty if there is no mesh or it is too big.
	var out := PackedVector3Array()
	if mesh == null:
		return out
	var faces: PackedVector3Array = mesh.get_faces() # every triangle's three corners, in order
	var triangles := faces.size() / 3
	if triangles == 0 or triangles > MAX_TRIANGLES:
		return out
	var cos_limit := cos(deg_to_rad(angle_degrees))
	var edge_normals := {} # edge key -> [first normal, second normal or null, a, b, count]
	for t in triangles:
		var a := faces[t * 3]
		var b := faces[t * 3 + 1]
		var c := faces[t * 3 + 2]
		var normal := (b - a).cross(c - a)
		if normal.length() < 0.0000001:
			continue
		normal = normal.normalized()
		for pair in [[a, b], [b, c], [c, a]]:
			var key := _edge_key(pair[0], pair[1])
			if edge_normals.has(key):
				var entry: Array = edge_normals[key]
				entry[4] += 1
				if entry[1] == null:
					entry[1] = normal
			else:
				edge_normals[key] = [normal, null, pair[0], pair[1], 1]
	for key in edge_normals:
		var e: Array = edge_normals[key]
		var sharp: bool = e[4] == 1 or e[4] > 2 or e[1] == null or (e[0] as Vector3).dot(e[1]) < cos_limit
		if sharp:
			out.append(e[2])
			out.append(e[3])
	return out


static func _edge_key(a: Vector3, b: Vector3) -> String:
	var ka := _vertex_key(a)
	var kb := _vertex_key(b)
	return "%s|%s" % [ka, kb] if ka < kb else "%s|%s" % [kb, ka]


static func _vertex_key(v: Vector3) -> String:
	return "%d,%d,%d" % [roundi(v.x * 1000.0), roundi(v.y * 1000.0), roundi(v.z * 1000.0)]


static func build_mesh(lines: PackedVector3Array) -> ArrayMesh:
	## A lines mesh from segment endpoints (pairs). Null for none.
	if lines.size() < 2:
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh
