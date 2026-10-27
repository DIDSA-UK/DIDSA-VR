extends "res://scripts/design_table/features/feature_tool.gd"
## Helix: a helix curve made from its numbers (no sketch): a start diameter, an optional taper (an end diameter OR a taper angle; the other is shown for information),
## and the pitch: any number of segments (pitch and turns each, so a spring can have tight end coils) or, with Pitch: varies, the pitch at distances
## along the axis, changing smoothly between them (the backend's pitch_points; the last distance is the height), right- or left-handed. It stands on the part's XY plane unless a plane or flat
## face is picked first: the plane's normal is the axis, its origin the start, its x axis where the start lies. The result is a curve feature (not a body): a
## Sweep path, a Fill boundary, and a plane can be made normal to it. The backend has no coarse preview for a curve, so it is made when the settings change (and
## taken back on Cancel) like the other eager tools. The tool id is "helix"; the backend's feature type is "curve" (PartFeatures.ROUTE_TYPES).
## Diameters (the mean diameter, through the wire centre: a spring is specified that way), as in the flat app; the backend and the rows hold radii, halved/doubled here.

const Common := preload("res://scripts/design_table/features/gear_common.gd")

const TAPERS := ["none", "end_diameter", "angle"]

## The settings live in the editor's `options` (h_ keys), not in this object: the Build tree's Edit asks FeatureTools.for_type for the tool, which is another instance than the
## editor's own, and it loads the row into the editor.
const DEFAULTS := {"h_diameter": 10.0, "h_taper": "none", "h_taper_value": 16.0, "h_segments": [{"pitch": 2.0, "turns": 3.0}], "h_points": [], "h_right": true, "h_plane": {}}


func _init() -> void:
	id = "helix"


func build_type() -> String:
	return "curve"


func edits_row(row: Dictionary) -> bool:
	return str(row.get("curve_type", "")) == "helix" # an intersection curve has no settings here


func _o(ed) -> Dictionary:
	## The settings, put into the editor's options the first time they are looked at (each a copy, the arrays are edited in place).
	for key in DEFAULTS:
		if not ed.options.has(key):
			ed.options[key] = DEFAULTS[key].duplicate(true) if DEFAULTS[key] is Array or DEFAULTS[key] is Dictionary else DEFAULTS[key]
	return ed.options


func total_height(ed) -> float:
	var points: Array = _o(ed)["h_points"]
	if not points.is_empty():
		return absf(float((points.back() as Dictionary)["at"]))
	var total := 0.0
	for seg in _o(ed)["h_segments"]:
		total += absf(float((seg as Dictionary)["pitch"])) * float((seg as Dictionary)["turns"])
	return total


func taper_readout(ed) -> String:
	## The taper as the other quantity: an end diameter shows its angle, an angle shows the end diameter it gives (the backend does the same sum, in radii).
	var o := _o(ed)
	var h := total_height(ed)
	if h <= 0.0 or o["h_taper"] == "none":
		return ""
	if o["h_taper"] == "end_diameter":
		return "= %s deg" % Common.num(rad_to_deg(atan((float(o["h_taper_value"]) - float(o["h_diameter"])) / 2.0 / h)))
	if absf(float(o["h_taper_value"])) >= 90.0:
		return ""
	return "= end diameter %s mm" % Common.num(float(o["h_diameter"]) + 2.0 * h * tan(deg_to_rad(float(o["h_taper_value"]))))


