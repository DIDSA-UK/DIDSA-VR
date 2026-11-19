extends SceneTree
## The Dimension tool's options against DIDSA-CAD's docs/sketch-dimension-catalogue.json (S4 of docs/dimension-constraint-parity-plan.md; the file is read in TESTS ONLY,
## tests/fixtures/sketch_dimension_catalogue.json is a copy, compared with the CAD checkout's when it is next to this one). For every entry: a session model with the
## selection built in pick order (and, for the unordered ones, the other order), under each combination of the conditions the entry or its options name; the candidates the
## session offers are compared with the file: keys, labels, order, the default (the first), what each creates (the constraint type, its orientation or side, or the circle's
## own size), the `side: pointer` marks, and the cursor rule. Then the file's notes (what is offered for nothing), the pick rules, and the `pinned` block (the reference kinds
## offered between pinned things). No backend. No expected failures.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_dimension_catalogue.gd  (see tests/README.md)

const SketchSession := preload("res://scripts/design_table/sketch_session.gd")
const FIXTURE := "res://tests/fixtures/sketch_dimension_catalogue.json"

var failures := 0
var checks := 0


func _check(ok: bool, what: String, detail := "") -> void:
	checks += 1
	if not ok:
		failures += 1
	print("SMOKE ", what, ": ", ok, " ", detail if not ok else "")


# --- building a selection -------------------------------------------------------------

func _pt(s, id: String, v: Vector2) -> String:
	s.points[id] = v
	return id


func _line(s, id: String, a: Vector2, b: Vector2) -> String:
	s.points[id + "_a"] = a
	s.points[id + "_b"] = b
	s.lines[id] = {"a": id + "_a", "b": id + "_b", "construction": false}
	return id


func _circle(s, id: String, c: Vector2, r: float) -> String:
	s.points[id + "_c"] = c
	s.points[id + "_p"] = c + Vector2(r, 0)
	s.circles[id] = {"c": id + "_c", "p": id + "_p", "k": "K" + id, "cards": [], "construction": false}
	return id


func _arc(s, id: String, c: Vector2, r: float) -> String:
	s.points[id + "_c"] = c
	s.points[id + "_s"] = c + Vector2(r, 0)
	s.points[id + "_e"] = c + Vector2(0, r)
	s.arcs[id] = {"c": id + "_c", "s": id + "_s", "e": id + "_e", "k": "K" + id, "construction": false}
	return id


func _ellipse(s, id: String, c: Vector2) -> String:
	s.points[id + "_c"] = c
	s.points[id + "_ma"] = c + Vector2(20, 0)
	s.points[id + "_mi"] = c + Vector2(0, 10)
	s.ellipses[id] = {"c": id + "_c", "ma": id + "_ma", "mi": id + "_mi", "man": "", "mnn": "", "km": "KM" + id, "kn": "KN" + id, "construction": false}
	return id


func _ellipse_arc(s, id: String, c: Vector2) -> String:
	s.points[id + "_c"] = c
	s.points[id + "_ma"] = c + Vector2(20, 0)
	s.points[id + "_mi"] = c + Vector2(0, 10)
	s.points[id + "_s"] = c + Vector2(20, 0)
	s.points[id + "_e"] = c + Vector2(-20, 0)
	s.ellipse_arcs[id] = {"c": id + "_c", "ma": id + "_ma", "mi": id + "_mi", "s": id + "_s", "e": id + "_e", "construction": false}
	return id


## The conditions, as a dictionary of what the geometry should do; `good` is the one where nothing is excluded.
const GOOD := {"parallel": true, "point_on_end": false, "point_of_curve": false, "apart": true, "misses": true}


