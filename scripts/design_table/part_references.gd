extends RefCounted
## The part's own vertices and edges, projected onto the sketch plane: the geometry a sketch is dimensioned TO and drawn FROM. Pure
## maths over the `topology` meta the table's copy carries (body id -> {edges: {index: PackedVector3Array segment pairs},
## edge_kinds, vertices: {index: Vector3}, vertex_at}, all in the part's frame, mm), so it is unit-tested without a scene.
##
## Because the sketch and the part are one thing on the table (sketch mm = part mm, always), a vertex or edge here sits exactly
## where it is drawn on the sheet. Nothing needs converting, fixing or marking as construction first: the sketch session turns
## whatever you aim at into a pinned reference point or line on demand (sketch_session.gd: ensure_reference).
##
## Several vertices or edges can project onto the same spot (a box's top and bottom corners seen from above); the one nearest the
## plane is kept, so the corners of the face you sketch on win. Look-ups go through a coarse grid built once, so aiming at a part
## with thousands of edge segments costs the same as aiming at a box.

const SELF := "res://scripts/design_table/part_references.gd"

## A circular edge lies "in the plane" (a hole or boss on the face you are sketching on) when every point of it is this close to the plane, mm: the backend
## only turns such an edge into a circle or arc of the sketch (plane_geometry.resolve_planar_circle uses 1e-4); a circle in a parallel plane, or a tilted one
## (an ellipse seen along the normal), is drawn as a quiet reference but cannot be picked.
const COPLANAR_MM := 0.001

var vertices: Array = [] ## [{body, index, uv, depth}] (depth: distance off the plane, mm)
var edges: Array = [] ## [{body, index, kind, segs (PackedVector2Array of segment pairs), a, b, a_vertex, b_vertex, depth, lo, hi, circle}]
var circles: Array = [] ## the coplanar circular edges, indices into `edges` ({circle: {c, r, full}} is on the entry itself): what a hole or boss is
var faces: Array = [] ## the faces the sketch can point at without a rim of theirs in the plane: [{body, index, kind ("face_line" | "face_axis"), a, b (a flat face seen edge-on: its ends) | c, r (a round face with its axis square to the plane: the axis point), depth}]

var _cell := 10.0
var _vertex_grid := {} ## Vector2i -> Array of indices into `vertices`
var _edge_grid := {} ## Vector2i -> Array of indices into `edges`


static func build(topology: Dictionary, plane: Dictionary) -> RefCounted:
	var refs: RefCounted = (load(SELF) as GDScript).new()
	refs._build(topology, plane)
	return refs


func is_empty() -> bool:
	return vertices.is_empty() and edges.is_empty() and faces.is_empty()


