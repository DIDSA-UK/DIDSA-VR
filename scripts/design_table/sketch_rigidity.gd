extends RefCounted
## Which parts of a sketch are fully constrained, over-constrained or free (parity follow-ups F7, decision 8), written from DIDSA-CAD's docs/sketch-rigidity-spec.md (not from the
## Dart): a topological count, not a solve. Union-find clusters of points joined by constraints; each constraint removes a fixed number of degrees of freedom by type; a cluster
## with none left that is tied to a fixed point (the origin, a locked point) is fully constrained. Positions are never read, so it is cheap enough for every refresh. The
## backend's solve stays the authority for the whole sketch; this says which STRUCTURE still needs a dimension (the flat app colours each line, circle and arc the same way).
## Pinned against DIDSA-CAD's docs/sketch-rigidity-vectors.json by tests/sketch_rigidity_vectors.gd (exact sets, no tolerance).
##
##   var r := SketchRigidity.analyse(point_ids, fixed, lines, constraints, trust_converged_solve)
##   r.is_fully(p) / is_over(p) / is_grounded(p) / is_pinned(p) / any_grounded      (the spec's queries)
##   r.segment_fully(a, b) / segment_over(a, b)
##   r.entity_state(pairs) -> "over" | "fully" | "free"          (section 4's pair rule; the caller adds the backend's forced-over sources and the whole-sketch override)

const COST := {
	"distance": 1, "vertical": 1, "horizontal": 1, "coincident": 2, "concentric": 2, "angle": 1, "parallel": 1, "perpendicular": 1, "equal_length": 1, "line_distance": 1,
	"collinear": 2, "point_line_distance": 1, "point_on_line": 1, "at_midpoint": 2, "tangent": 1, "curve_tangent": 1, "equal_radius": 1, "spline_tangent": 1,
	"point_on_circle": 1, "point_on_ellipse": 1, "arc_length": 1, "horizontal_angle": 1, "point_angle": 1, "line_circle_distance": 1, "circle_distance": 1, "point_circle_distance": 1,
}

var fully := {} ## id -> true
var over := {}
var grounded := {}
var pinned := {}
var any_grounded := false

var _parent := {}


static func _line_points(lines: Dictionary, id: Variant) -> Array:
	## A Line id's start and end point ids ({a, b} from a session, or [start, end] from the vectors); a missing id contributes none.
	var l: Variant = lines.get(str(id))
	if l is Dictionary:
		return [str(l["a"]), str(l["b"])]
	if l is Array and (l as Array).size() >= 2:
		return [str(l[0]), str(l[1])]
	return []


static func points_of(c: Dictionary, lines: Dictionary) -> Array:
	## Section 2: the points a constraint names, in the spec's order.
	var out: Array = []
	var t := str(c.get("type", ""))
	match t:
		"distance", "vertical", "horizontal", "coincident":
			out = [c.get("point_a_id"), c.get("point_b_id")]
		"concentric":
			out = [c.get("center1_point_id"), c.get("center2_point_id")]
		"angle", "parallel", "perpendicular", "equal_length", "line_distance", "collinear":
			out = _line_points(lines, c.get("line1_id")) + _line_points(lines, c.get("line2_id"))
		"point_line_distance", "point_on_line", "at_midpoint":
			out = [c.get("point_id")] + _line_points(lines, c.get("line_id"))
		"tangent":
			out = [c.get("center_point_id"), c.get("radius_point_id")] + _line_points(lines, c.get("line_id"))
		"curve_tangent":
			out = [c.get("center1_point_id"), c.get("center2_point_id"), c.get("shared_point_id")]
		"equal_radius", "circle_distance":
			out = [c.get("center1_point_id"), c.get("radius1_point_id"), c.get("center2_point_id"), c.get("radius2_point_id")]
		"spline_tangent":
			out = [c.get("segment_a_p0"), c.get("segment_a_p1"), c.get("segment_a_p2"), c.get("segment_a_p3"), c.get("segment_b_p1"), c.get("segment_b_p2"), c.get("segment_b_p3")]
		"point_on_circle", "point_circle_distance":
			out = [c.get("point_id"), c.get("center_point_id"), c.get("radius_point_id")]
		"point_on_ellipse":
			out = [c.get("point_id"), c.get("center_point_id"), c.get("major_point_id"), c.get("minor_point_id")]
		"arc_length":
			out = [c.get("center_point_id"), c.get("start_point_id"), c.get("end_point_id")]
		"horizontal_angle":
			out = [c.get("line_start_id"), c.get("line_end_id")]
		"point_angle":
			out = [c.get("vertex_point_id"), c.get("point1_id"), c.get("point2_id")]
		"line_circle_distance":
			out = [c.get("line_start_id"), c.get("line_end_id"), c.get("center_point_id"), c.get("radius_point_id")]
	return out.filter(func(v: Variant) -> bool: return v != null and str(v) != "").map(func(v: Variant) -> String: return str(v))