func build(picks: Array, p: Dictionary) -> Array:
	## [session, selection]: the geometry for `picks` (in that order) with the relations in `p`.
	var s = SketchSession.new()
	var made: Array = []
	var key := "+".join(picks)
	match key:
		"line":
			made = [["line", _line(s, "L", Vector2(10, 10), Vector2(60, 30))]]
		"circle":
			made = [["circle", _circle(s, "C", Vector2(100, 100), 20)]]
		"arc":
			made = [["arc", _arc(s, "A", Vector2(100, 100), 20)]]
		"ellipse":
			made = [["ellipse", _ellipse(s, "E", Vector2(100, 100))]]
		"ellipse_arc":
			made = [["ellipse_arc", _ellipse_arc(s, "EA", Vector2(100, 100))]]
		"point+point":
			made = [["point", _pt(s, "p1", Vector2(10, 10))], ["point", _pt(s, "p2", Vector2(50, 40))]]
		"point+line":
			var l := _line(s, "L", Vector2(0, 0), Vector2(60, 0))
			made = [["point", "L_a" if bool(p["point_on_end"]) else _pt(s, "p1", Vector2(30, 20))], ["line", l]]
		"line+line":
			var l1 := _line(s, "L1", Vector2(0, 0), Vector2(60, 0))
			var l2 := _line(s, "L2", Vector2(0, 20), Vector2(60, 20)) if bool(p["parallel"]) else _line(s, "L2", Vector2(0, 20), Vector2(40, 50))
			made = [["line", l1], ["line", l2]]
		"point+circle", "point+arc":
			var curve := _circle(s, "C", Vector2(100, 100), 20) if key.ends_with("circle") else _arc(s, "C", Vector2(100, 100), 20)
			var own := "C_p" if key.ends_with("circle") else "C_s"
			made = [["point", own if bool(p["point_of_curve"]) else _pt(s, "p1", Vector2(200, 130))], [key.split("+")[1], curve]]
		"circle+circle", "circle+arc", "arc+arc":
			var kinds: Array = key.split("+")
			var far := Vector2(220, 100) if bool(p["apart"]) else Vector2(130, 100)
			var one := _circle(s, "C1", Vector2(100, 100), 20) if kinds[0] == "circle" else _arc(s, "C1", Vector2(100, 100), 20)
			var two := _circle(s, "C2", far, 30) if kinds[1] == "circle" else _arc(s, "C2", far, 30)
			made = [[kinds[0], one], [kinds[1], two]]
		"line+circle", "line+arc":
			var l := _line(s, "L", Vector2(0, 0), Vector2(200, 0))
			var centre := Vector2(100, 60) if bool(p["misses"]) else Vector2(100, 10)
			var curve := _circle(s, "C", centre, 20) if key.ends_with("circle") else _arc(s, "C", centre, 20)
			made = [["line", l], [key.split("+")[1], curve]]
		"point+point+point":
			made = [["point", _pt(s, "t0", Vector2(0, 0))], ["point", _pt(s, "t1", Vector2(30, 0))], ["point", _pt(s, "t2", Vector2(0, 40))]]
	return [s, made.map(func(m): return {"kind": m[0], "id": m[1]})]


func holds(cond, p: Dictionary) -> bool:
	## Whether a `when` of the catalogue is true under these relations.
	if cond == null:
		return true
	match str(cond):
		"lines_parallel":
			return bool(p["parallel"])
		"lines_not_parallel":
			return not bool(p["parallel"])
		"point_not_on_line_end":
			return not bool(p["point_on_end"])
		"point_not_of_curve":
			return not bool(p["point_of_curve"])
		"curves_apart":
			return bool(p["apart"])
		"line_misses_curve":
			return bool(p["misses"])
	return false


func vtext(v: Dictionary) -> String:
	## The relations in `v` as plain words ("plain" when nothing is excluded). (No ': false' in a check's text: the CI scan reads it as a failed assertion.)
	if v == GOOD:
		return "plain"
	var parts: Array = []
	for k in v:
		if v[k] != GOOD[k]:
			parts.append("%s flipped" % k)
	return ", ".join(parts)


func variants(entries: Array) -> Array:
	## Every combination of the relations the entries (of one pick) name; just GOOD when none is named.
	var names := {}
	for e in entries:
		for c in [e.get("when")] + (e["options"] as Array).map(func(o): return o.get("when")):
			if c != null:
				names[str(c)] = true
	var axes: Array = []
	for n in names:
		var axis: String = {"lines_parallel": "parallel", "lines_not_parallel": "parallel", "point_not_on_line_end": "point_on_end", "point_not_of_curve": "point_of_curve", "curves_apart": "apart", "line_misses_curve": "misses"}[n]
		if not axes.has(axis):
			axes.append(axis)
	var out: Array = [GOOD.duplicate()]
	for axis in axes:
		var more: Array = []
		for v in out:
			var flipped: Dictionary = v.duplicate()
			flipped[axis] = not bool(GOOD[axis]) if axis != "parallel" else false
			more.append(flipped)
		out.append_array(more)
	return out


