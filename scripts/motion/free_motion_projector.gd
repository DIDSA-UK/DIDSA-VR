extends RefCounted
## The per-frame free-motion projector (DIDSA-CAD docs/motion/projector-spec.md
## §2-§5): given the latest accepted anchor (reference poses + free-motion basis)
## and the hand's wished pose for the GRABBED occurrence, which pose should
## every group member be drawn at? Local, no network. PURE: no scene tree, so
## tests/motion_vectors.gd can pin it against the golden vectors to 1e-9.
##
## Replaces the old project_motion()/weighted_basis() of mates_tool.gd: the
## group's followers are in the metric (FOLLOWER_WEIGHT), the integrator is the
## screw exponential (not "add v, compose exp(w)"), and L is the response's
## chart.lever_arm, not a constant 100 mm.

const Se3 := preload("res://scripts/motion/se3.gd")

const FOLLOWER_WEIGHT := 1e-4 ## the backend's _FOLLOWER_WEIGHT: a contract constant, never on the wire
const GS_DROP_RELATIVE := 1e-6
const GS_DROP_ABSOLUTE := 1e-12

enum Integrator { SCREW, ADDITIVE }

var refs: Array = [] ## Array of poses: the anchor's members[].transform, grabbed first (= basis column order)
var rows: Array = [] ## Array of Array[float] (6k each): the response basis re-made orthonormal in the follower-weighted metric
var lever := 1.0 ## L, from the response chart.lever_arm
var follower_weight := FOLLOWER_WEIGHT
var scale: Array = [] ## per-coordinate metric scale s: <a,b> = sum (s a)(s b)


## Builds the model from an anchor response: runs the weighted Gram-Schmidt ONCE.
static func from_anchor(ref_poses: Array, basis: Array, lever_arm: float, follower: float = FOLLOWER_WEIGHT):
	var p = (load("res://scripts/motion/free_motion_projector.gd") as GDScript).new()
	p.refs = ref_poses
	p.lever = lever_arm
	p.follower_weight = follower
	p.scale = member_scale(ref_poses.size(), lever_arm, 0, follower)
	p.rows = weighted_gram_schmidt(basis, p.scale)
	return p


## Same model with other rows and/or refs (the hysteresis mixes an old basis with a new ref).
func with_rows(new_rows: Array, new_refs: Array = []):
	var p = (load("res://scripts/motion/free_motion_projector.gd") as GDScript).new()
	p.refs = new_refs if not new_refs.is_empty() else refs
	p.rows = new_rows
	p.lever = lever
	p.follower_weight = follower_weight
	p.scale = scale
	return p


func members() -> int:
	return refs.size()


## Number of free directions after re-orthonormalisation; 0 = the group cannot move.
func dim() -> int:
	return rows.size()


## Per-coordinate metric scale s (length 6·members): [1,1,1,L,L,L] for `grabbed`, times `follower` for the others.
static func member_scale(member_count: int, lever_arm: float, grabbed: int = 0, follower: float = FOLLOWER_WEIGHT) -> Array:
	var out := []
	for m in member_count:
		var f := 1.0 if m == grabbed else follower
		out.append_array([f, f, f, f * lever_arm, f * lever_arm, f * lever_arm])
	return out


static func weighted_dot(s: Array, a: Array, b: Array) -> float:
	var acc := 0.0
	for i in a.size():
		acc += (s[i] * a[i]) * (s[i] * b[i])
	return acc


static func weighted_norm(s: Array, a: Array) -> float:
	return sqrt(weighted_dot(s, a, a))


## Modified Gram-Schmidt with one re-orthogonalisation pass in metric `s` (spec §3). Dependent / zero rows are skipped.
static func weighted_gram_schmidt(input_rows: Array, s: Array) -> Array:
	var out: Array = []
	for row in input_rows:
		var v: Array = []
		for x in row:
			v.append(float(x))
		var n0 := weighted_norm(s, v)
		if n0 < GS_DROP_ABSOLUTE:
			continue
		for _pass in 2:
			for u in out:
				var c := weighted_dot(s, v, u)
				for i in v.size():
					v[i] -= c * u[i]
		var n := weighted_norm(s, v)
		if n < GS_DROP_RELATIVE * n0:
			continue
		var unit: Array = []
		for i in v.size():
			unit.append(v[i] / n)
		out.append(unit)
	return out


## Σ ⟨u_i, want⟩ u_i — the weighted least-squares fit of `want` onto the span of the orthonormal rows.
static func project_onto_rows(orthonormal_rows: Array, s: Array, want: Array) -> Array:
	var a: Array = []
	a.resize(want.size())
	a.fill(0.0)
	for u in orthonormal_rows:
		var c := weighted_dot(s, u, want)
		for i in a.size():
			a[i] += c * u[i]
	return a


## The wish vector: the grabbed block is screw_log(ref_0, wanted) (spec §4: the exact inverse of the screw integrator, so a wish
## that lies on the free manifold is reproduced exactly); zero elsewhere (followers have no wish). Integrator.ADDITIVE pairs
## with the v0 chart pose_delta (informational only).
func wish_vector(wanted: Dictionary, integrator: int = Integrator.SCREW) -> Array:
	var want: Array = []
	want.resize(6 * members())
	want.fill(0.0)
	var d := Se3.screw_log(refs[0], wanted) if integrator == Integrator.SCREW else Se3.pose_delta(wanted, refs[0])
	for i in 6:
		want[i] = d[i]
	return want


func project_twist(wanted: Dictionary, integrator: int = Integrator.SCREW) -> Array:
	return project_onto_rows(rows, scale, wish_vector(wanted, integrator))


## Poses for every member at the wished grabbed pose. dim() == 0 returns the refs (the group cannot move).
func project(wanted: Dictionary, integrator: int = Integrator.SCREW) -> Array:
	return integrate(project_twist(wanted, integrator), integrator)


func integrate(d: Array, integrator: int = Integrator.SCREW) -> Array:
	var out: Array = []
	for m in members():
		out.append(Se3.screw_exp(refs[m], d, 6 * m) if integrator == Integrator.SCREW else Se3.apply_delta(refs[m], d, 6 * m))
	return out


## ‖g ∘ log(ref_0, shown)‖, g = [1,1,1,L,L,L] — travel of the grabbed member since the anchor (spec §6).
func travel(shown_grabbed: Dictionary) -> float:
	return Se3.weighted_dist(shown_grabbed, refs[0], lever)
