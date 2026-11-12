extends "res://scripts/design_table/features/feature_tool.gd"
## Pattern: repeat a body. Rectangular: along a direction (X, Y or Z, or a line of an earlier sketch) with a count and a spacing, optionally crossed with a
## second direction (X / Y / Z); Circular: round an axis (a line of an earlier sketch) with a count over a total angle. Reverse flips a direction; Merge
## fuses the copies into the body. Two picks, a body and (for a line direction or the circular axis) a sketch line: the "Pick" toggles say which the laser
## fills, and both stay lit. The preview is the coarse route.


func _init() -> void:
	id = "pattern"


func options(ed) -> Array:
	var o: Dictionary = ed.options
	var list: Array = [
		{"id": "pat_rect", "text": "Rectangular", "toggle": true, "pressed": str(o["pat_type"]) == "rectangular"},
		{"id": "pat_circ", "text": "Circular", "toggle": true, "pressed": str(o["pat_type"]) == "circular"},
		{"id": "pick_bodies", "text": "Body (%d)" % ed.bodies.size(), "toggle": true, "pressed": str(o["pat_pick"]) == "bodies"},
		{"id": "pick_lines", "text": "Line (%d)" % ed.curve_picks.size(), "toggle": true, "pressed": str(o["pat_pick"]) == "curves"},
	]
	if str(o["pat_type"]) == "rectangular":
		for d in ["x", "y", "z", "line"]:
			list.append({"id": "pat_dir1_" + d, "text": "Dir %s" % d.to_upper() if d != "line" else "Dir: line", "toggle": true, "pressed": str(o["pat_dir1"]) == d})
		list.append({"id": "pat_count1", "text": "Count %d" % int(o["pat_count1"])})
		list.append({"id": "pat_spacing1", "text": "Spacing %.2f mm" % float(o["pat_spacing1"])})
		list.append({"id": "pat_rev1", "text": "Reverse", "toggle": true, "pressed": bool(o["pat_rev1"])})
		for d in ["none", "x", "y", "z"]:
			list.append({"id": "pat_dir2_" + d, "text": "2nd: %s" % d.to_upper() if d != "none" else "No 2nd", "toggle": true, "pressed": str(o["pat_dir2"]) == d})
		if str(o["pat_dir2"]) != "none":
			list.append({"id": "pat_count2", "text": "Count 2: %d" % int(o["pat_count2"])})
			list.append({"id": "pat_spacing2", "text": "Spacing 2: %.2f mm" % float(o["pat_spacing2"])})
			list.append({"id": "pat_rev2", "text": "Reverse 2", "toggle": true, "pressed": bool(o["pat_rev2"])})
	else:
		list.append({"id": "pat_count_ang", "text": "Count %d" % int(o["pat_count_ang"])})
		list.append({"id": "pat_angle", "text": "Total angle %s deg" % ed.BuildTree.number(float(o["pat_angle"]))})
		list.append({"id": "pat_rev_ang", "text": "Reverse", "toggle": true, "pressed": bool(o["pat_rev_ang"])})
	list.append({"id": "pat_merge", "text": "Merge in", "toggle": true, "pressed": bool(o["pat_merge"])})
	if str(o["pat_type"]) == "circular":
		list.append({"id": "pat_orient_rotate", "text": "Rotate", "toggle": true, "pressed": str(o["pat_orient"]) == "rotate_with_pattern"})
		list.append({"id": "pat_orient_keep", "text": "Keep angle", "toggle": true, "pressed": str(o["pat_orient"]) == "maintain_orientation"})
	list.append({"id": "pat_skip", "text": "Skip: %s" % (", ".join((o["pat_skip"] as Array).map(func(i): return str(i))) if not (o["pat_skip"] as Array).is_empty() else "none")})
	list.append({"id": "clear_pattern", "text": "Clear"})
	list.append({"id": "apply", "text": "Apply", "disabled": not can_apply(ed)})
	return list


