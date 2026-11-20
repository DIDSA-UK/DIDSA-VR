extends RefCounted
## The per-frame sketch drag projector (parity plan S9), written from DIDSA-CAD's
## docs/motion/sketch-projector-spec.md (sections 1-11), not from the Dart: the
## hand wants these points here; where should the points of the dragged group be
## drawn so that every constraint still holds? Local, no network, no scene tree.
## Pinned against DIDSA-CAD's docs/motion/sketch-vectors.json by
## tests/sketch_projector_vectors.gd.
##
## One call per drag frame:
##   SketchProjector.project(points, constraints, lines, anchors, pinned, stiff, reference, provisional)
## points: id -> [x, y] or Vector2 (the wish: the grabbed point(s) at the cursor, every other point where it is);
## constraints: the backend wire dictionaries; lines: Line id -> [start id, end id] (or {a, b});
## anchors: the grabbed point ids; pinned: ids that never move (origin, references, Fix points);
## stiff: other points the correction should avoid moving; reference: id -> [x, y], the last accepted
## frame (the walk starts there and the branch signs are read there; {} = points);
## provisional: constraint id -> value for a `provisional: true` distance switched on for this call.
## Returns {unsupported, converged, points (the group's only: id -> [x, y]), residual_inf,
## variable_points, rows, exit, walks, rejected_steps, iterations}.
##
## Plain 64-bit floats throughout (Vector2 is 32-bit in a standard build); the
## Jacobian comes from forward-mode duals (a PackedFloat64Array [value, d/dq0..])
## over the 2k coordinates of each constraint's k points.

const FOLLOWER := 0.01
const NEAREST_MAX := 24
const ARRIVED := 1e-5
const MIN_OMEGA := 1.0 / 32.0
const MAX_BOOST := 8.0
const CORRECTORS := 4
const MAX_POLISH := 10
const TOLERANCE := 1e-6
const TRUST := 2.0
const TRUST_DIAGONAL := 0.1
const EPS := 1e-12
const LAMBDA_RELATIVE := 1e-10
const LAMBDA_ABSOLUTE := 1e-14
const CORRECTOR_HALVINGS := 8
const CLOSER_RATIO := 1e-9
const RHO_REVERSE := -0.3
const RHO_BOOST_LOW := 0.5
const RHO_BOOST_HIGH := 0.999
const STALL_LIMIT := 5

enum T {
	DIST_LINEAR, DIST_H, DIST_V, VERTICAL, HORIZONTAL, COINCIDENT, ANGLE, PARALLEL, PERPENDICULAR,
	EQUAL_LENGTH, COLLINEAR, LINE_DISTANCE, POINT_LINE_DISTANCE, POINT_ON_LINE, AT_MIDPOINT, TANGENT,
	CURVE_TANGENT, EQUAL_RADIUS, POINT_ON_CIRCLE, POINT_ON_ELLIPSE, ARC_LENGTH, HORIZONTAL_ANGLE,
	POINT_ANGLE, POINT_CIRCLE_MAX, POINT_CIRCLE_MIN, CIRCLE_MAX, CIRCLE_MIN, LINE_CIRCLE_MAX, LINE_CIRCLE_MIN,
}

const SPLINE_POINT_FIELDS := [
	"segment_a_p0", "segment_a_p1", "segment_a_p2", "segment_a_p3",
	"segment_b_p0", "segment_b_p1", "segment_b_p2", "segment_b_p3",
]

## One group constraint, compiled once per call (section 4's rows, section 5's signs fixed).
class Term:
	var t := 0
	var cols := PackedInt32Array() ## per local coordinate: the variable column, or -1 for a constant (pinned) point
	var consts := PackedFloat64Array() ## the constant points' coordinates
	var slot := PackedInt32Array() ## section 4's named points -> index in the de-duplicated list
	var k2 := 0
	var a := 0.0 ## the dimension's value
	var sign := 1.0 ## b_axis / b_outside / b_side
	var ct := 1.0 ## cos θ of the angle rows
	var nrows := 1
	var seeds: Array = [] ## per local coordinate: its dual seed [value, 0.., 1 at its own slot (if variable), ..0]; only [0] changes


# ---- the system, built once per call -------------------------------------------------------------
var _n := 0 ## gradient size of the duals being evaluated (2k of the current term; 0 = values only)
var _terms: Array = [] ## Term per group constraint, in input order
var _ids := PackedStringArray() ## group point ids, variable order
var _s := PackedFloat64Array() ## stiffness per coordinate
var _w := PackedFloat64Array() ## wish per coordinate
var _x := PackedFloat64Array() ## current coordinates
var _m := 0 ## rows
# rows at _x
var _r := PackedFloat64Array()
var _jv := PackedFloat64Array() ## the Jacobian's entries (row by row; the pattern below is fixed per call)
# the sparsity pattern, fixed per call: entries of row i are _roff[i] .. _roff[i + 1] - 1, column _jcol[e];
# M = A Aᵀ is the sum over (_pt, _pa, _pb) of A[_pa] A[_pb] into M[_pt]
var _roff := PackedInt32Array()
var _jcol := PackedInt32Array()
var _pt := PackedInt32Array()
var _pa := PackedInt32Array()
var _pb := PackedInt32Array()
var _bw := 0 ## M's half bandwidth (largest |i - j| of a nonzero); partial pivoting keeps L within it and U within 2 _bw
var _jac_ok := false
var iterations := 0


static func project(points: Dictionary, constraints: Array, lines: Dictionary, anchors: Array,
		pinned: Array = [], stiff: Array = [], reference: Dictionary = {}, provisional: Dictionary = {}) -> Dictionary:
	var p = (load("res://scripts/motion/sketch_projector.gd") as GDScript).new()
	return p._project(points, constraints, lines, anchors, pinned, stiff, reference, provisional)


static func _xy(v) -> PackedFloat64Array:
	if v is Vector2:
		return PackedFloat64Array([float(v.x), float(v.y)])
	return PackedFloat64Array([float(v[0]), float(v[1])])


static func _line_ends(lines: Dictionary, id: String):
	if not lines.has(id):
		return null
	var l = lines[id]
	if l is Dictionary:
		return [str(l.get("a", l.get("start", ""))), str(l.get("b", l.get("end", "")))]
	return [str(l[0]), str(l[1])]


