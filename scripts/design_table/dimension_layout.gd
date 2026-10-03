extends RefCounted
## Where the parts of a dimension go, the way an engineering drawing draws them. Pure maths in the sketch's own millimetres (no scene tree), so
## the shapes are unit-tested (tests/design_table_logic.gd) and sketch_view.gd only turns the result into ribbons, arrows and text.
##
## layout(spec, params) returns
##   segments   [[a, b], ...]   thin lines: the EXTENSION lines (leaving a small gap from the geometry, overshooting the dimension line) and the
##                              DIMENSION line (or the leader)
##   arrows     [[tip, dir], ...] filled arrowheads: the tip, and the direction the arrow points
##   arcs       [[p, p, ...], ...] polylines (the angle dimension's arc)
##   text_uv    where the text's centre goes (above the line, off the geometry)
##   text_angle the text's baseline direction in radians, always upright (reading left to right or bottom to top)
##   text_up    the unit vector the text's top points to
## Specs (what is being measured):
##   {kind: "linear", a, b}                     aligned: the dimension line parallel to a-b, offset to the outside
##   {kind: "horizontal"|"vertical", a, b}      the dimension line axis-aligned, below / above (left / right) the points
##   {kind: "perp", a, b}                       a distance across, like linear, for a point to a line (b is the foot) or two parallel lines
##   {kind: "radius", c, r, u}                  a leader from the centre through the circle at direction u, arrow on the circle, text beyond
##   {kind: "diameter", c, r, u}                a line through the centre with an arrow at each end on the circle, text above it
##   {kind: "angle", apex, d1, d2, r}           an arc of radius r from direction d1 to d2 about the apex, arrows at both ends
## params: offset (distance of the dimension line from the geometry), arrow (arrowhead length), gap (extension line gap), over (overshoot),
## centroid (the middle of the sketch: with no better reason a dimension line goes away from it), obstacles (the sketch's points: the dimension line
## takes the side with more room), text_w / text_h (the text's size, to keep it clear of its leader).


static func layout(spec: Dictionary, params: Dictionary) -> Dictionary:
	match str(spec.get("kind", "")):
		"linear", "perp":
			return _linear(spec["a"], spec["b"], params)
		"horizontal":
			return _axis_aligned(spec["a"], spec["b"], params, true)
		"vertical":
			return _axis_aligned(spec["a"], spec["b"], params, false)
		"radius":
			return _radius(spec["c"], float(spec["r"]), spec["u"], params)
		"diameter":
			return _diameter(spec["c"], float(spec["r"]), spec["u"], params)
		"angle":
			return _angle(spec["apex"], spec["d1"], spec["d2"], float(spec["r"]), params)
	return _empty()


static func _empty() -> Dictionary:
	return {"segments": [], "arrows": [], "arcs": [], "text_uv": Vector2.ZERO, "text_angle": 0.0, "text_up": Vector2(0, 1)}


static func upright(angle: float) -> float:
	## A text direction turned into the range (-90, 90] degrees, so text never reads upside down.
	var a := wrapf(angle, -PI, PI)
	if a > PI * 0.5 + 0.0001:
		a -= PI
	elif a <= -PI * 0.5 + 0.0001:
		a += PI
	return a


static func _text_frame(angle: float) -> Array:
	var dir := Vector2(cos(angle), sin(angle))
	return [dir, Vector2(-dir.y, dir.x)]


static func _arrows_for(p1: Vector2, p2: Vector2, params: Dictionary, segments: Array, arrows: Array) -> void:
	## The two ends of a dimension line p1-p2: arrowheads inside pointing outward at the extension lines, or, when the line is too short to hold
	## them, outside pointing in with a short tail (as on a drawing).
	var arrow := float(params["arrow"])
	var d := (p2 - p1)
	var len := d.length()
	if len < 0.00001:
		return
	var dir := d / len
	if len >= arrow * 2.4:
		arrows.append([p1, -dir])
		arrows.append([p2, dir])
	else:
		arrows.append([p1, dir])
		arrows.append([p2, -dir])
		segments.append([p1 - dir * arrow * 1.6, p1])
		segments.append([p2, p2 + dir * arrow * 1.6])


