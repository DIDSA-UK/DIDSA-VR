extends Node
## The Appearance tool (DIDSA-CAD `docs/appearance-tool-scope.md`, V2): paints colour, see-through, shine, metal and glow on a
## face, a body, a placed part, every copy of a pattern, every placement of a part, a sub-assembly or the whole assembly.
## Replaces the old Colours page and Paint gun (appearance_tool.gd), which could only set one occurrence's colour.
##
## Where paint goes (D2): painting in an assembly is an OVERRIDE in the assembly being worked in (the world's root, or a room's
## Part), never an edit of the placed parts' own files: PUT /parts/{root}/appearance-overrides with the row's target
## ({path, body_id?, face?, scope?, pattern_id?, part_id?}) and the merged appearance, or `appearance: null` to clear (Clear is a
## swatch like any other). One paint is one undo step (undo PUTs back what was there).
##
## What shows: the glb's materials on load (the backend paints them with the same rule); after that this tool restyles parts
## itself (appearance_look.gd) from its RESOLUTION MODEL, the reference's plain-dict shape (appearance_rule.gd), built from the
## backend's own lists: GET /parts/{id} (the Part's own appearance), GET /parts/{id}/appearance-overrides (faces at their
## current index) and the occurrence rows. The same model drives the breadcrumb's live preview, its swatches and the eyedropper.
##
## While mates are relaxed (the sandbox, mates_tool.gd) painting is TEMPORARY (D5): it goes into a layer on top of everything
## (`_temporary`, like a shown scene's) and nothing is sent; Return parts drops the layer and the parts show their real looks.
##
## `api`: anything with request(method, path, body) -> {ok, code, json, error} (design_table/cad_api.gd in the app, a fake in tests).

signal document_changed() ## a paint was saved: what a save would write is different
signal message(text: String) ## a one-line outcome for the wrist / status line

const Rule := preload("res://scripts/appearance/appearance_rule.gd")
const Look := preload("res://scripts/appearance/appearance_look.gd")
const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const ClipLook := preload("res://scripts/clip_look.gd")

const API_PREFIX := "/document"
const RECENT_MAX := 8
const CLEAR := {} ## the Clear swatch: painting it removes the row's own override
## Built-in saved appearances (section 2's presets; the user's own are kept in app_settings.gd's paint_saved).
const PRESETS: Array[Dictionary] = [
	{"name": "Matte plastic", "appearance": {"metallic": 0.0, "roughness": 0.9}},
	{"name": "Gloss plastic", "appearance": {"metallic": 0.0, "roughness": 0.15}},
	{"name": "Brushed metal", "appearance": {"metallic": 1.0, "roughness": 0.45}},
	{"name": "Polished metal", "appearance": {"metallic": 1.0, "roughness": 0.08}},
	{"name": "Glass", "appearance": {"opacity": 0.25, "metallic": 0.0, "roughness": 0.05}},
	{"name": "Glowing", "appearance": {"emission_strength": 2.0}},
]

var api = null
var world_root := "" ## the world's root Part (main.gd sets it on every load); a room's parts are painted in the room's Part
var settings: RefCounted = null ## app_settings.gd (recent colours, saved appearances); null in tests that don't need them
var mates_tool: Node = null ## for the sandbox (relaxed / sandbox_changed); null = never temporary
var face_highlight: Node = null ## told when a part's mesh is rebuilt
var command_stack: RefCounted = null
var local_only := false ## P4: an observer's own view (live session): there is no backend, and paint is only ever the temporary layer below (nothing is sent, nothing is saved)

## The brush: the fields a paint sets (only these; the rest show through from below). Empty = Clear.
var brush: Dictionary = {"colour": "#D94A3B"}
var eyedropper := false ## the next shot takes the appearance under the laser into the brush instead of painting