## The point ids a supported constraint reads, in order (section 4's "Points" column),
## or null when a Line it names is unknown. Unsupported types return [].
static func _point_list(c: Dictionary, lines: Dictionary):
	var t := str(c.get("type", ""))
	match t:
		"distance", "vertical", "horizontal", "coincident":
			return [str(c.get("point_a_id", "")), str(c.get("point_b_id", ""))]
		"concentric":
			return [str(c.get("center1_point_id", "")), str(c.get("center2_point_id", ""))]
		"angle", "parallel", "perpendicular", "equal_length", "collinear":
			var l1 = _line_ends(lines, str(c.get("line1_id", "")))
			var l2 = _line_ends(lines, str(c.get("line2_id", "")))
			if l1 == null or l2 == null:
				return null
			return [l1[0], l1[1], l2[0], l2[1]]
		"line_distance":
			var l1 = _line_ends(lines, str(c.get("line1_id", "")))
			var l2 = _line_ends(lines, str(c.get("line2_id", "")))
			if l1 == null or l2 == null:
				return null
			return [l1[0], l1[1], l2[0]]
		"point_line_distance", "point_on_line", "at_midpoint":
			var l = _line_ends(lines, str(c.get("line_id", "")))
			if l == null:
				return null
			return [str(c.get("point_id", "")), l[0], l[1]]
		"tangent":
			var l = _line_ends(lines, str(c.get("line_id", "")))
			if l == null:
				return null
			return [str(c.get("center_point_id", "")), str(c.get("radius_point_id", "")), l[0], l[1]]
		"curve_tangent":
			return [str(c.get("center1_point_id", "")), str(c.get("center2_point_id", "")), str(c.get("shared_point_id", ""))]
		"equal_radius", "circle_distance":
			return [str(c.get("center1_point_id", "")), str(c.get("radius1_point_id", "")),
				str(c.get("center2_point_id", "")), str(c.get("radius2_point_id", ""))]
		"point_on_circle", "point_circle_distance":
			return [str(c.get("point_id", "")), str(c.get("center_point_id", "")), str(c.get("radius_point_id", ""))]
		"point_on_ellipse":
			return [str(c.get("point_id", "")), str(c.get("center_point_id", "")),
				str(c.get("major_point_id", "")), str(c.get("minor_point_id", ""))]
		"arc_length":
			return [str(c.get("center_point_id", "")), str(c.get("start_point_id", "")), str(c.get("end_point_id", ""))]
		"horizontal_angle":
			return [str(c.get("line_start_id", "")), str(c.get("line_end_id", ""))]
		"point_angle":
			return [str(c.get("vertex_point_id", "")), str(c.get("point1_id", "")), str(c.get("point2_id", ""))]
		"line_circle_distance":
			return [str(c.get("line_start_id", "")), str(c.get("line_end_id", "")),
				str(c.get("center_point_id", "")), str(c.get("radius_point_id", ""))]
	return []


static func _supported(t: String) -> bool:
	return t in ["distance", "vertical", "horizontal", "coincident", "concentric", "angle", "parallel",
		"perpendicular", "equal_length", "collinear", "line_distance", "point_line_distance", "point_on_line",
		"at_midpoint", "tangent", "curve_tangent", "equal_radius", "point_on_circle", "point_on_ellipse",
		"arc_length", "horizontal_angle", "point_angle", "point_circle_distance", "circle_distance",
		"line_circle_distance"]


static func _unique(list: Array) -> Array:
	var out := []
	for id in list:
		if not out.has(id):
			out.append(id)
	return out


static func _result(unsupported: bool, converged: bool, pts: Dictionary, res, nvar: int, nrows: int,
		exit: String, walks: int, rejected: int, iters: int) -> Dictionary:
	return {"unsupported": unsupported, "converged": converged, "points": pts, "residual_inf": res,
		"variable_points": nvar, "rows": nrows, "exit": exit, "walks": walks, "rejected_steps": rejected,
		"iterations": iters}


