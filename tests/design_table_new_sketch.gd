extends SceneTree
## The deck's NEW SKETCH path (table_ui.gd, table_editor.gd new_sketch()): a button larger than a tool button heads the Sketch and
## Constrain tabs; their tools are dimmed (still pressable) until a sketch is open; New sketch with a sketch open ends it and asks for a
## plane or flat face; with no part on the table it is greyed. Fake backend, headless.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_new_sketch.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var table = rig.table
	var ed = rig.ed
	var ui = table.ui
	var nb: Button = ui.new_sketch_button()
	var tool_btn: Button = ui.tool_button("line")
	print("SMOKE New sketch is on the Sketch tab, enabled with a part on the table, and bigger than a tool button: ", nb.is_visible_in_tree() and not nb.disabled and nb.custom_minimum_size.x > tool_btn.custom_minimum_size.x and nb.custom_minimum_size.y > tool_btn.custom_minimum_size.y)
	print("SMOKE ...and the sketch tools are dimmed until a sketch is open: ", ui.tools_dimmed() and ed.session == null)
	ui.select_category("feature")
	print("SMOKE the Feature tab has no New sketch button and its tools are not dimmed: ", not nb.is_visible_in_tree() and not ui.tools_dimmed())
	ui.select_category("constrain")
	print("SMOKE the Constrain tab is dimmed too, with New sketch: ", ui.tools_dimmed() and nb.is_visible_in_tree())
	ui.select_category("sketch")

	var top: Dictionary = rig.top_face()
	await ed.begin_sketch({"face": {"body_id": top["body_id"], "index": top["index"]}})
	await rig.frames(2)
	print("SMOKE with a sketch open the tools are not dimmed: ", ed.session != null and not ui.tools_dimmed())

	nb.pressed.emit()
	await rig.settle(func() -> bool: return ed.session == null)
	print("SMOKE New sketch ends the open sketch, no tool stays on, and plane picking is asked for: ", ed.session == null and ed.state == "pick_plane" and table.active_tool == "" and table.status().begins_with("Aim at a flat face"))
	print("SMOKE ...and the tools are dimmed again: ", ui.tools_dimmed())

	table.return_part()
	await rig.frames(3)
	print("SMOKE with no part on the table New sketch is greyed: ", nb.disabled)
	ui.new_sketch_pressed.emit()
	await rig.frames(2)
	print("SMOKE ...and asking for one anyway says to put a part on the table: ", table.status().contains("part on the table"))
	quit()
