extends Node
## Face-level highlighting for the Mates and Measure tools. The laser used to tint the WHOLE mesh under
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
## Edges and vertices: the tools can only PICK faces today (docs/backend-api-notes.md: edge/vertex picking
## isn't wired client-side), so only faces are highlighted; the same hover/pick plumbing is where an edge or
## vertex highlight would go once they can be picked.
## A part with no backend face identity (a bare local .glb) gets no highlight at all, because a pick on it
## is rejected anyway.

const HOVER_COLOUR := Color(1.0, 0.93, 0.45, 0.55)
const PICK_COLOURS: Array[Color] = [Color(0.25, 0.85, 1.0, 0.55), Color(1.0, 0.62, 0.22, 0.55)]
const MAX_CACHED_PARTS := 4
const HOVER_LIFT := 1.8 ## the hover layer sits this much further off the surface than a pick layer, so it shows over a picked face

var _hover := {} ## source (the hand) -> {part, key, node}
var _picks: Array = [] ## [{part, key, node}] in pick order
var _cache := {} ## part instance id -> {faces: PackedVector3Array, map: Dictionary key -> PackedInt32Array}
var _cache_order: Array = []
var _hover_material := _make_material(HOVER_COLOUR)
var _pick_materials: Array[StandardMaterial3D] = [_make_material(PICK_COLOURS[0]), _make_material(PICK_COLOURS[1])]


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
	var key := face_key(part, face_index)
	var current: Dictionary = _hover.get(source, {})
	if key == "":
		if not current.is_empty():
			_free_node(current)
			_hover.erase(source)
		return
	if not current.is_empty() and current["part"] == part and current["key"] == key and is_instance_valid(current["node"]):
		return # still the same face: nothing to rebuild
	_free_node(current)
	var node := _build_node(part, key, _hover_material, HOVER_LIFT)
	_hover[source] = {"part": part, "key": key, "node": node} if node != null else {}
	if node == null:
		_hover.erase(source)


func clear_hover(source: Object) -> void:
	set_hover(source, null, -1)


func set_picks(entries: Array) -> void:
	## entries: [{part, face_index}] in pick order (the tools' picked entities). Replaces every pick highlight.
	for p in _picks:
		_free_node(p)
	_picks.clear()
	for i in mini(entries.size(), PICK_COLOURS.size()):
		var part = entries[i].get("part")
		if part == null or not is_instance_valid(part):
			continue
		var key := face_key(part, int(entries[i].get("face_index", -1)))
		if key == "":
			continue
		var node := _build_node(part, key, _pick_materials[i], 1.0)
		if node != null:
			_picks.append({"part": part, "key": key, "node": node})


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


func _make_material(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = colour
	m.render_priority = 3
	return m


func _build_node(part: Node3D, key: String, material: StandardMaterial3D, lift: float) -> MeshInstance3D:
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
	node.mesh = mesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	part.add_child(node)
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
	var data := {"faces": faces, "map": map}
	_cache[id] = data
	_cache_order.append(id)
	while _cache_order.size() > MAX_CACHED_PARTS:
		_cache.erase(_cache_order.pop_front())
	return data
