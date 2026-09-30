extends RefCounted
## SE(3) chart for the free-motion projector — DIDSA-CAD's
## docs/motion/projector-spec.md §2 and §5. PURE maths, no scene tree.
##
## Why not Transform3D/Vector3/Basis: they are 32-bit floats in a standard Godot
## build, and the golden vectors (docs/motion/vectors.json) are pinned to 1e-9.
## GDScript's own `float` is a 64-bit double, so every pose in here is
## {"t": [x, y, z], "r": [9 floats, row-major]} of plain floats, and only
## `from_transform3d` / `to_transform3d` touch Godot's own types.
##
## Conventions (the backend's apply_delta chart): a twist [vx vy vz wx wy wz]
## has v = displacement of the occurrence ORIGIN and w = a rotation vector
## (rad) composed on the LEFT, R' = exp(w)·R.

const SERIES_SWITCH := 1e-4 ## below this angle the Rodrigues / screw coefficients use their Taylor series
const NEAR_PI := 1e-3 ## within this of pi the rotation-vector axis comes from (R + I)/2


# --- 3-vectors / 3x3 matrices (row-major, 9 floats) ---

static func identity() -> Array:
	return [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]


static func mat_mul(a: Array, b: Array) -> Array:
	var out := []
	out.resize(9)
	for r in 3:
		for c in 3:
			out[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]
	return out


static func mat_transpose(m: Array) -> Array:
	return [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]


static func mat_vec(m: Array, v: Array) -> Array:
	return [
		m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
		m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
		m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
	]


static func cross(a: Array, b: Array) -> Array:
	return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


static func norm3(a: Array) -> float:
	return sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


## Cross-product matrix: skew(w)·x == w × x. (The prototype's third row was wrong — this is the right one.)
static func skew(w: Array) -> Array:
	return [0.0, -w[2], w[1], w[2], 0.0, -w[0], -w[1], w[0], 0.0]


static func _lin(i_scale: float, a: float, k: Array, b: float, k2: Array) -> Array:
	var out := []
	out.resize(9)
	var eye := identity()
	for i in 9:
		out[i] = i_scale * eye[i] + a * k[i] + b * k2[i]
	return out


## Rodrigues: exp(skew(w)).
static func rot_from_rotvec(w: Array) -> Array:
	var th := norm3(w)
	var k := skew(w)
	var a: float
	var b: float
	if th < SERIES_SWITCH:
		a = 1.0 - th * th / 6.0
		b = 0.5 - th * th / 24.0
	else:
		a = sin(th) / th
		b = (1.0 - cos(th)) / (th * th)
	return _lin(1.0, a, k, b, mat_mul(k, k))


## Inverse of rot_from_rotvec (angles in [0, pi]): atan2-based (exact at small angles), axis from the symmetric part near pi (spec §5).
static func rotvec_from_rot(r: Array) -> Array:
	var v := [(r[7] - r[5]) / 2.0, (r[2] - r[6]) / 2.0, (r[3] - r[1]) / 2.0]
	var s := norm3(v)
	var c: float = (r[0] + r[4] + r[8] - 1.0) / 2.0
	var th := atan2(s, c)
	if th < SERIES_SWITCH:
		var f := 1.0 + th * th / 6.0
		return [v[0] * f, v[1] * f, v[2] * f]
	if PI - th < NEAR_PI:
		# sin(th) ~ 0: (R + I)/2 = a·aᵀ; take the column of the largest diagonal entry, sign from v
		var j := 0
		if r[4] > r[j * 4]:
			j = 1
		if r[8] > r[j * 4]:
			j = 2
		var col := []
		for i in 3:
			col.append((r[i * 3 + j] + (1.0 if i == j else 0.0)) / 2.0)
		var n := norm3(col)
		var u := [col[0] / n, col[1] / n, col[2] / n]
		var sign := 1.0 if (u[0] * v[0] + u[1] * v[1] + u[2] * v[2]) >= 0.0 else -1.0
		return [u[0] * th * sign, u[1] * th * sign, u[2] * th * sign]
	var f2 := th / s
	return [v[0] * f2, v[1] * f2, v[2] * f2]


## Rotation about `axis` (normalised here; zero axis or zero angle = identity) by `degrees` — the wire rotation_axis + rotation_angle_degrees.
static func rot_axis_angle(axis: Array, degrees: float) -> Array:
	var n := norm3(axis)
	if n < 1e-12 or absf(degrees) < 1e-15:
		return identity()
	var rad := deg_to_rad(degrees)
	return rot_from_rotvec([axis[0] / n * rad, axis[1] / n * rad, axis[2] / n * rad])


# --- poses ---

static func make_pose(t: Array, r: Array) -> Dictionary:
	return {"t": t, "r": r}


