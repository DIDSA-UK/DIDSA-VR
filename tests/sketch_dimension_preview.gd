extends SceneTree
## S5 of docs/dimension-constraint-parity-plan.md: the Dimension tool's one preview at the laser (scripts/design_table/dimension_preview.gd), as logic.
##   * The label placement a pointer gives is the golden one: every case of tests/fixtures/sketch_label_placement_cases.json goes the other way
##     from tests/sketch_label_placement.gd (pointer -> placement, within 1e-3; "no placement" where the file says null), and that placement laid
##     out puts the label back at the case's label centre.
##   * On a session model: the kinds and their default; the stick's flicks (once per push) and who owns the stick (F3); the cycle wraps and stays
##     chosen; the two-point cursor rule until a kind is chosen; the angle sector from the laser, sticky near the rays (fix 2a), the quadrant and
##     value it gives the three angles; the label at the laser for every kind a line, a circle, an arc and the curve pairs offer; drop freezes
##     kind / placement / side and B steps back pad -> preview -> picking (F4); a driven (reference) candidate never goes to the pad; F7 off by
##     default and no preview with it on.
##   * Through the fake backend: confirming a drop posts the frozen side (quadrant) and saves the placement (PUT .../label); a full ellipse's axis saves its placement too (S6), an elliptical arc's does not.
## NOT checked here: the laser, the stick and B on the real input path (tests/design_table_dimension_preview.gd), the real backend (tests/e2e_sketch_dimension_drop.gd).
## Run: "$GODOT" --headless --path . --script res://tests/sketch_dimension_preview.gd  (see tests/README.md)

const Session := preload("res://scripts/design_table/sketch_session.gd")
const Flow := preload("res://scripts/design_table/dimension_preview.gd")
const DimLayout := preload("res://scripts/design_table/dimension_layout.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")
const FIXTURE := "res://tests/fixtures/sketch_label_placement_cases.json"
const TOL := 1e-3

var failures := 0
var _n := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


static func v(a: Array) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


func _params() -> Dictionary:
	return {"offset": 2.0, "arrow": 0.5, "gap": 0.2, "over": 0.3, "centroid": Vector2.ZERO, "text_h": 1.0, "text_w": 3.0}


func _point(s, p: Vector2) -> String:
	_n += 1
	var id := "p%d" % _n
	s.points[id] = p
	return id


func _line(s, a: Variant, b: Variant) -> String:
	_n += 1
	var id := "l%d" % _n
	s.lines[id] = {"a": _point(s, a if a is Vector2 else v(a)), "b": _point(s, b if b is Vector2 else v(b))}
	return id


func _circle(s, centre: Variant, rim: Variant) -> String:
	_n += 1
	var id := "c%d" % _n
	s.circles[id] = {"c": _point(s, centre if centre is Vector2 else v(centre)), "p": _point(s, rim if rim is Vector2 else v(rim)), "k": "k%d" % _n}
	return id


