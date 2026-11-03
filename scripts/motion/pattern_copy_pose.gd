extends RefCounted
## The pose of a pattern copy for a source at a pose: a GDScript mirror of DIDSA-CAD's `assembly.pattern_copy_pose` / `pattern_step` (and the Flutter
## client's `patternCopyPose`). Checked against the same committed golden fixture (tests/fixtures/pattern_copy_pose_vectors.json, generated from the
## backend: tests/pattern_copy_pose.gd). Plain doubles in the repo's own `Se3` pose form ({t, r}), not Transform3D (float32): only the edge touches it.
##
## `pattern` is a component pattern row as the backend sends it (`GET /parts/{id}/component-patterns`): pattern_type, direction, count, spacing,
## reverse, direction_2, count_2, spacing_2, reverse_2, axis {origin, direction}, count_angular, angle_total, reverse_angular, skip_indices,
## orient_with_rotation. Poses are in the pattern's own frame (the owning Part's: a source occurrence's LOCAL transform).

const Se3 := preload("res://scripts/motion/se3.gd")
const SEGMENT := "#pattern:"


## The indices of the live copies of `pattern` (every derived index, the seed 0 being the source itself, that is not skipped). Backend `_live_pattern_indices`.
static func live_indices(pattern: Dictionary) -> Array:
	var skipped := {}
	for s in pattern.get("skip_indices", []):
		skipped[int(s)] = true
	var total := 1
	if str(pattern.get("pattern_type", "linear")) == "linear":
		total = maxi(int(pattern.get("count", 1)), 1) * maxi(int(pattern.get("count_2", 1)), 1)
	else:
		total = maxi(int(pattern.get("count_angular", 1)), 1)
	var out: Array = []
	for i in range(1, total):
		if not skipped.has(i):
			out.append(i)
	return out


static func _unit_step(direction: Array, distance: float) -> Array:
	var n := Se3.norm3(direction)
	if n < 1e-6:
		return [0.0, 0.0, 0.0] # a degenerate direction is refused by the backend before it is ever stored
	return [direction[0] / n * distance, direction[1] / n * distance, direction[2] / n * distance]


## {step: pose, keep_rotation: bool} of copy `index`: the copy of a source at (R, t) is at `step ∘ (R, t)`, with R itself kept when `keep_rotation`
## (Circular, orient_with_rotation false). Backend `pattern_step`.
static func step(pattern: Dictionary, index: int) -> Dictionary:
	if str(pattern.get("pattern_type", "linear")) == "linear":
		var count_2 := maxi(int(pattern.get("count_2", 1)), 1)
		var i := index / count_2
		var j := index % count_2
		var sign_1 := -1.0 if bool(pattern.get("reverse", false)) else 1.0
		var sign_2 := -1.0 if bool(pattern.get("reverse_2", false)) else 1.0
		var t := _unit_step(pattern.get("direction", [1.0, 0.0, 0.0]), float(pattern.get("spacing", 0.0)) * i * sign_1)
		if count_2 > 1:
			var t2 := _unit_step(pattern.get("direction_2", [0.0, 1.0, 0.0]), float(pattern.get("spacing_2", 0.0)) * j * sign_2)
			t = [t[0] + t2[0], t[1] + t2[1], t[2] + t2[2]]
		return {"step": Se3.make_pose(t, Se3.identity()), "keep_rotation": false}
	var count := maxi(int(pattern.get("count_angular", 1)), 1)
	var axis = pattern.get("axis")
	var origin: Array = [0.0, 0.0, 0.0] if not (axis is Dictionary) else axis["origin"]
	var direction: Array = [0.0, 0.0, 1.0] if not (axis is Dictionary) else axis["direction"]
	var angle := float(pattern.get("angle_total", 360.0)) / count * index * (-1.0 if bool(pattern.get("reverse_angular", false)) else 1.0)
	# T(origin) R(axis, angle) T(-origin): its translation term is `origin - R origin`
	var r := Se3.rot_axis_angle(direction, angle)
	var ro := Se3.mat_vec(r, origin)
	return {"step": Se3.make_pose([origin[0] - ro[0], origin[1] - ro[1], origin[2] - ro[2]], r), "keep_rotation": not bool(pattern.get("orient_with_rotation", true))}


## `parent ∘ child`: apply `child` first, then `parent` (the backend's `compose`).
static func compose(parent: Dictionary, child: Dictionary) -> Dictionary:
	var rt := Se3.mat_vec(parent["r"], child["t"])
	return Se3.make_pose([rt[0] + parent["t"][0], rt[1] + parent["t"][1], rt[2] + parent["t"][2]], Se3.mat_mul(parent["r"], child["r"]))


static func copy_pose(pattern: Dictionary, source: Dictionary, index: int) -> Dictionary:
	## The pose of copy `index` of `pattern` for a source at `source`. Does not check that the index is live (`live_indices` does).
	var s := step(pattern, index)
	var composed := compose(s["step"], source)
	if bool(s["keep_rotation"]):
		return Se3.make_pose(composed["t"], source["r"])
	return composed


## {source, pattern, index} of a copy segment `<source>#pattern:<pattern id>:<index>`; empty for any other segment.
static func parse_segment(segment: String) -> Dictionary:
	var at := segment.find(SEGMENT)
	if at < 0:
		return {}
	var rest := segment.substr(at + SEGMENT.length())
	var colon := rest.rfind(":")
	if colon < 0 or not rest.substr(colon + 1).is_valid_int():
		return {}
	return {"source": segment.substr(0, at), "pattern": rest.substr(0, colon), "index": int(rest.substr(colon + 1))}
