extends "res://scripts/design_table/features/feature_tool.gd"
## Scale Body: grow or shrink a body uniformly about its own middle by a factor.


func _init() -> void:
	id = "scale_body"


func options(ed) -> Array:
	return [{"id": "sb_factor", "text": "Factor %s" % ed.BuildTree.number(float(ed.options["sb_factor"]))}, {"id": "clear_bodies", "text": "Clear"}, {"id": "apply", "text": "Apply", "disabled": not can_apply(ed)}]


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"sb_factor":
			ed.type_option("sb_factor", "Scale factor (1 = same size)")
		"clear_bodies":
			ed.clear_picks()
		_:
			return false
	return true


func on_activated(ed) -> void:
	ed.start_body_picks(1)
	ed.table.set_status("Pick the body to scale, set the factor, then Apply.")


func can_apply(ed) -> bool:
	return not ed.bodies.is_empty()


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	return PartFeatures.scale_body_request(str(ed.bodies[0]["body_id"]) if not ed.bodies.is_empty() else "", float(ed.options["sb_factor"]))


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["body_id", "factor"]


func load_from_row(ed, row: Dictionary) -> void:
	ed.options["sb_factor"] = float(row.get("factor", 1.0))
	var b := str(row.get("body_id", ""))
	ed.bodies = [{"kind": "body", "body_id": b, "index": -1, "key": "solid:%s" % b}]


func summary(f: Dictionary, _features: Array) -> String:
	return "x %s" % String.num(float(f.get("factor", 1.0)), 3).rstrip("0").rstrip(".")


func done_text() -> String:
	return "Body scaled."