func _case_candidate(c: Dictionary, s) -> Dictionary:
	## A candidate {key, spec, apply} of the case's kind, built the way sketch_session.gd builds it (unplaced).
	var g: Dictionary = c["geometry"]
	var q: int = int(g["quadrant"]) if g.has("quadrant") else -1
	var side := str(g.get("side", "min"))
	match str(c["kind"]):
		"distance_linear":
			return {"key": "length", "spec": {"kind": "linear", "a": v(g["a"]), "b": v(g["b"])}}
		"ellipse_axis":
			return {"key": "majordiameter", "spec": {"kind": "linear", "a": v(g["opposite_tip"]), "b": v(g["tip"])}}
		"distance_horizontal":
			return {"key": "h", "spec": {"kind": "horizontal", "a": v(g["a"]), "b": v(g["b"])}}
		"distance_vertical":
			return {"key": "v", "spec": {"kind": "vertical", "a": v(g["a"]), "b": v(g["b"])}}
		"point_line_distance":
			return {"key": "perpendicular", "spec": s.perp_spec(_point(s, v(g["point"])), _line(s, g["line_start"], g["line_end"]))}
		"line_distance":
			var l1 := _line(s, g["line1_start"], g["line1_end"])
			var l2 := _line(s, g["line2_start"], g["line2_end"])
			return {"key": "lineDistance", "spec": s.line_distance_spec(l1, l2), "apply": {"create": {"type": "line_distance", "line1_id": l1, "line2_id": l2}}}
		"radius", "diameter":
			return {"key": str(c["kind"]), "spec": s.circle_spec(str(c["kind"]), _circle(s, g["center"], g["rim"]))}
		"angle":
			return {"key": "angle", "spec": s.angle_spec(_line(s, g["line1_start"], g["line1_end"]), _line(s, g["line2_start"], g["line2_end"]), float(g.get("value_degrees", -1.0)), q)}
		"arc_length":
			_n += 1
			var arc_id := "a%d" % _n
			s.arcs[arc_id] = {"c": _point(s, v(g["center"])), "s": _point(s, v(g["start"])), "e": _point(s, v(g["end"])), "k": ""}
			return {"key": "arcLength", "spec": s.arc_length_spec(arc_id)}
		"horizontal_angle":
			return {"key": "horizontalAngle", "spec": s.horizontal_angle_spec(_line(s, g["line_start"], g["line_end"]), q)}
		"point_angle":
			return {"key": "pointAngle", "spec": s.point_angle_spec(_point(s, v(g["vertex"])), _point(s, v(g["point1"])), _point(s, v(g["point2"])), q)}
		"point_circle_distance":
			var pt := _point(s, v(g["point"]))
			return {"key": side + "Distance", "spec": s.point_circle_spec(pt, _circle(s, g["center"], g["rim"]), side)}
		"circle_distance":
			var c1 := _circle(s, g["center1"], g["rim1"])
			return {"key": side + "Distance", "spec": s.circle_circle_spec(c1, _circle(s, g["center2"], g["rim2"]), side)}
		"line_circle_distance":
			var ln := _line(s, g["line_start"], g["line_end"])
			return {"key": "tangentDistance" if side == "min" else "farDistance", "spec": s.line_circle_spec(ln, _circle(s, g["center"], g["rim"]), side)}
	return {}


func _same_place(got: Dictionary, want: Dictionary) -> bool:
	if got.size() != want.size():
		return false
	for k in want:
		if not got.has(k) or absf(float(got[k]) - float(want[k])) > TOL:
			return false
	return true


func _label_at(s, g: Dictionary) -> Vector2:
	var layout := DimLayout.layout(g["spec"], _params())
	return layout["text_uv"]


func _golden_cases() -> void:
	var doc = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var wrong: Array = []
	var moved: Array = []
	var count := 0
	var nulls := 0
	for c in doc["cases"]:
		for ptr in c["pointers"]:
			var s := Session.new()
			var g := _case_candidate(c, s)
			var p := v(ptr["pointer"])
			var got := Flow.placement_at(s, g, p)
			if ptr["placement"] == null:
				nulls += 1
				if not got.is_empty():
					wrong.append("%s %s: %s for none" % [c["kind"], p, got])
				continue
			count += 1
			if not _same_place(got, ptr["placement"]):
				wrong.append("%s (%s) %s: %s want %s" % [c["kind"], c["name"], p, got, ptr["placement"]])
				continue
			g["spec"] = Flow.placed_spec(s, g, got)
			var at := _label_at(s, g)
			if at.distance_to(v(ptr["label_center"])) > TOL:
				moved.append("%s %s: label at %s want %s" % [c["kind"], p, at, ptr["label_center"]])
	_check(wrong.is_empty() and count == 63 and nulls == 3, "every golden pointer gives the case's placement (63, within 1e-3) and the three 'none' pointers give none %s" % [wrong])
	_check(moved.is_empty(), "...and that placement, read back as a saved one is, puts the label at the case's label centre %s" % [moved])


func _session_with(picks: Array, s) -> void:
	s.selection = picks
	s.ghosts = s._build_ghosts()


