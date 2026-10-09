extends "res://scripts/design_table/features/feature_tool.gd"
## Sweep: a sketch's closed profile along a path of lines and arcs picked from EARLIER sketches. The profile is the open sketch, or (with none open) a
## visible finished sketch picked in the viewport first. Boss or Cut. The picks are the backend's sketch entity refs, in pick order, which is the order of the chain.


func _init() -> void:
	id = "sweep"


func options(ed) -> Array:
	var list := [
		{"id": "boss", "text": "Boss", "toggle": true, "pressed": bool(ed.options["boss"])},
		{"id": "cut", "text": "Cut", "toggle": true, "pressed": not bool(ed.options["boss"])},
		{"id": "clear_curves", "text": "Clear"},
		{"id": "apply", "text": "Apply (%d path lines)" % ed.curve_picks.size(), "disabled": not can_apply(ed)},
	]
	if ed.session == null and ed.editing.is_empty():
		list.insert(list.size() - 1, ed.targets_option())
	return list


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"boss":
			ed.options["boss"] = true
		"cut":
			ed.options["boss"] = false
		"clear_curves":
			ed.clear_picks()
		"targets":
			ed.toggle_target_picking()
		_:
			return false
	return true


func on_activated(ed) -> void:
	if ed.activating_edit:
		return # a Build row's Edit loads its own picks
	if ed.session == null:
		ed.start_sketch_pick() # no sketch open: pick the profile sketch first, the path lines come next
		return
	if ed.session != null and not ed.session.profile_ok():
		ed.table.set_status("The open sketch needs a closed shape to sweep.")
	ed.start_curve_picks(0)


func can_apply(ed) -> bool:
	return not ed.curve_picks.is_empty() and (ed.seed_ready() or not ed.editing.is_empty())


func preview_mode() -> String:
	return "eager"


func finishes_sketch() -> bool:
	return true


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	var sketch_feature: String = ed.seed_sketch_id()
	if sketch_feature == "":
		sketch_feature = str(ed.editing.get("original", {}).get("sketch_feature_id", ""))
	return PartFeatures.sweep_request(sketch_feature, ed.curve_refs(), bool(ed.options["boss"]), ed.extrude_targets())


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["path_refs", "mode", "target_body_ids"]


func patch_body(req: Dictionary) -> Dictionary:
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	body.erase("sketch_feature_id") # a sweep's profile sketch is never revised
	return body


func load_from_row(ed, row: Dictionary) -> void:
	ed.options["boss"] = str(row.get("mode", "boss")) == "boss"
	ed.curve_picks = []
	for ref in row.get("path_refs", []):
		var r: Dictionary = ref
		ed.curve_picks.append({"kind": "curve", "sketch_feature_id": "", "sketch_id": str(r.get("sketch_id", "")), "entity_type": str(r.get("entity_type", "")), "entity_id": str(r.get("entity_id", "")), "key": "curve:%s:%s" % [r.get("sketch_id", ""), r.get("entity_id", "")]})


func summary(f: Dictionary, _features: Array) -> String:
	return "%s along %d path line(s)" % ["Cut" if str(f.get("mode", "boss")) == "cut" else "Boss", (f.get("path_refs", []) as Array).size()]


func done_text() -> String:
	return "Sweep done."
