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
##   {kind: "arc_length", c, r, a0, sweep}      a concentric arc outside the arc c / r running a0 (radians) round counter-clockwise by sweep, extension lines out
##                                              from its two ends, arrows at both
## A spec may carry the label's SAVED PLACEMENT (the backend's `label`; the saved numbers are read by sketch_session.gd, which turns them into these
## spec keys, so this file never sees the backend's own field names). Without them the automatic layout below applies (F2 of the parity plan):
##   linear / perp / horizontal / vertical   place {offset, along}: where the dimension line sits and where the label sits along it (the meaning of
##                                           sketch-label-placement-cases.json); perp may carry `u` too (two parallel lines: offset runs along u,
##                                           the dimension line across it)
##   radius / diameter    label_r: the label's distance from the centre, along u
##   angle / arc_length   label_a (radians, absolute): the label's place round the arc; angle's r and arc_length's `ra` (the dimension arc's radius) are the saved radii
## The label's centre is then exactly where it was saved (text_uv), the dimension line is broken round it or runs on out to it.
## params: offset (distance of the dimension line from the geometry), arrow (arrowhead length), gap (extension line gap), over (overshoot),
## centroid (the middle of the sketch: with no better reason a dimension line goes away from it), obstacles (the sketch's points: the dimension line
## takes the side with more room), text_w / text_h (the text's size, to keep it clear of its leader).


static func layout(spec: Dictionary, params: Dictionary) -> Dictionary:
	match str(spec.get("kind", "")):
		"linear", "perp":
			if spec.has("place"):
				return _linear_placed(spec["a"], spec["b"], spec.get("u", _left_normal(spec["b"] - spec["a"])), spec["place"], params)
			return _linear(spec["a"], spec["b"], params)
		"horizontal":
			if spec.has("place"):
				return _axis_placed(spec["a"], spec["b"], spec["place"], params, true)
			return _axis_aligned(spec["a"], spec["b"], params, true)
		"vertical":
			if spec.has("place"):
				return _axis_placed(spec["a"], spec["b"], spec["place"], params, false)
			return _axis_aligned(spec["a"], spec["b"], params, false)
		"radius":
			return _radius(spec["c"], float(spec["r"]), spec["u"], params, float(spec.get("label_r", NAN)))
		"diameter":
			return _diameter(spec["c"], float(spec["r"]), spec["u"], params, float(spec.get("label_r", NAN)))
		"angle":
			return _angle(spec["apex"], spec["d1"], spec["d2"], float(spec["r"]), params, float(spec.get("label_a", NAN)))
		"arc_length":
			return _arc_length(spec["c"], float(spec["r"]), float(spec["a0"]), float(spec["sweep"]), float(spec.get("ra", NAN)), float(spec.get("label_a", NAN)), params)
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


static func _left_normal(d: Vector2) -> Vector2:
	var dir := d.normalized()
	return Vector2(-dir.y, dir.x)


static func _split_around(a: Vector2, b: Vector2, centre: Vector2, half: float) -> Array:
	## The segment a-b with a gap of half either side of `centre` (a point of it): the pieces that are left ([] when nothing is).
	var d := b - a
	var len := d.length()
	if len < 0.00001:
		return []
	var t := d / len
	var s := (centre - a).dot(t)
	var out: Array = []
	if s - half > 0.00001:
		out.append([a, a + t * minf(s - half, len)])
	if s + half < len - 0.00001:
		out.append([a + t * maxf(s + half, 0.0), b])
	return out


static func _placed_line(out: Dictionary, p1: Vector2, p2: Vector2, label: Vector2, params: Dictionary) -> void:
	## The dimension line p1-p2 (arrows as ever at its ends) with its label at `label`, a point on the line's own axis: the line is broken round the text
	## when the label is between the ends, and runs on out to it (a leader, as on a drawing) when it is beyond one.
	_arrows_for(p1, p2, params, out["segments"], out["arrows"])
	var d := p2 - p1
	var len := d.length()
	if len < 0.00001:
		return
	var t := d / len
	var half := float(params["text_w"]) * 0.5 + float(params["gap"])
	var s := (label - p1).dot(t)
	if s + half < 0.0:
		out["segments"].append([label + t * half, p1])
	elif s - half > len:
		out["segments"].append([p2, label - t * half])
	for piece in _split_around(p1, p2, label, half):
		out["segments"].append(piece)


static func _linear_placed(a: Vector2, b: Vector2, n: Vector2, place: Dictionary, params: Dictionary) -> Dictionary:
	## A distance a-b whose dimension line is `offset` off a-b along n, its label `along` from the line's middle towards b.
	var out := _empty()
	var d := b - a
	if d.length() < 0.00001:
		return out
	var t := d.normalized()
	var off := float(place.get("offset", 0.0))
	var p1 := a + n * off
	var p2 := b + n * off
	_extension_lines(out, [[a, p1], [b, p2]], params)
	var label := (p1 + p2) * 0.5 + t * float(place.get("along", 0.0))
	_placed_line(out, p1, p2, label, params)
	var angle := upright(t.angle())
	out["text_angle"] = angle
	out["text_up"] = _text_frame(angle)[1]
	out["text_uv"] = label
	return out


