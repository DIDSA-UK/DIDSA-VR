extends "res://scripts/design_table/features/feature_tool.gd"
## Create Plane: a plane offset from a reference plane, a flat face or a plane already made (Offset), halfway between two parallel planes (Middle), parallel to a
## plane through a corner (On corner), normal to a straight edge through a corner (To edge), or through three corners (3 corners). The plane is not a body, so there
## is no preview; once made it is drawn beside the three reference planes (plane_markers.gd) and can be picked to sketch on, or offset again.

const METHODS := [["offset", "Offset"], ["midplane", "Middle"], ["vertex", "On corner"], ["edge", "To edge"], ["points", "3 corners"]]
const BACKEND_TYPES := {"offset": "offset_face", "midplane": "midplane", "vertex": "parallel_to_face_through_vertex", "edge": "normal_to_edge_through_vertex", "points": "three_points"}


func _init() -> void:
	id = "create_plane"


func options(ed) -> Array:
	## The five ways are chips; what each needs follows. Chips first, then the values, so the two-column panel pairs them well.
	var method := str(ed.options["pl_method"])
	var list := []
	for m in METHODS:
		list.append({"id": "pl_m_" + m[0], "text": m[1], "toggle": true, "pressed": method == m[0]})
	match method:
		"offset":
			list.append({"id": "plane_base", "text": "From: %s" % _base_text(ed.plane_base), "disabled": true})
			list.append({"id": "plane_offset", "text": "Offset %.2f mm" % float(ed.options["plane_offset"])})
			list.append({"id": "plane_flip", "text": "Reverse", "toggle": true, "pressed": bool(ed.options["plane_flip"])})
		"midplane":
			list.append({"id": "pl_info", "text": "Planes: %d of 2" % (0 if ed.plane_base.is_empty() else (1 if ed.plane_base2.is_empty() else 2)), "disabled": true})
		"vertex":
			list.append({"id": "pl_pick_plane", "text": "Plane (%d)" % (0 if ed.plane_base.is_empty() else 1), "toggle": true, "pressed": ed.state == "pick_plane"})
			list.append({"id": "pl_pick_vertex", "text": "Corner (%d)" % ed.vertices.size(), "toggle": true, "pressed": ed.state == "pick_vertices"})
		"edge":
			list.append({"id": "pl_pick_edge", "text": "Edge (%d)" % ed.edges.size(), "toggle": true, "pressed": ed.state == "pick_edges"})
			list.append({"id": "pl_pick_vertex", "text": "Corner (%d)" % ed.vertices.size(), "toggle": true, "pressed": ed.state == "pick_vertices"})
		"points":
			list.append({"id": "pl_info", "text": "Corners: %d of 3" % ed.vertices.size(), "disabled": true})
	list.append({"id": "apply", "text": "Make plane", "disabled": not can_apply(ed)})
	return list


static func _base_text(base: Dictionary) -> String:
	if base.has("fixed"):
		return "%s plane" % str(base["fixed"])
	if base.has("face"):
		return "a face"
	if base.has("plane_feature_id"):
		return "a made plane"
	return "pick one"


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"plane_offset":
			ed.type_option("plane_offset", "Offset (mm)")
		"plane_flip":
			ed.options["plane_flip"] = not bool(ed.options["plane_flip"])
		"pl_pick_plane":
			ed.set_pick_mode("plane")
		"pl_pick_edge":
			ed.set_pick_mode("edges")
		"pl_pick_vertex":
			ed.set_pick_mode("vertices")
		_:
			if not option_id.begins_with("pl_m_"):
				return false
			ed.options["pl_method"] = option_id.trim_prefix("pl_m_")
			_enter(ed)
	return true


