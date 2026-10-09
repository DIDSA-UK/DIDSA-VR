extends "res://scripts/diegetic_panel.gd"
## The PROPERTIES panel at the design table's right (Phase 5.2): every setting of the active tool in one place, built from the same
## option list the tool gives the editor (features/feature_tool.gd `options`): [{id, text, toggle?, pressed?, disabled?}], so the
## deck's old one-row strip is gone. It shows the tool's name and what to do (the registry's hint), then the settings one per row
## (toggles side by side in a group), and Apply last. Pressing one emits `option_pressed(id)`, the signal the deck's row used to.
##
## First version: today's controls in today's style (ui/themes/), only stacked. Layout and colour are the next step, not this one.
## It is open whenever the console is: the tool tip (the table's status line) is shown here, then what the tool has picked (the Selected list), then the tool's settings.

signal option_pressed(option_id: String)


var table ## design_table.gd
var _title: Label
var _hint: Label
var _rows: VBoxContainer
var _scroll: ScrollContainer
var _options: Array = []
var _buttons := {} ## option id -> Button
var _tool_title := ""
var _tool_hint := ""
var _selection: Array = [] ## what the tool has picked so far, a line per kind
var _selection_label: Label
var _tip := "" ## the live tool tip (the table's status line); shown instead of the tool's fixed hint when there is one
var _accent := Color.WHITE
var _wanted := false ## there is something to show; the window opens as soon as the console is open
@export var dock_position := Vector3(0.50, 0.20, 0.06) ## in the console's frame
@export var dock_yaw_degrees: float = -24.0 ## turns the panel in towards the slab


func setup_for_table(p_table, left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	table = p_table
	panel_title = "Properties"
	panel_size = Vector2(0.30, 0.40)
	viewport_size = Vector2i(516, 688)
	setup(left, right, camera)
	set_title("Properties")
	_apply_panel_size(panel_size, true)
	_base_width = panel_size.x


func _build_content() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_title = Label.new()
	_title.theme_type_variation = &"LabelTitle"
	column.add_child(_title)
	_hint = Label.new()
	_hint.theme_type_variation = &"LabelDim"
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_hint)
	_selection_label = Label.new()
	_selection_label.theme_type_variation = &"LabelSmall"
	_selection_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_selection_label.visible = false
	column.add_child(_selection_label)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 8)
	_scroll.add_child(_rows)
	column.add_child(_scroll)
	scroll_target = _scroll
	return column


func _place_in_front_of_camera() -> void:
	## Docked at the console's right instead of in front of the camera.
	transform = Transform3D(Basis(Vector3.UP, deg_to_rad(dock_yaw_degrees)), dock_position)


# --- What the editor and the deck feed it ----------------------------------------------

func set_tool(title: String, hint: String, accent: Color) -> void:
	_tool_title = title
	_tool_hint = hint
	_accent = accent
	_show_tool()


func set_tip(text: String) -> void:
	## The tool tip (what to do next, or what went wrong): it lives here, not on the dock.
	if text == _tip:
		return
	_tip = text
	_show_tool()


func set_selection(lines: Array) -> void:
	## The "Selected" list: what the active tool has picked (edges, faces, bodies, sketch lines, the open sketch).
	if lines == _selection:
		return
	_selection = lines.duplicate()
	_show_selection()


func selection_text() -> String:
	return _selection_label.text if _selection_label != null and _selection_label.visible else ""


func _show_selection() -> void:
	if _selection_label == null:
		return
	_selection_label.visible = not _selection.is_empty()
	_selection_label.text = "SELECTED\n" + "\n".join(_selection) if not _selection.is_empty() else ""


func tip_text() -> String:
	return _hint.text if _hint != null else ""


func set_options(options: Array) -> void:
	## The active tool's settings (an empty list = nothing to show; the window goes away).
	if options == _options:
		return
	_options = options.duplicate(true)
	_rebuild()


func option_button(option_id: String) -> Button:
	return _buttons.get(option_id)


func has_options() -> bool:
	return not _options.is_empty()


func option_ids() -> Array:
	return _options.map(func(o): return str(o.get("id", "")))


func set_wanted(wanted: bool) -> void:
	## The console is open (the panel carries the tool tip even when the tool has no settings).
	_wanted = wanted
	if wanted and not is_open() and _ui_root != null:
		open()
	elif not wanted and is_open():
		close()


func _show_tool() -> void:
	if _title == null:
		return
	_title.text = _tool_title
	_hint.text = _tip if _tip != "" else _tool_hint
	_hint.visible = _hint.text != ""
	_show_selection()


func _rebuild() -> void:
	if _rows == null:
		return
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_buttons.clear()
	var toggles: Array = []
	var group: HFlowContainer = null
	for o in _options:
		var b := _make_button(o)
		_buttons[str(o.get("id", ""))] = b
		if bool(o.get("toggle", false)):
			if group == null:
				group = HFlowContainer.new()
				group.add_theme_constant_override("h_separation", 8)
				group.add_theme_constant_override("v_separation", 8)
				_rows.add_child(group)
			group.add_child(b)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			group = null # the next toggles start a new group
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			if str(o.get("id", "")) in ["apply", "fix_apply"]:
				b.theme_type_variation = &"ButtonAccent"
			_rows.add_child(b)
	_show_tool()
	if table != null:
		set_wanted(table.is_open())


func _make_button(o: Dictionary) -> Button:
	var b := Button.new()
	b.text = str(o.get("text", ""))
	b.toggle_mode = bool(o.get("toggle", false))
	b.set_pressed_no_signal(bool(o.get("pressed", false)))
	b.disabled = bool(o.get("disabled", false))
	b.clip_text = true
	b.custom_minimum_size = Vector2(0, 56)
	b.add_theme_font_size_override("font_size", tokens.font_small)
	if b.toggle_mode:
		b.add_theme_stylebox_override("pressed", tokens.selected_box(_accent))
		b.add_theme_stylebox_override("hover_pressed", tokens.selected_box(_accent))
		b.custom_minimum_size = Vector2(150, 56)
	var id := str(o.get("id", ""))
	b.pressed.connect(func() -> void:
		UiFeedback.haptic(_right, "tick")
		option_pressed.emit(id))
	return b


func _on_opened() -> void:
	_show_tool()
