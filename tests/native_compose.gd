extends SceneTree
## Multi-file native assemblies (scripts/native_compose.gd): the files an assembly's occurrences reference (`external_ref`) are found and
## folded into one import payload, under the extension they were written with or another one (`.DIDSAprt` written, `.didsa` on disk,
## any letter case), in a subfolder, shared by two occurrences (one Part), and a reference that is missing, loops back or reuses a Part
## id is left unresolved and reported. Integers stay integers in the composed text (the backend refuses 0.0 for an integer field), and
## a file with no references is passed through as its own text. Writes its fixture files under user://native_compose_test/.
## Run: "$GODOT" --headless --path . --script res://tests/native_compose.gd  (see tests/README.md)

const NativeCompose := preload("res://scripts/native_compose.gd")
const DIR := "user://native_compose_test"


func _part(id: String, occurrences: Array) -> Dictionary:
	return {"id": id, "name": id, "features": [], "occurrences": occurrences, "mates": []}


func _occ(id: String, ref: String) -> Dictionary:
	return {"id": id, "external_ref": ref, "resolved_part_id": null, "name_override": null,
		"transform": {"translation": [10, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0}, "suppressed": false, "hidden": false, "fixed": false, "color": null}


func _write(name: String, part: Dictionary, sketches: Array = []) -> String:
	## A native file as the flat app writes it, with plain integers in the text.
	var payload := {"schema_version": 1, "document": {"id": "doc-" + str(part["id"]), "root_part_id": part["id"], "parts": [part]}, "sketches": sketches}
	var path := DIR.path_join(name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(NativeCompose.to_json(payload))
	f.close()
	return path


func _clean() -> void:
	for sub in ["sub", ""]:
		var d := DirAccess.open(DIR.path_join(sub))
		if d == null:
			continue
		for file in d.get_files():
			d.remove(file)
	DirAccess.remove_absolute(DIR.path_join("sub"))


func _find(parts: Array, id: String) -> Dictionary:
	for p in parts:
		if p["id"] == id:
			return p
	return {}


func _initialize() -> void:
	_clean()
	print("SMOKE native extensions are told apart in any case, current first: ", NativeCompose.native_extension("a/Frame.DIDSAPRT") == "DIDSAprt" and NativeCompose.native_extension("x.didsa") == "didsa" and NativeCompose.native_extension("x.didsacad") == "didsacad" and NativeCompose.native_extension("x.step") == "")
	print("SMOKE the base-name key ignores the extension and the case: ", NativeCompose.base_name_key("Bracket.didsa") == NativeCompose.base_name_key("bracket.DIDSAprt") and NativeCompose.base_name_key("Bracket.didsa") != NativeCompose.base_name_key("Bracket2.didsa"))
	print("SMOKE whole-number floats are written as integers, others in full: ", NativeCompose.to_json({"a": 0.0, "b": 3.0, "c": 0.25, "d": [1.0, -2.0], "e": null, "f": "x"}) == '{"a":0,"b":3,"c":0.25,"d":[1,-2],"e":null,"f":"x"}')

	# --- the fixture: Root references Frame_A (written as .DIDSAprt, on disk as .didsa), a bolt in a subfolder (in another case), a missing file,
	# and a file that refers back to Root. Frame_A references the same bolt again (a diamond: one Part).
	_write("Frame_A.didsa", _part("frame", [_occ("f-bolt", "sub/Bolt.didsa")]), [{"id": "sk1", "plane": "XY", "entities": [], "count": 2}])
	_write("sub/bolt.DIDSAprt", _part("bolt", []))
	_write("Loop.didsa", _part("loop", [_occ("l-root", "Root.didsa")]))
	_write("Twin.didsa", _part("frame", [])) # a different file reusing Frame_A's Part id (an old Save As copy)
	var root_path := _write("Root.didsa", _part("root", [
		_occ("o-frame", "Frame_A.DIDSAprt"),
		_occ("o-bolt", "sub/Bolt.didsa"),
		_occ("o-missing", "Missing.didsa"),
		_occ("o-loop", "Loop.didsa"),
		_occ("o-twin", "Twin.didsa"),
	]))
	print("SMOKE a reference finds its file under another extension: ", NativeCompose.find_file("Frame_A.DIDSAprt", [DIR]) == DIR.path_join("Frame_A.didsa"))
	print("SMOKE ...and in a subfolder, in another case: ", NativeCompose.find_file("sub/Bolt.didsa", [DIR]) == DIR.path_join("sub/bolt.DIDSAprt"))
	print("SMOKE ...a missing file, or a path walking out of the folder, is not found: ", NativeCompose.find_file("Missing.didsa", [DIR]) == "" and NativeCompose.find_file("../Root.didsa", [DIR.path_join("sub")]) == "")

	var composed := NativeCompose.compose(root_path)
	var payload = JSON.parse_string(composed["text"])
	print("SMOKE the composed payload parses and names the root: ", composed["ok"] and payload is Dictionary and payload["document"]["root_part_id"] == "root" and composed["root_part_id"] == "root")
	var parts: Array = payload["document"]["parts"]
	print("SMOKE it carries the root, the frame, the bolt (once, though two occurrences use it) and the loop file: ", parts.size() == 4 and not _find(parts, "frame").is_empty() and not _find(parts, "bolt").is_empty() and not _find(parts, "loop").is_empty())
	var root_occs: Array = _find(parts, "root")["occurrences"]
	print("SMOKE each found occurrence names its Part: ", root_occs[0]["resolved_part_id"] == "frame" and root_occs[1]["resolved_part_id"] == "bolt" and _find(parts, "frame")["occurrences"][0]["resolved_part_id"] == "bolt")
	print("SMOKE ...and its reference is healed to the name it was found under: ", root_occs[0]["external_ref"] == "Frame_A.didsa" and root_occs[1]["external_ref"] == "sub/bolt.DIDSAprt")
	print("SMOKE a missing file, a loop back to the root and a reused Part id stay unresolved: ", root_occs[2]["resolved_part_id"] == null and _find(parts, "loop")["occurrences"][0]["resolved_part_id"] == null and root_occs[4]["resolved_part_id"] == null)
	print("SMOKE ...and are reported: ", composed["resolved"] == 4 and (composed["unresolved"] as Array).size() == 3 and str(composed["unresolved"]).contains("Missing.didsa (not found)") and str(composed["unresolved"]).contains("refers back") and str(composed["unresolved"]).contains("already used"))
	print("SMOKE the note for the status line counts them: ", NativeCompose.unresolved_note(composed).begins_with(" 3 referenced files not loaded:"))
	print("SMOKE sketches from referenced files come along: ", payload["sketches"].size() == 1 and payload["sketches"][0]["id"] == "sk1")
	var text: String = composed["text"]
	print("SMOKE integers stay integers in the composed text: ", text.contains('"schema_version":1,') and text.contains('"translation":[10,0,0]') and text.contains('"count":2') and not text.contains("1.0"))

	var plain := _write("Plain.didsa", _part("plain", []))
	var passed := NativeCompose.compose(plain)
	print("SMOKE a file with no references is sent as its own text, untouched: ", passed["ok"] and passed["text"] == FileAccess.get_file_as_string(plain) and passed["unresolved"].is_empty())
	print("SMOKE a missing root file says so: ", not NativeCompose.compose(DIR.path_join("Nope.didsa"))["ok"])
	_clean()
	quit()
