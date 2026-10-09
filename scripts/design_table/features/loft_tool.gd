extends "res://scripts/design_table/features/feature_tool.gd"
## Loft: a solid through two or more sections, each the closed profile of a finished sketch (its own plane: make planes with Plane first). The laser
## picks a visible sketch for each section (any line of it), in pick order. A Build row's Edit keeps the older line picking (Lines on / off narrows it). Boss or Cut, Ruled
## (straight between sections). Preview is the coarse route: nothing is stored until Apply.


func _init() -> void:
	id = "loft"


func options(ed) -> Array:
	return [
		{"id": "boss", "text": "Boss", "toggle": true, "pressed": bool(ed.options["boss"])},
		{"id": "cut", "text": "Cut", "toggle": true, "pressed": not bool(ed.options["boss"])},
		{"id": "ruled", "text": "Ruled", "toggle": true, "pressed": bool(ed.options["ruled"])},
		{"id": "clear_curves", "text": "Clear"},
		{"id": "apply", "text": "Apply (%d sections)" % sections(ed).size(), "disabled": not can_apply(ed)},
	]


static func sections(ed) -> Array:
	## The sketches picked as sections, in pick order: the ones picked in the viewport, else the distinct sketches of the picked curves.
	if not ed.seed_sketches.is_empty():
		return ed.seed_sketches.duplicate()
	var out: Array = []
	for c in ed.curve_picks:
		if not out.has(str(c["sketch_feature_id"])):
			out.append(str(c["sketch_feature_id"]))
	return out


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"boss":
			ed.options["boss"] = true
		"cut":
			ed.options["boss"] = false
		"ruled":
			ed.options["ruled"] = not bool(ed.options["ruled"])
		"clear_curves":
			ed.clear_picks()
		_:
			return false
	return true


func on_activated(ed) -> void:
	if ed.activating_edit or ed.session != null:
		ed.start_curve_picks(0) # editing a loft (its sections are loaded as picks), or a sketch is open: the line picking as before
		return
	ed.start_sketch_pick()


func can_apply(ed) -> bool:
	return sections(ed).size() >= 2


func preview_mode() -> String:
	return "coarse"


func preview_route() -> String:
	return "loft-features/coarse-preview"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	return PartFeatures.loft_request(sections(ed), bool(ed.options["boss"]), bool(ed.options["ruled"]), ed.extrude_targets())


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["sections", "mode", "ruled", "target_body_ids"]


func load_from_row(ed, row: Dictionary) -> void:
	ed.options["boss"] = str(row.get("mode", "boss")) == "boss"
	ed.options["ruled"] = bool(row.get("ruled", false))
	ed.curve_picks = []
	for sec in row.get("sections", []):
		var sid := str((sec as Dictionary).get("sketch_feature_id", ""))
		ed.curve_picks.append({"kind": "curve", "sketch_feature_id": sid, "sketch_id": "", "entity_type": "", "entity_id": "", "key": "section:%s" % sid})


func summary(f: Dictionary, _features: Array) -> String:
	return "%s, %d sections%s" % ["Cut" if str(f.get("mode", "boss")) == "cut" else "Boss", (f.get("sections", []) as Array).size(), ", ruled" if bool(f.get("ruled", false)) else ""]


func done_text() -> String:
	return "Loft done."
