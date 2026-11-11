extends RefCounted
## What a selection on the design table can do (T6, docs/test-report-30-oct-plan.md), as DATA: a pure table from a selection to the actions the selection drawer
## offers, a port of the flat app's `selection_actions.dart` contextActionsFor() (DIDSA-CAD client/lib/viewport3d/), taken as a reference rather than a complete
## list. No scene tree, no backend: tests/design_table_selection_actions.gd pins every row.
##
## A selection is a list of entities: {kind: "face" | "edge" | "vertex" | "body" | "sketch" | "feature", ...}:
##   face   {kind, body_id, index, planar: bool}      edge   {kind, body_id, index}      vertex {kind, body_id, index}
##   body   {kind, body_id}                            sketch {kind, feature_id, closed: bool}      feature {kind, feature_id, type}
## `ctx` = {surface_bodies: [body ids with no solid], has_face_extrude: bool (the backend can extrude a face; false: left out)}.
##
## An action is {id, text, group, enabled, reason}. `id` is a tool id of the table's deck where there is one (fillet, chamfer, create_plane, move_face, ...) so the
## drawer can start that tool with the selection already picked, else a drawer verb (sketch_on_face, edit_sketch, edit_feature, suppress, delete_feature, rollback,
## return_arena...). `group` is "create" (blue), "refine" (amber) or "modify" (violet), the deck's three feature groups. A disabled action keeps its place with
## its `reason` (the flat app's rule: explain, don't hide). The first action is the default.

const GROUP_CREATE := "create"
const GROUP_REFINE := "refine"
const GROUP_MODIFY := "modify"


static func _a(id: String, text: String, group: String, enabled := true, reason := "") -> Dictionary:
	return {"id": id, "text": text, "group": group, "enabled": enabled, "reason": reason}


static func kinds(selection: Array) -> Dictionary:
	var out := {"face": 0, "edge": 0, "vertex": 0, "body": 0, "sketch": 0, "feature": 0}
	for e in selection:
		var k := str(e.get("kind", ""))
		out[k] = int(out.get(k, 0)) + 1
	return out


static func body_ids(selection: Array) -> Array:
	var ids: Array = []
	for e in selection:
		var id := str(e.get("body_id", ""))
		if id != "" and id not in ids:
			ids.append(id)
	return ids


static func actions_for(selection: Array, ctx: Dictionary = {}) -> Array:
	## The actions for this selection, default first; [] for nothing selected.
	if selection.is_empty():
		return []
	var c := kinds(selection)
	var n := selection.size()
	var surface: Array = ctx.get("surface_bodies", [])
	var bodies := body_ids(selection)
	var one_body := bodies.size() <= 1
	var on_surface := not bodies.is_empty() and bodies.all(func(b) -> bool: return b in surface)
	if c["sketch"] == n and n == 1:
		return _sketch_actions(selection[0])
	if c["feature"] == n and n == 1:
		return _feature_actions(selection[0])
	if c["body"] == n:
		return _body_actions(n, on_surface)
	if c["edge"] == n:
		return _edge_actions(n, one_body, on_surface)
	if c["face"] == n:
		return _face_actions(selection, one_body, on_surface, bool(ctx.get("has_face_extrude", false)))
	if c["vertex"] == n:
		return _vertex_actions(n)
	return _mixed_actions(c, n)


static func _edge_actions(n: int, one_body: bool, on_surface: bool) -> Array:
	var out: Array = []
	var two_bodies := "Pick edges on one body"
	var no_solid := "A surface body has no solid to round off"
	var blocked := "" if one_body else two_bodies
	if on_surface:
		blocked = no_solid
	out.append(_a("fillet", "Fillet", GROUP_REFINE, blocked == "", blocked))
	out.append(_a("chamfer", "Chamfer", GROUP_REFINE, blocked == "", blocked))
	out.append(_a("create_plane", "Create plane", GROUP_CREATE, n == 1, "" if n == 1 else "Pick one edge (a plane normal to it)"))
	return out