func _flow_logic() -> void:
	var s := Session.new()
	var line := _line(s, Vector2(0, 0), Vector2(40, 30))
	var f := Flow.new()
	_check(not f.show_all and f.stage == "picking" and not f.live(), "F7: one preview is the default; nothing picked, nothing previewed")
	_session_with([{"kind": "line", "id": line}], s)
	f.sync(s)
	_check(f.stage == "preview" and f.live() and f.current_key(s, Vector2(50, 0)) == "length", "a line picked: the preview is live, Length (the default) first")
	var g := f.preview(s, Vector2(10, 20), 1.0)
	_check(g["key"] == "length" and _label_at(s, g).distance_to(Vector2(10, 20)) < TOL, "...its label sits at the laser")
	# --- the stick: a flick is one step, held is no more, back near the middle re-arms
	_check(f.stick(0.8) == 1 and f.stick(0.95) == 0 and f.stick(0.5) == 0 and f.stick(0.1) == 0 and f.stick(-0.7) == -1 and f.stick(-0.2) == 0 and f.stick(0.65) == 1,
		"the stick steps once per flick (0.6 out), held or wavering does nothing more, back under 0.3 re-arms")
	f.stick(0.0)
	_check(Flow.owns_stick(true, true, false) and not Flow.owns_stick(true, true, true) and not Flow.owns_stick(true, false, false) and not Flow.owns_stick(false, true, false),
		"F3: the stick is the preview's only with a preview live and the laser on the sheet; gripped, with Orbit lock off (the default argument), it is the table's")
	_check(Flow.owns_stick(true, true, true, true) and Flow.owns_stick(true, true, false, true) and not Flow.owns_stick(true, true, true, false) and not Flow.owns_stick(true, false, true, true) and not Flow.owns_stick(false, true, true, true),
		"F2 (decision 1): with Orbit lock on a grip does not take the stick (cycling works while the other hand holds the table); with it off a grip does; no preview or the laser off the sheet: never")
	var keys: Array = []
	for i in 5:
		keys.append(f.cycle(s, Vector2(10, 20), 1))
	_check(keys == ["h", "v", "horizontalAngle", "length", "h"], "the cycle steps through the four kinds and wraps (%s)" % [keys])
	_check(f.cycle(s, null, -1) == "length" and f.cycle(s, null, -1) == "horizontalAngle", "...and back the other way")
	_check(f.preview(s, Vector2(-30, 5), 1.0)["key"] == "horizontalAngle", "a kind once chosen stays chosen wherever the laser goes")
	_check(f.choose(s, "v") and f.current_key(s, Vector2.ZERO) == "v" and not f.choose(s, "radius"), "the options row chooses a kind of the pick (not another's)")
	# every kind of a line: the label at the laser
	var off: Array = []
	for k in ["length", "h", "v", "horizontalAngle"]:
		f.choose(s, k)
		for p in [Vector2(12, 25), Vector2(45, -8), Vector2(-6, 14)]:
			var pg := f.preview(s, p, 0.5)
			if _label_at(s, pg).distance_to(p) > TOL:
				off.append("%s %s" % [k, p])
	_check(off.is_empty(), "every kind of a line is laid out with its label at the laser %s" % [off])

	# --- a new pick forgets the kind; two points: the cursor rule until a kind is chosen
	var pa := _point(s, Vector2(100, 100))
	var pb := _point(s, Vector2(140, 120))
	_session_with([{"kind": "point", "id": pa}, {"kind": "point", "id": pb}], s)
	f.sync(s)
	_check(f.chosen == "", "a new pick starts with no kind chosen")
	_check(f.current_key(s, Vector2(120, 150)) == "h" and f.current_key(s, Vector2(120, 60)) == "h", "two points: the laser above or below the pair's box gives Horizontal")
	_check(f.current_key(s, Vector2(170, 110)) == "v" and f.current_key(s, Vector2(80, 110)) == "v", "...left or right of it, Vertical")
	_check(f.current_key(s, Vector2(120, 110)) == "linear" and f.current_key(s, Vector2(170, 150)) == "linear", "...inside it or off a corner, Aligned")
	f.cycle(s, Vector2(120, 150), 1)
	_check(f.chosen == "v" and f.current_key(s, Vector2(120, 150)) == "v", "the stick from Horizontal (the cursor rule's) goes on to Vertical, and it then stays whatever the box says")

	# --- the two-line angle: the sector from the laser, sticky near the rays
	var l1 := _line(s, Vector2(0, -100), Vector2(50, -100)) # along +x from (0,-100)
	var l2 := _line(s, Vector2(0, -100), Vector2(30, -70)) # 45 degrees
	_session_with([{"kind": "line", "id": l1}, {"kind": "line", "id": l2}], s)
	f.sync(s)
	var apex := Vector2(0, -100)
	_check(s.ghosts.size() == 1 and f.current_key(s, apex) == "angle", "two lines that meet: one candidate, the angle")
	var a0 := f.preview(s, apex + Vector2(20, 6), 1.0)
	_check(int(a0["quadrant"]) == 0 and is_equal_approx(float(a0["value"]), 45.0) and int(a0["apply"]["create"]["quadrant"]) == 0, "the laser between the two outward rays: quadrant 0, 45 degrees, the quadrant in the create body")
	var a1 := f.preview(s, apex + Vector2(-20, 6), 1.0)
	_check(int(a1["quadrant"]) == 1 and is_equal_approx(float(a1["value"]), 135.0), "past the first ray's back: quadrant 1 (that ray flipped), 135 degrees")
	_check(_label_at(s, a1).distance_to(apex + Vector2(-20, 6)) < TOL, "...its label at the laser")
	var near := f.preview(s, apex + Vector2(-20, 0.4), 1.0)
	_check(int(near["quadrant"]) == 1, "STICKY: on (within the band of) the first ray's line, the sector chosen stays (fix 2a)")
	var near2 := f.preview(s, apex + Vector2(20, 0.4), 1.0)
	_check(int(near2["quadrant"]) == 1, "...on the other side of the vertex too, still within the band")
	_check(int(f.preview(s, apex + Vector2(0.3, 0.2), 1.0)["quadrant"]) == 1, "...and on the vertex")
	_check(int(f.preview(s, apex + Vector2(-20, -6), 1.0)["quadrant"]) == 3 and int(f.preview(s, apex + Vector2(10, -20), 1.0)["quadrant"]) == 2,
		"only another sector's open area changes it (opposite: 3, the second ray flipped: 2)")
	_session_with([{"kind": "line", "id": l2}, {"kind": "line", "id": l1}], s)
	f.sync(s)
	var fresh_angle := f.preview(s, apex + Vector2(20, 0.4), 1.0)
	_check(int(fresh_angle.get("quadrant", -1)) == 0, "a new line pair forgets the sector: on a line before any sector, the sector the candidate is drawn in (made explicit)")

	# --- three points: the angle at the first
	var v0 := _point(s, Vector2(-100, 0))
	var v1 := _point(s, Vector2(-60, 0))
	var v2 := _point(s, Vector2(-100, 40))
	_session_with([{"kind": "point", "id": v0}, {"kind": "point", "id": v1}, {"kind": "point", "id": v2}], s)
	f.sync(s)
	var pa0 := f.preview(s, Vector2(-90, 10), 1.0)
	var pa1 := f.preview(s, Vector2(-110, 10), 1.0)
	_check(pa0["key"] == "pointAngle" and int(pa0["apply"]["create"]["quadrant"]) == 0 and is_equal_approx(float(pa0["value"]), 90.0) and int(pa1["apply"]["create"]["quadrant"]) == 1,
		"three points: the angle at the first, its sector from the laser (0 between the rays, 1 past the first ray's back)")
	_check(int(f.preview(s, Vector2(-110, 0.3), 1.0)["quadrant"]) == 1, "...sticky near its rays as well")

	# --- the angle to horizontal: the nearer end, the side of its vertical
	_session_with([{"kind": "line", "id": line}], s)
	f.sync(s)
	f.choose(s, "horizontalAngle")
	var h0 := f.preview(s, Vector2(10, 2), 1.0)
	var h3 := f.preview(s, Vector2(35, 32), 1.0)
	_check(int(h0["apply"]["create"]["quadrant"]) == 0 and is_equal_approx(float(h0["value"]), rad_to_deg(atan2(30.0, 40.0))), "angle to horizontal near the start, right of it: quadrant 0, the line's own angle")
	_check(int(h3["apply"]["create"]["quadrant"]) == 3 and is_equal_approx(float(h3["value"]), rad_to_deg(atan2(30.0, 40.0))) and int(f.preview(s, Vector2(45, 32), 1.0)["quadrant"]) == 1,
		"...near the end, left of it: quadrant 3 (at the end, towards -x); right of the end: 1")

	# --- every kind of a circle, an arc and the curve pairs: the label at the laser
	var cc := _circle(s, Vector2(200, 0), Vector2(210, 0))
	_n += 1
	s.arcs["arc"] = {"c": _point(s, Vector2(300, 0)), "s": _point(s, Vector2(320, 0)), "e": _point(s, Vector2(300, 20)), "k": "karc"}
	var cpt := _point(s, Vector2(158, 40)) # (not straight above the line's end: a zero horizontal distance has nothing to draw)
	var cl := _line(s, Vector2(150, -60), Vector2(260, -60))
	var cc2 := _circle(s, Vector2(260, 60), Vector2(265, 60))
	off = []
	var kinds_seen: Array = []
	for picks in [[{"kind": "circle", "id": cc}], [{"kind": "arc", "id": "arc"}], [{"kind": "point", "id": cpt}, {"kind": "circle", "id": cc}],
			[{"kind": "line", "id": cl}, {"kind": "circle", "id": cc}], [{"kind": "circle", "id": cc}, {"kind": "circle", "id": cc2}], [{"kind": "point", "id": cpt}, {"kind": "line", "id": cl}]]:
		_session_with(picks, s)
		f.sync(s)
		for cand in s.ghosts:
			f.choose(s, str(cand["key"]))
			kinds_seen.append(cand["key"])
			for p in [Vector2(230, 30), Vector2(180, -20)]:
				var pg := f.preview(s, p, 0.5)
				if pg["place"].is_empty() or _label_at(s, pg).distance_to(p) > TOL:
					off.append("%s %s" % [cand["key"], p])
	_check(off.is_empty() and kinds_seen.size() >= 20, "every kind of a circle, an arc, a point / line / circle with a circle and a point with a line: the label at the laser (%d kinds) %s" % [kinds_seen.size(), off])

	# --- drop and step back
	_session_with([{"kind": "line", "id": line}], s)
	f.sync(s)
	var dropped := f.drop(s, Vector2(10, 20), 1.0)
	_check(f.stage == "pad" and not f.live() and f.frozen["key"] == "length" and not (f.frozen["place"] as Dictionary).is_empty() and dropped == f.frozen,
		"a drop freezes the kind and the placement and goes to the pad")
	f.preview(s, Vector2(-50, -50), 1.0)
	_check((f.frozen["place"] as Dictionary) == (dropped["place"] as Dictionary), "...the laser moving on does not move what was dropped")
	_check(f.step_back(s) == "preview" and f.stage == "preview" and f.frozen.is_empty() and s.selection.size() == 1, "B from the pad: back to the preview, the pick kept")
	_check(f.step_back(s) == "picking" and f.stage == "picking" and s.selection.is_empty() and s.ghosts.is_empty(), "B from the preview: back to picking, the pick let go")
	_check(f.step_back(s) == "", "B with nothing picked: nothing to step back from (B does what it did)")
	_session_with([{"kind": "line", "id": l1}, {"kind": "line", "id": l2}], s)
	f.sync(s)
	f.preview(s, apex + Vector2(-20, 6), 1.0)
	var ad := f.drop(s, apex + Vector2(-20, 0.3), 1.0)
	_check(int(ad["apply"]["create"]["quadrant"]) == 1, "an angle dropped near a ray keeps the sector it had (the side is frozen with it)")
	f.step_back(s)
	# a driven candidate never goes to the pad
	var pinned := Session.new()
	var pl := _line(pinned, Vector2(0, 0), Vector2(10, 0))
	for pid in pinned.points:
		pinned.point_locked[pid] = true
	_session_with([{"kind": "line", "id": pl}], pinned)
	var pf := Flow.new()
	pf.sync(pinned)
	var dg := pf.drop(pinned, Vector2(5, 3), 1.0)
	_check(bool(dg.get("driven", false)) and pf.stage == "preview" and pf.frozen.is_empty(), "between pinned things the candidate is driven: a drop does not open the pad (the caller keeps it)")
	pf.show_all = true
	_check(not pf.live(), "F7 on (every candidate at once): no preview follows the laser")


