extends "res://scripts/design_table/features/feature_tool.gd"
## Chamfer: bevel the picked edges.


func _init() -> void:
	id = "chamfer"


func options(ed) -> Array:
	## Order matters to the panel's two-column layout: the chips (Angle, Flip) sit together, then the two values (Distance, the angle) share a line.
	var o: Dictionary = ed.options
	var list := []
	var angled := bool(o["ch_angle_on"]) and not bool(o["ch_mixed"])
	if bool(o["ch_mixed"]):
		list.append({"id": "ch_mixed", "text": "Angles per edge (kept)", "toggle": true, "pressed": true, "disabled": true}) # made in the flat app: left as it is
	else:
		list.append({"id": "ch_angle_on", "text": "Angle", "toggle": true, "pressed": bool(o["ch_angle_on"])})
		if angled:
			list.append({"id": "ch_flip", "text": "Flip", "toggle": true, "pressed": bool(o["ch_flip"])})
	list.append({"id": "distance", "text": "Distance %.2f mm" % float(o["distance"])})
	if angled:
		list.append({"id": "ch_angle", "text": "%s deg" % ed.BuildTree.number(float(o["ch_angle"]))})
	list.append({"id": "clear_edges", "text": "Clear"})
	list.append({"id": "apply", "text": "Apply (%d)" % ed.edges.size(), "disabled": not can_apply(ed)})
	return list


func handle_option(ed, option_id: String) -> bool:
	var o: Dictionary = ed.options
	match option_id:
		"distance":
			ed.type_option("distance", "Distance (mm)")
		"ch_angle_on":
			o["ch_angle_on"] = not bool(o["ch_angle_on"])
		"ch_angle":
			ed.type_option("ch_angle", "Chamfer angle (degrees, under 90)")
		"ch_flip":
			o["ch_flip"] = not bool(o["ch_flip"])
		"clear_edges":
			ed.clear_picks()
		_:
			return false
	return true


func on_activated(ed) -> void:
	if not ed.activating_edit:
		ed.options["ch_mixed"] = false # (a Build row's Edit loads its own)
	ed.start_edge_picks()


func can_apply(ed) -> bool:
	return not ed.edges.is_empty()


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	var o: Dictionary = ed.options
	var angle := float(o["ch_angle"]) if bool(o["ch_angle_on"]) and not bool(o["ch_mixed"]) else 0.0
	var req: Dictionary = PartFeatures.chamfer_request(ed.edge_refs(), float(o["distance"]), angle, bool(o["ch_flip"]))
	if req["ok"] and bool(o["ch_mixed"]):
		(req["body"] as Dictionary).erase("edge_options") # per-edge values from the flat app stay as they are
		req["mixed"] = true
	return req


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["edge_refs", "distance", "edge_options"]


func patch_body(req: Dictionary) -> Dictionary:
	## Turning the angle OFF is an empty edge_options (omitted would mean "leave it"); mixed per-edge values are left alone by omitting it.
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	if not body.has("edge_options") and not bool(req.get("mixed", false)):
		body["edge_options"] = {}
	return body


func load_from_row(ed, row: Dictionary) -> void:
	var o: Dictionary = ed.options
	o["distance"] = float(row.get("distance", 2.0))
	ed.edges = (row.get("edge_refs", []) as Array).map(func(r): return {"kind": "edge", "body_id": str(r.get("body_id", "")), "index": int(r.get("index", 0)), "key": "edge:%s:%d" % [r.get("body_id", ""), int(r.get("index", 0))]})
	var opts: Dictionary = row.get("edge_options", {}) if row.get("edge_options") is Dictionary else {}
	o["ch_angle_on"] = false
	o["ch_flip"] = false
	o["ch_mixed"] = false
	var first: Dictionary = {}
	for key in opts:
		var e: Dictionary = opts[key]
		if e.get("angle") == null:
			continue
		if first.is_empty():
			first = e
		elif not is_equal_approx(float(e["angle"]), float(first["angle"])) or bool(e.get("flip", false)) != bool(first.get("flip", false)) or (e.get("face_ref") != null):
			o["ch_mixed"] = true
	if first.get("face_ref") != null:
		o["ch_mixed"] = true # a hand-picked reference face can't be shown here
	if not first.is_empty():
		o["ch_angle_on"] = true
		o["ch_angle"] = float(first["angle"])
		o["ch_flip"] = bool(first.get("flip", false))


func summary(f: Dictionary, _features: Array) -> String:
	var text := "%s mm, %d edge(s)" % [ed_number(f.get("distance", 0.0)), (f.get("edge_refs", []) as Array).size()]
	var opts = f.get("edge_options")
	if opts is Dictionary and not (opts as Dictionary).is_empty():
		text += ", angled"
	return text


static func ed_number(x) -> String:
	return String.num(float(x), 2).rstrip("0").rstrip(".")