func _build(topology: Dictionary, plane: Dictionary) -> void:
	var origin: Vector3 = plane["origin"]
	var normal: Vector3 = plane["n"]
	var seen_vertices := {}
	var seen_edges := {}
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for body_id in topology:
		var body: Dictionary = topology[body_id]
		var body_vertices: Dictionary = body.get("vertices", {})
		var vertex_at: Dictionary = body.get("vertex_at", {})
		for index in body_vertices:
			var p: Vector3 = body_vertices[index]
			var uv := _to_uv(p, plane)
			var depth := absf((p - origin).dot(normal))
			var key := _key(uv)
			if seen_vertices.has(key):
				var kept: Dictionary = vertices[seen_vertices[key]]
				if depth < float(kept["depth"]) - 0.0001:
					kept["body"] = str(body_id)
					kept["index"] = int(index)
					kept["depth"] = depth
				continue
			seen_vertices[key] = vertices.size()
			vertices.append({"body": str(body_id), "index": int(index), "uv": uv, "depth": depth})
			lo = lo.min(uv)
			hi = hi.max(uv)
		var body_edges: Dictionary = body.get("edges", {})
		var kinds: Dictionary = body.get("edge_kinds", {})
		for index in body_edges:
			var pts: PackedVector3Array = body_edges[index]
			if pts.size() < 2:
				continue
			var segs := PackedVector2Array()
			var elo := Vector2(INF, INF)
			var ehi := Vector2(-INF, -INF)
			var depth_sum := 0.0
			for p in pts:
				depth_sum += absf((p - origin).dot(normal))
			for i in range(0, pts.size() - 1, 2):
				var a := _to_uv(pts[i], plane)
				var b := _to_uv(pts[i + 1], plane)
				if a.distance_to(b) < 0.0001:
					continue
				segs.append(a)
				segs.append(b)
				elo = elo.min(a).min(b)
				ehi = ehi.max(a).max(b)
			if segs.is_empty():
				continue
			var first := _to_uv(pts[0], plane)
			var last := _to_uv(pts[pts.size() - 1], plane)
			var kind := str(kinds.get(index, "other"))
			var k1 := _key(first)
			var k2 := _key(last)
			var ekey := "%s|%s|%s" % [kind, k1 if k1 < k2 else k2, k2 if k1 < k2 else k1]
			var depth := depth_sum / float(pts.size())
			var entry := _edge(str(body_id), int(index), kind, segs, first, last, vertex_at, pts, depth, elo, ehi)
			if kind == "circle":
				entry["circle"] = _fit_circle(pts, plane)
			if seen_edges.has(ekey):
				if depth < float((edges[seen_edges[ekey]] as Dictionary)["depth"]) - 0.0001:
					edges[seen_edges[ekey]] = entry
				continue
			seen_edges[ekey] = edges.size()
			edges.append(entry)
			lo = lo.min(elo)
			hi = hi.max(ehi)
	for i in edges.size():
		if not ((edges[i] as Dictionary).get("circle", {}) as Dictionary).is_empty():
			circles.append(i)
	_build_faces(topology, plane)
	if lo.x == INF:
		return
	_cell = maxf(maxf(hi.x - lo.x, hi.y - lo.y) / 32.0, 1.0)
	for i in vertices.size():
		var vcell := _cell_of(vertices[i]["uv"])
		if not _vertex_grid.has(vcell):
			_vertex_grid[vcell] = []
		(_vertex_grid[vcell] as Array).append(i)
	for i in edges.size():
		var e: Dictionary = edges[i]
		var c0 := _cell_of(e["lo"])
		var c1 := _cell_of(e["hi"])
		for cx in range(c0.x, c1.x + 1):
			for cy in range(c0.y, c1.y + 1):
				var ecell := Vector2i(cx, cy)
				if not _edge_grid.has(ecell):
					_edge_grid[ecell] = []
				(_edge_grid[ecell] as Array).append(i)


## How far (mm) a face's boundary may stray from a straight line (a flat face seen edge-on) or from one circle (a round face with its axis square to the plane)
## and still count; the backend's own test is an angle of a degree.
const FACE_FIT_MM := 0.02
const FACE_MIN_MM := 0.5

func _build_faces(topology: Dictionary, plane: Dictionary) -> void:
	## A flat face standing square to the sketch plane is a line there; a cylinder with its axis square to it is a circle there, whose centre is the axis.
	## Both are read from the face's boundary edges alone (their points projected onto the plane), so no mesh is walked and a part with thousands of faces
	## costs a pass over its edges. Anything that does not fit stays out (a face at an angle, a cone, a cylinder seen sideways).
	var origin: Vector3 = plane["origin"]
	var normal: Vector3 = plane["n"]
	for body_id in topology:
		var body: Dictionary = topology[body_id]
		var face_edges: Array = body.get("face_edges", [])
		var kinds: Array = body.get("face_kinds", [])
		var body_edges: Dictionary = body.get("edges", {})
		for face_id in face_edges.size():
			var kind := str(kinds[face_id]) if face_id < kinds.size() else ""
			if kind != "plane" and kind != "cylinder":
				continue
			var uvs: Array = []
			var depth := INF
			for edge_index in (face_edges[face_id] as PackedInt32Array):
				for p in (body_edges.get(edge_index, PackedVector3Array()) as PackedVector3Array):
					uvs.append(_to_uv(p, plane))
					depth = minf(depth, absf((p - origin).dot(normal)))
			if uvs.size() < 2:
				continue
			var entry: Dictionary = _fit_flat_face(uvs) if kind == "plane" else _fit_round_face(uvs)
			if entry.is_empty():
				continue
			entry["body"] = str(body_id)
			entry["index"] = face_id
			entry["depth"] = depth
			faces.append(entry)