func creates_ok(g: Dictionary, creates: String) -> bool:
	## The candidate really makes what the catalogue says: the constraint's type and its orientation or side, or the circle's own size constraint.
	var parts := creates.split(":")
	var apply: Dictionary = g["apply"]
	if creates in ["radius", "diameter"]:
		var want_factor := 1.0 if creates == "radius" else 0.5
		var made_by_patch: bool = apply.has("patch_id") and not str(apply["patch_id"]).is_empty()
		var made_by_distance: bool = apply.has("create") and str(apply["create"].get("type", "")) == "distance" # a partial ellipse's axis is a plain distance
		return (made_by_patch or made_by_distance) and is_equal_approx(float(apply["factor"]), want_factor)
	if not apply.has("create"):
		return false
	var c: Dictionary = apply["create"]
	if str(c.get("type", "")) != parts[0]:
		return false
	if parts[0] == "distance":
		return str(c.get("orientation", "")) == parts[1]
	if parts.size() > 1:
		return str(c.get("side", "")) == parts[1]
	return true


func _initialize() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	var data: Dictionary = JSON.parse_string(text)
	_check(data is Dictionary and int(data.get("version", 0)) == 1 and (data["entries"] as Array).size() > 10, "the catalogue fixture reads (version 1)")
	var cad_state := "no source"
	var cad_candidates: Array[String] = []
	if OS.get_environment("DIDSA_CAD_DIR") != "": # (as the other fixture-copy tests: env DIDSA_CAD_DIR, else ../DIDSA-CAD)
		cad_candidates.append(OS.get_environment("DIDSA_CAD_DIR").path_join("docs/sketch-dimension-catalogue.json"))
	cad_candidates.append(ProjectSettings.globalize_path("res://").path_join("../DIDSA-CAD/docs/sketch-dimension-catalogue.json"))
	for cad in cad_candidates:
		if FileAccess.file_exists(cad):
			cad_state = "same" if FileAccess.get_file_as_string(cad) == text else "DIFFERENT"
			break
	_check(cad_state != "DIFFERENT", "the fixture equals DIDSA-CAD's docs/sketch-dimension-catalogue.json (%s)" % cad_state)

	# group the entries by what is picked
	var groups := {}
	for e in data["entries"]:
		var k := "+".join(e["picks"])
		if not groups.has(k):
			groups[k] = []
		(groups[k] as Array).append(e)

	var offered_total := 0
	for k in groups:
		var entries: Array = groups[k]
		var picks: Array = entries[0]["picks"]
		var ordered: bool = bool(entries[0].get("ordered", false))
		var orders: Array = [picks]
		if not ordered and picks.size() == 2 and picks[0] != picks[1]:
			orders.append([picks[1], picks[0]]) # unordered: the other order offers the same
		for v in variants(entries):
			var expect: Array = []
			var default_key := ""
			var rule := ""
			for e in entries:
				if not holds(e.get("when"), v):
					continue
				default_key = str(e.get("default", ""))
				rule = str(e.get("cursor_rule", "")) if e.get("cursor_rule") != null else ""
				for o in e["options"]:
					if holds(o.get("when"), v):
						expect.append(o)
			for order in orders:
				var built := build(picks, v)
				var s = built[0]
				var sel: Array = built[1]
				if order != picks:
					sel.reverse() # (the same geometry, picked the other way round)
				var got: Array = s._ghosts_for(sel)
				var label := "%s%s %s" % [k, "" if order == picks else " (reversed)", vtext(v)]
				var got_keys: Array = got.map(func(g): return g["key"])
				var want_keys: Array = expect.map(func(o): return o["key"])
				_check(got_keys == want_keys, "[%s] keys and order" % label, "got %s want %s" % [got_keys, want_keys])
				if got_keys != want_keys:
					continue
				offered_total += got.size()
				var ok_labels := true
				var ok_creates := true
				var ok_side := true
				for i in got.size():
					ok_labels = ok_labels and got[i]["label"] == expect[i]["label"]
					ok_creates = ok_creates and creates_ok(got[i], str(expect[i]["creates"]))
					ok_side = ok_side and str(got[i].get("side", "")) == str(expect[i].get("side", ""))
				_check(ok_labels, "[%s] labels" % label)
				_check(ok_creates, "[%s] what each creates" % label)
				_check(ok_side, "[%s] the angle sides that follow the pointer" % label)
				if not got.is_empty():
					_check(str(got[0]["key"]) == default_key, "[%s] the default is the first" % label, "default %s first %s" % [default_key, got[0]["key"]])
				var cursor: Dictionary = s.cursor_rule(sel)
				_check((cursor.get("rule", "") if not got.is_empty() else "") == rule or got.is_empty(), "[%s] the cursor rule" % label, "got %s want '%s'" % [cursor, rule])
				var values_ok := true
				for g in got:
					values_ok = values_ok and is_finite(float(g["value"])) and float(g["value"]) >= 0.0 and (g["uv"] as Vector2).is_finite()
				_check(values_ok, "[%s] values and label places are finite" % label)
	_check(offered_total > 80, "a good many candidates were compared (%d)" % offered_total)

	_notes()
	_cursor()
	_picks()
	_pinned(data)
	print("SMOKE catalogue: %d checks, %d failed" % [checks, failures])
	quit()


