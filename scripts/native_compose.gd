extends RefCounted
## Multi-file native assemblies: folds every file a native file references (an Occurrence's `external_ref`, a path
## relative to the project folder) into one payload for POST /document/import/native or add-component. A port of the
## flat app's AssemblyGraphComposer (DIDSA-CAD client/lib/assembly/assembly_graph_composer.dart): the backend has no
## filesystem of its own, so resolving the references is the client's job, and without it an assembly opened here
## showed its root and none of its parts.
##
## A reference written under one native extension still finds the file under another (`Frame_A.DIDSAprt` written
## before the move to `.didsa`, or the other way round), and in any letter case: the exact name wins, then any file
## in the same folder with the same name once the extension is set aside (relative_path.dart's nativePathAlternatives
## and nativeBaseNameKey). The name the file was found under is written back onto the Occurrence, as the flat app does.
##
## Where a reference is looked for, in order: the folder of the file being opened, then `search_dirs` (the project
## folder and the models folders). A reference that can't be found, would close a cycle, holds more than one Part or
## reuses another file's Part id is left as it was (the backend skips an unresolved Occurrence) and listed in
## `unresolved`, so the caller can say so. The flat app re-mints a clashing id; that is not ported.
##
## Godot's JSON parser reads every number as a float, and JSON.stringify writes 0 back as 0.0, which the backend
## refuses for its integer fields. So when nothing needs resolving the file's own text is returned untouched, and
## otherwise to_json() writes whole numbers without a fraction.

const NATIVE_EXTENSIONS: Array[String] = ["didsa", "DIDSAprt", "didsacad"] ## current first (relative_path.dart)


static func native_extension(path: String) -> String:
	## The native extension `path` ends with ("didsa", "DIDSAprt", "didsacad", as spelled here), or "" for none.
	var lower := path.strip_edges().to_lower()
	for ext in NATIVE_EXTENSIONS:
		if lower.ends_with("." + ext.to_lower()):
			return ext
	return ""


static func base_name_key(path: String) -> String:
	## `path` lower-cased with any native extension removed: `Bracket.didsa` and `bracket.DIDSAprt` compare equal.
	var trimmed := path.strip_edges()
	var ext := native_extension(trimmed)
	if ext != "":
		trimmed = trimmed.substr(0, trimmed.length() - ext.length() - 1)
	return trimmed.to_lower()


static func find_file(ref: String, bases: Array) -> String:
	## The file `ref` names, looked for under each of `bases` in turn: the exact name first, then a native file in the
	## same folder with the same base name (another extension, another case). "" if none.
	if ref.strip_edges() == "":
		return ""
	var clean := ref.strip_edges().replace("\\", "/")
	if clean.begins_with("/") or ".." in clean.split("/"):
		return "" # an external_ref is relative to the project folder and never walks out of it
	for base in bases:
		var exact: String = (base as String).path_join(clean)
		if FileAccess.file_exists(exact):
			return exact
	if native_extension(clean) == "":
		return ""
	var key := base_name_key(clean.get_file())
	for base in bases:
		var folder: String = (base as String).path_join(clean.get_base_dir()) if clean.get_base_dir() != "" else base
		var dir := DirAccess.open(folder)
		if dir == null:
			continue
		for name in dir.get_files():
			if native_extension(name) != "" and base_name_key(name) == key:
				return folder.path_join(name)
	return ""


static func compose(root_path: String, search_dirs: Array = []) -> Dictionary:
	## {ok, text, root_part_id, parsed (the root file as read), resolved: int, unresolved: [String], error}.
	## `text` is ready to POST. With nothing to resolve it is the root file's own text, unchanged.
	var out := {"ok": false, "text": "", "root_part_id": "", "parsed": null, "resolved": 0, "unresolved": [], "error": ""}
	if not FileAccess.file_exists(root_path):
		out["error"] = "No such file: %s" % root_path
		return out
	var root_text := FileAccess.get_file_as_string(root_path)
	var root = JSON.parse_string(root_text)
	if not (root is Dictionary) or not ((root as Dictionary).get("document") is Dictionary):
		out["error"] = "Couldn't parse %s as JSON — is it a real exported .didsa/.DIDSAprt file?" % root_path.get_file()
		return out
	out["parsed"] = root
	var document: Dictionary = root["document"]
	out["root_part_id"] = str(document.get("root_part_id", "")) if document.get("root_part_id") != null else ""
	var root_parts: Array = document.get("parts", []) if document.get("parts") is Array else []
	if not _has_external_refs(root_parts):
		out["ok"] = true
		out["text"] = root_text
		return out

	var bases: Array = [root_path.get_base_dir()]
	for d in search_dirs:
		if str(d) != "" and not (str(d) in bases):
			bases.append(str(d))
	var state := {
		"parts": [], # every Part in the payload, root file's first
		"part_ids": {}, # part id -> the file it came from
		"by_file": {}, # resolved file -> its Part id
		"sketches": {}, # sketch id -> sketch
		"sketch_order": [],
		"unresolved": [],
		"resolved": 0,
		"bases": bases,
	}
	for part in root_parts:
		if part is Dictionary:
			state["parts"].append(part)
			state["part_ids"][str(part.get("id", ""))] = root_path
	state["by_file"][root_path] = out["root_part_id"]
	_add_sketches(state, root)
	for part in root_parts:
		if part is Dictionary:
			_resolve_occurrences(state, part, [root_path])

	var composed := {}
	for key in root:
		if key != "document" and key != "sketches":
			composed[key] = root[key] # schema_version and the client-only extras ride along as they were
	var doc_out := document.duplicate()
	doc_out["parts"] = state["parts"]
	composed["document"] = doc_out
	var sketches := []
	for id in state["sketch_order"]:
		sketches.append(state["sketches"][id])
	composed["sketches"] = sketches
	out["ok"] = true
	out["text"] = to_json(composed)
	out["resolved"] = state["resolved"]
	out["unresolved"] = state["unresolved"]
	return out