static func _fit_flat_face(uvs: Array) -> Dictionary:
	## {kind: "face_line", a, b} if every point lies on one line (and it has a length), else {}.
	var a: Vector2 = uvs[0]
	var far_a := a
	for uv in uvs:
		if a.distance_to(uv) > a.distance_to(far_a):
			far_a = uv
	var far_b := far_a
	for uv in uvs:
		if far_a.distance_to(uv) > far_a.distance_to(far_b):
			far_b = uv
	if far_a.distance_to(far_b) < FACE_MIN_MM:
		return {}
	for uv in uvs:
		var near := Geometry2D.get_closest_point_to_segment(uv, far_a, far_b)
		if uv.distance_to(near) > FACE_FIT_MM:
			return {}
	return {"kind": "face_line", "a": far_a, "b": far_b}


static func _fit_round_face(uvs: Array) -> Dictionary:
	## {kind: "face_axis", c, r} if every point lies on one circle (the projected rims of a cylinder whose axis is square to the plane), else {}.
	var n := uvs.size()
	var a: Vector2 = uvs[0]
	var b: Vector2 = uvs[n / 3]
	var c: Vector2 = uvs[(2 * n) / 3]
	var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
	if absf(d) < 0.000001:
		return {}
	var centre := Vector2(
		(a.length_squared() * (b.y - c.y) + b.length_squared() * (c.y - a.y) + c.length_squared() * (a.y - b.y)) / d,
		(a.length_squared() * (c.x - b.x) + b.length_squared() * (a.x - c.x) + c.length_squared() * (b.x - a.x)) / d)
	var radius := centre.distance_to(a)
	if radius < FACE_MIN_MM:
		return {}
	for uv in uvs:
		if absf(centre.distance_to(uv) - radius) > FACE_FIT_MM:
			return {}
	return {"kind": "face_axis", "c": centre, "r": radius}


static func _edge(body: String, index: int, kind: String, segs: PackedVector2Array, a: Vector2, b: Vector2, vertex_at: Dictionary, pts: PackedVector3Array, depth: float, lo: Vector2, hi: Vector2) -> Dictionary:
	return {"body": body, "index": index, "kind": kind, "segs": segs, "a": a, "b": b,
		"a_vertex": int(vertex_at.get(Vector3i((pts[0] * 100.0).round()), -1)),
		"b_vertex": int(vertex_at.get(Vector3i((pts[pts.size() - 1] * 100.0).round()), -1)),
		"depth": depth, "lo": lo, "hi": hi}


static func _fit_circle(pts: PackedVector3Array, plane: Dictionary) -> Dictionary:
	## {c (uv), r, full} for a circular edge that lies in the sketch plane, else {}: the circle through three well-spread points of the edge's polyline.
	## `full` is a whole circle (a hole's rim: the edge starts and ends at the same place), else an arc.
	var origin: Vector3 = plane["origin"]
	var normal: Vector3 = plane["n"]
	for p in pts:
		if absf((p - origin).dot(normal)) > COPLANAR_MM:
			return {}
	var poly: Array = [pts[0]]
	for i in range(1, pts.size(), 2):
		poly.append(pts[i])
	var n := poly.size()
	if n < 4:
		return {}
	var a := _to_uv(poly[0], plane)
	var b := _to_uv(poly[n / 3], plane)
	var c := _to_uv(poly[(2 * n) / 3], plane)
	var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
	if absf(d) < 0.000001:
		return {}
	var centre := Vector2(
		((a.length_squared()) * (b.y - c.y) + b.length_squared() * (c.y - a.y) + c.length_squared() * (a.y - b.y)) / d,
		((a.length_squared()) * (c.x - b.x) + b.length_squared() * (a.x - c.x) + c.length_squared() * (b.x - a.x)) / d)
	var radius := centre.distance_to(a)
	if radius < 0.001:
		return {}
	var full: bool = (poly[0] as Vector3).distance_to(poly[n - 1]) < 0.01
	return {"c": centre, "r": radius, "full": full}