func options(ed) -> Array:
	var o := _o(ed)
	var list: Array = [{"id": "h_diameter", "text": "Diameter %s mm" % Common.num(float(o["h_diameter"]))}]
	list.append({"id": "h_taper", "text": "Taper: %s" % {"none": "none", "end_diameter": "end diameter", "angle": "angle"}[o["h_taper"]]})
	if o["h_taper"] != "none":
		list.append({"id": "h_taper_value", "text": ("End diameter %s mm" if o["h_taper"] == "end_diameter" else "Angle %s deg") % Common.num(float(o["h_taper_value"]))})
		var readout := taper_readout(ed)
		if readout != "":
			list.append({"id": "h_taper_info", "text": readout, "disabled": true}) # the other quantity, for information
	var points: Array = o["h_points"]
	list.append({"id": "h_pitch_mode", "text": "Pitch: %s" % ("varies" if not points.is_empty() else "segments")})
	if not points.is_empty():
		for i in points.size():
			var point: Dictionary = points[i]
			if i > 0:
				list.append({"id": "h_at_%d" % i, "text": "Point %d: at %s mm" % [i + 1, Common.num(float(point["at"]))]})
			list.append({"id": "h_ppitch_%d" % i, "text": "Point %d%s: pitch %s mm" % [i + 1, " (start)" if i == 0 else "", Common.num(float(point["pitch"]))]})
			if i > 0 and points.size() > 2:
				list.append({"id": "h_pdel_%d" % i, "text": "Remove point %d" % (i + 1)})
		list.append({"id": "h_padd", "text": "Add point"})
	else:
		var segments: Array = o["h_segments"]
		for i in segments.size():
			var seg: Dictionary = segments[i]
			list.append({"id": "h_pitch_%d" % i, "text": "Segment %d: pitch %s mm" % [i + 1, Common.num(float(seg["pitch"]))]})
			list.append({"id": "h_turns_%d" % i, "text": "Segment %d: %s turns" % [i + 1, Common.num(float(seg["turns"]))]})
			if segments.size() > 1:
				list.append({"id": "h_del_%d" % i, "text": "Remove segment %d" % (i + 1)})
		list.append({"id": "h_add", "text": "Add segment"})
	list.append({"id": "h_hand", "text": "Right-handed", "toggle": true, "pressed": bool(o["h_right"])})
	list.append({"id": "h_plane", "text": "Plane: %s" % Common.plane_text(o["h_plane"]), "toggle": true, "pressed": false})
	list.append({"id": "apply", "text": "Apply (height %s mm)" % Common.num(total_height(ed)), "disabled": not can_apply(ed)})
	return list


func handle_option(ed, option_id: String) -> bool:
	var o := _o(ed)
	match option_id:
		"h_diameter", "h_taper_value":
			_ask(ed, option_id)
			return true
		"h_taper":
			o["h_taper"] = TAPERS[(TAPERS.find(o["h_taper"]) + 1) % TAPERS.size()]
			if o["h_taper"] == "end_diameter":
				o["h_taper_value"] = float(o["h_diameter"]) + 6.0
			elif o["h_taper"] == "angle":
				o["h_taper_value"] = 10.0
		"h_add":
			var last: Dictionary = (o["h_segments"] as Array).back()
			(o["h_segments"] as Array).append({"pitch": float(last["pitch"]), "turns": 1.0})
		"h_hand":
			o["h_right"] = not bool(o["h_right"])
		"h_pitch_mode":
			if (o["h_points"] as Array).is_empty():
				# Varying pitch starts from the segments' own pitches: the first at the start, the last at the top (the same height).
				var segments: Array = o["h_segments"]
				var height := total_height(ed)
				o["h_points"] = [{"at": 0.0, "pitch": float((segments[0] as Dictionary)["pitch"])}, {"at": height, "pitch": float((segments.back() as Dictionary)["pitch"])}]
			else:
				o["h_points"] = []
		"h_padd":
			var last: Dictionary = (o["h_points"] as Array).back()
			(o["h_points"] as Array).append({"at": float(last["at"]) + 2.0 * absf(float(last["pitch"])), "pitch": float(last["pitch"])})
		"h_plane":
			ed.set_pick_mode("plane")
			ed.table.set_status("Aim at a plane or a flat face and pull the trigger: the helix's axis is its normal.")
		_:
			if option_id.begins_with("h_pitch_") or option_id.begins_with("h_turns_") or option_id.begins_with("h_at_") or option_id.begins_with("h_ppitch_"):
				_ask(ed, option_id)
				return true
			if option_id.begins_with("h_pdel_"):
				if (o["h_points"] as Array).size() > 2:
					(o["h_points"] as Array).remove_at(int(option_id.trim_prefix("h_pdel_")))
			elif option_id.begins_with("h_del_"):
				if (o["h_segments"] as Array).size() > 1:
					(o["h_segments"] as Array).remove_at(int(option_id.trim_prefix("h_del_")))
			else:
				return false
	ed._update_options()
	ed.schedule_preview()
	return true


