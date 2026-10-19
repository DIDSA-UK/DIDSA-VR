extends RefCounted
## The Appearance tool's resolution rule: which appearance a face shows (DIDSA-CAD `docs/appearance-tool-scope.md` D3).
## A line-for-line copy of DIDSA-CAD's reference, `backend/app/document/appearance.py`, checked against its golden vectors
## (`tests/fixtures/appearance_vectors.json`, a copy of DIDSA-CAD's `docs/appearance/vectors.json`; tests/appearance_vectors.gd).
## The backend paints the glb's materials with the same rule; this copy is for what the client works out itself: the live
## preview of a paint row, the swatch each row shows, the eyedropper, and the sandbox's temporary paint.
##
## It works on a plain-dictionary RESOLUTION MODEL, the vectors' shape:
##   {"parts": {part_id: {
##       "appearance": {...}, "body_appearances": {body_id: {...}},
##       "face_appearances": [{"face": {"body_id", "index"}, "appearance": {...}}],
##       "appearance_overrides": [{"path", "scope"?, "pattern_id"?, "part_id"?, "body_id"?, "face"?, "appearance"}],
##       "occurrences": {occurrence_id: {"part_id", "color"}}}}}
## An appearance is {colour?, opacity?, metallic?, roughness?, emission?, emission_strength?}; only set fields are present.
##
## Which wins, field by field: the shown scene (or the sandbox's temporary paint), then the overrides of the root, then of each
## sub-assembly file on the way down (ending with the leaf Part's own list), then the leaf Part's own face / body / part
## appearance. Within one list: a face beats a body beats a whole node; then the node nearest the face; on one node a named
## path beats Pattern (all N) beats Every <part> (N); the Whole assembly (empty path) is under everything; a tie goes to the
## later entry. `Occurrence.color` reads as the override {path: <occurrence>, appearance: {colour}}.

const FIELDS := ["colour", "opacity", "metallic", "roughness", "emission", "emission_strength"]
const SCOPE_PATTERN := "pattern"
const SCOPE_SAME_PART := "same_part"
const PATTERN_SEGMENT := "#pattern:"
const EMISSION_STRENGTH_MAX := 10.0


static func appearance_errors(data: Variant) -> Array:
	## Why `data` is not a valid appearance ([] when it is), the backend's own checks (so the tool refuses before sending).
	if not (data is Dictionary):
		return ["appearance must be an object"]
	var errors: Array = []
	for key in data:
		if not FIELDS.has(key):
			errors.append("unknown appearance field '%s'" % key)
	var any_set := false
	for key in FIELDS:
		if data.get(key) != null:
			any_set = true
	if not any_set:
		errors.append("an appearance must set at least one field")
	for key in ["colour", "emission"]:
		var v = data.get(key)
		if v != null and not (v is String and is_hex(v)):
			errors.append("%s must be '#RRGGBB'" % key)
	for key in ["opacity", "metallic", "roughness", "emission_strength"]:
		var v = data.get(key)
		if v == null:
			continue
		var upper := EMISSION_STRENGTH_MAX if key == "emission_strength" else 1.0
		if not (v is float or v is int) or float(v) < 0.0 or float(v) > upper:
			errors.append("%s must be a number from 0 to %s" % [key, str(upper)])
	return errors


static func is_hex(text: String) -> bool:
	if text.length() != 7 or not text.begins_with("#"):
		return false
	for c in text.substr(1):
		if not "0123456789abcdefABCDEF".contains(c):
			return false
	return true


static func base_segment(segment: String) -> String:
	## The occurrence id of a path segment: a pattern copy `<source>#pattern:<pattern id>:<index>` names `<source>`.
	var at := segment.find(PATTERN_SEGMENT)
	return segment if at < 0 else segment.substr(0, at)


static func split_path(path: String) -> Array:
	return [] if path == "" else Array(path.split("/"))


static func override_key(record: Dictionary) -> Array:
	## What one override targets; an assembly holds at most one override per key.
	var face = record.get("face")
	return [str(record.get("path", "")), record.get("scope"), record.get("pattern_id"), record.get("part_id"), record.get("body_id"),
		int(face.get("index")) if face is Dictionary and face.get("index") != null else null]