# --- the file's notes: what is offered for nothing, and how a pick is read ---------------------

func _notes() -> void:
	var s = SketchSession.new()
	var c := _circle(s, "C", Vector2(100, 100), 20)
	_check(s._ghosts_for([{"kind": "point", "id": c + "_c"}, {"kind": "circle", "id": c}]).is_empty(), "nothing for a point that is the circle's own centre")
	var rim: Array = s._ghosts_for([{"kind": "point", "id": c + "_p"}, {"kind": "circle", "id": c}]).map(func(g): return g["key"])
	_check(rim == ["linear", "h", "v"], "a point on the circle's rim (not its centre) keeps the three distances and loses Minimum / Maximum", str(rim))
	var d := _circle(s, "D", Vector2(100, 100), 30)
	s.circles["D"]["c"] = "C_c" # (they share one centre POINT)
	_check(s._ghosts_for([{"kind": "circle", "id": c}, {"kind": "circle", "id": d}]).is_empty(), "nothing for two circles that share a centre")
	var l := _line(s, "L", Vector2(100, 100), Vector2(200, 100))
	s.lines["L"]["a"] = "C_c" # (the line starts at the circle's centre point)
	_check(s._ghosts_for([{"kind": "line", "id": l}, {"kind": "circle", "id": c}]).is_empty(), "nothing for a line whose end is the circle's centre")
	var sp = SketchSession.new()
	var spline_ok := true
	sp.splines["S"] = {"through": [], "control": [], "construction": false}
	sp.texts["T"] = {"anchor": "", "content": "x", "font": "", "size": 10.0, "rot": 0.0, "construction": false}
	spline_ok = sp._ghosts_for([{"kind": "spline", "id": "S"}]).is_empty() and sp._ghosts_for([{"kind": "text", "id": "T"}]).is_empty() and sp._ghosts_for([{"kind": "point", "id": "nope"}]).is_empty()
	_check(spline_ok, "a spline, a text and a lone point have no options")
	var e = SketchSession.new()
	var ell := _ellipse(e, "E", Vector2(100, 100))
	var ln := _line(e, "L", Vector2(0, 0), Vector2(50, 0))
	_check(e._ghosts_for([{"kind": "ellipse", "id": ell}, {"kind": "line", "id": ln}]).is_empty(), "an ellipse with anything else has no options")
	# two points that are an end of each of two parallel lines are read as those lines; on a middle too; on the same line or non-parallel lines they are two points
	var t = SketchSession.new()
	_line(t, "A", Vector2(0, 0), Vector2(60, 0))
	_line(t, "B", Vector2(0, 20), Vector2(60, 20))
	var parallel_ends: Array = t._ghosts_for([{"kind": "point", "id": "A_a"}, {"kind": "point", "id": "B_b"}]).map(func(g): return g["key"])
	_check(parallel_ends == ["lineDistance"], "two end points of two parallel lines are read as those lines", str(parallel_ends))
	_pt(t, "mid", Vector2(30, 0))
	var parallel_mid: Array = t._ghosts_for([{"kind": "point", "id": "mid"}, {"kind": "point", "id": "B_a"}]).map(func(g): return g["key"])
	_check(parallel_mid == ["lineDistance"], "...and so is a point at a line's middle", str(parallel_mid))
	_line(t, "C", Vector2(0, 40), Vector2(40, 70))
	var skew: Array = t._ghosts_for([{"kind": "point", "id": "A_b"}, {"kind": "point", "id": "C_a"}]).map(func(g): return g["key"])
	_check(skew == ["linear", "h", "v"], "...two points on lines that are not parallel stay two points", str(skew))
	var parallel_cos := _line(t, "D", Vector2(0, 80), Vector2(60, 80) + Vector2(0, 60.0 * tan(0.0199)))
	var near_para: Array = t._ghosts_for([{"kind": "line", "id": "A"}, {"kind": "line", "id": parallel_cos}]).map(func(g): return g["key"])
	var just_over := _line(t, "E", Vector2(0, 100), Vector2(60, 100) + Vector2(0, 60.0 * tan(0.0215)))
	var past: Array = t._ghosts_for([{"kind": "line", "id": "A"}, {"kind": "line", "id": just_over}]).map(func(g): return g["key"])
	_check(near_para == ["lineDistance"] and past == ["angle"], "the parallel tolerance is |cross| <= sin(0.02 rad): 0.0199 rad is parallel, 0.0215 is not", "%s %s" % [near_para, past])


