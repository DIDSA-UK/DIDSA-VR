extends RefCounted
## Local nearest-point retraction — DIDSA-CAD docs/motion/projector-spec.md §4b (F1b). PURE maths, no scene tree.
##
## Given an anchor's `constraint_model` (the resolved mate geometry), solve the mates ON the client every frame: sequential
## nearest-point steps (trust region, analytic Jacobians) from the previous DISPLAYED poses towards the hand's wish, then a
## constraint-only polish. The result is used only if it converged and is close enough to the projector's answer
## (`frame()`), otherwise the projector's poses are shown — never worse than the projection.
##
## Mirrors client/lib/motion/local_retraction.dart line for line (and backend app/document/constraint_model.py); the SAME golden
## vectors (kind `local_retract`) gate all three. Every residual is zero ONLY on the branch its mate names (`alignment` /
## `side` / `perp`, +1 or -1 per mate in the model; absent or 0 reads as +1): docs/mate-solution-choice-plan.md. Poses are {"t": [x,y,z], "r": [9 floats row-major]} like se3.gd.
##
## COST: GDScript is much slower than Dart; the plan limits this port to small groups (LOCAL_MAX_MEMBERS = 3) until it has been
## measured on the headset (tests/bench_local_retraction.gd).

const Se3 := preload("res://scripts/motion/se3.gd")

const LOCAL_FOLLOWER := 1e-2 ## follower weight of the LOCAL solve (the projection metric keeps FOLLOWER_WEIGHT = 1e-4)
const ITERATIONS := 3
const ITERATIONS_MAX := 8 ## a far wish (hitch) gets ITERATIONS + ceil((d_wish - TRUST) / TRUST), capped here
const POLISH := 1
const TRUST := 6.0 ## weighted mm of wished displacement per iteration
const ROTATION_CAP := 0.6 ## rad per iteration, any member
const LAMBDA_ABS := 1e-9
const ACCEPT_RESIDUAL := 1e-6
const ACCEPT_DISTANCE := 0.5 ## of max(L, hand distance from the start pose)
const MAX_MEMBERS := 3 ## GDScript: small groups only until measured on the headset (Dart: 8)
const MAX_ROWS := 64
const MODEL_VERSION := 3 ## 3: an ANGLE about a hinge also fixes the swing sense (hinge_direction on a side); 2: branch-specific residuals (alignment / side / perp per mate)
const PAIR_MODEL_VERSION := 4 ## 4 = 3 plus an optional `pair` on a side: the second face of a Width / Symmetric mid-plane over two members (the backend emits 4 only then)
const COUPLER_MODEL_VERSION := 5 ## 5 = coupler mates (gear / rack_pinion / screw): rows on each side's MOVE from its `anchor` pose; `set_anchors` re-bases them at every accepted anchor
const LIMIT_MODEL_VERSION := 6 ## 6 = limit mates (limit_distance / limit_angle): an inequality row with `min` / `max`, held at the nearest bound only while violated (see `retract`); a superset of 3 to 5
const LIMIT_ROUNDS := 3 ## active-set rounds of one retraction
const LIMIT_TOL := 1e-6 ## mm / degrees a value may sit outside its range before the limit counts as violated
const DISTANCE_FLOOR := 1e-3 ## mm: divisor floor of the mm-scaled squared DISTANCE residuals (axis-axis, point-point)

const _TYPES := ["coincident", "concentric", "parallel", "angle", "distance"]
const _COUPLER_TYPES := ["gear", "rack_pinion", "screw"]
const _LIMIT_TYPES := ["limit_distance", "limit_angle"]

var members := 0
var member_ids: Array = []
var rows := 0
var n := 0 ## 6 * members
var _mates: Array = []
var _anchors: Array = [] ## version 5: the pose each member had at the latest accepted anchor (the base of a coupler's rows); empty = the exported ones
var _jac := true ## false = residual-only evaluation (no derivative arithmetic)
var _held := {} ## the limits `retract` is holding at a bound, {mate id: bound}: set by the latest `retract` (reset at its start), so `residual` / `residual_inf` right after it include the held rows


## Re-bases a coupler's rows on `poses` (one per member, the model's member order): call it with the members' poses of every accepted anchor.
func set_anchors(poses: Array) -> void:
	if poses.size() == members:
		_anchors = poses.duplicate()


## Whether the model holds a limit mate.
func has_limits() -> bool:
	for mate in _mates:
		if _LIMIT_TYPES.has(mate["type"]):
			return true
	return false


## The limits the latest `retract` held, {mate id: bound} (a copy).
func held_limits() -> Dictionary:
	return _held.duplicate()


## Whether the model holds a coupler mate (rows measured from anchors).
func has_coupler() -> bool:
	for mate in _mates:
		if _COUPLER_TYPES.has(mate["type"]):
			return true
	return false


