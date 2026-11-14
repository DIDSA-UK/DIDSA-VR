extends RefCounted
## S3: where a server project's local copy (the mirror) and its private sync state live. Pure static functions.
##
##   mirror    <root>/<server host>/<project>/      VISIBLE, in Documents (a sibling of Documents/DIDSA, never inside it and never a dot-folder: the
##                                                  moved-files index skips dot-folders and the local Files list would show a nested one), so the owner can
##                                                  drag files in and out by hand. native_compose.gd, file_lookup.gd, file_index.gd and project_save.gd
##                                                  read and write it as any folder.
##   state     user://didsa-cloud-state/<key>/      PRIVATE: what each file was at the last sync, the queue of unsent saves, the change-feed cursor, the
##                                                  "mine" copies kept after Take theirs. Deleting the mirror cannot delete the queue.
##
## The root is ONE setting (`AppSettings.cloud_folder`; "" = the default below) so it can move if the Quest storage check shows Documents too slow or small.
## Documents needs All files access on the Quest (as the local project folder does); without it, or when Documents can't be used, the mirror falls back
## to user://DIDSA-Cloud and the Files page says so (docs/android-build.md, "Server projects").

const DIR_NAME := "DIDSA-Cloud"
const FALLBACK_ROOT := "user://DIDSA-Cloud"
const STATE_ROOT := "user://didsa-cloud-state"
const STATE_ENV := "DIDSA_CLOUD_STATE" ## tests: another state folder


static func default_root(documents: String = "<system>") -> String:
	## Documents/DIDSA-Cloud, or the fallback when there is no Documents folder.
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) if documents == "<system>" else documents
	return FALLBACK_ROOT if docs.is_empty() else docs.path_join(DIR_NAME)


static func resolve_root(setting: String, on_android: bool, all_files: bool, documents: String = "<system>") -> Dictionary:
	## {path, fallback: bool, note: String}. The configured folder (or the default), unless it can't be used: on Android without All files access a
	## folder outside the app's own storage can't be relied on, and any folder that can't be made and written falls back to user://DIDSA-Cloud.
	var wanted := setting.strip_edges() if setting.strip_edges() != "" else default_root(documents)
	var outside_app := not (wanted.begins_with("user://") or wanted.begins_with("res://"))
	if wanted == FALLBACK_ROOT:
		return {"path": wanted, "fallback": false, "note": ""}
	if on_android and outside_app and not all_files:
		return {"path": FALLBACK_ROOT, "fallback": true, "note": "All files access is off, so the local copy of server projects is in the app's own storage (%s), not Documents. Allow All files access to keep it in Documents where you can drag files in and out." % ProjectSettings.globalize_path(FALLBACK_ROOT)}
	if outside_app:
		var made := DirAccess.make_dir_recursive_absolute(wanted)
		if made != OK and not DirAccess.dir_exists_absolute(wanted):
			return {"path": FALLBACK_ROOT, "fallback": true, "note": "%s can't be made, so the local copy of server projects is in the app's own storage (%s)." % [wanted, ProjectSettings.globalize_path(FALLBACK_ROOT)]}
		var probe := _can_write(wanted)
		if not probe:
			return {"path": FALLBACK_ROOT, "fallback": true, "note": "%s can't be written to, so the local copy of server projects is in the app's own storage (%s)." % [wanted, ProjectSettings.globalize_path(FALLBACK_ROOT)]}
	return {"path": wanted, "fallback": false, "note": ""}


static func _can_write(folder: String) -> bool:
	var marker := folder.path_join(".didsa_cloud_probe_%d" % Time.get_ticks_usec())
	var file := FileAccess.open(marker, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string("probe")
	file.close()
	var ok := FileAccess.file_exists(marker)
	DirAccess.remove_absolute(marker)
	return ok


static func host_folder(store_url: String) -> String:
	## The store's address as a folder name: "store.example.com", or "192.168.1.5_8200" (a port other than 80 / 443 is kept; a colon is not a legal
	## file name character on every filesystem).
	var rest := store_url.strip_edges()
	if "://" in rest:
		rest = rest.get_slice("://", 1)
	rest = rest.get_slice("/", 0)
	if "@" in rest:
		rest = rest.substr(rest.rfind("@") + 1) # user:pass@host
	var host := rest
	var port := ""
	if rest.begins_with("["): # [::1]:8200
		var close := rest.find("]")
		host = rest.substr(0, close + 1)
		port = rest.substr(close + 2) if close >= 0 and rest.length() > close + 2 else ""
	elif ":" in rest:
		host = rest.get_slice(":", 0)
		port = rest.get_slice(":", 1)
	var name := safe_segment(host)
	if port not in ["", "80", "443"]:
		name += "_" + safe_segment(port)
	return name if name != "" else "server"


static func safe_segment(text: String) -> String:
	## One path segment: no separators, no characters a filesystem refuses, no leading dot (a dot-folder would be skipped), no trailing dot or space.
	var out := text.strip_edges()
	for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "[", "]"]:
		out = out.replace(bad, "_")
	out = out.lstrip(".").rstrip(". ")
	return out


static func mirror_dir(root: String, store_url: String, project: String) -> String:
	return root.path_join(host_folder(store_url)).path_join(safe_segment(project) if safe_segment(project) != "" else "project")


static func state_root() -> String:
	var override := OS.get_environment(STATE_ENV)
	return override if override != "" else STATE_ROOT


static func state_dir(store_url: String, project: String, root: String = "") -> String:
	## A stable folder per (store, project): a hash, so no project name can escape or collide.
	var base := root if root != "" else state_root()
	var key := ("%s\n%s" % [store_url.strip_edges().trim_suffix("/").to_lower(), project]).sha256_text().substr(0, 24)
	return base.path_join(key)


static func relative(mirror: String, full: String) -> String:
	## `full` relative to the mirror folder, "" when it is not inside it.
	var prefix := mirror.trim_suffix("/") + "/"
	return full.substr(prefix.length()) if full.begins_with(prefix) else ""
