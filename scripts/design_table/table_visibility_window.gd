extends "res://scripts/diegetic_panel.gd"
## The VISIBILITY drawer (docs/sketch-as-seed-plan.md section 3): a panel beside the Properties dock, opened by the eye button in the
## generic column. One row per category: an eye (all visible), half eye (some) or eye-off (none), the name and, for the categories that are
## features, how many are visible ("3 of 5"). Show all / Hide all act on every row. The logic is visibility.gd (the rules) and
## table_build.gd (the hidden ids; the session switches); this is only the view. A category with nothing in it is dimmed; Centre of gravity
## is a placeholder until the backend can report it.

const Visibility := preload("res://scripts/design_table/visibility.gd")

const ROWS := [ ## [id, label, feature category or ""]
	[Visibility.SKETCHES, "Sketches"],
	[Visibility.BODIES, "Bodies"],
	[Visibility.SURFACES, "Surfaces"],
	[Visibility.CURVES, "3D curves"],
	[Visibility.PLANES, "Created planes"],
	[Visibility.REFERENCE_PLANES, "Reference planes"],
	[Visibility.ORIGIN_AXES, "Origin and axes"],
	["centre_of_gravity", "Centre of gravity (soon)"],
	[Visibility.DIMENSIONS, "Sketch dimensions"],
	[Visibility.CONSTRUCTION, "Construction geometry"],
	[Visibility.EDGE_LINES, "Edge lines"],
]

var table ## design_table.gd
var _rows := VBoxContainer.new()
var _buttons := {} ## row id -> Button
var _show_all: Button
var _hide_all: Button
@export var dock_position := Vector3(0.84, 0.20, 0.06) ## in the console's frame, beside the Properties dock
@export var dock_yaw_degrees: float = -14.0


func setup_for_table(p_table, left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	table = p_table
	panel_title = "Visibility"
	panel_size = Vector2(0.30, 0.54)
	viewport_size = Vector2i(516, 930)
	setup(left, right, camera)
	set_title("Visibility")
	_apply_panel_size(panel_size, true)
	_base_width = panel_size.x
	table.build.changed.connect(refresh)
	table.build.visibility.changed.connect(refresh)


func _build_content() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	_show_all = _plain("Show all", func() -> void: table.build.set_all_visible(true))
	_hide_all = _plain("Hide all", func() -> void: table.build.set_all_visible(false))
	top.add_child(_show_all)
	top.add_child(_hide_all)
	column.add_child(top)
	_rows.add_theme_constant_override("separation", 8)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for r in ROWS:
		var id: String = r[0]
		var b := Button.new()
		b.clip_text = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 56)
		b.add_theme_font_size_override("font_size", tokens.font_small)
		b.pressed.connect(func() -> void:
			UiFeedback.haptic(_right, "tick")
			_row_pressed(id))
		_buttons[id] = b
		_rows.add_child(b)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(_rows)
	column.add_child(scroll)
	scroll_target = scroll
	return column


func _plain(text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 52)
	b.add_theme_font_size_override("font_size", tokens.font_small)
	b.pressed.connect(func() -> void:
		UiFeedback.haptic(_right, "tick")
		callback.call())
	return b


func _place_in_front_of_camera() -> void:
	transform = Transform3D(Basis(Vector3.UP, deg_to_rad(dock_yaw_degrees)), dock_position)


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
	return {"state": "soon", "label": ""}


func button_for(id: String) -> Button:
	return _buttons.get(id)


func refresh() -> void:
	for r in ROWS:
		var b: Button = _buttons.get(r[0])
		if b == null:
			continue
		var st := row_state(r[0])
		b.text = " %s%s" % [r[1], ("   " + st["label"]) if st["label"] != "" else ""]
		b.icon = UiIcons.texture({"all": "eye", "some": "eye_half"}.get(st["state"], "eye_off"), 28)
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
	table.ui.set_eye(false) # closed with its X (or with the table): the eye lets go
