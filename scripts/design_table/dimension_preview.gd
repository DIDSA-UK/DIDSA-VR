extends RefCounted
## S5 of docs/dimension-constraint-parity-plan.md: the Dimension tool's ONE preview at the laser, the flat app's preview / choose / drop flow
## (DIDSA-CAD docs/bug-report-2026-11-18-plan.md part A), written from that description, not from the Dart.
##
## Stages: "picking" (nothing to preview), "preview" (a candidate follows the laser), "pad" (dropped: kind, placement and side are frozen in
## `frozen` while the number pad is open). B steps back one stage (F4). From the laser's point on the sheet it works out:
##   * which candidate is shown: the kind chosen on the stick or the options row (`chosen`), else the catalogue's cursor rule for two points
##     (sketch_session.gd cursor_rule / point_pair_kind), else the first (the default);
##   * which of its angles it is, for the candidates whose `side` is "pointer": the sector under the laser for the two-line angle and the
##     three-point angle, STICKY near the rays (fix 2a: inside the band of either ray, or on the vertex, the last sector is kept; only another
##     sector's open area changes it); the angle to horizontal at the line's nearer end, towards the side of the vertical the laser is on;
##   * its label placement (section 3.2): the inverse of the readers the spec builders use, so the label sits at the laser and a confirmed
##     dimension stays where it was dropped. tests/sketch_dimension_preview.gd holds it to the golden cases.
## No scene tree: table_editor.gd drives it and sketch_view.gd draws what preview() returns.

const SketchSession := preload("res://scripts/design_table/sketch_session.gd")

const STICK_FLICK := 0.6 ## how far the stick goes left / right to step the kind
const STICK_RELEASE := 0.3 ## ...and how near the middle it must come back before the next step

var chosen := "" ## the kind picked on the stick or the options row; "" = the cursor rule / the default. A new selection forgets it
var show_all := false ## F7: every candidate at once (VR's older style) instead of the one preview; off by default
var stage := "picking"
var frozen: Dictionary = {} ## the dropped candidate: its key, apply (with the quadrant), value, spec and `place`
var _sel_key := ""
var _rule: Dictionary = {}
var _sticky := -1 ## the angle sector last found for this selection (-1: none yet)
var _last_place: Dictionary = {}
var _last_place_key := ""
var _stick_armed := true


static func selection_key(selection: Array) -> String:
	return ",".join(selection.map(func(e): return "%s:%s" % [e["kind"], e["id"]]))


func sync(session) -> void:
	## After the selection or its candidates changed: a new selection starts over (no kind chosen, no sector, no placement); the stage follows
	## whether there is anything to preview. A drop stays dropped while its candidate is still offered.
	var key := selection_key(session.selection)
	if key != _sel_key:
		_sel_key = key
		chosen = ""
		_sticky = -1
		_last_place = {}
		_last_place_key = ""
		_rule = session.cursor_rule(session.selection) if not session.ghosts.is_empty() else {}
		if stage == "pad":
			frozen = {}
			stage = "picking"
	if session.ghosts.is_empty():
		stage = "picking"
		frozen = {}
	elif stage == "picking":
		stage = "preview"
	if chosen != "" and session.ghost(chosen).is_empty():
		chosen = ""


func live() -> bool:
	## One candidate is following the laser.
	return stage == "preview" and not show_all


func current_key(session, pointer: Variant) -> String:
	if session.ghosts.is_empty():
		return ""
	if chosen != "" and not session.ghost(chosen).is_empty():
		return chosen
	if not _rule.is_empty() and pointer != null:
		var k := SketchSession.point_pair_kind(_rule["a"], _rule["b"], pointer)
		if not session.ghost(k).is_empty():
			return k
	return str(session.ghosts[0]["key"])


func choose(session, key: String) -> bool:
	if session.ghost(key).is_empty():
		return false
	chosen = key
	if stage == "picking":
		stage = "preview"
	return true


func cycle(session, pointer: Variant, step: int) -> String:
	## The next (step 1) or previous (-1) kind of the selection, wrapping; it stays chosen (the cursor rule no longer decides).
	var keys: Array = session.ghosts.map(func(g): return str(g["key"]))
	if keys.is_empty():
		return ""
	var i := keys.find(current_key(session, pointer))
	chosen = keys[posmod(i + step, keys.size())]
	return chosen