static func analyse(point_ids: Array, fixed: Array, lines: Dictionary, constraints: Array, trust_converged_solve: bool) -> RefCounted:
	var r = new()
	r._run(point_ids, fixed, lines, constraints, trust_converged_solve)
	return r


func _find(parent: Dictionary, x: String) -> String:
	if not parent.has(x):
		parent[x] = x
	var root := x
	while parent[root] != root:
		root = parent[root]
	var c := x
	while parent[c] != root:
		var nxt: String = parent[c]
		parent[c] = root
		c = nxt
	return root


func _union(parent: Dictionary, a: String, b: String) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[ra] = rb


func _run(point_ids: Array, fixed: Array, lines: Dictionary, constraints: Array, trust: bool) -> void:
	var fixed_set := {}
	for f in fixed:
		fixed_set[str(f)] = true
	var descs: Array = []
	for c: Dictionary in constraints:
		var t := str(c.get("type", ""))
		if t == "distance" and bool(c.get("provisional", false)):
			continue
		descs.append({"type": t, "points": points_of(c, lines)})
	var parent := {}
	for d: Dictionary in descs:
		var pts: Array = d["points"]
		for i in range(1, pts.size()):
			_union(parent, str(pts[0]), str(pts[i]))
	var removed := {}
	for d: Dictionary in descs:
		var pts: Array = d["points"]
		if pts.is_empty():
			continue
		var root := _find(parent, str(pts[0]))
		removed[root] = int(removed.get(root, 0)) + int(COST.get(str(d["type"]), 0))
	var raw := {}
	var grounded_root := {}
	for id in point_ids:
		if not parent.has(str(id)):
			continue
		var root := _find(parent, str(id))
		raw[root] = int(raw.get(root, 0)) + (0 if fixed_set.has(str(id)) else 2)
		if fixed_set.has(str(id)):
			grounded_root[root] = true
	for id in point_ids:
		if not parent.has(str(id)):
			continue
		var root := _find(parent, str(id))
		var remaining: int = int(raw.get(root, 0)) - int(removed.get(root, 0))
		if remaining < 0 and not trust:
			over[str(id)] = true
		elif remaining == 0 and grounded_root.has(root):
			fully[str(id)] = true
		if grounded_root.has(root):
			grounded[str(id)] = true
	any_grounded = not grounded.is_empty()
	# pinned: fixed points and what they are tied to by coincident / concentric links only
	var pin := {}
	for d: Dictionary in descs:
		if d["type"] == "coincident" or d["type"] == "concentric":
			var pts: Array = d["points"]
			for i in range(1, pts.size()):
				_union(pin, str(pts[0]), str(pts[i]))
	var fixed_roots := {}
	for f in fixed_set:
		if pin.has(f):
			fixed_roots[_find(pin, f)] = true
		pinned[f] = true
	for id in point_ids:
		if pin.has(str(id)) and fixed_roots.has(_find(pin, str(id))):
			pinned[str(id)] = true


func is_fully(p: String) -> bool:
	return fully.has(p)


func is_over(p: String) -> bool:
	return over.has(p)


func is_grounded(p: String) -> bool:
	return grounded.has(p)


func is_pinned(p: String) -> bool:
	return pinned.has(p)


func segment_fully(a: String, b: String) -> bool:
	return fully.has(a) and fully.has(b)


func segment_over(a: String, b: String) -> bool:
	return over.has(a) or over.has(b)


func entity_state(pairs: Array) -> String:
	## Section 4's rigidity part: over when any pair is over, fully when every pair is fully constrained, else free. (The caller adds forced-over points and the whole-sketch override.)
	if pairs.is_empty():
		return "free"
	var all_fully := true
	for p: Array in pairs:
		if segment_over(str(p[0]), str(p[1])):
			return "over"
		all_fully = all_fully and segment_fully(str(p[0]), str(p[1]))
	return "fully" if all_fully else "free"


static func pairs_of(kind: String, pts: Array) -> Array:
	## Section 4's defining pairs from an entity's points: line [start, end]; circle [centre, radius]; arc [centre, start, end]; ellipse [centre, major, minor];
	## ellipse arc [centre, major, minor, start, end]; spline through points in order.
	var out: Array = []
	match kind:
		"line", "circle":
			out.append([pts[0], pts[1]])
		"arc":
			out = [[pts[0], pts[1]], [pts[0], pts[2]]]
		"ellipse":
			out = [[pts[0], pts[1]], [pts[0], pts[2]]]
		"ellipse_arc":
			out = [[pts[0], pts[1]], [pts[0], pts[2]], [pts[0], pts[3]], [pts[0], pts[4]]]
		"spline":
			for i in pts.size() - 1:
				out.append([pts[i], pts[i + 1]])
		"point", "text":
			out.append([pts[0], pts[0]])
	return out
