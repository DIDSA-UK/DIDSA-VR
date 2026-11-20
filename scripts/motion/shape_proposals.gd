extends RefCounted
## Dragging a closed-form shape's point (parity follow-ups F8), written from DIDSA-CAD's docs/motion/sketch-projector-spec.md section 13 (not from the Dart): where
## should EVERY point of a rigid, regular shape go when one of its points follows the hand? A circle's rim drag resizes it and keeps the centre, a rectangle's corner
## drag keeps the opposite corner, a centre drag translates. The projector (sketch_projector.gd) then only clamps that proposal to the user's constraints (13.4).
## Pinned against DIDSA-CAD's docs/motion/sketch-shape-vectors.json by tests/sketch_shape_vectors.gd. No scene tree, no network.
##
##   locate(records, points, exists, point_id)           -> {id, kind, rec, role: {r, i, s}} of the intact shape the point belongs to (13.1), or {}
##   proposal(shape, grabbed, P, T, constraints, records) -> id -> [x, y] for the shape's points, or null (nothing moves this frame)
##   is_hybrid(shape, constraints, records)               -> a user constraint touches the shape (13.4), decided once at the grab
##   provisional_for(shape, constraints, P, proposal)     -> constraint id -> value for the shape's provisional sizes (13.4)
##   grab_refusal(shape, constraints)                     -> "" or why the grab is refused by a confirmed size (13.3, the part that needs no rigidity)
##
## records: id -> the backend's entity dictionary plus "kind" (circle, arc, ellipse, ellipse_arc, rectangle, polygon, slot); points: id -> [x, y] (64-bit floats;
## the vectors' tolerance is below a Vector2's precision); exists: id -> true for every line and arc of the sketch (intactness); P: the current positions.

const SketchProjector := preload("res://scripts/motion/sketch_projector.gd")
const ORDER := ["polygon", "slot", "circle", "arc", "ellipse", "ellipse_arc", "rectangle"]
const EPS := 1e-9
const CIRCLE_ANGLES := [PI / 2.0, 0.0, 3.0 * PI / 2.0, PI] ## cardinal N, E, S, W


# ---- 13.1: membership -------------------------------------------------------------------------------

static func _s(rec: Dictionary, key: String) -> String:
	var v: Variant = rec.get(key)
	return "" if v == null else str(v)


static func _list(rec: Dictionary, key: String) -> Array:
	var out: Array = []
	var v: Variant = rec.get(key)
	if v is Array:
		for e in v:
			if e != null and str(e) != "":
				out.append(str(e))
	return out


static func _role(r: String, i := -1, s := 1) -> Dictionary:
	return {"r": r, "i": i, "s": s}


static func role_in(kind: String, rec: Dictionary, pid: String) -> Dictionary:
	## The role `pid` has in the record (centre, vertex i, corner i, ...), or {} when the record does not name it among its grabbable points.
	var centre := _s(rec, "center_point_id")
	match kind:
		"polygon":
			if pid == centre:
				return _role("centre")
			var vi := _list(rec, "vertex_point_ids").find(pid)
			return _role("vertex", vi) if vi >= 0 else {}
		"slot":
			if pid == _s(rec, "center1_point_id"):
				return _role("centre1")
			if pid == _s(rec, "center2_point_id"):
				return _role("centre2")
			var ci := [_s(rec, "a_point_id"), _s(rec, "b_point_id"), _s(rec, "c_point_id"), _s(rec, "d_point_id")].find(pid)
			return _role("corner", ci) if ci >= 0 else {}
		"circle":
			if pid == centre:
				return _role("centre")
			var ki := _list(rec, "cardinal_point_ids").find(pid)
			if ki >= 0:
				return _role("rim", ki)
			return _role("rim", -1) if pid == _s(rec, "radius_point_id") else {}
		"arc":
			if pid == centre:
				return _role("centre")
			if pid == _s(rec, "start_point_id"):
				return _role("end", 0)
			return _role("end", 1) if pid == _s(rec, "end_point_id") else {}
		"ellipse":
			if pid == centre:
				return _role("centre")
			if pid == _s(rec, "major_point_id"):
				return _role("major", 0, 1)
			if pid != "" and pid == _s(rec, "major_point_neg_id"):
				return _role("major", 1, -1)
			if pid == _s(rec, "minor_point_id"):
				return _role("minor", 0, 1)
			return _role("minor", 1, -1) if pid != "" and pid == _s(rec, "minor_point_neg_id") else {}
		"ellipse_arc":
			if pid == centre:
				return _role("centre")
			if pid == _s(rec, "major_point_id"):
				return _role("major", 0, 1)
			if pid == _s(rec, "minor_point_id"):
				return _role("minor", 0, 1)
			if pid == _s(rec, "start_point_id"):
				return _role("end", 0)
			return _role("end", 1) if pid == _s(rec, "end_point_id") else {}
		"rectangle":
			if pid != "" and pid == centre:
				return _role("centre")
			var ri := _list(rec, "corner_point_ids").find(pid)
			return _role("corner", ri) if ri >= 0 else {}
	return {}