func _project(points: Dictionary, constraints: Array, lines: Dictionary, anchors: Array, pinned_list: Array,
		stiff_list: Array, reference: Dictionary, provisional: Dictionary) -> Dictionary:
	var pinned := {}
	for id in pinned_list:
		pinned[str(id)] = true
	var ref: Dictionary = reference if not reference.is_empty() else points

	# 1. active constraints (with their point lists) and the ones kept aside
	var active: Array = [] ## [constraint, its points de-duplicated, value override or null, its points as named]
	var aside: Array = []
	for c in constraints:
		if not (c is Dictionary):
			continue
		var t := str(c.get("type", ""))
		var value_override = null
		if t == "distance" and bool(c.get("provisional", false)):
			var cid := str(c.get("id", ""))
			if not provisional.has(cid):
				continue
			value_override = float(provisional[cid])
		if t == "fixed":
			continue
		if not _supported(t):
			aside.append(c)
			continue
		var list = _point_list(c, lines)
		if list == null:
			continue
		var unique := _unique(list)
		var known := true
		for id in unique:
			if not points.has(id):
				known = false
				break
		if known:
			active.append([c, unique, value_override, list])

	# 2. the group: from the free anchors, through active constraints, never through a pinned point
	var by_point := {}
	for i in active.size():
		for id in active[i][1]:
			if not by_point.has(id):
				by_point[id] = []
			by_point[id].append(i)
	var index := {} ## point id -> variable index
	var order: Array = []
	for a in anchors:
		var id := str(a)
		if points.has(id) and not pinned.has(id) and not index.has(id):
			index[id] = order.size()
			order.append(id)
	var stack: Array = order.duplicate() # depth first, the first anchor first
	stack.reverse()
	var in_group := {}
	while not stack.is_empty():
		var id: String = stack.pop_back()
		for ci in by_point.get(id, []):
			if in_group.has(ci):
				continue
			in_group[ci] = true
			for other in active[ci][1]:
				if pinned.has(other) or index.has(other):
					continue
				index[other] = order.size()
				order.append(other)
				stack.append(other)

	# 3. unsupported: a kept-aside constraint the group touches (an unknown type always)
	for c in aside:
		if str(c.get("type", "")) == "spline_tangent":
			for f in SPLINE_POINT_FIELDS:
				if index.has(str(c.get(f, ""))):
					return _result(true, false, {}, INF, 0, 0, "none", 0, 0, 0)
		else:
			return _result(true, false, {}, INF, 0, 0, "none", 0, 0, 0)

	# 5. no group points
	if order.is_empty():
		return _result(false, true, {}, 0.0, 0, 0, "none", 0, 0, 0)

	# 4. variables and rows
	var g := order.size()
	_ids = PackedStringArray(order)
	_s.resize(2 * g)
	_w.resize(2 * g)
	_x.resize(2 * g)
	var stiff := {}
	for id in anchors:
		stiff[str(id)] = true
	for id in stiff_list:
		stiff[str(id)] = true
	var minx := INF
	var miny := INF
	var maxx := -INF
	var maxy := -INF
	for i in g:
		var id: String = order[i]
		var st := 1.0 if stiff.has(id) else FOLLOWER
		_s[2 * i] = st
		_s[2 * i + 1] = st
		var wp := _xy(points[id])
		_w[2 * i] = wp[0]
		_w[2 * i + 1] = wp[1]
		var xp := _xy(reference[id]) if reference.has(id) else wp
		_x[2 * i] = xp[0]
		_x[2 * i + 1] = xp[1]
		minx = minf(minx, xp[0])
		maxx = maxf(maxx, xp[0])
		miny = minf(miny, xp[1])
		maxy = maxf(maxy, xp[1])
	var diag := sqrt((maxx - minx) * (maxx - minx) + (maxy - miny) * (maxy - miny))
	var tau := TOLERANCE * maxf(1.0, diag)

	_terms.clear()
	_m = 0
	var ci_sorted: Array = in_group.keys()
	ci_sorted.sort()
	for ci in ci_sorted:
		var d := _compile(active[ci][0], active[ci][3], active[ci][1], active[ci][2], index, points, ref)
		var term := Term.new()
		term.t = int(d["t"])
		term.cols = d["cols"]
		term.consts = d["consts"]
		term.slot = d["slot"]
		term.k2 = 2 * int(d["k"])
		term.a = float(d["a"])
		term.sign = float(d["sign"])
		term.ct = cos(float(d["theta"]))
		term.nrows = int(d["nrows"])
		for j in term.k2:
			var seed := PackedFloat64Array()
			seed.resize(term.k2 + 1)
			seed.fill(0.0)
			if term.cols[j] >= 0:
				seed[j + 1] = 1.0
			term.seeds.append(seed)
		_terms.append(term)
		_m += term.nrows
	_pattern()

	var walk := _walk(diag, tau)
	var pts := {}
	var finite := true
	for i in g:
		var px := _x[2 * i]
		var py := _x[2 * i + 1]
		if not (is_finite(px) and is_finite(py)):
			finite = false
		pts[_ids[i]] = [px, py]
	var res := _inf_norm()
	var converged := finite and res <= tau
	return _result(false, converged, pts, res, g, _m, walk["exit"], walk["walks"], walk["rejected"], iterations)


# ---- section 5: one constraint, its branch signs read from the reference --------------------------