func handle_option(ed, option_id: String) -> bool:
	var o: Dictionary = ed.options
	match option_id:
		"pat_rect":
			o["pat_type"] = "rectangular"
		"pat_circ":
			o["pat_type"] = "circular"
			o["pat_pick"] = "curves" if ed.bodies.size() > 0 else "bodies"
			ed.set_pick_mode(str(o["pat_pick"]))
		"pick_bodies":
			o["pat_pick"] = "bodies"
			ed.set_pick_mode("bodies")
		"pick_lines":
			o["pat_pick"] = "curves"
			ed.set_pick_mode("curves")
		"pat_count1":
			ed.type_option("pat_count1", "Count")
		"pat_spacing1":
			ed.type_option("pat_spacing1", "Spacing (mm)")
		"pat_rev1":
			o["pat_rev1"] = not bool(o["pat_rev1"])
		"pat_count2":
			ed.type_option("pat_count2", "Count in the second direction")
		"pat_spacing2":
			ed.type_option("pat_spacing2", "Spacing in the second direction (mm)")
		"pat_rev2":
			o["pat_rev2"] = not bool(o["pat_rev2"])
		"pat_count_ang":
			ed.type_option("pat_count_ang", "Count")
		"pat_angle":
			ed.type_option("pat_angle", "Total angle (deg, up to 360)")
		"pat_rev_ang":
			o["pat_rev_ang"] = not bool(o["pat_rev_ang"])
		"pat_merge":
			o["pat_merge"] = not bool(o["pat_merge"])
		"pat_orient_rotate":
			o["pat_orient"] = "rotate_with_pattern"
		"pat_orient_keep":
			o["pat_orient"] = "maintain_orientation"
		"pat_skip":
			ed.table.open_keyboard(", ".join((o["pat_skip"] as Array).map(func(i): return str(i))), func(text: String) -> void: skip_typed(ed, text),
				{"mode": "full", "title": "Instances to skip, e.g. 2 4 (1 is the first copy; leave empty for none)"})
		"clear_pattern":
			ed.clear_picks()
		_:
			if option_id.begins_with("pat_dir1_"):
				o["pat_dir1"] = option_id.substr(9)
			elif option_id.begins_with("pat_dir2_"):
				o["pat_dir2"] = option_id.substr(9)
			else:
				return false
	return true


static func total_instances(o: Dictionary) -> int:
	## How many instances the pattern holds counting the seed (0): what skipped numbers must stay under.
	if str(o["pat_type"]) == "circular":
		return int(o["pat_count_ang"])
	return int(o["pat_count1"]) * (int(o["pat_count2"]) if str(o["pat_dir2"]) != "none" else 1)


static func parse_skip(text: String, total: int) -> Dictionary:
	## {ok, list, error}: "2, 4" or "2 4" to [2, 4] (sorted, no repeats). The seed (0) can't be skipped and each number has to be under the instance count.
	var list: Array = []
	for part in text.replace(",", " ").split(" ", false):
		if not part.is_valid_int():
			return {"ok": false, "list": [], "error": "'%s' is not a whole number." % part}
		var n := int(part)
		if n < 1 or n >= total:
			return {"ok": false, "list": [], "error": "Skipped numbers go from 1 to %d here (0 is the original and can't be skipped)." % (total - 1)}
		if not list.has(n):
			list.append(n)
	list.sort()
	return {"ok": true, "list": list, "error": ""}


func skip_typed(ed, text: String) -> void:
	var parsed := parse_skip(text, total_instances(ed.options))
	if not bool(parsed["ok"]):
		ed.table.set_status(str(parsed["error"]))
		return
	ed.options["pat_skip"] = parsed["list"]
	ed._update_options()
	ed.schedule_preview()


func on_activated(ed) -> void:
	if not ed.activating_edit:
		ed.options["pat_skip"] = []
		ed.options["pat_orient"] = "rotate_with_pattern"
	ed.options["pat_pick"] = "bodies"
	ed.start_body_picks(1)
	ed.table.set_status("Pick the body to repeat. A direction along X, Y or Z needs no line; for a line direction or a circular axis press Pick line and pick a line of an earlier sketch.")


func _uses_line(ed) -> bool:
	return str(ed.options["pat_type"]) == "circular" or str(ed.options["pat_dir1"]) == "line"


func can_apply(ed) -> bool:
	return not ed.bodies.is_empty() and (not _uses_line(ed) or not ed.curve_picks.is_empty())


func preview_mode() -> String:
	return "coarse"


func preview_route() -> String:
	return "pattern-features/coarse-preview"