## Parses an anchor's `constraint_model`. Returns null (= keep projecting) for no model, another version, an unknown mate type,
## a side missing geometry its residual needs, or a group the local solve is not meant for.
static func try_parse(json, max_members: int = MAX_MEMBERS):
	if not (json is Dictionary):
		return null
	var version := int(json.get("version", 0))
	if version != MODEL_VERSION and version != PAIR_MODEL_VERSION and version != COUPLER_MODEL_VERSION and version != LIMIT_MODEL_VERSION:
		return null
	var v6 := version == LIMIT_MODEL_VERSION
	var ids: Array = json.get("members", [])
	if ids.is_empty() or ids.size() > max_members:
		return null
	var model = (load("res://scripts/motion/local_retraction.gd") as GDScript).new()
	model.members = ids.size()
	model.member_ids = ids
	model.n = 6 * ids.size()
	for raw in json.get("mates", []):
		var type := str(raw["type"])
		var coupler := _COUPLER_TYPES.has(type)
		var limit := _LIMIT_TYPES.has(type)
		if not _TYPES.has(type) and not (coupler and (version == COUPLER_MODEL_VERSION or v6)) and not (limit and v6):
			return null
		if limit:
			if not (raw.get("id") is String) or (raw.get("min") == null and raw.get("max") == null):
				return null
		var a = _parse_side(raw["a"])
		var b = _parse_side(raw["b"])
		if a == null or b == null:
			return null
		if int(a["member"]) >= ids.size() or int(b["member"]) >= ids.size():
			return null
		for side in [a, b]:
			# `anchor` belongs to version 5 (and 6, the superset) only.
			if side["ar"] != null and version != COUPLER_MODEL_VERSION and not v6:
				return null
			if side["pair"] != null:
				# `pair` belongs to version 4 only; a version-3 model carrying one is malformed. Out-of-range member => null.
				if version == MODEL_VERSION or int(side["pair"]["member"]) >= ids.size():
					return null
		if coupler:
			# A coupler's two sides each need an axis, a member side its anchor, and a positive value.
			if raw.get("value") == null or float(raw["value"]) <= 0.0:
				return null
			for side in [a, b]:
				if not (side["geo"].has("axis_origin") and side["geo"].has("direction")):
					return null
				if int(side["member"]) >= 0 and side["ar"] == null:
					return null
		model._mates.append({
			"type": type,
			"k": _sign(raw.get("k")),
			"value": raw.get("value"),
			"allow_rotation": bool(raw.get("allow_rotation", true)),
			"alignment": _sign(raw.get("alignment")),
			"side": _sign(raw.get("side")),
			"perp": _sign(raw.get("perp")),
			"a": a,
			"b": b,
			"id": str(raw.get("id", "")),
			"min": raw.get("min"),
			"max": raw.get("max"),
		})
	# A dry evaluation at identity poses: tells the row count and fails on a missing field (a side lacking geometry).
	var identity: Array = []
	for i in ids.size():
		identity.append(Se3.make_pose([0.0, 0.0, 0.0], Se3.identity()))
	var r = model._evaluate(identity)
	if r == null or (r[0] as PackedFloat64Array).size() > MAX_ROWS:
		return null
	model.rows = (r[0] as PackedFloat64Array).size()
	for mate in model._mates:
		if _LIMIT_TYPES.has(mate["type"]):
			if model._limit_row(mate, identity) == null:
				return null # a side lacking the geometry the limit measures
			model.rows += 1 # (counted for the size cap; it adds a row only while held)
			if model.rows > MAX_ROWS:
				return null
	return model


## A side as {member, geo, fr, ft, pair}; `pair` is null or the same shape holding only `porigin` / `pnormal`. Returns null when
## a `pair` lacks its plane (a malformed v4 side).
static func _parse_side(j: Dictionary):
	var geo := {}
	for name in ["point", "axis_origin", "direction", "perp", "hinge_direction"]:
		if j.has(name) and j[name] != null:
			geo[name] = _floats(j[name])
	if j.has("plane") and j["plane"] != null:
		geo["porigin"] = _floats(j["plane"]["origin"])
		geo["pnormal"] = _floats(j["plane"]["normal"])
	var side := {"member": int(j["member"]), "geo": geo, "fr": null, "ft": null, "pair": null, "ar": null, "at": null}
	_parse_frozen(side, j)
	if j.has("anchor") and j["anchor"] != null:
		var ar: Array = []
		for row in j["anchor"]["r"]:
			ar.append_array(_floats(row))
		side["ar"] = ar
		side["at"] = _floats(j["anchor"]["t"])
	if j.has("pair") and j["pair"] != null:
		var pj: Dictionary = j["pair"]
		if not (pj.get("plane") is Dictionary) or not (pj["plane"].has("origin") and pj["plane"].has("normal")) or not pj.has("member"):
			return null
		var pgeo := {"porigin": _floats(pj["plane"]["origin"]), "pnormal": _floats(pj["plane"]["normal"])}
		var pair := {"member": int(pj["member"]), "geo": pgeo, "fr": null, "ft": null, "pair": null}
		_parse_frozen(pair, pj)
		side["pair"] = pair
	return side


static func _parse_frozen(side: Dictionary, j: Dictionary) -> void:
	if j.has("frozen") and j["frozen"] != null:
		var fr: Array = []
		for row in j["frozen"]["r"]:
			fr.append_array(_floats(row))
		side["fr"] = fr
		side["ft"] = _floats(j["frozen"]["t"])


static func _sign(v) -> float:
	return -1.0 if (v is float or v is int) and float(v) < 0.0 else 1.0


