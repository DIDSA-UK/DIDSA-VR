extends SceneTree
## Headless, no network: finding moved files (scripts/file_lookup.gd) against DIDSA-CAD's golden vectors - docs/file-lookup/vectors.json,
## written by its reference (backend/app/document/file_lookup.py). The json is COPIED to tests/fixtures/file_lookup_vectors.json; when a
## DIDSA-CAD checkout is reachable (env DIDSA_CAD_DIR, else ../DIDSA-CAD) this test also fails if the copy differs. Every answer is
## compared exactly; also checks the name key.
## Run: "$GODOT" --headless --path . --script res://tests/file_lookup_vectors.gd

const FileLookup := preload("res://scripts/file_lookup.gd")
const FIXTURE := "res://tests/fixtures/file_lookup_vectors.json"

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _source_check(text: String) -> String:
	var dir := OS.get_environment("DIDSA_CAD_DIR")
	var candidates: Array[String] = []
	if dir != "":
		candidates.append(dir.path_join("docs/file-lookup/vectors.json"))
	candidates.append(ProjectSettings.globalize_path("res://").path_join("../DIDSA-CAD/docs/file-lookup/vectors.json"))
	for p in candidates:
		if FileAccess.file_exists(p):
			return "same" if FileAccess.get_file_as_string(p) == text else "DIFFERENT (%s)" % p
	return "no source"


func _initialize() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	var doc = JSON.parse_string(text)
	if not (doc is Dictionary):
		print("SMOKE FAILED: couldn't read ", FIXTURE)
		quit(1)
		return
	var src := _source_check(text)
	_check(src == "same" or src == "no source", "the fixture copy equals DIDSA-CAD's docs/file-lookup/vectors.json (%s)" % src)
	var mismatches: Array = []
	for c in doc["cases"]:
		var got := FileLookup.find_file(c["reference"], c["at_path"], c["index"])
		if got != c["expected"]:
			mismatches.append(str(c["name"]))
			print("  ", c["name"], ": got ", got, " expected ", c["expected"])
	print("SMOKE golden vectors: ", (doc["cases"] as Array).size(), " cases, mismatches ", mismatches)
	_check((doc["cases"] as Array).size() >= 16 and mismatches.is_empty(), "every vector gives the reference's answer")
	_check(FileLookup.name_key("parts/Bracket.didsa") == FileLookup.name_key("old/bracket.DIDSAprt") and FileLookup.name_key("Bracket.DIDSACAD") == "bracket", "the name key sets the native extension and the case aside")
	_check(FileLookup.name_key("a\\b\\Frame A.didsa") == "frame a" and FileLookup.name_key("notes.txt") == "notes.txt", "...takes the last segment of either slash, and leaves other files alone")
	_check(FileLookup.is_native("x/Frame.DIDSAPRT") and not FileLookup.is_native("x/Frame.step"), "native files are told apart in any case")
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
