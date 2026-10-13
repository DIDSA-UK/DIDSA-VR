extends SceneTree
## The docked PROPERTIES panel (scripts/design_table/table_props_window.gd) that replaced the deck's options row: it opens with a tool
## that has settings and shows every one of them, one per row (toggles grouped), with the tool's name and hint above; a press reaches the
## editor like the row's did; it follows the tool and the options (greys Apply, rewrites a label); it goes away with no tool; the deck's
## own row stays hidden; buttons pair two to a line and toggles wrap four to a line, with `wide` and `group` honoured (Phase 7.0); it is docked at the console's right and follows the slab when it is resized; closing the table puts it away.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_props_panel.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var table = rig.table
	var ed = rig.ed
	var props = table.props
	print("SMOKE the properties window exists, docked at the console's right, open with the console (it carries the tool tip): ", props != null and props.dock_position.x > 0.0 and props.is_open())
	await rig.draw_rectangle()
	table.manager.activate("extrude")
	await rig.frames(3)
	print("SMOKE choosing Extrude opens the panel: ", props.is_open())
	print("SMOKE ...and a Selected list says the open sketch has a closed shape ready: ", props.selection_text().begins_with("SELECTED") and props.selection_text().contains("closed shape ready"), " ", props.selection_text())
	print("SMOKE ...it lists every setting of the tool, as the deck's row did: ", props.option_ids() == ["boss", "cut", "flip", "ext_sym", "new_body", "depth", "ext_thin", "ext_draft", "apply"], " ", props.option_ids())
	print("SMOKE ...under the tool's name and its hint: ", props._title.text == "Extrude" and props._hint.text.contains("Boss or Cut"))
	print("SMOKE ...the deck's own options row stays hidden and the deck finds the buttons in the panel: ", not table.ui._options_row.visible and table.ui.option_button("flip") == props.option_button("flip") and props.option_button("flip") != null)
	var boss: Button = props.option_button("boss")
	print("SMOKE ...Boss is shown pressed, Apply is on (the sketch has a closed shape): ", boss.button_pressed and not props.option_button("apply").disabled)
	props.option_button("flip").pressed.emit()
	await rig.frames(2)
	print("SMOKE a press in the panel reaches the editor: Flip is on, and the panel shows it: ", bool(ed.options["flip"]) and props.option_button("flip").button_pressed)
	props.option_button("cut").pressed.emit()
	await rig.frames(2)
	print("SMOKE Cut takes New body away (the panel is rebuilt from the tool's list): ", props.option_button("new_body") == null and props.option_ids().size() == 8)
	table.manager.activate("fillet")
	await rig.frames(3)
	print("SMOKE changing tool changes the panel: Fillet shows Radius, Clear and a greyed Apply: ", props._title.text == "Fillet" and props.option_ids() == ["radius", "clear_edges", "apply"] and props.option_button("apply").disabled)
	print("SMOKE ...Fillet has no toggles, so no toggle group: ", _groups(props) == 0)
	print("SMOKE ...its Radius and Clear share one line, and Apply has a line of its own: ", props.option_button("radius").get_parent() == props.option_button("clear_edges").get_parent() and props.option_button("apply").get_parent() == props._rows)
	table.manager.activate("extrude")
	await rig.frames(3)
	print("SMOKE ...and Extrude's toggles are one group before Depth and one for Thin wall / Draft after it: ", _groups(props) == 2)
	table.manager.deactivate()
	await rig.frames(3)
	print("SMOKE with no tool the panel stays (tip only) with no settings: ", props.is_open() and not props.has_options())
	table.manager.activate("polygon")
	await rig.frames(3)
	print("SMOKE a sketch tool with settings opens it too (Polygon: Fewer, the count, More): ", props.is_open() and props.option_ids() == ["sides_down", "sides_label", "sides_up"])
	props.set_options([
		{"id": "a", "text": "Count 3"}, {"id": "b", "text": "Spacing 25.00 mm"},
		{"id": "c", "text": "A long label that cannot share a half line"}, {"id": "d", "text": "Short", "wide": true},
		{"id": "e", "text": "One"}, {"id": "f", "text": "Two"}, {"id": "g", "text": "Three"},
		{"id": "t1", "text": "T1", "toggle": true}, {"id": "t2", "text": "T2", "toggle": true},
		{"id": "h", "text": "Angle", "group": "Draft"}, {"id": "i", "text": "Outward", "toggle": true, "group": "Draft"},
		{"id": "apply", "text": "Apply"}])
	await rig.frames(2)
	print("SMOKE layout: two short buttons share a line: ", props.option_button("a").get_parent() == props.option_button("b").get_parent() and props.option_button("a").get_parent() is HBoxContainer)
	print("SMOKE ...a long label and a `wide` option each take a whole line: ", props.option_button("c").get_parent() == props._rows and props.option_button("d").get_parent() == props._rows)
	print("SMOKE ...pairing restarts after a wide one: One and Two share a line, Three starts the next: ", props.option_button("e").get_parent() == props.option_button("f").get_parent() and props.option_button("g").get_parent() != props.option_button("f").get_parent())
	print("SMOKE ...toggles are chips in one flow group and rows are 44 px: ", props.option_button("t1").get_parent() == props.option_button("t2").get_parent() and props.option_button("t1").get_parent() is HFlowContainer and props.option_button("a").custom_minimum_size.y == 44.0 and props.option_button("t1").custom_minimum_size.x == 110.0)
	print("SMOKE ...a `group` puts a caption over the run, and every option is still listed and routes: ", _captions(props) == ["DRAFT"] and props.option_ids().size() == 12)
	var got: Array = []
	props.option_pressed.connect(func(id: String) -> void: got.append(id))
	props.option_button("h").pressed.emit()
	print("SMOKE ...pressing a grouped option emits its id: ", got == ["h"])
	var before: float = props.position.x
	table.set_slab_size(table.slab_size + Vector2(0.2, 0.0))
	print("SMOKE resizing the slab moves the panel out with its edge: ", is_equal_approx(props.position.x - before, 0.1) and is_equal_approx(props.dock_position.x, table.slab_size.x * 0.5 + 0.20))
	table.close()
	await rig.frames(2)
	print("SMOKE closing the table puts the panel away: ", not props.is_open())
	quit()


func _groups(props) -> int:
	var n := 0
	for child in props._rows.get_children():
		if child is HFlowContainer:
			n += 1
	return n


func _captions(props) -> Array:
	var out: Array = []
	for child in props._rows.get_children():
		if child is Label:
			out.append(child.text)
	return out
