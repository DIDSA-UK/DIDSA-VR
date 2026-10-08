extends "res://scripts/design_table/features/feature_tool.gd"
## Delete Body: remove the picked bodies from the part.


func _init() -> void:
	id = "delete_body"


func options(ed) -> Array:
	return [{"id": "clear_bodies", "text": "Clear"}, {"id": "apply", "text": "Apply (%d)" % ed.bodies.size(), "disabled": not can_apply(ed)}]


func handle_option(ed, option_id: String) -> bool:
	if option_id != "clear_bodies":
		return false
	ed.clear_picks()
	return true


func on_activated(ed) -> void:
	ed.start_body_picks(0)
	ed.table.set_status("Pick the bodies to delete, then Apply.")


func can_apply(ed) -> bool:
	return not ed.bodies.is_empty()


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	return PartFeatures.delete_body_request(ed.body_refs())


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["body_ids"]


func load_from_row(ed, row: Dictionary) -> void:
	ed.bodies = (row.get("body_ids", []) as Array).map(func(b): return {"kind": "body", "body_id": str(b), "index": -1, "key": "solid:%s" % str(b)})


func summary(f: Dictionary, _features: Array) -> String:
	return "%d bod%s" % [(f.get("body_ids", []) as Array).size(), "y" if (f.get("body_ids", []) as Array).size() == 1 else "ies"]


func done_text() -> String:
	return "Body deleted."
