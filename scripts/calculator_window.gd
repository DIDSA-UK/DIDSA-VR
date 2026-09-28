extends "res://scripts/diegetic_panel.gd"
## Milestone 3's Calculator window: the simplest of the three new floating
## windows, built first specifically to prove several diegetic_panel.gd
## windows can be open and interactive at once (see docs/status.md) before
## the Assembly Tree window (this repo's real, higher-value deliverable)
## was trusted to share the same arbitration. No backend calls, no
## dependency on the loaded assembly at all.

var _display: Label
var _expression_text := ""


func setup_calculator(left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	panel_title = "Calculator"
	panel_size = Vector2(0.20, 0.28)
	viewport_size = Vector2i(360, 500)
	open_distance = 0.55
	open_lateral_offset = 0.0
	super.setup(left, right, camera)


func _build_content() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)

	_display = Label.new()
	_display.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_display.add_theme_font_size_override("font_size", 40)
	_display.text = "0"
	box.add_child(_display)

	var rows := [
		["7", "8", "9", "÷"],
		["4", "5", "6", "×"],
		["1", "2", "3", "-"],
		["C", "0", ".", "+"],
	]
	for row_keys in rows:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		box.add_child(row)
		for key in row_keys:
			var button := Button.new()
			button.text = key
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.pressed.connect(_key_pressed.bind(key))
			row.add_child(button)

	var equals := Button.new()
	equals.text = "="
	equals.pressed.connect(_evaluate)
	box.add_child(equals)

	return box


func _key_pressed(key: String) -> void:
	if key == "C":
		_expression_text = ""
	else:
		_expression_text += ("*" if key == "×" else "/" if key == "÷" else key)
	_display.text = _expression_text if _expression_text != "" else "0"


func _evaluate() -> void:
	if _expression_text == "":
		return
	var result := evaluate_expression(_expression_text)
	if result["ok"]:
		_display.text = result["text"]
		_expression_text = result["text"]
	else:
		_display.text = "Error"
		_expression_text = ""


static func evaluate_expression(text: String) -> Dictionary:
	## Pure (no UI): {"ok": bool, "text": String} - "text" is the formatted
	## result on success, or empty on failure. Used directly by
	## tests/calculator_window.gd. Godot's own Expression class does the
	## actual parsing/arithmetic - but, caught by actually running this
	## against a real Godot instead of only inspecting the code (see
	## docs/status.md), it does real integer division for two integer
	## literals exactly like GDScript itself does ("10/4" -> 2, not 2.5),
	## so every bare integer literal is floatified first via _floatify()
	## below - a calculator silently truncating "10/4" to "2" would be a
	## real, user-facing wrong-answer bug, not just a formatting quirk.
	var expr := Expression.new()
	if expr.parse(_floatify(text)) != OK:
		return {"ok": false, "text": ""}
	var value = expr.execute([], null, false)
	if expr.has_execute_failed():
		return {"ok": false, "text": ""}
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return {"ok": false, "text": ""}
	return {"ok": true, "text": _trim_number(float(value))}


static func _floatify(text: String) -> String:
	## Appends ".0" to every bare integer literal (one not already part of
	## a decimal number) so Expression always divides as float - matching
	## `\d+\.\d+|\d+`'s own alternation order (try the full decimal-number
	## shape first) is what keeps an already-typed "2.5" as one match
	## rather than splitting it into "2" + "." + "5" and mangling it.
	var re := RegEx.new()
	re.compile("\\d+\\.\\d+|\\d+")
	var result := ""
	var last_end := 0
	for m in re.search_all(text):
		var matched: String = m.get_string()
		result += text.substr(last_end, m.get_start() - last_end)
		result += matched if matched.contains(".") else matched + ".0"
		last_end = m.get_end()
	result += text.substr(last_end)
	return result


static func _trim_number(x: float) -> String:
	return ("%.6f" % x).rstrip("0").rstrip(".")