static func _to_uv(p: Vector3, plane: Dictionary) -> Vector2:
	var d: Vector3 = p - (plane["origin"] as Vector3)
	return Vector2(d.dot(plane["x"]), d.dot(plane["y"]))


static func _key(uv: Vector2) -> String:
	return "%d,%d" % [roundi(uv.x * 1000.0), roundi(uv.y * 1000.0)]


func _cell_of(uv: Vector2) -> Vector2i:
	return Vector2i(floori(uv.x / _cell), floori(uv.y / _cell))


func _cells_near(uv: Vector2, radius: float) -> Array:
	var out: Array = []
	var c0 := _cell_of(uv - Vector2(radius, radius))
	var c1 := _cell_of(uv + Vector2(radius, radius))
	for cx in range(c0.x, c1.x + 1):
		for cy in range(c0.y, c1.y + 1):
			out.append(Vector2i(cx, cy))
	return out


# --- Looking up what is under the laser -----------------------------------------------------------

func nearest_vertex(uv: Vector2, radius: float) -> Dictionary:
	## The part vertex nearest `uv` within `radius` (mm): {body, index, uv, depth, distance} or {}.
	var best := {}
	var best_d := radius
	if _vertex_grid.is_empty() or radius > _cell * 64.0:
		return best
	var tried := {}
	for cell in _cells_near(uv, radius):
		for i in _vertex_grid.get(cell, []):
			if tried.has(i):
				continue
			tried[i] = true
			var v: Dictionary = vertices[i]
			var d := uv.distance_to(v["uv"])
			if d <= best_d:
				best_d = d
				best = {"body": v["body"], "index": v["index"], "uv": v["uv"], "depth": v["depth"], "distance": d}
	return best


func nearest_edge(uv: Vector2, radius: float, straight_only: bool = true) -> Dictionary:
	## The part edge nearest `uv` within `radius`: {body, index, kind, a, b, a_vertex, b_vertex, depth, distance, point} or {}. Only straight
	## edges unless told otherwise (a straight edge is a line in the sketch; a circle is not one).
	return _nearest_edge(uv, radius, func(e: Dictionary) -> bool: return not straight_only or str(e["kind"]) == "line")


func nearest_circular(uv: Vector2, radius: float) -> Dictionary:
	## The nearest circular edge lying in the sketch plane (a hole's or boss's rim, or an arc of one): the same entry as nearest_edge's, with
	## `circle` ({c, r, full}) on it. {} if none within `radius`.
	return _nearest_edge(uv, radius, func(e: Dictionary) -> bool: return not (e.get("circle", {}) as Dictionary).is_empty())


func _nearest_edge(uv: Vector2, radius: float, wanted: Callable) -> Dictionary:
	var best := {}
	var best_d := radius
	if _edge_grid.is_empty() or radius > _cell * 64.0:
		return best
	var tried := {}
	for cell in _cells_near(uv, radius):
		for i in _edge_grid.get(cell, []):
			if tried.has(i):
				continue
			tried[i] = true
			var e: Dictionary = edges[i]
			if not wanted.call(e):
				continue
			var segs: PackedVector2Array = e["segs"]
			for s in range(0, segs.size() - 1, 2):
				var near := Geometry2D.get_closest_point_to_segment(uv, segs[s], segs[s + 1])
				var d := uv.distance_to(near)
				if d <= best_d:
					best_d = d
					best = {"body": e["body"], "index": e["index"], "kind": e["kind"], "a": e["a"], "b": e["b"], "a_vertex": e["a_vertex"], "b_vertex": e["b_vertex"], "depth": e["depth"], "distance": d, "point": near, "circle": e.get("circle", {})}
	return best


