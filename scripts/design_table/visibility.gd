extends RefCounted
## What the design table shows (docs/sketch-as-seed-plan.md section 2), as pure rules over the backend's feature rows and the file's
## `hidden_feature_ids`, no scene tree, so tests can pin them. Two kinds of thing:
##   FEATURE categories (sketches, bodies, surfaces, curves, planes): hidden per feature id in `hidden_feature_ids`, the only visibility
##     state that is saved. The load rule decides the starting set; a category button edits the same list (batch rule below).
##   SESSION categories (reference planes, origin and axes, dimension glyphs, construction geometry, edge lines): one on/off switch each,
##     held in an instance of this script for the session and never saved.
## Rollback: rolled-back features are not on the table, so they are not counted and consume nothing.

const SKETCHES := "sketches"
const BODIES := "bodies"
const SURFACES := "surfaces"
const CURVES := "curves"
const PLANES := "planes"
const FEATURE_CATEGORIES := [SKETCHES, BODIES, SURFACES, CURVES, PLANES]

const REFERENCE_PLANES := "reference_planes"
const ORIGIN_AXES := "origin_axes"
const DIMENSIONS := "dimensions"
const CONSTRUCTION := "construction"
const EDGE_LINES := "edge_lines"
const SESSION_CATEGORIES := [REFERENCE_PLANES, ORIGIN_AXES, DIMENSIONS, CONSTRUCTION, EDGE_LINES]

const CURVE_TYPES := ["curve", "curve_3d", "spline_3d"] ## the backend's 3D curve rows (no tool makes them yet: matched by name)

var _on := {} ## session category -> bool


func _init(edge_lines_on := true) -> void:
	reset(edge_lines_on)


func reset(edge_lines_on: bool) -> void:
	## The load rule for the session switches: everything off except edge lines, which follow View > Display.
	_on = {}
	for c in SESSION_CATEGORIES:
		_on[c] = false
	_on[EDGE_LINES] = edge_lines_on


func is_on(category: String) -> bool:
	return bool(_on.get(category, false))


func set_on(category: String, on: bool) -> void:
	if _on.has(category):
		_on[category] = on


func toggle(category: String) -> bool:
	set_on(category, not is_on(category))
	return is_on(category)


func set_all(on: bool) -> void:
	for c in SESSION_CATEGORIES:
		_on[c] = on


# --- Feature categories ---------------------------------------------------------------------

static func category_of(f: Dictionary) -> String:
	match str(f.get("type", "")):
		"sketch":
			return SKETCHES
		"create_plane":
			return PLANES
		"surface":
			return SURFACES
	if CURVE_TYPES.has(str(f.get("type", ""))):
		return CURVES
	return BODIES


static func ids_of(features: Array, category: String, excluded: Array = []) -> Array:
	## The feature ids of one category that are on the table (not rolled back), in build order.
	var out: Array = []
	for f in features:
		var id := str(f.get("id", ""))
		if category_of(f) == category and not excluded.has(id):
			out.append(id)
	return out


static func seed_sketch_ids(features: Array, excluded: Array = []) -> Array:
	## The sketches an applied (not rolled-back) feature consumes: an Extrude's or Revolve's sketch, a Loft's sections, a Sweep's profile
	## and path sketches. (A Pattern's direction does not count: it is a reference, not a consumed profile.) A path ref names the sketch by
	## its `sketch_id`, not its feature id, so that is mapped back through the sketch rows.
	var by_sketch_id := {}
	for f in features:
		if str(f.get("type", "")) == "sketch":
			by_sketch_id[str(f.get("sketch_id", ""))] = str(f.get("id", ""))
	var out: Array = []
	for f in features:
		if excluded.has(str(f.get("id", ""))):
			continue
		var found: Array = []
		match str(f.get("type", "")):
			"extrude", "revolve":
				found.append(str(f.get("sketch_feature_id", "")))
			"loft":
				for sec in f.get("sections", []):
					found.append(str((sec as Dictionary).get("sketch_feature_id", "")))
			"sweep":
				found.append(str(f.get("sketch_feature_id", "")))
				for ref in f.get("path_refs", []):
					found.append(str(by_sketch_id.get(str((ref as Dictionary).get("sketch_id", "")), "")))
		for id in found:
			if id != "" and not out.has(id):
				out.append(id)
	return out


static func load_hidden(features: Array, saved_hidden: Array, excluded: Array = []) -> Array:
	## The load rule: the hidden list a freshly loaded part starts from. Created planes are hidden; sketches follow the seed rule (consumed
	## ones hidden, the rest shown, whatever the file said); every other id the file hid stays hidden, as do ids of other parts.
	var mine := {}
	for f in features:
		mine[str(f.get("id", ""))] = category_of(f)
	var out: Array = []
	for id in saved_hidden:
		var s := str(id)
		if not mine.has(s) or (mine[s] != SKETCHES and mine[s] != PLANES):
			out.append(s)
	for id in seed_sketch_ids(features, excluded):
		if mine.get(id, "") == SKETCHES and not out.has(id):
			out.append(id)
	for id in ids_of(features, PLANES):
		if not out.has(id):
			out.append(id)
	return out


static func category_state(features: Array, hidden: Array, category: String, excluded: Array = []) -> Dictionary:
	## {total, visible, state}: state is "all" (everything visible), "some", "none" (all hidden) or "empty" (nothing in the category).
	## The label is the drawer's "3 of 5".
	var ids := ids_of(features, category, excluded)
	var visible := 0
	for id in ids:
		if not hidden.has(id):
			visible += 1
	var state := "empty"
	if not ids.is_empty():
		state = "all" if visible == ids.size() else ("none" if visible == 0 else "some")
	return {"total": ids.size(), "visible": visible, "state": state, "label": "%d of %d" % [visible, ids.size()]}


static func toggle_category(features: Array, hidden: Array, category: String, excluded: Array = []) -> Array:
	## The category button: everything visible -> hide all; otherwise show ALL, whatever the earlier individual settings. Returns the new
	## hidden list (ids of other categories and other parts untouched).
	var ids := ids_of(features, category, excluded)
	var hide_all: bool = category_state(features, hidden, category, excluded)["state"] == "all"
	var out: Array = []
	for id in hidden:
		if hide_all or not ids.has(str(id)):
			out.append(str(id))
	if hide_all:
		for id in ids:
			if not out.has(id):
				out.append(id)
	return out
