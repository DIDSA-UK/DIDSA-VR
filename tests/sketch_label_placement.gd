extends SceneTree
## S2 of docs/dimension-constraint-parity-plan.md: a saved label placement is drawn where it says, for every dimension type, against the golden cases both
## apps share (tests/fixtures/sketch_label_placement_cases.json, a copy of DIDSA-CAD's docs/sketch-label-placement-cases.json: per kind a geometry, three
## pointers, the placement the pointer gives and the label's centre that placement lays out).
## Each case's geometry is put into a SketchSession's own dictionaries, the saved placement goes through the spec builder the dimension is drawn with
## (circle_spec, angle_spec, arc_length_spec ...), dimension_layout.gd lays it out, and the label's centre (`text_uv`) must be the case's. Float32 vectors:
## the tolerance is 1e-3 sketch units, not the file's 1e-9 (the Dart doubles). Also the pieces that have no case: a placement with none of a kind's keys is
## ignored (the automatic layout), a missing placement leaves the automatic layout alone, and the quadrant / value rule of the two-line angle.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_label_placement.gd  (see tests/README.md)

const Session := preload("res://scripts/design_table/sketch_session.gd")
const DimLayout := preload("res://scripts/design_table/dimension_layout.gd")
const FIXTURE := "res://tests/fixtures/sketch_label_placement_cases.json"
const TOL := 1e-3

var failures := 0
var _n := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _source_check(text: String) -> String:
	var dir := OS.get_environment("DIDSA_CAD_DIR")
	var candidates: Array[String] = []
	if dir != "":
		candidates.append(dir.path_join("docs/sketch-label-placement-cases.json"))
	candidates.append(ProjectSettings.globalize_path("res://").path_join("../DIDSA-CAD/docs/sketch-label-placement-cases.json"))
	for p in candidates:
		if FileAccess.file_exists(p):
			return "same" if FileAccess.get_file_as_string(p) == text else "DIFFERENT (%s)" % p
	return "no source"


static func v(a: Array) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


func _params() -> Dictionary:
	return {"offset": 2.0, "arrow": 0.5, "gap": 0.2, "over": 0.3, "centroid": Vector2.ZERO, "text_h": 1.0, "text_w": 3.0}


func _point(s: Session, p: Vector2) -> String:
	_n += 1
	var id := "p%d" % _n
	s.points[id] = p
	return id


func _line(s: Session, a: Array, b: Array) -> String:
	var id := "l%d" % _n
	_n += 1
	s.lines[id] = {"a": _point(s, v(a)), "b": _point(s, v(b))}
	return id


func _circle(s: Session, centre: Array, rim: Array) -> String:
	var id := "c%d" % _n
	_n += 1
	s.circles[id] = {"c": _point(s, v(centre)), "p": _point(s, v(rim)), "k": ""}
	return id


func _spec_for(c: Dictionary, s: Session, place: Dictionary) -> Dictionary:
	## The spec the dimension of this case's kind is drawn with, its placement as the backend would hold it.
	var g: Dictionary = c["geometry"]
	var quadrant: int = int(g["quadrant"]) if g.has("quadrant") else -1
	var side := str(g.get("side", "min"))
	match str(c["kind"]):
		"distance_linear", "ellipse_axis":
			var a: Vector2 = v(g["a"]) if g.has("a") else v(g["opposite_tip"])
			var b: Vector2 = v(g["b"]) if g.has("b") else v(g["tip"])
			return Session._linear_between(a, b, place)
		"distance_horizontal", "distance_vertical":
			var kind := "horizontal" if c["kind"] == "distance_horizontal" else "vertical"
			return {"kind": kind, "a": v(g["a"]), "b": v(g["b"]), "place": Session._linear_place(place)}
		"point_line_distance":
			var l := _line(s, g["line_start"], g["line_end"])
			return s.perp_spec(_point(s, v(g["point"])), l, place)
		"line_distance":
			return s.line_distance_spec(_line(s, g["line1_start"], g["line1_end"]), _line(s, g["line2_start"], g["line2_end"]), place)
		"radius", "diameter":
			return s.circle_spec(str(c["kind"]), _circle(s, g["center"], g["rim"]), place)
		"angle":
			return s.angle_spec(_line(s, g["line1_start"], g["line1_end"]), _line(s, g["line2_start"], g["line2_end"]), float(g.get("value_degrees", -1.0)), quadrant, place)
		"arc_length":
			var arc_id := "a%d" % _n
			_n += 1
			s.arcs[arc_id] = {"c": _point(s, v(g["center"])), "s": _point(s, v(g["start"])), "e": _point(s, v(g["end"])), "k": ""}
			return s.arc_length_spec(arc_id, place)
		"horizontal_angle":
			return s.horizontal_angle_spec(_line(s, g["line_start"], g["line_end"]), quadrant, -1.0, place)
		"point_angle":
			return s.point_angle_spec(_point(s, v(g["vertex"])), _point(s, v(g["point1"])), _point(s, v(g["point2"])), quadrant, place)
		"point_circle_distance":
			var pt := _point(s, v(g["point"]))
			return s.point_circle_spec(pt, _circle(s, g["center"], g["rim"]), side, place)
		"circle_distance":
			var c1 := _circle(s, g["center1"], g["rim1"])
			return s.circle_circle_spec(c1, _circle(s, g["center2"], g["rim2"]), side, place)
		"line_circle_distance":
			var ln := _line(s, g["line_start"], g["line_end"])
			return s.line_circle_spec(ln, _circle(s, g["center"], g["rim"]), side, place)
	return {}


