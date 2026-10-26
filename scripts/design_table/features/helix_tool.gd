extends "res://scripts/design_table/features/feature_tool.gd"
## Helix: a helix curve made from its numbers (no sketch): a start radius, an optional taper (an end radius OR a taper angle; the other is shown for information),
## and any number of segments (pitch and turns each, so a spring can have tight end coils), right- or left-handed. It stands on the part's XY plane unless a plane or flat
## face is picked first: the plane's normal is the axis, its origin the start, its x axis where the start lies. The result is a curve feature (not a body): a
## Sweep path, a Fill boundary, and a plane can be made normal to it. The backend has no coarse preview for a curve, so it is made when the settings change (and
## taken back on Cancel) like the other eager tools. The tool id is "helix"; the backend's feature type is "curve" (PartFeatures.ROUTE_TYPES).

const Common := preload("res://scripts/design_table/features/gear_common.gd")

const TAPERS := ["none", "end_radius", "angle"]

## The settings live in the editor's `options` (h_ keys), not in this object: the Build tree's Edit asks FeatureTools.for_type for the tool, which is another instance than the
## editor's own, and it loads the row into the editor.
const DEFAULTS := {"h_radius": 5.0, "h_taper": "none", "h_taper_value": 8.0, "h_segments": [{"pitch": 2.0, "turns": 3.0}], "h_right": true, "h_plane": {}}


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
	var total := 0.0
	for seg in _o(ed)["h_segments"]:
		total += absf(float((seg as Dictionary)["pitch"])) * float((seg as Dictionary)["turns"])
	return total


func taper_readout(ed) -> String:
	## The taper as the other quantity: an end radius shows its angle, an angle shows the end radius it gives (the backend does the same sum).
	var o := _o(ed)
	var h := total_height(ed)
	if h <= 0.0 or o["h_taper"] == "none":
		return ""
	if o["h_taper"] == "end_radius":
		return "= %s deg" % Common.num(rad_to_deg(atan((float(o["h_taper_value"]) - float(o["h_radius"])) / h)))
	if absf(float(o["h_taper_value"])) >= 90.0:
		return ""
	return "= end radius %s mm" % Common.num(float(o["h_radius"]) + h * tan(deg_to_rad(float(o["h_taper_value"]))))


func options(ed) -> Array:
	var o := _o(ed)
	var list: Array = [{"id": "h_radius", "text": "Radius %s mm" % Common.num(float(o["h_radius"]))}]
	list.append({"id": "h_taper", "text": "Taper: %s" % {"none": "none", "end_radius": "end radius", "angle": "angle"}[o["h_taper"]]})
	if o["h_taper"] != "none":
		list.append({"id": "h_taper_value", "text": ("End radius %s mm" if o["h_taper"] == "end_radius" else "Angle %s deg") % Common.num(float(o["h_taper_value"]))})
		var readout := taper_readout(ed)
		if readout != "":
			list.append({"id": "h_taper_info", "text": readout, "disabled": true}) # the other quantity, for information
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
		"h_radius", "h_taper_value":
			_ask(ed, option_id)
			return true
		"h_taper":
			o["h_taper"] = TAPERS[(TAPERS.find(o["h_taper"]) + 1) % TAPERS.size()]
			if o["h_taper"] == "end_radius":
				o["h_taper_value"] = float(o["h_radius"]) + 3.0
			elif o["h_taper"] == "angle":
				o["h_taper_value"] = 10.0
		"h_add":
			var last: Dictionary = (o["h_segments"] as Array).back()
			(o["h_segments"] as Array).append({"pitch": float(last["pitch"]), "turns": 1.0})
		"h_hand":
			o["h_right"] = not bool(o["h_right"])
		"h_plane":
			ed.set_pick_mode("plane")
			ed.table.set_status("Aim at a plane or a flat face and pull the trigger: the helix's axis is its normal.")
		_:
			if option_id.begins_with("h_pitch_") or option_id.begins_with("h_turns_"):
				_ask(ed, option_id)
				return true
			if option_id.begins_with("h_del_"):
				if (o["h_segments"] as Array).size() > 1:
					(o["h_segments"] as Array).remove_at(int(option_id.trim_prefix("h_del_")))
			else:
				return false
	ed._update_options()
	ed.schedule_preview()
	return true