func nearest_centre(uv: Vector2, radius: float) -> Dictionary:
	## The centre of the circular edge (in the sketch plane) whose centre is nearest `uv` within `radius`: {body, index, uv, radius, full, distance} or {}.
	var best := {}
	var best_d := radius
	for i in circles:
		var e: Dictionary = edges[i]
		var circle: Dictionary = e["circle"]
		var d := uv.distance_to(circle["c"])
		if d <= best_d:
			best_d = d
			best = {"body": e["body"], "index": e["index"], "uv": circle["c"], "radius": circle["r"], "full": circle["full"], "distance": d}
	return best


func nearest_face_axis(uv: Vector2, radius: float) -> Dictionary:
	## The axis of the round face (a blind hole's wall: its rims are not in the sketch plane) whose axis point is nearest `uv` within `radius`:
	## {body, index, uv, radius, distance} or {}. A hole whose rim IS in the plane is the circular edge's centre instead (nearest_centre), which wins.
	var best := {}
	var best_d := radius
	for f in faces:
		if str(f["kind"]) != "face_axis":
			continue
		var d := uv.distance_to(f["c"])
		if d <= best_d:
			best_d = d
			best = {"body": f["body"], "index": f["index"], "uv": f["c"], "radius": f["r"], "distance": d}
	return best


func nearest_face_line(uv: Vector2, radius: float) -> Dictionary:
	## The flat face standing square to the sketch plane whose edge-on line passes nearest `uv` within `radius`: {body, index, a, b, distance, point} or {}.
	var best := {}
	var best_d := radius
	for f in faces:
		if str(f["kind"]) != "face_line":
			continue
		var near := Geometry2D.get_closest_point_to_segment(uv, f["a"], f["b"])
		var d := uv.distance_to(near)
		if d <= best_d:
			best_d = d
			best = {"body": f["body"], "index": f["index"], "a": f["a"], "b": f["b"], "distance": d, "point": near}
	return best


func nearest_midpoint(uv: Vector2, radius: float) -> Dictionary:
	## The midpoint of the straight part edge whose midpoint is nearest `uv` within `radius`: {body, index, a, b, a_vertex, b_vertex, uv, distance} or {}.
	var best := {}
	var best_d := radius
	if _edge_grid.is_empty() or radius > _cell * 64.0:
		return best
	var tried := {}
	for cell in _cells_near(uv, radius):
		for i in _edge_grid.get(cell, []):
			if tried.has(i):
				continue
			tried[i] = true
			var e: Dictionary = edges[i]
			if str(e["kind"]) != "line" or not _straight_ok(e):
				continue
			var mid: Vector2 = ((e["a"] as Vector2) + (e["b"] as Vector2)) * 0.5
			var d := uv.distance_to(mid)
			if d <= best_d:
				best_d = d
				best = {"body": e["body"], "index": e["index"], "a": e["a"], "b": e["b"], "a_vertex": e["a_vertex"], "b_vertex": e["b_vertex"], "uv": mid, "distance": d}
	return best


static func _straight_ok(e: Dictionary) -> bool:
	## A straight edge the sketch can turn into a line: both ends are real, different part vertices.
	return int(e["a_vertex"]) >= 0 and int(e["b_vertex"]) >= 0 and int(e["a_vertex"]) != int(e["b_vertex"])


static func edge_usable(e: Dictionary) -> bool:
	## True for a straight edge the sketch can use as a pinned line (public form of _straight_ok, for the snap resolver).
	return _straight_ok(e)


static func edge_ref(e: Dictionary) -> Dictionary:
	## The reference a picked straight edge carries (what the session's ensure_reference turns into a pinned construction line).
	return {"kind": "edge", "body": e["body"], "index": e["index"], "a_vertex": e["a_vertex"], "b_vertex": e["b_vertex"], "a": e["a"], "b": e["b"]}


static func face_axis_ref(f: Dictionary) -> Dictionary:
	## A round face's axis as a live centre: ensure_reference asks convert-entities/face, which finds a circular edge of the face to follow.
	return {"kind": "face_axis", "body": f["body"], "index": f["index"]}


static func face_line_ref(f: Dictionary) -> Dictionary:
	## A flat face seen edge-on as a pinned line between its two extreme corners (convert-entities/face).
	return {"kind": "face_line", "body": f["body"], "index": f["index"], "a": f["a"], "b": f["b"]}