func _initialize() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	var doc = JSON.parse_string(text)
	if not (doc is Dictionary):
		print("SMOKE FAILED: couldn't read ", FIXTURE)
		quit(1)
		return
	var src := _source_check(text)
	_check(src == "same" or src == "no source", "the fixture copy equals DIDSA-CAD's docs/sketch-label-placement-cases.json (%s)" % src)
	var per_kind := {}
	var wrong: Array = []
	var automatic_ok := true
	var count := 0
	for c in doc["cases"]:
		for ptr in c["pointers"]:
			if ptr["placement"] == null:
				continue
			var s := Session.new()
			var spec := _spec_for(c, s, ptr["placement"])
			var layout := DimLayout.layout(spec, _params()) if not spec.is_empty() else {}
			var want := v(ptr["label_center"])
			var got: Vector2 = layout.get("text_uv", Vector2(INF, INF))
			count += 1
			per_kind[c["kind"]] = int(per_kind.get(c["kind"], 0)) + 1
			if layout.is_empty() or not got.is_finite() or got.distance_to(want) > TOL:
				wrong.append("%s / %s: pointer %s want %s got %s" % [c["kind"], c["name"], ptr["pointer"], want, got])
			# the same geometry with no placement is still drawn (the automatic layout)
			var plain := DimLayout.layout(_spec_for(c, Session.new(), {}), _params())
			if (plain["segments"] as Array).is_empty() and (plain["arcs"] as Array).is_empty() and (plain["arrows"] as Array).is_empty():
				automatic_ok = false
	for w in wrong.slice(0, 6):
		print("  MISMATCH ", w)
	_check(count >= 40 and wrong.is_empty(), "every golden placement lays its label's centre where the case says (%d placements, %d kinds, %d wrong)" % [count, per_kind.size(), wrong.size()])
	_check(per_kind.size() >= 15, "...across every kind the file holds (%s)" % str(per_kind.keys()))
	_check(automatic_ok, "...and the same geometry with no placement is still drawn by the automatic layout")

	# a placement that holds none of a kind's keys is not that kind's placement: ignored
	var s2 := Session.new()
	var l := _line(s2, [0, 0], [10, 0])
	var k1 := _circle(s2, [30, 8], [35, 8])
	s2.constraints = {"d": {"type": "line_circle_distance", "id": "d", "line_id": l, "circle_or_arc_id": k1, "distance": 5.0, "side": "min", "label": {"angle": 10.0, "leg": 1.0}}}
	var items: Array = s2.dimension_items()
	_check(items.size() == 1 and not (items[0]["spec"] as Dictionary).has("place"), "a placement without `offset` / `along` leaves a linear dimension to the automatic layout (no `place` in its spec)")
	# the quadrant of a two-line angle: bit 0 flips the first ray, bit 1 the second; none saved, the value picks the sector
	var s3 := Session.new()
	var l1 := _line(s3, [0, 0], [10, 0])
	var l2 := _line(s3, [2, 2], [6, 6])
	var q0 := s3.angle_spec(l1, l2, 45.0, 0)
	var q1 := s3.angle_spec(l1, l2, 135.0, 1)
	var by_value := s3.angle_spec(l1, l2, 135.0)
	var near := s3.angle_spec(l1, l2)
	_check(absf(rad_to_deg(absf(wrapf((q0["d2"] as Vector2).angle() - (q0["d1"] as Vector2).angle(), -PI, PI))) - 45.0) < 0.01
		and absf(rad_to_deg(absf(wrapf((q1["d2"] as Vector2).angle() - (q1["d1"] as Vector2).angle(), -PI, PI))) - 135.0) < 0.01
		and absf(rad_to_deg(absf(wrapf((by_value["d2"] as Vector2).angle() - (by_value["d1"] as Vector2).angle(), -PI, PI))) - 135.0) < 0.01
		and absf(rad_to_deg(absf(wrapf((near["d2"] as Vector2).angle() - (near["d1"] as Vector2).angle(), -PI, PI))) - 45.0) < 0.01, "a two-line angle draws the sector the backend measures: quadrant 0 is the 45 degree one, quadrant 1 the 135 degree one, no quadrant follows the value, a candidate the nearer")
	# the angle to horizontal with no quadrant: the value picks the horizontal ray
	var s4 := Session.new()
	var hl := _line(s4, [2, 1], [8, 7])
	var h_plus := s4.horizontal_angle_spec(hl, -1, 45.0)
	var h_minus := s4.horizontal_angle_spec(hl, -1, 135.0)
	_check((h_plus["d2"] as Vector2) == Vector2(1, 0) and (h_minus["d2"] as Vector2) == Vector2(-1, 0) and (h_plus["apex"] as Vector2) == Vector2(2, 1), "an angle to horizontal with no quadrant uses the +x ray for 45 degrees and the -x ray for 135 (from the line's start)")
	# the reference dimensions of the part D kinds are drawn too (no saved placement: the automatic layout)
	var s5 := Session.new()
	var arc_id := "arcx"
	s5.arcs[arc_id] = {"c": _point(s5, Vector2(0, 0)), "s": _point(s5, Vector2(10, 0)), "e": _point(s5, Vector2(0, 10)), "k": ""}
	var pa := _point(s5, Vector2(30, 0))
	var pb := _point(s5, Vector2(40, 10))
	var ln5 := _line(s5, [0, 20], [30, 20])
	var circ := _circle(s5, [20, -20], [25, -20])
	var circ2 := _circle(s5, [-20, -20], [-17, -20])
	s5.ref_dims = [
		{"id": "r1", "kind": "arc_length", "refs": [{"type": "arc", "id": arc_id}], "value": 15.71},
		{"id": "r2", "kind": "horizontal_angle", "refs": [{"type": "line", "id": ln5}], "value": 0.0},
		{"id": "r3", "kind": "point_angle", "refs": [{"type": "point", "id": pa}, {"type": "point", "id": pb}, {"type": "point", "id": s5.arcs[arc_id]["c"]}], "value": 30.0},
		{"id": "r4", "kind": "min_distance", "refs": [{"type": "point", "id": pa}, {"type": "circle", "id": circ}], "value": 10.0},
		{"id": "r5", "kind": "max_distance", "refs": [{"type": "circle", "id": circ}, {"type": "circle", "id": circ2}], "value": 50.0},
		{"id": "r6", "kind": "min_distance", "refs": [{"type": "circle", "id": circ}, {"type": "line", "id": ln5}], "value": 30.0}]
	var ref_items: Array = s5.driven_items()
	var texts: Array = ref_items.map(func(i): return i["text"])
	var kinds: Array = ref_items.map(func(i): return i["spec"]["kind"])
	_check(ref_items.size() == 6 and texts[0] == "(⌒15.71)" and kinds[0] == "arc_length" and kinds[1] == "angle" and kinds[2] == "angle" and kinds[3] == "linear" and kinds[4] == "linear" and kinds[5] == "linear" and texts[2] == "(30°)",
		"...an arc length as the arc sign and its number, the angles as degrees, the three distances as linear dimensions between the measured ends")
	var min_pt := Session.new()
	var mp := _point(min_pt, Vector2(0, 0))
	var mc := _circle(min_pt, [10, 0], [13, 0])
	var ml := min_pt.point_circle_spec(mp, mc, "min")
	var mx := min_pt.point_circle_spec(mp, mc, "max")
	_check((ml["b"] as Vector2).is_equal_approx(Vector2(7, 0)) and (mx["b"] as Vector2).is_equal_approx(Vector2(13, 0)), "the nearest distance from a point to a circle runs to the circle's near side (7 away), the farthest to the far side (13)")
	print(("SMOKE PASSED" if failures == 0 else "SMOKE FAILED"))
	quit(1 if failures > 0 else 0)
