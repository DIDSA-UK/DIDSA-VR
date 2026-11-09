extends Node3D
## The selection drawer (T6, docs/test-report-30-oct-plan.md): a fixed-size panel that rises out of the FRONT of the design table's slab, inside the slab's outline,
## centred on its front edge, a few millimetres above the glass and tipped up about 15 degrees towards the user. Top row: the breadcrumb of what is selected
## (selection_breadcrumbs.gd); under it up to four action buttons (selection_actions.gd), a More button for the rest, and an X that clears the selection and closes it.
##
## FIXED SIZE (owner, 4 Nov): DRAWER_SIZE, the same at every slab size. It never reaches past the slab's front edge (so it can never cover the tool deck, which sits
## `deck_gap` in front of it) and the deck does not move when it opens. The Properties and tree windows are left clear too (tests/design_table_selection_drawer.gd
## checks the on-screen rectangles from the standing eye point). It slides out in about 150 ms (at once with Reduce motion) when something is selected and back when
## the selection is cleared; a thin leader line to the selected entity fades after a second.
##
## Drawn like the rest of the UI: real Controls in a SubViewport on a quad, hit by the right laser through a LaserSurface. It has no logic of its own: it shows the
## rungs and actions it is given and says what was pressed.

const LaserSurface := preload("res://scripts/ui/laser_surface.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

signal action_pressed(id: String)
signal rung_pressed(rung: Dictionary)
signal close_pressed

const DRAWER_SIZE := Vector2(0.40, 0.11) ## metres: width across the slab, depth towards you. One constant, so it can be tuned after the owner tries it.
const PX_PER_M := 2500.0
const TIP_DEGREES := 15.0 ## how far it is tipped up from flat, towards the user
const LIFT := 0.004 ## metres above the glass at its lowest edge
const SLIDE_SECONDS := 0.15
const MAX_ACTIONS := 4 ## action buttons before More
const GROUP_COLOURS := {"create": Color(0.31, 0.77, 1.0), "refine": Color(0.96, 0.69, 0.25), "modify": Color(0.78, 0.55, 0.98)}
const CRUMB_PX := 92
const ACTION_PX := 150
const CLOSE_PX := 100

var table: Node3D ## design_table.gd
var surface ## LaserSurface
var shown := false
var rungs: Array = []
var actions: Array = []
var more_open := false
var _viewport: SubViewport
var _quad: MeshInstance3D
var _root: PanelContainer
var _crumb_row: HBoxContainer
var _action_row: HBoxContainer
var _tween: Tween
var _tokens: Resource
var _leader: MeshInstance3D
var _leader_tween: Tween
var _fold_open := false


func setup(p_table: Node3D, p_tokens: Resource, right: XRController3D) -> void:
	table = p_table
	_tokens = p_tokens
	var px := Vector2i((DRAWER_SIZE * PX_PER_M).round())
	_viewport = SubViewport.new()
	_viewport.size = px
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_root = PanelContainer.new()
	_root.size = Vector2(px)
	_root.theme = _tokens.build_theme()
	_root.theme.default_font_size = 30
	_viewport.add_child(_root)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_root.add_child(column)
	_crumb_row = HBoxContainer.new()
	_crumb_row.name = "Crumbs"
	_crumb_row.add_theme_constant_override("separation", 6)
	_crumb_row.custom_minimum_size = Vector2(0, CRUMB_PX)
	column.add_child(_crumb_row)
	_action_row = HBoxContainer.new()
	_action_row.name = "Actions"
	_action_row.add_theme_constant_override("separation", 8)
	_action_row.custom_minimum_size = Vector2(0, ACTION_PX)
	column.add_child(_action_row)
	var cursor := LaserSurface.make_cursor()
	_root.add_child(cursor)
	# The panel lies on the slab like the deck does: its quad faces +Z, so it is laid down about X and tipped up TIP_DEGREES towards the user.
	_quad = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = DRAWER_SIZE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _viewport.get_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	_quad.mesh = mesh
	add_child(_quad)
	rotation_degrees = Vector3(-(90.0 - TIP_DEGREES), 0.0, 0.0)
	surface = LaserSurface.new()
	surface.setup(self, _viewport, right, DRAWER_SIZE)
	surface.claim_first = true
	surface.cursor = cursor
	visible = false
	place()


func place() -> void:
	## Centred on the slab's front edge, INSIDE the slab: its front (lower) edge on the slab's front edge, its depth running back over the glass.
	if table == null:
		return
	var tip := deg_to_rad(TIP_DEGREES)
	var half_d := DRAWER_SIZE.y * 0.5
	position = Vector3(0.0, LIFT + half_d * sin(tip), table.slab_size.y * 0.5 - half_d * cos(tip))


func corners_in_console() -> Array:
	## The four corners of the panel in the console's frame (for the overlap tests): lower-left, lower-right, upper-right, upper-left.
	var h := DRAWER_SIZE * 0.5
	var out: Array = []
	for c in [Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)]:
		out.append(transform * Vector3(c.x, c.y, 0.0))
	return out


func show_for(p_rungs: Array, p_actions: Array) -> void:
	## Something is selected (or the selection changed): the rungs and the actions, sliding out if it was away.
	rungs = p_rungs
	actions = p_actions
	_fold_open = false
	more_open = false
	_rebuild()
	if shown:
		return
	shown = true
	visible = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	surface.arm()
	place()
	var target := position
	if UiFeedback.reduce_motion or SLIDE_SECONDS <= 0.0 or not is_inside_tree():
		return
	position = target + Vector3(0.0, -DRAWER_SIZE.y * 0.6, 0.02) # starts lower and a little further in: "rising out of the slab's front"
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "position", target, SLIDE_SECONDS)
	UiFeedback.play("open", self)


