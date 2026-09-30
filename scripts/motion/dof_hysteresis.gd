extends RefCounted
## Rank/dof-change hysteresis (DIDSA-CAD docs/motion/projector-spec.md §10). A
## dof DROP (a new wall) or equal dof is adopted at once so the user feels the
## wall; a dof RISE keeps the old directions until GAIN_FRAMES consecutive
## frames show a real gain (the wish captured only by the new directions).

const Se3 := preload("res://scripts/motion/se3.gd")
const Projector := preload("res://scripts/motion/free_motion_projector.gd")

const GAIN_MIN := 0.05 ## weighted mm the wish must gain from the new directions for a frame to count
const GAIN_FRAMES := 3

var active = null ## a Projector
var _cand: Array = [] ## candidate rows (empty = none)
var _has_cand := false
var count := 0


func reset() -> void:
	active = null
	_cand = []
	_has_cand = false
	count = 0


func dim() -> int:
	return 0 if active == null else active.dim()


func has_candidate() -> bool:
	return _has_cand


## Feed an ACCEPTED anchor (a Projector). Returns "adopted" or "candidate".
func on_anchor(anchor) -> String:
	if active == null or anchor.dim() <= active.dim():
		active = anchor
		_cand = []
		_has_cand = false
		count = 0
		return "adopted"
	# more freedom: refresh the reference, keep the old directions, remember the candidate
	active = active.with_rows(active.rows, anchor.refs)
	_cand = anchor.rows
	_has_cand = true
	return "candidate"


## The active model's projection of `wanted` WITHOUT advancing the candidate counter (for blending at an anchor).
func peek(wanted: Dictionary, integrator: int = Projector.Integrator.SCREW) -> Array:
	return active.project(wanted, integrator)


## One frame. Returns {"poses", "gain", "event" ("none" | "adopted"), "prev_poses" (only when adopted: what the OLD rows showed, for blending)}.
func frame(wanted: Dictionary, integrator: int = Projector.Integrator.SCREW) -> Dictionary:
	var cur = active
	var want: Array = cur.wish_vector(wanted)
	var gain := 0.0
	var event := "none"
	var prev: Array = []
	if _has_cand:
		var full := Projector.project_onto_rows(_cand, cur.scale, want)
		var old := Projector.project_onto_rows(cur.rows, cur.scale, want)
		var diff: Array = []
		for i in want.size():
			diff.append(full[i] - old[i])
		gain = Projector.weighted_norm(cur.scale, diff)
		count = count + 1 if gain > GAIN_MIN else 0
		if count >= GAIN_FRAMES:
			prev = cur.project(wanted, integrator)
			cur = cur.with_rows(_cand)
			active = cur
			_cand = []
			_has_cand = false
			count = 0
			event = "adopted"
	var out := {"poses": cur.project(wanted, integrator), "gain": gain, "event": event}
	if event == "adopted":
		out["prev_poses"] = prev
	return out