static func _floats(a) -> Array:
	var out: Array = []
	for x in a:
		out.append(float(x))
	return out


# --- world vectors with their derivative (3 x n, row-major) w.r.t. the 6k twist coordinates ---

func _world(side: Dictionary, poses: Array, name: String) -> Array:
	## [value, derivative]; the derivative is EMPTY when `_jac` is false (residual-only evaluation).
	var local: Array = side["geo"][name]
	var point := name == "point" or name == "axis_origin" or name == "porigin"
	var d := PackedFloat64Array()
	if _jac:
		d.resize(3 * n)
	var m: int = side["member"]
	var rm: Array
	var t: Array
	if m < 0:
		if side["fr"] == null:
			return [local.duplicate(), d]
		rm = side["fr"]
		t = side["ft"]
	else:
		rm = poses[m]["r"]
		t = poses[m]["t"]
	var w := Se3.mat_vec(rm, local)
	var v: Array = [w[0] + t[0], w[1] + t[1], w[2] + t[2]] if point else w
	if m >= 0 and _jac:
		var c0 := 6 * m
		if point:
			d[0 * n + c0] = 1.0
			d[1 * n + c0 + 1] = 1.0
			d[2 * n + c0 + 2] = 1.0
		# -skew(w)
		d[0 * n + c0 + 4] = w[2]
		d[0 * n + c0 + 5] = -w[1]
		d[1 * n + c0 + 3] = -w[2]
		d[1 * n + c0 + 5] = w[0]
		d[2 * n + c0 + 3] = w[1]
		d[2 * n + c0 + 4] = -w[0]
	return [v, d]


func _geo(side: Dictionary, poses: Array) -> Dictionary:
	var g := {}
	for name in side["geo"]:
		g[name] = _world(side, poses, name)
	var pair = side["pair"]
	if pair != null and g.has("porigin"):
		# Version 4: the plane midway between this face and the pair's (origin = average, normal = this face's own).
		var other := _world(pair, poses, "porigin")
		var o: Array = g["porigin"]
		var mid_v: Array = [(o[0][0] + other[0][0]) / 2.0, (o[0][1] + other[0][1]) / 2.0, (o[0][2] + other[0][2]) / 2.0]
		var mid_d := PackedFloat64Array()
		if _jac:
			var od: PackedFloat64Array = o[1]
			var pd: PackedFloat64Array = other[1]
			mid_d.resize(3 * n)
			for i in 3 * n:
				mid_d[i] = (od[i] + pd[i]) / 2.0
		g["porigin"] = [mid_v, mid_d]
		if g.has("point"):
			g["point"] = g["porigin"]
		g["pair_normal"] = _world(pair, poses, "pnormal")
	return g


func _sub(a: Array, b: Array) -> Array:
	var d := PackedFloat64Array()
	if _jac:
		d.resize(3 * n)
		var ad: PackedFloat64Array = a[1]
		var bd: PackedFloat64Array = b[1]
		for i in 3 * n:
			d[i] = ad[i] - bd[i]
	return [[a[0][0] - b[0][0], a[0][1] - b[0][1], a[0][2] - b[0][2]], d]


## Scalar a·b with its derivative (n).
func _dot(a: Array, b: Array) -> Array:
	var d := PackedFloat64Array()
	var av: Array = a[0]
	var bv: Array = b[0]
	if not _jac:
		return [av[0] * bv[0] + av[1] * bv[1] + av[2] * bv[2], d]
	d.resize(n)
	var ad: PackedFloat64Array = a[1]
	var bd: PackedFloat64Array = b[1]
	for c in n:
		d[c] = ad[c] * bv[0] + ad[n + c] * bv[1] + ad[2 * n + c] * bv[2] + bd[c] * av[0] + bd[n + c] * av[1] + bd[2 * n + c] * av[2]
	return [av[0] * bv[0] + av[1] * bv[1] + av[2] * bv[2], d]


func _cross(a: Array, b: Array) -> Array:
	var av: Array = a[0]
	var bv: Array = b[0]
	var d := PackedFloat64Array()
	if not _jac:
		return [Se3.cross(av, bv), d]
	var ad: PackedFloat64Array = a[1]
	var bd: PackedFloat64Array = b[1]
	d.resize(3 * n)
	for c in n:
		# Da x b + a x Db
		var d0: float = (ad[n + c] * bv[2] - ad[2 * n + c] * bv[1]) + (av[1] * bd[2 * n + c] - av[2] * bd[n + c])
		var d1: float = (ad[2 * n + c] * bv[0] - ad[c] * bv[2]) + (av[2] * bd[c] - av[0] * bd[2 * n + c])
		var d2: float = (ad[c] * bv[1] - ad[n + c] * bv[0]) + (av[0] * bd[n + c] - av[1] * bd[c])
		d[c] = d0
		d[n + c] = d1
		d[2 * n + c] = d2
	return [Se3.cross(av, bv), d]


func _scale(a: Array, c: float) -> Array:
	var d := PackedFloat64Array()
	if _jac:
		var ad: PackedFloat64Array = a[1]
		d.resize(3 * n)
		for i in 3 * n:
			d[i] = ad[i] * c
	return [[a[0][0] * c, a[0][1] * c, a[0][2] * c], d]


