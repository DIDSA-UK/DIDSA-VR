extends Node3D
## The lines and curves of the part's FINISHED sketches, drawn on the table's copy and offered to the laser (Phase 5.4): what a Loft takes as
## sections, a Sweep as its path and a Pattern as a direction. A child of the copy, so it moves with it. Each sketch is read once with a
## read-only SketchSession (its points and entities; nothing is made), in the sketch's own plane, and every non-helper line, circle and arc is a
## candidate: {kind: "curve", sketch_feature_id, sketch_id, entity_type, entity_id, points (pairs, in the part's space), key}.
## A Build tree row can leave its sketch out (set_included), so a busy part can be narrowed down to the sketch you mean.

const SketchSession := preload("res://scripts/design_table/sketch_session.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const SketchView := preload("res://scripts/design_table/sketch_view.gd")
const FaceHighlight := preload("res://scripts/face_highlight.gd")

const ARC_SEGMENTS := 24
const CIRCLE_SEGMENTS := 48
const TUBE_RADIUS := 0.0010 ## world metres
const BASE_COLOUR := Color(0.31, 0.77, 1.00, 0.85)

var curves: Array = [] ## candidate entities (see above)
var sketches: Dictionary = {} ## sketch feature id -> {sketch_id, plane, count, included, closed (it holds a closed profile an extrude can use)}
var tints: Dictionary = {} ## sketch feature id -> PackedVector3Array of triangles filling its closed loops (a cue for a sketch used as a seed, not a pick)
var tint_on := false
var _tint_node: MeshInstance3D = null
var _tint_material: StandardMaterial3D
var _node: MeshInstance3D = null
var _material: StandardMaterial3D
var _scale := 1.0


func _init() -> void:
	name = "SketchPicks"
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = BASE_COLOUR
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = false
	_tint_material = StandardMaterial3D.new()
	_tint_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_tint_material.albedo_color = Color(0.31, 0.77, 1.00, 0.22)
	_tint_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_tint_material.cull_mode = BaseMaterial3D.CULL_DISABLED


func load_sketches(call: Callable, part_id: String, rows: Array, plane_for: Callable, skip_feature_id: String = "") -> int:
	## `rows`: the Build tree's feature rows; `plane_for`: Callable(row) -> the sketch's plane basis in the part's frame, or {} when it can't be
	## placed (a flipped or turned sketch: left out, as reopening one is). Returns how many curves can be picked.
	curves.clear()
	sketches.clear()
	tints.clear()
	for row in rows:
		if str(row.get("type", "")) != "sketch" or str(row.get("id", "")) == skip_feature_id or str(row.get("sketch_id", "")) == "":
			continue
		var plane: Dictionary = await plane_for.call(row)
		if plane.is_empty():
			continue
		var session := SketchSession.new(call)
		session.owner_part_id = part_id
		if not await session.reopen(row, plane):
			continue
		var count := 0
		for id in session.lines:
			count += _add_line(session, row, id, plane)
		for id in session.circles:
			count += _add_circle(session, row, id, plane)
		for id in session.arcs:
			count += _add_arc(session, row, id, plane)
		sketches[str(row["id"])] = {"sketch_id": str(row["sketch_id"]), "plane": plane, "count": count, "included": true, "closed": session.profile_ok()}
		tints[str(row["id"])] = _tint_triangles(session, plane)
	_redraw()
	return curves.size()


func _tint_triangles(session, plane: Dictionary) -> PackedVector3Array:
	## The closed loops of a sketch (circles, and chains of lines and arcs that end where they began) filled with triangles in the part's frame.
	## Construction and reference shapes are not part of a profile. Nested loops are each filled (it is a cue); a chain that does not close is left out.
	var out := PackedVector3Array()
	var normal: Vector3 = (plane["n"] as Vector3) * 0.02 # a hair off the plane so the fill does not fight a face the sketch lies on
	for uvs in _loops(session):
		var tri: PackedInt32Array = Geometry2D.triangulate_polygon(PackedVector2Array(uvs))
		for i in tri:
			out.append(SketchMath.from_sheet(uvs[i], plane) + normal)
	return out


func _loops(session) -> Array:
	var loops: Array = []
	for id in session.circles:
		var c: Dictionary = session.circles[id]
		if session.is_reference(id) or bool(c.get("construction", false)) or not session.points.has(c["c"]) or not session.points.has(c["p"]):
			continue
		var centre: Vector2 = session.points[c["c"]]
		var radius := centre.distance_to(session.points[c["p"]])
		var ring: Array = []
		for i in CIRCLE_SEGMENTS:
			var a := TAU * float(i) / float(CIRCLE_SEGMENTS)
			ring.append(centre + Vector2(cos(a), sin(a)) * radius)
		loops.append(ring)
	var segs: Array = [] # [point a, point b, polyline from a to b]
	for id in session.lines:
		var l: Dictionary = session.lines[id]
		if session.is_reference(id) or bool(l.get("construction", false)) or not session.points.has(l["a"]) or not session.points.has(l["b"]):
			continue
		segs.append([str(l["a"]), str(l["b"]), [session.points[l["a"]], session.points[l["b"]]]])
	for id in session.arcs:
		var a: Dictionary = session.arcs[id]
		if session.is_reference(id) or bool(a.get("construction", false)) or not session.points.has(a["c"]) or not session.points.has(a["s"]) or not session.points.has(a["e"]):
			continue
		segs.append([str(a["s"]), str(a["e"]), SketchView.arc_points(session.points[a["c"]], session.points[a["s"]], session.points[a["e"]], ARC_SEGMENTS)])
	var at := {} # point id -> the segments that end there
	for i in segs.size():
		for end in [segs[i][0], segs[i][1]]:
			if not at.has(end):
				at[end] = []
			(at[end] as Array).append(i)
	var used := {}
	for i in segs.size():
		if used.has(i):
			continue
		used[i] = true
		var start: String = segs[i][0]
		var here: String = segs[i][1]
		var poly: Array = (segs[i][2] as Array).duplicate()
		var closed := false
		while true:
			if here == start:
				closed = true
				break
			var next := -1
			for j in at.get(here, []):
				if not used.has(j):
					next = j
					break
			if next < 0:
				break
			used[next] = true
			var seg: Array = segs[next]
			var line: Array = (seg[2] as Array).duplicate()
			if seg[0] != here:
				line.reverse()
				here = seg[0]
			else:
				here = seg[1]
			poly.append_array(line.slice(1))
		if closed and poly.size() >= 4:
			poly.pop_back() # the last point repeats the first
			loops.append(poly)
	return loops


func set_tint(on: bool) -> void:
	tint_on = on
	_redraw_tint()


func _redraw_tint() -> void:
	if _tint_node != null and is_instance_valid(_tint_node):
		remove_child(_tint_node) # out of the tree now, so the new node can take the name
		_tint_node.queue_free()
	_tint_node = null
	if not tint_on:
		return
	var all := PackedVector3Array()
	for id in tints:
		if bool(sketches.get(id, {}).get("included", false)) and bool(sketches[id].get("closed", false)):
			all.append_array(tints[id])
	if all.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = all
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_tint_node = MeshInstance3D.new()
	_tint_node.name = "SketchTint"
	_tint_node.mesh = mesh
	_tint_node.material_override = _tint_material
	_tint_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_tint_node)


