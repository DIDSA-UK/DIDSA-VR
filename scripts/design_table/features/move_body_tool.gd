extends "res://scripts/design_table/features/feature_tool.gd"
## Move Body: translate a body by X / Y / Z mm (negative goes the other way), optionally leaving a copy behind. (Rotation about an axis is in the backend
## but not offered here yet.)


func _init() -> void:
	id = "move_body"


func options(ed) -> Array:
	return [
		{"id": "mb_dx", "text": "X %.2f mm" % float(ed.options["mb_dx"])},
		{"id": "mb_dy", "text": "Y %.2f mm" % float(ed.options["mb_dy"])},
		{"id": "mb_dz", "text": "Z %.2f mm" % float(ed.options["mb_dz"])},
		{"id": "mb_copy", "text": "Make a copy", "toggle": true, "pressed": bool(ed.options["mb_copy"])},
		{"id": "clear_bodies", "text": "Clear"},
		{"id": "apply", "text": "Apply", "disabled": not can_apply(ed)},
	]


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"mb_dx":
			ed.type_option("mb_dx", "Move X (mm)")
		"mb_dy":
			ed.type_option("mb_dy", "Move Y (mm)")
		"mb_dz":
			ed.type_option("mb_dz", "Move Z (mm)")
		"mb_copy":
			ed.options["mb_copy"] = not bool(ed.options["mb_copy"])
		"clear_bodies":
			ed.clear_picks()
		_:
			return false
	return true


func on_activated(ed) -> void:
	ed.start_body_picks(1)
	ed.table.set_status("Pick the body to move, set X / Y / Z, then Apply.")


func can_apply(ed) -> bool:
	return not ed.bodies.is_empty()


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	return PartFeatures.move_body_request(str(ed.bodies[0]["body_id"]) if not ed.bodies.is_empty() else "", [ed.options["mb_dx"], ed.options["mb_dy"], ed.options["mb_dz"]], bool(ed.options["mb_copy"]))


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["body_id", "delta", "make_copy"]


func load_from_row(ed, row: Dictionary) -> void:
	var d: Array = row.get("delta", [0, 0, 0])
	ed.options["mb_dx"] = float(d[0])
	ed.options["mb_dy"] = float(d[1])
	ed.options["mb_dz"] = float(d[2])
	ed.options["mb_copy"] = bool(row.get("make_copy", false))
	var b := str(row.get("body_id", ""))
	ed.bodies = [{"kind": "body", "body_id": b, "index": -1, "key": "solid:%s" % b}]


func summary(f: Dictionary, _features: Array) -> String:
	var d: Array = f.get("delta", [0, 0, 0])
	return "by (%s, %s, %s)%s" % [d[0], d[1], d[2], ", copy" if bool(f.get("make_copy", false)) else ""]


func done_text() -> String:
	return "Body moved."