## `a - s b`: zero only when `a` points the way `s b` does (the alignment branch).
func _add_direction(res: PackedFloat64Array, jac: Array, a: Array, b: Array, s: float) -> void:
	_add_v(res, jac, _sub(a, _scale(b, s)))


func _unit(a: Array) -> Array:
	var av: Array = a[0]
	var nn := Se3.norm3(av)
	var u := [av[0] / nn, av[1] / nn, av[2] / nn]
	var d := PackedFloat64Array()
	if not _jac:
		return [u, d]
	var ad: PackedFloat64Array = a[1]
	d.resize(3 * n)
	for c in n:
		var p: float = u[0] * ad[c] + u[1] * ad[n + c] + u[2] * ad[2 * n + c]
		d[c] = (ad[c] - u[0] * p) / nn
		d[n + c] = (ad[n + c] - u[1] * p) / nn
		d[2 * n + c] = (ad[2 * n + c] - u[2] * p) / nn
	return [u, d]


## [residual PackedFloat64Array, jacobian Array of PackedFloat64Array rows (n each)] at `poses`; null if a field is missing.
# --- coupler rows (version 5, projector-spec section 4b "gear, rack_pinion, screw") ---

func _base_axis(side: Dictionary) -> Array:
	## The side's axis in the world at its base pose (a constant).
	var u := _unit_plain(side["geo"]["direction"])
	if int(side["member"]) >= 0:
		var r0: Array = _anchors[side["member"]]["r"] if not _anchors.is_empty() else side["ar"]
		return Se3.mat_vec(r0, u)
	return Se3.mat_vec(side["fr"], u) if side["fr"] != null else u


static func _unit_plain(a: Array) -> Array:
	var l := sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
	return [a[0] / l, a[1] / l, a[2] / l]


func _motion(side: Dictionary, poses: Array, axis: Array) -> Array:
	## [turn, d turn, travel, d travel] of a member side about / along the world unit `axis` since its anchor pose.
	var zero := PackedFloat64Array()
	zero.resize(n)
	var m: int = side["member"]
	if m < 0:
		return [0.0, zero, 0.0, zero.duplicate()]
	var r0: Array
	var t0: Array
	if not _anchors.is_empty():
		r0 = _anchors[m]["r"]
		t0 = _anchors[m]["t"]
	else:
		r0 = side["ar"]
		t0 = side["at"]
	var r: Array = poses[m]["r"]
	var t: Array = poses[m]["t"]
	var q := Se3.mat_mul(r, Se3.mat_transpose(r0))
	# unit quaternion of q, w >= 0 (same branch as the backend)
	var w: float
	var v: Array
	var tr: float = q[0] + q[4] + q[8]
	if tr > 0.0:
		var sc := sqrt(tr + 1.0) * 2.0
		w = 0.25 * sc
		v = [(q[7] - q[5]) / sc, (q[2] - q[6]) / sc, (q[3] - q[1]) / sc]
	else:
		var i := 0
		if q[4] > q[0]:
			i = 1
		if q[8] > q[4 * i]:
			i = 2
		var j := (i + 1) % 3
		var k := (i + 2) % 3
		var sc := sqrt(q[4 * i] - q[4 * j] - q[4 * k] + 1.0) * 2.0
		v = [0.0, 0.0, 0.0]
		v[i] = 0.25 * sc
		v[j] = (q[3 * j + i] + q[3 * i + j]) / sc
		v[k] = (q[3 * k + i] + q[3 * i + k]) / sc
		w = (q[3 * k + j] - q[3 * j + k]) / sc
	if w < 0.0:
		w = -w
		v = [-v[0], -v[1], -v[2]]
	var a: float = v[0] * axis[0] + v[1] * axis[1] + v[2] * axis[2]
	var vxa := Se3.cross(v, axis)
	var den := w * w + a * a
	var gturn := zero.duplicate()
	for i in 3:
		gturn[6 * m + 3 + i] = (w * w * axis[i] + w * vxa[i] + a * v[i]) / den
	var p: Array = side["geo"]["axis_origin"]
	var rp := Se3.mat_vec(r, p)
	var r0p := Se3.mat_vec(r0, p)
	var travel: float = ((rp[0] + t[0]) - (r0p[0] + t0[0])) * axis[0] \
		+ ((rp[1] + t[1]) - (r0p[1] + t0[1])) * axis[1] \
		+ ((rp[2] + t[2]) - (r0p[2] + t0[2])) * axis[2]
	var gtravel := zero.duplicate()
	var qxa := Se3.cross(rp, axis)
	for i in 3:
		gtravel[6 * m + i] = axis[i]
		gtravel[6 * m + 3 + i] = qxa[i]
	return [2.0 * atan2(a, w), gturn, travel, gtravel]