func hide_drawer() -> void:
	if not shown:
		return
	shown = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	surface.release_all()
	visible = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	clear_leader()


func _rebuild() -> void:
	for child in _crumb_row.get_children():
		_crumb_row.remove_child(child)
		child.queue_free()
	for child in _action_row.get_children():
		_action_row.remove_child(child)
		child.queue_free()
	var Crumbs := preload("res://scripts/design_table/selection_breadcrumbs.gd")
	var folded: Dictionary = Crumbs.folded(rungs) if not _fold_open else {"shown": rungs, "hidden": []}
	var i := 0
	for rung in folded["shown"]:
		if i > 0:
			var sep := Label.new()
			sep.text = ">"
			sep.theme_type_variation = &"LabelDim"
			sep.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			_crumb_row.add_child(sep)
		var b := Button.new()
		b.name = "Crumb_%s" % str(rung["id"])
		b.text = str(rung["text"])
		b.clip_text = true
		b.custom_minimum_size = Vector2(0, CRUMB_PX)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL if i == 0 else Control.SIZE_SHRINK_BEGIN
		if i == 0:
			b.theme_type_variation = &"ButtonAccent" # the selected rung is lit
		var r: Dictionary = rung
		b.pressed.connect(func() -> void: _on_rung(r))
		_crumb_row.add_child(b)
		i += 1
	# actions: the first MAX_ACTIONS (the default first), then More, then X
	var page: Array = actions if more_open else actions.slice(0, MAX_ACTIONS)
	for action in page:
		_action_row.add_child(_action_button(action))
	if not more_open and actions.size() > MAX_ACTIONS:
		var more := Button.new()
		more.name = "More"
		more.text = "More"
		more.custom_minimum_size = Vector2(150, ACTION_PX)
		more.pressed.connect(func() -> void:
			more_open = true
			_rebuild())
		_action_row.add_child(more)
	elif more_open:
		var back := Button.new()
		back.name = "Less"
		back.text = "Back"
		back.custom_minimum_size = Vector2(150, ACTION_PX)
		back.pressed.connect(func() -> void:
			more_open = false
			_rebuild())
		_action_row.add_child(back)
	var close := Button.new()
	close.name = "Close"
	close.text = "X"
	close.custom_minimum_size = Vector2(CLOSE_PX, ACTION_PX)
	close.size_flags_horizontal = Control.SIZE_SHRINK_END
	close.pressed.connect(func() -> void: close_pressed.emit())
	_action_row.add_child(close)


func _action_button(action: Dictionary) -> Button:
	var b := Button.new()
	b.name = "Action_%s" % str(action["id"])
	b.text = str(action["text"])
	b.clip_text = true
	b.custom_minimum_size = Vector2(0, ACTION_PX)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.disabled = not bool(action["enabled"])
	b.tooltip_text = str(action.get("reason", ""))
	var colour: Color = GROUP_COLOURS.get(str(action.get("group", "")), Color.WHITE)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(colour.r, colour.g, colour.b, 0.28 if not b.disabled else 0.10)
	sb.border_color = colour
	sb.set_border_width_all(3 if not b.disabled else 1)
	sb.set_corner_radius_all(10)
	b.add_theme_stylebox_override("normal", sb)
	var hover: StyleBoxFlat = sb.duplicate()
	hover.bg_color = Color(colour.r, colour.g, colour.b, 0.5)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	var id := str(action["id"])
	b.pressed.connect(func() -> void: action_pressed.emit(id))
	b.mouse_entered.connect(func() -> void:
		if b.disabled and str(action.get("reason", "")) != "":
			table.set_status(str(action["reason"])) # a disabled action explains itself when the laser rests on it
	)
	return b


func _on_rung(rung: Dictionary) -> void:
	if str(rung.get("level", "")) == "fold":
		_fold_open = true
		_rebuild()
		return
	rung_pressed.emit(rung)


func button_named(name: String) -> Button:
	return _root.find_child(name, true, false) as Button


func button_names() -> Array:
	return _root.find_children("*", "Button", true, false).map(func(b) -> String: return str(b.name))


func process(delta: float) -> void:
	if shown:
		surface.process(delta, true)


# --- the leader line ---------------------------------------------------------------------------------------------

func show_leader(console_point: Vector3) -> void:
	## A thin line from the drawer's left end to the selected entity (console frame), fading after a second.
	clear_leader()
	if table == null:
		return
	var from_point: Vector3 = position + Vector3(-DRAWER_SIZE.x * 0.5, 0.0, 0.0)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(from_point)
	im.surface_add_vertex(console_point)
	im.surface_end()
	_leader = MeshInstance3D.new()
	_leader.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	_leader.material_override = mat
	table.add_child(_leader)
	if is_inside_tree():
		_leader_tween = create_tween()
		_leader_tween.tween_interval(1.0)
		_leader_tween.tween_property(mat, "albedo_color:a", 0.0, 0.4)
		_leader_tween.tween_callback(clear_leader)


func clear_leader() -> void:
	if _leader_tween != null and _leader_tween.is_valid():
		_leader_tween.kill()
	if _leader != null and is_instance_valid(_leader):
		_leader.queue_free()
	_leader = null