func stick(x: float) -> int:
	## A flick of the stick: -1 left, 1 right, once per push (it must come back near the middle before the next), else 0.
	if absf(x) < STICK_RELEASE:
		_stick_armed = true
		return 0
	if _stick_armed and absf(x) >= STICK_FLICK:
		_stick_armed = false
		return 1 if x > 0.0 else -1
	return 0


static func owns_stick(preview_live: bool, laser_on_sheet: bool, gripped: bool, part_locked: bool = false) -> bool:
	## F3 / F2 (owner decision 1 of docs/parity-followups-investigation.md): the right stick cycles the kind whenever a preview is live and the laser is on the sheet,
	## except when Orbit lock is off (`part_locked` false) and a hand grips the table: then the stick turns the part, as it did. With Orbit lock on (the default)
	## the stick does nothing to the part in a sketch, so a grip takes nothing from it and cycling works while the other hand holds the table.
	return preview_live and laser_on_sheet and (part_locked or not gripped)


func preview(session, pointer: Vector2, band: float) -> Dictionary:
	## The candidate shown at `pointer`: its side from the laser, `place` its label placement there, and its spec laid out with it. {} if none.
	var key := current_key(session, pointer)
	var g: Dictionary = session.ghost(key)
	if g.is_empty():
		return {}
	g = g.duplicate(true)
	if str(g.get("side", "")) == "pointer":
		var q := side_at(session, g, pointer, band)
		if q < 0 and str(g["key"]) == "angle":
			var rays := angle_rays(session, g) # no sector yet: the one the candidate is drawn in, made explicit (what you see is what is saved)
			var spec: Dictionary = g.get("spec", {})
			if not rays.is_empty() and spec.has("d1"):
				q = sector_at(rays["apex"], rays["r1"], rays["r2"], (rays["apex"] as Vector2) + (spec["d1"] as Vector2) + (spec["d2"] as Vector2))
		if q >= 0:
			g = with_side(session, g, q)
	var place := placement_at(session, g, pointer)
	if place.is_empty() and _last_place_key == key:
		place = _last_place # (the laser behind an angle's vertex gives none: the label stays where it was)
	if not place.is_empty():
		_last_place = place
		_last_place_key = key
	g["place"] = place
	g["spec"] = placed_spec(session, g, place)
	return g


func drop(session, pointer: Vector2, band: float) -> Dictionary:
	## The trigger on empty sheet: freezes the kind, the placement and the side. A driven (reference) candidate has no value to type, so it does
	## not go to the pad (the caller keeps it at once).
	var g := preview(session, pointer, band)
	if g.is_empty():
		return {}
	if not bool(g.get("driven", false)):
		frozen = g
		stage = "pad"
	return g


func step_back(session) -> String:
	## B (F4): the pad goes back to the preview, the preview back to picking (the selection is let go). Returns the stage stepped back to, or ""
	## when there was nothing to step back from.
	if stage == "pad":
		frozen = {}
		stage = "preview" if not session.ghosts.is_empty() else "picking"
		return stage
	if not session.selection.is_empty():
		session.clear_selection()
		sync(session)
		return "picking"
	return ""


# --- Which angle it is ------------------------------------------------------------------------

static func sector_at(apex: Vector2, r1: Vector2, r2: Vector2, p: Vector2) -> int:
	## Which of the four sectors round `apex` `p` is in, as a quadrant (bit 0: ray 1 flipped, bit 1: ray 2 flipped): p - apex = a r1 + b r2, a
	## negative a or b flips that ray. -1 on the vertex or for parallel rays.
	var w := p - apex
	if w.length_squared() < 1e-18:
		return -1
	var det := r1.cross(r2)
	if absf(det) < 1e-12:
		return -1
	var a := w.cross(r2) / det
	var b := r1.cross(w) / det
	return (1 if a < 0.0 else 0) | (2 if b < 0.0 else 0)