static func _point_keys(kind: String, rec: Dictionary) -> Array:
	## Every point id the record names (they must all still exist).
	var out: Array = []
	match kind:
		"polygon":
			out = _list(rec, "vertex_point_ids") + [_s(rec, "center_point_id")]
		"slot":
			for k in ["center1_point_id", "center2_point_id", "a_point_id", "b_point_id", "c_point_id", "d_point_id"]:
				out.append(_s(rec, k))
		"circle":
			out = _list(rec, "cardinal_point_ids") + [_s(rec, "center_point_id"), _s(rec, "radius_point_id")]
		"arc":
			out = [_s(rec, "center_point_id"), _s(rec, "start_point_id"), _s(rec, "end_point_id")]
		"ellipse":
			for k in ["center_point_id", "major_point_id", "major_point_neg_id", "minor_point_id", "minor_point_neg_id"]:
				out.append(_s(rec, k))
		"ellipse_arc":
			for k in ["center_point_id", "major_point_id", "minor_point_id", "start_point_id", "end_point_id"]:
				out.append(_s(rec, k))
		"rectangle":
			out = _list(rec, "corner_point_ids") + [_s(rec, "center_point_id")]
	return out.filter(func(id: Variant) -> bool: return str(id) != "")


static func _entity_keys(kind: String, rec: Dictionary) -> Array:
	## The line (and slot arc) ids the intact test needs.
	var out: Array = []
	match kind:
		"polygon":
			out = _list(rec, "line_ids")
		"slot":
			for k in ["centerline_id", "line1_id", "line2_id", "arc1_id", "arc2_id"]:
				out.append(_s(rec, k))
		"ellipse", "ellipse_arc":
			out = [_s(rec, "major_axis_line_id"), _s(rec, "minor_axis_line_id")]
		"rectangle":
			out = _list(rec, "line_ids") + [_s(rec, "diagonal_line_id")]
	return out.filter(func(id: Variant) -> bool: return str(id) != "")


static func intact(kind: String, rec: Dictionary, points: Dictionary, exists: Dictionary) -> bool:
	if kind == "rectangle" and (not bool(rec.get("axis_aligned", false)) or _s(rec, "center_point_id") == "" or _s(rec, "diagonal_line_id") == ""):
		return false
	for id in _point_keys(kind, rec):
		if not points.has(id):
			return false
	for id in _entity_keys(kind, rec):
		if not exists.has(id):
			return false
	return true


static func locate(records: Dictionary, points: Dictionary, exists: Dictionary, pid: String) -> Dictionary:
	## The first family (ORDER) whose record names the point decides; a shape that is not intact makes it a plain point.
	for kind in ORDER:
		for sid in records:
			var rec: Dictionary = records[sid]
			if str(rec.get("kind", "")) != kind:
				continue
			var role := role_in(kind, rec, pid)
			if role.is_empty():
				continue
			if not intact(kind, rec, points, exists):
				return {}
			return {"id": str(sid), "kind": kind, "rec": rec, "role": role}
	return {}


