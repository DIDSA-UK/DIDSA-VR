extends RefCounted
## Dragging the design table's slab to a new size by its corners, the same gesture the floating windows use
## (scripts/diegetic_panel.gd): four corner brackets just outside the slab's corners, dim at rest, bright and a
## little larger while the right laser is on one or it is being dragged. Aim at one, hold the trigger and drag; the
## OPPOSITE corner stays put and the console's origin moves to the middle of the new rectangle. The brackets follow the
## slab's rounded corners (a quarter-circle with a short straight arm either side), so they hug the glass.
##
## While a bracket is aimed at it claims the shared "ui_hover" / "ui_hit_distance" meta like any panel, so the trigger
## never also selects a part and the laser stops on it; the claim is only taken if nothing else (the deck) has it this
## frame. The deck, the tree and the handle are laid out from the slab's size by design_table.gd (set_slab_size()).

const CORNER_DIRS: Array[Vector2] = [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)] ## (x, z) signs in the console frame: back-left, back-right, front-left, front-right
const INSET := 0.008 ## metres the hit zone reaches back inside the slab's edge
const GAP := 0.012 ## metres between the glass and the bracket
const ARM := 0.05 ## the straight arms either side of the arc
const THICKNESS := 0.010
const DOT_RADIUS := 0.010 ## metres: the point at each corner, big enough to find against the curved glass edge
const LIFT := 0.003 ## metres above the slab's plane

var min_size := Vector2(0.50, 0.30) ## metres, x by z
var max_size := Vector2(1.40, 1.00)
var reach := 0.10 ## metres outward from a corner (along both edges) that counts as aiming at it
var hover := -1
var dragging := -1

var _table ## design_table.gd
var _holders: Array[Node3D] = []
var _materials: Array[StandardMaterial3D] = []
var _dot_materials: Array[StandardMaterial3D] = [] ## the small point at each corner of the slab's rectangle: what you aim at
var _idle := Color(0.82, 0.85, 0.9, 0.55)
var _hot := Color(0.35, 0.85, 1.0, 1.0)


func setup(table) -> void:
	_table = table
	table._right.button_pressed.connect(_on_pressed)
	table._right.button_released.connect(_on_released)
	_build()
	restyle()
	layout()


func restyle() -> void:
	var tokens: Resource = _table.tokens
	_idle = tokens.border.lightened(0.3)
	_idle.a = 0.55
	_hot = tokens.accent
	_refresh_look()


func layout() -> void:
	## Puts each bracket at its corner of the slab (after the slab was resized), with the radius of the slab's rounded corners.
	var half: Vector2 = _table.slab_size * 0.5
	for i in _holders.size():
		var dir := CORNER_DIRS[i]
		_holders[i].position = Vector3(dir.x * half.x, LIFT, dir.y * half.y)
		_holders[i].scale = Vector3(dir.x, 1.0, dir.y) * (1.4 if (i == hover or i == dragging) else 1.0)


func cancel() -> void:
	dragging = -1
	_set_hover(-1)


# --- Per frame ----------------------------------------------------------------------------

func process() -> void:
	## Called by the table every frame while it is open, after the deck has had its chance to claim the laser.
	var right: XRController3D = _table._right
	if dragging >= 0:
		_drag(right)
		return
	var corner := -1
	var distance := -1.0
	if not _table.surface.hovering and not _table.surface.pressed and not _table.manip.is_gripping():
		var hit = _plane_hit(right)
		if hit != null and right.global_position.distance_to(hit) <= _table.max_point_distance:
			var local: Vector3 = _table.global_transform.affine_inverse() * hit
			var half: Vector2 = _table.slab_size * 0.5
			if absf(local.x) > half.x or absf(local.z) > half.y:
				corner = corner_at(Vector2(local.x, local.z), _table.slab_size)
				distance = right.global_position.distance_to(hit)
	if corner >= 0 and not bool(right.get_meta("ui_hover", false)):
		right.set_meta("ui_hover", true)
		right.set_meta("ui_hit_distance", distance)
	else:
		corner = -1
	_set_hover(corner)


func _plane_hit(right: XRController3D) -> Variant:
	var basis: Basis = _table.global_transform.basis
	return Plane(basis.y.normalized(), _table.global_position).intersects_ray(right.global_position, -right.global_transform.basis.z.normalized())


static func corner_at(p: Vector2, slab_size: Vector2, hit_reach: float = 0.10) -> int:
	## Which corner's outward hit zone (a `hit_reach` square reaching INSET back inside the edge) `p` (console x, z) is in; -1
	## if none. Nearest wins if zones overlap on a tiny slab.
	var best := -1
	var best_d := INF
	for i in CORNER_DIRS.size():
		var dir := CORNER_DIRS[i]
		var corner := Vector2(dir.x * slab_size.x * 0.5, dir.y * slab_size.y * 0.5)
		var rel := (p - corner) * dir # outward-positive along both axes
		if rel.x >= -INSET and rel.x <= hit_reach and rel.y >= -INSET and rel.y <= hit_reach:
			if rel.length() < best_d:
				best_d = rel.length()
				best = i
	return best


