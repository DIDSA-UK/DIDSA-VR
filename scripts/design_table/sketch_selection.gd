extends RefCounted
## What a selection of sketch entities can do, as DATA: the contextual menu of the Select tool, ported from the flat app's sketcher
## (client/lib/sketch/sketch_controller.dart, availableConstraintOptions, and the ribbon's Make construction / Fix / Delete chips).
## Pure functions over a sketch_session.gd's selection and local model, no scene tree, so tests can pin every selection shape.
##
## A selection is a list of {kind, id}, kind one of "point", "line", "circle", "arc". An option is {id, text}; the ids the session
## understands are the keys of CONSTRAINT_OPTIONS (each posts the constraint(s) of that name), "fix", "construction", "delete" and
## "clear"; "dim:<key>" options are the dimension candidates (sketch_session.gd ghosts) and open the number pad.
##
##   1 line                  Horizontal, Vertical, Length
##   1 circle / arc          Radius, Diameter
##   1 point                 Fix
##   2 points                Coincident, Merge, Distance (+ Horizontal / Vertical distance)
##   3+ points               Merge (not the origin, not a circle's or ellipse's quadrant point, not two points of one shape)
##   2 lines                 Parallel, Perpendicular, Equal, Collinear, Distance or Angle
##   3+ lines                Equal, Collinear
##   2+ circles / arcs       Concentric, Equal radius (two arcs sharing an end also: Tangent)
##   point + line            On line, Midpoint, Distance
##   point + circle / arc    On curve
##   point + ellipse         On ellipse
##   line + circle / arc     Tangent
##   any                     Fix (and Unfix when a Fix holds it), Construction / Solid (lines, circles, arcs), Delete, Clear

const TEXT := {
	"horizontal": "Horizontal", "vertical": "Vertical", "parallel": "Parallel", "perpendicular": "Perpendicular",
	"equal_length": "Equal", "collinear": "Collinear", "concentric": "Concentric", "equal_radius": "Equal radius",
	"tangent": "Tangent", "coincident": "Coincident", "merge": "Merge", "point_on_line": "On line", "at_midpoint": "Midpoint",
	"point_on_curve": "On curve", "point_on_ellipse": "On ellipse", "fix": "Fix", "unfix": "Unfix", "delete": "Delete", "clear": "Clear",
}


static func counts(selection: Array) -> Dictionary:
	var out := {"point": 0, "line": 0, "circle": 0, "arc": 0, "curve": 0, "ellipse": 0}
	for e in selection:
		var kind := str(e.get("kind", ""))
		out[kind] = int(out.get(kind, 0)) + 1
		if kind == "circle" or kind == "arc":
			out["curve"] += 1
		if kind in ["ellipse", "ellipse_arc", "spline", "text"]:
			out["other"] = int(out.get("other", 0)) + 1
	return out


static func constraint_ids(selection: Array, session = null) -> Array:
	## The constraint option ids that suit this selection, in menu order.
	var n := selection.size()
	var c := counts(selection)
	var out: Array = []
	if n == 0:
		return out
	if c["line"] == n:
		if n == 1:
			out.append_array(["horizontal", "vertical"])
		else:
			if n == 2:
				out.append_array(["parallel", "perpendicular"])
			out.append_array(["equal_length", "collinear"])
	elif c["curve"] == n:
		if n >= 2:
			out.append_array(["concentric", "equal_radius"])
			if n == 2 and session != null and _arcs_share_end(selection, session):
				out.append("tangent")
	elif n == 2 and c["point"] == 2:
		out.append("coincident")
	elif n == 2 and c["point"] == 1 and c["line"] == 1:
		out.append_array(["point_on_line", "at_midpoint"])
	elif n == 2 and c["point"] == 1 and c["curve"] == 1:
		out.append("point_on_curve")
	elif n == 2 and c["point"] == 1 and c["ellipse"] == 1:
		out.append("point_on_ellipse")
	elif n == 2 and c["line"] == 1 and c["curve"] == 1:
		out.append("tangent")
	return out


