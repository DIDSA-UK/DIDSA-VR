extends Node
const RoomClip := preload("res://scripts/room/room_clip.gd")
## Face-, edge- and vertex-level highlighting for the Mates and Measure tools. The laser used to tint the WHOLE mesh under
## it, which says nothing about what a pick would actually take: a pick is one CAD face (the backend's
## `face_ids` / `body_ids` per triangle, see mesh_identity.gd). Now, while one of those tools is on:
##   * HOVER: only the face under the laser lights up (pale yellow), per hand;
##   * PICKED: every face already picked stays lit (first pick cyan, second orange) until the picks are
##     cleared (Clear, tool switched off, a third Measure pick starting afresh, mate created).
## A highlight is a thin extra mesh made of just that face's triangles, nudged a hair off the surface so it
## doesn't z-fight, parented to the part (so it follows every move, hide and scale). Built once per hovered
## face change, from the triangle order the picking raycast already uses (`mesh.get_faces()` matches the
## trimesh collider 1:1, mesh_identity.gd's own finding), never per frame.
##
## Edges and vertices (Measure): the same plumbing lights a picked-to-be EDGE (a thin tube along it) or VERTEX
## (a small ball) instead of a face; what is under the laser is decided by topology_pick.gd. Entities are
## {kind, body_id, index, face_index}; a plain face_index (Mates, and the original API) means a face.
## A part with no backend face identity (a bare local .glb) gets no highlight at all, because a pick on it
## is rejected anyway.