func _direction(ed, key: String) -> Dictionary:
	if key == "line":
		return {"sketch_line_ref": ed.curve_refs()[0]}
	return {"fixed_axis": key}


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	var o: Dictionary = ed.options
	if ed.bodies.is_empty():
		return PartFeatures._bad("Pick the body to repeat first.")
	var body := {"source_body_ids": ed.body_refs(), "merge": "fuse_into_one" if bool(o["pat_merge"]) else "keep_separate"}
	var skipped: Array = (o["pat_skip"] as Array).filter(func(i): return int(i) < total_instances(o)) # (the count may have been lowered since)
	body["skip_indices"] = skipped # always sent: an empty list on a PATCH clears an old one
	if str(o["pat_type"]) == "circular":
		if ed.curve_picks.is_empty():
			return PartFeatures._bad("Pick a line of an earlier sketch as the axis first.")
		if int(o["pat_count_ang"]) < 2:
			return PartFeatures._bad("The count has to be at least 2.")
		body["pattern_type"] = "circular"
		body["axis"] = {"sketch_line_ref": ed.curve_refs()[0]}
		body["count_angular"] = int(o["pat_count_ang"])
		body["angle_total"] = float(o["pat_angle"])
		body["reverse_angular"] = bool(o["pat_rev_ang"])
		body["orientation_mode"] = str(o["pat_orient"])
		return PartFeatures._good("pattern-features", body)
	if str(o["pat_dir1"]) == "line" and ed.curve_picks.is_empty():
		return PartFeatures._bad("Pick a line of an earlier sketch as the direction first.")
	if int(o["pat_count1"]) < 2 or float(o["pat_spacing1"]) <= 0.0:
		return PartFeatures._bad("The count has to be at least 2 and the spacing more than zero.")
	body["pattern_type"] = "rectangular"
	body["direction_1"] = _direction(ed, str(o["pat_dir1"]))
	body["count_1"] = int(o["pat_count1"])
	body["spacing_1"] = float(o["pat_spacing1"])
	body["reverse_1"] = bool(o["pat_rev1"])
	if str(o["pat_dir2"]) != "none":
		body["direction_2"] = {"fixed_axis": str(o["pat_dir2"])}
		body["count_2"] = int(o["pat_count2"])
		body["spacing_2"] = float(o["pat_spacing2"])
		body["reverse_2"] = bool(o["pat_rev2"])
	return PartFeatures._good("pattern-features", body)


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["source_body_ids", "pattern_type", "direction_1", "count_1", "spacing_1", "reverse_1", "direction_2", "count_2", "spacing_2", "reverse_2", "axis", "count_angular", "angle_total", "reverse_angular", "merge", "skip_indices", "orientation_mode"]


func load_from_row(ed, row: Dictionary) -> void:
	var o: Dictionary = ed.options
	o["pat_type"] = str(row.get("pattern_type", "rectangular"))
	o["pat_merge"] = str(row.get("merge", "keep_separate")) == "fuse_into_one"
	ed.bodies = (row.get("source_body_ids", []) as Array).map(func(b): return {"kind": "body", "body_id": str(b), "index": -1, "key": "solid:%s" % str(b)})
	ed.curve_picks = []
	var d1: Dictionary = row.get("direction_1", {}) if row.get("direction_1") is Dictionary else {}
	if d1.get("fixed_axis") != null:
		o["pat_dir1"] = str(d1["fixed_axis"])
	elif d1.get("sketch_line_ref") != null:
		o["pat_dir1"] = "line"
		ed.curve_picks.append(_curve_from_ref(d1["sketch_line_ref"]))
	o["pat_count1"] = float(row.get("count_1", 3))
	o["pat_spacing1"] = float(row.get("spacing_1", 20.0))
	o["pat_rev1"] = bool(row.get("reverse_1", false))
	var d2: Dictionary = row.get("direction_2", {}) if row.get("direction_2") is Dictionary else {}
	o["pat_dir2"] = str(d2["fixed_axis"]) if d2.get("fixed_axis") != null else "none"
	o["pat_count2"] = float(row.get("count_2", 2))
	o["pat_spacing2"] = float(row.get("spacing_2", 20.0))
	o["pat_rev2"] = bool(row.get("reverse_2", false))
	o["pat_count_ang"] = float(row.get("count_angular", 4))
	o["pat_angle"] = float(row.get("angle_total", 360.0))
	o["pat_rev_ang"] = bool(row.get("reverse_angular", false))
	o["pat_skip"] = (row.get("skip_indices", []) as Array).map(func(i): return int(i))
	o["pat_orient"] = str(row.get("orientation_mode", "rotate_with_pattern"))
	var axis: Dictionary = row.get("axis", {}) if row.get("axis") is Dictionary else {}
	if axis.get("sketch_line_ref") != null:
		ed.curve_picks.append(_curve_from_ref(axis["sketch_line_ref"]))


static func _curve_from_ref(ref: Dictionary) -> Dictionary:
	return {"kind": "curve", "sketch_feature_id": "", "sketch_id": str(ref.get("sketch_id", "")), "entity_type": str(ref.get("entity_type", "")), "entity_id": str(ref.get("entity_id", "")), "key": "curve:%s:%s" % [ref.get("sketch_id", ""), ref.get("entity_id", "")]}


func summary(f: Dictionary, _features: Array) -> String:
	if str(f.get("pattern_type", "rectangular")) == "circular":
		return "Circular, %d over %s deg" % [int(f.get("count_angular", 0)), String.num(float(f.get("angle_total", 360.0)), 1).trim_suffix(".0")]
	var text := "Rectangular, %d x %s mm" % [int(f.get("count_1", 0)), String.num(float(f.get("spacing_1", 0.0)), 2).rstrip("0").rstrip(".")]
	if f.get("direction_2") != null:
		text += " by %d" % int(f.get("count_2", 1))
	return text


func done_text() -> String:
	return "Pattern done."