## From the wire form (RigidTransform JSON: translation, rotation_axis, rotation_angle_degrees).
static func pose_from_json(j: Dictionary) -> Dictionary:
	var t: Array = j.get("translation", [0.0, 0.0, 0.0])
	var axis: Array = j.get("rotation_axis", [0.0, 0.0, 1.0])
	return make_pose([float(t[0]), float(t[1]), float(t[2])], rot_axis_angle([float(axis[0]), float(axis[1]), float(axis[2])], float(j.get("rotation_angle_degrees", 0.0))))


## Wire form; identity rotation reports axis [0, 0, 1].
static func pose_to_json(p: Dictionary) -> Dictionary:
	var v := rotvec_from_rot(p["r"])
	var th := norm3(v)
	var axis := [0.0, 0.0, 1.0]
	if th > 1e-12:
		axis = [v[0] / th, v[1] / th, v[2] / th]
	return {"translation": [p["t"][0], p["t"][1], p["t"][2]], "rotation_axis": axis, "rotation_angle_degrees": rad_to_deg(th)}


## The vectors' output form: translation + row-major 3x3 "rotation".
static func pose_from_out(j: Dictionary) -> Dictionary:
	var t: Array = j["translation"]
	var r: Array = j["rotation"]
	return make_pose([float(t[0]), float(t[1]), float(t[2])], r.map(func(x): return float(x)))


## Godot's Transform3D is float32: only the EDGE of the projector touches it.
static func from_transform3d(t: Transform3D) -> Dictionary:
	var b := t.basis.orthonormalized()
	return make_pose(
		[t.origin.x, t.origin.y, t.origin.z],
		[b.x.x, b.y.x, b.z.x, b.x.y, b.y.y, b.z.y, b.x.z, b.y.z, b.z.z])


static func to_transform3d(p: Dictionary) -> Transform3D:
	var r: Array = p["r"]
	var t: Array = p["t"]
	return Transform3D(
		Basis(Vector3(r[0], r[3], r[6]), Vector3(r[1], r[4], r[7]), Vector3(r[2], r[5], r[8])),
		Vector3(t[0], t[1], t[2]))


## [t_new − t_old, rotvec(R_new·R_oldᵀ)] — the inverse of apply_delta.
static func pose_delta(newer: Dictionary, older: Dictionary) -> Array:
	var w := rotvec_from_rot(mat_mul(newer["r"], mat_transpose(older["r"])))
	return [newer["t"][0] - older["t"][0], newer["t"][1] - older["t"][1], newer["t"][2] - older["t"][2], w[0], w[1], w[2]]


## (t + v, exp(w)·R): the additive integration the backend's chart defines. `d` = 6 floats from `offset`.
static func apply_delta(base: Dictionary, d: Array, offset: int = 0) -> Dictionary:
	return make_pose(
		[base["t"][0] + d[offset], base["t"][1] + d[offset + 1], base["t"][2] + d[offset + 2]],
		mat_mul(rot_from_rotvec([d[offset + 3], d[offset + 4], d[offset + 5]]), base["r"]))


## Integrates the twist d[offset..offset+6] as a constant spatial screw (spec §5): R' = E·R, t' = E·t + V·(v − w × t). Exact for group orbits.
static func screw_exp(base: Dictionary, d: Array, offset: int = 0) -> Dictionary:
	var v := [d[offset], d[offset + 1], d[offset + 2]]
	var w := [d[offset + 3], d[offset + 4], d[offset + 5]]
	var th := norm3(w)
	var k := skew(w)
	var a: float
	var b: float
	if th < SERIES_SWITCH:
		a = 0.5 - th * th / 24.0
		b = 1.0 / 6.0 - th * th / 120.0
	else:
		a = (1.0 - cos(th)) / (th * th)
		b = (th - sin(th)) / (th * th * th)
	var vm := _lin(1.0, a, k, b, mat_mul(k, k))
	var e := rot_from_rotvec(w)
	var wxt := cross(w, base["t"])
	var et := mat_vec(e, base["t"])
	var vt := mat_vec(vm, [v[0] - wxt[0], v[1] - wxt[1], v[2] - wxt[2]])
	return make_pose([et[0] + vt[0], et[1] + vt[1], et[2] + vt[2]], mat_mul(e, base["r"]))


## ‖[1,1,1,L,L,L] ∘ log(a, b)‖ — the weighted distance between two poses (spec §7, and §6's `travel`).
static func weighted_dist(a: Dictionary, b: Dictionary, lever: float) -> float:
	var d := pose_delta(a, b)
	return sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2] + pow(d[3] * lever, 2) + pow(d[4] * lever, 2) + pow(d[5] * lever, 2))