func _ask(ed, key: String) -> void:
	## The popup keyboard for one number; what is typed goes to type_value.
	var titles := {"h_radius": "Radius at the start (mm)", "h_taper_value": "End radius (mm)" if _o(ed)["h_taper"] == "end_radius" else "Taper angle (degrees, + widens)"}
	var title: String = titles.get(key, "Pitch: height per turn (mm, negative goes the other way)" if key.begins_with("h_pitch_") else "Turns")
	ed.table._main.open_keyboard_for("%.2f" % _value_of(ed, key), func(text: String) -> void: type_value(ed, key, text), {"title": title})


func _value_of(ed, key: String) -> float:
	var o := _o(ed)
	if key == "h_radius" or key == "h_taper_value":
		return float(o[key])
	return float((o["h_segments"] as Array)[int(key.get_slice("_", 2))]["pitch" if key.begins_with("h_pitch_") else "turns"])


func type_value(ed, key: String, text: String) -> void:
	## A typed number for a setting: kept when allowed (the panel and the preview follow), else said why not.
	var o := _o(ed)
	var cleaned := text.strip_edges()
	if not cleaned.is_valid_float():
		ed.table.set_status("Enter a number.")
		return
	var v := cleaned.to_float()
	if key == "h_radius":
		if v <= 0.0:
			ed.table.set_status("The radius has to be bigger than zero.")
			return
		o["h_radius"] = v
	elif key == "h_taper_value":
		if o["h_taper"] == "end_radius" and v <= 0.0:
			ed.table.set_status("The end radius has to be bigger than zero.")
			return
		if o["h_taper"] == "angle" and absf(v) >= 90.0:
			ed.table.set_status("The taper angle has to be under 90 degrees.")
			return
		o["h_taper_value"] = v
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
	return PartFeatures.helix_request({"radius": float(o["h_radius"]), "taper": str(o["h_taper"]), "taper_value": float(o["h_taper_value"]), "segments": o["h_segments"], "right_handed": bool(o["h_right"])}, o["h_plane"])


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["axis_ref", "radius", "end_radius", "segments", "right_handed"]


func patch_body(req: Dictionary) -> Dictionary:
	## An update keeps what it is not sent, so turning the taper off has to say so (an explicit null clears the end radius).
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	body.erase("curve_type")
	if not body.has("end_radius") and not body.has("taper_angle_degrees"):
		body["end_radius"] = null
	return body


func load_from_row(ed, row: Dictionary) -> void:
	var o := _o(ed)
	o["h_radius"] = float(row.get("radius", 5.0))
	o["h_right"] = bool(row.get("right_handed", true))
	var segments: Array = []
	for seg in row.get("segments", []):
		segments.append({"pitch": float((seg as Dictionary).get("pitch", 2.0)), "turns": float((seg as Dictionary).get("turns", 1.0))})
	o["h_segments"] = segments if not segments.is_empty() else [{"pitch": 2.0, "turns": 3.0}]
	if row.get("end_radius") != null:
		o["h_taper"] = "end_radius"
		o["h_taper_value"] = float(row["end_radius"])
	else:
		o["h_taper"] = "none"
	o["h_plane"] = Common.plane_ref_from_row({"plane_ref": row.get("axis_ref")})


func row_payload(row: Dictionary) -> Dictionary:
	## What puts the old values back on Undo: the stored end radius is sent as it was (an explicit null when there was none).
	var out := {}
	for key in ["axis_ref", "radius", "segments", "right_handed"]:
		if row.has(key):
			out[key] = row[key]
	out["end_radius"] = row.get("end_radius")
	return out


func summary(f: Dictionary, _features: Array) -> String:
	if str(f.get("curve_type", "")) != "helix":
		return ""
	var segments: Array = f.get("segments", []) as Array
	var turns := 0.0
	for seg in segments:
		turns += float((seg as Dictionary).get("turns", 0.0))
	var radius := "R %s" % Common.num(float(f.get("radius", 0.0)))
	if f.get("end_radius") != null:
		radius += " to %s" % Common.num(float(f["end_radius"]))
	return "%s mm, %s turns, %d segment%s, %s" % [radius, Common.num(turns), segments.size(), "" if segments.size() == 1 else "s", "right-handed" if bool(f.get("right_handed", true)) else "left-handed"]


func done_text() -> String:
	return "Helix made."