# ---- confirmed sizes (13.1) ---------------------------------------------------------------------------

static func confirmed(constraints: Array, a: String, b: String) -> Variant:
	## The value of the first `distance` constraint a -> b when it is not provisional, else null.
	for c: Dictionary in constraints:
		if str(c.get("type", "")) == "distance" and str(c.get("point_a_id", "")) == a and str(c.get("point_b_id", "")) == b:
			return null if bool(c.get("provisional", false)) else float(c.get("distance", 0.0))
	return null


static func _confirmed_polygon(rec: Dictionary, constraints: Array, records: Dictionary) -> Variant:
	## The circumradius: a non-provisional centre -> vertex 0 distance first, else through the inscribed circle (r / cos(pi / sides)).
	var verts := _list(rec, "vertex_point_ids")
	var centre := _s(rec, "center_point_id")
	if not verts.is_empty():
		for c: Dictionary in constraints:
			if str(c.get("type", "")) == "distance" and str(c.get("point_a_id", "")) == centre and str(c.get("point_b_id", "")) == verts[0] and not bool(c.get("provisional", false)):
				return float(c.get("distance", 0.0))
	var circle: Dictionary = records.get(_s(rec, "inscribed_circle_id"), {})
	if not circle.is_empty():
		var r: Variant = confirmed(constraints, _s(circle, "center_point_id"), _s(circle, "radius_point_id"))
		if r != null:
			return float(r) / cos(PI / float(_sides(rec)))
	return null


static func _sides(rec: Dictionary) -> int:
	var n := int(rec.get("sides", 0))
	return n if n > 0 else _list(rec, "vertex_point_ids").size()


static func size_of(shape: Dictionary, which: String, constraints: Array, records: Dictionary) -> Variant:
	## which: radius (circle / arc / slot), major, minor, circum. null = not confirmed.
	var rec: Dictionary = shape["rec"]
	match str(shape["kind"]):
		"circle":
			return confirmed(constraints, _s(rec, "center_point_id"), _s(rec, "radius_point_id"))
		"arc":
			return confirmed(constraints, _s(rec, "center_point_id"), _s(rec, "start_point_id"))
		"slot":
			return confirmed(constraints, _s(rec, "center1_point_id"), _s(rec, "a_point_id"))
		"ellipse", "ellipse_arc":
			return confirmed(constraints, _s(rec, "center_point_id"), _s(rec, "major_point_id" if which == "major" else "minor_point_id"))
		"polygon":
			return _confirmed_polygon(rec, constraints, records)
	return null


static func grab_refusal(shape: Dictionary, constraints: Array, records: Dictionary) -> String:
	## 13.3 / 13.5 step 3, the refusals a confirmed size makes by itself.
	var kind: String = shape["kind"]
	var role: Dictionary = shape["role"]
	if kind == "slot" and role["r"] == "corner" and size_of(shape, "radius", constraints, records) != null:
		return "That slot's width is dimensioned: its corners do not move."
	if kind in ["ellipse", "ellipse_arc"] and role["r"] == "minor" and size_of(shape, "minor", constraints, records) != null:
		return "That ellipse's minor radius is dimensioned: this point does not move."
	return ""


# ---- 13.2: the proposals ----------------------------------------------------------------------------

static func _p(P: Dictionary, id: String) -> Array:
	return P[id]


static func _translate(ids: Array, P: Dictionary, d: Array, out: Dictionary) -> void:
	for id in ids:
		if id != "" and P.has(id):
			var p: Array = P[id]
			out[id] = [p[0] + d[0], p[1] + d[1]]


