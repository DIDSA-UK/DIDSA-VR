extends RefCounted
## How a resolved appearance looks on a part (DIDSA-CAD `docs/appearance-tool-scope.md` section 2, D7): the Godot material for
## one appearance, and restyling a placed part so it shows what the rule resolves for each of its faces.
##
## The glb already carries these materials (the backend paints them with the same rule): a freshly loaded part needs nothing
## from here. This is for what changes on screen without a reload: a paint applied, a row of the paint breadcrumb previewed,
## the sandbox's temporary paint, an undo.
##
## material_for() matches what Godot's glTF importer makes of the backend's material (measured: the importer turns the
## linear factor back into the picked sRGB colour, so a hex colour is used as it is here; opacity below 1 is alpha with a
## depth pre-pass, so a see-through part does not show its own back faces; glow is emission with its strength as the energy).
##
## restyle(): one appearance for the whole part sets `material_override` (no mesh change; nothing painted = plain(), the importer's
## default look). Faces that differ rebuild the
## part's mesh with one surface per appearance and keep everything that reads triangles in step: the `face_ids` / `body_ids`
## metas follow the new triangle order (mesh.get_faces() order, which the trimesh collider and face_highlight.gd use), and
## the collider is rebuilt. While a room or the section tool is open their clip shader wears the part (room_clip.gd,
## section_tool.gd): it shows one base colour per part, as it always has.

const Rule := preload("res://scripts/appearance/appearance_rule.gd")

const SIGNATURE := "appearance_signature" ## meta: the grouping a split mesh was last built for ("" = not split by this script)


static func colour_of(hex: String, alpha: float = 1.0) -> Color:
	## "#RRGGBB" as picked (sRGB): Godot's albedo is sRGB too, so no conversion.
	var c := Color.html(hex) if Rule.is_hex(hex) else Color(0.78, 0.78, 0.78)
	c.a = alpha
	return c


static var _plain: StandardMaterial3D = null


static func plain() -> StandardMaterial3D:
	## Nothing painted: the look Godot's glTF importer gives a primitive with no material (white, fully rough, not metallic).
	if _plain == null:
		_plain = StandardMaterial3D.new()
		_plain.roughness = 1.0
	return _plain


static func material_for(appearance: Dictionary) -> StandardMaterial3D:
	## The material for one resolved appearance, or null for {} (nothing set: the renderer's own default, as a glb part with no
	## material shows). Unset fields take the backend's default look (DIDSA-CAD `appearance.DEFAULT_LOOK`).
	if appearance.is_empty():
		return null
	var opacity := float(appearance.get("opacity", 1.0))
	var m := StandardMaterial3D.new()
	m.albedo_color = colour_of(str(appearance.get("colour", "#C8C8C8")), opacity)
	m.metallic = float(appearance.get("metallic", 0.0))
	m.roughness = float(appearance.get("roughness", 0.8))
	if opacity < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	var strength = appearance.get("emission_strength")
	if appearance.get("emission") != null or strength != null:
		var energy := 1.0 if strength == null else float(strength)
		if energy > 0.0:
			m.emission_enabled = true
			m.emission = colour_of(str(appearance.get("emission", appearance.get("colour", "#C8C8C8"))))
			m.emission_energy_multiplier = energy
	return m


static func triangle_keys(part: MeshInstance3D) -> PackedStringArray:
	## "body:face" of every triangle, in mesh.get_faces() order (empty if the part has no face identity).
	var out := PackedStringArray()
	if not part.has_meta("face_ids") or not part.has_meta("body_ids"):
		return out
	var face_ids: Array = part.get_meta("face_ids")
	var body_ids: Array = part.get_meta("body_ids")
	for t in mini(face_ids.size(), body_ids.size()):
		out.append(Rule.face_key(body_ids[t], face_ids[t]))
	return out