var _model: Dictionary = {"parts": {}}
var _patterns: Dictionary = {} ## Part id -> its component pattern rows (for the Pattern (all N) row)
var _names: Dictionary = {} ## Part id -> name
var _loaded: Dictionary = {} ## Part id -> true once its lists are in the model
var _local_touched: Dictionary = {} ## local_only: nodes restyled by an own paint (put back to their base look when it goes)
var _temporary: Dictionary = {} ## scope root Part id -> [override records]: the sandbox's paint (never sent)
var _preview: Dictionary = {} ## the row being previewed: {root, record, appearance (or CLEAR)}; empty = none
var _busy := false
var _inflight: Dictionary = {} ## Part id -> true while its lists are being read (V-3: a second ensure_loaded waits for it instead of starting another read)
var _versions: Dictionary = {} ## Part id -> bumped by every PUT that lands (V-3: a load that began before a PUT keeps the newer override list)
signal _load_finished


func _ready() -> void:
	if mates_tool != null and mates_tool.has_signal("sandbox_changed"):
		mates_tool.sandbox_changed.connect(_on_sandbox_changed)


func configure(p_api, p_settings: RefCounted = null) -> void:
	api = p_api
	settings = p_settings


func is_busy() -> bool:
	return _busy or not _inflight.is_empty()


func is_saving() -> bool:
	## A paint's PUT is on its way (a load running is not this: a paint awaits the load, controller.gd).
	return _busy


func is_temporary() -> bool:
	## Painting now goes into the sandbox's temporary layer (mates relaxed), not the document. An observer's own view (`local_only`) is that same layer for good.
	if local_only:
		return true
	return mates_tool != null and (mates_tool.get("relaxed") == true or mates_tool.get("relaxed_fixed") == true) # (Relax fix too: moves and paint are temporary, V-6)


func panel_title() -> String:
	if local_only:
		return "Painting · only in your view"
	return "Painting · temporary (mates relaxed)" if is_temporary() else "Painting"


# --- the model -----------------------------------------------------------------------------------------------------

func model() -> Dictionary:
	return _model


func forget() -> void:
	## The document was replaced (a load): every list is read again on next use. The sandbox's paint goes with the old parts.
	_model = {"parts": {}}
	_patterns.clear()
	_names.clear()
	_loaded.clear()
	_versions.clear()
	if not local_only:
		_temporary.clear() # (an observer's own paint is records by path, not by node: it survives the presenter's refetch and is put back on the new nodes, session_own_view.gd)
	_preview.clear()


func seed_local_model(nodes: Array, root: String) -> void:
	## An observer has no backend to read the occurrence lists from, so the model the rules need (Part ids, occurrences) is built from what the glb itself says: each
	## node's `instance_path` (a node without one, a demo's, gets a path of its own), one stand-in Part per occurrence on the way down. Each part's own Part carries the look its
	## glb materials show now (so painting one face leaves the others as the glb painted them). The rows of the paint breadcrumb and the temporary layer then work exactly as they do
	## for the sandbox; nothing is read from or sent to any server. Called for freshly loaded nodes only (a restyled node would be read as its own base).
	var parts := {root: {"occurrences": {}}}
	var index := 0
	_local_touched.clear()
	for node in nodes:
		index += 1
		if not is_instance_valid(node):
			continue
		if not (node as Node).has_meta("instance_path") and not (node as Node).has_meta("group_path"):
			(node as Node).set_meta("group_path", ["n%d" % index])
		var owner := root
		var prefix := ""
		for segment in path_of(node):
			var base := Rule.base_segment(str(segment))
			prefix = base if prefix == "" else prefix + "/" + base
			var child := "own:" + prefix
			var occurrences: Dictionary = parts[owner]["occurrences"]
			if not occurrences.has(base):
				occurrences[base] = {"part_id": child}
			if not parts.has(child):
				parts[child] = {"occurrences": {}}
			owner = child
		if node is MeshInstance3D and owner != root:
			_seed_base_look(parts[owner], node)
	_model = {"parts": parts}
	_loaded[root] = true
	world_root = root