static func _on_ray(C: Array, old: Array, rho: float) -> Array:
	## The point on the ray from C through `old` at distance rho (C + (rho, 0) when old sits on C).
	var dx: float = old[0] - C[0]
	var dy: float = old[1] - C[1]
	var l := sqrt(dx * dx + dy * dy)
	if l < EPS:
		return [C[0] + rho, C[1]]
	return [C[0] + dx / l * rho, C[1] + dy / l * rho]


static func _at(C: Array, r: float, ang: float) -> Array:
	return [C[0] + r * cos(ang), C[1] + r * sin(ang)]


static func _rot(v: Array, ang: float) -> Array:
	var c := cos(ang)
	var s := sin(ang)
	return [v[0] * c - v[1] * s, v[0] * s + v[1] * c]


static func _angle(a: Array, b: Array) -> float:
	## The angle of b - a.
	return atan2(b[1] - a[1], b[0] - a[0])


static func _dist(a: Array, b: Array) -> float:
	return sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]))


static func proposal(shape: Dictionary, grabbed: String, P: Dictionary, T: Array, constraints: Array, records: Dictionary) -> Variant:
	var kind: String = shape["kind"]
	var rec: Dictionary = shape["rec"]
	var role: Dictionary = shape["role"]
	var out := {}
	var r: String = role["r"]
	if r == "centre" and kind != "slot":
		var cid := _s(rec, "center_point_id")
		var d := [T[0] - P[cid][0], T[1] - P[cid][1]]
		return _centre_translate(kind, rec, P, d, out)
	match kind:
		"circle":
			return _circle(rec, role, grabbed, P, T, constraints, shape, records, out)
		"arc":
			return _arc(rec, role, grabbed, P, T, constraints, shape, records, out)
		"ellipse":
			return _ellipse(rec, role, P, T, constraints, shape, records, out)
		"ellipse_arc":
			return _ellipse_arc(rec, role, P, T, constraints, shape, records, out)
		"rectangle":
			return _rectangle(rec, role, P, T, out)
		"polygon":
			return _polygon(rec, role, P, T, constraints, records, out)
		"slot":
			return _slot(rec, role, P, T, out)
	return null


static func _centre_translate(kind: String, rec: Dictionary, P: Dictionary, d: Array, out: Dictionary) -> Dictionary:
	var cid := _s(rec, "center_point_id")
	out[cid] = [P[cid][0] + d[0], P[cid][1] + d[1]]
	var others: Array = []
	match kind:
		"circle":
			others = [_s(rec, "radius_point_id")] + _list(rec, "cardinal_point_ids")
		"arc":
			others = [_s(rec, "start_point_id"), _s(rec, "end_point_id")]
		"ellipse":
			others = [_s(rec, "major_point_id"), _s(rec, "major_point_neg_id"), _s(rec, "minor_point_id"), _s(rec, "minor_point_neg_id")]
		"ellipse_arc":
			others = [_s(rec, "major_point_id"), _s(rec, "minor_point_id"), _s(rec, "start_point_id"), _s(rec, "end_point_id")]
		"rectangle":
			others = _list(rec, "corner_point_ids")
		"polygon":
			others = _list(rec, "vertex_point_ids")
	_translate(others, P, d, out)
	return out


static func _circle(rec: Dictionary, role: Dictionary, grabbed: String, P: Dictionary, T: Array, constraints: Array, shape: Dictionary, records: Dictionary, out: Dictionary) -> Variant:
	var cid := _s(rec, "center_point_id")
	var C: Array = P[cid]
	if size_of(shape, "radius", constraints, records) != null:
		# a confirmed radius: the rim only carries the circle along (the centre drag with the centre's target C + (T - P(grabbed)))
		return _centre_translate("circle", rec, P, [T[0] - P[grabbed][0], T[1] - P[grabbed][1]], out)
	var cards := _list(rec, "cardinal_point_ids")
	var i: int = role["i"]
	var rho: float
	if i == 0 or i == 2:
		rho = absf(T[1] - C[1])
	elif i == 1 or i == 3:
		rho = absf(T[0] - C[0])
	else:
		rho = _dist(C, T)
	if rho < EPS:
		return null
	for j in cards.size():
		out[cards[j]] = _at(C, rho, CIRCLE_ANGLES[j])
	var rp := _s(rec, "radius_point_id")
	if rp != "" and not cards.has(rp):
		out[rp] = [T[0], T[1]] if rp == grabbed else _on_ray(C, P[rp], rho)
	return out