static func _clearance(p1: Vector2, p2: Vector2, params: Dictionary, skip_a: Vector2, skip_b: Vector2) -> float:
	## How far the nearest other piece of the sketch (a point, or a stretch of line or curve: obstacles / obstacle_segments in params) is from a
	## dimension line p1-p2 (INF with none): the side with more room is the better side. The stretch being dimensioned itself is skipped.
	var best := INF
	for q in params.get("obstacles", []):
		if (q as Vector2).is_equal_approx(skip_a) or (q as Vector2).is_equal_approx(skip_b):
			continue
		best = minf(best, (q as Vector2).distance_to(Geometry2D.get_closest_point_to_segment(q, p1, p2)))
	for seg in params.get("obstacle_segments", []):
		var q1: Vector2 = seg[0]
		var q2: Vector2 = seg[1]
		if (q1.is_equal_approx(skip_a) and q2.is_equal_approx(skip_b)) or (q1.is_equal_approx(skip_b) and q2.is_equal_approx(skip_a)):
			continue
		if Geometry2D.segment_intersects_segment(p1, p2, q1, q2) != null:
			return 0.0
		best = minf(best, minf(minf(q1.distance_to(Geometry2D.get_closest_point_to_segment(q1, p1, p2)), q2.distance_to(Geometry2D.get_closest_point_to_segment(q2, p1, p2))),
			minf(p1.distance_to(Geometry2D.get_closest_point_to_segment(p1, q1, q2)), p2.distance_to(Geometry2D.get_closest_point_to_segment(p2, q1, q2)))))
	return best


static func _inside_shape(p: Vector2, params: Dictionary) -> bool:
	for poly in params.get("interiors", []):
		if (poly as Array).size() >= 3 and Geometry2D.is_point_in_polygon(p, PackedVector2Array(poly)):
			return true
	return false


static func prefer_first(c1: Array, c2: Array, params: Dictionary, skip_a: Vector2, skip_b: Vector2, off: float) -> bool:
	## Which of two candidate dimension lines ([p1, p2] each) is better: the one that is not inside a closed shape of the sketch, else the one with
	## clearly more room, else (nothing to tell them apart) the first.
	var in1 := _inside_shape((c1[0] + c1[1]) * 0.5, params)
	var in2 := _inside_shape((c2[0] + c2[1]) * 0.5, params)
	if in1 != in2:
		return not in1
	var r1 := _clearance(c1[0], c1[1], params, skip_a, skip_b)
	var r2 := _clearance(c2[0], c2[1], params, skip_a, skip_b)
	if absf(r1 - r2) > off * 0.25 or (r1 == INF) != (r2 == INF):
		return r1 > r2
	return true


static func _linear(a: Vector2, b: Vector2, params: Dictionary) -> Dictionary:
	var out := _empty()
	var d := b - a
	if d.length() < 0.00001:
		return out
	var dir := d.normalized()
	var n := Vector2(-dir.y, dir.x)
	var centroid: Vector2 = params.get("centroid", (a + b) * 0.5)
	var off := float(params["offset"])
	var gap := float(params["gap"])
	var over := float(params["over"])
	if n.dot((a + b) * 0.5 - centroid) < 0.0:
		n = -n # (with nothing to tell the sides apart: away from the middle of the sketch)
	if not prefer_first([a + n * off, b + n * off], [a - n * off, b - n * off], params, a, b, off):
		n = -n
	var p1 := a + n * off
	var p2 := b + n * off
	out["segments"].append([a + n * gap, p1 + n * over])
	out["segments"].append([b + n * gap, p2 + n * over])
	out["segments"].append([p1, p2])
	_arrows_for(p1, p2, params, out["segments"], out["arrows"])
	var angle := upright(dir.angle())
	var frame := _text_frame(angle)
	var up: Vector2 = frame[1]
	out["text_angle"] = angle
	out["text_up"] = up
	out["text_uv"] = (p1 + p2) * 0.5 + up * (float(params["text_h"]) * 0.75)
	return out


static func _axis_aligned(a: Vector2, b: Vector2, params: Dictionary, horizontal: bool) -> Dictionary:
	var out := _empty()
	var off := float(params["offset"])
	var gap := float(params["gap"])
	var over := float(params["over"])
	var centroid: Vector2 = params.get("centroid", (a + b) * 0.5)
	var p1: Vector2
	var p2: Vector2
	var side: float
	if horizontal:
		var y_low := minf(a.y, b.y) - off
		var y_high := maxf(a.y, b.y) + off
		var low := [Vector2(a.x, y_low), Vector2(b.x, y_low)]
		var high := [Vector2(a.x, y_high), Vector2(b.x, y_high)]
		var mid_y := (a.y + b.y) * 0.5
		var away_low := mid_y <= centroid.y
		side = -1.0 if (prefer_first(low, high, params, a, b, off) if away_low else not prefer_first(high, low, params, a, b, off)) else 1.0
		var y := y_low if side < 0.0 else y_high
		p1 = Vector2(a.x, y)
		p2 = Vector2(b.x, y)
		out["segments"].append([a + Vector2(0, side * gap), p1 + Vector2(0, side * over)])
		out["segments"].append([b + Vector2(0, side * gap), p2 + Vector2(0, side * over)])
	else:
		var x_low := minf(a.x, b.x) - off
		var x_high := maxf(a.x, b.x) + off
		var left := [Vector2(x_low, a.y), Vector2(x_low, b.y)]
		var right := [Vector2(x_high, a.y), Vector2(x_high, b.y)]
		var mid_x := (a.x + b.x) * 0.5
		var away_left := mid_x <= centroid.x
		side = -1.0 if (prefer_first(left, right, params, a, b, off) if away_left else not prefer_first(right, left, params, a, b, off)) else 1.0
		var x := x_low if side < 0.0 else x_high
		p1 = Vector2(x, a.y)
		p2 = Vector2(x, b.y)
		out["segments"].append([a + Vector2(side * gap, 0), p1 + Vector2(side * over, 0)])
		out["segments"].append([b + Vector2(side * gap, 0), p2 + Vector2(side * over, 0)])
	if p1.distance_to(p2) < 0.00001:
		return _empty()
	out["segments"].append([p1, p2])
	_arrows_for(p1, p2, params, out["segments"], out["arrows"])
	var angle := 0.0 if horizontal else PI * 0.5
	var frame := _text_frame(angle)
	out["text_angle"] = angle
	out["text_up"] = frame[1]
	out["text_uv"] = (p1 + p2) * 0.5 + (frame[1] as Vector2) * (float(params["text_h"]) * 0.75)
	return out


