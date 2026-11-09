extends RefCounted
## The breadcrumb chain of a selection on the design table (T6): entity > body > made by <feature> > part, a port of the flat app's selection_breadcrumbs.dart
## (which has no feature rung, because the backend has no per-face feature history) with the one rung the backend CAN tell us: the feature that CREATED a body.
##
## A body's id IS the id of the feature that created it (Extrude, Revolve, Sweep, Import...), with a "#N" suffix when one operation made several solids (a
## multi-profile boss, a cut that splits a body, Mirror / Pattern copies): DIDSA-CAD backend/app/document/graph.py base_feature_id() strips "#N" and
## body_ids_for_feature_id() is the reverse. The rung reads "made by Extrude 2", never "Extrude 2": after a Cut, Fillet or Shell the body keeps its creator's id,
## and when bodies merge the survivor keeps one of their ids.
##
## A rung is {id, text, level, select}: `level` is "entity", "body", "feature", "sketch" or "part"; `select` is the selection a tap on it makes (the drawer's
## actions then change to that level's). Pure: no scene tree, no backend.

const FEATURE_RUNG_MAX := 5 ## the chain shows its first and last rung and folds the middle into "..." beyond this many rungs


static func base_feature_id(body_id: String) -> String:
	## graph.py base_feature_id(): the body id without a "#N" suffix is the id of the feature that made it.
	var i := body_id.find("#")
	return body_id.substr(0, i) if i >= 0 else body_id


static func entity_name(e: Dictionary) -> String:
	var k := str(e.get("kind", ""))
	match k:
		"face", "edge", "vertex":
			return "%s %d" % [k.capitalize(), int(e.get("index", 0)) + 1]
		"body":
			return "Body"
		"line", "point", "circle", "arc", "ellipse", "spline", "text":
			return "%s %s" % [k.capitalize(), str(e.get("label", e.get("id", "")))]
		"dimension", "constraint":
			return str(e.get("label", k.capitalize()))
		"sketch":
			return str(e.get("name", "Sketch"))
		"feature":
			return str(e.get("name", "Feature"))
	return k.capitalize()


static func _plural(kind: String, n: int) -> String:
	return "%d %s%s" % [n, kind, "" if n == 1 else "s"]


static func chain(selection: Array, ctx: Dictionary = {}) -> Array:
	## The rungs for a selection, innermost first. ctx = {body_names: {body_id -> name}, feature_names: {feature id -> "Extrude 2"}, part_name, sketch_name}.
	## Several entities: the first rung reads "3 edges"; the rungs above it appear only if every entity shares them.
	if selection.is_empty():
		return []
	var rungs: Array = []
	var part_name := str(ctx.get("part_name", "Part"))
	var first: Dictionary = selection[0]
	var kind := str(first.get("kind", ""))
	var same_kind := selection.all(func(e) -> bool: return str(e.get("kind", "")) == kind)
	var text: String
	if selection.size() == 1:
		text = entity_name(first)
	elif same_kind:
		text = _plural(kind, selection.size())
	else:
		text = "%d items" % selection.size()
	rungs.append({"id": "entity", "text": text, "level": "entity", "select": selection.duplicate()})
	if kind in ["line", "point", "circle", "arc", "ellipse", "ellipse_arc", "spline", "text", "dimension", "constraint"]:
		# a sketch entity: its sketch, then the part
		rungs.append({"id": "sketch", "text": str(ctx.get("sketch_name", "Sketch")), "level": "sketch", "select": [{"kind": "sketch", "feature_id": str(ctx.get("sketch_feature_id", ""))}]})
	elif kind in ["face", "edge", "vertex", "body"]:
		var bodies: Array = []
		for e in selection:
			var b := str(e.get("body_id", ""))
			if b != "" and b not in bodies:
				bodies.append(b)
		if bodies.size() == 1:
			var body_id: String = bodies[0]
			var body_name := str(ctx.get("body_names", {}).get(body_id, "Body"))
			if kind != "body":
				rungs.append({"id": "body", "text": body_name, "level": "body", "select": [{"kind": "body", "body_id": body_id}]})
			var feature_id := base_feature_id(body_id)
			var feature_name := str(ctx.get("feature_names", {}).get(feature_id, ""))
			if feature_name != "":
				rungs.append({"id": "feature", "text": "made by %s" % feature_name, "level": "feature", "select": [{"kind": "feature", "feature_id": feature_id, "name": feature_name}]})
	rungs.append({"id": "part", "text": "Part \"%s\"" % part_name, "level": "part", "select": []})
	return rungs


static func folded(rungs: Array) -> Dictionary:
	## The rungs the row has room for: {shown: [...], hidden: [...]}. A chain longer than FEATURE_RUNG_MAX keeps its first and last rungs and folds the middle
	## into one "..." rung that opens the rest.
	if rungs.size() <= FEATURE_RUNG_MAX:
		return {"shown": rungs.duplicate(), "hidden": []}
	var hidden := rungs.slice(1, rungs.size() - 1)
	return {"shown": [rungs[0], {"id": "fold", "text": "...", "level": "fold", "select": []}, rungs[rungs.size() - 1]], "hidden": hidden}