func _cursor() -> void:
	var a := Vector2(10, 10)
	var b := Vector2(50, 40)
	var P = SketchSession
	_check(P.point_pair_kind(a, b, Vector2(30, 25)) == "linear", "the cursor inside the pair's box gives Aligned")
	_check(P.point_pair_kind(a, b, Vector2(30, 80)) == "h" and P.point_pair_kind(a, b, Vector2(30, -20)) == "h", "above or below the box (within its x span) gives Horizontal")
	_check(P.point_pair_kind(a, b, Vector2(90, 25)) == "v" and P.point_pair_kind(a, b, Vector2(-30, 25)) == "v", "left or right of the box (within its y span) gives Vertical")
	_check(P.point_pair_kind(a, b, Vector2(90, 80)) == "linear" and P.point_pair_kind(a, b, Vector2(-5, -5)) == "linear", "a corner region gives Aligned")
	_check(P.point_pair_kind(a, b, Vector2(10, 80)) == "h" and P.point_pair_kind(a, b, Vector2(90, 40)) == "v", "the spans are closed intervals (on the box's edge line still counts)")
	_check(P.point_pair_kind(b, a, Vector2(30, 80)) == "h", "the order of the pair does not matter")


func _picks() -> void:
	var s = SketchSession.new()
	s.tool = "dimension"
	for i in 4:
		_pt(s, "p%d" % i, Vector2(20 * i, 10 * i * i))
	_line(s, "L", Vector2(200, 0), Vector2(260, 40))
	_circle(s, "C", Vector2(300, 100), 20)
	_ellipse(s, "E", Vector2(500, 100))
	var picked := func() -> Array: return s.selection.map(func(e): return e["id"])
	for i in 3:
		s._select_for_dimension({"kind": "point", "id": "p%d" % i})
	_check(picked.call() == ["p0", "p1", "p2"] and s.ghosts.map(func(g): return g["key"]) == ["pointAngle"], "three points are three picks, the first the vertex, and offer the angle", str(picked.call()))
	var angle: Dictionary = s.ghost("pointAngle")
	_check(angle["apply"]["create"]["vertex_point_id"] == "p0" and angle["apply"]["create"]["point1_id"] == "p1" and angle["apply"]["create"]["point2_id"] == "p2", "...the first pick is the vertex")
	s._select_for_dimension({"kind": "point", "id": "p3"})
	_check(picked.call() == ["p3"], "a fourth pick restarts the selection", str(picked.call()))
	s.selection.clear()
	s._select_for_dimension({"kind": "line", "id": "L"})
	s._select_for_dimension({"kind": "point", "id": "p0"})
	s._select_for_dimension({"kind": "point", "id": "p1"})
	_check(picked.call() == ["p1"], "two picks that are not both points, then a third: the third restarts", str(picked.call()))
	s._select_for_dimension({"kind": "point", "id": "p1"})
	_check(picked.call().is_empty() and s.ghosts.is_empty(), "picking a picked entity again takes it out")
	s._select_for_dimension({"kind": "circle", "id": "C"})
	s._select_for_dimension({"kind": "point", "id": "p0"})
	_check(picked.call() == ["C", "p0"] and s.ghosts.map(func(g): return g["key"]) == ["linear", "h", "v", "minDistance", "maxDistance"], "a circle and a point are a pair (a circle is no longer dimensioned only on its own)", str(s.ghosts.map(func(g): return g["key"])))
	s._select_for_dimension({"kind": "ellipse", "id": "E"})
	_check(picked.call() == ["E"], "an ellipse restarts the selection and stands alone")
	s._select_for_dimension({"kind": "point", "id": "p0"})
	_check(picked.call() == ["p0"], "...and a pick after it restarts again")
	# the Select tool takes up to three for the angle
	var t = SketchSession.new()
	t.tool = "select"
	for i in 3:
		_pt(t, "q%d" % i, Vector2(20 * i, 10 * i * i))
		t.toggle_select({"kind": "point", "id": "q%d" % i})
	_check(t.ghosts.map(func(g): return g["key"]) == ["pointAngle"], "Select offers the angle for three points too")


