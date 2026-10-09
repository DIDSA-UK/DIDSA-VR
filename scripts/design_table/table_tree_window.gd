extends "res://scripts/assembly_tree_window.gd"
## The tree at the design table's left, from John's sketch. Two tabs:
##   BUILD  the part on the table's own build tree, the flat app's part-design-lens tree: every feature that made it (planes, sketches,
##          extrudes, fillets...) in order, with Edit / Hide / Roll back / Delete on the selected row (the logic is table_build.gd, this
##          is only its view). It opens as soon as a part goes on the table.
##   PARTS  the ordinary Assembly Tree window (browse the occurrences, tap a name to select the part) docked to the console and given
##          two actions on every placed part:
##   Table  puts that part on the table to edit it, without carrying it there;
##   Bring  moves it to a spot in front of you in the arena (an ordinary, undoable move).
## Only parts with geometry in the arena can be taken: a sub-assembly row has none of its own (open it and take one of its parts).
## It is a child of the console, so it moves with it; its own grab handle still moves it separately, and its X puts it away
## until the table is next opened.
##
## Pulling a row out by dragging it is not built: the laser freezes the pointer while the trigger is held (laser_surface.gd, so
## a shaky squeeze can't cancel a button press), so a drag from a row would need a second gesture of its own.

var table ## design_table.gd
var _new_part_button: Button
var _tab_build: Button
var _tab_parts: Button
var _parts_pane: Control
var _build_pane: Control
var _parts_scroll: ScrollContainer
var _build_scroll: ScrollContainer
var _rename_button: Button
var _build_title: Label
var _build_rows: VBoxContainer
var _tab := "parts"
var _build_dirty := false
@export var dock_position := Vector3(-0.50, 0.20, 0.06) ## in the console's frame
@export var dock_yaw_degrees: float = 24.0 ## turns the panel in towards the slab

const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const Visibility := preload("res://scripts/design_table/visibility.gd")


func setup_for_table(p_table, left: XRController3D, right: XRController3D, camera: XRCamera3D, main: Node) -> void:
	table = p_table
	setup_tree(left, right, camera, main)
	panel_title = "Table tree"
	set_title("Table tree")
	panel_size = Vector2(0.30, 0.40)
	viewport_size = Vector2i(516, 688)
	_apply_panel_size(panel_size, true)
	_base_width = panel_size.x
	# "+" in the header beside the close button: a new empty part on the table (the same as the tablet's Table page > New part).
	var plus := add_header_button("", func() -> void: table.new_part(), false)
	plus.icon = UiIcons.texture("plus", 64)
	plus.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plus.expand_icon = false
	plus.theme_type_variation = &"ButtonAccent"
	_header.move_child(plus, _header.get_child_count() - 2) # between the title and the close button
	_new_part_button = plus


func attach_build(build) -> void:
	## The table's Build tree state (table_build.gd) is what the Build tab shows; the tab redraws whenever it changes, and the
	## window opens on it as soon as a part goes on the table.
	build.changed.connect(_on_build_changed)
	table.editor.state_changed.connect(func(_state: String) -> void: _on_build_changed()) # the sketch rows offer "Lines" while curves are being picked
	table.part_seated.connect(func(_part: Node3D) -> void: show_tab("build"))


func show_tab(which: String) -> void:
	_tab = which
	if _parts_pane == null:
		return
	_parts_pane.visible = which == "parts"
	_build_pane.visible = which == "build"
	_tab_parts.set_pressed_no_signal(which == "parts")
	_tab_build.set_pressed_no_signal(which == "build")
	scroll_target = _parts_scroll if which == "parts" else _build_scroll
	if which == "build":
		_redraw_build()


func current_tab() -> String:
	return _tab


func _on_build_changed() -> void:
	if table.seated == null and _tab == "build":
		show_tab("parts") # the part left the table: back to choosing one
	elif is_open() or _tab == "build":
		_redraw_build()
	else:
		_build_dirty = true


func _on_opened() -> void:
	super._on_opened()
	if _build_dirty:
		_build_dirty = false
		_redraw_build()


