extends SceneTree
## V-9 (docs/vr-feedback-2026-11-11-plan.md): saving like the flat app, one file per Part in place (scripts/project_save.gd), with a fake backend and a temp folder:
##   - every Part gets its own file (a new Part is named after itself, unique in the folder), children written before parents, each occurrence's `external_ref` stamped
##     relative to the root's folder with `ref_part_id`, numbers written exactly (`0` stays `0`, `1.50` stays `1.50`), the root file gets the client-only extras
##   - what the files read back as: native_compose.gd opens the root file and finds every reference (the round trip)
##   - a second save with nothing changed writes nothing; one changed Part writes only its file and leaves the root untouched
##   - a file changed on disk since it was read is not overwritten (ask: reported; overwrite; copy; skip)
##   - a demo's res:// files are never a save target; a half-written file never appears (temp then rename); canonical comparison ignores formatting and 0 vs 0.0
## NOT covered: main.gd's wiring and the real backend (tests/e2e_project_save.gd), the Files page, a real shared folder (the flat app editing it meanwhile).
## Run: "$GODOT" --headless --path . --script res://tests/project_save.gd  (see tests/README.md)

const ProjectSave := preload("res://scripts/project_save.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")

var texts := {}


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func fetch(part_id: String) -> String:
	await process_frame
	return str(texts.get(part_id, ""))


func part_text(id: String, name: String, resolved: String = "", distance: String = "0") -> String:
	var occurrences := ""
	if resolved != "":
		occurrences = "{\"id\": \"o1\", \"external_ref\": null, \"resolved_part_id\": \"%s\", \"transform\": {\"translation\": [0, 0, 0], \"rotation_axis\": [0, 0, 1], \"rotation_angle_degrees\": 0}}" % resolved
	return "{\"schema_version\": 1, \"document\": {\"id\": \"default\", \"root_part_id\": \"%s\", \"parts\": [{\"id\": \"%s\", \"name\": \"%s\", \"features\": [{\"type\": \"extrude\", \"distance\": %s, \"width\": 1.50}], \"occurrences\": [%s], \"mates\": []}]}, \"sketches\": []}" % [id, id, name, distance, occurrences]


