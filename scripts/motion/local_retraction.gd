extends RefCounted
## Local nearest-point retraction — DIDSA-CAD docs/motion/projector-spec.md §4b (F1b). PURE maths, no scene tree.
##
## Given an anchor's `constraint_model` (the resolved mate geometry), solve the mates ON the client every frame: sequential
## nearest-point steps (trust region, analytic Jacobians) from the previous DISPLAYED poses towards the hand's wish, then a
## constraint-only polish. The result is used only if it converged and is close enough to the projector's answer
## (`frame()`), otherwise the projector's poses are shown — never worse than the projection.
##
## Mirrors client/lib/motion/local_retraction.dart line for line (and backend app/document/constraint_model.py); the SAME golden
## vectors (kind `local_retract`) gate all three. Poses are {"t": [x,y,z], "r": [9 floats row-major]} like se3.gd.
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
const MODEL_VERSION := 1

const _TYPES := ["coincident", "concentric", "parallel", "angle", "distance"]

var members := 0
var member_ids: Array = []
var rows := 0
var n := 0 ## 6 * members
var _mates: Array = []
var _jac := true ## false = residual-only evaluation (no derivative arithmetic)


## Parses an anchor's `constraint_model`. Returns null (= keep projecting) for no model, another version, an unknown mate type,
## a side missing geometry its residual needs, or a group the local solve is not meant for.
static func try_parse(json, max_members: int = MAX_MEMBERS):
	if not (json is Dictionary):
		return null
	if int(json.get("version", 0)) != MODEL_VERSION:
		return null
	var ids: Array = json.get("members", [])
	if ids.is_empty() or ids.size() > max_members:
		return null
	var model = (load("res://scripts/motion/local_retraction.gd") as GDScript).new()
	model.members = ids.size()
	model.member_ids = ids
	model.n = 6 * ids.size()
	for raw in json.get("mates", []):
		var type := str(raw["type"])
		if not _TYPES.has(type):
			return null
		var a = _parse_side(raw["a"])
		var b = _parse_side(raw["b"])
		if int(a["member"]) >= ids.size() or int(b["member"]) >= ids.size():
			return null
		model._mates.append({
			"type": type,
			"value": raw.get("value"),
			"allow_rotation": bool(raw.get("allow_rotation", true)),
			"a": a,
			"b": b,
		})
	# A dry evaluation at identity poses: tells the row count and fails on a missing field (a side lacking geometry).
	var identity: Array = []
	for i in ids.size():
		identity.append(Se3.make_pose([0.0, 0.0, 0.0], Se3.identity()))
	var r = model._evaluate(identity)
	if r == null or (r[0] as PackedFloat64Array).size() > MAX_ROWS:
		return null
	model.rows = (r[0] as PackedFloat64Array).size()
	return model


static func _parse_side(j: Dictionary) -> Dictionary:
	var geo := {}
	for name in ["point", "axis_origin", "direction", "perp"]:
		if j.has(name) and j[name] != null:
			geo[name] = _floats(j[name])
	if j.has("plane") and j["plane"] != null:
		geo["porigin"] = _floats(j["plane"]["origin"])
		geo["pnormal"] = _floats(j["plane"]["normal"])
	var side := {"member": int(j["member"]), "geo": geo, "fr": null, "ft": null}
	if j.has("frozen") and j["frozen"] != null:
		var fr: Array = []
		for row in j["frozen"]["r"]:
			fr.append_array(_floats(row))
		side["fr"] = fr
		side["ft"] = _floats(j["frozen"]["t"])
	return side


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
func _evaluate(poses: Array):
	var res := PackedFloat64Array()
	var jac: Array = []
	for mate in _mates:
		var d := _geo(mate["a"], poses)
		var f := _geo(mate["b"], poses)
		var type: String = mate["type"]
		if type == "coincident":
			if d.has("porigin") and f.has("porigin"):
				_add_s(res, jac, _dot(_sub(d["porigin"], f["porigin"]), f["pnormal"]))
				_add_v(res, jac, _cross(d["pnormal"], f["pnormal"]))
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
			_add_v(res, jac, _cross(d["direction"], f["direction"]))
			_add_v(res, jac, _cross(_sub(d["axis_origin"], f["axis_origin"]), f["direction"]))
			if not mate["allow_rotation"] and d.has("perp") and f.has("perp"):
				_add_v(res, jac, _cross(d["perp"], f["perp"]))
		elif type == "parallel":
			if not (d.has("direction") and f.has("direction")):
				return null
			_add_v(res, jac, _cross(d["direction"], f["direction"]))
		elif type == "angle":
			if not (d.has("direction") and f.has("direction")) or mate["value"] == null:
				return null
			var target := fposmod(absf(float(mate["value"])), 360.0)
			target = minf(target, 360.0 - target)
			var dd := _dot(_unit(d["direction"]), _unit(f["direction"]))
			res.append(dd[0] - cos(deg_to_rad(target)))
			if _jac:
				jac.append(dd[1])
		elif type == "distance":
			if mate["value"] == null:
				return null
			var tsq := float(mate["value"]) * float(mate["value"])
			if d.has("porigin") and f.has("porigin"):
				_add_sq(res, jac, _dot(_sub(d["porigin"], f["porigin"]), f["pnormal"]), tsq)
				_add_v(res, jac, _cross(d["pnormal"], f["pnormal"]))
			elif d.has("porigin"):
				_add_sq(res, jac, _dot(_sub(f["point"], d["porigin"]), d["pnormal"]), tsq)
			elif f.has("porigin"):
				_add_sq(res, jac, _dot(_sub(d["point"], f["porigin"]), f["pnormal"]), tsq)
			elif d.has("axis_origin") and f.has("axis_origin"):
				var p := _cross(_sub(d["axis_origin"], f["axis_origin"]), f["direction"])
				var pp := _dot(p, p)
				res.append(pp[0] - tsq)
				if _jac:
					jac.append(pp[1])
				_add_v(res, jac, _cross(d["direction"], f["direction"]))
			else:
				var off := _sub(d["point"], f["point"])
				var oo := _dot(off, off)
				res.append(oo[0] - tsq)
				if _jac:
					jac.append(oo[1])
	return [res, jac]


func _add_s(res: PackedFloat64Array, jac: Array, s: Array) -> void:
	res.append(s[0])
	if _jac:
		jac.append(s[1])


func _add_sq(res: PackedFloat64Array, jac: Array, s: Array, tsq: float) -> void:
	res.append(s[0] * s[0] - tsq)
	if not _jac:
		return
	var d: PackedFloat64Array = s[1]
	var out := PackedFloat64Array()
	out.resize(n)
	for c in n:
		out[c] = 2.0 * s[0] * d[c]
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
func retract(poses: Array, wishes: Array, w: Array, iterations: int = ITERATIONS, polish: int = POLISH) -> Array:
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
	var ok := res <= ACCEPT_RESIDUAL and dist <= ACCEPT_DISTANCE * maxf(lever, wish_step)
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