static func angle_rays(session, g: Dictionary) -> Dictionary:
	## The unflipped rays of a sector angle: {apex, r1, r2} (unit), {} for any other candidate.
	var create: Dictionary = (g.get("apply", {}) as Dictionary).get("create", {})
	var spec: Dictionary = {}
	match str(g.get("key", "")):
		"angle":
			spec = session.angle_spec(str(create.get("line1_id", "")), str(create.get("line2_id", "")), -1.0, 0)
		"pointAngle":
			spec = session.point_angle_spec(str(create.get("vertex_point_id", "")), str(create.get("point1_id", "")), str(create.get("point2_id", "")), 0)
	if spec.is_empty():
		return {}
	return {"apex": spec["apex"], "r1": spec["d1"], "r2": spec["d2"]}


func side_at(session, g: Dictionary, pointer: Vector2, band: float) -> int:
	## The quadrant the laser means, -1 when none is known yet.
	if str(g.get("key", "")) == "horizontalAngle":
		var create: Dictionary = g["apply"]["create"]
		var ends: Array = session._line_points(str(create.get("line_id", "")))
		if not session.points.has(ends[0]) or not session.points.has(ends[1]):
			return -1
		var start: Vector2 = session.points[ends[0]]
		var end: Vector2 = session.points[ends[1]]
		var at_end := pointer.distance_to(end) < pointer.distance_to(start)
		var vertex := end if at_end else start
		return (1 if at_end else 0) | (2 if pointer.x < vertex.x else 0)
	var rays := angle_rays(session, g)
	if rays.is_empty():
		return -1
	var w: Vector2 = pointer - (rays["apex"] as Vector2)
	if absf(w.cross(rays["r1"])) < band or absf(w.cross(rays["r2"])) < band:
		return _sticky # on (near) a ray or the vertex: the sector chosen stays chosen
	var q := sector_at(rays["apex"], rays["r1"], rays["r2"], pointer)
	if q >= 0:
		_sticky = q
	return q if q >= 0 else _sticky


static func with_side(session, g: Dictionary, q: int) -> Dictionary:
	## The candidate as the angle of quadrant `q`: the quadrant in its create body, its value the angle between that quadrant's rays, its spec drawn in it.
	var out := g.duplicate(true)
	var apply: Dictionary = out["apply"]
	var create: Dictionary = apply.get("create", {})
	var spec: Dictionary = {}
	match str(g["key"]):
		"angle":
			spec = session.angle_spec(str(create.get("line1_id", "")), str(create.get("line2_id", "")), -1.0, q)
		"horizontalAngle":
			spec = session.horizontal_angle_spec(str(create.get("line_id", "")), q)
		"pointAngle":
			spec = session.point_angle_spec(str(create.get("vertex_point_id", "")), str(create.get("point1_id", "")), str(create.get("point2_id", "")), q)
	if spec.is_empty():
		return g
	if apply.has("create"):
		create["quadrant"] = q
	out["quadrant"] = q
	out["spec"] = spec
	out["value"] = rad_to_deg(acos(clampf((spec["d1"] as Vector2).dot(spec["d2"]), -1.0, 1.0)))
	return out


# --- Label placement (section 3.2; the formulas of tests/fixtures/sketch_label_placement_cases.json) -------------------------------

static func _degrees(radians: float) -> float:
	## Degrees in (-180, 180].
	var d := wrapf(rad_to_deg(radians), -180.0, 180.0)
	return 180.0 if d <= -180.0 + 1e-9 else d


static func linear_placement(a: Vector2, b: Vector2, p: Vector2) -> Dictionary:
	## distance_linear: offset along A-B's left-hand normal, along towards B, both from the middle of A-B.
	var t := b - a
	if t.length() < 0.0001:
		return {}
	t = t.normalized()
	var n := Vector2(-t.y, t.x)
	var mid := (a + b) * 0.5
	return {"offset": (p - mid).dot(n), "along": (p - mid).dot(t)}


