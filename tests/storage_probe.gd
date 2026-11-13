extends SceneTree
## S0 spike (DIDSA-CAD docs/shared-storage-scope.md, "The Quest spike"), on this machine: the storage report finds user://, its free space, the
## Documents folder, and writes, reads back and removes a test file of the size asked; the text and the log line say all of it; sizes read as
## MB / GB; a failure says what failed. The button on the launcher's Servers page is in tests/servers.gd. NOT covered: the headset (that is
## the point of the spike: docs/android-build.md, "Storage for server projects", has the owner's checklist).
## Run: "$GODOT" --headless --path . --script res://tests/storage_probe.gd

const StorageProbe := preload("res://scripts/storage_probe.gd")


func _initialize() -> void:
	var r: Dictionary = StorageProbe.report(2)
	print("SMOKE the report finds user:// and its free space: ", r["ok"] and str(r["user_dir"]) != "" and int(r["user_free_bytes"]) > 0)
	print("SMOKE a 2 MB file is written and read back, with timings: ", r["read_back_ok"] and float(r["write_ms"]) >= 0.0 and float(r["read_ms"]) >= 0.0 and int(r["test_mb"]) == 2)
	print("SMOKE ...and removed afterwards: ", not FileAccess.file_exists(StorageProbe.TEST_FILE))
	var text: String = StorageProbe.text(r)
	print("SMOKE the text names the folder, the free space, Documents and the timings: ", text.contains("App storage (user://): " + str(r["user_dir"])) and text.contains("Free there:") and text.contains("Documents:") and text.contains("2 MB written in"))
	print("SMOKE the log line is one line for adb logcat: ", StorageProbe.log_line(r).begins_with("DIDSA VR: storage: ") and not StorageProbe.log_line(r).contains("\n"))
	print("SMOKE sizes read as MB / GB, unknown below zero: ", StorageProbe.size_text(5 * 1024 * 1024) == "5 MB" and StorageProbe.size_text(3 * 1024 * 1024 * 1024) == "3.0 GB" and StorageProbe.size_text(-1) == "unknown")
	var failed := {"ok": false, "error": "a file cannot be written in user:// (Permission denied)", "user_dir": "/x", "write_ms": -1.0}
	print("SMOKE a failure says what failed: ", StorageProbe.text(failed).begins_with("Storage check failed: a file cannot be written"))
	quit(0)