func _ask(ed, key: String) -> void:
	## The popup keyboard for one number; what is typed goes to type_value.
	var titles := {"h_diameter": "Diameter at the start (mm, through the wire centre)", "h_taper_value": "End diameter (mm)" if _o(ed)["h_taper"] == "end_diameter" else "Taper angle (degrees, + widens)"}
	var title: String = titles.get(key, "Pitch: height per turn (mm, negative goes the other way)" if key.begins_with("h_pitch_") or key.begins_with("h_ppitch_")
		else ("Distance from the start (mm)" if key.begins_with("h_at_") else "Turns"))
	ed.table._main.open_keyboard_for("%.2f" % _value_of(ed, key), func(text: String) -> void: type_value(ed, key, text), {"title": title})


func _value_of(ed, key: String) -> float:
	var o := _o(ed)
	if key == "h_diameter" or key == "h_taper_value":
		return float(o[key])
	if key.begins_with("h_at_") or key.begins_with("h_ppitch_"):
		return float((o["h_points"] as Array)[int(key.get_slice("_", 2))]["at" if key.begins_with("h_at_") else "pitch"])
	return float((o["h_segments"] as Array)[int(key.get_slice("_", 2))]["pitch" if key.begins_with("h_pitch_") else "turns"])


func type_value(ed, key: String, text: String) -> void:
	## A typed number for a setting: kept when allowed (the panel and the preview follow), else said why not.
	var o := _o(ed)
	var cleaned := text.strip_edges()
	if not cleaned.is_valid_float():
		ed.table.set_status("Enter a number.")
		return
	var v := cleaned.to_float()
	if key == "h_diameter":
		if v <= 0.0:
			ed.table.set_status("The diameter has to be bigger than zero.")
			return
		o["h_diameter"] = v
	elif key == "h_taper_value":
		if o["h_taper"] == "end_diameter" and v <= 0.0:
			ed.table.set_status("The end diameter has to be bigger than zero.")
			return
		if o["h_taper"] == "angle" and absf(v) >= 90.0:
			ed.table.set_status("The taper angle has to be under 90 degrees.")
			return
		o["h_taper_value"] = v
	elif key.begins_with("h_at_"):
		var i := int(key.get_slice("_", 2))
		var points: Array = o["h_points"]
		if v <= float((points[i - 1] as Dictionary)["at"]) or (i + 1 < points.size() and v >= float((points[i + 1] as Dictionary)["at"])):
			ed.table.set_status("A point has to be further along than the one before it and short of the one after.")
			return
		points[i]["at"] = v
	elif key.begins_with("h_ppitch_"):
		if is_zero_approx(v):
			ed.table.set_status("The pitch can't be zero.")
			return
		o["h_points"][int(key.get_slice("_", 2))]["pitch"] = v
	elif key.begins_with("h_pitch_"):
		if is_zero_approx(v):
			ed.table.set_status("The pitch can't be zero.")
			return
		o["h_segments"][int(key.get_slice("_", 2))]["pitch"] = v
	else:
		if v <= 0.0:
			ed.table.set_status("The turns have to be more than zero.")
			return
		o["h_segments"][int(key.get_slice("_", 2))]["turns"] = v
	ed._update_options()
	ed.schedule_preview()


func on_activated(ed) -> void:
	if ed.activating_edit:
		return # a Build row's Edit loads its own settings
	_o(ed)["h_plane"] = {}
	if ed.session != null:
		ed.table.set_status("Finish the sketch first (Done), then make a helix.")
		return
	ed.set_pick_mode("plane")
	ed.table.set_status("Set the helix, then Apply. To stand it on another plane, pull the trigger on that plane or a flat face first.")


