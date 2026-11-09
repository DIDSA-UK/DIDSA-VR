extends RefCounted
## The project folder, as pure static functions (docs/test-report-30-oct-plan.md T1): where it defaults to, whether a folder can really be used
## (probe), the folders inside one (for the chooser) and the text that tells the user where files go. Nothing here keeps state.
##
## On the Quest (Android scoped storage) a plain path is readable only if the app made the files itself, or has *All files access*. This code
## cannot tell which: probe() tries a real write and a real read, so what it reports is what happened, not a guess.

const APP_FOLDER := "user://models" ## "Keep in app storage": what main.gd used before there was a project folder
const DEFAULT_NAME := "DIDSA" ## Documents/DIDSA
const MODEL_EXTENSIONS := ["glb", "gltf", "didsa", "didsaprt", "didsacad", "step", "stp", "stl", "obj"]
const LISTED_MAX := 60 ## folders shown at once in the chooser (a page that scrolls, not a wall)


static func documents_dir() -> String:
	## The system Documents folder ("" when the platform has none, as a bare headless run can be).
	return OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)


static func default_folder(documents: String = "<system>") -> String:
	## Documents/DIDSA, or user://models when there is no Documents folder. `documents` is for tests.
	var docs := documents_dir() if documents == "<system>" else documents
	if docs.is_empty():
		return APP_FOLDER
	return docs.path_join(DEFAULT_NAME)


static func probe(path: String) -> Dictionary:
	## Can this folder be used? Makes it if missing, writes and deletes a small file, lists it:
	## {exists, readable, writable, error} (error is "" when all is well; else words for the user).
	var out := {"exists": false, "readable": false, "writable": false, "error": ""}
	if path.strip_edges().is_empty():
		out["error"] = "No folder given."
		return out
	if not DirAccess.dir_exists_absolute(path):
		var made := DirAccess.make_dir_recursive_absolute(path)
		if made != OK or not DirAccess.dir_exists_absolute(path):
			out["error"] = "The folder doesn't exist and couldn't be made (error %d). On the Quest only folders the app made itself are allowed unless *All files access* is on." % made
			return out
	out["exists"] = true
	var dir := DirAccess.open(path)
	out["readable"] = dir != null
	var marker := path.path_join(".didsa_probe_%d" % Time.get_ticks_usec())
	var file := FileAccess.open(marker, FileAccess.WRITE)
	if file != null:
		file.store_string("probe")
		file.close()
		out["writable"] = FileAccess.file_exists(marker)
		DirAccess.remove_absolute(marker)
	if not out["readable"]:
		out["error"] = "The folder can't be read."
	elif not out["writable"]:
		out["error"] = "The folder can't be written to, so nothing could be saved there."
	return out


static func usable(path: String) -> bool:
	var result := probe(path)
	return result["exists"] and result["readable"] and result["writable"]


static func full_path(path: String) -> String:
	## The real path, never user:// or res:// (what a file browser would show).
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	return path


static func short_name(path: String) -> String:
	## "Documents/DIDSA" for a folder under Documents, else the last two parts: the short form for a header.
	if path.is_empty():
		return "app storage"
	var full := full_path(path).rstrip("/")
	var docs := documents_dir().rstrip("/")
	if not docs.is_empty() and full.begins_with(docs + "/"):
		return "Documents/" + full.substr(docs.length() + 1)
	var parts := full.split("/", false)
	if parts.size() <= 2:
		return full
	return "%s/%s" % [parts[parts.size() - 2], parts[parts.size() - 1]]


static func parent_of(path: String) -> String:
	## The folder above, "" when there is none (a root).
	var trimmed := path.rstrip("/")
	if trimmed.is_empty() or trimmed.ends_with(":"):
		return ""
	var idx := trimmed.rfind("/")
	if idx <= 0:
		return "/" if idx == 0 and trimmed != "/" else ""
	return trimmed.substr(0, idx)


static func subfolders(path: String) -> PackedStringArray:
	## The folders inside `path`, sorted, without hidden ones; empty when it can't be listed.
	var found := PackedStringArray()
	var dir := DirAccess.open(path)
	if dir == null:
		return found
	for name in dir.get_directories():
		if not name.begins_with("."):
			found.append(name)
	found.sort()
	return found


static func model_files(path: String) -> PackedStringArray:
	## The model files directly in `path` (names), by extension.
	var found := PackedStringArray()
	var dir := DirAccess.open(path)
	if dir == null:
		return found
	for name in dir.get_files():
		if name.get_extension().to_lower() in MODEL_EXTENSIONS:
			found.append(name)
	found.sort()
	return found


static func make_subfolder(parent: String, name: String) -> Dictionary:
	## {ok, path, error}: a new folder named `name` inside `parent` (the name is cleaned: no slashes, no dots at the start).
	var clean := name.strip_edges().replace("/", "").replace("\\", "").lstrip(".")
	if clean.is_empty():
		return {"ok": false, "path": "", "error": "Give the folder a name."}
	var path := parent.path_join(clean)
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err != OK and not DirAccess.dir_exists_absolute(path):
		return {"ok": false, "path": path, "error": "Couldn't make %s (error %d)." % [clean, err]}
	return {"ok": true, "path": path, "error": ""}


static func start_dir(current: String) -> String:
	## Where the chooser opens: the current project folder if it exists, else Documents, else the app's folder.
	if not current.is_empty() and DirAccess.dir_exists_absolute(current):
		return current
	var docs := documents_dir()
	if not docs.is_empty() and DirAccess.dir_exists_absolute(docs):
		return docs
	return ProjectSettings.globalize_path("user://")


static func status_line(path: String) -> String:
	## One line for Settings and the Files page: the full path, writable or not, how many model files it holds.
	var shown := full_path(APP_FOLDER if path.is_empty() else path)
	var result := probe(shown)
	var state := "can be written to" if result["writable"] else ("read only" if result["exists"] else "doesn't exist")
	return "%s: %s, %d model file(s)" % [shown, state, model_files(shown).size()]