static func options(selection: Array, session = null, ghosts: Array = []) -> Array:
	## The whole menu for a selection: its dimension candidates first (each opens the number pad), then the constraints that fit, then Fix,
	## Construction / Solid, Delete and Clear. [] when nothing is selected.
	var out: Array = []
	if selection.is_empty():
		return out
	for g in ghosts:
		out.append({"id": "dim:%s" % g["key"], "text": "%s %.2f" % [g["label"], float(g["value"])]})
	for id in constraint_ids(selection, session):
		out.append({"id": id, "text": TEXT[id]})
		if id == "coincident" and session != null and session.merge_offered():
			out.append({"id": "merge", "text": TEXT["merge"]}) # (not a constraint: the session special-cases it)
	if session != null and counts(selection)["point"] > 2 and counts(selection)["point"] == selection.size() and session.merge_offered():
		out.append({"id": "merge", "text": TEXT["merge"]}) # three or more points: Coincident is for two, Merge takes any number
	out.append({"id": "fix", "text": TEXT["fix"]})
	if session != null and not session.fix_constraints_for(selection).is_empty():
		out.append({"id": "unfix", "text": TEXT["unfix"]}) # something picked is held by a Fix of its own: this takes it off
	var c := counts(selection)
	if int(c["line"]) + int(c["curve"]) + int(c.get("other", 0)) > 0:
		out.append({"id": "construction", "text": "Solid" if all_construction(selection, session) else "Construction"})
	if session == null or not only_origin(selection, session):
		out.append({"id": "delete", "text": TEXT["delete"]})
	out.append({"id": "clear", "text": TEXT["clear"]})
	return out


static func annotation_options(annotations: Array, selection: Array, session = null) -> Array:
	## T5: the menu when dimension labels or constraint glyphs are selected (alone, or with geometry): one dimension alone can have its value edited;
	## anything else is Delete only (the constraints go, then any selected geometry with what depends on it). Always Clear. (The flat app's Driven /
	## Driving switch is not offered: the backend notes have no route for it.)
	var out: Array = []
	if annotations.is_empty():
		return out
	if annotations.size() == 1 and selection.is_empty() and str(annotations[0]["kind"]) == "dimension":
		var value: Dictionary = session.dimension_value(str(annotations[0]["id"])) if session != null else {"ok": true}
		if bool(value.get("ok", false)):
			out.append({"id": "edit_value", "text": "Edit value"})
	out.append({"id": "delete", "text": TEXT["delete"]})
	out.append({"id": "clear", "text": TEXT["clear"]})
	return out


static func all_construction(selection: Array, session) -> bool:
	## True if every line / circle / arc in the selection is already a construction entity (so the menu offers Solid).
	var any := false
	for e in selection:
		var kind := str(e.get("kind", ""))
		var entity: Dictionary = {}
		match kind:
			"line":
				entity = session.lines.get(str(e["id"]), {})
			"circle":
				entity = session.circles.get(str(e["id"]), {})
			"arc":
				entity = session.arcs.get(str(e["id"]), {})
			"ellipse":
				entity = session.ellipses.get(str(e["id"]), {})
			"ellipse_arc":
				entity = session.ellipse_arcs.get(str(e["id"]), {})
			"spline":
				entity = session.splines.get(str(e["id"]), {})
			"text":
				entity = session.texts.get(str(e["id"]), {})
			_:
				continue
		any = true
		if not bool(entity.get("construction", false)):
			return false
	return any


static func only_origin(selection: Array, session) -> bool:
	## The sketch origin is structural: it can be selected, constrained and dimensioned but never deleted.
	return selection.size() == 1 and str(selection[0].get("kind", "")) == "point" and session.is_origin(str(selection[0]["id"]))


static func _arcs_share_end(selection: Array, session) -> bool:
	if str(selection[0]["kind"]) != "arc" or str(selection[1]["kind"]) != "arc":
		return false
	return shared_end(session.arcs.get(str(selection[0]["id"]), {}), session.arcs.get(str(selection[1]["id"]), {})) != ""


static func shared_end(a: Dictionary, b: Dictionary) -> String:
	## The id of the endpoint two arcs have in common, or "".
	for p in [a.get("s", ""), a.get("e", "")]:
		if str(p) != "" and (str(p) == str(b.get("s", "")) or str(p) == str(b.get("e", ""))):
			return str(p)
	return ""


static func page(list: Array, shown: int, slots: int = 6) -> Dictionary:
	## The options row holds `slots` buttons. A longer menu shows slots-1 and turns the last into "More n/m" (the same idea as tool_pager.gd).
	## {items, has_more, page, pages}.
	if list.size() <= slots:
		return {"items": list.duplicate(), "has_more": false, "page": 0, "pages": 1}
	var per := slots - 1
	var pages := ceili(float(list.size()) / float(per))
	var p := clampi(shown, 0, pages - 1)
	return {"items": list.slice(p * per, mini((p + 1) * per, list.size())), "has_more": true, "page": p, "pages": pages}
