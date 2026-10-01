extends Control
## UI Lab: the redesigned look in a plain desktop window, no headset, no backend.
##
##   Godot editor -> open res://lab/ui_lab.tscn -> F6.
##
## To tune the look: open res://ui/didsa_ui_theme.tres in the Inspector, change a
## colour / radius / font size, save, press F6 again. Everything below is built
## from that one resource, exactly as the tablet, windows and keyboard will be.
##
## Phase 1: a style sheet laid out like the new tablet (category grid, utility
## cluster, tool rail, controls pane, side panel, status line) so the direction
## can be judged before the real shell exists. Phase 2 replaces the stand-in
## widgets with the real shell fed by a stub context.

const THEME_PATH := "res://ui/didsa_ui_theme.tres"
const CATEGORY_ACCENTS := {
	"View": Color(0.35, 0.78, 0.95), "Assembly": Color(0.95, 0.72, 0.35),
	"Windows": Color(0.72, 0.60, 0.95), "Files": Color(0.50, 0.85, 0.60),
}

var tokens: Resource


func _ready() -> void:
	tokens = load(THEME_PATH)
	theme = tokens.build_theme()
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.03, 0.05)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 28)
	row.offset_left = 40; row.offset_top = 40; row.offset_right = -40; row.offset_bottom = -40
	add_child(row)
	row.add_child(_tablet_mock())
	row.add_child(_side_panel_mock())


func _tablet_mock() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 2.6
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", tokens.gap + 4)
	panel.add_child(column)

	# Top bar: category grid (left), utility cluster (right).
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", tokens.gap)
	column.add_child(top)
	var cats := GridContainer.new()
	cats.columns = 4
	cats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cats.add_theme_constant_override("h_separation", tokens.gap)
	cats.add_theme_constant_override("v_separation", tokens.gap)
	top.add_child(cats)
	var group := ButtonGroup.new()
	for name in CATEGORY_ACCENTS:
		var b := Button.new()
		b.text = name
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(0, 64)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_pressed = (name == "Assembly")
		if b.button_pressed:
			b.add_theme_stylebox_override("pressed", tokens.selected_box(CATEGORY_ACCENTS[name]))
		cats.add_child(b)
	var divider := ColorRect.new()
	divider.custom_minimum_size = Vector2(2, 0)
	divider.color = tokens.border
	top.add_child(divider)
	var utility := HBoxContainer.new()
	utility.add_theme_constant_override("separation", tokens.gap)
	top.add_child(utility)
	for label in ["Undo", "Redo", "Set", "X"]:
		var u := Button.new()
		u.text = label
		u.custom_minimum_size = Vector2(72, 64)
		u.disabled = (label == "Redo")
		if label == "X":
			u.theme_type_variation = &"ButtonDanger"
		utility.add_child(u)

	# Body: tool rail + controls pane.
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", tokens.gap + 4)
	column.add_child(body)
	var rail := VBoxContainer.new()
	rail.add_theme_constant_override("separation", tokens.gap)
	body.add_child(rail)
	var rail_group := ButtonGroup.new()
	for tool_name in ["Mates", "Colours", "Sections", "Measure"]:
		var t := Button.new()
		t.text = tool_name
		t.theme_type_variation = &"ButtonRail"
		t.toggle_mode = true
		t.button_group = rail_group
		t.custom_minimum_size = Vector2(150, 64)
		t.button_pressed = (tool_name == "Mates")
		rail.add_child(t)
	body.add_child(_controls_mock())
	return panel


func _controls_mock() -> Control:
	var pane := VBoxContainer.new()
	pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pane.add_theme_constant_override("separation", tokens.gap + 2)

	var header := HBoxContainer.new()
	pane.add_child(header)
	var title := Label.new()
	title.text = "Mates"
	title.theme_type_variation = &"LabelTitle"
	header.add_child(title)
	var chip := Label.new()
	chip.text = "  ASSEMBLY"
	chip.theme_type_variation = &"LabelSmall"
	chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(chip)
	var on := Button.new()
	on.text = "Tool: ON"
	on.toggle_mode = true
	on.button_pressed = true
	header.add_child(on)

	var hint := Label.new()
	hint.text = "Laser-target a face, then a face on a second part."
	hint.theme_type_variation = &"LabelDim"
	pane.add_child(hint)

	var picks := PanelContainer.new()
	picks.theme_type_variation = &"PanelRaised"
	var picks_label := Label.new()
	picks_label.text = "Picked: Bracket_Main · F14"
	picks.add_child(picks_label)
	pane.add_child(picks)

	var type_row := HBoxContainer.new()
	type_row.add_theme_constant_override("separation", tokens.gap)
	pane.add_child(type_row)
	var type_group := ButtonGroup.new()
	for type_name in ["Coincident", "Concentric", "Parallel", "Distance", "Angle"]:
		var b := Button.new()
		b.text = type_name
		b.toggle_mode = true
		b.button_group = type_group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_pressed = (type_name == "Concentric")
		type_row.add_child(b)

	var slider_caption := Label.new()
	slider_caption.text = "Travel speed: 6.0 m/s"
	slider_caption.theme_type_variation = &"LabelDim"
	pane.add_child(slider_caption)
	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(0, 52)
	slider.value = 40
	pane.add_child(slider)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", tokens.gap)
	pane.add_child(actions)
	var create := Button.new()
	create.text = "Create mate"
	create.theme_type_variation = &"ButtonAccent"
	create.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(create)
	var off := Button.new()
	off.text = "Disabled"
	off.disabled = true
	off.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(off)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pane.add_child(spacer)
	var status := PanelContainer.new()
	status.theme_type_variation = &"PanelRaised"
	var status_label := Label.new()
	status_label.text = "●  Pick the second face — trigger to confirm"
	status_label.theme_type_variation = &"LabelDim"
	status.add_child(status_label)
	pane.add_child(status)
	return pane


func _side_panel_mock() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", tokens.gap)
	panel.add_child(column)
	var title := Label.new()
	title.text = "Mates  3"
	title.theme_type_variation = &"LabelTitle"
	column.add_child(title)
	for entry in [["Coincident", "Plate ↔ Bracket", ""], ["Concentric", "Pin 4 ↔ Hole 3", ""], ["Distance 12.5 mm", "Redundant", "warn"]]:
		var card := PanelContainer.new()
		card.theme_type_variation = &"PanelRaised"
		var inner := VBoxContainer.new()
		var name_label := Label.new()
		name_label.text = entry[0]
		inner.add_child(name_label)
		var sub := Label.new()
		sub.text = entry[1]
		sub.theme_type_variation = &"LabelDim"
		if entry[2] == "warn":
			sub.add_theme_color_override("font_color", tokens.warn)
		inner.add_child(sub)
		card.add_child(inner)
		column.add_child(card)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)
	var delete := Button.new()
	delete.text = "Delete mate"
	delete.theme_type_variation = &"ButtonDanger"
	column.add_child(delete)
	return panel
