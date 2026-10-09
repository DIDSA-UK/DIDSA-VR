extends "res://scripts/design_table/features/feature_tool.gd"
## Revolve: a sketch's closed profile spun about a line of any sketch. The sketch is the open one, or (with none open) a visible finished one
## picked in the viewport, then a line of any visible sketch for the axis.


func _init() -> void:
	id = "revolve"


func options(ed) -> Array:
	var list := [
		{"id": "boss", "text": "Boss", "toggle": true, "pressed": bool(ed.options["boss"])},
		{"id": "cut", "text": "Cut", "toggle": true, "pressed": not bool(ed.options["boss"])},
		{"id": "angle", "text": "Angle %s deg" % ed.BuildTree.number(float(ed.options["angle"]))},
		{"id": "axis", "text": "Axis: set" if ed.revolve_axis != "" else "Axis: pick"},
		{"id": "apply", "text": "Apply", "disabled": not can_apply(ed)},
	]
	if ed.session == null and ed.seed_sketch != "":
		list.insert(4, {"id": "clear_seed", "text": "Clear"}) # forget the picked profile and axis
	if ed.session == null:
		list.insert(list.size() - 1, ed.targets_option())
	return list


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"boss":
			ed.options["boss"] = true
		"cut":
			ed.options["boss"] = false
		"angle":
			ed.type_option("angle", "Angle (deg, up to 360)")
		"clear_seed":
			ed.clear_seed()
		"targets":
			ed.toggle_target_picking()
		"axis":
			ed.table.set_status("Pull the trigger on a line of the sketch to make it the axis.")
			if ed.session == null and ed.seed_sketch == "":
				ed.table.set_status("Pull the trigger on a line of a sketch to use it, then on a line of it for the axis.")
		_:
			return false
	return true


func on_activated(ed) -> void:
	if ed.session == null:
		ed.start_sketch_pick() # no sketch open: the visible finished sketches are offered
		return
	if not ed.session.profile_ok():
		ed.table.set_status("The sketch needs a closed shape to revolve (and a line to spin it about).")
	if ed.state in ["pick_edges", "extrude"]:
		ed.set_state("sketch" if ed.session != null else "pick_plane") # the laser picks the axis line on the sketch, so the sketch stays live


func can_apply(ed) -> bool:
	return ed.seed_ready() and ed.revolve_axis != ""


func finishes_sketch() -> bool:
	return true ## spends the OPEN sketch (the editor only ends one that is open)


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	if not ed.seed_ready():
		return PartFeatures._bad("The sketch needs a closed shape to revolve.")
	return PartFeatures.revolve_request(ed.seed_sketch_id(), ed.seed_axis_sketch_id(), ed.revolve_axis, float(ed.options["angle"]), bool(ed.options["boss"]), ed.extrude_targets())
