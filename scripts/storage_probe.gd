extends RefCounted
## S0 spike (DIDSA-CAD docs/shared-storage-scope.md, "The Quest spike"): where this app's own storage (`user://`) really is on the headset,
## how much room it has, and how fast a file of the size a cached project file might be writes and reads there. The server projects of S3
## keep a local copy (a mirror folder) in `user://`, which needs no storage permission; this answers whether that is a sensible home for it.
## Pure static functions: nothing here keeps state. The launcher's Servers page runs it from "Check storage" and prints one
## "DIDSA VR: storage:" line for `adb logcat`.

const TEST_FILE := "user://storage_probe.tmp"


static func report(test_mb: int = 20) -> Dictionary:
	## {ok, error, user_dir, user_free_bytes, documents_dir, documents_free_bytes, test_mb, write_ms, read_ms, read_back_ok}
	var out := {
		"ok": false, "error": "", "user_dir": OS.get_user_data_dir(), "user_free_bytes": -1,
		"documents_dir": OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS), "documents_free_bytes": -1,
		"test_mb": test_mb, "write_ms": -1.0, "read_ms": -1.0, "read_back_ok": false,
	}
	var user := DirAccess.open("user://")
	if user == null:
		out["error"] = "user:// cannot be opened (%s)" % error_string(DirAccess.get_open_error())
		return out
	out["user_free_bytes"] = user.get_space_left()
	if str(out["documents_dir"]) != "":
		var documents := DirAccess.open(str(out["documents_dir"]))
		if documents != null:
			out["documents_free_bytes"] = documents.get_space_left()
	var block := PackedByteArray()
	block.resize(1024 * 1024)
	for i in block.size():
		block[i] = i % 251 # not all zeros: a filesystem that compresses would make a zero file look fast
	var started := Time.get_ticks_usec()
	var file := FileAccess.open(TEST_FILE, FileAccess.WRITE)
	if file == null:
		out["error"] = "a file cannot be written in user:// (%s)" % error_string(FileAccess.get_open_error())
		return out
	for i in test_mb:
		file.store_buffer(block)
	file.close()
	out["write_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var back := FileAccess.get_file_as_bytes(TEST_FILE)
	out["read_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	out["read_back_ok"] = back.size() == test_mb * block.size() and (test_mb == 0 or back.slice(0, block.size()) == block)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_FILE))
	out["ok"] = out["read_back_ok"]
	if not out["ok"]:
		out["error"] = "the file read back is not the one written"
	return out


static func size_text(bytes: int) -> String:
	## Pure - "12.3 GB", "456 MB", or "unknown" for a negative size.
	if bytes < 0:
		return "unknown"
	if bytes >= 1024 * 1024 * 1024:
		return "%.1f GB" % (bytes / float(1024 * 1024 * 1024))
	return "%d MB" % int(round(bytes / float(1024 * 1024)))


static func text(r: Dictionary) -> String:
	## Pure - the report as lines for the Servers page (and, joined with " | ", for the log).
	if not r.get("ok", false) and str(r.get("error", "")) != "" and float(r.get("write_ms", -1.0)) < 0.0:
		return "Storage check failed: %s.\nApp storage (user://): %s" % [r["error"], r.get("user_dir", "?")]
	var lines := PackedStringArray([
		"App storage (user://): %s" % r["user_dir"],
		"Free there: %s" % size_text(int(r["user_free_bytes"])),
		"Documents: %s (free: %s)" % [r["documents_dir"] if str(r["documents_dir"]) != "" else "none", size_text(int(r["documents_free_bytes"]))],
		"%d MB written in %.0f ms, read in %.0f ms%s" % [int(r["test_mb"]), float(r["write_ms"]), float(r["read_ms"]), "" if r["ok"] else " (READ BACK WRONG)"],
	])
	return "\n".join(lines)


static func log_line(r: Dictionary) -> String:
	return "DIDSA VR: storage: " + text(r).replace("\n", " | ")