static func circle_ref(e: Dictionary) -> Dictionary:
	## The reference a picked circular edge carries: ensure_reference makes a pinned construction circle (or arc) with its centre pinned to the hole.
	var circle: Dictionary = e["circle"]
	return {"kind": "circle_edge", "body": e["body"], "index": e["index"], "full": circle["full"], "c": circle["c"], "r": circle["r"],
		"a_vertex": e["a_vertex"], "b_vertex": e["b_vertex"]}


func pick(uv: Vector2, radius: float, kinds: Array) -> Dictionary:
	## What a pick of the part's geometry at `uv` means, as the entity the sketch tools take: a vertex beats an edge, as a point beats a line in
	## the sketch (a hole's centre counts as a corner: a {kind: "point", ref: {kind: "circle_centre", ...}}); of a straight edge and a circular one (a
	## hole's rim) the nearer wins. {kind: "point", id: "", ref: {kind: "vertex", body, index}, uv}
	## or {kind: "line", id: "", ref: {kind: "edge", ...}, uv} or {kind: "circle" | "arc", id: "", ref: {kind: "circle_edge", ...}, uv} or {}.
	if "point" in kinds:
		var v := nearest_vertex(uv, radius)
		var centre: Dictionary = nearest_centre(uv, radius)
		if not centre.is_empty() and (v.is_empty() or float(centre["distance"]) < float(v["distance"])):
			return {"kind": "point", "id": "", "distance": centre["distance"], "uv": centre["uv"], "ref": {"kind": "circle_centre", "body": centre["body"], "index": centre["index"]}}
		if not v.is_empty():
			return {"kind": "point", "id": "", "distance": v["distance"], "uv": v["uv"], "ref": {"kind": "vertex", "body": v["body"], "index": v["index"]}}
		var axis := nearest_face_axis(uv, radius)
		if not axis.is_empty():
			return {"kind": "point", "id": "", "distance": axis["distance"], "uv": axis["uv"], "ref": face_axis_ref(axis)}
	var line := {}
	if "line" in kinds:
		var e := nearest_edge(uv, radius)
		if not e.is_empty() and _straight_ok(e):
			line = {"kind": "line", "id": "", "distance": e["distance"], "uv": e["point"], "ref": edge_ref(e)}
	var rim := {}
	if "circle" in kinds or "arc" in kinds:
		var c := nearest_circular(uv, radius)
		if not c.is_empty():
			var full: bool = bool(c["circle"]["full"])
			if ("circle" in kinds and full) or ("arc" in kinds and not full):
				rim = {"kind": "circle" if full else "arc", "id": "", "distance": c["distance"], "uv": c["point"], "ref": circle_ref(c)}
	if not line.is_empty() and not rim.is_empty():
		return line if float(line["distance"]) <= float(rim["distance"]) else rim
	if line.is_empty() and rim.is_empty() and "line" in kinds:
		var flat := nearest_face_line(uv, radius) # a flat face standing square to the sketch with no usable straight edge of its own under the laser
		if not flat.is_empty():
			return {"kind": "line", "id": "", "distance": flat["distance"], "uv": flat["point"], "ref": face_line_ref(flat)}
	return line if not line.is_empty() else rim


func edges_in(lo: Vector2, hi: Vector2) -> Array:
	## The edges whose box meets the rectangle lo..hi (what to draw for a window onto the part).
	var out: Array = []
	for e in edges:
		var elo: Vector2 = e["lo"]
		var ehi: Vector2 = e["hi"]
		if ehi.x < lo.x or elo.x > hi.x or ehi.y < lo.y or elo.y > hi.y:
			continue
		out.append(e)
	return out


func vertices_in(lo: Vector2, hi: Vector2) -> Array:
	var out: Array = []
	for v in vertices:
		var uv: Vector2 = v["uv"]
		if uv.x >= lo.x and uv.x <= hi.x and uv.y >= lo.y and uv.y <= hi.y:
			out.append(v)
	return out