func wants_plane_pick() -> bool:
	return true


func on_plane_picked(ed, spec: Dictionary) -> void:
	_o(ed)["h_plane"] = Common.plane_ref_from_spec(spec)
	ed.table.set_status("The helix's axis is the normal of %s." % Common.plane_text(_o(ed)["h_plane"]))
	ed._update_options()
	ed.schedule_preview()


func can_apply(ed) -> bool:
	return request(ed)["ok"]


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	var o := _o(ed)
	var end_diameter: bool = o["h_taper"] == "end_diameter"
	return PartFeatures.helix_request({"radius": float(o["h_diameter"]) / 2.0, "taper": "end_radius" if end_diameter else str(o["h_taper"]),
		"taper_value": float(o["h_taper_value"]) / 2.0 if end_diameter else float(o["h_taper_value"]), "segments": o["h_segments"], "points": o["h_points"],
		"right_handed": bool(o["h_right"])}, o["h_plane"])


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["axis_ref", "radius", "end_radius", "segments", "pitch_points", "right_handed"]


func patch_body(req: Dictionary) -> Dictionary:
	## An update keeps what it is not sent, so turning the taper off has to say so (an explicit null clears the end radius).
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	body.erase("curve_type")
	if not body.has("end_radius") and not body.has("taper_angle_degrees"):
		body["end_radius"] = null
	# The pitch form in use replaces the other (the backend clears the one sent empty).
	if body.has("pitch_points"):
		body["segments"] = []
	else:
		body["pitch_points"] = []
	return body


func load_from_row(ed, row: Dictionary) -> void:
	var o := _o(ed)
	o["h_diameter"] = 2.0 * float(row.get("radius", 5.0))
	o["h_right"] = bool(row.get("right_handed", true))
	var segments: Array = []
	for seg in row.get("segments", []):
		segments.append({"pitch": float((seg as Dictionary).get("pitch", 2.0)), "turns": float((seg as Dictionary).get("turns", 1.0))})
	o["h_segments"] = segments if not segments.is_empty() else [{"pitch": 2.0, "turns": 3.0}]
	var points: Array = []
	for point in row.get("pitch_points", []):
		points.append({"at": float((point as Dictionary).get("at", 0.0)), "pitch": float((point as Dictionary).get("pitch", 2.0))})
	o["h_points"] = points
	if row.get("end_radius") != null:
		o["h_taper"] = "end_diameter"
		o["h_taper_value"] = 2.0 * float(row["end_radius"])
	else:
		o["h_taper"] = "none"
	o["h_plane"] = Common.plane_ref_from_row({"plane_ref": row.get("axis_ref")})


func row_payload(row: Dictionary) -> Dictionary:
	## What puts the old values back on Undo: the stored end radius is sent as it was (an explicit null when there was none).
	var out := {}
	for key in ["axis_ref", "radius", "segments", "pitch_points", "right_handed"]:
		if row.has(key):
			out[key] = row[key]
	out["end_radius"] = row.get("end_radius")
	return out


func summary(f: Dictionary, _features: Array) -> String:
	if str(f.get("curve_type", "")) != "helix":
		return ""
	var segments: Array = f.get("segments", []) as Array
	var points: Array = f.get("pitch_points", []) as Array
	var turns := 0.0
	for seg in segments:
		turns += float((seg as Dictionary).get("turns", 0.0))
	if not points.is_empty() and f.get("total_turns") != null:
		turns = float(f["total_turns"])
	var diameter := "D %s" % Common.num(2.0 * float(f.get("radius", 0.0)))
	if f.get("end_radius") != null:
		diameter += " to %s" % Common.num(2.0 * float(f["end_radius"]))
	var pitch := "%d segment%s" % [segments.size(), "" if segments.size() == 1 else "s"]
	if not points.is_empty():
		pitch = "pitch varies over %d points" % points.size()
	return "%s mm, %s turns, %s, %s" % [diameter, Common.num(turns), pitch, "right-handed" if bool(f.get("right_handed", true)) else "left-handed"]


func done_text() -> String:
	return "Helix made."
