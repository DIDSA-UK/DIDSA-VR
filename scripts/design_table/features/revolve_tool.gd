extends "res://scripts/design_table/features/feature_tool.gd"
## Revolve: a sketch's closed profile spun about a line of any sketch. The sketch is the open one, or (with none open) a visible finished one
## picked in the viewport, then a line of any visible sketch for the axis.


func _init() -> void:
	id = "revolve"


func _open_profile(ed) -> bool:
	## The sketch has no closed shape but one open line chain: it can only be revolved as a thin wall (Thin is locked on).
	return ed.has_method("seed_open_chain") and ed.seed_open_chain()


func _thin(ed) -> bool:
	return bool(ed.options["rev_thin"]) or _open_profile(ed)


func options(ed) -> Array:
	var o: Dictionary = ed.options
	var open := _open_profile(ed)
	var list := [
		{"id": "boss", "text": "Boss", "toggle": true, "pressed": bool(o["boss"])},
		{"id": "cut", "text": "Cut", "toggle": true, "pressed": not bool(o["boss"])},
		{"id": "angle", "text": "Angle %s deg" % ed.BuildTree.number(float(o["angle"]))},
		{"id": "rev_thin", "text": "Thin wall", "toggle": true, "pressed": _thin(ed), "disabled": open}, # an open profile has no solid revolve: Thin stays on
	]
	if _thin(ed):
		list.append({"id": "rev_wall", "text": "Wall %.2f mm" % float(o["rev_wall"])})
		# An open chain has no inside: its wall is read against the axis.
		for d in [["outward", "Away from axis" if open else "Out"], ["inward", "Toward axis" if open else "In"], ["symmetric", "Both sides" if open else "Mid"]]:
			list.append({"id": "rev_dir_" + d[0], "text": d[1], "toggle": true, "pressed": str(o["rev_dir"]) == d[0]})
	list.append({"id": "axis", "text": "Axis: set" if ed.revolve_axis != "" else "Axis: pick"})
	list.append({"id": "apply", "text": "Apply", "disabled": not can_apply(ed)})
	if ed.session == null and ed.seed_sketch != "":
		list.insert(list.size() - 1, {"id": "clear_seed", "text": "Clear"}) # forget the picked profile and axis
	if ed.session == null:
		list.insert(list.size() - 1, ed.targets_option())
	return list


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"boss":
			ed.options["boss"] = true
		"cut":
			ed.options["boss"] = false
		"angle":
			ed.type_option("angle", "Angle (deg, up to 360)")
		"rev_thin":
			ed.options["rev_thin"] = not bool(ed.options["rev_thin"])
		"rev_wall":
			ed.type_option("rev_wall", "Wall thickness (mm)")
		"rev_dir_outward", "rev_dir_inward", "rev_dir_symmetric":
			ed.options["rev_dir"] = option_id.trim_prefix("rev_dir_")
		"clear_seed":
			ed.clear_seed()
		"targets":
			ed.toggle_target_picking()
		"axis":
			ed.table.set_status("Pull the trigger on a line of the sketch to make it the axis.")
			if ed.session == null and ed.seed_sketch == "":
				ed.table.set_status("Pull the trigger on a line of a sketch to use it, then on a line of it for the axis.")
		_:
			return false
	return true


func on_activated(ed) -> void:
	if ed.session == null:
		ed.start_sketch_pick() # no sketch open: the visible finished sketches are offered
		return
	if not ed.session.profile_ok() and not ed.session.open_chain_ok():
		ed.table.set_status("The sketch needs a closed shape, or one open line chain for a thin wall (and a line to spin it about).")
	if ed.state in ["pick_edges", "extrude"]:
		ed.set_state("sketch" if ed.session != null else "pick_plane") # the laser picks the axis line on the sketch, so the sketch stays live


func can_apply(ed) -> bool:
	return (ed.seed_ready() or _open_profile(ed)) and ed.revolve_axis != ""


func finishes_sketch() -> bool:
	return true ## spends the OPEN sketch (the editor only ends one that is open)


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	if not ed.seed_ready() and not _open_profile(ed):
		return PartFeatures._bad("The sketch needs a closed shape, or one open line chain for a thin wall, to revolve.")
	var extra := {}
	if _thin(ed):
		extra["thickness"] = float(ed.options["rev_wall"])
		extra["thickness_direction"] = str(ed.options["rev_dir"])
	return PartFeatures.revolve_request(ed.seed_sketch_id(), ed.seed_axis_sketch_id(), ed.revolve_axis, float(ed.options["angle"]), bool(ed.options["boss"]), ed.extrude_targets(), extra)