func _seed_base_look(leaf: Dictionary, node: MeshInstance3D) -> void:
	## The part's own look = what its glb materials show: one look for the part, or (with face identity and more than one surface) one per face.
	var looks := Look.surface_looks(node)
	if looks.is_empty():
		return
	var first: Dictionary = looks[0]["appearance"]
	var triangle_keys := Look.triangle_keys(node)
	if looks.size() == 1 or triangle_keys.is_empty():
		if not first.is_empty():
			leaf["appearance"] = first
		return
	var face_appearances: Array = []
	var seen := {}
	var at := 0
	for look in looks:
		var count := int(look["triangles"])
		for t in range(at, mini(at + count, triangle_keys.size())):
			var key: String = triangle_keys[t]
			if seen.has(key) or (look["appearance"] as Dictionary).is_empty():
				continue
			seen[key] = true
			var parts_of_key := key.rsplit(":", true, 1)
			face_appearances.append({"face": {"body_id": parts_of_key[0], "index": int(parts_of_key[1])}, "appearance": look["appearance"]})
		at += count
	leaf["face_appearances"] = face_appearances
	if not first.is_empty():
		leaf["appearance"] = first


func _local_touches(node: Node, layer: Array) -> bool:
	## Whether any temporary paint record is on this node (its path is at or under the record's), or it was restyled before and so has to be restyled back.
	if _local_touched.has(node):
		return true
	var path := path_of(node)
	for record in layer:
		var record_path := Rule.split_path(str((record as Dictionary).get("path", "")))
		if record_path.size() <= path.size() and path.slice(0, record_path.size()) == record_path:
			return true
	return false


func temporary_count() -> int:
	## How many temporary paint records there are (the sandbox's, or an observer's own).
	var n := 0
	for layer in _temporary.values():
		n += (layer as Array).size()
	return n


func clear_local(nodes: Array) -> void:
	## Reset my view: every temporary paint goes, and the parts show what the glb painted.
	_temporary.clear()
	_preview.clear()
	repaint(nodes, world_root)
	_local_touched.clear()


func ensure_loaded(root_part_id: String) -> void:
	## Reads every Part under `root_part_id` into the model (a coroutine; parts already read are not read again).
	if api == null or root_part_id == "":
		return
	var queue: Array = [root_part_id]
	var seen := {}
	while not queue.is_empty():
		var pid: String = queue.pop_front()
		if seen.has(pid):
			continue
		seen[pid] = true
		if not _loaded.has(pid):
			if _inflight.has(pid):
				while _inflight.has(pid):
					await _load_finished # (V-3: the read already running for this Part is awaited, not repeated)
			else:
				await _load_part(pid)
		var entry: Dictionary = (_model["parts"] as Dictionary).get(pid, {})
		for occ in (entry.get("occurrences", {}) as Dictionary).values():
			var child := str((occ as Dictionary).get("part_id", ""))
			if child != "" and not seen.has(child):
				queue.append(child)


func _load_part(pid: String) -> void:
	_inflight[pid] = true
	var version_at_start := int(_versions.get(pid, 0))
	var entry := {"occurrences": {}}
	var part: Dictionary = await _fetch("/parts/%s" % pid)
	_names[pid] = str(part.get("name", pid))
	if part.get("appearance") is Dictionary:
		entry["appearance"] = part["appearance"]
	if part.get("body_appearances") is Dictionary and not (part["body_appearances"] as Dictionary).is_empty():
		entry["body_appearances"] = part["body_appearances"]
	var faces: Array = []
	for f in part.get("face_appearances", []):
		if f.get("current_index") == null:
			continue # can't be found on the part now: paints nothing until it is (the backend reports it)
		faces.append({"face": {"body_id": str(f["face"]["body_id"]), "index": int(f["current_index"])}, "appearance": f["appearance"]})
	if not faces.is_empty():
		entry["face_appearances"] = faces
	var rows = await _get_list("/parts/%s/occurrences" % pid)
	for row in rows:
		if bool(row.get("suppressed", false)) or row.get("resolved_part_id") == null:
			continue
		entry["occurrences"][str(row["id"])] = {"part_id": str(row["resolved_part_id"]), "color": row.get("color"), "hidden": bool(row.get("hidden", false))} # (hidden: for scenes_tool.gd)
	_set_overrides(entry, (await _fetch("/parts/%s/appearance-overrides" % pid)).get("overrides", []))
	_patterns[pid] = await _get_list("/parts/%s/component-patterns" % pid)
	if int(_versions.get(pid, 0)) != version_at_start:
		# V-3: a paint's PUT landed while this read was on its way. What the PUT returned is newer than what was read: keep its override
		# list (and the occurrence colours it mirrored) and take everything else from this read.
		var newer: Dictionary = (_model["parts"] as Dictionary).get(pid, {})
		if newer.has("appearance_overrides"):
			entry["appearance_overrides"] = newer["appearance_overrides"]
		else:
			entry.erase("appearance_overrides")
		for occ_id in (newer.get("occurrences", {}) as Dictionary):
			if (entry["occurrences"] as Dictionary).has(occ_id):
				entry["occurrences"][occ_id]["color"] = newer["occurrences"][occ_id].get("color")
		print("DIDSA VR: paint: a read of Part %s finished after a paint; kept the newer override list" % pid)
	_model["parts"][pid] = entry
	_loaded[pid] = true
	_inflight.erase(pid)
	_load_finished.emit()


