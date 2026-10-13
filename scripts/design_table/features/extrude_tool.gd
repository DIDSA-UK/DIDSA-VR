extends "res://scripts/design_table/features/feature_tool.gd"
## Extrude: the open sketch's closed profile, as a boss (grows out of a face) or a cut (into the part).


func _init() -> void:
	id = "extrude"


func options(ed) -> Array:
	var o: Dictionary = ed.options
	var thin := bool(o["ext_thin"])
	var draft := bool(o["ext_draft"])
	var list := [
		{"id": "boss", "text": "Boss", "toggle": true, "pressed": bool(o["boss"])},
		{"id": "cut", "text": "Cut", "toggle": true, "pressed": not bool(o["boss"])},
		{"id": "flip", "text": "Flip", "toggle": true, "pressed": bool(o["flip"]), "disabled": bool(o["ext_sym"])},
		{"id": "ext_sym", "text": "Both sides", "toggle": true, "pressed": bool(o["ext_sym"])},
		{"id": "depth", "text": "Depth %.2f mm" % float(o["depth"])},
		{"id": "ext_thin", "text": "Thin wall", "toggle": true, "pressed": thin, "disabled": draft}, # a wall and a draft can't be combined (the backend refuses it)
	]
	if thin:
		list.append({"id": "ext_wall", "text": "Wall %.2f mm" % float(o["ext_wall"])})
		for d in [["outward", "Out"], ["inward", "In"], ["symmetric", "Mid"]]:
			list.append({"id": "ext_dir_" + d[0], "text": d[1], "toggle": true, "pressed": str(o["ext_dir"]) == d[0]})
	list.append({"id": "ext_draft", "text": "Draft", "toggle": true, "pressed": draft, "disabled": thin})
	if draft:
		list.append({"id": "ext_angle", "text": "Angle %s deg" % ed.BuildTree.number(float(o["ext_angle"]))})
		list.append({"id": "ext_draft_out", "text": "Widen", "toggle": true, "pressed": bool(o["ext_draft_out"])})
	if bool(o["boss"]):
		list.insert(4, {"id": "new_body", "text": "New body", "toggle": true, "pressed": bool(o["new_body"])})
	if ed.session == null and ed.editing.is_empty():
		list.append(ed.targets_option()) # a picked sketch: the bodies to fuse into are picked too
	list.append({"id": "apply", "text": "Apply", "disabled": not can_apply(ed)})
	return list


func handle_option(ed, option_id: String) -> bool:
	var o: Dictionary = ed.options
	match option_id:
		"boss":
			o["boss"] = true
		"cut":
			o["boss"] = false
		"flip":
			o["flip"] = not bool(o["flip"])
		"new_body":
			o["new_body"] = not bool(o["new_body"])
		"ext_sym":
			o["ext_sym"] = not bool(o["ext_sym"])
		"ext_thin":
			o["ext_thin"] = not bool(o["ext_thin"])
		"ext_draft":
			o["ext_draft"] = not bool(o["ext_draft"])
		"ext_draft_out":
			o["ext_draft_out"] = not bool(o["ext_draft_out"])
		"ext_dir_outward", "ext_dir_inward", "ext_dir_symmetric":
			o["ext_dir"] = option_id.trim_prefix("ext_dir_")
		"targets":
			ed.toggle_target_picking()
		"depth":
			ed.type_option("depth", "Depth (mm)")
		"ext_wall":
			ed.type_option("ext_wall", "Wall thickness (mm)")
		"ext_angle":
			ed.type_option("ext_angle", "Draft angle (degrees, under 90)")
		_:
			return false
	return true


func on_activated(ed) -> void:
	if ed.activating_edit:
		return # a Build row's Edit loads the feature's own settings
	## With a sketch open it is the seed, as ever. With none open the visible finished sketches are offered to the laser instead.
	if ed.session == null:
		ed.start_sketch_pick()
		return
	if not ed.session.profile_ok():
		ed.table.set_status("The sketch needs a closed shape to extrude.")
	ed.set_state("extrude")


func can_apply(ed) -> bool:
	return ed.seed_ready() or not ed.editing.is_empty()


func finishes_sketch() -> bool:
	return true ## spends the OPEN sketch (the editor only ends one that is open; a picked finished sketch is left to the auto-hide)


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	if not can_apply(ed):
		return PartFeatures._bad("The sketch needs a closed shape to extrude.")
	var o: Dictionary = ed.options
	var d: Array = ed.extrude_distances()
	var extra := {}
	if bool(o["ext_thin"]):
		extra["thickness"] = float(o["ext_wall"])
		extra["thickness_direction"] = str(o["ext_dir"])
	if bool(o["ext_draft"]):
		extra["draft_angle"] = float(o["ext_angle"])
		extra["draft_outward"] = bool(o["ext_draft_out"])
	var sketch_feature: String = ed.seed_sketch_id()
	if sketch_feature == "":
		sketch_feature = str(ed.editing.get("original", {}).get("sketch_feature_id", ""))
	var req: Dictionary = PartFeatures.extrude_request(sketch_feature, bool(o["boss"]), d[0], d[1], ed.extrude_targets(), extra)
	if req["ok"] and not ed.editing.is_empty():
		# an edit changes settings, never the profile or the bodies it was made for, and keeps an odd span (a start offset made in the flat app) unless the depth settings moved
		var body: Dictionary = req["body"]
		body.erase("sketch_feature_id")
		body.erase("target_body_ids")
		if o.get("ext_orig", []) == _span_key(o):
			body.erase("start_distance")
			body.erase("end_distance")
	return req


static func _span_key(o: Dictionary) -> Array:
	## The settings that decide the span, to tell whether an Edit moved them.
	return [bool(o["boss"]), float(o["depth"]), bool(o["flip"]), bool(o["ext_sym"])]


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["extrude_type", "start_distance", "end_distance", "thickness", "thickness_direction", "draft_angle", "draft_outward"]


func patch_body(req: Dictionary) -> Dictionary:
	## Turning a wall or a draft OFF is an explicit null (the update route reads an omitted field as "leave it").
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	for key in ["thickness", "draft_angle"]:
		if not body.has(key):
			body[key] = null
	return body


func load_from_row(ed, row: Dictionary) -> void:
	var o: Dictionary = ed.options
	var start := float(row.get("start_distance", 0.0))
	var end := float(row.get("end_distance", 0.0))
	var boss := str(row.get("extrude_type", "boss")) != "cut"
	var sym := start < 0.0 and is_equal_approx(start, -end)
	o["boss"] = boss
	o["depth"] = end - start
	o["ext_sym"] = sym
	o["flip"] = false if sym else ((end > absf(start)) != boss)
	o["ext_thin"] = row.get("thickness") != null
	o["ext_wall"] = absf(float(row["thickness"])) if row.get("thickness") != null else 2.0
	o["ext_dir"] = str(row.get("thickness_direction", "outward"))
	o["ext_draft"] = row.get("draft_angle") != null
	o["ext_angle"] = float(row["draft_angle"]) if row.get("draft_angle") != null else 5.0
	o["ext_draft_out"] = bool(row.get("draft_outward", true))
	o["ext_orig"] = _span_key(o)


func summary(_f: Dictionary, _features: Array) -> String:
	return "" # the Build row's second line for an extrude is BuildTree.summary's own
