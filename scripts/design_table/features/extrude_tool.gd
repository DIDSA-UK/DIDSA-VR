extends "res://scripts/design_table/features/feature_tool.gd"
## Extrude: the open sketch's closed profile, as a boss (grows out of a face) or a cut (into the part).


func _init() -> void:
	id = "extrude"


func options(ed) -> Array:
	var list := [
		{"id": "boss", "text": "Boss", "toggle": true, "pressed": bool(ed.options["boss"])},
		{"id": "cut", "text": "Cut", "toggle": true, "pressed": not bool(ed.options["boss"])},
		{"id": "flip", "text": "Flip", "toggle": true, "pressed": bool(ed.options["flip"])},
		{"id": "depth", "text": "Depth %.2f mm" % float(ed.options["depth"])},
		{"id": "apply", "text": "Apply", "disabled": not can_apply(ed)},
	]
	if bool(ed.options["boss"]):
		list.insert(3, {"id": "new_body", "text": "New body", "toggle": true, "pressed": bool(ed.options["new_body"])})
	return list


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"boss":
			ed.options["boss"] = true
		"cut":
			ed.options["boss"] = false
		"flip":
			ed.options["flip"] = not bool(ed.options["flip"])
		"new_body":
			ed.options["new_body"] = not bool(ed.options["new_body"])
		"depth":
			ed.type_option("depth", "Depth (mm)")
		_:
			return false
	return true


func on_activated(ed) -> void:
	if ed.session == null:
		ed.table.set_status("Draw a closed shape on a plane first.")
	elif not ed.session.profile_ok():
		ed.table.set_status("The sketch needs a closed shape to extrude.")
	ed.set_state("extrude" if ed.session != null else ed.state)


func can_apply(ed) -> bool:
	return ed.session != null and ed.session.profile_ok()


func finishes_sketch() -> bool:
	return true


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	if not can_apply(ed):
		return PartFeatures._bad("The sketch needs a closed shape to extrude.")
	var d: Array = ed.extrude_distances()
	return PartFeatures.extrude_request(ed.session.feature_id, bool(ed.options["boss"]), d[0], d[1], ed.extrude_targets())
