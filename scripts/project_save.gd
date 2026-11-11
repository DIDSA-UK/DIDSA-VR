extends RefCounted
## V-9: saving like the flat app: ONE FILE PER PART, in place (docs/vr-feedback-2026-11-11-plan.md; the flat app's `AssemblyDocumentClient.saveAll`,
## `save_all.dart`, DIDSA-CAD `docs/save-project-overhaul-scope.md`), instead of one whole-session snapshot in a new file. Pure file logic with the backend behind a
## Callable, so tests can drive it with a fake backend and a temp folder; `main.gd` supplies the HTTP and the status line.
##
## What it keeps: `files`, part id -> {path, fingerprint, mtime} for every Part that came from (or was written to) a file. `register_composed()` fills it from
## `native_compose.gd`'s `part_files` when a file is opened.
##
## Save (`save()`):
##  1. every Part's own native text (`GET /export/native?part_id=<id>`, written EXACTLY as the backend wrote it: no number is re-written, the float trap), its
##     occurrences' `external_ref` stamped with the referenced Part's path RELATIVE TO THE ROOT FILE'S FOLDER (the code's rule: native_compose.gd resolves a reference
##     against the root's folder, and the flat app stamps project-root-relative paths; the plan's "relative to that file's folder" is the same thing while every file
##     is in one folder) and `ref_part_id` set to the Part's id; the root file also gets the loaded file's client-only extras back;
##  2. children are written before their parents (`placed_first`), each to a temp file then renamed: never a half-written file;
##  3. a Part whose new text equals its file (compared as canonical JSON: sorted keys, 0 == 0.0) is NOT written: no dirty tracking needed;
##  4. a Part with no file yet gets `<its name>.didsa`, unique in the folder (next to the root file); the demos (res://) and a session with no file save there too;
##  5. a file that CHANGED ON DISK since it was read or last written (its modified time moved) is not overwritten unless the policy says so ("overwrite" /
##     "copy": written beside it as "<name> (copy).didsa" / "skip"); the default "ask" reports them and writes nothing for them.
## The result says what happened per Part: {saved, unchanged, conflicts, failed, copies}.

const NativeCompose := preload("res://scripts/native_compose.gd")

var files: Dictionary = {} ## part id -> {"path": String, "fingerprint": String, "mtime": int}


# --- pure helpers ----------------------------------------------------------------------------------------------------------------------

static func canonical(text: String) -> String:
	## Sorted-keys JSON of `text`, for "is this the same file content": formatting, key order and 0 vs 0.0 don't count. "" if it isn't JSON.
	var parsed = JSON.parse_string(text)
	return "" if parsed == null else JSON.stringify(parsed, "", true)


static func fingerprint(text: String) -> String:
	var c := canonical(text)
	return c.md5_text() if c != "" else ""


static func relative_path(from_folder: String, to_file: String) -> String:
	## `to_file` as a path relative to `from_folder` ("Bracket.didsa", "parts/Bolt.didsa", "../shared/Nut.didsa"), '/' separators.
	var base := from_folder.replace("\\", "/").rstrip("/").split("/", false)
	var target := to_file.replace("\\", "/").split("/", false)
	var lead := ("/" if to_file.replace("\\", "/").begins_with("/") else "")
	var i := 0
	while i < base.size() and i < target.size() - 1 and base[i] == target[i]:
		i += 1
	var parts: PackedStringArray = []
	for _k in range(i, base.size()):
		parts.append("..")
	for k in range(i, target.size()):
		parts.append(target[k])
	var out := "/".join(parts)
	return out if i > 0 or lead == "" else to_file.replace("\\", "/") # (no common folder on an absolute path: keep it absolute)


static func placed_first(part_ids: Array, parts: Array) -> Array:
	## `part_ids` ordered so that a Part comes after every Part its occurrences place (children first); Parts that don't place each other keep their order.
	var placed := {}
	for part in parts:
		if part is Dictionary:
			var kids: Array = []
			for occ in (part.get("occurrences", []) if part.get("occurrences") is Array else []):
				if occ is Dictionary and occ.get("resolved_part_id") != null and str(occ["resolved_part_id"]) != "":
					kids.append(str(occ["resolved_part_id"]))
			placed[str(part.get("id", ""))] = kids
	var wanted := {}
	for id in part_ids:
		wanted[str(id)] = true
	var ordered: Array = []
	var visited := {}
	for id in part_ids:
		_visit(str(id), placed, wanted, visited, ordered)
	return ordered


static func _visit(id: String, placed: Dictionary, wanted: Dictionary, visited: Dictionary, ordered: Array) -> void:
	if visited.has(id):
		return
	visited[id] = true
	for kid in placed.get(id, []):
		_visit(str(kid), placed, wanted, visited, ordered)
	if wanted.has(id):
		ordered.append(id)