func _add_line(session, row: Dictionary, id: String, plane: Dictionary) -> int:
	var l: Dictionary = session.lines[id]
	if session.is_reference(id) or not session.points.has(l["a"]) or not session.points.has(l["b"]):
		return 0
	var pts := PackedVector3Array([SketchMath.from_sheet(session.points[l["a"]], plane), SketchMath.from_sheet(session.points[l["b"]], plane)])
	_add(row, "line", id, pts)
	return 1


func _add_circle(session, row: Dictionary, id: String, plane: Dictionary) -> int:
	var c: Dictionary = session.circles[id]
	if session.is_reference(id) or not session.points.has(c["c"]) or not session.points.has(c["p"]):
		return 0
	var centre: Vector2 = session.points[c["c"]]
	var radius := centre.distance_to(session.points[c["p"]])
	var ring: Array = []
	for i in CIRCLE_SEGMENTS + 1:
		var a := TAU * float(i) / float(CIRCLE_SEGMENTS)
		ring.append(centre + Vector2(cos(a), sin(a)) * radius)
	_add(row, "circle", id, _pairs(ring, plane))
	return 1


func _add_arc(session, row: Dictionary, id: String, plane: Dictionary) -> int:
	var a: Dictionary = session.arcs[id]
	if session.is_reference(id) or not session.points.has(a["c"]) or not session.points.has(a["s"]) or not session.points.has(a["e"]):
		return 0
	_add(row, "arc", id, _pairs(SketchView.arc_points(session.points[a["c"]], session.points[a["s"]], session.points[a["e"]], ARC_SEGMENTS), plane))
	return 1