static func _arc(rec: Dictionary, role: Dictionary, grabbed: String, P: Dictionary, T: Array, constraints: Array, shape: Dictionary, records: Dictionary, out: Dictionary) -> Variant:
	var C: Array = P[_s(rec, "center_point_id")]
	if size_of(shape, "radius", constraints, records) != null:
		return _centre_translate("arc", rec, P, [T[0] - P[grabbed][0], T[1] - P[grabbed][1]], out)
	var rho := _dist(C, T)
	if rho < EPS:
		return null
	var other := _s(rec, "end_point_id") if int(role["i"]) == 0 else _s(rec, "start_point_id")
	out[grabbed] = [T[0], T[1]]
	out[other] = _on_ray(C, P[other], rho)
	return out


static func _tips(rec: Dictionary, a: float, b: float, theta: float, C: Array, out: Dictionary) -> void:
	out[_s(rec, "major_point_id")] = _at(C, a, theta)
	if _s(rec, "major_point_neg_id") != "":
		out[_s(rec, "major_point_neg_id")] = _at(C, -a, theta)
	out[_s(rec, "minor_point_id")] = _at(C, b, theta + PI / 2.0)
	if _s(rec, "minor_point_neg_id") != "":
		out[_s(rec, "minor_point_neg_id")] = _at(C, -b, theta + PI / 2.0)


static func _ellipse(rec: Dictionary, role: Dictionary, P: Dictionary, T: Array, constraints: Array, shape: Dictionary, records: Dictionary, out: Dictionary) -> Variant:
	var C: Array = P[_s(rec, "center_point_id")]
	var sg: float = float(role["s"])
	var theta: float
	var a: float
	var b: float
	if role["r"] == "major":
		var u := [sg * (T[0] - C[0]), sg * (T[1] - C[1])]
		var rho := sqrt(u[0] * u[0] + u[1] * u[1])
		if rho < EPS:
			return null
		theta = atan2(u[1], u[0])
		var cm: Variant = size_of(shape, "major", constraints, records)
		a = float(cm) if cm != null else rho
		b = _dist(C, P[_s(rec, "minor_point_id")])
	else:
		a = _dist(C, P[_s(rec, "major_point_id")])
		if a < EPS:
			return null
		theta = _angle(C, P[_s(rec, "major_point_id")])
		var n := [cos(theta + PI / 2.0), sin(theta + PI / 2.0)]
		b = absf(sg * ((T[0] - C[0]) * n[0] + (T[1] - C[1]) * n[1]))
	if b < EPS:
		return null
	_tips(rec, a, b, theta, C, out)
	return out


static func _param(p: Array, C: Array, r: float, a0: float, b0: float) -> float:
	var q := _rot([p[0] - C[0], p[1] - C[1]], -r)
	return atan2(q[1] / b0, q[0] / a0)


static func _ell(t: float, C: Array, r: float, a: float, b: float) -> Array:
	var v := _rot([a * cos(t), b * sin(t)], r)
	return [C[0] + v[0], C[1] + v[1]]


