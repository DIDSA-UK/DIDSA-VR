extends Node3D
## The tool wheel: a quick radial menu for the tools you reach for most, like the spell / weapon wheel in an FPS
## VR game. Squeeze the right trigger and grip together; a ring of wedges opens at your hand. Move the hand
## towards a wedge (the ring is steered by hand MOVEMENT, not by aiming) and let go to choose it. Let go at the
## centre to cancel. A wedge marked as a sub-wheel opens its own ring once the hand travels well out towards it;
## release over one of its wedges to choose that.
##
## controller.gd detects the chord (trigger + grip within a quarter of a second of each other, so a single
## press still grabs or selects exactly as before) and emits wheel_chord_started. From then until BOTH buttons
## are up again the hand carries the meta "wheel_open": the grip, trigger, stick and laser are the wheel's
## (controller.gd, two_hand_model.gd and locomotion.gd's is_manipulating() check it).
##
## What is on the ring comes from `entries_provider` (wheel_flows.gd), asked each time the wheel opens, so the
## ring can follow what you are doing (while Mates is on it offers Create / Flip / Clear). An entry is a
## dictionary:
##   id, label, icon (ui_icons.gd name), accent (Color), hint (one line shown in the centre),
##   enabled (bool, default true), run (Callable, for a normal wedge), children (Callable -> Array, for a
##   sub-wheel), active (bool: drawn as "on").
## The geometry (which wedge, outlines) is tool_wheel_math.gd, pure and tested headless.