func _coupler_row(mate: Dictionary, poses: Array) -> Array:
	## The one row of a coupler mate: [value, gradient].
	var axis_a := _base_axis(mate["a"])
	var value: float = float(mate["value"])
	var k: float = mate["k"]
	var a: Array
	var b: Array
	var out := PackedFloat64Array()
	out.resize(n)
	match mate["type"]:
		"gear":
			a = _motion(mate["a"], poses, axis_a)
			b = _motion(mate["b"], poses, _base_axis(mate["b"]))
			for i in n:
				out[i] = b[1][i] - k * value * a[1][i]
			return [b[0] - k * value * a[0], out]
		"rack_pinion":
			a = _motion(mate["a"], poses, axis_a)
			b = _motion(mate["b"], poses, _base_axis(mate["b"]))
			var c := k * value / TAU
			for i in n:
				out[i] = b[3][i] - c * a[1][i]
			return [b[2] - c * a[0], out]
	# screw: everything about / along the screw's (A's) axis
	a = _motion(mate["a"], poses, axis_a)
	b = _motion(mate["b"], poses, axis_a)
	var cs := k * value / TAU
	for i in n:
		out[i] = (b[3][i] - a[3][i]) - cs * (b[1][i] - a[1][i])
	return [(b[2] - a[2]) - cs * (b[0] - a[0]), out]


## `[value, gradient]` of a limit mate's measured value (mm for limit_distance, `(P_a - P_b) . N`, N = B's plane normal else A's;
## degrees for limit_angle, `atan2((a x b) . h, a . b)`, h the hinge); the gradient is per unit of that value. Null if a side lacks geometry.
func _limit_row(mate: Dictionary, poses: Array):
	var d := _geo(mate["a"], poses)
	var f := _geo(mate["b"], poses)
	if mate["type"] == "limit_distance":
		var origin_a = d["porigin"] if d.has("porigin") else d.get("point")
		var origin_b = f["porigin"] if f.has("porigin") else f.get("point")
		var normal = f["pnormal"] if f.has("pnormal") else d.get("pnormal")
		if origin_a == null or origin_b == null or normal == null:
			return null
		return _dot(_sub(origin_a, origin_b), _unit(normal))
	var hinge = d["hinge_direction"] if d.has("hinge_direction") else f.get("hinge_direction")
	if hinge == null or not (d.has("direction") and f.has("direction")):
		return null
	var na := _unit(d["direction"])
	var nb := _unit(f["direction"])
	var sn := _dot(_cross(na, nb), _unit(hinge))
	var cs := _dot(na, nb)
	var den: float = sn[0] * sn[0] + cs[0] * cs[0]
	var deg := 180.0 / PI
	var grad := PackedFloat64Array()
	if _jac:
		grad.resize(n)
		var sd: PackedFloat64Array = sn[1]
		var cd: PackedFloat64Array = cs[1]
		for c in n:
			grad[c] = (cs[0] * sd[c] - sn[0] * cd[c]) / den * deg
	return [rad_to_deg(atan2(sn[0], cs[0])), grad]


## The measured value of a limit mate at `poses` (the same number as `_limit_row`'s first element) without building the whole side geometry or any
## derivative: only the three vectors the value needs. The per-frame stop of a drag evaluates this a dozen times a frame.
func _limit_value(mate: Dictionary, poses: Array) -> float:
	var a: Dictionary = mate["a"]
	var b: Dictionary = mate["b"]
	if mate["type"] == "limit_distance":
		var geo_a: Dictionary = a["geo"]
		var geo_b: Dictionary = b["geo"]
		var pa: Array = _world(a, poses, "porigin" if geo_a.has("porigin") else "point")[0]
		var pb: Array = _world(b, poses, "porigin" if geo_b.has("porigin") else "point")[0]
		var normal: Array = _world(b, poses, "pnormal")[0] if geo_b.has("pnormal") else _world(a, poses, "pnormal")[0]
		var nn := Se3.norm3(normal)
		return ((pa[0] - pb[0]) * normal[0] + (pa[1] - pb[1]) * normal[1] + (pa[2] - pb[2]) * normal[2]) / nn
	var ga: Dictionary = a["geo"]
	var hinge_side: Dictionary = a if ga.has("hinge_direction") else b
	var da: Array = _world(a, poses, "direction")[0]
	var db: Array = _world(b, poses, "direction")[0]
	var h: Array = _world(hinge_side, poses, "hinge_direction")[0]
	var x: Array = Se3.cross(da, db)
	var hn := Se3.norm3(h)
	var sine: float = (x[0] * h[0] + x[1] * h[1] + x[2] * h[2]) / (hn * Se3.norm3(da) * Se3.norm3(db))
	var cosine: float = (da[0] * db[0] + da[1] * db[1] + da[2] * db[2]) / (Se3.norm3(da) * Se3.norm3(db))
	return rad_to_deg(atan2(sine, cosine))


## The indices of the members a limit mate measures (a limit's value reads only those members' poses).
func limit_member_indices() -> Array:
	var out: Array = []
	for mate in _mates:
		if _LIMIT_TYPES.has(mate["type"]):
			for side in [mate["a"], mate["b"]]:
				var m: int = side["member"]
				if m >= 0 and not out.has(m):
					out.append(m)
	return out


## Whether every limit mate's value at `poses` lies within its range (no solve, no derivatives): the cheap check a drag uses to stop at a limit.
func limits_in_range(poses: Array) -> bool:
	var was := _jac
	_jac = false
	var ok := true
	for mate in _mates:
		if not _LIMIT_TYPES.has(mate["type"]):
			continue
		var value: float = _limit_value(mate, poses)
		if (mate["max"] != null and value > float(mate["max"]) + LIMIT_TOL) or (mate["min"] != null and value < float(mate["min"]) - LIMIT_TOL):
			ok = false
			break
	_jac = was
	return ok