func _build_content() -> Control:
	## Two tabs over two panes: Build (the feature list of the part on the table) and Parts (the assembly's parts, to put one on the
	## table or bring it to you: the assembly tree this window used to be).
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	var group := ButtonGroup.new()
	_tab_build = _tab_button("Build", "cat_feature", group, "build")
	_tab_parts = _tab_button("Parts", "assembly", group, "parts")
	tabs.add_child(_tab_build)
	tabs.add_child(_tab_parts)
	column.add_child(tabs)
	_parts_pane = super._build_content() # the assembly list: sets _status_label, _rows_box and scroll_target
	_parts_scroll = scroll_target
	_parts_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_parts_pane)
	_build_pane = _make_build_pane()
	_build_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_build_pane)
	_build_pane.visible = false
	_tab_parts.set_pressed_no_signal(true)
	return column


func _tab_button(text: String, icon_name: String, group: ButtonGroup, which: String) -> Button:
	var b := Button.new()
	b.text = text
	b.icon = UiIcons.texture(icon_name, 28)
	b.toggle_mode = true
	b.button_group = group
	b.theme_type_variation = &"ButtonRail"
	b.custom_minimum_size = Vector2(0, 56)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_stylebox_override("pressed", tokens.selected_box(tokens.accent))
	b.add_theme_stylebox_override("hover_pressed", tokens.selected_box(tokens.accent))
	b.pressed.connect(func() -> void: show_tab(which))
	return b


func _make_build_pane() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	box.add_child(title_row)
	_build_title = Label.new()
	_build_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_build_title)
	_rename_button = Button.new()
	_rename_button.text = "Rename"
	_rename_button.custom_minimum_size = Vector2(150, 52)
	_rename_button.pressed.connect(func() -> void: table.rename_part())
	title_row.add_child(_rename_button)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_build_scroll = scroll
	_build_rows = VBoxContainer.new()
	_build_rows.add_theme_constant_override("separation", 4)
	_build_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_build_rows)
	return box


# --- The Build tab ---------------------------------------------------------------------------

func _redraw_build() -> void:
	if _build_rows == null or table == null or table.build == null:
		return
	var build = table.build
	for child in _build_rows.get_children():
		_build_rows.remove_child(child)
		child.queue_free()
	_rename_button.visible = table.seated != null and table.editor.part_id != ""
	if table.seated == null:
		_build_title.text = "Nothing is on the table."
		_add_note("Carry a part over the slab, pick one in Parts, or press + for a new one.")
		return
	_build_title.text = "%s: %d feature(s)%s" % [build.part_name(), build.features.size(), "  (rolled back)" if build.is_rolled_back_any() else ""]
	if build.features.is_empty():
		_add_note("Nothing built yet. Pick a plane on the part and sketch.")
	var hidden: Array = build.hidden_ids()
	var groups := _group_strip(build)
	if groups != null:
		_build_rows.add_child(groups)
	for i in build.features.size():
		var f: Dictionary = build.features[i]
		var id := str(f.get("id", ""))
		_build_rows.add_child(_feature_row(build, i, f, hidden.has(id)))
		if id == build.selected_id:
			_build_rows.add_child(_action_strip(build, id, hidden.has(id)))
	if not build.view_filters_ok:
		_add_note("Hide / Show and Roll back are off: this backend is older than DIDSA-CAD 2026-10-03 and would ignore them. Update the backend to use them.")
	var bodies: Array = build.body_ids()
	if not bodies.is_empty():
		var heading := Label.new()
		heading.text = "Bodies"
		heading.theme_type_variation = &"LabelDim"
		_build_rows.add_child(heading)
		var named := BuildTree.body_names(bodies)
		for body_id in bodies:
			var b := Button.new()
			b.text = str(named[body_id])
			b.icon = UiIcons.texture("assembly", 24)
			b.toggle_mode = true
			b.set_pressed_no_signal(build.selected_body == str(body_id))
			b.theme_type_variation = &"ButtonRail"
			b.custom_minimum_size = Vector2(0, 52)
			b.add_theme_stylebox_override("pressed", tokens.selected_box(tokens.accent))
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.pressed.connect(func() -> void: build.select_body(str(body_id)))
			_build_rows.add_child(b)