static func safe_name(name: String, fallback: String = "Part") -> String:
	var cleaned := name
	for bad in ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]:
		cleaned = cleaned.replace(bad, "_")
	cleaned = cleaned.strip_edges().rstrip(".").strip_edges()
	return cleaned.substr(0, 80).strip_edges() if cleaned != "" else fallback


static func auto_path(folder: String, name: String, taken: Dictionary) -> String:
	## `<folder>/<name>.didsa`, made unique against `taken` (lower-case full path -> true, which it is added to) and against what is on disk.
	var base := safe_name(name)
	var candidate := folder.path_join("%s.didsa" % base)
	var counter := 2
	while taken.has(candidate.to_lower()) or FileAccess.file_exists(candidate):
		candidate = folder.path_join("%s %d.didsa" % [base, counter])
		counter += 1
	taken[candidate.to_lower()] = true
	return candidate


static func stamp(text: String, root_folder: String, path_of: Dictionary) -> String:
	## `text` (one Part's native file) with every occurrence whose `resolved_part_id` has a path in `path_of` (part id -> file path) given that path, relative to
	## `root_folder`, as its `external_ref`, and `ref_part_id` set. The numbers are written back exactly (native_compose.gd parse_exact / to_json). "" if `text`
	## isn't a native object.
	var parsed = NativeCompose.parse_exact(text)
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("document") is Dictionary):
		return ""
	for part in ((parsed as Dictionary)["document"] as Dictionary).get("parts", []):
		if not (part is Dictionary):
			continue
		for occ in (part.get("occurrences", []) if part.get("occurrences") is Array else []):
			if not (occ is Dictionary) or occ.get("resolved_part_id") == null:
				continue
			var target := str(occ["resolved_part_id"])
			if path_of.has(target):
				occ["external_ref"] = relative_path(root_folder, str(path_of[target]))
				occ["ref_part_id"] = target
	return NativeCompose.to_json(parsed)


static func append_extras(text: String, extras: Dictionary) -> String:
	## `text` (a JSON object) with `extras` added as further top-level keys, on the TEXT (the numbers stay as written). "" if it isn't an object.
	var trimmed := text.strip_edges()
	if extras.is_empty():
		return trimmed
	if not trimmed.ends_with("}"):
		return ""
	var body := trimmed.substr(0, trimmed.length() - 1).strip_edges()
	var pieces: PackedStringArray = []
	for key in extras:
		pieces.append("%s: %s" % [JSON.stringify(str(key)), JSON.stringify(extras[key])])
	return "%s%s%s}" % [body, "" if body.ends_with("{") else ", ", ", ".join(pieces)]


static func write_atomic(path: String, text: String) -> String:
	## Writes `text` to a temp file beside `path`, then renames it over `path`. "" on success, else why not.
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var made := DirAccess.make_dir_recursive_absolute(dir)
		if made != OK:
			return "couldn't make the folder %s (error %d)" % [dir, made]
	var temp := path + ".saving"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return "couldn't write %s (error %d)" % [path.get_file(), FileAccess.get_open_error()]
	file.store_string(text)
	file.close()
	var renamed := DirAccess.rename_absolute(temp, path)
	if renamed != OK:
		DirAccess.remove_absolute(temp)
		return "couldn't replace %s (error %d)" % [path.get_file(), renamed]
	return ""


# --- the files this session knows ------------------------------------------------------------------------------------------------------

func register_composed(part_files: Dictionary) -> void:
	## `part_files`: part id -> the file it was read from (native_compose.gd's compose() output). Remembers each file's content fingerprint and modified time as
	## read, which is what a later save compares against.
	files.clear()
	for part_id in part_files:
		var path := str(part_files[part_id])
		if path == "" or not FileAccess.file_exists(path) or path.begins_with("res://"):
			continue
		files[str(part_id)] = {"path": path, "fingerprint": fingerprint(FileAccess.get_file_as_string(path)), "mtime": FileAccess.get_modified_time(path)}


func clear() -> void:
	files.clear()


func path_of(part_id: String) -> String:
	return str(files.get(part_id, {}).get("path", ""))


# --- save ------------------------------------------------------------------------------------------------------------------------------