## {mate id: bound} of the limits not yet held whose range `poses` leave.
func _violated(poses: Array) -> Dictionary:
	var out := {}
	var was := _jac
	_jac = false
	for mate in _mates:
		if not _LIMIT_TYPES.has(mate["type"]) or _held.has(mate["id"]):
			continue
		var value: float = _limit_row(mate, poses)[0]
		if mate["max"] != null and value > float(mate["max"]) + LIMIT_TOL:
			out[mate["id"]] = float(mate["max"])
		elif mate["min"] != null and value < float(mate["min"]) - LIMIT_TOL:
			out[mate["id"]] = float(mate["min"])
	_jac = was
	return out


func _evaluate(poses: Array):
	var res := PackedFloat64Array()
	var jac: Array = []
	for mate in _mates:
		if _LIMIT_TYPES.has(mate["type"]):
			if _held.has(mate["id"]):
				var lr = _limit_row(mate, poses)
				var unit := PI / 180.0 if mate["type"] == "limit_angle" else 1.0
				res.append((float(lr[0]) - float(_held[mate["id"]])) * unit)
				if _jac:
					var g := PackedFloat64Array()
					g.resize(n)
					var lg: PackedFloat64Array = lr[1]
					for c in n:
						g[c] = lg[c] * unit
					jac.append(g)
			continue
		if _COUPLER_TYPES.has(mate["type"]):
			var cr := _coupler_row(mate, poses)
			res.append(cr[0])
			if _jac:
				jac.append(cr[1])
			continue
		var d := _geo(mate["a"], poses)
		var f := _geo(mate["b"], poses)
		var type: String = mate["type"]
		var s: float = mate["alignment"]
		if type == "coincident":
			if d.has("porigin") and f.has("porigin"):
				_add_s(res, jac, _dot(_sub(d["porigin"], f["porigin"]), f["pnormal"]))
				_add_direction(res, jac, d["pnormal"], f["pnormal"], s)
			elif d.has("porigin"):
				if not f.has("point"):
					return null
				_add_s(res, jac, _dot(_sub(f["point"], d["porigin"]), d["pnormal"]))
			elif f.has("porigin"):
				if not d.has("point"):
					return null
				_add_s(res, jac, _dot(_sub(d["point"], f["porigin"]), f["pnormal"]))
			else:
				if not (d.has("point") and f.has("point")):
					return null
				_add_v(res, jac, _sub(d["point"], f["point"]))
		elif type == "concentric":
			if not (d.has("direction") and f.has("direction") and d.has("axis_origin") and f.has("axis_origin")):
				return null
			_add_direction(res, jac, d["direction"], f["direction"], s)
			_add_v(res, jac, _cross(_sub(d["axis_origin"], f["axis_origin"]), f["direction"]))
			if not mate["allow_rotation"] and d.has("perp") and f.has("perp"):
				_add_direction(res, jac, d["perp"], f["perp"], mate["perp"])
		elif type == "parallel":
			if not (d.has("direction") and f.has("direction")):
				return null
			_add_direction(res, jac, d["direction"], f["direction"], s)
		elif type == "angle":
			if not (d.has("direction") and f.has("direction")) or mate["value"] == null:
				return null
			var target := fposmod(absf(float(mate["value"])), 360.0)
			target = minf(target, 360.0 - target)
			var nd := _unit(d["direction"])
			var nf := _unit(f["direction"])
			var dd := _dot(nd, nf)
			res.append(dd[0] - cos(deg_to_rad(target)))
			if _jac:
				jac.append(dd[1])
			var hinge = d["hinge_direction"] if d.has("hinge_direction") else (f["hinge_direction"] if f.has("hinge_direction") else null)
			if hinge != null and sin(deg_to_rad(target)) >= 1e-6:
				# About a hinge: the sine of the signed swing is +-sin(target) (`alignment`) - zero only on the named way.
				var sw := _dot(_cross(nd, nf), _unit(hinge))
				res.append(sw[0] - s * sin(deg_to_rad(target)))
				if _jac:
					jac.append(sw[1])
		elif type == "distance":
			if mate["value"] == null:
				return null
			var dist := absf(float(mate["value"]))
			var signed_target: float = float(mate["side"]) * dist
			if d.has("porigin") and f.has("porigin"):
				_add_signed(res, jac, _dot(_sub(d["porigin"], f["porigin"]), f["pnormal"]), signed_target)
				_add_direction(res, jac, d["pnormal"], f["pnormal"], s)
			elif d.has("porigin"):
				_add_signed(res, jac, _dot(_sub(f["point"], d["porigin"]), d["pnormal"]), signed_target)
			elif f.has("porigin"):
				_add_signed(res, jac, _dot(_sub(d["point"], f["porigin"]), f["pnormal"]), signed_target)
			elif d.has("axis_origin") and f.has("axis_origin"):
				var p := _cross(_sub(d["axis_origin"], f["axis_origin"]), f["direction"])
				_add_scaled(res, jac, _dot(p, p), dist)
				_add_direction(res, jac, d["direction"], f["direction"], s)
			else:
				var off := _sub(d["point"], f["point"])
				_add_scaled(res, jac, _dot(off, off), dist)
		for g in [d, f]:
			# A pair's two faces stay parallel: cross of the unit normals (3 rows, rank 2); side a before side b.
			if g.has("pair_normal"):
				_add_v(res, jac, _cross(_unit(g["pnormal"]), _unit(g["pair_normal"])))
	return [res, jac]