const GROUPS := [[Visibility.SKETCHES, "Sketches"], [Visibility.BODIES, "Bodies"], [Visibility.SURFACES, "Surfaces"], [Visibility.CURVES, "3D curves"], [Visibility.PLANES, "Planes"]]
const EYE_LEFT := 60.0 ## px kept clear at the left of a row for its eye


func _eye_icon(state: String) -> String:
	return {"all": "eye", "some": "eye_half"}.get(state, "eye_off")


func _group_strip(build) -> Control:
	## The group headings: one eye per kind of feature the part has, acting on the whole kind exactly like the drawer's tile for it (all visible
	## -> hide all, otherwise show all). The list below stays in build order: rollback and the history depend on it.
	var strip := HFlowContainer.new()
	strip.add_theme_constant_override("h_separation", 6)
	strip.add_theme_constant_override("v_separation", 6)
	var any := false
	for g in GROUPS:
		var st: Dictionary = build.category_state(g[0])
		if st["total"] == 0:
			continue
		any = true
		var b := Button.new()
		b.text = " %s" % g[1]
		b.icon = UiIcons.texture(_eye_icon(st["state"]), 24)
		b.custom_minimum_size = Vector2(0, 48)
		b.add_theme_font_size_override("font_size", tokens.font_small)
		b.disabled = not build.view_filters_ok
		if st["state"] == "none":
			b.modulate = Color(1, 1, 1, 0.55)
		var category: String = g[0]
		b.pressed.connect(func() -> void: build.toggle_category(category))
		strip.add_child(b)
	return strip if any else null


func _padded(box: StyleBox, left: float) -> StyleBox:
	var padded: StyleBox = box.duplicate()
	padded.content_margin_left = maxf(padded.content_margin_left, 0.0) + left
	return padded


func _add_note(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.theme_type_variation = &"LabelDim"
	_build_rows.add_child(l)


func _feature_row(build, index: int, f: Dictionary, is_hidden: bool) -> Button:
	var id := str(f.get("id", ""))
	var type := str(f.get("type", ""))
	var rolled: bool = build.is_rolled_back(id)
	var b := Button.new()
	b.toggle_mode = true
	b.set_pressed_no_signal(id == build.selected_id)
	b.theme_type_variation = &"ButtonRail"
	b.icon = UiIcons.texture(BuildTree.glyph(type), 28)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.custom_minimum_size = Vector2(0, 60)
	var line2: String = BuildTree.summary(build.features, index)
	var state := ""
	if is_hidden:
		var seed_note: String = build.auto_note(id)
		state = "  · %s" % (seed_note if seed_note != "" else "hidden")
	if rolled:
		state += "  · rolled back"
	var reference_note := BuildTree.reference_note(f)
	if reference_note != "":
		state += "  · %s" % reference_note
		b.add_theme_color_override("font_color", tokens.warn)
	b.text = "%s   %s%s" % [build.names[index], line2, state]
	# Room at the left for the eye, then the eye itself laid over the row: one tap hides or shows the feature without selecting it first.
	for state_name in ["normal", "hover", "focus", "disabled"]:
		b.add_theme_stylebox_override(state_name, _padded(b.get_theme_stylebox(state_name), EYE_LEFT))
	b.add_theme_stylebox_override("pressed", _padded(tokens.selected_box(tokens.accent), EYE_LEFT))
	b.add_theme_stylebox_override("hover_pressed", _padded(tokens.selected_box(tokens.accent), EYE_LEFT))
	if is_hidden or rolled:
		b.modulate = Color(1, 1, 1, 0.5)
	b.pressed.connect(func() -> void: build.select(id))
	var eye := Button.new()
	eye.name = "Eye"
	eye.flat = true
	eye.icon = UiIcons.texture("eye_off" if is_hidden else "eye", 28)
	eye.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	eye.expand_icon = false
	eye.disabled = not build.view_filters_ok
	eye.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	eye.offset_left = 4.0
	eye.offset_right = EYE_LEFT - 4.0
	eye.offset_top = 4.0
	eye.offset_bottom = -4.0
	eye.pressed.connect(func() -> void: build.toggle_hidden(id))
	b.add_child(eye)
	return b


func _action_strip(build, id: String, is_hidden: bool) -> Control:
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 4)
	var edit := _strip_button("Edit", "settings", func() -> void: build.edit_selected())
	edit.disabled = not build.can_edit(id)
	strip.add_child(edit)
	if not BuildTree.fix_target(build.row(id)).is_empty():
		var fix := _strip_button("Fix", "settings", func() -> void: build.fix_selected())
		fix.theme_type_variation = &"ButtonAccent" # a flagged reference: re-pick it
		strip.add_child(fix)
	var picks = table.editor.sketch_picks if table.editor.state == "pick_curves" else null
	if picks != null and is_instance_valid(picks) and picks.sketches.has(id):
		var on: bool = bool(picks.sketches[id]["included"])
		var lines_button := _strip_button("Lines: on" if on else "Lines: off", "visibility", func() -> void:
			picks.set_included(id, not on)
			_redraw_build())
		strip.add_child(lines_button) # a finished sketch's lines are picked for a Loft / Sweep / Pattern; off leaves them out
	var hide_button := _strip_button("Show" if is_hidden else "Hide", "visibility", func() -> void: build.toggle_hidden_selected())
	hide_button.disabled = not build.view_filters_ok
	strip.add_child(hide_button)
	var is_last: bool = build.index_of(id) >= build.features.size() - 1
	var back := _strip_button("Roll forward" if build.rollback_to == id else "Roll back", "history", func() -> void: build.toggle_rollback_selected())
	back.disabled = (is_last and build.rollback_to != id) or not build.view_filters_ok
	strip.add_child(back)
	var delete := _strip_button("Sure?" if build.armed(id) else "Delete", "close", func() -> void: build.delete_selected())
	delete.theme_type_variation = &"ButtonDanger"
	strip.add_child(delete)
	return strip


