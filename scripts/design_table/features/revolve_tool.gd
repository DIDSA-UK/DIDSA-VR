extends "res://scripts/design_table/features/feature_tool.gd"
## Revolve: the open sketch's closed profile spun about one of the sketch's lines.


func _init() -> void:
	id = "revolve"


func options(ed) -> Array:
	return [
		{"id": "boss", "text": "Boss", "toggle": true, "pressed": bool(ed.options["boss"])},
		{"id": "cut", "text": "Cut", "toggle": true, "pressed": not bool(ed.options["boss"])},
		{"id": "angle", "text": "Angle %s deg" % ed.BuildTree.number(float(ed.options["angle"]))},
		{"id": "axis", "text": "Axis: set" if ed.revolve_axis != "" else "Axis: pick"},
		{"id": "apply", "text": "Apply", "disabled": not can_apply(ed)},
	]


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"boss":
			ed.options["boss"] = true
		"cut":
			ed.options["boss"] = false
		"angle":
			ed.type_option("angle", "Angle (deg, up to 360)")
		"axis":
			ed.table.set_status("Pull the trigger on a line of the sketch to make it the axis.")
		_:
			return false
	return true


func on_activated(ed) -> void:
	if ed.session == null:
		ed.table.set_status("Draw a closed shape and a line on a plane first.")
	elif not ed.session.profile_ok():
		ed.table.set_status("The sketch needs a closed shape to revolve (and a line to spin it about).")
	if ed.state in ["pick_edges", "extrude"]:
		ed.set_state("sketch" if ed.session != null else "pick_plane") # the laser picks the axis line on the sketch, so the sketch stays live


func can_apply(ed) -> bool:
	return ed.session != null and ed.session.profile_ok() and ed.revolve_axis != ""


func finishes_sketch() -> bool:
	return true


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	if ed.session == null or not ed.session.profile_ok():
		return PartFeatures._bad("The sketch needs a closed shape to revolve.")
	return PartFeatures.revolve_request(ed.session.feature_id, ed.session.sketch_id, ed.revolve_axis, float(ed.options["angle"]), bool(ed.options["boss"]), ed.extrude_targets())