static func _set_overrides(entry: Dictionary, listed: Array) -> void:
	## The backend's override list (GET / PUT response) into the model: legacy colours are already in `occurrences`, unresolved
	## ones paint nothing, and a face is matched at its current index.
	var records: Array = []
	for o in listed:
		if bool(o.get("legacy", false)) or o.get("unresolved") != null:
			continue
		records.append(_record_from_wire(o))
	if records.is_empty():
		entry.erase("appearance_overrides")
	else:
		entry["appearance_overrides"] = records


static func _record_from_wire(o: Dictionary) -> Dictionary:
	var r := {"path": str(o.get("path", "")), "appearance": o.get("appearance", {})}
	for k in ["scope", "pattern_id", "part_id", "body_id"]:
		if o.get(k) != null:
			r[k] = str(o[k])
	if o.get("face") is Dictionary:
		var index = o.get("face_current_index") if o.get("face_current_index") != null else o["face"].get("index")
		r["face"] = {"body_id": str(o["face"]["body_id"]), "shape_type": "face", "index": int(index)}
		r["body_id"] = str(o["face"]["body_id"])
	return r


func part_name(pid: String) -> String:
	return str(_names.get(pid, pid))


func patterns_of(pid: String) -> Array:
	return _patterns.get(pid, [])


func all_patterns() -> Dictionary:
	## Part id -> its component pattern rows, as far as they have been fetched (group_index.gd names pattern copies from them; no request is made for a Part not here).
	return _patterns


# --- which node is which -------------------------------------------------------------------------------------------

static func root_of(node: Node, world_root: String) -> String:
	## The assembly a node is painted in: its scope (a room's Part, or the world's root).
	if node.has_meta("group_root"):
		return str(node.get_meta("group_root"))
	if node.has_meta("room_part_id"):
		return str(node.get_meta("room_part_id")) # (a room part not indexed yet)
	return world_root


static func path_of(node: Node) -> Array:
	## The node's occurrence path from its scope root: the glb's own `instance_path` (pattern copies included), else group_index.gd's.
	if node.has_meta("instance_path"):
		return Rule.split_path(str(node.get_meta("instance_path")))
	return (node.get_meta("group_path", []) as Array).duplicate()


func leaf_of(node: Node, root: String) -> String:
	var chain = Rule.instance_chain(_model, root, path_of(node))
	return "" if chain == null else str(chain[chain.size() - 1])


# --- what shows ----------------------------------------------------------------------------------------------------

func layer_for(root: String) -> Array:
	## What sits on top of the document for parts painted in `root`: the sandbox's temporary paint, and a previewed row.
	var layer: Array = (_temporary.get(root, []) as Array).duplicate()
	if not _preview.is_empty() and _preview["root"] == root and _preview["temporary"]:
		layer = _with_record(layer, _preview["record"], _preview["appearance"])
	return layer


func _model_for(root: String) -> Dictionary:
	## The model with a previewed (real, not temporary) row applied in `root`'s own list.
	if _preview.is_empty() or _preview["root"] != root or _preview["temporary"]:
		return _model
	var m := _model.duplicate(true)
	var entry: Dictionary = m["parts"].get(root, {})
	entry["appearance_overrides"] = _with_record(entry.get("appearance_overrides", []), _preview["record"], _preview["appearance"])
	m["parts"][root] = entry
	return m


