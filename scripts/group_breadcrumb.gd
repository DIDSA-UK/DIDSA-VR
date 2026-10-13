extends Node3D
## The laser's assembly-level breadcrumb: hold the trigger on a part that sits in sub-assemblies and a small stack of labels opens at the hit point, the
## part first then each sub-assembly it belongs to, innermost to outermost. Swing the laser over the level you want (it lights up) and let go to take it;
## letting go off the stack keeps the part. It faces the user and is flat, so the hit test is a ray against its plane.

const ROW_H := 0.045 ## metres per row
const WIDTH := 0.34
const FONT := 34

var labels: Array[String] = []
var hovered := 0
var _rows: Array[Label3D] = []
var _backs: Array[MeshInstance3D] = []


static func row_at(local: Vector2, count: int) -> int:
	## Which row a point on the panel (x across, y down from the top edge, metres, panel-local with x from the left edge) is over; -1 outside.
	if local.x < 0.0 or local.x > WIDTH or local.y < 0.0 or local.y >= ROW_H * count:
		return -1
	return clampi(int(local.y / ROW_H), 0, count - 1)


func open(texts: Array, at: Vector3, towards: Vector3, selected: int) -> void:
	labels.clear()
	for t in texts:
		labels.append(str(t))
	hovered = selected
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_rows.clear()
	_backs.clear()
	global_position = at
	_face(towards)
	for i in labels.size():
		var back := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(WIDTH, ROW_H * 0.92)
		back.mesh = q
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.no_depth_test = true
		m.render_priority = 9
		back.material_override = m
		back.position = Vector3(WIDTH * 0.5, -ROW_H * (i + 0.5), 0.0)
		add_child(back)
		_backs.append(back)
		var l := Label3D.new()
		l.text = labels[i]
		l.font_size = FONT
		l.pixel_size = 0.0008
		l.no_depth_test = true
		l.render_priority = 10
		l.outline_size = 8
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		l.position = Vector3(0.012, -ROW_H * (i + 0.5), 0.001)
		l.offset = Vector2(0, 0)
		add_child(l)
		_rows.append(l)
	_paint()


func _face(towards: Vector3) -> void:
	## Turn the panel's +Z to look at `towards` (the user's head), staying upright, with its top-left corner at the hit point.
	var to := towards - global_position
	to.y = 0.0
	if to.length() < 0.001:
		return
	look_at(global_position - to.normalized(), Vector3.UP) # -Z points away from the user, so +Z (the face) looks at them


func point_to_local(ray_origin: Vector3, ray_dir: Vector3) -> Variant:
	## Where the laser meets the panel's plane, in panel coordinates (x from the left edge, y down from the top), or null if it points away.
	var plane := Plane(global_transform.basis.z.normalized(), global_position)
	var hit: Variant = plane.intersects_ray(ray_origin, ray_dir.normalized())
	if hit == null:
		return null
	var local: Vector3 = global_transform.affine_inverse() * (hit as Vector3)
	return Vector2(local.x, -local.y)


func update_aim(ray_origin: Vector3, ray_dir: Vector3) -> int:
	## Lights the row under the laser (or none) and returns its index (-1 for none).
	var local: Variant = point_to_local(ray_origin, ray_dir)
	hovered = row_at(local, labels.size()) if local != null else -1
	_paint()
	return hovered


func _paint() -> void:
	for i in _backs.size():
		var m := _backs[i].material_override as StandardMaterial3D
		m.albedo_color = Color(0.2, 0.7, 0.95, 0.85) if i == hovered else Color(0.04, 0.09, 0.14, 0.7)
		_rows[i].modulate = Color(1, 1, 1) if i == hovered else Color(0.75, 0.88, 0.95)
