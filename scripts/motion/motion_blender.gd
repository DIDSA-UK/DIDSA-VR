extends RefCounted
## Displayed-vs-anchor blend (DIDSA-CAD docs/motion/projector-spec.md §9). A
## newly accepted anchor changes the model, so the projection of the same wish
## jumps by the anchor step; the blender keeps a per-member offset in the
## pose_delta chart and decays it by exp(−1/τ) per frame. DISPLAY ONLY: never
## feed `shown` back into the wish, never persist it.

const Se3 := preload("res://scripts/motion/se3.gd")

const TAU_FRAMES := 2.0 ## ≈ 33 ms at 60 Hz
const SETTLED := 1e-6 ## offsets below this weighted size may be dropped

var offsets: Array = [] ## one 6-vector per member
var _decay := 0.0


func _init(member_count: int = 1, tau_frames: float = TAU_FRAMES) -> void:
	_decay = exp(-1.0 / tau_frames)
	reset(member_count)


func reset(member_count: int = -1) -> void:
	var n := offsets.size() if member_count < 0 else member_count
	offsets = []
	for _m in n:
		offsets.append([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])


## Call on the frame a new anchor is accepted, BEFORE shown(): continuity with what the OLD model would have shown this frame.
func on_anchor(old_projected: Array, new_projected: Array) -> void:
	var old_shown: Array = []
	for m in old_projected.size():
		old_shown.append(Se3.apply_delta(old_projected[m], offsets[m]))
	offsets = []
	for m in old_shown.size():
		offsets.append(Se3.pose_delta(old_shown[m], new_projected[m]))


## apply_delta(P, o) per member, then decays the offsets by one frame.
func shown(projected: Array) -> Array:
	var out: Array = []
	for m in projected.size():
		out.append(Se3.apply_delta(projected[m], offsets[m]))
	for o in offsets:
		for i in 6:
			o[i] *= _decay
	return out


func is_settled(lever: float) -> bool:
	for o in offsets:
		var n := sqrt(pow(o[0], 2) + pow(o[1], 2) + pow(o[2], 2) + pow(o[3] * lever, 2) + pow(o[4] * lever, 2) + pow(o[5] * lever, 2))
		if n >= SETTLED:
			return false
	return true