static func _with_record(records: Array, target: Dictionary, appearance: Dictionary) -> Array:
	## `records` with `target`'s key set to `appearance` (merged into what is there), or removed for CLEAR.
	var key := str(Rule.override_key(target))
	var out: Array = []
	var merged := {}
	for r in records:
		if str(Rule.override_key(r)) == key:
			merged = (r["appearance"] as Dictionary).duplicate()
		else:
			out.append(r)
	if not appearance.is_empty():
		for k in appearance:
			merged[k] = appearance[k]
		var rec := target.duplicate(true)
		rec["appearance"] = merged
		out.append(rec)
	return out


func resolved_at(node: Node, world_root: String, body_id: Variant = null, face_index: Variant = null) -> Dictionary:
	## What a face (or, with no body, the node as a whole) shows now, preview and sandbox included.
	var root := root_of(node, world_root)
	return Rule.resolve_appearance(_model_for(root), root, path_of(node), body_id, face_index, layer_for(root))


func repaint(nodes: Array, world_root: String) -> int:
	## Restyles `nodes` from the model (and the layers on top). Returns how many meshes had to be rebuilt.
	var rebuilt := 0
	for node in nodes:
		if not is_instance_valid(node) or not (node is MeshInstance3D):
			continue
		var root := root_of(node, world_root)
		var path := path_of(node)
		var m := _model_for(root)
		var layer := layer_for(root)
		if Rule.instance_chain(m, root, path) == null:
			continue # not in the model (yet): keep what the glb painted
		if local_only and not _local_touches(node, layer):
			continue # an observer's view: only a part the own paint is on is restyled; every other part keeps its glb materials as they are
		var whole := Rule.resolve_appearance(m, root, path, null, null, layer)
		var by_face := Rule.resolve_faces(m, root, path, Look.faces_of(node), layer)
		if local_only:
			_local_touched[node] = true
		if Look.restyle(node, by_face, whole):
			rebuilt += 1
			if face_highlight != null and face_highlight.has_method("invalidate"):
				face_highlight.invalidate(node)
	return rebuilt


# --- the rows of the paint breadcrumb (D1) ------------------------------------------------------------------------

func rows_for(node: Node, face_index: int, scope: Array, world_root: String) -> Array:
	## What a hold on `node` (the triangle `face_index` under the laser) offers, innermost first:
	## [{id, label, record, members, set_here, swatch}]. record is the override's target (no appearance).
	## Face, Body, Part, Pattern (all N) for a pattern copy or source, Every <part> (N) when placed more than once, each
	## sub-assembly it sits in, and Whole assembly. The root's own bodies have no Part row (painting the part there is the assembly).
	var root := root_of(node, world_root)
	var path := path_of(node)
	var path_text := "/".join(PackedStringArray(path.map(func(x) -> String: return str(x))))
	var ref := MeshIdentity.subshape_ref_for_hit(node, face_index)
	var mine := scope.filter(func(n) -> bool: return is_instance_valid(n) and root_of(n, world_root) == root and int(n.get_meta("room_id", 0)) == int(node.get_meta("room_id", 0)))
	var names: Array = node.get_meta("group_names", [])
	var rows: Array = []
	if not ref.is_empty():
		var body_id := str(ref["body_id"])
		rows.append({"id": "face", "label": "Face", "members": [node],
			"record": {"path": path_text, "body_id": body_id, "face": {"body_id": body_id, "shape_type": "face", "index": int(ref["index"])}}})
		rows.append({"id": "body", "label": "Body", "members": [node], "record": {"path": path_text, "body_id": body_id}})
	if not path.is_empty():
		rows.append({"id": "part", "label": "Part · %s" % (str(names[names.size() - 1]) if not names.is_empty() else str(node.name)),
			"members": [node], "record": {"path": path_text}})
		rows += _pattern_rows(node, path, mine, root)
		var leaf := leaf_of(node, root)
		if leaf != "":
			var placements := mine.filter(func(n) -> bool: return not path_of(n).is_empty() and leaf_of(n, root) == leaf)
			if placements.size() > 1:
				rows.append({"id": "same_part", "label": "Every %s (%d)" % [part_name(leaf), placements.size()], "members": placements,
					"record": {"path": "", "scope": Rule.SCOPE_SAME_PART, "part_id": leaf}})
		for d in range(path.size() - 1, 0, -1):
			var prefix := path.slice(0, d)
			var members := mine.filter(func(n) -> bool: return _starts_with(path_of(n), prefix))
			var label := str(names[d - 1]) if d - 1 < names.size() else "Sub-assembly"
			rows.append({"id": "sub_%d" % d, "label": "%s (%d parts)" % [label, members.size()], "members": members,
				"record": {"path": "/".join(PackedStringArray(prefix.map(func(x) -> String: return str(x))))}})
	rows.append({"id": "whole", "label": "Whole assembly", "members": mine, "record": {"path": ""}})
	var list: Array = _real_or_temporary_list(root)
	for row in rows:
		var key := str(Rule.override_key(row["record"]))
		var own: Variant = null
		for r in list:
			if str(Rule.override_key(r)) == key:
				own = r["appearance"]
		row["set_here"] = own != null
		row["swatch"] = own if own != null else resolved_at(node, world_root, str(ref.get("body_id")) if not ref.is_empty() else null, int(ref.get("index", 0)) if not ref.is_empty() else null)
	return rows