func _add_s(res: PackedFloat64Array, jac: Array, s: Array) -> void:
	res.append(s[0])
	if _jac:
		jac.append(s[1])


## A signed separation against its target on the chosen side, `sep - side * d`: linear, one Newton step from either side.
func _add_signed(res: PackedFloat64Array, jac: Array, sg: Array, target: float) -> void:
	res.append(sg[0] - target)
	if _jac:
		jac.append(sg[1])


## A squared form scaled to mm, `(x^2 - d^2) / (2 max(d, floor))`.
func _add_scaled(res: PackedFloat64Array, jac: Array, sq: Array, dist: float) -> void:
	var scale := 2.0 * maxf(dist, DISTANCE_FLOOR)
	res.append((sq[0] - dist * dist) / scale)
	if not _jac:
		return
	var d: PackedFloat64Array = sq[1]
	var out := PackedFloat64Array()
	out.resize(n)
	for c in n:
		out[c] = d[c] / scale
	jac.append(out)


func _add_v(res: PackedFloat64Array, jac: Array, v: Array) -> void:
	for i in 3:
		res.append(v[0][i])
	if _jac:
		var d: PackedFloat64Array = v[1]
		for i in 3:
			jac.append(d.slice(i * n, (i + 1) * n))


## Stacked mate residual at `poses`.
func residual(poses: Array) -> PackedFloat64Array:
	_jac = false
	var r = _evaluate(poses)[0]
	_jac = true
	return r


func residual_inf(poses: Array) -> float:
	var m := 0.0
	for x in residual(poses):
		m = maxf(m, absf(x))
	return m


## Analytic Jacobian rows (rows x 6·members), same chart as the basis.
func jacobian(poses: Array) -> Array:
	return _evaluate(poses)[1]


# --- retraction ---

func _step(cur: Array, dx: PackedFloat64Array) -> Array:
	var out: Array = []
	for i in members:
		out.append(Se3.apply_delta(cur[i], dx, 6 * i))
	return out


func _cap_rotation(dx: PackedFloat64Array) -> PackedFloat64Array:
	var rot := 0.0
	for i in members:
		rot = maxf(rot, sqrt(dx[6 * i + 3] * dx[6 * i + 3] + dx[6 * i + 4] * dx[6 * i + 4] + dx[6 * i + 5] * dx[6 * i + 5]))
	if rot <= ROTATION_CAP:
		return dx
	var f := ROTATION_CAP / rot
	var out := PackedFloat64Array()
	out.resize(n)
	for i in n:
		out[i] = dx[i] * f
	return out


## Aᵀ (A·Aᵀ + λ I)⁻¹ rhs with A = J / w (n-vector). `a` = rows of A.
func _correction(a: Array, rhs: PackedFloat64Array) -> PackedFloat64Array:
	var m := a.size()
	var mat := PackedFloat64Array()
	mat.resize(m * m)
	for i in m:
		var ai: PackedFloat64Array = a[i]
		for j in range(i, m):
			var aj: PackedFloat64Array = a[j]
			var s := 0.0
			for c in n:
				s += ai[c] * aj[c]
			mat[i * m + j] = s
			mat[j * m + i] = s
		mat[i * m + i] += LAMBDA_ABS
	var z := _solve(mat, rhs.duplicate(), m)
	var out := PackedFloat64Array()
	out.resize(n)
	for i in m:
		var ai: PackedFloat64Array = a[i]
		var zi := z[i]
		for c in n:
			out[c] += ai[c] * zi
	return out


## Gaussian elimination with partial pivoting; `m` (k x k row-major) and `b` are consumed.
static func _solve(m: PackedFloat64Array, b: PackedFloat64Array, k: int) -> PackedFloat64Array:
	for col in k:
		var piv := col
		var best := absf(m[col * k + col])
		for r in range(col + 1, k):
			var v := absf(m[r * k + col])
			if v > best:
				best = v
				piv = r
		if piv != col:
			for c in k:
				var tmp := m[col * k + c]
				m[col * k + c] = m[piv * k + c]
				m[piv * k + c] = tmp
			var tb := b[col]
			b[col] = b[piv]
			b[piv] = tb
		var d := m[col * k + col]
		for r in range(col + 1, k):
			var f := m[r * k + col] / d
			if f == 0.0:
				continue
			for c in range(col, k):
				m[r * k + c] -= f * m[col * k + c]
			b[r] -= f * b[col]
	var x := PackedFloat64Array()
	x.resize(k)
	for r in range(k - 1, -1, -1):
		var s := b[r]
		for c in range(r + 1, k):
			s -= m[r * k + c] * x[c]
		x[r] = s / m[r * k + r]
	return x


