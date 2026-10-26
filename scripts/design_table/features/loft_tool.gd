extends "res://scripts/design_table/features/feature_tool.gd"
## Loft: a solid through two or more sections, each the closed profile of a finished sketch (its own plane: make planes with Plane first). The laser
## picks a visible sketch for each section (any line of it), in pick order. A Build row's Edit keeps the older line picking (Lines on / off narrows it). Boss or Cut, Ruled
## (straight between sections). Guides (Add guide) are curves of earlier sketches that run through every section and shape the surface between them: each pull
## on a curve adds one to the guide being built (Done keeps it), any number of guides, ignored (and not sent) while Ruled is on. Preview is the coarse route:
## nothing is stored until Apply.


func _init() -> void:
	id = "loft"


func options(ed) -> Array:
	var list := [
		{"id": "boss", "text": "Boss", "toggle": true, "pressed": bool(ed.options["boss"])},
		{"id": "cut", "text": "Cut", "toggle": true, "pressed": not bool(ed.options["boss"])},
		{"id": "ruled", "text": "Ruled", "toggle": true, "pressed": bool(ed.options["ruled"])},
		{"id": "lo_thin", "text": "Thin wall", "toggle": true, "pressed": bool(ed.options["lo_thin"])},
		{"id": "clear_curves", "text": "Clear"},
		{"id": "apply", "text": "Apply (%d sections)" % sections(ed).size(), "disabled": not can_apply(ed)},
	]
	if not bool(ed.options["ruled"]):
		var at := list.size() - 2 # the guide rows sit before Clear and Apply
		for row in ed.guide_option_rows():
			list.insert(at, row)
			at += 1
	if bool(ed.options["lo_thin"]):
		list.insert(4, {"id": "lo_closed", "text": "From closed", "toggle": true, "pressed": bool(ed.options["lo_closed"])}) # a chip beside Thin wall, the value beside Clear
		list.insert(5, {"id": "lo_wall", "text": "Wall %.2f mm" % float(ed.options["lo_wall"])})
	if ed.session == null and ed.editing.is_empty():
		list.insert(list.size() - 1, ed.targets_option())
	return list


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
		"lo_thin":
			ed.options["lo_thin"] = not bool(ed.options["lo_thin"])
		"lo_closed":
			ed.options["lo_closed"] = not bool(ed.options["lo_closed"])
		"lo_wall":
			ed.type_option("lo_wall", "Wall thickness (mm)")
		"clear_curves":
			ed.clear_picks()
		"targets":
			ed.toggle_target_picking()
		"guide_add":
			ed.start_guide_pick()
		"guide_done":
			ed.finish_guide_pick(true)
		"guide_cancel":
			ed.finish_guide_pick(false)
		_:
			if option_id.begins_with("guide_del_"):
				ed.remove_guide(int(option_id.trim_prefix("guide_del_")))
				return true
			return false
	return true


func on_activated(ed) -> void:
	if ed.activating_edit or ed.session != null:
		ed.start_curve_picks(0) # editing a loft (its sections are loaded as picks), or a sketch is open: the line picking as before
		return
	ed.start_sketch_pick()


func can_apply(ed) -> bool:
	return sections(ed).size() >= 2 and not ed.is_picking_guide()


func preview_mode() -> String:
	return "coarse"


func preview_route() -> String:
	return "loft-features/coarse-preview"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	var o: Dictionary = ed.options
	return PartFeatures.loft_request(sections(ed), bool(o["boss"]), bool(o["ruled"]), ed.extrude_targets(), float(o["lo_wall"]) if bool(o["lo_thin"]) else 0.0, bool(o["lo_closed"]), ed.guide_refs())


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["sections", "mode", "ruled", "target_body_ids", "thickness", "thin_from_closed_profile", "guide_curves"]


func load_from_row(ed, row: Dictionary) -> void:
	ed.options["boss"] = str(row.get("mode", "boss")) == "boss"
	ed.options["ruled"] = bool(row.get("ruled", false))
	ed.options["lo_thin"] = row.get("thickness") != null
	ed.options["lo_wall"] = absf(float(row["thickness"])) if row.get("thickness") != null else 2.0
	ed.options["lo_closed"] = bool(row.get("thin_from_closed_profile", false))
	ed.curve_picks = []
	for sec in row.get("sections", []):
		var sid := str((sec as Dictionary).get("sketch_feature_id", ""))
		ed.curve_picks.append({"kind": "curve", "sketch_feature_id": sid, "sketch_id": "", "entity_type": "", "entity_id": "", "key": "section:%s" % sid})
	ed.guides = []
	ed.guide_draft = []
	for guide in row.get("guide_curves", []):
		var chain: Array = []
		for ref in guide:
			var r: Dictionary = ref
			chain.append({"kind": "curve", "sketch_feature_id": "", "sketch_id": str(r.get("sketch_id", "")), "entity_type": str(r.get("entity_type", "")), "entity_id": str(r.get("entity_id", "")), "key": "curve:%s:%s" % [r.get("sketch_id", ""), r.get("entity_id", "")]})
		ed.guides.append(chain)


func patch_body(req: Dictionary) -> Dictionary:
	## Turning the wall OFF is an explicit null (the update route reads an omitted one as "leave it").
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	if not body.has("thickness"):
		body["thickness"] = null
	return body


func summary(f: Dictionary, _features: Array) -> String:
	var guides: int = (f.get("guide_curves", []) as Array).size()
	return "%s, %d sections%s%s%s" % ["Cut" if str(f.get("mode", "boss")) == "cut" else "Boss", (f.get("sections", []) as Array).size(), ", ruled" if bool(f.get("ruled", false)) else "", ", thin wall" if f.get("thickness") != null else "", (", %d guide%s" % [guides, "" if guides == 1 else "s"]) if guides > 0 else ""]


func done_text() -> String:
	return "Loft done."