func _real_or_temporary_list(root: String) -> Array:
	var real: Array = ((_model["parts"] as Dictionary).get(root, {}) as Dictionary).get("appearance_overrides", [])
	return real + (_temporary.get(root, []) as Array) if is_temporary() else real


func _pattern_rows(node: Node, path: Array, mine: Array, root: String) -> Array:
	## Pattern (all N): the node's last segment is a pattern copy, or the source of a pattern of the Part that places it.
	var out: Array = []
	var last := str(path[path.size() - 1])
	var source := Rule.base_segment(last)
	var chain = Rule.instance_chain(_model, root, path)
	if chain == null:
		return out
	var owner := str(chain[chain.size() - 2])
	var prefix := path.slice(0, path.size() - 1)
	for pattern in patterns_of(owner):
		if bool(pattern.get("suppressed", false)) or not (pattern.get("source_occurrence_ids", []) as Array).has(source):
			continue
		var pid := str(pattern["id"])
		if last != source and not last.begins_with("%s%s%s:" % [source, Rule.PATTERN_SEGMENT, pid]):
			continue
		var copies := {}
		var members: Array = []
		for n in mine:
			var p := path_of(n)
			if p.size() < path.size() or p.slice(0, prefix.size()) != prefix:
				continue
			var seg := str(p[prefix.size()])
			if seg == source or seg.begins_with("%s%s%s:" % [source, Rule.PATTERN_SEGMENT, pid]):
				copies[seg] = true
				members.append(n)
		out.append({"id": "pattern_%s" % pid, "label": "Pattern (all %d)" % copies.size(), "members": members,
			"record": {"path": "/".join(PackedStringArray((prefix + [source]).map(func(x) -> String: return str(x)))), "scope": Rule.SCOPE_PATTERN, "pattern_id": pid}})
	return out


static func _starts_with(path: Array, prefix: Array) -> bool:
	return path.size() >= prefix.size() and path.slice(0, prefix.size()) == prefix


# --- preview, apply, undo ------------------------------------------------------------------------------------------

func preview(row: Dictionary, root: String, nodes: Array, world_root: String) -> void:
	## Shows what releasing on `row` with the brush would do (live, nothing sent). `nodes`: what to restyle (the scope).
	_preview = {"root": root, "record": row["record"], "appearance": brush.duplicate(), "temporary": is_temporary()}
	repaint(nodes, world_root)


func end_preview(nodes: Array, world_root: String) -> void:
	if _preview.is_empty():
		return
	_preview.clear()
	repaint(nodes, world_root)


