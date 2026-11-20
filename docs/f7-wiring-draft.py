# DRAFT, NEVER RUN: the F7 part 2 wiring (SketchSession.rigidity / entity_states / contradictory_points, sketch_view.gd per-entity colours) as a patch script written while the
# tree was in the F8 state. Use it as a reading aid for the plan in docs/parity-followups-investigation.md (tracker row F7), not as a tool: apply the edits by hand with Edit, then delete this file.
import re
p='/home/user/DIDSA-VR/scripts/design_table/sketch_session.gd'
s=open(p).read()

# 1. preload
s=s.replace('const ShapeProposals := preload("res://scripts/motion/shape_proposals.gd")\n','const ShapeProposals := preload("res://scripts/motion/shape_proposals.gd")\nconst SketchRigidity := preload("res://scripts/design_table/sketch_rigidity.gd")\n',1)

# 2. replace the stubs
a=s.index('func point_rigidity(_id: String) -> String:')
b=s.index('func restore_points() -> void:')
new='''func rigidity() -> RefCounted:
	## The topological rigidity count (sketch_rigidity.gd, F7) of the sketch as it is: fixed = the origin, the locked points and the points of a Fix; the backend's last solve
	## converged (false before any solve). Cheap (no geometry is read); recomputed per call, which a refresh or a press makes a handful of.
	var fixed := {}
	if origin_id != "":
		fixed[origin_id] = true
	for id in point_locked:
		if bool(point_locked[id]):
			fixed[str(id)] = true
	for cid in constraints:
		var c: Dictionary = constraints[cid]
		if str(c.get("type", "")) == "fixed":
			for pid in constraint_point_ids(c):
				fixed[str(pid)] = true
	return SketchRigidity.analyse(points.keys(), fixed.keys(), lines, constraints.values(), converged and dof >= 0)


func point_rigidity(id: String) -> String:
	## What the rigidity analysis says of a point: "over" (over-constrained), "pinned" (tied to a fixed point by coincident / concentric links), "fully" (fully constrained) or
	## "free".
	var r: RefCounted = rigidity()
	if r.is_over(id):
		return "over"
	if r.is_pinned(id):
		return "pinned"
	return "fully" if r.is_fully(id) else "free"


func sketch_grounded() -> bool:
	## The rigidity analysis grounds at least one point (the pre-grab rule's whole-sketch case).
	return (rigidity() as RefCounted).any_grounded


func contradictory_points() -> Dictionary:
	## id -> true: the endpoints of a line that is both horizontal and vertical, or of either of two lines that are both parallel and perpendicular (forced over-constrained,
	## spec 4 and 13.5).
	var kinds := {} ## line id -> {type: true}; "a|b" -> {type: true} for a pair of lines
	for cid in constraints:
		var c: Dictionary = constraints[cid]
		var t := str(c.get("type", ""))
		if t == "horizontal" or t == "vertical":
			var lid := str(c.get("line_id", ""))
			if lid != "":
				kinds[lid] = kinds.get(lid, {})
				kinds[lid][t] = true
		elif t == "parallel" or t == "perpendicular":
			var key := "%s|%s" % [str(c.get("line1_id", "")), str(c.get("line2_id", ""))]
			var rev := "%s|%s" % [str(c.get("line2_id", "")), str(c.get("line1_id", ""))]
			kinds[key] = kinds.get(key, {})
			kinds[key][t] = true
			kinds[rev] = kinds[key]
	var out := {}
	for key in kinds:
		if (kinds[key].has("horizontal") and kinds[key].has("vertical")) or (kinds[key].has("parallel") and kinds[key].has("perpendicular")):
			for lid in str(key).split("|"):
				if lines.has(lid):
					out[str(lines[lid]["a"])] = true
					out[str(lines[lid]["b"])] = true
	return out


func on_contradictory_line(point_id: String) -> bool:
	return contradictory_points().has(point_id)


func entity_states() -> Dictionary:
	## "kind:id" -> "over" | "fully" | "free" for every line, circle, arc, ellipse, elliptical arc, spline and text (F7, spec 4): over when a pair is over by the count or a defining
	## point is forced over (a constraint the last solve reported failed, a line both horizontal and vertical, two lines both parallel and perpendicular); fully when the
	## whole sketch is fully constrained or every defining pair is. The colours are the view's.
	var r: RefCounted = rigidity()
	var whole := constraint_state() == "full"
	var forced := failed_point_ids()
	forced.merge(contradictory_points())
	var out := {}
	for kind in ["line", "circle", "arc", "ellipse", "ellipse_arc", "spline", "text"]:
		var source: Dictionary = _entity_dict(kind)
		for id in source:
			var e: Dictionary = source[id]
			var pts: Array = []
			match kind:
				"line":
					pts = [e["a"], e["b"]]
				"circle":
					pts = [e["c"], e["p"]]
				"arc":
					pts = [e["c"], e["s"], e["e"]]
				"ellipse":
					pts = [e["c"], e["ma"], e["mi"]]
				"ellipse_arc":
					pts = [e["c"], e["ma"], e["mi"], e["s"], e["e"]]
				"spline":
					pts = e.get("through", [])
				"text":
					pts = [e["anchor"]]
			var state := "free"
			if pts.size() >= (1 if kind == "text" else 2):
				var pair_pts: Array = (pts as Array).map(func(v: Variant) -> String: return str(v))
				var any_forced := false
				for pid in pair_pts:
					any_forced = any_forced or forced.has(pid)
				state = r.entity_state(SketchRigidity.pairs_of(kind, pair_pts))
				if any_forced:
					state = "over"
				elif whole and state != "over":
					state = "fully"
			out["%s:%s" % [kind, id]] = state
	return out


'''
s=s[:a]+new+s[b:]
open(p,'w').write(s)

