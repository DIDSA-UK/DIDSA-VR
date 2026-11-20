extends SceneTree
## F7 follow-up: the deck's "Colours: Structure / Exact" switch (opt-in, off by default) reaches the sketch. Only while a sketch is open does the button show; pressing it sets
## `DesignTable.exact_colours` and the session's `exact_colours`, redraws the sketch, says what it means on the status line, and turning it off gives the structure colours back.
## The colours themselves are tested in sketch_rigidity_wiring.gd; this is the wiring.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_exact_colours.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var table = rig.table
	var ed = rig.ed
	await rig.draw_rectangle()
	await rig.frames(3)
	var button: Button = table.ui.colours_button()
	_check(button != null and button.visible and not button.disabled and button.text == "Colours: Structure" and not table.exact_colours, "with a sketch open the Colours button shows, reading Structure, and exact colours are off")
	_check(not ed.session.exact_colours, "...the session is on the structure colours")
	var before: int = ed.view.stats["pieces_drawn"]
	button.button_pressed = true
	await rig.frames(2)
	_check(table.exact_colours and ed.session.exact_colours and button.text == "Colours: Exact", "pressing it turns exact colours on in the table and the session, and the button says so")
	_check(ed.view.stats["pieces_drawn"] >= before and table.status().contains("Exact colours"), "...the sketch was drawn again and the status line says what it means: %s" % table.status())
	button.button_pressed = false
	await rig.frames(2)
	_check(not table.exact_colours and not ed.session.exact_colours and button.text == "Colours: Structure" and table.status().contains("Structure colours"), "turning it off gives the structure colours back")
	print("SMOKE ", "PASSED" if failures == 0 else "FAILED %d" % failures)
	quit(1 if failures > 0 else 0)