func apply(row: Dictionary, root: String, nodes: Array, world_root: String) -> Dictionary:
	## Paints `row` with the brush (CLEAR removes the row's own override). One undo step. {ok, error}. A coroutine.
	_preview.clear()
	var record: Dictionary = row["record"]
	var before: Variant = _own_appearance(root, record)
	var after: Variant = null
	if not brush.is_empty():
		after = (before if before != null else {}).duplicate()
		for k in brush:
			after[k] = brush[k]
	var loading := not _inflight.is_empty()
	var result: Dictionary = await _store(root, record, after, nodes, world_root)
	if loading and result["ok"]:
		# V-3: the nodes were not in the model yet when the paint landed (the read was still running), so repaint() left them as the glb had them. Once
		# the read is in (it keeps this paint's override list), show the paint.
		await ensure_loaded(root)
		repaint(nodes, world_root)
	_log_paint(row, root, result, loading, nodes)
	if not result["ok"]:
		return result
	_remember_colour(str(brush.get("colour", "")))
	var temporary: bool = result["temporary"]
	if command_stack != null:
		command_stack.push("paint %s" % str(row.get("label", "")),
			func() -> void: _store(root, record, before, nodes, world_root),
			func() -> void: _store(root, record, after, nodes, world_root),
			not temporary)
	var verb := "Cleared" if after == null else "Painted"
	var where := ""
	if temporary:
		where = " (only in your view)" if local_only else " (temporary: mates relaxed)"
	message.emit("%s %s%s." % [verb, str(row.get("label", "")), where])
	return result


func _log_paint(row: Dictionary, root: String, result: Dictionary, loading_at_start: bool, nodes: Array) -> void:
	## V-3: one line per paint for `adb logcat` (filter "DIDSA VR: paint"), so one reproduction names the cause of "the paint shows nothing until the
	## next one": the row, the scope, temporary or not, whether the PUT worked, how many overrides came back, how many meshes were rebuilt, the colour the
	## first painted node wears afterwards, whether a clip (room / section) shader was on it, and whether a read was running.
	var members: Array = row.get("members", [])
	var node = members[0] if not members.is_empty() else null
	var colour := "-"
	var clip := false
	if node is MeshInstance3D and is_instance_valid(node):
		var m: Material = node.material_override
		if m == null and node.mesh != null and node.mesh.get_surface_count() > 0:
			m = node.get_surface_override_material(0) if node.get_surface_override_material(0) != null else node.mesh.surface_get_material(0)
		clip = ClipLook.is_clip(m)
		if m is BaseMaterial3D:
			colour = (m as BaseMaterial3D).albedo_color.to_html()
		elif m is ShaderMaterial:
			var c = (m as ShaderMaterial).get_shader_parameter("albedo_color")
			colour = (c as Color).to_html() if c is Color else "-"
	print("DIDSA VR: paint: row=%s root=%s temporary=%s ok=%s overrides=%s rebuilt=%s colour_after=%s clip=%s load_running_at_start=%s load_running_now=%s nodes=%d error=%s" % [
		str(row.get("id", "")), root, str(result.get("temporary", false)), str(result.get("ok", false)), str(result.get("overrides", "-")),
		str(result.get("rebuilt", "-")), colour, str(clip), str(loading_at_start), str(not _inflight.is_empty()), nodes.size(), str(result.get("error", ""))])


func _own_appearance(root: String, record: Dictionary) -> Variant:
	var key := str(Rule.override_key(record))
	for r in _real_or_temporary_list(root):
		if str(Rule.override_key(r)) == key:
			return (r["appearance"] as Dictionary).duplicate()
	return null


