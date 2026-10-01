extends SceneTree
## The contextual list panel's UI (scripts/ui/side_panel_ui.gd), no XR: rows from plain data,
## no rebuild (and so no flicker / lost scroll) when polled with unchanged data, empty text,
## state colouring, and the two-tap confirm on destructive actions.
## Run: "$GODOT" --headless --path . --script res://tests/side_panel_ui.gd  (see tests/README.md)

func _find_btn(n: Node, text: String) -> Button:
	if n is Button and n.text == text:
		return n
	for c in n.get_children():
		var f := _find_btn(c, text)
		if f:
			return f
	return null

func _initialize() -> void:
	var tokens: Resource = load("res://ui/didsa_ui_theme.tres")
	var panel = load("res://scripts/ui/side_panel_ui.gd").new()
	root.add_child(panel)
	panel.setup(tokens, Vector2(452, 693))
	var hits := [0]
	var rows := [
		{"id": "a", "title": "Coincident", "subtitle": "Plate", "state": "warn", "actions": [{"label": "Delete", "danger": true, "confirm": true, "callback": func() -> void: hits[0] += 1}]},
		{"id": "b", "title": "Concentric", "subtitle": "", "state": "normal"},
	]
	panel.set_list("Mates", rows, "No mates yet.")
	await process_frame
	print("SMOKE rows become cards and the title shows with a count: ", panel.row_count() == 2 and panel._title.text == "Mates" and panel._count.text == "2")
	var first: Node = panel._rows.get_child(0)
	panel.set_list("Mates", rows.duplicate(true), "No mates yet.")
	print("SMOKE polling with unchanged data does not rebuild the list (no flicker, scroll kept): ", panel._rows.get_child(0) == first)
	var changed := rows.duplicate(true)
	changed[1]["title"] = "Parallel"
	panel.set_list("Mates", changed, "No mates yet.")
	await process_frame
	print("SMOKE changed data does rebuild it: ", panel._rows.get_child(0) != first and panel.row_count() == 2)
	panel.set_list("Mates", [], "No mates yet.")
	await process_frame
	print("SMOKE an empty list shows the empty text and no count: ", panel.row_count() == 1 and (panel._rows.get_child(0) as Label).text == "No mates yet." and panel._count.text == "")
	panel.set_list("Mates", rows, "No mates yet.")
	await process_frame
	var del: Button = _find_btn(panel, "Delete")
	print("SMOKE a danger action is drawn as a danger button: ", del != null and del.theme_type_variation == &"ButtonDanger")
	del.pressed.emit()
	print("SMOKE a confirm action's first press only asks 'Sure?' (nothing deleted): ", del.text == "Sure?" and hits[0] == 0)
	del.pressed.emit()
	print("SMOKE the second press runs it once and the label resets: ", hits[0] == 1 and del.text == "Delete")
	var warn_label: Label = null
	for n in panel.find_children("*", "Label", true, false):
		if (n as Label).text == "Plate":
			warn_label = n
	print("SMOKE a warn row's subtitle is coloured amber: ", warn_label != null and warn_label.get_theme_color("font_color") == tokens.warn)
	quit()