static func _ellipse_arc(rec: Dictionary, role: Dictionary, P: Dictionary, T: Array, constraints: Array, shape: Dictionary, records: Dictionary, out: Dictionary) -> Variant:
	var C: Array = P[_s(rec, "center_point_id")]
	var M: Array = P[_s(rec, "major_point_id")]
	var a0 := _dist(C, M)
	var b0 := _dist(C, P[_s(rec, "minor_point_id")])
	var r0 := _angle(C, M)
	var sid := _s(rec, "start_point_id")
	var eid := _s(rec, "end_point_id")
	if role["r"] == "end":
		if b0 < EPS or a0 < EPS:
			return null
		var id := sid if int(role["i"]) == 0 else eid
		out[id] = _ell(_param(T, C, r0, a0, b0), C, r0, a0, b0)
		return out
	var theta: float
	var a: float
	var b: float
	if role["r"] == "major":
		var rho := _dist(C, T)
		if rho < EPS:
			return null
		theta = _angle(C, T)
		var cm: Variant = size_of(shape, "major", constraints, records)
		a = float(cm) if cm != null else maxf(rho, b0)
		b = b0
	else:
		if a0 < EPS:
			return null
		theta = r0
		a = a0
		b = minf(absf((T[0] - C[0]) * cos(theta + PI / 2.0) + (T[1] - C[1]) * sin(theta + PI / 2.0)), a0)
	if b < EPS:
		return null
	out[_s(rec, "major_point_id")] = _at(C, a, theta)
	out[_s(rec, "minor_point_id")] = _at(C, b, theta + PI / 2.0)
	if b0 >= EPS and a0 >= EPS:
		out[sid] = _ell(_param(P[sid], C, r0, a0, b0), C, theta, a, b)
		out[eid] = _ell(_param(P[eid], C, r0, a0, b0), C, theta, a, b)
	return out


static func _rectangle(rec: Dictionary, role: Dictionary, P: Dictionary, T: Array, out: Dictionary) -> Variant:
	var ks := _list(rec, "corner_point_ids")
	var i: int = role["i"]
	var O: Array = P[ks[(i + 2) % 4]]
	out[ks[i]] = [T[0], T[1]]
	if i % 2 == 0:
		out[ks[(i + 1) % 4]] = [O[0], T[1]]
		out[ks[(i + 3) % 4]] = [T[0], O[1]]
	else:
		out[ks[(i + 1) % 4]] = [T[0], O[1]]
		out[ks[(i + 3) % 4]] = [O[0], T[1]]
	out[_s(rec, "center_point_id")] = [(T[0] + O[0]) / 2.0, (T[1] + O[1]) / 2.0]
	return out


static func _polygon(rec: Dictionary, role: Dictionary, P: Dictionary, T: Array, constraints: Array, records: Dictionary, out: Dictionary) -> Variant:
	var C: Array = P[_s(rec, "center_point_id")]
	var vs := _list(rec, "vertex_point_ids")
	var n := _sides(rec)
	var d := [T[0] - C[0], T[1] - C[1]]
	var dl := sqrt(d[0] * d[0] + d[1] * d[1])
	if dl < EPS:
		return null
	var cm: Variant = _confirmed_polygon(rec, constraints, records)
	var R: float = float(cm) if cm != null else dl
	var beta := atan2(d[1], d[0]) - TAU * float(role["i"]) / float(n)
	for j in vs.size():
		out[vs[j]] = _at(C, R, beta + TAU * float(j) / float(n))
	var circle: Dictionary = records.get(_s(rec, "inscribed_circle_id"), {})
	if not circle.is_empty() and P.has(_s(circle, "radius_point_id")):
		var rin: Variant = confirmed(constraints, _s(circle, "center_point_id"), _s(circle, "radius_point_id"))
		out[_s(circle, "radius_point_id")] = _at(C, float(rin) if rin != null else R * cos(PI / float(n)), beta + PI / float(n))
	return out