func _through_the_fake() -> void:
	var fake := Fake.new()
	var s = Session.new(Callable(fake, "handle"))
	s.owner_part_id = "P"
	await s.open_sketch({"fixed": "XY"})
	s.set_tool("line")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(40, 0)})
	s.finish_chain()
	s.set_tool("line")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(30, 30)})
	s.finish_chain()
	s.set_tool("dimension")
	var ids: Array = s.lines.keys()
	await s.select({"kind": "line", "id": str(ids[0])})
	var f := Flow.new()
	f.sync(s)
	var g := f.drop(s, Vector2(20, 9), 0.5)
	fake.calls.clear()
	var r: Dictionary = await s.confirm_ghost(str(g["key"]), 42.0, f.frozen)
	var posts := fake.calls.filter(func(c): return c[0].ends_with("/constraints") and c[0].begins_with("POST"))
	var puts := fake.calls.filter(func(c): return c[0].begins_with("PUT") and c[0].ends_with("/label"))
	_check(r["ok"] and posts.size() == 1 and float(posts[0][1]["distance"]) == 42.0, "confirming a dropped Length makes the dimension with the typed value")
	_check(puts.size() == 1 and puts[0][0].contains(str(fake.cons.keys()[-1])) and _same_place(puts[0][1], g["place"]), "...and saves the dropped placement on it (PUT .../constraints/{id}/label)")
	var item: Dictionary = {}
	for it in s.dimension_items():
		item = it
	_check(not item.is_empty() and DimLayout.layout(item["spec"], _params())["text_uv"].distance_to(Vector2(20, 9)) < TOL, "...so the made dimension is drawn with its label where it was dropped")
	await s.select({"kind": "line", "id": str(ids[0])})
	await s.select({"kind": "line", "id": str(ids[1])})
	f.sync(s)
	f.preview(s, Vector2(-10, 3), 0.5)
	g = f.drop(s, Vector2(-10, 3), 0.5)
	fake.calls.clear()
	r = await s.confirm_ghost("angle", 135.0, f.frozen)
	posts = fake.calls.filter(func(c): return c[0].ends_with("/constraints") and c[0].begins_with("POST"))
	_check(r["ok"] and posts.size() == 1 and int(posts[0][1].get("quadrant", -1)) == 1 and float(posts[0][1]["angle_degrees"]) == 135.0, "a dropped two-line angle posts the sector the laser chose (quadrant 1) with the value")
	# a full ellipse's axis is drawn tip to tip like the flat app's, so its placement is saved like any other (S6); an elliptical arc's axis is read radially there, so not
	fake.calls.clear()
	var e := {"key": "majorradius", "place": {"offset": 1.0, "along": 0.0}, "apply": {"patch_id": str(fake.cons.keys()[0]), "factor": 1.0}}
	s.ghosts = [e]
	await s.confirm_ghost("majorradius", 12.0, e)
	_check(fake.calls.filter(func(c): return c[0].begins_with("PUT") and c[0].ends_with("/label")).size() == 1, "a full ellipse's axis placement is saved (S6)")
	fake.calls.clear()
	e = {"key": "majorradius", "place": {"offset": 1.0, "along": 0.0}, "place_unsaved": true, "apply": {"patch_id": str(fake.cons.keys()[0]), "factor": 1.0}}
	s.ghosts = [e]
	await s.confirm_ghost("majorradius", 12.0, e)
	_check(fake.calls.filter(func(c): return c[0].ends_with("/label")).is_empty(), "an elliptical arc's axis placement is not written from here")


func _initialize() -> void:
	_golden_cases()
	_flow_logic()
	await _through_the_fake()
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