func _pairs(uvs: Array, plane: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in uvs.size() - 1:
		out.append(SketchMath.from_sheet(uvs[i], plane))
		out.append(SketchMath.from_sheet(uvs[i + 1], plane))
	return out


func _add(row: Dictionary, type: String, id: String, pts: PackedVector3Array) -> void:
	curves.append({"kind": "curve", "sketch_feature_id": str(row["id"]), "sketch_id": str(row["sketch_id"]), "entity_type": type, "entity_id": id,
		"points": pts, "key": "curve:%s:%s" % [row["sketch_id"], id]})


func set_included(feature_id: String, included: bool) -> void:
	if sketches.has(feature_id):
		sketches[feature_id]["included"] = included
		_redraw()


func apply_hidden(hidden_feature_ids: Array) -> void:
	## At rest: draw the sketches the Visibility model shows (every one not in the hidden list). One redraw, only when something changed.
	var changed := false
	for id in sketches:
		var want := not hidden_feature_ids.has(id)
		if bool(sketches[id]["included"]) != want:
			sketches[id]["included"] = want
			changed = true
	if changed:
		_redraw()


func candidates() -> Array:
	return curves.filter(func(c): return bool(sketches.get(str(c["sketch_feature_id"]), {}).get("included", false)))


func entity_ref(entity: Dictionary) -> Dictionary:
	## The backend's SketchEntityRef for a picked curve.
	return {"sketch_id": str(entity["sketch_id"]), "entity_type": str(entity["entity_type"]), "entity_id": str(entity["entity_id"])}


func nearest(world_origin: Vector3, world_dir: Vector3, reach_world: float) -> Dictionary:
	## The candidate whose polyline passes closest to the laser, within `reach_world` metres of it (the same reach idea as topology_pick.gd's);
	## ties go to the nearer along the ray. {} if none.
	var parent := get_parent() as Node3D
	if parent == null:
		return {}
	var inverse: Transform3D = parent.global_transform.affine_inverse()
	var o: Vector3 = inverse * world_origin
	var far: Vector3 = inverse * (world_origin + world_dir * 8.0)
	var scale_x: float = maxf(parent.global_transform.basis.get_scale().x, 0.000001)
	var reach := reach_world / scale_x
	var best := {}
	var best_d := reach
	for c in candidates():
		var pts: PackedVector3Array = c["points"]
		for i in range(0, pts.size() - 1, 2):
			var pair := Geometry3D.get_closest_points_between_segments(o, far, pts[i], pts[i + 1])
			var d: float = pair[0].distance_to(pair[1])
			if d < best_d:
				best_d = d
				best = c.duplicate()
				best["distance"] = o.distance_to(pair[0]) * scale_x
	return best


func _redraw() -> void:
	_redraw_tint()
	if _node != null and is_instance_valid(_node):
		_node.queue_free()
	_node = null
	var all := PackedVector3Array()
	for c in candidates():
		all.append_array(c["points"])
	var parent := get_parent() as Node3D
	var scale_x: float = maxf(parent.global_transform.basis.get_scale().x, 0.000001) if parent != null else 1.0
	var mesh := FaceHighlight.tube_mesh(all, TUBE_RADIUS / scale_x)
	if mesh == null:
		return
	_node = MeshInstance3D.new()
	_node.name = "SketchCurves"
	_node.mesh = mesh
	_node.material_override = _material
	_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_node)


func clear() -> void:
	curves.clear()
	sketches.clear()
	tints.clear()
	if _node != null and is_instance_valid(_node):
		_node.queue_free()
	_node = null
	if _tint_node != null and is_instance_valid(_tint_node):
		_tint_node.queue_free()
	_tint_node = null