const Math := preload("res://scripts/ui/tool_wheel_math.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

signal opened()
signal closed()
signal chosen(entry_id: String)

const ICON_PX := 64
const ICON_PIXEL_SIZE := 0.0007 ## metres per icon pixel: a 4.5 cm icon
const HOVER_LIFT := 0.012 ## metres: the hovered wedge lifts towards you
const SIZE_NAMES: Array[String] = ["Small", "Normal", "Large"]
const SIZE_SCALES: Array[float] = [0.8, 1.0, 1.3]
const TRIGGER_ACTION := "trigger_click"
const GRIP_ACTION := "grip_click"

var tokens: Resource
var entries_provider: Callable = Callable() ## () -> Array of entry dictionaries
var dead_zone := Math.DEAD_ZONE
var wheel_scale := 1.0

var _hand: XRController3D
var _camera: Camera3D
var _held := false ## the chord is held (the hand's "wheel_open" meta)
var _shown := false ## the ring is up (it goes away as soon as one button is released)
var _entries: Array = []
var _stack: Array = [] ## the rings above the current one (for a sub-wheel): [{entries, title}]
var _title := ""
var _hover := -1
var _anchor := Vector3.ZERO
var _right := Vector3.RIGHT
var _wedges: Array[MeshInstance3D] = []
var _icons: Array[Sprite3D] = []
var _centre_title: Label3D
var _centre_hint: Label3D
var _cursor: MeshInstance3D
var _ring: Node3D


func setup(hand: XRController3D, camera: Camera3D, p_tokens: Resource, provider: Callable) -> void:
	_hand = hand
	_camera = camera
	tokens = p_tokens
	entries_provider = provider
	_ring = Node3D.new()
	_ring.name = "Ring"
	add_child(_ring)
	_centre_title = _make_label(40, 0.0006)
	_centre_title.position = Vector3(0, 0.012, 0.004)
	_centre_hint = _make_label(24, 0.0006)
	_centre_hint.position = Vector3(0, -0.018, 0.004)
	_centre_hint.modulate = tokens.text_dim
	_cursor = MeshInstance3D.new()
	var dot := SphereMesh.new()
	dot.radius = 0.007
	dot.height = 0.014
	_cursor.mesh = dot
	_cursor.material_override = _material(tokens.text, 1.0)
	_ring.add_child(_cursor)
	visible = false
	hand.wheel_enabled = true
	hand.wheel_chord_started.connect(_on_chord)
	hand.button_released.connect(_on_released)
	set_process(false)


func set_size(index: int) -> void:
	wheel_scale = SIZE_SCALES[clampi(index, 0, SIZE_SCALES.size() - 1)]


func is_open() -> bool:
	## The chord is held (whether or not the ring is still up).
	return _held


func is_shown() -> bool:
	return _shown


func hovered_index() -> int:
	return _hover


func current_entries() -> Array:
	return _entries


func set_enabled(on: bool) -> void:
	if _hand:
		_hand.wheel_enabled = on
	if not on and _held:
		_end()


# --- Opening / closing -------------------------------------------------------------------------

func _on_chord() -> void:
	if _held:
		return
	_hand.cancel_for_wheel() # the first press of the chord already began a grab / selected something: let go of it
	_held = true
	_hand.set_meta("wheel_open", true)
	_stack.clear()
	var entries: Array = entries_provider.call() if entries_provider.is_valid() else []
	_title = ""
	_show_ring(entries, _hand.global_position)
	UiFeedback.play("open", self)
	UiFeedback.haptic(_hand, "open")
	opened.emit()


func _show_ring(entries: Array, at: Vector3) -> void:
	_entries = entries
	_hover = -1
	_anchor = at
	_orient_to_user()
	global_transform = Transform3D(_basis_for(), _anchor)
	scale = Vector3.ONE * wheel_scale
	_rebuild()
	_shown = not _entries.is_empty()
	visible = _shown
	set_process(_shown)
	_update_centre()


func _orient_to_user() -> void:
	## A vertical ring facing the user's head, steered by the head's yaw only (looking down at your hand doesn't tip it).
	var forward := -_camera.global_transform.basis.z if _camera != null and _camera.is_inside_tree() else Vector3.FORWARD
	forward.y = 0.0
	if forward.length() < 0.001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	_right = forward.cross(Vector3.UP).normalized()


func _basis_for() -> Basis:
	return Basis(_right, Vector3.UP, _right.cross(Vector3.UP).normalized())


func _on_released(action_name: String) -> void:
	if not _held or (action_name != TRIGGER_ACTION and action_name != GRIP_ACTION):
		return
	if _shown:
		_commit()
	if not _hand.is_button_pressed(TRIGGER_ACTION) and not _hand.is_button_pressed(GRIP_ACTION):
		_end()


func _end() -> void:
	_held = false
	_shown = false
	_hover = -1
	_stack.clear()
	visible = false
	set_process(false)
	if _hand:
		_hand.set_meta("wheel_open", false)
	closed.emit()


func _commit() -> void:
	## Release: do what the hovered wedge says. Release at the centre, over a greyed wedge or over a sub-wheel's
	## label (the ring wasn't opened) does nothing.
	var picked := _hover
	_shown = false
	visible = false
	set_process(false)
	if picked < 0 or picked >= _entries.size():
		UiFeedback.play("close", self)
		return
	var entry: Dictionary = _entries[picked]
	if not bool(entry.get("enabled", true)) or entry.has("children") or not entry.has("run"):
		UiFeedback.haptic(_hand, "error")
		UiFeedback.play("error", self)
		return
	UiFeedback.play("confirm", self)
	UiFeedback.haptic(_hand, "confirm")
	chosen.emit(str(entry.get("id", "")))
	(entry["run"] as Callable).call()


# --- Per frame: steer by hand movement ---------------------------------------------------------

func _process(_delta: float) -> void:
	if not _shown:
		return
	var offset := Math.project_offset(_hand.global_position, _anchor, _right) / maxf(wheel_scale, 0.01)
	_update_hover(Math.wedge_for(offset, _entries.size(), dead_zone), offset)
	var shown_len := minf(offset.length(), Math.OUTER_RADIUS * 1.15)
	_cursor.position = Vector3(offset.normalized().x * shown_len, offset.normalized().y * shown_len, 0.006) if offset.length() > 0.0001 else Vector3(0, 0, 0.006)
	if _hover >= 0 and _entries[_hover].has("children") and bool(_entries[_hover].get("enabled", true)) and Math.is_drilling(offset):
		_drill(_hover)


func _update_hover(index: int, _offset: Vector2) -> void:
	# (a greyed wedge is still pointed at, to read why it is greyed; it just can't be chosen)
	if index == _hover:
		return
	_hover = index
	if _hover >= 0:
		UiFeedback.haptic(_hand, "hover")
	_paint()
	_update_centre()


func _drill(index: int) -> void:
	## The hand travelled out towards a sub-wheel's wedge: open its ring, centred where the hand is now.
	var children: Array = (_entries[index]["children"] as Callable).call()
	if children.is_empty():
		return
	_stack.append({"entries": _entries, "title": _title})
	_title = str(_entries[index].get("label", ""))
	UiFeedback.play("open", self)
	UiFeedback.haptic(_hand, "press")
	_show_ring(children, _hand.global_position)


# --- Drawing -----------------------------------------------------------------------------------

func _rebuild() -> void:
	for n in _wedges:
		n.queue_free()
	for n in _icons:
		n.queue_free()
	_wedges.clear()
	_icons.clear()
	var count := _entries.size()
	for i in count:
		var wedge := MeshInstance3D.new()
		wedge.mesh = _wedge_mesh(i, count)
		wedge.material_override = _material(tokens.bg_panel, 0.86)
		_ring.add_child(wedge)
		_wedges.append(wedge)
		var icon := Sprite3D.new()
		icon.texture = UiIcons.texture(str(_entries[i].get("icon", "")), ICON_PX)
		icon.pixel_size = ICON_PIXEL_SIZE
		icon.shaded = false
		icon.double_sided = true
		icon.no_depth_test = true
		icon.render_priority = 12
		icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		var dir := Math.centre_direction(i, count)
		var radius := (Math.INNER_RADIUS + Math.OUTER_RADIUS) * 0.5
		icon.position = Vector3(dir.x * radius, dir.y * radius, 0.003)
		_ring.add_child(icon)
		_icons.append(icon)
	_cursor.position = Vector3(0, 0, 0.006)
	_paint()


func _paint() -> void:
	for i in _wedges.size():
		var entry: Dictionary = _entries[i]
		var accent: Color = entry.get("accent", tokens.accent)
		var enabled := bool(entry.get("enabled", true))
		var on := bool(entry.get("active", false))
		var hovered := i == _hover
		var fill: Color = tokens.bg_panel
		if on:
			fill = tokens.accent_deep
		if hovered and enabled:
			fill = accent.darkened(0.35)
		var mat := _wedges[i].material_override as StandardMaterial3D
		mat.albedo_color = Color(fill.r, fill.g, fill.b, 0.93 if hovered else 0.84)
		_wedges[i].position.z = HOVER_LIFT if hovered and enabled else 0.0
		_icons[i].modulate = (accent if enabled else tokens.text_disabled) if not hovered else Color.WHITE
		_icons[i].position.z = 0.003 + (HOVER_LIFT if hovered and enabled else 0.0)
		_icons[i].scale = Vector3.ONE * (1.25 if hovered and enabled else 1.0)


func _update_centre() -> void:
	if _hover >= 0 and _hover < _entries.size():
		var entry: Dictionary = _entries[_hover]
		var enabled := bool(entry.get("enabled", true))
		_centre_title.text = str(entry.get("label", ""))
		_centre_title.modulate = tokens.text if enabled else tokens.text_disabled
		_centre_hint.text = str(entry.get("hint", "")) if enabled else str(entry.get("hint_disabled", "Not available right now"))
	else:
		_centre_title.text = _title if _title != "" else "Tools"
		_centre_title.modulate = tokens.text_dim
		_centre_hint.text = "release here to cancel"


func _wedge_mesh(index: int, count: int) -> ArrayMesh:
	var outline := Math.wedge_outline(index, count)
	var indices := Geometry2D.triangulate_polygon(outline)
	var mesh := ArrayMesh.new()
	if indices.is_empty():
		return mesh
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for p in outline:
		verts.append(Vector3(p.x, p.y, 0.0))
		normals.append(Vector3.BACK)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _material(colour: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(colour.r, colour.g, colour.b, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	m.render_priority = 10
	return m


func _make_label(font_size: int, pixel_size: float) -> Label3D:
	var l := Label3D.new()
	l.font_size = font_size
	l.pixel_size = pixel_size
	l.shaded = false
	l.no_depth_test = true
	l.outline_size = 8
	l.render_priority = 14
	l.outline_render_priority = 13
	l.modulate = tokens.text
	add_child(l)
	return l
