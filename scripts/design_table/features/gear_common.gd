extends RefCounted
## What the three gear tools (gear_tool.gd, rack_tool.gd, bevel_gear_tool.gd) share: their settings live in the editor's `options` under their own keys (so the
## popup keyboard's type_option / option_typed work on them), the plane they stand on is held as the backend's plane_ref, and the pressure angle cycles.

const PRESSURE_ANGLES := [20.0, 14.5, 25.0]


static func ensure(ed, defaults: Dictionary) -> void:
	## A tool's settings are put in the editor's options the first time the tool looks at them (the editor's own list stays about the older tools).
	for key in defaults:
		if not ed.options.has(key):
			ed.options[key] = defaults[key]


static func next_pressure_angle(current: float) -> float:
	var i := -1
	for k in PRESSURE_ANGLES.size():
		if is_equal_approx(float(PRESSURE_ANGLES[k]), current):
			i = k
	return float(PRESSURE_ANGLES[(i + 1) % PRESSURE_ANGLES.size()])


static func plane_ref_from_spec(spec: Dictionary) -> Dictionary:
	## The backend's plane_ref for what the laser picked ({fixed} | {face: {body_id, index}} | {plane_feature_id}).
	if spec.has("fixed"):
		return {"fixed_plane": str(spec["fixed"])}
	if spec.has("face"):
		return {"face_ref": {"body_id": str(spec["face"]["body_id"]), "shape_type": "face", "index": int(spec["face"]["index"])}}
	if spec.has("plane_feature_id"):
		return {"plane_feature_id": str(spec["plane_feature_id"])}
	return {}


static func plane_ref_from_row(row: Dictionary) -> Dictionary:
	## A feature row's plane_ref has every key, the unused ones null: only the one in use is kept. An XY plane is the default, so it comes back as {} (no plane picked).
	var ref = row.get("plane_ref")
	if not (ref is Dictionary):
		return {}
	var out := {}
	for key in ["fixed_plane", "face_ref", "plane_feature_id"]:
		if ref.get(key) != null:
			out[key] = ref[key]
	if out.get("fixed_plane") == "XY" and out.size() == 1:
		return {}
	return out


static func plane_text(plane_ref: Dictionary) -> String:
	if plane_ref.is_empty():
		return "XY plane"
	if plane_ref.has("fixed_plane"):
		return "%s plane" % str(plane_ref["fixed_plane"])
	if plane_ref.has("plane_feature_id"):
		return "a made plane"
	return "a face"


static func num(x: float) -> String:
	var s := "%.2f" % x
	return s.rstrip("0").rstrip(".")