static func _radius(c: Vector2, r: float, u: Vector2, params: Dictionary) -> Dictionary:
	var out := _empty()
	if r < 0.00001:
		return out
	var dir := u.normalized() if u.length() > 0.00001 else Vector2(1, 0)
	var arrow := float(params["arrow"])
	var tip := c + dir * r
	var end := tip + dir * (arrow * 2.5 + float(params["gap"]))
	out["segments"].append([c, end])
	out["arrows"].append([tip, dir])
	var angle := upright(dir.angle())
	var frame := _text_frame(angle)
	var t: Vector2 = frame[0]
	var up: Vector2 = frame[1]
	var half_w := float(params["text_w"]) * 0.5
	var half_h := float(params["text_h"]) * 0.5
	var push := absf(dir.dot(t)) * half_w + absf(dir.dot(up)) * half_h + float(params["gap"])
	out["text_angle"] = angle
	out["text_up"] = up
	out["text_uv"] = end + dir * push
	return out


static func _diameter(c: Vector2, r: float, u: Vector2, params: Dictionary) -> Dictionary:
	var out := _empty()
	if r < 0.00001:
		return out
	var dir := u.normalized() if u.length() > 0.00001 else Vector2(1, 0)
	var p1 := c - dir * r
	var p2 := c + dir * r
	out["segments"].append([p1, p2])
	out["arrows"].append([p1, -dir])
	out["arrows"].append([p2, dir])
	var angle := upright(dir.angle())
	var frame := _text_frame(angle)
	out["text_angle"] = angle
	out["text_up"] = frame[1]
	out["text_uv"] = c + (frame[1] as Vector2) * (float(params["text_h"]) * 0.75)
	return out


static func _angle(apex: Vector2, d1: Vector2, d2: Vector2, r: float, params: Dictionary) -> Dictionary:
	var out := _empty()
	if r < 0.00001 or d1.length() < 0.00001 or d2.length() < 0.00001:
		return out
	var a1 := d1.angle()
	var sweep := wrapf(d2.angle() - a1, -PI, PI) # the smaller way round, signed
	if absf(sweep) < 0.0001:
		return out
	var steps := maxi(6, int(absf(sweep) / (PI / 24.0)))
	var pts: Array = []
	for i in steps + 1:
		var t := a1 + sweep * float(i) / float(steps)
		pts.append(apex + Vector2(cos(t), sin(t)) * r)
	out["arcs"].append(pts)
	var tangent_start := Vector2(-sin(a1), cos(a1)) * signf(sweep)
	var end_angle := a1 + sweep
	var tangent_end := Vector2(-sin(end_angle), cos(end_angle)) * signf(sweep)
	out["arrows"].append([pts[0], -tangent_start])
	out["arrows"].append([pts[pts.size() - 1], tangent_end])
	var gap := float(params["gap"])
	var over := float(params["over"])
	for pair in [[d1.normalized(), pts[0]], [d2.normalized(), pts[pts.size() - 1]]]:
		out["segments"].append([apex + (pair[0] as Vector2) * gap, (pair[1] as Vector2) + (pair[0] as Vector2) * over])
	var mid_angle := a1 + sweep * 0.5
	var mid_dir := Vector2(cos(mid_angle), sin(mid_angle))
	var angle := 0.0 # an angle's value is written horizontally
	var frame := _text_frame(angle)
	var t2: Vector2 = frame[0]
	var up2: Vector2 = frame[1]
	var push := absf(mid_dir.dot(t2)) * float(params["text_w"]) * 0.5 + absf(mid_dir.dot(up2)) * float(params["text_h"]) * 0.5 + gap
	out["text_angle"] = angle
	out["text_up"] = up2
	out["text_uv"] = apex + mid_dir * (r + push)
	return out