func _pinned(data: Dictionary) -> void:
	var pinned: Dictionary = data["pinned"]
	_check(pinned["offer"] == "reference", "the catalogue's pinned offer is a reference dimension")
	_check(SketchSession.PINNED_KINDS == pinned["kinds"], "the session's PINNED_KINDS is the catalogue's pinned.kinds", str(SketchSession.PINNED_KINDS))
	var all_kinds := {}
	for key in pinned["kinds"]:
		var picks: Array = key.split("+")
		var want: Array = pinned["kinds"][key]
		var seen := {}
		for v in variants(_entries_for(data, picks)):
			var built := build(picks, v)
			var s = built[0]
			var sel: Array = built[1]
			for pid in s.points:
				s.point_locked[pid] = true # everything picked is pinned
			_check(SketchSession.pins_key(sel) == key, "[pinned %s] the pick's key" % key)
			var got: Array = s._ghosts_for(sel)
			var all_driven: bool = got.all(func(g): return bool(g.get("driven", false)) and str(g["ref"]) != "")
			var refs: Array = got.map(func(g): return g["ref"])
			var inside: bool = refs.all(func(r): return want.has(r))
			_check(all_driven and inside, "[pinned %s, %s] only the listed reference kinds, each driven" % [key, vtext(v)], str(refs))
			for r in refs:
				seen[r] = true
		_check(seen.keys().size() == want.size() and want.all(func(r): return seen.has(r)), "[pinned %s] every listed kind is offered in some geometry" % key, "%s of %s" % [seen.keys(), want])
		for r in want:
			all_kinds[r] = true
	var ref_ok := true
	for r in all_kinds:
		ref_ok = ref_ok and r in ["distance", "horizontal", "vertical", "radius", "diameter", "angle", "arc_length", "horizontal_angle", "point_angle", "min_distance", "max_distance"]
	_check(ref_ok, "every pinned kind is one the reference-dimensions route knows")
	# something not pinned: the ordinary candidates; a part pinned and a free point: ordinary (the free point can move)
	var s2 = SketchSession.new()
	_pt(s2, "a", Vector2(0, 0))
	_pt(s2, "b", Vector2(30, 10))
	s2.point_locked["a"] = true
	_check(not s2._ghosts_for([{"kind": "point", "id": "a"}, {"kind": "point", "id": "b"}]).any(func(g): return bool(g.get("driven", false))), "one pinned and one free point are an ordinary (driving) dimension")


func _entries_for(data: Dictionary, picks: Array) -> Array:
	var out: Array = []
	var kind_key := "+".join(picks)
	for e in data["entries"]:
		var k := "+".join(e["picks"])
		if k == kind_key or "+".join(_sorted(e["picks"])) == kind_key:
			out.append(e)
	return out


func _sorted(picks: Array) -> Array:
	var out := picks.duplicate()
	var rank := {"point": 0, "line": 1, "circle": 2, "arc": 3}
	if out.size() != 3:
		out.sort_custom(func(a, b): return int(rank.get(a, 9)) < int(rank.get(b, 9)))
	return out