# --- the view
p='/home/user/DIDSA-VR/scripts/design_table/sketch_view.gd'
s=open(p).read()
s=s.replace('''"base_obj": FULL_COLOUR if session.constraint_state() == "full" else OBJECT_COLOUR, "failed_e": session.failed_entity_ids(), "failed_p": session.failed_point_ids()}
		var cache_key := [canvas_scale, _geo_ctx["warn"], _geo_ctx["accent"], repick_point, _geo_ctx["base_obj"]]''','''"base_obj": OBJECT_COLOUR, "states": session.entity_states(), "failed_e": session.failed_entity_ids(), "failed_p": session.failed_point_ids()}
		var cache_key := [canvas_scale, _geo_ctx["warn"], _geo_ctx["accent"], repick_point, _geo_ctx["base_obj"]]''',1)
s=s.replace("# the sketch's state: fully constrained geometry is tinted, what the solver says conflicts is red","# the sketch's state: each entity is tinted when it is fully constrained (F7: its own defining pairs, or the whole sketch), red when over-constrained or what the solver says conflicts",1)
s=s.replace('''	sig.append_array([(_geo_ctx["failed_e"] as Dictionary).has(id), session.is_reference(id), _source_of(session, kind).get(id, {}).get("construction", false)])''','''	sig.append_array([(_geo_ctx["failed_e"] as Dictionary).has(id), (_geo_ctx["states"] as Dictionary).get(key, "free"), session.is_reference(id), _source_of(session, kind).get(id, {}).get("construction", false)])''',1)
s=s.replace('''	var failed_e: Dictionary = _geo_ctx["failed_e"]
	var failed_p: Dictionary = _geo_ctx["failed_p"]
	var key := "%s:%s" % [kind, id]''','''	var failed_e: Dictionary = _geo_ctx["failed_e"]
	var failed_p: Dictionary = _geo_ctx["failed_p"]
	var key := "%s:%s" % [kind, id]
	var rigid: String = (_geo_ctx["states"] as Dictionary).get(key, "free")''',1)
old='FAILED_COLOUR if failed_e.has(id) else (CONSTRUCTION_COLOUR if construction else base_obj)'
new_c='_object_colour(failed_e.has(id), rigid, construction, base_obj)'
assert s.count(old)==5, s.count(old)
s=s.replace(old,new_c)
s=s.replace('''func _assemble_geo() -> void:''','''static func _object_colour(failed: bool, rigid: String, construction: bool, base: Color) -> Color:
	## An entity's own colour (F7): red when over-constrained (the count, or the solver's failed list), then construction, then green when fully constrained, else plain. The
	## order on a line in the flat app: over, construction, fully, unconstrained (so red shows on construction geometry, green does not).
	if failed or rigid == "over":
		return FAILED_COLOUR
	if construction:
		return CONSTRUCTION_COLOUR
	return FULL_COLOUR if rigid == "fully" else base


func _assemble_geo() -> void:''',1)
open(p,'w').write(s)
print('patched')