func _compile(c: Dictionary, raw: Array, list: Array, value_override, index: Dictionary, points: Dictionary, ref: Dictionary) -> Dictionary:
	var k := list.size()
	var cols := PackedInt32Array()
	var consts := PackedFloat64Array()
	cols.resize(2 * k)
	consts.resize(2 * k)
	for j in k:
		var id: String = list[j]
		if index.has(id):
			cols[2 * j] = 2 * int(index[id])
			cols[2 * j + 1] = 2 * int(index[id]) + 1
		else:
			cols[2 * j] = -1
			cols[2 * j + 1] = -1
			var p := _xy(points[id])
			consts[2 * j] = p[0]
			consts[2 * j + 1] = p[1]
	# slot of each named point in the de-duplicated list
	var t := str(c["type"])
	var term := {"cols": cols, "consts": consts, "k": k, "a": 0.0, "sign": 1.0, "theta": 0.0, "nrows": 1}
	var slot := PackedInt32Array()
	for id in raw:
		slot.append(list.find(id))
	term["slot"] = slot
	match t:
		"distance":
			var d := absf(float(value_override if value_override != null else c.get("distance", 0.0)))
			term["a"] = d
			var o := str(c.get("orientation", "linear"))
			if o == "horizontal" or o == "vertical":
				term["t"] = T.DIST_H if o == "horizontal" else T.DIST_V
				var axis := 0 if o == "horizontal" else 1
				var ra = _ref(ref, raw[0])
				var rb = _ref(ref, raw[1])
				if ra != null and rb != null:
					term["sign"] = 1.0 if rb[axis] - ra[axis] >= 0.0 else -1.0
			else:
				term["t"] = T.DIST_LINEAR
		"vertical":
			term["t"] = T.VERTICAL
		"horizontal":
			term["t"] = T.HORIZONTAL
		"coincident", "concentric":
			term["t"] = T.COINCIDENT
			term["nrows"] = 2
		"angle":
			term["t"] = T.ANGLE
			var tt := fmod(absf(float(c.get("angle_degrees", 0.0))), 360.0)
			tt = minf(tt, 360.0 - tt)
			var cang := 0.0
			var pts := []
			for id in raw:
				pts.append(_ref(ref, id))
			var supplement := false
			if not pts.has(null):
				var ux: float = pts[1][0] - pts[0][0]
				var uy: float = pts[1][1] - pts[0][1]
				var vx: float = pts[3][0] - pts[2][0]
				var vy: float = pts[3][1] - pts[2][1]
				var lu := sqrt(ux * ux + uy * uy)
				var lv := sqrt(vx * vx + vy * vy)
				if lu == 0.0 or lv == 0.0:
					cang = -1.0 # zero-length reference ray: not the supplement
				else:
					cang = rad_to_deg(acos(clampf((ux * vx + uy * vy) / (lu * lv), -1.0, 1.0)))
			if cang >= 0.0:
				supplement = absf((180.0 - tt) - cang) < absf(tt - cang)
			term["theta"] = deg_to_rad(180.0 - tt if supplement else tt)
		"parallel":
			term["t"] = T.PARALLEL
		"perpendicular":
			term["t"] = T.PERPENDICULAR
		"equal_length":
			term["t"] = T.EQUAL_LENGTH
		"collinear":
			term["t"] = T.COLLINEAR
			term["nrows"] = 2
		"line_distance":
			term["t"] = T.LINE_DISTANCE
			term["a"] = float(c.get("distance", 0.0))
		"point_line_distance":
			term["t"] = T.POINT_LINE_DISTANCE
			term["a"] = float(c.get("distance", 0.0))
		"point_on_line":
			term["t"] = T.POINT_ON_LINE
		"at_midpoint":
			term["t"] = T.AT_MIDPOINT
			term["nrows"] = 2
		"tangent":
			term["t"] = T.TANGENT
		"curve_tangent":
			term["t"] = T.CURVE_TANGENT
		"equal_radius":
			term["t"] = T.EQUAL_RADIUS
		"point_on_circle":
			term["t"] = T.POINT_ON_CIRCLE
		"point_on_ellipse":
			term["t"] = T.POINT_ON_ELLIPSE
		"arc_length":
			term["t"] = T.ARC_LENGTH
			term["a"] = float(c.get("length", 0.0))
		"horizontal_angle", "point_angle":
			term["t"] = T.HORIZONTAL_ANGLE if t == "horizontal_angle" else T.POINT_ANGLE
			var alpha := float(c.get("angle_degrees", 0.0))
			var q = c.get("quadrant", null)
			var supplement := false
			if q == null:
				var cang := -1.0
				if t == "horizontal_angle":
					var a = _ref(ref, raw[0])
					var b = _ref(ref, raw[1])
					if a != null and b != null:
						var dx: float = b[0] - a[0]
						var dy: float = b[1] - a[1]
						var l := sqrt(dx * dx + dy * dy)
						if l > 0.0:
							cang = rad_to_deg(acos(clampf(dx / l, -1.0, 1.0)))
				else:
					var v = _ref(ref, raw[0])
					var p1 = _ref(ref, raw[1])
					var p2 = _ref(ref, raw[2])
					if v != null and p1 != null and p2 != null:
						var ux: float = p1[0] - v[0]
						var uy: float = p1[1] - v[1]
						var wx: float = p2[0] - v[0]
						var wy: float = p2[1] - v[1]
						var lu := sqrt(ux * ux + uy * uy)
						var lw := sqrt(wx * wx + wy * wy)
						if lu > 0.0 and lw > 0.0:
							cang = rad_to_deg(acos(clampf((ux * wx + uy * wy) / (lu * lw), -1.0, 1.0)))
				if cang >= 0.0:
					supplement = absf((180.0 - alpha) - cang) < absf(alpha - cang)
			else:
				var qi := int(q)
				supplement = ((qi & 1) != 0) != ((qi & 2) != 0)
			term["theta"] = deg_to_rad(180.0 - alpha if supplement else alpha)
		"point_circle_distance":
			term["a"] = float(c.get("distance", 0.0))
			if str(c.get("side", "min")) == "max":
				term["t"] = T.POINT_CIRCLE_MAX
			else:
				term["t"] = T.POINT_CIRCLE_MIN
				var p = _ref(ref, raw[0])
				var cc = _ref(ref, raw[1])
				var rr = _ref(ref, raw[2])
				if p != null and cc != null and rr != null:
					var d2: float = (p[0] - cc[0]) * (p[0] - cc[0]) + (p[1] - cc[1]) * (p[1] - cc[1])
					var r2: float = (rr[0] - cc[0]) * (rr[0] - cc[0]) + (rr[1] - cc[1]) * (rr[1] - cc[1])
					term["sign"] = 1.0 if sqrt(d2) >= sqrt(r2) else -1.0
		"circle_distance":
			term["a"] = float(c.get("distance", 0.0))
			term["t"] = T.CIRCLE_MAX if str(c.get("side", "min")) == "max" else T.CIRCLE_MIN
		"line_circle_distance":
			term["a"] = float(c.get("distance", 0.0))
			term["t"] = T.LINE_CIRCLE_MAX if str(c.get("side", "min")) == "max" else T.LINE_CIRCLE_MIN
			var a = _ref(ref, raw[0])
			var b = _ref(ref, raw[1])
			var cc = _ref(ref, raw[2])
			if a != null and b != null and cc != null:
				var cr: float = (cc[0] - a[0]) * (b[1] - a[1]) - (cc[1] - a[1]) * (b[0] - a[0])
				term["sign"] = -1.0 if cr < 0.0 else 1.0
	return term


static func _ref(ref: Dictionary, id: String):
	if not ref.has(id):
		return null
	return _xy(ref[id])


# ---- forward-mode duals ------------------------------------------------------------------------------
# A dual is a PackedFloat64Array [value, d/dq0, ..., d/dq(n-1)] over the 2k coordinates of the term being
# evaluated. When only the row values are wanted (_n == 0) the same code runs on plain floats, so a
# value-only evaluation allocates nothing.

static func _v(a) -> float:
	return a if a is float else a[0]


func _add(a, b):
	return a + b if _n == 0 else _d_add(a, b)


func _sub(a, b):
	return a - b if _n == 0 else _d_sub(a, b)


func _addc(a, k: float):
	return a + k if _n == 0 else _d_addc(a, k)


func _scale(a, k: float):
	return a * k if _n == 0 else _d_scale(a, k)


func _mul(a, b):
	return a * b if _n == 0 else _d_mul(a, b)


func _div(a, b):
	return a / b if _n == 0 else _d_div(a, b)


## |(x, y)| = sqrt(max(x² + y², ε²)); derivative (x x' + y y') / |v| (section 2).
func _norm(x, y):
	return sqrt(maxf(x * x + y * y, EPS * EPS)) if _n == 0 else _d_norm(x, y)


func _dot(ax, ay, bx, by):
	return ax * bx + ay * by if _n == 0 else _d_dot(ax, ay, bx, by)


func _cross(ax, ay, bx, by):
	return ax * by - ay * bx if _n == 0 else _d_cross(ax, ay, bx, by)


## sqrt(max(f, ε)); derivative f' / (2 sqrt(max(f, ε))) (the ellipse row).
func _sqrt_eps(f):
	return sqrt(maxf(f, EPS)) if _n == 0 else _d_sqrt_eps(f)


## |B − A| for the points (bx, by), (ax, ay): _norm(_sub(bx, ax), _sub(by, ay)) as one dual operation.
func _dist(bx, by, ax, ay):
	if _n == 0:
		var dx: float = bx - ax
		var dy: float = by - ay
		return sqrt(maxf(dx * dx + dy * dy, EPS * EPS))
	return _d_dist(bx, by, ax, ay)


