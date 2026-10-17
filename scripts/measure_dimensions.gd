extends Node3D
## Measure results drawn IN the world, like a dimension on an engineering drawing: a linear dimension (a line
## between the two picked points with end ticks and its value), or a radius / diameter callout hung off the
## picked point. Volume, area and mass don't fit on a line; they stay on the tablet, which opens by itself
## when the tool is switched on from the tool wheel (main.gd).
##
## describe() is pure (a result dictionary + the picked world points in, drawing items out), so
## tests/measure_dimensions.gd checks what gets drawn headless. The node part just turns the items into lines
## and billboard labels, rebuilt whenever measure_tool.gd reports a new result or pick. The points come from
## measure_tool.picked_points() (where the laser landed, kept in each part's own space so a dimension follows
## a part that moves). Signals alone don't see a move or turn of the model, so _process() also redraws whenever
## those points have shifted since the last drawing (points_moved()).

const LABEL_FONT_SIZE := 48
const LABEL_PIXEL_SIZE := 0.0006 ## metres per label pixel: ~3 cm tall text
const TICK := 0.02 ## metres: half-length of a linear dimension's end ticks
const LEADER := 0.14 ## metres: how far a callout's leader runs from the picked point
const COLOUR := Color(1.0, 0.82, 0.25)
const MOVE_EPSILON := 0.0005 ## metres: picked points moving less than this don't trigger a redraw

var _tool
var _camera: Camera3D
var _items: Array = []
var _lines: MeshInstance3D
var _labels: Array[Label3D] = []
var _line_material: StandardMaterial3D
var _drawn_points: Array = [] ## the picked world points the current drawing was built from


static func format_mm(x: float) -> String:
	return ("%.3f" % x).rstrip("0").rstrip(".")


static func describe(result: Dictionary, points: Array) -> Array:
	## Items to draw: {kind: "linear"|"callout", a: Vector3, b: Vector3 (linear only), text: String}.
	var items := []
	if result.is_empty() or points.is_empty():
		return items
	if points.size() >= 2 and result.get("distance") != null:
		items.append({"kind": "linear", "a": points[0], "b": points[1], "text": "%s mm" % format_mm(float(result["distance"]))})
		return items
	var at: Vector3 = points[0]
	if result.get("diameter") != null:
		var text := "Ø %s mm" % format_mm(float(result["diameter"]))
		if result.get("radius") != null:
			text += "   R %s mm" % format_mm(float(result["radius"]))
		items.append({"kind": "callout", "a": at, "text": text})
	elif result.get("radius") != null:
		items.append({"kind": "callout", "a": at, "text": "R %s mm" % format_mm(float(result["radius"]))})
	elif result.get("length") != null:
		items.append({"kind": "callout", "a": at, "text": "L %s mm" % format_mm(float(result["length"]))})
	return items


static func points_moved(before: Array, after: Array, epsilon: float = MOVE_EPSILON) -> bool:
	if before.size() != after.size():
		return true
	for i in before.size():
		if (before[i] as Vector3).distance_to(after[i] as Vector3) > epsilon:
			return true
	return false


func setup(measure_tool, camera: Camera3D) -> void:
	_tool = measure_tool
	_camera = camera
	_line_material = StandardMaterial3D.new()
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.albedo_color = COLOUR
	_line_material.no_depth_test = true
	_line_material.render_priority = 100
	_lines = MeshInstance3D.new()
	_lines.name = "Lines"
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_lines)
	_tool.result_changed.connect(refresh)
	_tool.picks_changed.connect(refresh)
	refresh()


func items() -> Array:
	return _items


func _process(_delta: float) -> void:
	# The model was moved, turned or scaled (grip, two-hand, undo): the dimension follows its picked points.
	if _tool == null or not _tool.active or _items.is_empty():
		return
	if points_moved(_drawn_points, _tool.picked_points()):
		refresh()


func refresh() -> void:
	## Rebuilds the drawing for the tool's current result and picks. Nothing is shown while the tool is off.
	for l in _labels:
		l.queue_free()
	_labels.clear()
	_lines.mesh = null
	_drawn_points = _tool.picked_points()
	_items = describe(_tool.result, _drawn_points) if _tool.active else []
	visible = not _items.is_empty()
	if _items.is_empty():
		return
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _line_material)
	var view_dir := -_camera.global_transform.basis.z if _camera != null and _camera.is_inside_tree() else Vector3.FORWARD
	var up := _camera.global_transform.basis.y if _camera != null and _camera.is_inside_tree() else Vector3.UP
	var right := _camera.global_transform.basis.x if _camera != null and _camera.is_inside_tree() else Vector3.RIGHT
	for item in _items:
		var a: Vector3 = item["a"]
		if item["kind"] == "linear":
			var b: Vector3 = item["b"]
			mesh.surface_add_vertex(to_local(a))
			mesh.surface_add_vertex(to_local(b))
			var along := (b - a).normalized()
			var side := along.cross(view_dir)
			side = side.normalized() * TICK if side.length() > 0.0001 else up * TICK
			for end in [a, b]:
				mesh.surface_add_vertex(to_local(end - side))
				mesh.surface_add_vertex(to_local(end + side))
			_add_label(item["text"], (a + b) * 0.5 + side * 1.6)
		else:
			var tip := a + (right + up * 0.6).normalized() * LEADER
			mesh.surface_add_vertex(to_local(a))
			mesh.surface_add_vertex(to_local(tip))
			_add_label(item["text"], tip + up * 0.02)
	mesh.surface_end()
	_lines.mesh = mesh


func _add_label(text: String, world_pos: Vector3) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = LABEL_FONT_SIZE
	label.pixel_size = LABEL_PIXEL_SIZE
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.shaded = false
	label.no_depth_test = true
	label.modulate = COLOUR
	label.outline_size = 12
	label.render_priority = 101
	label.outline_render_priority = 100
	add_child(label)
	label.global_position = world_pos
	_labels.append(label)