func _store(root: String, record: Dictionary, appearance: Variant, nodes: Array, world_root: String) -> Dictionary:
	## Sets the row's own override to `appearance` (null clears) - in the sandbox's layer while relaxed, else on the backend.
	if is_temporary():
		var layer: Array = (_temporary.get(root, []) as Array).filter(func(r) -> bool: return str(Rule.override_key(r)) != str(Rule.override_key(record)))
		if appearance != null:
			var rec := record.duplicate(true)
			rec["appearance"] = appearance
			layer.append(rec)
		_temporary[root] = layer
		repaint(nodes, world_root)
		return {"ok": true, "error": "", "temporary": true}
	if api == null:
		return {"ok": false, "error": "no backend configured", "temporary": false}
	var body := record.duplicate(true)
	body["appearance"] = appearance
	if body.has("face"):
		var face: Dictionary = body["face"]
		face["index"] = int(face["index"])
	_busy = true
	var r: Dictionary = await api.request(HTTPClient.METHOD_PUT, API_PREFIX + "/parts/%s/appearance-overrides" % root, body)
	_busy = false
	if not r.get("ok", false):
		return {"ok": false, "error": str(r.get("error", "the backend refused the paint")), "temporary": false}
	_versions[root] = int(_versions.get(root, 0)) + 1
	var entry: Dictionary = (_model["parts"] as Dictionary).get(root, {"occurrences": {}})
	var listed: Array = (r["json"] as Dictionary).get("overrides", []) if r.get("json") is Dictionary else []
	_set_overrides(entry, listed)
	_mirror_legacy(entry, record, appearance)
	_model["parts"][root] = entry
	var rebuilt := repaint(nodes, world_root)
	document_changed.emit()
	return {"ok": true, "error": "", "temporary": false, "overrides": listed.size(), "rebuilt": rebuilt}


static func _mirror_legacy(entry: Dictionary, record: Dictionary, appearance: Variant) -> void:
	## The backend mirrors a top-level occurrence's own colour into Occurrence.color (and clears it with the override): the
	## model's copy of the occurrence follows, so the legacy alias doesn't resurrect a cleared colour.
	var path := str(record.get("path", ""))
	if path == "" or path.contains("/") or path.contains("#") or record.size() != 1:
		return
	var occ: Dictionary = (entry.get("occurrences", {}) as Dictionary).get(path, {})
	if occ.is_empty():
		return
	if appearance == null:
		occ["color"] = null
	elif (appearance as Dictionary).has("colour"):
		occ["color"] = appearance["colour"]


func _on_sandbox_changed(on: bool) -> void:
	if not on and not _temporary.is_empty():
		var roots := _temporary.keys()
		_temporary.clear()
		var nodes := get_tree().get_nodes_in_group("grabbable_parts") if is_inside_tree() else []
		for r in roots:
			repaint(nodes, str(r))
		message.emit("Temporary paint went back with the parts.")


# --- the eyedropper, recent colours, saved appearances ------------------------------------------------------------

func take_from(node: Node, face_index: int, world_root: String) -> Dictionary:
	## Eyedropper: the brush becomes everything the face under the laser shows (all fields). Returns the new brush.
	var ref := MeshIdentity.subshape_ref_for_hit(node, face_index)
	var got := resolved_at(node, world_root, ref.get("body_id"), ref.get("index"))
	brush = got.duplicate() if not got.is_empty() else {"colour": "#C8C8C8"}
	eyedropper = false
	return brush


func recent_colours() -> Array:
	return settings.paint_recent.duplicate() if settings != null else []


func _remember_colour(hex: String) -> void:
	if settings == null or not Rule.is_hex(hex):
		return
	var list: Array = settings.paint_recent.filter(func(c) -> bool: return str(c).to_upper() != hex.to_upper())
	list.push_front(hex.to_upper())
	settings.set_paint_recent(list.slice(0, RECENT_MAX))


func saved_appearances() -> Array:
	## The presets, then the user's own.
	var out: Array = PRESETS.duplicate(true)
	if settings != null:
		out += settings.paint_saved.duplicate(true)
	return out


func save_brush(name_: String) -> void:
	if settings == null or brush.is_empty():
		return
	var list: Array = settings.paint_saved.duplicate(true)
	list.append({"name": name_, "appearance": brush.duplicate()})
	settings.set_paint_saved(list)


# --- requests ------------------------------------------------------------------------------------------------------

func _fetch(path: String) -> Dictionary:
	var r: Dictionary = await api.request(HTTPClient.METHOD_GET, API_PREFIX + path, null)
	return r["json"] if r.get("ok", false) and r.get("json") is Dictionary else {}


func _get_list(path: String) -> Array:
	var r: Dictionary = await api.request(HTTPClient.METHOD_GET, API_PREFIX + path, null)
	return r["json"] if r.get("ok", false) and r.get("json") is Array else []