static func _d_dist(bx: PackedFloat64Array, by: PackedFloat64Array, ax: PackedFloat64Array, ay: PackedFloat64Array) -> PackedFloat64Array:
	var r := bx.duplicate()
	var dx := bx[0] - ax[0]
	var dy := by[0] - ay[0]
	var l := sqrt(maxf(dx * dx + dy * dy, EPS * EPS))
	r[0] = l
	for i in range(1, r.size()):
		r[i] = (dx * (bx[i] - ax[i]) + dy * (by[i] - ay[i])) / l
	return r


static func _d_add(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var r := a.duplicate()
	for i in r.size():
		r[i] += b[i]
	return r


static func _d_sub(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var r := a.duplicate()
	for i in r.size():
		r[i] -= b[i]
	return r


static func _d_addc(a: PackedFloat64Array, k: float) -> PackedFloat64Array:
	var r := a.duplicate()
	r[0] += k
	return r


static func _d_scale(a: PackedFloat64Array, k: float) -> PackedFloat64Array:
	var r := a.duplicate()
	for i in r.size():
		r[i] *= k
	return r


static func _d_mul(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var r := a.duplicate()
	var av := a[0]
	var bv := b[0]
	r[0] = av * bv
	for i in range(1, r.size()):
		r[i] = a[i] * bv + av * b[i]
	return r


static func _d_div(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var r := a.duplicate()
	var bv := b[0]
	var q := a[0] / bv
	r[0] = q
	for i in range(1, r.size()):
		r[i] = (a[i] - q * b[i]) / bv
	return r


static func _d_norm(x: PackedFloat64Array, y: PackedFloat64Array) -> PackedFloat64Array:
	var r := x.duplicate()
	var xv := x[0]
	var yv := y[0]
	var l := sqrt(maxf(xv * xv + yv * yv, EPS * EPS))
	r[0] = l
	for i in range(1, r.size()):
		r[i] = (xv * x[i] + yv * y[i]) / l
	return r


static func _d_dot(ax: PackedFloat64Array, ay: PackedFloat64Array, bx: PackedFloat64Array, by: PackedFloat64Array) -> PackedFloat64Array:
	var r := ax.duplicate()
	var axv := ax[0]
	var ayv := ay[0]
	var bxv := bx[0]
	var byv := by[0]
	r[0] = axv * bxv + ayv * byv
	for i in range(1, r.size()):
		r[i] = ax[i] * bxv + axv * bx[i] + ay[i] * byv + ayv * by[i]
	return r


static func _d_cross(ax: PackedFloat64Array, ay: PackedFloat64Array, bx: PackedFloat64Array, by: PackedFloat64Array) -> PackedFloat64Array:
	var r := ax.duplicate()
	var axv := ax[0]
	var ayv := ay[0]
	var bxv := bx[0]
	var byv := by[0]
	r[0] = axv * byv - ayv * bxv
	for i in range(1, r.size()):
		r[i] = ax[i] * byv + axv * by[i] - ay[i] * bxv - ayv * bx[i]
	return r


static func _d_sqrt_eps(f: PackedFloat64Array) -> PackedFloat64Array:
	var r := f.duplicate()
	var s := sqrt(maxf(f[0], EPS))
	r[0] = s
	for i in range(1, r.size()):
		r[i] = f[i] / (2.0 * s)
	return r


## abs: f when f ≥ 0, else -f (the derivative likewise).
func _abs(f):
	return f if _v(f) >= 0.0 else _scale(f, -1.0)


## sweep(u, w): the counter-clockwise angle u -> w in (0, 2π] (section 4).
func _sweep(ux, uy, wx, wy):
	var y = _cross(ux, uy, wx, wy)
	var x = _dot(ux, uy, wx, wy)
	var yv := _v(y)
	var xv := _v(x)
	var a := atan2(yv, xv)
	if a <= 1e-12:
		a += TAU
	if _n == 0:
		return a
	var r := PackedFloat64Array()
	r.resize(_n + 1)
	r[0] = a
	var den := maxf(xv * xv + yv * yv, EPS)
	for i in range(1, _n + 1):
		r[i] = (xv * y[i] - yv * x[i]) / den
	return r


## sd(p, s, e) = cross(p − s, e − s) / |e − s|.
func _sd(px, py, sx, sy, ex, ey):
	var ux = _sub(ex, sx)
	var uy = _sub(ey, sy)
	return _div(_cross(_sub(px, sx), _sub(py, sy), ux, uy), _norm(ux, uy))


# ---- section 4: the rows of one term ---------------------------------------------------------------

## q: Array of duals [x0, y0, x1, y1, ...] for the term's de-duplicated points; returns its rows.
func _rows_of(term: Term, q: Array) -> Array:
	var sl := term.slot
	var a := term.a
	match term.t:
		T.DIST_LINEAR:
			var A := 2 * sl[0]
			var B := 2 * sl[1]
			return [_addc(_dist(q[B], q[B + 1], q[A], q[A + 1]), -a)]
		T.DIST_H, T.DIST_V:
			var o := 0 if term.t == T.DIST_H else 1
			var A := 2 * sl[0] + o
			var B := 2 * sl[1] + o
			return [_addc(_scale(_sub(q[B], q[A]), term.sign), -a)]
		T.VERTICAL:
			return [_sub(q[2 * sl[0]], q[2 * sl[1]])]
		T.HORIZONTAL:
			return [_sub(q[2 * sl[0] + 1], q[2 * sl[1] + 1])]
		T.COINCIDENT:
			var A := 2 * sl[0]
			var B := 2 * sl[1]
			return [_sub(q[A], q[B]), _sub(q[A + 1], q[B + 1])]
		T.ANGLE, T.PARALLEL, T.PERPENDICULAR, T.EQUAL_LENGTH:
			var s1 := 2 * sl[0]
			var e1 := 2 * sl[1]
			var s2 := 2 * sl[2]
			var e2 := 2 * sl[3]
			var ux = _sub(q[e1], q[s1])
			var uy = _sub(q[e1 + 1], q[s1 + 1])
			var vx = _sub(q[e2], q[s2])
			var vy = _sub(q[e2 + 1], q[s2 + 1])
			var lu = _norm(ux, uy)
			var lv = _norm(vx, vy)
			match term.t:
				T.ANGLE:
					return [_sub(_dot(ux, uy, vx, vy), _scale(_mul(lu, lv), term.ct))]
				T.PARALLEL:
					return [_div(_cross(ux, uy, vx, vy), _mul(lu, lv))]
				T.PERPENDICULAR:
					return [_div(_dot(ux, uy, vx, vy), _mul(lu, lv))]
			return [_sub(lu, lv)]
		T.COLLINEAR:
			var s1 := 2 * sl[0]
			var e1 := 2 * sl[1]
			var s2 := 2 * sl[2]
			var e2 := 2 * sl[3]
			return [_sd(q[s2], q[s2 + 1], q[s1], q[s1 + 1], q[e1], q[e1 + 1]),
				_sd(q[e2], q[e2 + 1], q[s1], q[s1 + 1], q[e1], q[e1 + 1])]
		T.LINE_DISTANCE:
			var s1 := 2 * sl[0]
			var e1 := 2 * sl[1]
			var s2 := 2 * sl[2]
			return [_addc(_sd(q[s2], q[s2 + 1], q[s1], q[s1 + 1], q[e1], q[e1 + 1]), -a)]
		T.POINT_LINE_DISTANCE, T.POINT_ON_LINE:
			var p := 2 * sl[0]
			var s := 2 * sl[1]
			var e := 2 * sl[2]
			return [_addc(_sd(q[p], q[p + 1], q[s], q[s + 1], q[e], q[e + 1]), -a)]
		T.AT_MIDPOINT:
			var p := 2 * sl[0]
			var s := 2 * sl[1]
			var e := 2 * sl[2]
			return [_sub(q[p], _scale(_add(q[s], q[e]), 0.5)), _sub(q[p + 1], _scale(_add(q[s + 1], q[e + 1]), 0.5))]
		T.TANGENT:
			var c := 2 * sl[0]
			var r := 2 * sl[1]
			var s := 2 * sl[2]
			var e := 2 * sl[3]
			var o = _abs(_sd(q[c], q[c + 1], q[s], q[s + 1], q[e], q[e + 1]))
			return [_sub(o, _dist(q[r], q[r + 1], q[c], q[c + 1]))]
		T.CURVE_TANGENT:
			var c1 := 2 * sl[0]
			var c2 := 2 * sl[1]
			var s := 2 * sl[2]
			return [_sd(q[s], q[s + 1], q[c1], q[c1 + 1], q[c2], q[c2 + 1])]
		T.EQUAL_RADIUS:
			var c1 := 2 * sl[0]
			var r1 := 2 * sl[1]
			var c2 := 2 * sl[2]
			var r2 := 2 * sl[3]
			return [_sub(_dist(q[r1], q[r1 + 1], q[c1], q[c1 + 1]),
				_dist(q[r2], q[r2 + 1], q[c2], q[c2 + 1]))]
		T.POINT_ON_CIRCLE:
			var p := 2 * sl[0]
			var c := 2 * sl[1]
			var r := 2 * sl[2]
			return [_sub(_dist(q[p], q[p + 1], q[c], q[c + 1]),
				_dist(q[r], q[r + 1], q[c], q[c + 1]))]
		T.POINT_ON_ELLIPSE:
			var p := 2 * sl[0]
			var c := 2 * sl[1]
			var mj := 2 * sl[2]
			var mn := 2 * sl[3]
			var mx = _sub(q[mj], q[c])
			var my = _sub(q[mj + 1], q[c + 1])
			var nx = _sub(q[mn], q[c])
			var ny = _sub(q[mn + 1], q[c + 1])
			var dx = _sub(q[p], q[c])
			var dy = _sub(q[p + 1], q[c + 1])
			var la = _norm(mx, my)
			var lb = _norm(nx, ny)
			var fa = _div(_dot(dx, dy, mx, my), _mul(la, la))
			var fb = _div(_dot(dx, dy, nx, ny), _mul(lb, lb))
			var f = _add(_mul(fa, fa), _mul(fb, fb))
			var kk := (_v(la) + _v(lb)) * 0.5
			return [_scale(_addc(_sqrt_eps(f), -1.0), kk)]
		T.ARC_LENGTH:
			var c := 2 * sl[0]
			var s := 2 * sl[1]
			var e := 2 * sl[2]
			var ux = _sub(q[s], q[c])
			var uy = _sub(q[s + 1], q[c + 1])
			var wx = _sub(q[e], q[c])
			var wy = _sub(q[e + 1], q[c + 1])
			return [_addc(_mul(_norm(ux, uy), _sweep(ux, uy, wx, wy)), -a)]
		T.HORIZONTAL_ANGLE:
			var A := 2 * sl[0]
			var B := 2 * sl[1]
			var ux = _sub(q[B], q[A])
			var uy = _sub(q[B + 1], q[A + 1])
			return [_sub(ux, _scale(_norm(ux, uy), term.ct))]
		T.POINT_ANGLE:
			var v := 2 * sl[0]
			var p1 := 2 * sl[1]
			var p2 := 2 * sl[2]
			var ux = _sub(q[p1], q[v])
			var uy = _sub(q[p1 + 1], q[v + 1])
			var wx = _sub(q[p2], q[v])
			var wy = _sub(q[p2 + 1], q[v + 1])
			return [_sub(_dot(ux, uy, wx, wy), _scale(_mul(_norm(ux, uy), _norm(wx, wy)), term.ct))]
		T.POINT_CIRCLE_MAX, T.POINT_CIRCLE_MIN:
			var p := 2 * sl[0]
			var c := 2 * sl[1]
			var r := 2 * sl[2]
			var d = _dist(q[p], q[p + 1], q[c], q[c + 1])
			var rr = _dist(q[r], q[r + 1], q[c], q[c + 1])
			if term.t == T.POINT_CIRCLE_MAX:
				return [_addc(_add(d, rr), -a)]
			return [_addc(_scale(_sub(d, rr), term.sign), -a)]
		T.CIRCLE_MAX, T.CIRCLE_MIN:
			var c1 := 2 * sl[0]
			var r1 := 2 * sl[1]
			var c2 := 2 * sl[2]
			var r2 := 2 * sl[3]
			var d = _dist(q[c2], q[c2 + 1], q[c1], q[c1 + 1])
			var rho = _add(_dist(q[r1], q[r1 + 1], q[c1], q[c1 + 1]),
				_dist(q[r2], q[r2 + 1], q[c2], q[c2 + 1]))
			if term.t == T.CIRCLE_MAX:
				return [_addc(_add(d, rho), -a)]
			return [_addc(_sub(d, rho), -a)]
		T.LINE_CIRCLE_MAX, T.LINE_CIRCLE_MIN:
			var A := 2 * sl[0]
			var B := 2 * sl[1]
			var c := 2 * sl[2]
			var r := 2 * sl[3]
			var o = _scale(_sd(q[c], q[c + 1], q[A], q[A + 1], q[B], q[B + 1]), term.sign)
			var rr = _dist(q[r], q[r + 1], q[c], q[c + 1])
			if term.t == T.LINE_CIRCLE_MAX:
				return [_addc(_add(o, rr), -a)]
			return [_addc(_sub(o, rr), -a)]
	return []


# ---- evaluation: rows (and, on demand, the Jacobian) at _x ------------------------------------------

## The Jacobian's sparsity pattern: a term's rows have an entry for each of its variable coordinates.
func _pattern() -> void:
	_roff = PackedInt32Array()
	_jcol = PackedInt32Array()
	var row_of := PackedInt32Array()
	_roff.append(0)
	var row := 0
	for term: Term in _terms:
		for rr in term.nrows:
			for c in term.cols:
				if c >= 0:
					_jcol.append(c)
					row_of.append(row)
			_roff.append(_jcol.size())
			row += 1
	var by_col: Array = []
	by_col.resize(_x.size())
	for c in _x.size():
		by_col[c] = PackedInt32Array()
	for e in _jcol.size():
		by_col[_jcol[e]].append(e)
	_pt = PackedInt32Array()
	_pa = PackedInt32Array()
	_pb = PackedInt32Array()
	_bw = 0
	for c in _x.size():
		var es: PackedInt32Array = by_col[c]
		for ea in es:
			for eb in es:
				_bw = maxi(_bw, absi(row_of[ea] - row_of[eb]))
				_pt.append(row_of[ea] * _m + row_of[eb])
				_pa.append(ea)
				_pb.append(eb)


func _evaluate(with_jac: bool) -> void:
	_r = PackedFloat64Array()
	_r.resize(_m)
	var jv := PackedFloat64Array()
	if with_jac:
		jv.resize(_jcol.size())
	var row := 0
	var e := 0
	var q: Array = []
	for term: Term in _terms:
		var k2 := term.k2
		var cols := term.cols
		var consts := term.consts
		q.resize(k2)
		if with_jac:
			_n = k2
			var seeds := term.seeds
			for j in k2:
				var c := cols[j]
				var d: PackedFloat64Array = seeds[j]
				d[0] = _x[c] if c >= 0 else consts[j]
				q[j] = d
		else:
			_n = 0
			for j in k2:
				var c := cols[j]
				q[j] = _x[c] if c >= 0 else consts[j]
		for rr in _rows_of(term, q):
			if with_jac:
				_r[row] = rr[0]
				for j in k2:
					if cols[j] >= 0:
						jv[e] = rr[j + 1]
						e += 1
			else:
				_r[row] = rr
			row += 1
	_n = 0
	if with_jac:
		_jv = jv
	_jac_ok = with_jac


func _ensure_jac() -> void:
	if not _jac_ok:
		_evaluate(true)


func _inf_norm() -> float:
	var worst := 0.0
	for v in _r:
		worst = maxf(worst, absf(v))
	return worst


func _sq_norm() -> float:
	var sum := 0.0
	for v in _r:
		sum += v * v
	return sum


## δ(x) = sqrt(Σ (s_c (w_c − x_c))²).
func _wish_distance() -> float:
	var sum := 0.0
	for c in _x.size():
		var d := _s[c] * (_w[c] - _x[c])
		sum += d * d
	return sqrt(sum)


## _r and _jv are never written in place (each evaluation makes new ones), so only x is copied.
func _save() -> Array:
	return [_x.duplicate(), _r, _jac_ok, _jv]


func _restore(saved: Array) -> void:
	_x = (saved[0] as PackedFloat64Array).duplicate()
	_r = saved[1]
	_jac_ok = saved[2]
	_jv = saved[3]


# ---- 7.1: the minimum-norm step (scaled), and 9: Gaussian elimination with partial pivoting ------

## uniform: every s_c = 1 (the rescue's metric, 7.3.1); reuse_jac: keep _jv as it is (the rescue's second-order
## correction pairs the SAVED point's Jacobian with the trial point's residual values).
func _step(y0: PackedFloat64Array, uniform := false, reuse_jac := false) -> PackedFloat64Array:
	if not reuse_jac:
		_ensure_jac()
	var m := _m
	var nnz := _jcol.size()
	var A := PackedFloat64Array() # A = J S⁻¹
	A.resize(nnz)
	for e in nnz:
		A[e] = _jv[e] if uniform else _jv[e] / _s[_jcol[e]]
	var M := PackedFloat64Array()
	M.resize(m * m)
	M.fill(0.0)
	for t in _pt.size():
		M[_pt[t]] += A[_pa[t]] * A[_pb[t]]
	var biggest := 0.0
	for i in m:
		biggest = maxf(biggest, M[i * m + i])
	var lam := LAMBDA_RELATIVE * biggest + LAMBDA_ABSOLUTE
	for i in m:
		M[i * m + i] += lam
	var rhs := PackedFloat64Array()
	rhs.resize(m)
	for i in m:
		var sum := _r[i]
		for e in range(_roff[i], _roff[i + 1]):
			sum += A[e] * y0[_jcol[e]]
		rhs[i] = sum
	var z := _solve(M, rhs, m, _bw)
	var y := y0.duplicate()
	for i in m:
		var zi := z[i]
		for e in range(_roff[i], _roff[i + 1]):
			y[_jcol[e]] -= A[e] * zi
	return y


## Gaussian elimination with partial pivoting (section 9). bw: M's half bandwidth (m - 1 = dense); the
## loops skip only entries that are exactly zero, so the answer is the dense elimination's.
static func _solve(M: PackedFloat64Array, b: PackedFloat64Array, m: int, bw: int = -1) -> PackedFloat64Array:
	if bw < 0 or bw > m - 1:
		bw = m - 1
	for col in m:
		var last_row := mini(m - 1, col + bw)
		var piv := col
		var best := absf(M[col * m + col])
		for r in range(col + 1, last_row + 1):
			var v := absf(M[r * m + col])
			if v > best:
				best = v
				piv = r
		if best == 0.0:
			continue
		var last_col := mini(m - 1, col + 2 * bw)
		if piv != col:
			for cc in range(col, last_col + 1):
				var t := M[col * m + cc]
				M[col * m + cc] = M[piv * m + cc]
				M[piv * m + cc] = t
			var tb := b[col]
			b[col] = b[piv]
			b[piv] = tb
		var d := M[col * m + col]
		for r in range(col + 1, last_row + 1):
			var f := M[r * m + col] / d
			if f == 0.0:
				continue
			for cc in range(col, last_col + 1):
				M[r * m + cc] -= f * M[col * m + cc]
			b[r] -= f * b[col]
	var z := PackedFloat64Array()
	z.resize(m)
	z.fill(0.0)
	for i in range(m - 1, -1, -1):
		var d := M[i * m + i]
		if d == 0.0:
			continue
		var sum := b[i]
		for j in range(i + 1, mini(m - 1, i + 2 * bw) + 1):
			sum -= M[i * m + j] * z[j]
		z[i] = sum / d
	return z


# ---- 7.2: one corrector (constraint-only Newton step, damped) ------------------------------------

func _corrector() -> bool:
	var zero := PackedFloat64Array()
	zero.resize(_x.size())
	zero.fill(0.0)
	var y := _step(zero)
	var before := _sq_norm()
	var saved := _save()
	var base: PackedFloat64Array = saved[0]
	var alpha := 1.0
	for h in CORRECTOR_HALVINGS:
		for c in _x.size():
			_x[c] = base[c] + alpha * y[c] / _s[c]
		_evaluate(false)
		if _sq_norm() < before:
			iterations += 1
			return true
		alpha *= 0.5
	_restore(saved)
	return false


# ---- 7.3.1: the rescue step (a singular start; F6) -----------------------------------------------

## Retries a rejected attempt from `saved` (the caller restores nothing: this does). True when the rescued x is accepted.
func _rescue(saved: Array, f: float, n0: float, radius: float, tau: float, scale1: float) -> bool:
	var nv := _x.size()
	_restore(saved)
	_ensure_jac()
	var jv_saved := _jv
	var base := _x.duplicate()
	var pull := PackedFloat64Array()
	pull.resize(nv)
	for c in nv:
		pull[c] = _w[c] - base[c]
	var u := _step(pull, true)
	var big := 0.0
	for c in nv:
		big = maxf(big, absf(u[c]))
	if big < ARRIVED * scale1:
		return false
	var cap: float = radius / (big * f) if big * f > radius else 1.0
	for c in nv:
		_x[c] = base[c] + f * cap * u[c]
	_evaluate(false)
	_jv = jv_saved
	var zero := PackedFloat64Array()
	zero.resize(nv)
	zero.fill(0.0)
	var v := _step(zero, true, true)
	var t := _x.duplicate()
	for c in nv:
		_x[c] = t[c] + v[c]
	_evaluate(false)
	iterations += 1
	var corr := 0
	while corr < CORRECTORS and _inf_norm() > tau:
		corr += 1
		if not _corrector():
			break
	return _inf_norm() <= tau and _wish_distance() < n0 * (1.0 - CLOSER_RATIO)


# ---- 7.3: the walk ---------------------------------------------------------------------------------

func _walk(diag: float, tau: float) -> Dictionary:
	iterations = 0
	var walks := 0
	var rejected := 0
	var nv := _x.size()
	_evaluate(false)
	if _m == 0:
		_x = _w.duplicate()
	var polish := 0
	while polish < MAX_POLISH and _m > 0 and _inf_norm() > tau:
		polish += 1
		if not _corrector():
			break
	var trust: float = maxf(TRUST, TRUST_DIAGONAL * diag)
	var radius := trust
	var omega := 1.0
	var prev := PackedFloat64Array()
	var stalled := 0
	var exit := "limit"
	var scale1: float = maxf(1.0, diag)
	for step_no in NEAREST_MAX:
		if not (_m > 0 and _inf_norm() <= tau):
			break
		var n0 := _wish_distance()
		if n0 < tau:
			exit = "arrived"
			break
		var saved := _save()
		var base: PackedFloat64Array = saved[0]
		var pull := PackedFloat64Array()
		pull.resize(nv)
		for c in nv:
			pull[c] = _s[c] * (_w[c] - _x[c])
		var y := _step(pull)
		var dx := PackedFloat64Array()
		dx.resize(nv)
		var big := 0.0
		for c in nv:
			dx[c] = y[c] / _s[c]
			big = maxf(big, absf(dx[c]))
		if big < ARRIVED * scale1:
			exit = "arrived"
			break
		var boost := 1.0
		if not prev.is_empty():
			var num := 0.0
			var den := 0.0
			for c in nv:
				num += dx[c] * prev[c]
				den += prev[c] * prev[c]
			var rho := num / den if den != 0.0 else 0.0
			if rho < RHO_REVERSE:
				omega = maxf(MIN_OMEGA, omega / 2.0)
			if rho > RHO_BOOST_LOW and rho < RHO_BOOST_HIGH:
				boost = minf(MAX_BOOST, 1.0 / (1.0 - rho))
		var infeasible := false
		var accepted := false
		var factors := [omega * boost, omega] if boost > 1.0 else [omega]
		for f in factors:
			var cap: float = radius / (big * f) if big * f > radius else 1.0
			for c in nv:
				_x[c] = base[c] + f * cap * dx[c]
			_evaluate(false)
			iterations += 1
			var corr := 0
			while corr < CORRECTORS and _inf_norm() > tau:
				corr += 1
				if not _corrector():
					break
			if _inf_norm() <= tau and _wish_distance() < n0 * (1.0 - CLOSER_RATIO):
				accepted = true
				break
			if _inf_norm() > tau:
				infeasible = true
			if walks == 0 and _rescue(saved, f, n0, radius, tau, scale1):
				accepted = true
				break
			_restore(saved)
		if not accepted:
			prev = PackedFloat64Array()
			rejected += 1
			if infeasible:
				radius /= 2.0
				stalled += 1
				if stalled > STALL_LIMIT:
					exit = "stalled"
					break
			else:
				omega /= 2.0
				if omega < MIN_OMEGA:
					exit = "arrived"
					break
			continue
		walks += 1
		stalled = 0
		radius = minf(trust, 2.0 * radius)
		prev = PackedFloat64Array()
		prev.resize(nv)
		var moved := 0.0
		for c in nv:
			prev[c] = _x[c] - base[c]
			moved = maxf(moved, absf(prev[c]))
		if moved < ARRIVED * scale1 or _wish_distance() < tau:
			exit = "arrived"
			break
	if _m > 0:
		_evaluate(false)
	return {"exit": exit, "walks": walks, "rejected": rejected}