static func _slot(rec: Dictionary, role: Dictionary, P: Dictionary, T: Array, out: Dictionary) -> Variant:
	var i1 := _s(rec, "center1_point_id")
	var i2 := _s(rec, "center2_point_id")
	var c1: Array = P[i1]
	var c2: Array = P[i2]
	var rho: float
	match str(role["r"]):
		"centre1":
			c1 = [T[0], T[1]]
			rho = _dist(P[_s(rec, "a_point_id")], P[i1])
		"centre2":
			c2 = [T[0], T[1]]
			rho = _dist(P[_s(rec, "a_point_id")], P[i1])
		_:
			var dx: float = c2[0] - c1[0]
			var dy: float = c2[1] - c1[1]
			var l := sqrt(dx * dx + dy * dy)
			if l < EPS:
				return null
			rho = absf((T[0] - c1[0]) * dy - (T[1] - c1[1]) * dx) / l
	var ex: float = c2[0] - c1[0]
	var ey: float = c2[1] - c1[1]
	var len := sqrt(ex * ex + ey * ey)
	if len < EPS or rho < EPS:
		return null
	var nx := -ey / len
	var ny := ex / len
	out[i1] = c1
	out[i2] = c2
	out[_s(rec, "a_point_id")] = [c1[0] + rho * nx, c1[1] + rho * ny]
	out[_s(rec, "b_point_id")] = [c1[0] - rho * nx, c1[1] - rho * ny]
	out[_s(rec, "c_point_id")] = [c2[0] - rho * nx, c2[1] - rho * ny]
	out[_s(rec, "d_point_id")] = [c2[0] + rho * nx, c2[1] + rho * ny]
	return out


# ---- 13.4: plain or hybrid -----------------------------------------------------------------------------

static func touch_set(shape: Dictionary, records: Dictionary) -> Dictionary:
	## {points: id -> true, lines: id -> true}: what a user constraint must name to make the drag hybrid.
	var kind: String = shape["kind"]
	var rec: Dictionary = shape["rec"]
	var is_centre: bool = str(shape["role"]["r"]) in ["centre", "centre1", "centre2"]
	var pts: Array = []
	var lns: Array = []
	match kind:
		"polygon":
			pts = _list(rec, "vertex_point_ids")
			for k in ["inscribed_circle_id", "circumscribed_circle_id"]:
				var circle: Dictionary = records.get(_s(rec, k), {})
				if not circle.is_empty():
					pts += [_s(circle, "radius_point_id")] + _list(circle, "cardinal_point_ids")
			if is_centre:
				pts.append(_s(rec, "center_point_id"))
			lns = _list(rec, "line_ids") + _list(rec, "radial_line_ids")
		"slot":
			pts = [_s(rec, "a_point_id"), _s(rec, "b_point_id"), _s(rec, "c_point_id"), _s(rec, "d_point_id")]
			lns = [_s(rec, "line1_id"), _s(rec, "line2_id")]
			if is_centre:
				pts += [_s(rec, "center1_point_id"), _s(rec, "center2_point_id")]
				lns.append(_s(rec, "centerline_id"))
		"circle":
			pts = [_s(rec, "radius_point_id")] + _list(rec, "cardinal_point_ids")
		"arc":
			pts = [_s(rec, "start_point_id"), _s(rec, "end_point_id")]
		"ellipse":
			pts = [_s(rec, "major_point_id"), _s(rec, "major_point_neg_id"), _s(rec, "minor_point_id"), _s(rec, "minor_point_neg_id")]
			lns = [_s(rec, "major_axis_line_id"), _s(rec, "minor_axis_line_id")]
		"ellipse_arc":
			pts = [_s(rec, "major_point_id"), _s(rec, "minor_point_id"), _s(rec, "start_point_id"), _s(rec, "end_point_id")]
			lns = [_s(rec, "major_axis_line_id"), _s(rec, "minor_axis_line_id")]
		"rectangle":
			pts = _list(rec, "corner_point_ids") + [_s(rec, "center_point_id")]
			lns = _list(rec, "line_ids") + [_s(rec, "diagonal_line_id"), _s(rec, "diagonal2_line_id")]
	if is_centre and kind in ["circle", "arc", "ellipse", "ellipse_arc"]:
		pts.append(_s(rec, "center_point_id"))
	var out := {"points": {}, "lines": {}}
	for id in pts:
		if str(id) != "":
			out["points"][str(id)] = true
	for id in lns:
		if str(id) != "":
			out["lines"][str(id)] = true
	return out