static func placement_at(session, g: Dictionary, p: Vector2) -> Dictionary:
	## The placement that puts the label of candidate `g` (as its spec now stands) at `p`. {} when the pointer gives none.
	var spec: Dictionary = g.get("spec", {})
	match str(spec.get("kind", "")):
		"linear":
			return linear_placement(spec["a"], spec["b"], p)
		"perp":
			if str(g.get("key", "")) == "lineDistance":
				var u := _line_dir(session, str((g["apply"]["create"] as Dictionary).get("line1_id", "")))
				var a: Vector2 = spec["a"]
				var b: Vector2 = spec["b"]
				if u == Vector2.ZERO or a.distance_to(b) < 0.0001:
					return {}
				return {"offset": (p - a).dot(u), "along": (p - (a + b) * 0.5).dot((b - a).normalized())}
			return linear_placement(spec["a"], spec["b"], p)
		"horizontal":
			var a: Vector2 = spec["a"]
			var b: Vector2 = spec["b"]
			return {"offset": p.y - maxf(a.y, b.y), "along": p.x - (a.x + b.x) * 0.5}
		"vertical":
			var a: Vector2 = spec["a"]
			var b: Vector2 = spec["b"]
			return {"offset": p.x - maxf(a.x, b.x), "along": p.y - (a.y + b.y) * 0.5}
		"radius", "diameter":
			if not spec.has("rim_a") or p.distance_to(spec["c"]) < 0.0001:
				return {}
			return {"angle": _degrees((p - (spec["c"] as Vector2)).angle() - float(spec["rim_a"])), "leg": p.distance_to(spec["c"]) - float(spec["r"])}
		"angle":
			var apex: Vector2 = spec["apex"]
			var d1: Vector2 = spec["d1"]
			var d2: Vector2 = spec["d2"]
			var w := p - apex
			if w.length() < 0.0001:
				return {}
			var sweep := wrapf(d2.angle() - d1.angle(), -PI, PI)
			var mid := d1.angle() + sweep * 0.5
			var off := wrapf(w.angle() - mid, -PI, PI)
			if str(g.get("key", "")) == "angle":
				if w.dot(Vector2.from_angle(mid)) <= 0.0:
					return {} # behind the vertex
				return {"radius": w.length(), "along": w.length() * off * signf(sweep)}
			return {"radius": w.length(), "angle": _degrees(off)}
		"arc_length":
			var c: Vector2 = spec["c"]
			if p.distance_to(c) < 0.0001:
				return {}
			return {"leg": p.distance_to(c) - float(spec["r"]), "angle": _degrees((p - c).angle() - (float(spec["a0"]) + float(spec["sweep"]) * 0.5))}
	return {}


static func _line_dir(session, line_id: String) -> Vector2:
	var ends: Array = session._line_points(line_id)
	if not session.points.has(ends[0]) or not session.points.has(ends[1]):
		return Vector2.ZERO
	var d: Vector2 = session.points[ends[1]] - session.points[ends[0]]
	return d.normalized() if d.length() > 0.0001 else Vector2.ZERO


static func placed_spec(session, g: Dictionary, place: Dictionary) -> Dictionary:
	## The candidate's spec with `place` applied, read the way a saved placement is (so the preview is what the confirmed dimension will be).
	var spec: Dictionary = (g.get("spec", {}) as Dictionary).duplicate()
	if place.is_empty() or spec.is_empty():
		return spec
	match str(spec["kind"]):
		"linear", "horizontal", "vertical", "perp":
			spec["place"] = SketchSession._linear_place(place)
			if str(g.get("key", "")) == "lineDistance":
				spec["u"] = _line_dir(session, str((g["apply"]["create"] as Dictionary).get("line1_id", "")))
		"radius", "diameter":
			if spec.has("rim_a") and float(spec["r"]) >= 0.0001:
				spec["u"] = Vector2.from_angle(float(spec["rim_a"]) + deg_to_rad(float(place.get("angle", 0.0))))
				spec["label_r"] = float(spec["r"]) + float(place.get("leg", 0.0))
		"angle":
			SketchSession._place_on_arc(spec, place, str(g.get("key", "")) == "angle")
		"arc_length":
			var r := float(spec["r"])
			spec["ra"] = maxf(r + float(place.get("leg", 0.0)), 0.1 * r)
			spec["label_a"] = float(spec["a0"]) + float(spec["sweep"]) * 0.5 + deg_to_rad(float(place.get("angle", 0.0)))
	return spec