func _scaled_rows(jac: Array, w: Array) -> Array:
	var a: Array = []
	for row in jac:
		var out := PackedFloat64Array()
		out.resize(n)
		for c in n:
			out[c] = row[c] / w[c]
		a.append(out)
	return a


## Sequential nearest-point retraction (spec §4b): `iterations` trust-region steps towards `wishes`, then `polish`
## constraint-only steps. `w` = per-coordinate metric (see local_scale).
##
## With limit mates (version 6) it is the active-set rounds: retract with none held, hold every limit the answer leaves at its nearest bound (an
## equality row) and retract again from the SAME start and wish, at most LIMIT_ROUNDS times. Nothing is carried to the next call (a limit is released
## the moment the wish no longer pushes past it); `held_limits()` says which were held.
func retract(poses: Array, wishes: Array, w: Array, iterations: int = ITERATIONS, polish: int = POLISH) -> Array:
	_held = {}
	var got := _retract_once(poses, wishes, w, iterations, polish)
	if not has_limits():
		return got
	for _round in LIMIT_ROUNDS:
		var violated := _violated(got)
		if violated.is_empty():
			break
		_held.merge(violated, true)
		got = _retract_once(poses, wishes, w, iterations, polish)
	return got


func _retract_once(poses: Array, wishes: Array, w: Array, iterations: int, polish: int) -> Array:
	var cur: Array = poses.duplicate()
	for _it in iterations:
		var ev = _evaluate(cur)
		var r: PackedFloat64Array = ev[0]
		var g := PackedFloat64Array()
		for i in members:
			g.append_array(PackedFloat64Array(Se3.pose_delta(wishes[i], cur[i])))
		var a := _scaled_rows(ev[1], w)
		var y0 := PackedFloat64Array()
		y0.resize(n)
		var n0 := 0.0
		for c in n:
			y0[c] = w[c] * g[c]
			n0 += y0[c] * y0[c]
		n0 = sqrt(n0)
		if n0 > TRUST:
			var f := TRUST / n0
			for c in n:
				y0[c] *= f
		var y := y0
		if r.size() > 0:
			var rhs := PackedFloat64Array()
			rhs.resize(r.size())
			for i in r.size():
				var s := 0.0
				var ai: PackedFloat64Array = a[i]
				for c in n:
					s += ai[c] * y0[c]
				rhs[i] = s + r[i]
			var corr := _correction(a, rhs)
			y = PackedFloat64Array()
			y.resize(n)
			for c in n:
				y[c] = y0[c] - corr[c]
		var dx := PackedFloat64Array()
		dx.resize(n)
		for c in n:
			dx[c] = y[c] / w[c]
		cur = _step(cur, _cap_rotation(dx))
	for _it in polish:
		var ev2 = _evaluate(cur)
		var r2: PackedFloat64Array = ev2[0]
		if r2.is_empty():
			break
		var big := 0.0
		for x in r2:
			big = maxf(big, absf(x))
		if big < 1e-12:
			break
		var corr2 := _correction(_scaled_rows(ev2[1], w), r2)
		var dx2 := PackedFloat64Array()
		dx2.resize(n)
		for c in n:
			dx2[c] = -corr2[c] / w[c]
		cur = _step(cur, _cap_rotation(dx2))
	return cur


## One frame: retract from `poses` (the previous displayed poses) towards `wishes` (grabbed: the hand; followers: their previous
## displayed poses) in the local metric; accept only a converged result within ACCEPT_DISTANCE · max(L, hand distance) of the
## projector's grabbed pose (`fallback` = the projector's poses for the same wish). Returns a Dictionary:
## {accepted, poses (to show), local_poses, residual_inf, fallback_distance}.
func frame(poses: Array, wishes: Array, fallback: Array, lever: float) -> Dictionary:
	var w := local_scale(members, lever)
	var wish_step := Se3.weighted_dist(wishes[0], poses[0], lever)
	var got := retract(poses, wishes, w, local_iterations(wish_step))
	var res := residual_inf(got)
	var dist := Se3.weighted_dist(got[0], fallback[0], lever)
	# A held limit is a stop the projector (the fallback) knows nothing of - it would show the part going on through it - so the distance guard
	# cannot judge the answer: a converged result with a limit held is accepted as it is.
	var ok := res <= ACCEPT_RESIDUAL and (not _held.is_empty() or dist <= ACCEPT_DISTANCE * maxf(lever, wish_step))
	return {
		"accepted": ok,
		"poses": got if ok else fallback,
		"local_poses": got,
		"residual_inf": res,
		"fallback_distance": dist,
	}


## Iterations for a frame whose hand wish is `wish_step` (weighted mm) from the start pose.
static func local_iterations(wish_step: float) -> int:
	return mini(ITERATIONS_MAX, maxi(ITERATIONS, ITERATIONS + int(ceil((wish_step - TRUST) / TRUST))))


## The local metric: grabbed [1,1,1,L,L,L], followers × LOCAL_FOLLOWER; the grabbed member is index 0.
static func local_scale(member_count: int, lever: float) -> Array:
	var out: Array = []
	for m in member_count:
		var f := 1.0 if m == 0 else LOCAL_FOLLOWER
		out.append_array([f, f, f, f * lever, f * lever, f * lever])
	return out