static func is_hybrid(shape: Dictionary, constraints: Array, records: Dictionary) -> bool:
	## A user constraint: its id is not among the shape's structural ones and it names a touch-set point or line.
	var rec: Dictionary = shape["rec"]
	if not rec.has("structural_constraint_ids"):
		return false # the structural ids are unknown: plain
	var structural := _list(rec, "structural_constraint_ids")
	var touch := touch_set(shape, records)
	for c: Dictionary in constraints:
		if str(c.get("id", "")) in structural:
			continue
		for key in c:
			if key == "id" or key == "type":
				continue
			var v: Variant = c[key]
			if v is String and (touch["points"].has(v) or touch["lines"].has(v)):
				return true
			if v is Array:
				for e in v:
					if e is String and (touch["points"].has(e) or touch["lines"].has(e)):
						return true
	return false


static func provisional_for(shape: Dictionary, constraints: Array, P: Dictionary, prop: Dictionary) -> Dictionary:
	## constraint id -> |B - A| for each provisional distance among the shape's structural constraints, A and B at their proposed positions.
	var out := {}
	var structural := _list(shape["rec"], "structural_constraint_ids")
	for c: Dictionary in constraints:
		if str(c.get("type", "")) != "distance" or not bool(c.get("provisional", false)) or not (str(c.get("id", "")) in structural):
			continue
		var a := str(c.get("point_a_id", ""))
		var b := str(c.get("point_b_id", ""))
		var pa: Variant = prop.get(a, P.get(a))
		var pb: Variant = prop.get(b, P.get(b))
		if pa != null and pb != null:
			out[str(c["id"])] = _dist(pa, pb)
	return out


# ---- one frame (13.1 "One frame", 13.4) ------------------------------------------------------------------

static func frame(shape: Dictionary, grabbed: String, P: Dictionary, T: Array, constraints: Array, lines: Dictionary, pinned: Array, records: Dictionary,
		hybrid: bool, provisional: Variant = null) -> Dictionary:
	## The proposal for target T from the current positions P; plain: written back as it is; hybrid: clamped by one projector call. Returns {proposal (null = none), hybrid,
	## provisional, clamp: none | accepted | rejected | unsupported, result: id -> [x, y] to write back (empty when nothing moves this frame)}. `provisional` overrides the
	## computed sizes (the vectors replay the file's). Not applied: the flat app's two guards (a non-anchor point flung further than max(10 D, 100) from the seed, an arc
	## whose centre flips across its chord), which no vector reaches.
	var out := {"proposal": null, "hybrid": hybrid, "provisional": {}, "clamp": "none", "result": {}}
	var prop: Variant = proposal(shape, grabbed, P, T, constraints, records)
	if prop == null:
		return out
	out["proposal"] = prop
	if not hybrid:
		out["result"] = (prop as Dictionary).duplicate()
		return out
	var prov: Dictionary = provisional if provisional is Dictionary else provisional_for(shape, constraints, P, prop)
	out["provisional"] = prov
	var pts: Dictionary = P.duplicate()
	for id in prop:
		pts[id] = prop[id]
	var res: Dictionary = SketchProjector.project(pts, constraints, lines, [grabbed], pinned, (prop as Dictionary).keys(), P, prov)
	if bool(res["unsupported"]):
		out["clamp"] = "unsupported"
		out["result"] = (prop as Dictionary).duplicate() # a spline tangency in the group: unclamped, the drop's backend solve settles it
		return out
	if not bool(res["converged"]):
		out["clamp"] = "rejected"
		return out
	var written: Dictionary = (res["points"] as Dictionary).duplicate()
	for id in prop:
		if not written.has(id):
			written[id] = prop[id]
	out["clamp"] = "accepted"
	out["result"] = written
	return out