func _strip_button(text: String, icon_name: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text # words only: four buttons share one narrow row, and an icon beside "Roll back" cut it short
	b.custom_minimum_size = Vector2(0, 52)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", tokens.font_small)
	b.pressed.connect(callback)
	return b


func _place_in_front_of_camera() -> void:
	## Docked at the console's left instead of in front of the camera.
	transform = Transform3D(Basis(Vector3.UP, deg_to_rad(dock_yaw_degrees)), dock_position)


func _add_row_actions(line: HBoxContainer, row: Dictionary, _is_expandable: bool) -> void:
	var occurrence_id := str(row.get("id", ""))
	if occurrence_id == "": # the root row is the assembly itself
		return
	var node: Node3D = table.node_for_occurrence(occurrence_id) if table else null
	var on_table: bool = node != null and node == table.seated
	line.add_child(_action("Table", "table", node != null and not on_table, _take_to_table.bind(occurrence_id), &"ButtonAccent"))
	line.add_child(_action("Bring", "scale", node != null and not on_table, _bring.bind(occurrence_id), &""))


func _action(text: String, icon_name: String, enabled: bool, callback: Callable, variation: StringName) -> Button:
	var b := Button.new()
	b.text = text
	b.icon = UiIcons.texture(icon_name, 24)
	b.disabled = not enabled
	b.custom_minimum_size = Vector2(0, 0)
	b.add_theme_font_size_override("font_size", tokens.font_small)
	if variation != &"":
		b.theme_type_variation = variation
	b.pressed.connect(callback)
	return b


func _take_to_table(occurrence_id: String) -> void:
	if table == null:
		return
	var node: Node3D = table.node_for_occurrence(occurrence_id)
	if node == null:
		_set_status("That part isn't in the arena (hidden, or a sub-assembly with no body of its own).")
		return
	var reason: String = table.seat_node(node)
	_set_status(reason)
	_rebuild_rows()


func _bring(occurrence_id: String) -> void:
	if table == null:
		return
	var node: Node3D = table.node_for_occurrence(occurrence_id)
	if node == null:
		_set_status("That part isn't in the arena (hidden, or a sub-assembly with no body of its own).")
		return
	_set_status(table.bring_part(node))