func save(session: Dictionary, fetch: Callable, folder: String, root_path: String, extras: Dictionary = {}, policy: String = "ask") -> Dictionary:
	## `session`: {"root_part_id": String, "parts": [{id, name, occurrences: [{resolved_part_id}]}]} (the full session's export); `fetch(part_id) -> String` a coroutine
	## returning that Part's own native text ("" = failed); `folder`: where new files go; `root_path`: the file the session came from (the folder refs are relative
	## to; "" = `folder`); `extras`: the root file's client-only keys. `policy`: what to do with a file changed on disk since it was read: "ask" (report, write
	## nothing), "overwrite", "copy" (beside it as "<name> (copy).didsa") or "skip". Returns {saved: [{id, name, path}], unchanged: [names], conflicts:
	## [{id, name, path}], failed: [{id, name, path, reason}], copies: [{id, name, path}]}. A coroutine.
	var result := {"saved": [], "unchanged": [], "conflicts": [], "failed": [], "copies": []}
	var parts: Array = session.get("parts", [])
	var root_id := str(session.get("root_part_id", ""))
	var root_folder := root_path.get_base_dir() if root_path != "" and not root_path.begins_with("res://") else folder
	var names := {}
	for part in parts:
		names[str(part.get("id", ""))] = str(part.get("name", "Part"))
	# 1. every Part's file path: its own, or a new one named after it (the demos' res:// files are read-only: those Parts get new files too)
	var taken := {}
	var path_for := {}
	for id in names:
		if files.has(id):
			path_for[id] = str(files[id]["path"])
			taken[str(files[id]["path"]).to_lower()] = true
	for id in names:
		if not path_for.has(id):
			path_for[id] = auto_path(folder, names[id], taken)
	# 2. children first
	for id in placed_first(names.keys(), parts):
		var name: String = names[id]
		var path: String = path_for[id]
		var raw: String = await fetch.call(id)
		if raw == "":
			result["failed"].append({"id": id, "name": name, "path": path, "reason": "the backend didn't send it"})
			continue
		var stamped := stamp(raw, root_folder, path_for)
		if stamped == "":
			result["failed"].append({"id": id, "name": name, "path": path, "reason": "its file wasn't in the shape expected"})
			continue
		var text := append_extras(stamped, extras) if id == root_id else stamped
		if text == "":
			result["failed"].append({"id": id, "name": name, "path": path, "reason": "its file wasn't in the shape expected"})
			continue
		var known: Dictionary = files.get(id, {})
		var exists := FileAccess.file_exists(path)
		if exists and not known.is_empty() and fingerprint(text) == str(known.get("fingerprint", "")) and fingerprint(text) != "":
			result["unchanged"].append(name)
			continue
		var target := path
		if exists and not known.is_empty() and FileAccess.get_modified_time(path) != int(known.get("mtime", 0)):
			# someone else changed this file since it was read or last written (the flat app on a shared folder)
			var on_disk := fingerprint(FileAccess.get_file_as_string(path))
			if on_disk != "" and on_disk != str(known.get("fingerprint", "")) and on_disk != fingerprint(text):
				match policy:
					"overwrite":
						pass
					"copy":
						target = path.get_base_dir().path_join("%s (copy).didsa" % path.get_file().get_basename())
						var n := 2
						while FileAccess.file_exists(target):
							target = path.get_base_dir().path_join("%s (copy %d).didsa" % [path.get_file().get_basename(), n])
							n += 1
					"skip":
						result["conflicts"].append({"id": id, "name": name, "path": path})
						continue
					_:
						result["conflicts"].append({"id": id, "name": name, "path": path})
						continue
		var error := write_atomic(target, text)
		if error != "":
			result["failed"].append({"id": id, "name": name, "path": target, "reason": error})
			continue
		if target == path:
			files[id] = {"path": path, "fingerprint": fingerprint(text), "mtime": FileAccess.get_modified_time(path)}
			result["saved"].append({"id": id, "name": name, "path": path})
		else:
			result["copies"].append({"id": id, "name": name, "path": target})
	return result


static func summary(result: Dictionary) -> String:
	## "Saved 3 files (Bracket, Frame, Assembly); 1 skipped: Pin changed on disk since it was opened."
	var saved: Array = result.get("saved", [])
	var bits: PackedStringArray = []
	if not saved.is_empty():
		var names: PackedStringArray = saved.map(func(s) -> String: return str(s["name"]))
		bits.append("Saved %d file%s (%s)" % [saved.size(), "" if saved.size() == 1 else "s", ", ".join(names)])
	var copies: Array = result.get("copies", [])
	if not copies.is_empty():
		bits.append("%d saved as copies (%s)" % [copies.size(), ", ".join(PackedStringArray(copies.map(func(c) -> String: return str(c["path"]).get_file())))])
	var problems: PackedStringArray = []
	for c in result.get("conflicts", []):
		problems.append("%s changed on disk since it was opened" % str(c["name"]))
	for f in result.get("failed", []):
		problems.append("%s: %s" % [str(f["name"]), str(f["reason"])])
	var unchanged: Array = result.get("unchanged", [])
	if bits.is_empty() and problems.is_empty():
		return "Nothing to save: %d file%s unchanged." % [unchanged.size(), "" if unchanged.size() == 1 else "s"]
	var out := "; ".join(bits)
	if not problems.is_empty():
		out += "%s%d skipped: %s" % ["; " if out != "" else "", problems.size(), "; ".join(problems)]
	return out + "."