static func dragged(local: Vector2, slab_size: Vector2, dir: Vector2, lo: Vector2, hi: Vector2) -> Dictionary:
	## One frame of a corner drag: the corner opposite `dir` stays put, the dragged one goes to `local` (console x, z), the size
	## is clamped. Returns {size, shift}: the new size and how far the slab's middle moved (console frame).
	var fixed := Vector2(-dir.x * slab_size.x * 0.5, -dir.y * slab_size.y * 0.5)
	var wanted := Vector2((local.x - fixed.x) * dir.x, (local.y - fixed.y) * dir.y)
	var new_size := wanted.clamp(lo, hi)
	var moved := fixed + Vector2(dir.x * new_size.x, dir.y * new_size.y)
	return {"size": new_size, "shift": (fixed + moved) * 0.5}


func _drag(right: XRController3D) -> void:
	right.set_meta("ui_hover", true) # the trigger and stick belong to this drag until it ends
	var hit = _plane_hit(right)
	right.set_meta("ui_hit_distance", right.global_position.distance_to(hit) if hit != null else -1.0)
	if hit == null:
		return
	var local: Vector3 = _table.global_transform.affine_inverse() * hit
	var step := dragged(Vector2(local.x, local.z), _table.slab_size, CORNER_DIRS[dragging], min_size, max_size)
	var shift: Vector2 = step["shift"]
	_table.global_position += _table.global_transform.basis * Vector3(shift.x, 0.0, shift.y)
	_table.set_slab_size(step["size"])


func _on_pressed(action_name: String) -> void:
	if action_name == _table.click_action and hover >= 0 and _table.is_open() and not _table.surface.hovering and _table.handle.held_by == null:
		dragging = hover
		_table._right.trigger_haptic_pulse("haptic", 0.0, 0.4, 0.05, 0.0)
		_refresh_look()
		layout()


func _on_released(action_name: String) -> void:
	if action_name == _table.click_action and dragging >= 0:
		dragging = -1
		_refresh_look()
		layout()
		_table.remember_layout()


# --- Looks --------------------------------------------------------------------------------

func _set_hover(index: int) -> void:
	if index == hover:
		return
	hover = index
	_refresh_look()
	layout()


func _refresh_look() -> void:
	for i in _materials.size():
		var hot := i == hover or i == dragging
		_materials[i].albedo_color = _hot if hot else _idle
		if i < _dot_materials.size():
			_dot_materials[i].albedo_color = Color.WHITE if hot else _hot.lightened(0.15)


func _build() -> void:
	var mesh := _bracket_mesh(_table.slab_radius + GAP * 0.0, GAP, ARM, THICKNESS)
	for i in CORNER_DIRS.size():
		var holder := Node3D.new()
		holder.name = "ResizeCorner%d" % i
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.render_priority = 2
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = material
		holder.add_child(instance)
		# The corner point: the slab's rounded corner leaves nothing at the rectangle's corner to aim at, so a small bright dot sits there.
		var dot_material := StandardMaterial3D.new()
		dot_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dot_material.render_priority = 3
		var sphere := SphereMesh.new()
		sphere.radius = DOT_RADIUS
		sphere.height = DOT_RADIUS * 2.0
		sphere.radial_segments = 16
		sphere.rings = 8
		sphere.material = dot_material
		var dot := MeshInstance3D.new()
		dot.name = "CornerDot"
		dot.mesh = sphere
		holder.add_child(dot)
		_dot_materials.append(dot_material)
		_table.add_child(holder)
		_holders.append(holder)
		_materials.append(material)


static func _bracket_mesh(corner_radius: float, gap: float, arm: float, thickness: float) -> ArrayMesh:
	## One bracket for the front-right corner (+x, +z), built with the slab's corner point at the origin: a straight arm along
	## the front edge, a quarter circle round the rounded corner, a straight arm down the side. Flat in the XZ plane.
	var r := corner_radius
	var centre := Vector2(-r, -r) # the corner arc's centre, inside the corner
	var points: Array[Vector2] = []
	var normals: Array[Vector2] = []
	points.append(Vector2(centre.x - arm, gap))
	normals.append(Vector2(0, 1))
	points.append(Vector2(centre.x, gap))
	normals.append(Vector2(0, 1))
	var steps := 10
	for s in range(1, steps):
		var angle := PI * 0.5 * (1.0 - float(s) / float(steps))
		var n := Vector2(cos(angle), sin(angle))
		points.append(centre + n * (r + gap))
		normals.append(n)
	points.append(Vector2(gap, centre.y))
	normals.append(Vector2(1, 0))
	points.append(Vector2(gap, centre.y - arm))
	normals.append(Vector2(1, 0))
	var vertices := PackedVector3Array()
	for i in points.size():
		var a := points[i] + normals[i] * thickness * 0.5
		var b := points[i] - normals[i] * thickness * 0.5
		vertices.append(Vector3(a.x, 0.0, a.y))
		vertices.append(Vector3(b.x, 0.0, b.y))
	var indices := PackedInt32Array()
	for i in points.size() - 1:
		var k := i * 2
		indices.append_array([k, k + 1, k + 2, k + 1, k + 3, k + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