static func effective_overrides(part: Dictionary) -> Array:
	## A Part's own override list with the legacy `Occurrence.color` aliases folded in.
	var explicit: Array = (part.get("appearance_overrides", []) as Array).duplicate()
	var by_key := {}
	for i in explicit.size():
		by_key[str(override_key(explicit[i]))] = i
	var legacy: Array = []
	var occurrences: Dictionary = part.get("occurrences", {}) if part.get("occurrences") is Dictionary else {}
	for occurrence_id in occurrences:
		var colour = (occurrences[occurrence_id] as Dictionary).get("color")
		if colour == null or str(colour) == "":
			continue
		var key := str([str(occurrence_id), null, null, null, null, null])
		if by_key.has(key):
			var record: Dictionary = explicit[by_key[key]]
			if (record["appearance"] as Dictionary).get("colour") == null:
				var merged: Dictionary = (record["appearance"] as Dictionary).duplicate()
				merged["colour"] = colour
				var copy := record.duplicate()
				copy["appearance"] = merged
				explicit[by_key[key]] = copy
		else:
			legacy.append({"path": str(occurrence_id), "appearance": {"colour": colour}})
	return legacy + explicit


static func _specificity(record: Dictionary, suffix: Array, suffix_parts: Array, body_id: Variant, face_index: Variant) -> Variant:
	## [subshape, depth, kind] when `record` applies to the face (body_id, face_index) of the instance `suffix` below the
	## record's own Part, else null. Larger wins (compared element by element).
	var face = record.get("face")
	var has_face: bool = face is Dictionary
	var record_body = record.get("body_id")
	if record_body == null and has_face:
		record_body = face.get("body_id")
	var subshape := 2 if has_face else (1 if record_body != null else 0)
	if subshape > 0:
		if body_id == null or str(record_body) != str(body_id):
			return null
		if has_face and (face_index == null or int(face.get("index", -1)) != int(face_index)):
			return null
	var scope = record.get("scope")
	if scope == SCOPE_SAME_PART:
		var anchor := -1
		for j in suffix_parts.size():
			if suffix_parts[j] == record.get("part_id"):
				anchor = j
		if anchor < 0:
			return null
		var depth := anchor + 1
		if subshape > 0 and depth != suffix.size():
			return null
		return [subshape, depth, 1]
	var segments := split_path(str(record.get("path", "")))
	var n := segments.size()
	if scope == SCOPE_PATTERN:
		if n == 0 or suffix.size() < n or suffix.slice(0, n - 1) != segments.slice(0, n - 1):
			return null
		var source: String = segments[n - 1]
		var segment: String = suffix[n - 1]
		if segment != source and not segment.begins_with("%s%s%s:" % [source, PATTERN_SEGMENT, str(record.get("pattern_id"))]):
			return null
		if subshape > 0 and suffix.size() != n:
			return null
		return [subshape, n, 2]
	if suffix.size() < n or suffix.slice(0, n) != segments:
		return null
	if n == 0 and subshape == 0:
		return [0, 0, 0]
	if subshape > 0 and suffix.size() != n:
		return null
	return [subshape, n, 3]


static func _ordered_matches(records: Array, suffix: Array, suffix_parts: Array, body_id: Variant, face_index: Variant) -> Array:
	var matched: Array = []
	for index in records.size():
		var spec = _specificity(records[index], suffix, suffix_parts, body_id, face_index)
		if spec != null:
			matched.append({"spec": spec + [index], "appearance": records[index]["appearance"]})
	matched.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _greater(a["spec"], b["spec"]))
	return matched.map(func(m: Dictionary) -> Dictionary: return m["appearance"])


static func _greater(a: Array, b: Array) -> bool:
	for i in a.size():
		if a[i] != b[i]:
			return a[i] > b[i]
	return false


static func instance_chain(model: Dictionary, root_id: String, path: Array) -> Variant:
	## The Part ids from the root down to the instance (path.size() + 1 of them), or null when a segment does not resolve.
	var parts: Dictionary = model.get("parts", {})
	var chain: Array = [root_id]
	for segment in path:
		var part: Dictionary = parts.get(chain[chain.size() - 1], {})
		var occurrences: Dictionary = part.get("occurrences", {}) if part.get("occurrences") is Dictionary else {}
		var occurrence = occurrences.get(base_segment(str(segment)))
		if occurrence == null or not parts.has(str((occurrence as Dictionary).get("part_id", ""))):
			return null
		chain.append(str(occurrence["part_id"]))
	if not parts.has(root_id):
		return null
	return chain