static func _extension_lines(out: Dictionary, pairs: Array, params: Dictionary) -> void:
	## An extension line from each geometry end to its dimension-line end (a gap off the geometry, an overshoot past the line); none where they meet.
	var gap := float(params["gap"])
	var over := float(params["over"])
	for pair in pairs:
		var g: Vector2 = pair[0]
		var e: Vector2 = pair[1]
		var span := e - g
		if span.length() <= gap * 1.5:
			continue
		var s := span.normalized()
		out["segments"].append([g + s * gap, e + s * over])


static func _axis_placed(a: Vector2, b: Vector2, place: Dictionary, params: Dictionary, horizontal: bool) -> Dictionary:
	## horizontal: the dimension line at y = the higher point's y + offset, the label at x = the middle's x + along; vertical: x past the further-right point,
	## y from the middle (the cases file's distance_horizontal / distance_vertical).
	var out := _empty()
	var off := float(place.get("offset", 0.0))
	var along := float(place.get("along", 0.0))
	var p1: Vector2
	var p2: Vector2
	var label: Vector2
	if horizontal:
		var y := maxf(a.y, b.y) + off
		p1 = Vector2(a.x, y)
		p2 = Vector2(b.x, y)
		label = Vector2((a.x + b.x) * 0.5 + along, y)
	else:
		var x := maxf(a.x, b.x) + off
		p1 = Vector2(x, a.y)
		p2 = Vector2(x, b.y)
		label = Vector2(x, (a.y + b.y) * 0.5 + along)
	if p1.distance_to(p2) < 0.00001:
		return out
	_extension_lines(out, [[a, p1], [b, p2]], params)
	_placed_line(out, p1, p2, label, params)
	var angle := 0.0 if horizontal else PI * 0.5
	out["text_angle"] = angle
	out["text_up"] = _text_frame(angle)[1]
	out["text_uv"] = label
	return out


static func _radius(c: Vector2, r: float, u: Vector2, params: Dictionary, label_r := NAN) -> Dictionary:
	var out := _empty()
	if r < 0.00001:
		return out
	var dir := u.normalized() if u.length() > 0.00001 else Vector2(1, 0)
	var arrow := float(params["arrow"])
	var tip := c + dir * r
	var angle := upright(dir.angle())
	var frame := _text_frame(angle)
	var t: Vector2 = frame[0]
	var up: Vector2 = frame[1]
	var half_w := float(params["text_w"]) * 0.5
	var half_h := float(params["text_h"]) * 0.5
	var push := absf(dir.dot(t)) * half_w + absf(dir.dot(up)) * half_h + float(params["gap"])
	out["arrows"].append([tip, dir])
	out["text_angle"] = angle
	out["text_up"] = up
	if is_nan(label_r):
		var end := tip + dir * (arrow * 2.5 + float(params["gap"]))
		out["segments"].append([c, end])
		out["text_uv"] = end + dir * push
		return out
	# a saved placement: the label sits where it was put (inside the circle or out), the leader runs to it from the centre, or from it to the rim
	out["text_uv"] = c + dir * label_r
	if label_r - push >= r:
		out["segments"].append([c, c + dir * (label_r - push)])
	elif label_r + push < r:
		out["segments"].append([c + dir * (label_r + push), tip])
	else:
		out["segments"].append([c + dir * maxf(label_r - push, 0.0), tip])
	return out


static func _diameter(c: Vector2, r: float, u: Vector2, params: Dictionary, label_r := NAN) -> Dictionary:
	var out := _empty()
	if r < 0.00001:
		return out
	var dir := u.normalized() if u.length() > 0.00001 else Vector2(1, 0)
	var p1 := c - dir * r
	var p2 := c + dir * r
	out["arrows"].append([p1, -dir])
	out["arrows"].append([p2, dir])
	var angle := upright(dir.angle())
	var frame := _text_frame(angle)
	out["text_angle"] = angle
	out["text_up"] = frame[1]
	if is_nan(label_r):
		out["segments"].append([p1, p2])
		out["text_uv"] = c + (frame[1] as Vector2) * (float(params["text_h"]) * 0.75)
		return out
	var label := c + dir * label_r
	var half := float(params["text_w"]) * 0.5 + float(params["gap"])
	out["text_uv"] = label
	if absf(label_r) > r:
		out["segments"].append([p1, p2])
		out["segments"].append([p2 if label_r > 0.0 else p1, label - dir * half * signf(label_r)])
	else:
		for piece in _split_around(p1, p2, label, half):
			out["segments"].append(piece)
	return out