func read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _initialize() -> void:
	var folder := ProjectSettings.globalize_path("user://test_project_save")
	if DirAccess.dir_exists_absolute(folder):
		for f in DirAccess.get_files_at(folder):
			DirAccess.remove_absolute(folder.path_join(f))
	else:
		DirAccess.make_dir_recursive_absolute(folder)

	# --- pure helpers
	check("canonical ignores formatting, key order and 0 vs 0.0", ProjectSave.canonical("{\"b\": 0, \"a\": [1, 2]}") == ProjectSave.canonical("{ \"a\": [1,2],\n \"b\": 0.0 }") and ProjectSave.fingerprint("{\"a\": 1}") != ProjectSave.fingerprint("{\"a\": 2}") and ProjectSave.fingerprint("nonsense") == "")
	check("relative paths: the same folder, a subfolder, up one, across", ProjectSave.relative_path("/a/b", "/a/b/x.didsa") == "x.didsa" and ProjectSave.relative_path("/a/b", "/a/b/sub/y.didsa") == "sub/y.didsa" and ProjectSave.relative_path("/a/b/c", "/a/b/z.didsa") == "../z.didsa" and ProjectSave.relative_path("/a/b", "/a/q/z.didsa") == "../q/z.didsa")
	var parts := [{"id": "R", "occurrences": [{"resolved_part_id": "S"}, {"resolved_part_id": "B"}]}, {"id": "S", "occurrences": [{"resolved_part_id": "B"}]}, {"id": "B", "occurrences": []}, {"id": "N", "occurrences": []}]
	check("children are written before the parts that place them", ProjectSave.placed_first(["R", "S", "B", "N"], parts) == ["B", "S", "R", "N"])
	check("a file name drops what a file system refuses; an empty name falls back", ProjectSave.safe_name("a/b:c*?") == "a_b_c__" and ProjectSave.safe_name("  ..  ", "Part") == "Part")
	var taken := {}
	var first := ProjectSave.auto_path(folder, "Bracket", taken)
	var second := ProjectSave.auto_path(folder, "bracket", taken)
	check("auto names are unique in the folder: Bracket.didsa, then 'bracket 2.didsa'", first.get_file() == "Bracket.didsa" and second.get_file() == "bracket 2.didsa")
	check("atomic write: a file arrives whole, no temp file is left, a path that can't be made says why", ProjectSave.write_atomic(folder.path_join("w.didsa"), "{}") == "" and read(folder.path_join("w.didsa")) == "{}" and not FileAccess.file_exists(folder.path_join("w.didsa.saving")) and ProjectSave.write_atomic("/proc/nope/x.didsa", "{}") != "")
	DirAccess.remove_absolute(folder.path_join("w.didsa"))

	# --- the first save: every Part gets a file
	texts = {"R": part_text("R", "Assembly", "B"), "B": part_text("B", "Bracket"), "N": part_text("N", "New part")}
	var session := {"root_part_id": "R", "parts": [{"id": "R", "name": "Assembly", "occurrences": [{"resolved_part_id": "B"}]}, {"id": "B", "name": "Bracket", "occurrences": []}, {"id": "N", "name": "New part", "occurrences": []}]}
	var saver = ProjectSave.new()
	var root_path := folder.path_join("Assembly.didsa")
	var result: Dictionary = await saver.save(session, Callable(self, "fetch"), folder, "", {"hidden_feature_ids": ["f1"]})
	var written: Array = (result["saved"] as Array).map(func(s): return str(s["name"]))
	check("the first save writes one file per Part, the children first", written == ["Bracket", "Assembly", "New part"] and (result["failed"] as Array).is_empty() and (result["conflicts"] as Array).is_empty())
	check("...each named after its Part, in the folder", FileAccess.file_exists(root_path) and FileAccess.file_exists(folder.path_join("Bracket.didsa")) and FileAccess.file_exists(folder.path_join("New part.didsa")))
	var root_text := read(root_path)
	check("the root's occurrence says where its part is, relative to the root's folder, and which Part it is", root_text.contains("\"external_ref\":\"Bracket.didsa\"") and root_text.contains("\"ref_part_id\":\"B\""))
	check("numbers keep their text: 0 stays 0 and 1.50 stays 1.50 (the float trap)", root_text.contains("\"distance\":0,") and root_text.contains("1.50") and not root_text.contains("\"distance\":0.0"))
	check("the client-only extras go on the ROOT file only", root_text.contains("hidden_feature_ids") and not read(folder.path_join("Bracket.didsa")).contains("hidden_feature_ids"))
	var composed := NativeCompose.compose(root_path)
	check("reopening from the root file finds every reference (the round trip through native_compose)", composed["ok"] and int(composed["resolved"]) == 1 and (composed["unresolved"] as Array).is_empty() and str(composed["text"]).contains("\"id\":\"B\""))

	# --- nothing changed: nothing written
	var stamp_before := FileAccess.get_modified_time(root_path)
	var again: Dictionary = await saver.save(session, Callable(self, "fetch"), folder, "", {"hidden_feature_ids": ["f1"]})
	check("a second save with nothing changed writes nothing", (again["saved"] as Array).is_empty() and (again["unchanged"] as Array).size() == 3 and FileAccess.get_modified_time(root_path) == stamp_before)

	# --- one Part changed: only its file
	texts["B"] = part_text("B", "Bracket", "", "12")
	var root_before := read(root_path)
	var changed: Dictionary = await saver.save(session, Callable(self, "fetch"), folder, "", {"hidden_feature_ids": ["f1"]})
	check("changing one Part writes only that file and leaves the root untouched", (changed["saved"] as Array).size() == 1 and changed["saved"][0]["name"] == "Bracket" and read(root_path) == root_before and read(folder.path_join("Bracket.didsa")).contains("\"distance\":12"))

	# --- a file changed on disk since it was read
	texts["B"] = part_text("B", "Bracket", "", "99")
	DirAccess.remove_absolute(folder.path_join("Bracket.didsa"))
	var theirs := part_text("B", "Bracket", "", "7")
	var f := FileAccess.open(folder.path_join("Bracket.didsa"), FileAccess.WRITE)
	f.store_string(theirs)
	f.close()
	saver.files["B"]["mtime"] = int(saver.files["B"]["mtime"]) - 10 # (the modified time moved since we wrote it)
	var asked: Dictionary = await saver.save(session, Callable(self, "fetch"), folder, "", {})
	check("a file changed on disk since it was read is not overwritten: it is reported", (asked["conflicts"] as Array).size() == 1 and asked["conflicts"][0]["name"] == "Bracket" and read(folder.path_join("Bracket.didsa")) == theirs)
	var skipped: Dictionary = await saver.save(session, Callable(self, "fetch"), folder, "", {}, "skip")
	check("...'skip' leaves it too", (skipped["conflicts"] as Array).size() == 1 and read(folder.path_join("Bracket.didsa")) == theirs)
	var copied: Dictionary = await saver.save(session, Callable(self, "fetch"), folder, "", {}, "copy")
	check("...'copy' writes beside it and leaves theirs", (copied["copies"] as Array).size() == 1 and FileAccess.file_exists(folder.path_join("Bracket (copy).didsa")) and read(folder.path_join("Bracket.didsa")) == theirs and read(folder.path_join("Bracket (copy).didsa")).contains("\"distance\":99"))
	var over: Dictionary = await saver.save(session, Callable(self, "fetch"), folder, "", {}, "overwrite")
	check("...'overwrite' replaces it", (over["saved"] as Array).size() >= 1 and read(folder.path_join("Bracket.didsa")).contains("\"distance\":99"))

	# --- each file's own client-only keys survive a save of that file
	var extra_path := folder.path_join("Extras.didsa")
	var ef := FileAccess.open(extra_path, FileAccess.WRITE)
	ef.store_string(part_text("X", "Extras").trim_suffix("}") + ", \"section_planes\": [1, 2]}")
	ef.close()
	var keeper = ProjectSave.new()
	keeper.add_files({"X": extra_path})
	check("a file's own client-only keys are read when it is registered", (keeper.files["X"]["extras"] as Dictionary).has("section_planes"))
	texts["X"] = part_text("X", "Extras", "", "5")
	var kept: Dictionary = await keeper.save({"root_part_id": "X", "parts": [{"id": "X", "name": "Extras", "occurrences": []}]}, Callable(self, "fetch"), folder, "", {"section_planes": [1, 2]})
	check("...and written back with that file (here as the root's extras)", (kept["saved"] as Array).size() == 1 and read(extra_path).contains("section_planes"))
	var nonroot = ProjectSave.new()
	nonroot.add_files({"X": extra_path})
	texts["X"] = part_text("X", "Extras", "", "6")
	var kept2: Dictionary = await nonroot.save({"root_part_id": "R", "parts": [{"id": "X", "name": "Extras", "occurrences": []}]}, Callable(self, "fetch"), folder, "", {})
	check("a NON-root file keeps its own client-only keys too (not only the root's)", (kept2["saved"] as Array).size() == 1 and read(extra_path).contains("section_planes") and read(extra_path).contains("\"distance\":6"))

	# --- demos and a fresh session
	var fresh = ProjectSave.new()
	fresh.register_composed({"B": "res://demo/models/anything.didsa", "R": ""})
	check("a demo's res:// file (or a missing one) is never remembered as a save target", fresh.files.is_empty())
	var other := ProjectSettings.globalize_path("user://test_project_save_other")
	DirAccess.make_dir_recursive_absolute(other)
	var demo_save: Dictionary = await fresh.save(session, Callable(self, "fetch"), other, "res://demo/assemblies/x/x.didsa")
	check("saving a demo writes every Part as a new file in the project folder, nothing back to res://", (demo_save["saved"] as Array).size() == 3 and FileAccess.file_exists(other.path_join("Assembly.didsa")) and (demo_save["failed"] as Array).is_empty())

	# --- a failure is per Part
	texts.erase("N")
	var failing: Dictionary = await saver.save(session, Callable(self, "fetch"), folder, "", {})
	check("one Part the backend can't send is reported and the others still save", (failing["failed"] as Array).size() == 1 and failing["failed"][0]["name"] == "New part")
	check("the summary reads 'Saved 3 files (A, B, C); 1 skipped: ...'", ProjectSave.summary({"saved": [{"name": "Bracket"}, {"name": "Frame"}, {"name": "Assembly"}], "conflicts": [{"name": "Pin"}], "failed": [], "copies": [], "unchanged": []}) == "Saved 3 files (Bracket, Frame, Assembly); 1 skipped: Pin changed on disk since it was opened." and ProjectSave.summary({"saved": [], "conflicts": [], "failed": [], "copies": [], "unchanged": ["a", "b"]}) == "Nothing to save: 2 files unchanged.")
	quit(0)
