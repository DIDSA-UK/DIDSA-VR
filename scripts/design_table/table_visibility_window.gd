extends "res://scripts/diegetic_panel.gd"
## The VISIBILITY drawer (docs/sketch-as-seed-plan.md section 3): a drawer on the right of the tool deck, opened by the eye button in the
## generic column. A grid of square tiles, one per category: an eye (all visible), half eye (some) or eye-off (none) over the name; a
## category with nothing in it is dimmed. Rows run in groups: what the model made, the planes and axes, what is drawn on it. Show all / Hide all
## are the two large buttons down the far left and act on every category. The logic is visibility.gd (the rules) and table_build.gd (the hidden
## ids; the session switches); this is only the view. Centre of gravity is a placeholder until the backend can report it.

const Visibility := preload("res://scripts/design_table/visibility.gd")

const COLUMNS := 4
const TILE := 100.0 ## px, a square button: a little under twice the deck's buttons (52 px tall)
const ROWS := [ ## [id, label, feature category or ""]
	[Visibility.SKETCHES, "Sketches"],
	[Visibility.BODIES, "Bodies"],
	[Visibility.SURFACES, "Surfaces"],
	[Visibility.CURVES, "3D curves"],
	[Visibility.PLANES, "Planes"],
	[Visibility.REFERENCE_PLANES, "Ref. planes"],
	[Visibility.ORIGIN_AXES, "Origin, axes"],
	["centre_of_gravity", "Gravity"],
	[Visibility.DIMENSIONS, "Dims"],
	[Visibility.CONSTRUCTION, "Constr."],
	[Visibility.EDGE_LINES, "Edge lines"],
]

var table ## design_table.gd
var _buttons := {} ## row id -> Button
var _show_all: Button
var _hide_all: Button
const GAP := 0.012 ## metres between the deck's right edge and the drawer


func setup_for_table(p_table, left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	table = p_table
	panel_title = "Visibility"
	panel_size = Vector2(0.26, p_table.tools_size.y) # as tall as the deck it sits against
	viewport_size = Vector2i((panel_size * p_table.pixels_per_metre).round()) # the deck's own density: the same text size
	setup(left, right, camera)
	set_title("Visibility")
	_apply_panel_size(panel_size, true)
	_base_width = panel_size.x
	# Stationary: it is a child of the deck, flush against its right edge, so it has no grab handle and its corners do not resize it.
	handle.node.queue_free()
	handle.node = null
	for c in _corners:
		c.visible = false
	table.build.changed.connect(refresh)
	table.build.visibility.changed.connect(refresh)


func _build_content() -> Control:
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 12)
	_show_all = _plain("Show all", func() -> void: table.build.set_all_visible(true))
	_hide_all = _plain("Hide all", func() -> void: table.build.set_all_visible(false))
	left.add_child(_show_all)
	left.add_child(_hide_all)
	body.add_child(left)
	var grid := GridContainer.new()
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	for r in ROWS:
		var id: String = r[0]
		var b := Button.new()
		b.clip_text = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.expand_icon = false
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.custom_minimum_size = Vector2(TILE, TILE)
		b.add_theme_font_size_override("font_size", maxi(12, tokens.font_small - 2))
		b.pressed.connect(func() -> void:
			UiFeedback.haptic(_right, "tick")
			_row_pressed(id))
		_buttons[id] = b
		grid.add_child(b)
	body.add_child(grid)
	return body


func _plain(text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(120.0, (TILE * 3.0 + 20.0) * 0.5 - 6.0) # the two share the grid's height # one per grid row, a little wider than a tile
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.add_theme_font_size_override("font_size", tokens.font_small)
	b.pressed.connect(func() -> void:
		UiFeedback.haptic(_right, "tick")
		callback.call())
	return b


func _place_in_front_of_camera() -> void:
	dock_to_deck()


func dock_to_deck() -> void:
	## In the deck's frame (the deck is a quad centred on its origin): its right edge plus the gap, top edges level.
	position = Vector3(table.tools_size.x * 0.5 + panel_size.x * 0.5 + GAP, (table.tools_size.y - panel_size.y) * 0.5, 0.0)
	rotation = Vector3.ZERO


func _corner_at(_p: Vector2) -> int:
	return -1


func _row_pressed(id: String) -> void:
	if Visibility.FEATURE_CATEGORIES.has(id):
		table.build.toggle_category(id)
	elif Visibility.SESSION_CATEGORIES.has(id):
		table.build.visibility.toggle(id)


func row_state(id: String) -> Dictionary:
	## {state: "all" | "some" | "none" | "empty" | "soon", label: "3 of 5" or ""} for one row.
	if Visibility.FEATURE_CATEGORIES.has(id):
		var st: Dictionary = table.build.category_state(id)
		return {"state": st["state"], "label": st["label"] if st["total"] > 0 else ""}
	if Visibility.SESSION_CATEGORIES.has(id):
		return {"state": "all" if table.build.visibility.is_on(id) else "none", "label": ""}
	return {"state": "soon", "label": "coming soon"}


func button_for(id: String) -> Button:
	return _buttons.get(id)


func refresh() -> void:
	for r in ROWS:
		var b: Button = _buttons.get(r[0])
		if b == null:
			continue
		var st := row_state(r[0])
		b.text = r[1] if st["state"] != "soon" else "%s\n%s" % [r[1], st["label"]] # no counts on the tiles: the eye shows all / some / none
		b.icon = UiIcons.texture({"all": "eye", "some": "eye_half"}.get(st["state"], "eye_off"), 32)
		b.disabled = st["state"] in ["empty", "soon"] or (Visibility.FEATURE_CATEGORIES.has(r[0]) and not table.build.view_filters_ok)
		b.modulate = Color(1, 1, 1, 0.5) if st["state"] in ["empty", "soon", "none"] else Color.WHITE


func set_wanted(wanted: bool) -> void:
	if wanted and not is_open() and _ui_root != null:
		open()
	elif not wanted and is_open():
		close()


func _on_opened() -> void:
	refresh()
	table.ui.set_eye(true)


func _on_closed() -> void:
	table.ui.set_eye(false) # closed (by the eye or with the table): the eye lets go