static func _arc_core(out: Dictionary, centre: Vector2, r: float, a0: float, sweep: float, label_a: float, params: Dictionary) -> void:
	## The dimension arc of radius r about centre from angle a0 round by sweep (signed, radians), arrowheads at both ends. With a saved label angle the
	## arc is broken round the text when the label is on it and runs on to it when it is beyond an end.
	var tangent_sign := signf(sweep)
	var a1 := a0 + sweep
	var half_gap := (float(params["text_w"]) * 0.5 + float(params["gap"])) / maxf(r, 0.0001) # the text's half width as an angle on this arc
	var lo := minf(a0, a1)
	var hi := maxf(a0, a1)
	var cut_lo := NAN
	var cut_hi := NAN
	if not is_nan(label_a):
		var rel := wrapf(label_a - (a0 + sweep * 0.5), -PI, PI) + (a0 + sweep * 0.5) # the label's angle in the sweep's own turn, nearest the middle
		if rel >= lo and rel <= hi:
			cut_lo = rel - half_gap
			cut_hi = rel + half_gap
		else:
			lo = minf(lo, rel - half_gap)
			hi = maxf(hi, rel + half_gap)
	var ranges: Array = [[lo, hi]]
	if not is_nan(cut_lo):
		ranges = []
		if cut_lo > lo + 0.0001:
			ranges.append([lo, cut_lo])
		if cut_hi < hi - 0.0001:
			ranges.append([cut_hi, hi])
	for rng in ranges:
		var span: float = rng[1] - rng[0]
		var steps := maxi(3, int(span / (PI / 24.0)))
		var pts: Array = []
		for i in steps + 1:
			var t: float = rng[0] + span * float(i) / float(steps)
			pts.append(centre + Vector2(cos(t), sin(t)) * r)
		out["arcs"].append(pts)
	var tangent_start := Vector2(-sin(a0), cos(a0)) * tangent_sign
	var tangent_end := Vector2(-sin(a1), cos(a1)) * tangent_sign
	out["arrows"].append([centre + Vector2(cos(a0), sin(a0)) * r, -tangent_start])
	out["arrows"].append([centre + Vector2(cos(a1), sin(a1)) * r, tangent_end])


static func _angle(apex: Vector2, d1: Vector2, d2: Vector2, r: float, params: Dictionary, label_a := NAN) -> Dictionary:
	var out := _empty()
	if r < 0.00001 or d1.length() < 0.00001 or d2.length() < 0.00001:
		return out
	var a1 := d1.angle()
	var sweep := wrapf(d2.angle() - a1, -PI, PI) # the smaller way round, signed
	if absf(sweep) < 0.0001:
		return out
	_arc_core(out, apex, r, a1, sweep, label_a, params)
	var gap := float(params["gap"])
	var over := float(params["over"])
	var end_angle := a1 + sweep
	for pair in [[d1.normalized(), apex + Vector2(cos(a1), sin(a1)) * r], [d2.normalized(), apex + Vector2(cos(end_angle), sin(end_angle)) * r]]:
		out["segments"].append([apex + (pair[0] as Vector2) * gap, (pair[1] as Vector2) + (pair[0] as Vector2) * over])
	var angle := 0.0 # an angle's value is written horizontally
	var frame := _text_frame(angle)
	out["text_angle"] = angle
	out["text_up"] = frame[1]
	if not is_nan(label_a):
		out["text_uv"] = apex + Vector2(cos(label_a), sin(label_a)) * r
		return out
	var mid_angle := a1 + sweep * 0.5
	var mid_dir := Vector2(cos(mid_angle), sin(mid_angle))
	var t2: Vector2 = frame[0]
	var up2: Vector2 = frame[1]
	var push := absf(mid_dir.dot(t2)) * float(params["text_w"]) * 0.5 + absf(mid_dir.dot(up2)) * float(params["text_h"]) * 0.5 + gap
	out["text_uv"] = apex + mid_dir * (r + push)
	return out


static func _arc_length(c: Vector2, r: float, a0: float, sweep: float, ra: float, label_a: float, params: Dictionary) -> Dictionary:
	## The length of an arc: a dimension arc concentric with it, outside it (radius ra when saved, else the automatic offset), extension lines radially out from
	## its two ends and the value at its middle (or where it was put).
	var out := _empty()
	if r < 0.00001 or absf(sweep) < 0.0001:
		return out
	var big := ra if not is_nan(ra) else r + float(params["offset"])
	_arc_core(out, c, big, a0, sweep, label_a, params)
	var gap := float(params["gap"])
	var over := float(params["over"])
	for angle in [a0, a0 + sweep]:
		var dir := Vector2(cos(angle), sin(angle))
		var s := signf(big - r)
		if absf(big - r) > gap * 1.5:
			out["segments"].append([c + dir * (r + s * gap), c + dir * (big + s * over)])
	var text_angle := 0.0
	var frame := _text_frame(text_angle)
	out["text_angle"] = text_angle
	out["text_up"] = frame[1]
	if not is_nan(label_a):
		out["text_uv"] = c + Vector2(cos(label_a), sin(label_a)) * big
		return out
	var mid_angle := a0 + sweep * 0.5
	var mid_dir := Vector2(cos(mid_angle), sin(mid_angle))
	var push := absf(mid_dir.dot(frame[0])) * float(params["text_w"]) * 0.5 + absf(mid_dir.dot(frame[1])) * float(params["text_h"]) * 0.5 + gap
	out["text_uv"] = c + mid_dir * (big + push)
	return out