static func unresolved_note(composed: Dictionary) -> String:
	## " N referenced files not loaded: ..." for a status line, or "".
	var missing: Array = composed.get("unresolved", [])
	if missing.is_empty():
		return ""
	return " %d referenced file%s not loaded: %s." % [missing.size(), "" if missing.size() == 1 else "s", ", ".join(PackedStringArray(missing))]


static func _has_external_refs(parts: Array) -> bool:
	for part in parts:
		if not (part is Dictionary):
			continue
		for occ in (part.get("occurrences", []) if part.get("occurrences") is Array else []):
			if occ is Dictionary and occ.get("external_ref") != null and str(occ["external_ref"]) != "":
				return true
	return false


static func _add_sketches(state: Dictionary, payload: Dictionary) -> void:
	for sketch in (payload.get("sketches", []) if payload.get("sketches") is Array else []):
		if sketch is Dictionary:
			var id := str(sketch.get("id", ""))
			if not state["sketches"].has(id):
				state["sketch_order"].append(id)
			state["sketches"][id] = sketch


static func _resolve_occurrences(state: Dictionary, part: Dictionary, ancestors: Array) -> void:
	for occ in (part.get("occurrences", []) if part.get("occurrences") is Array else []):
		if not (occ is Dictionary) or occ.get("external_ref") == null or str(occ["external_ref"]) == "":
			continue
		var ref := str(occ["external_ref"])
		var file := find_file(ref, state["bases"])
		var part_id := _resolve_file(state, file, ref, ancestors)
		if part_id == "":
			continue
		occ["resolved_part_id"] = part_id
		occ["external_ref"] = _ref_as_found(ref, file)
		state["resolved"] += 1


static func _resolve_file(state: Dictionary, file: String, ref: String, ancestors: Array) -> String:
	## The Part id `file` contributes to the payload (reading and folding it in the first time), or "" (noted in unresolved).
	if file == "":
		state["unresolved"].append("%s (not found)" % ref)
		return ""
	if file in ancestors:
		state["unresolved"].append("%s (refers back to itself)" % ref)
		return ""
	if state["by_file"].has(file):
		return state["by_file"][file] # the same file from two places: one Part
	var payload = JSON.parse_string(FileAccess.get_file_as_string(file))
	var parts: Array = []
	if payload is Dictionary and (payload as Dictionary).get("document") is Dictionary and payload["document"].get("parts") is Array:
		parts = payload["document"]["parts"]
	if parts.size() != 1 or not (parts[0] is Dictionary):
		state["unresolved"].append("%s (not a single-part native file)" % ref)
		return ""
	var part: Dictionary = parts[0]
	var part_id := str(part.get("id", ""))
	if part_id == "" or state["part_ids"].has(part_id):
		state["unresolved"].append("%s (its part id is already used by %s)" % [ref, str(state["part_ids"].get(part_id, "another file")).get_file()])
		return ""
	state["by_file"][file] = part_id
	state["part_ids"][part_id] = file
	state["parts"].append(part)
	_add_sketches(state, payload)
	_resolve_occurrences(state, part, ancestors + [file])
	return part_id


static func _ref_as_found(ref: String, file: String) -> String:
	## `ref` with its file name swapped for the one the file was actually found under (its folder part unchanged).
	var clean := ref.strip_edges().replace("\\", "/")
	var folder := clean.get_base_dir()
	return folder.path_join(file.get_file()) if folder != "" else file.get_file()


static func to_json(value) -> String:
	## JSON with whole-number floats written as integers (Godot reads every JSON number as a float; the backend's
	## integer fields refuse 0.0). Other floats keep full precision.
	match typeof(value):
		TYPE_DICTIONARY:
			var pieces := PackedStringArray()
			for key in value:
				pieces.append("%s:%s" % [JSON.stringify(str(key)), to_json(value[key])])
			return "{" + ",".join(pieces) + "}"
		TYPE_ARRAY:
			var items := PackedStringArray()
			for item in value:
				items.append(to_json(item))
			return "[" + ",".join(items) + "]"
		TYPE_FLOAT:
			var f: float = value
			if is_finite(f) and f == floorf(f) and absf(f) < 1e15:
				return str(int(f))
			return JSON.stringify(f, "", false, true)
		_:
			return JSON.stringify(value)