func _enter(ed) -> void:
	## The method was chosen (or the tool opened): forget the old picks, set how many of each kind the laser may hold, and point the laser at the first thing needed.
	ed.plane_base = {}
	ed.plane_base2 = {}
	ed.clear_picks()
	var method := str(ed.options["pl_method"])
	ed.edge_limit = 1 if method == "edge" else 0
	ed.vertex_limit = {"vertex": 1, "edge": 1, "points": 3}.get(method, 0)
	if ed.session != null or ed.state == "idle":
		return
	match method:
		"offset":
			ed.set_pick_mode("plane")
			ed.table.set_status("Aim at a flat face or a plane and pull the trigger to offset a new plane from it.")
		"midplane":
			ed.set_pick_mode("plane")
			ed.table.set_status("Pick two planes or flat faces, parallel to each other: the new plane goes halfway between them.")
		"vertex":
			ed.set_pick_mode("plane")
			ed.table.set_status("Pick a plane or a flat face, then a corner: the new plane is parallel to it and goes through the corner.")
		"edge":
			ed.set_pick_mode("edges")
			ed.table.set_status("Pick a straight edge, then a corner: the new plane is square to the edge and goes through the corner.")
		"points":
			ed.set_pick_mode("vertices")
			ed.table.set_status("Pick three corners of the part.")
	ed._update_options()


func on_activated(ed) -> void:
	if ed.session != null:
		ed.table.set_status("Finish the sketch first (Done), then make a plane.")
		ed.plane_base = {}
		return
	_enter(ed)


func wants_plane_pick() -> bool:
	return true


func on_plane_picked(ed, spec: Dictionary) -> void:
	match str(ed.options["pl_method"]):
		"offset":
			ed.plane_base = spec
			ed.table.set_status("Offset from %s. Set the offset, then Make plane." % _base_text(spec))
		"midplane":
			if ed.plane_base.is_empty():
				ed.plane_base = spec
				ed.table.set_status("%s picked. Pick the second plane." % _base_text(spec).capitalize())
			else:
				ed.plane_base2 = spec # (a third pick replaces the second)
				ed.table.set_status("Halfway between %s and %s. Make plane." % [_base_text(ed.plane_base), _base_text(spec)])
		"vertex":
			ed.plane_base = spec
			if ed.vertices.is_empty():
				ed.set_pick_mode("vertices")
				ed.table.set_status("%s picked. Now pick the corner the plane goes through." % _base_text(spec).capitalize())
			else:
				ed.table.set_status("Parallel to %s through the corner. Make plane." % _base_text(spec))
		_:
			return
	ed._update_options()


func on_pick(ed, kind: String) -> void:
	var method := str(ed.options["pl_method"])
	if method == "edge" and kind == "edge" and ed.vertices.is_empty():
		ed.set_pick_mode("vertices")
		ed.table.set_status("Edge picked. Now pick the corner the plane goes through.")
	elif kind == "vertex" and method == "points" and ed.vertices.size() == 3:
		ed.table.set_status("Three corners picked. Make plane.")
	elif kind == "vertex" and method in ["vertex", "edge"] and ed.vertices.size() == 1:
		ed.table.set_status("Corner picked. Make plane.")


func can_apply(ed) -> bool:
	match str(ed.options["pl_method"]):
		"offset":
			return not ed.plane_base.is_empty()
		"midplane":
			return not ed.plane_base.is_empty() and not ed.plane_base2.is_empty()
		"vertex":
			return not ed.plane_base.is_empty() and not ed.vertices.is_empty()
		"edge":
			return not ed.edges.is_empty() and not ed.vertices.is_empty()
		"points":
			return ed.vertices.size() >= 3
	return false


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	var method := str(ed.options["pl_method"])
	if method == "offset":
		var offset := float(ed.options["plane_offset"]) * (-1.0 if bool(ed.options["plane_flip"]) else 1.0)
		return PartFeatures.create_plane_request(ed.plane_base, offset)
	return PartFeatures.create_plane_typed(method, [ed.plane_base, ed.plane_base2] if not ed.plane_base2.is_empty() else [ed.plane_base], ed.edges, ed.vertices)


func reload_build_after() -> bool:
	return true


func summary(f: Dictionary, _features: Array) -> String:
	for m in BACKEND_TYPES:
		if BACKEND_TYPES[m] == str(f.get("plane_type", "")):
			return {"offset": "offset", "midplane": "halfway between two", "vertex": "parallel, through a corner", "edge": "normal to an edge", "points": "through three corners"}[m]
	return str(f.get("plane_type", "plane")).replace("_", " ")


func done_text() -> String:
	return "Plane made. Aim at it to sketch on it."