static func resolve_layers(model: Dictionary, root_id: String, path: Array, body_id: Variant = null, face_index: Variant = null, scene_overrides: Array = []) -> Array:
	## Every appearance record that applies to one face (body_id null: the instance as a whole), highest priority first.
	var chain = instance_chain(model, root_id, path)
	if chain == null:
		return []
	var parts: Dictionary = model["parts"]
	var layers: Array = []
	if not scene_overrides.is_empty():
		layers += _ordered_matches(scene_overrides, path, chain.slice(1), body_id, face_index)
	for k in chain.size():
		layers += _ordered_matches(effective_overrides(parts[chain[k]]), path.slice(k), chain.slice(k + 1), body_id, face_index)
	layers += _leaf_layers(parts[chain[chain.size() - 1]], body_id, face_index)
	return layers


static func _leaf_layers(leaf: Dictionary, body_id: Variant, face_index: Variant) -> Array:
	var out: Array = []
	if body_id != null:
		for entry in leaf.get("face_appearances", []):
			var face: Dictionary = entry["face"]
			if str(face.get("body_id")) == str(body_id) and face_index != null and int(face.get("index", -1)) == int(face_index):
				out.append(entry["appearance"])
		var bodies: Dictionary = leaf.get("body_appearances", {}) if leaf.get("body_appearances") is Dictionary else {}
		if bodies.get(str(body_id)) is Dictionary and not (bodies[str(body_id)] as Dictionary).is_empty():
			out.append(bodies[str(body_id)])
	if leaf.get("appearance") is Dictionary and not (leaf["appearance"] as Dictionary).is_empty():
		out.append(leaf["appearance"])
	return out


static func merge_layers(layers: Array) -> Dictionary:
	## Field by field, the first layer that sets a field wins.
	var out := {}
	for layer in layers:
		for name in FIELDS:
			if not out.has(name) and (layer as Dictionary).get(name) != null:
				out[name] = layer[name]
	return out


static func resolve_appearance(model: Dictionary, root_id: String, path: Array, body_id: Variant = null, face_index: Variant = null, scene_overrides: Array = []) -> Dictionary:
	## The resolved appearance of one face of the instance at `path` (occurrence path segments from `root_id`; [] = the root's own
	## bodies), as seen in `root_id`'s assembly with `scene_overrides` on top. Only the fields something sets.
	return merge_layers(resolve_layers(model, root_id, path, body_id, face_index, scene_overrides))


static func resolve_faces(model: Dictionary, root_id: String, path: Array, faces: Array, scene_overrides: Array = []) -> Dictionary:
	## resolve_appearance for many faces of one instance at once (`faces`: [[body_id, face_index], ...]) -> {"body:face": appearance}.
	## The node-level matches are found once; only body / face entries are matched per face.
	var out := {}
	var chain = instance_chain(model, root_id, path)
	if chain == null:
		for f in faces:
			out[face_key(f[0], f[1])] = {}
		return out
	var parts: Dictionary = model["parts"]
	var lists: Array = []
	if not scene_overrides.is_empty():
		lists.append([scene_overrides, path, chain.slice(1)])
	for k in chain.size():
		lists.append([effective_overrides(parts[chain[k]]), path.slice(k), chain.slice(k + 1)])
	var node_matches: Array = []
	var subshape_records: Array = []
	for l in lists:
		node_matches.append(_ordered_matches(l[0], l[1], l[2], null, null))
		subshape_records.append((l[0] as Array).filter(func(r: Dictionary) -> bool: return r.get("face") != null or r.get("body_id") != null))
	var leaf: Dictionary = parts[chain[chain.size() - 1]]
	for f in faces:
		var layers: Array = []
		for i in lists.size():
			if not (subshape_records[i] as Array).is_empty():
				layers += _ordered_matches(subshape_records[i], lists[i][1], lists[i][2], f[0], f[1])
			layers += node_matches[i]
		layers += _leaf_layers(leaf, f[0], f[1])
		out[face_key(f[0], f[1])] = merge_layers(layers)
	return out


static func face_key(body_id: Variant, face_index: Variant) -> String:
	return "%s:%d" % [str(body_id), int(face_index)]


static func same(a: Dictionary, b: Dictionary) -> bool:
	## Two appearances set the same fields to the same values (numbers compared as numbers: JSON gives floats).
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
		if (a[k] is float or a[k] is int) and (b[k] is float or b[k] is int):
			if not is_equal_approx(float(a[k]), float(b[k])):
				return false
		elif str(a[k]) != str(b[k]):
			return false
	return true


static func key_of(appearance: Dictionary) -> String:
	## A stable text key for an appearance (sorted fields), to group faces that look alike.
	var parts: PackedStringArray = []
	for name in FIELDS:
		if appearance.has(name):
			parts.append("%s=%s" % [name, str(appearance[name])])
	return ";".join(parts)
