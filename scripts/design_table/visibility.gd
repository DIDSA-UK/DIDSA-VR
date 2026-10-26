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
const CONSTRAINTS := "constraints"
const SESSION_CATEGORIES := [REFERENCE_PLANES, ORIGIN_AXES, DIMENSIONS, CONSTRAINTS]
const SKETCH_GLYPHS := [DIMENSIONS, CONSTRAINTS] ## on by default: they are how a sketch is defined; they show only in the sketch they belong to (while it is open)

const CURVE_TYPES := ["curve", "curve_3d", "spline_3d"] ## the backend's 3D curve rows (no tool makes them yet: matched by name)

signal changed ## a switch moved: the drawer redraws

var _on := {} ## session category -> bool
var _touched := {} ## session category -> true once the user has moved its switch (the load default is "off", which is not the same as "hidden")


func _init() -> void:
	reset()


func reset() -> void:
	## The load rule for the session switches: everything off, except the sketch glyphs (dimensions and constraints), which are on: they only ever
	## show in the sketch that is open.
	_on = {}
	_touched = {}
	for c in SESSION_CATEGORIES:
		_on[c] = SKETCH_GLYPHS.has(c)
	changed.emit()


func is_on(category: String) -> bool:
	return bool(_on.get(category, false))


func set_on(category: String, on: bool) -> void:
	if _on.has(category) and _on[category] != on:
		_on[category] = on
		_touched[category] = true
		changed.emit()


func is_hidden_by_user(category: String) -> bool:
	## True if the user switched this category off (as opposed to it simply never having been switched on).
	return bool(_touched.get(category, false)) and not is_on(category)


func toggle(category: String) -> bool:
	set_on(category, not is_on(category))
	return is_on(category)


func set_all(on: bool) -> void:
	for c in SESSION_CATEGORIES:
		_on[c] = on
		_touched[c] = true
	changed.emit()


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


static func _seeds_of_row(f: Dictionary, by_sketch_id: Dictionary) -> Array:
	var found: Array = []
	match str(f.get("type", "")):
		"extrude", "revolve":
			found.append(str(f.get("sketch_feature_id", "")))
		"loft":
			for sec in f.get("sections", []):
				found.append(str((sec as Dictionary).get("sketch_feature_id", "")))
			for guide in f.get("guide_curves", []):
				for ref in guide:
					found.append(str(by_sketch_id.get(str((ref as Dictionary).get("sketch_id", "")), "")))
		"sweep":
			found.append(str(f.get("sketch_feature_id", "")))
			for ref in f.get("path_refs", []):
				found.append(str(by_sketch_id.get(str((ref as Dictionary).get("sketch_id", "")), "")))
	return found.filter(func(id): return id != "")


static func _sketch_index(features: Array) -> Dictionary:
	## A path ref names its sketch by `sketch_id`, not its feature id: sketch_id -> feature id.
	var by_sketch_id := {}
	for f in features:
		if str(f.get("type", "")) == "sketch":
			by_sketch_id[str(f.get("sketch_id", ""))] = str(f.get("id", ""))
	return by_sketch_id


static func seed_causes(features: Array, excluded: Array = []) -> Dictionary:
	## sketch feature id -> the ids of the applied (not rolled-back) features that consume it: an Extrude's or Revolve's sketch, a Loft's
	## sections, a Sweep's profile and path sketches. (A Pattern's direction does not count: it is a reference, not a consumed profile.)
	var by_sketch_id := _sketch_index(features)
	var out := {}
	for f in features:
		var id := str(f.get("id", ""))
		if excluded.has(id):
			continue
		for sketch in _seeds_of_row(f, by_sketch_id):
			if not out.has(sketch):
				out[sketch] = []
			if not (out[sketch] as Array).has(id):
				(out[sketch] as Array).append(id)
	return out


static func seed_sketch_ids(features: Array, excluded: Array = []) -> Array:
	return seed_causes(features, excluded).keys()


static func seeds_of_feature(features: Array, feature_id: String) -> Array:
	## The sketches ONE feature consumes (empty for a feature that is not an extrude, revolve, loft or sweep).
	var by_sketch_id := _sketch_index(features)
	for f in features:
		if str(f.get("id", "")) == feature_id:
			return _seeds_of_row(f, by_sketch_id)
	return []


static func load_hidden(features: Array, saved_hidden: Array, excluded: Array = []) -> Array:
	## The load rule: the hidden list a freshly loaded part starts from. Sketches follow the seed rule (consumed ones hidden, the rest shown, whatever the
	## file said); every other id the file hid stays hidden (created planes included: they start visible unless the file hid them), as do ids of other parts.
	var mine := {}
	for f in features:
		mine[str(f.get("id", ""))] = category_of(f)
	var out: Array = []
	for id in saved_hidden:
		var s := str(id)
		if not mine.has(s) or mine[s] != SKETCHES:
			out.append(s)
	for id in seed_sketch_ids(features, excluded):
		if mine.get(id, "") == SKETCHES and not out.has(id):
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


static func set_all_features(features: Array, hidden: Array, hide: bool, excluded: Array = []) -> Array:
	## "Show all" / "Hide all" over every feature category: the new hidden list (other parts' ids untouched).
	var mine := {}
	for f in features:
		if not excluded.has(str(f.get("id", ""))):
			mine[str(f.get("id", ""))] = true
	var out: Array = []
	for id in hidden:
		if not mine.has(str(id)):
			out.append(str(id))
	if hide:
		for id in mine:
			out.append(id)
	return out