static func _face_actions(selection: Array, one_body: bool, on_surface: bool, has_face_extrude: bool) -> Array:
	var n := selection.size()
	var out: Array = []
	var all_planar := selection.all(func(f) -> bool: return bool(f.get("planar", false)))
	if n == 1:
		var planar := bool(selection[0].get("planar", false))
		if planar:
			out.append(_a("sketch_on_face", "New sketch on face", GROUP_CREATE))
			if has_face_extrude:
				out.append(_a("extrude_face", "Extrude face", GROUP_CREATE))
		out.append(_a("move_face", "Move face", GROUP_MODIFY))
		if planar:
			out.append(_a("create_plane", "Create plane", GROUP_CREATE))
		if not on_surface:
			out.append(_a("fillet", "Fillet", GROUP_REFINE))
			out.append(_a("chamfer", "Chamfer", GROUP_REFINE))
			out.append(_a("shell", "Shell", GROUP_REFINE, true, ""))
		out.append(_a("delete_face", "Delete face", GROUP_MODIFY))
		return out
	# two or more faces
	if n == 2:
		out.append(_a("create_plane", "Create plane", GROUP_CREATE, all_planar, "" if all_planar else "Midplane needs two flat faces"))
	out.append(_a("move_face", "Move faces", GROUP_MODIFY, one_body, "" if one_body else "Pick faces on one body"))
	if not on_surface:
		out.append(_a("shell", "Shell", GROUP_REFINE, one_body, "" if one_body else "Pick faces on one body"))
	out.append(_a("delete_face", "Delete faces", GROUP_MODIFY, one_body, "" if one_body else "Pick faces on one body"))
	return out


static func _vertex_actions(n: int) -> Array:
	var ok := n >= 2
	return [_a("create_plane", "Create plane", GROUP_CREATE, ok, "" if ok else "Pick an edge or face as well")]


static func _body_actions(n: int, on_surface: bool) -> Array:
	var out: Array = []
	out.append(_a("move_body", "Move body", GROUP_MODIFY))
	out.append(_a("scale_body", "Scale body", GROUP_MODIFY))
	out.append(_a("mirror", "Mirror", GROUP_MODIFY))
	out.append(_a("pattern", "Pattern", GROUP_MODIFY))
	out.append(_a("shell", "Shell", GROUP_REFINE, not on_surface, "" if not on_surface else "A surface body has no solid to hollow"))
	out.append(_a("delete_body", "Delete body", GROUP_MODIFY))
	return out


static func _mixed_actions(c: Dictionary, n: int) -> Array:
	## Edges with faces or corners: only a plane can use a mixture (the flat app's Create plane combinations).
	var planes := (int(c["edge"]) == 1 and int(c["vertex"]) == 1 and n == 2) or (int(c["face"]) == 1 and int(c["vertex"]) == 1 and n == 2)
	return [_a("create_plane", "Create plane", GROUP_CREATE, planes, "" if planes else "Pick things of one kind")]


static func _sketch_actions(sketch: Dictionary) -> Array:
	var closed := bool(sketch.get("closed", false))
	var open_chain := bool(sketch.get("open_chain", false)) # a thin Revolve can use one open line chain
	var no_shape := "No closed shape"
	return [
		_a("edit_sketch", "Edit sketch", GROUP_CREATE),
		_a("extrude", "Extrude", GROUP_CREATE, closed, "" if closed else no_shape),
		_a("revolve", "Revolve", GROUP_CREATE, closed or open_chain, "" if (closed or open_chain) else no_shape),
		_a("sweep", "Sweep", GROUP_CREATE, closed, "" if closed else no_shape),
		_a("loft", "Loft", GROUP_CREATE, closed, "" if closed else no_shape),
		_a("delete_feature", "Delete", GROUP_MODIFY),
	]


static func _feature_actions(feature: Dictionary) -> Array:
	var suppressed := bool(feature.get("suppressed", false))
	return [
		_a("edit_feature", "Edit", GROUP_CREATE),
		_a("rollback", "Roll back to here", GROUP_MODIFY),
		_a("suppress", "Unsuppress" if suppressed else "Suppress", GROUP_MODIFY),
		_a("delete_feature", "Delete", GROUP_MODIFY),
	]


static func part_actions() -> Array:
	## What the Part rung of a breadcrumb offers.
	return [_a("return_arena", "Return to arena", GROUP_MODIFY), _a("appearance", "Appearance", GROUP_MODIFY), _a("properties", "Properties", GROUP_MODIFY)]


static func default_action(selection: Array, ctx: Dictionary = {}) -> Dictionary:
	## The first enabled action, or {} .
	for a in actions_for(selection, ctx):
		if a["enabled"]:
			return a
	return {}