const HOVER_COLOUR := Color(1.0, 0.93, 0.45, 0.55)
const PICK_COLOURS: Array[Color] = [Color(0.25, 0.85, 1.0, 0.55), Color(1.0, 0.62, 0.22, 0.55)] ## the two-pick tools; a Width mate's four picks use them by pair (see `colour_slot`)
const ClipShader := preload("res://shaders/highlight_clip.gdshader")
const ClipGlobals := preload("res://scripts/clip_globals.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const MAX_CACHED_PARTS := 4
const EDGE_RADIUS := 0.0018 ## world metres: the tube drawn along a highlighted edge
const VERTEX_RADIUS := 0.0035 ## world metres: the ball drawn on a highlighted vertex
const LINE_ALPHA := 0.95 ## edges and vertices are thin, so they are drawn nearly opaque
const HOVER_LIFT := 1.8 ## the hover layer sits this much further off the surface than a pick layer, so it shows over a picked face

var _hover := {} ## source (the hand) -> {part, key, node}
var _picks: Array = [] ## [{part, key, node}] in pick order
var _set: Array = [] ## nodes of the design table's multi-entity set (set_set)
var _set_part: Node3D = null
var _cache := {} ## part instance id -> {faces: PackedVector3Array, map: Dictionary key -> PackedInt32Array}
var _cache_order: Array = []
var _hover_material: ShaderMaterial

var _pick_materials: Array[ShaderMaterial] = []


func _init() -> void:
	ClipGlobals.ensure() # the highlight shader reads the clip globals
	_hover_material = _make_material(HOVER_COLOUR)
	_pick_materials = [_make_material(PICK_COLOURS[0]), _make_material(PICK_COLOURS[1])]


static func face_key(part: Node, face_index: int) -> String:
	## "body:face" of the triangle `face_index`, or "" if the part carries no face identity.
	if part == null or not is_instance_valid(part) or face_index < 0 or not part.has_meta("face_ids"):
		return ""
	var face_ids: Array = part.get_meta("face_ids")
	var body_ids: Array = part.get_meta("body_ids")
	if face_index >= face_ids.size() or face_index >= body_ids.size():
		return ""
	return "%s:%d" % [str(body_ids[face_index]), int(face_ids[face_index])]


func set_hover(source: Object, part: Node3D, face_index: int) -> void:
	## `source` is the hand whose laser this is (each hand has its own hover). part == null clears it.
	set_hover_entity(source, part, TopologyPick.face_entity(part, face_index) if part != null else {})


func set_hover_entity(source: Object, part: Node3D, entity: Dictionary) -> void:
	## Like set_hover, but for what the tool would actually pick: a face, an edge or a vertex (topology_pick.gd).
	var key := str(entity.get("key", "")) if part != null and is_instance_valid(part) else ""
	var current: Dictionary = _hover.get(source, {})
	if key == "":
		if not current.is_empty():
			_free_node(current)
			_hover.erase(source)
		return
	if not current.is_empty() and current["part"] == part and current["key"] == key and is_instance_valid(current["node"]):
		return # still the same face: nothing to rebuild
	_free_node(current)
	var node := _build_entity_node(part, entity, _hover_material, HOVER_LIFT)
	_hover[source] = {"part": part, "key": key, "node": node} if node != null else {}
	if node == null:
		_hover.erase(source)


func clear_hover(source: Object) -> void:
	set_hover(source, null, -1)


func set_picks(entries: Array) -> void:
	## entries: [{part, face_index}] or [{part, kind, body_id, index, face_index, key}] in pick order (the tools'
	## picked entities). Replaces every pick highlight.
	for p in _picks:
		_free_node(p)
	_picks.clear()
	for i in entries.size():
		# `colour_slot` (a Width mate's picks: 0, 0, 1, 1 - one colour per pair) says which pick colour an entry takes; the default is its order.
		var slot := int(entries[i].get("colour_slot", i))
		if slot >= PICK_COLOURS.size():
			continue
		var part = entries[i].get("part")
		if part == null or not is_instance_valid(part):
			continue
		var entity: Dictionary = entries[i] if entries[i].has("kind") else TopologyPick.face_entity(part, int(entries[i].get("face_index", -1)))
		var key := str(entity.get("key", ""))
		if key == "":
			continue
		var node := _build_entity_node(part, entity, _pick_materials[slot], 1.0)
		if node != null:
			_picks.append({"part": part, "key": key, "node": node})


func invalidate(part: Node3D) -> void:
	## The part's mesh was replaced (an edit on the design table): forget the triangles cached for it and drop any
	## highlight built on the old ones, so nothing lights up the wrong face.
	if part == null:
		return
	var id := part.get_instance_id()
	_cache.erase(id)
	_cache_order.erase(id)
	for source in _hover.keys():
		if _hover[source].get("part") == part:
			_free_node(_hover[source])
			_hover.erase(source)
	var kept: Array = []
	for p in _picks:
		if p.get("part") == part:
			_free_node(p)
		else:
			kept.append(p)
	_picks = kept
	if _set_part == part:
		clear_set()


func set_set(part: Node3D, entities: Array) -> void:
	## Lights up any NUMBER of faces / edges / vertices of one part in the second pick colour (the design table's
	## "edges to fillet"), replacing the previous set. [] clears it. Separate from hover and from the two-slot picks
	## the Mates / Measure tools use, so neither disturbs the other.
	clear_set()
	if part == null or not is_instance_valid(part):
		return
	_set_part = part
	for entity in entities:
		var node := _build_entity_node(part, entity, _pick_materials[1], 1.0)
		if node != null:
			_set.append(node)


func clear_set() -> void:
	for node in _set:
		if is_instance_valid(node):
			node.queue_free()
	_set.clear()
	_set_part = null


func set_nodes() -> Array:
	return _set.filter(func(n): return is_instance_valid(n))


func hover_key(source: Object) -> String:
	var h: Dictionary = _hover.get(source, {})
	return str(h.get("key", ""))


func hover_node(source: Object) -> MeshInstance3D:
	var h: Dictionary = _hover.get(source, {})
	return h.get("node") if not h.is_empty() and is_instance_valid(h["node"]) else null


func pick_nodes() -> Array:
	var out := []
	for p in _picks:
		if is_instance_valid(p["node"]):
			out.append(p["node"])
	return out


func _free_node(entry: Dictionary) -> void:
	if not entry.is_empty() and is_instance_valid(entry.get("node")):
		entry["node"].queue_free()


func _make_material(colour: Color) -> ShaderMaterial:
	## Clipped by the section plane like the part itself (shaders/highlight_clip.gdshader).
	var m := ShaderMaterial.new()
	m.shader = ClipShader
	m.set_shader_parameter("colour", colour)
	m.render_priority = 3
	return m


func _build_entity_node(part: Node3D, entity: Dictionary, material: ShaderMaterial, lift: float) -> MeshInstance3D:
	match str(entity.get("kind", "face")):
		"edge":
			return _build_edge_node(part, entity, material, lift)
		"curve":
			return _build_curve_node(part, entity, material, lift)
		"vertex":
			return _build_vertex_node(part, entity, material, lift)
	return _build_node(part, str(entity.get("key", "")), material, lift)


func _line_material(material: ShaderMaterial) -> ShaderMaterial:
	var m := material.duplicate() as ShaderMaterial
	var c: Color = material.get_shader_parameter("colour")
	m.set_shader_parameter("colour", Color(c.r, c.g, c.b, LINE_ALPHA))
	m.render_priority = 4
	return m


func _build_edge_node(part: Node3D, entity: Dictionary, material: ShaderMaterial, lift: float) -> MeshInstance3D:
	## A thin square-section tube along the edge's polyline, in the part's own space (so it follows the part).
	var pts := TopologyPick.edge_points(part, str(entity["body_id"]), int(entity["index"]))
	return _tube_node(part, pts, material, lift)


func _build_curve_node(part: Node3D, entity: Dictionary, material: ShaderMaterial, lift: float) -> MeshInstance3D:
	## A sketch curve of an earlier sketch (sketch_picks.gd): the entity carries its own polyline, as pairs of points in the part's space.
	return _tube_node(part, entity.get("points", PackedVector3Array()), material, lift)


func _tube_node(part: Node3D, pts: PackedVector3Array, material: ShaderMaterial, lift: float) -> MeshInstance3D:
	if pts.size() < 2:
		return null
	var scale_x: float = maxf(part.global_transform.basis.get_scale().x, 0.000001)
	var mesh := tube_mesh(pts, EDGE_RADIUS * lift / scale_x)
	if mesh == null:
		return null
	return _attach(part, "EdgeHighlight", mesh, _line_material(material))


static func tube_mesh(pts: PackedVector3Array, r: float) -> ArrayMesh:
	## Square-section tubes along point PAIRS (a, b, a, b...), `r` thick, overshooting each end by r so consecutive segments overlap at the joints.
	var verts := PackedVector3Array()
	for i in range(0, pts.size() - 1, 2):
		var a := pts[i]
		var b := pts[i + 1]
		var dir := b - a
		if dir.length() < 0.0000001:
			continue
		dir = dir.normalized()
		a -= dir * r
		b += dir * r
		var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var u := dir.cross(up).normalized() * r
		var v := dir.cross(u).normalized() * r
		var ring_a := [a + u + v, a - u + v, a - u - v, a + u - v]
		var ring_b := [b + u + v, b - u + v, b - u - v, b + u - v]
		for k in 4:
			var k2 := (k + 1) % 4
			verts.append_array([ring_a[k], ring_b[k], ring_b[k2], ring_a[k], ring_b[k2], ring_a[k2]])
	if verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_vertex_node(part: Node3D, entity: Dictionary, material: ShaderMaterial, lift: float) -> MeshInstance3D:
	var point = TopologyPick.vertex_point(part, str(entity["body_id"]), int(entity["index"]))
	if point == null:
		return null
	var scale_x: float = maxf(part.global_transform.basis.get_scale().x, 0.000001)
	var ball := SphereMesh.new()
	ball.radius = VERTEX_RADIUS * lift / scale_x
	ball.height = ball.radius * 2.0
	ball.radial_segments = 12
	ball.rings = 6
	var node := _attach(part, "VertexHighlight", ball, _line_material(material))
	node.position = point
	return node


func _for_part(part: Node3D, material: ShaderMaterial) -> ShaderMaterial:
	## An overlay on the design table's copy while a sketch is open is clipped to the sketch window too (sketch_clip.gd): its own copy of the
	## material with the switch on, so the material shared with the arena's overlays stays as it is.
	if not bool(part.get_meta("window_clip", false)):
		return material
	var m := material.duplicate() as ShaderMaterial
	m.set_shader_parameter("window_clip", true)
	return m


func _attach(part: Node3D, node_name: String, mesh: Mesh, material: ShaderMaterial) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.set_meta("highlight_kind", node_name.trim_suffix("Highlight").to_lower()) # "edge" / "vertex" (the node's own name is made unique when two sit on one part)
	node.mesh = mesh
	node.material_override = _for_part(part, material)
	node.set_meta("window_clip_adopted", part.has_meta("window_clip")) # already switched on (or not needed): sketch_clip.gd leaves it
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	part.add_child(node)
	RoomClip.sync_node(part, node) # cut by the same room walls as the part it lights
	return node


func _build_node(part: Node3D, key: String, material: ShaderMaterial, lift: float) -> MeshInstance3D:
	var data := _face_data(part)
	if data.is_empty() or not (data["map"] as Dictionary).has(key):
		return null
	var faces: PackedVector3Array = data["faces"]
	var tris: PackedInt32Array = data["map"][key]
	var aabb: AABB = (part as MeshInstance3D).get_aabb()
	var scale_x: float = maxf(part.global_transform.basis.get_scale().x, 0.000001)
	var eps: float = maxf(aabb.size.length() * 0.0008, 0.0004 / scale_x) * lift # a hair off the surface, in the part's own units
	var verts := PackedVector3Array()
	verts.resize(tris.size() * 3)
	var normals := PackedVector3Array()
	normals.resize(tris.size() * 3)
	var w := 0
	for t in tris:
		var a := faces[t * 3]
		var b := faces[t * 3 + 1]
		var c := faces[t * 3 + 2]
		var n := (c - a).cross(b - a) # Godot front faces are clockwise, so this is the outward normal
		n = n.normalized() if n.length() > 0.0000001 else Vector3.UP
		var off := n * eps
		verts[w] = a + off
		verts[w + 1] = b + off
		verts[w + 2] = c + off
		normals[w] = n
		normals[w + 1] = n
		normals[w + 2] = n
		w += 3
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.name = "FaceHighlight"
	node.set_meta("highlight_kind", "face")
	node.mesh = mesh
	node.material_override = _for_part(part, material)
	node.set_meta("window_clip_adopted", part.has_meta("window_clip"))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	part.add_child(node)
	RoomClip.sync_node(part, node)
	return node


func _face_data(part: Node3D) -> Dictionary:
	## The part's triangles and a face-key -> triangle-index map, built once per part (and kept for a few parts).
	if not (part is MeshInstance3D) or (part as MeshInstance3D).mesh == null or not part.has_meta("face_ids"):
		return {}
	var id := part.get_instance_id()
	if _cache.has(id):
		return _cache[id]
	var faces := (part as MeshInstance3D).mesh.get_faces()
	var map := {}
	var face_ids: Array = part.get_meta("face_ids")
	var body_ids: Array = part.get_meta("body_ids")
	var count := mini(mini(face_ids.size(), body_ids.size()), faces.size() / 3)
	for t in count:
		var key := "%s:%d" % [str(body_ids[t]), int(face_ids[t])]
		var list: PackedInt32Array = map.get(key, PackedInt32Array()) # packed arrays are values: write it back
		list.append(t)
		map[key] = list
		var solid_key := TopologyPick.body_key(str(body_ids[t])) # a whole body is lit as every triangle it has
		var solid_list: PackedInt32Array = map.get(solid_key, PackedInt32Array())
		solid_list.append(t)
		map[solid_key] = solid_list
	var data := {"faces": faces, "map": map}
	_cache[id] = data
	_cache_order.append(id)
	while _cache_order.size() > MAX_CACHED_PARTS:
		_cache.erase(_cache_order.pop_front())
	return data
