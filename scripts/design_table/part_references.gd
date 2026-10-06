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

var vertices: Array = [] ## [{body, index, uv, depth}] (depth: distance off the plane, mm)
var edges: Array = [] ## [{body, index, kind, segs (PackedVector2Array of segment pairs), a, b, a_vertex, b_vertex, depth, lo, hi}]

var _cell := 10.0
var _vertex_grid := {} ## Vector2i -> Array of indices into `vertices`
var _edge_grid := {} ## Vector2i -> Array of indices into `edges`


static func build(topology: Dictionary, plane: Dictionary) -> RefCounted:
	var refs: RefCounted = (load(SELF) as GDScript).new()
	refs._build(topology, plane)
	return refs


func is_empty() -> bool:
	return vertices.is_empty() and edges.is_empty()


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
			if seen_edges.has(ekey):
				if depth < float((edges[seen_edges[ekey]] as Dictionary)["depth"]) - 0.0001:
					edges[seen_edges[ekey]] = entry
				continue
			seen_edges[ekey] = edges.size()
			edges.append(entry)
			lo = lo.min(elo)
			hi = hi.max(ehi)
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


static func _edge(body: String, index: int, kind: String, segs: PackedVector2Array, a: Vector2, b: Vector2, vertex_at: Dictionary, pts: PackedVector3Array, depth: float, lo: Vector2, hi: Vector2) -> Dictionary:
	return {"body": body, "index": index, "kind": kind, "segs": segs, "a": a, "b": b,
		"a_vertex": int(vertex_at.get(Vector3i((pts[0] * 100.0).round()), -1)),
		"b_vertex": int(vertex_at.get(Vector3i((pts[pts.size() - 1] * 100.0).round()), -1)),
		"depth": depth, "lo": lo, "hi": hi}


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
			if straight_only and str(e["kind"]) != "line":
				continue
			var segs: PackedVector2Array = e["segs"]
			for s in range(0, segs.size() - 1, 2):
				var near := Geometry2D.get_closest_point_to_segment(uv, segs[s], segs[s + 1])
				var d := uv.distance_to(near)
				if d <= best_d:
					best_d = d
					best = {"body": e["body"], "index": e["index"], "kind": e["kind"], "a": e["a"], "b": e["b"], "a_vertex": e["a_vertex"], "b_vertex": e["b_vertex"], "depth": e["depth"], "distance": d, "point": near}
	return best


func pick(uv: Vector2, radius: float, kinds: Array) -> Dictionary:
	## What a pick of the part's geometry at `uv` means, as the entity the sketch tools take: a vertex beats an edge, as a point beats a line in
	## the sketch. {kind: "point", id: "", ref: {kind: "vertex", body, index}, uv} or {kind: "line", id: "", ref: {kind: "edge", ...}, uv} or {}.
	if "point" in kinds:
		var v := nearest_vertex(uv, radius)
		if not v.is_empty():
			return {"kind": "point", "id": "", "distance": v["distance"], "uv": v["uv"], "ref": {"kind": "vertex", "body": v["body"], "index": v["index"]}}
	if "line" in kinds:
		var e := nearest_edge(uv, radius)
		if not e.is_empty() and int(e["a_vertex"]) >= 0 and int(e["b_vertex"]) >= 0 and int(e["a_vertex"]) != int(e["b_vertex"]):
			return {"kind": "line", "id": "", "distance": e["distance"], "uv": e["point"], "ref": {"kind": "edge", "body": e["body"], "index": e["index"],
				"a_vertex": e["a_vertex"], "b_vertex": e["b_vertex"], "a": e["a"], "b": e["b"]}}
	return {}


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