static func faces_of(part: MeshInstance3D) -> Array:
	## The distinct [body_id, face index] pairs of the part (what Rule.resolve_faces takes).
	var seen := {}
	var out: Array = []
	if not part.has_meta("face_ids"):
		return out
	var face_ids: Array = part.get_meta("face_ids")
	var body_ids: Array = part.get_meta("body_ids")
	for t in mini(face_ids.size(), body_ids.size()):
		var key := Rule.face_key(body_ids[t], face_ids[t])
		if not seen.has(key):
			seen[key] = true
			out.append([str(body_ids[t]), int(face_ids[t])])
	return out


static func restyle(part: MeshInstance3D, by_face: Dictionary, whole: Dictionary) -> bool:
	## Shows `by_face` ("body:face" -> appearance, Rule.resolve_faces) on the part; `whole` is for a part with no face identity
	## (and for any face by_face doesn't name). Returns true if the mesh was rebuilt (callers drop caches built on the old one).
	var keys := triangle_keys(part)
	var groups := {} ## appearance key -> {appearance, tris}
	var order: Array = []
	for t in keys.size():
		var a: Dictionary = by_face.get(keys[t], whole)
		var k := Rule.key_of(a)
		if not groups.has(k):
			groups[k] = {"appearance": a, "tris": PackedInt32Array()}
			order.append(k)
		var tris: PackedInt32Array = groups[k]["tris"]
		tris.append(t)
		groups[k]["tris"] = tris
	if groups.size() <= 1:
		# One look for the whole part: an override over every surface (a mesh the glb or an earlier paint split keeps its surfaces;
		# nothing is rebuilt, so ending a preview over the whole assembly costs no collider rebuilds).
		var a: Dictionary = whole if groups.is_empty() else groups[order[0]]["appearance"]
		part.material_override = material_for(a) if not a.is_empty() else plain()
		return false
	part.material_override = null
	var signature_parts: PackedStringArray = []
	var plan: Array = []
	for k in order:
		signature_parts.append("%s#%d" % [k, (groups[k]["tris"] as PackedInt32Array).size()])
		plan.append(groups[k])
	var signature := "|".join(signature_parts)
	if str(part.get_meta(SIGNATURE, "")) == signature:
		return false # already split this way
	_rebuild(part, plan, signature)
	return true


static func _triangles(mesh: Mesh) -> Dictionary:
	## Every triangle's corners and normals in get_faces() order (surfaces one after another, indices expanded).
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := idx.size() if not idx.is_empty() else v.size()
		for i in count:
			var j := idx[i] if not idx.is_empty() else i
			verts.append(v[j])
			normals.append(n[j] if j < n.size() else Vector3.UP)
	return {"verts": verts, "normals": normals}


static func _rebuild(part: MeshInstance3D, plan: Array, signature: String) -> void:
	## A new mesh with one surface per entry of `plan` ({appearance, tris}), the face identity metas in the new order, and a new
	## collider (picking reads the collider's triangle order).
	var source := _triangles(part.mesh)
	var verts: PackedVector3Array = source["verts"]
	var normals: PackedVector3Array = source["normals"]
	var face_ids: Array = part.get_meta("face_ids", [])
	var body_ids: Array = part.get_meta("body_ids", [])
	var new_faces: Array = []
	var new_bodies: Array = []
	var mesh := ArrayMesh.new()
	for entry in plan:
		var tris: PackedInt32Array = entry["tris"]
		var v := PackedVector3Array()
		var n := PackedVector3Array()
		for t in tris:
			if t * 3 + 2 >= verts.size():
				continue
			for c in 3:
				v.append(verts[t * 3 + c])
				n.append(normals[t * 3 + c])
			new_faces.append(face_ids[t] if t < face_ids.size() else 0)
			new_bodies.append(body_ids[t] if t < body_ids.size() else "")
		if v.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = n
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := material_for(entry["appearance"])
		mesh.surface_set_material(mesh.get_surface_count() - 1, material if material != null else plain())
	part.mesh = mesh
	if part.has_meta("face_ids"):
		part.set_meta("face_ids", new_faces)
		part.set_meta("body_ids", new_bodies)
	part.set_meta(SIGNATURE, signature)
	for child in part.get_children():
		if child is StaticBody3D:
			part.remove_child(child)
			child.free()
	part.create_trimesh_collision()
