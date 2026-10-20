extends SceneTree
## Headless, no network: finding moved files (DIDSA-CAD docs/moved-files-scope.md, F2). native_compose.gd with file_lookup.gd's rule and
## file_index.gd's index: a file moved to a subfolder or renamed is found by the part id its occurrence remembers (`ref_part_id`, or an
## older file's `resolved_part_id`) and its path corrected; two files with the id, a same-name file only, a different file at the path
## or nothing are left unresolved and listed for review; the user's pick is used; a pick outside the searched folders is refused.
## Also the index (every subfolder, dot-folders skipped, each file once) and the Files > References rows (tablet_pages.gd) against a
## stand-in for main.gd. Writes its fixture files under user://moved_files_test/.
## Run: "$GODOT" --headless --path . --script res://tests/moved_files.gd

const NativeCompose := preload("res://scripts/native_compose.gd")
const FileIndex := preload("res://scripts/file_index.gd")
const TabletPages := preload("res://scripts/ui/tablet_pages.gd")
const DIR := "user://moved_files_test"

var failures := 0


class FakeMain extends Node:
	## The four calls the References page makes into main.gd.
	var review := {"root": "", "relinked": [], "review": [], "bases": []}
	var files: Array = []
	var chosen: Array = []
	var left: Array = []

	func reference_review() -> Dictionary:
		return review

	func reference_files() -> Array:
		return files

	func choose_reference(key: String, file: String) -> void:
		chosen.append([key, file])

	func leave_reference_missing(key: String) -> void:
		left.append(key)


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _part(id: String, occurrences: Array = []) -> Dictionary:
	return {"id": id, "name": id, "features": [], "occurrences": occurrences, "mates": []}


func _occ(id: String, ref: String, ref_part_id = null, resolved_part_id = null) -> Dictionary:
	var occ := {"id": id, "external_ref": ref, "resolved_part_id": resolved_part_id, "name_override": null,
		"transform": {"translation": [10, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0}, "suppressed": false, "hidden": false, "fixed": false, "color": null}
	if ref_part_id != null:
		occ["ref_part_id"] = ref_part_id
	return occ


func _write(name: String, part: Dictionary) -> String:
	var payload := {"schema_version": 1, "document": {"id": "doc-" + str(part["id"]), "root_part_id": part["id"], "parts": [part]}, "sketches": []}
	var path := DIR.path_join(name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(NativeCompose.to_json(payload))
	f.close()
	return path


func _remove_tree(folder: String) -> void:
	var d := DirAccess.open(folder)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		_remove_tree(folder.path_join(sub))
	for file in d.get_files():
		d.remove(file)
	DirAccess.remove_absolute(folder)


func _occ_of(composed: Dictionary, part_id: String, occ_id: String) -> Dictionary:
	var payload = JSON.parse_string(composed["text"])
	for p in payload["document"]["parts"]:
		if p["id"] == part_id:
			for o in p["occurrences"]:
				if o["id"] == occ_id:
					return o
	return {}


func _review_of(composed: Dictionary, occ_id: String) -> Dictionary:
	for item in composed["review"]:
		if item["occurrence_id"] == occ_id:
			return item
	return {}


func _initialize() -> void:
	_remove_tree(DIR)
	# Moved into a subfolder; renamed; two copies; a different file now at the path; an older reference with only a same-name file
	# elsewhere; an older file whose resolved_part_id still names its (moved) target; nothing at all.
	_write("parts/frames/Frame_A.didsa", _part("frame"))
	_write("parts/Bolt (renamed).didsa", _part("bolt"))
	_write("left/Leg.didsa", _part("leg"))
	_write("right/Leg.didsa", _part("leg"))
	_write("Plate.didsa", _part("not-the-plate"))
	_write("old/Washer.didsa", _part("washer-somewhere"))
	_write("moved/Seeded.didsa", _part("seeded"))
	_write(".hidden/Frame_A.didsa", _part("frame")) # a dot-folder: never searched
	var root_path := _write("Root.didsa", _part("root", [
		_occ("o-frame", "Frame_A.didsa", "frame"),
		_occ("o-bolt", "Bolt.didsa", "bolt"),
		_occ("o-leg", "Leg.didsa", "leg"),
		_occ("o-plate", "Plate.didsa", "plate"),
		_occ("o-washer", "Washer.didsa"),
		_occ("o-seeded", "Seeded.didsa", null, "seeded"),
		_occ("o-gone", "Gone.didsa", "gone"),
	]))

	var composed := NativeCompose.compose(root_path)
	_check(composed["ok"] and composed["resolved"] == 3, "three references resolve: two by id, one seeded from an older file's resolved_part_id (%d)" % composed["resolved"])
	var frame := _occ_of(composed, "root", "o-frame")
	_check(frame["resolved_part_id"] == "frame" and frame["external_ref"] == "parts/frames/Frame_A.didsa", "a file moved to a subfolder is found by its part id; its path is corrected (%s)" % frame["external_ref"])
	var bolt := _occ_of(composed, "root", "o-bolt")
	_check(bolt["resolved_part_id"] == "bolt" and bolt["external_ref"] == "parts/Bolt (renamed).didsa", "a renamed file is found by its part id")
	var seeded := _occ_of(composed, "root", "o-seeded")
	_check(seeded["resolved_part_id"] == "seeded" and seeded["external_ref"] == "moved/Seeded.didsa", "an older file's resolved_part_id finds its moved target")
	var relinked: Array = composed["relinked"]
	_check(relinked.size() == 3 and relinked.all(func(m) -> bool: return m["via"] == "id" and m["key"].begins_with("root/")), "the three are listed as found by id (%s)" % str(relinked.map(func(m): return m["path"])))
	_check(NativeCompose.unresolved_note(composed).contains("3 moved files found in new places") and NativeCompose.unresolved_note(composed).contains("Frame_A.didsa -> parts/frames/Frame_A.didsa"), "the status note says what moved (%s)" % NativeCompose.unresolved_note(composed))

	var leg := _review_of(composed, "o-leg")
	_check(leg.get("result") == "ask" and leg["candidates"].map(func(c): return c["path"]) == ["left/Leg.didsa", "right/Leg.didsa"] and _occ_of(composed, "root", "o-leg")["resolved_part_id"] == null,
		"two files with the part id: ask, both listed, nothing loaded")
	var plate := _review_of(composed, "o-plate")
	_check(plate.get("result") == "suggest" and plate["path_mismatch"] and plate["candidates"].map(func(c): return c["path"]) == ["Plate.didsa"] and _occ_of(composed, "root", "o-plate")["resolved_part_id"] == null,
		"a different part at the path is not loaded: a suggestion, the mismatch reported")
	var washer := _review_of(composed, "o-washer")
	_check(washer.get("result") == "suggest" and washer["candidates"].map(func(c): return c["path"]) == ["old/Washer.didsa"] and washer["ref_part_id"] == "",
		"an older reference (no id) with only a same-name file elsewhere: a suggestion, never loaded")
	var gone := _review_of(composed, "o-gone")
	_check(gone.get("result") == "missing" and gone["candidates"].is_empty(), "nothing with the id or the name: missing")
	var notes: Array = composed["unresolved"]
	_check(notes.size() == 4 and notes.has("Gone.didsa (not found)") and notes.any(func(n) -> bool: return n.begins_with("Leg.didsa (moved; 2 copies")), "the four are unresolved, each saying why (%s)" % str(notes))
	_check(composed["bases"] == [DIR], "the folders searched are reported (%s)" % str(composed["bases"]))

	# The user's picks: a copy for the leg, the same-name washer anyway; a file outside the searched folders is refused.
	var picks := {"root/o-leg": DIR.path_join("right/Leg.didsa"), "root/o-washer": DIR.path_join("old/Washer.didsa"), "root/o-gone": "user://elsewhere/Gone.didsa"}
	var picked := NativeCompose.compose(root_path, [], picks)
	var leg_occ := _occ_of(picked, "root", "o-leg")
	_check(leg_occ["resolved_part_id"] == "leg" and leg_occ["external_ref"] == "right/Leg.didsa", "a picked copy is used, its path written")
	_check(_occ_of(picked, "root", "o-washer")["resolved_part_id"] == "washer-somewhere", "a picked same-name file is used (the user said so)")
	_check(picked["relinked"].filter(func(m) -> bool: return m["via"] == "choice").size() == 2 and picked["resolved"] == 5, "both are listed as picked by the user")
	_check(_occ_of(picked, "root", "o-gone")["resolved_part_id"] == null and picked["unresolved"].has("Gone.didsa (the chosen file is not in the project folder)"), "a pick outside the searched folders is refused")

	# An older reference whose file is still at its path loads it, as before (no index built, nothing listed).
	var plain_path := _write("Plain.didsa", _part("plain", [_occ("o-frame", "parts/frames/Frame_A.didsa"), _occ("o-plate", "Plate.didsa")]))
	var plain := NativeCompose.compose(plain_path)
	_check(plain["resolved"] == 2 and plain["relinked"].is_empty() and plain["review"].is_empty(), "references with no id found at their path load as before")

	# The index: every subfolder, dot-folders skipped, each file once (under the first folder that holds it), with its part id.
	var index := FileIndex.build([DIR, DIR.path_join("parts")])
	var paths := index.map(func(e): return e["path"])
	_check(paths.has("parts/frames/Frame_A.didsa") and paths.has("left/Leg.didsa") and not paths.has("frames/Frame_A.didsa") and not paths.any(func(p) -> bool: return p.begins_with(".hidden")),
		"the index walks every subfolder, skips dot-folders and lists each file once (%d files)" % paths.size())
	_check(index.any(func(e) -> bool: return e["path"] == "Plate.didsa" and e["part_id"] == "not-the-plate"), "...with each file's root Part id")
	_check(FileIndex.relative_to(DIR.path_join("a/b.didsa"), [DIR]) == "a/b.didsa" and FileIndex.relative_to("user://other/b.didsa", [DIR]) == "", "a file outside the folders has no reference path")

	# Files > References, against a stand-in for main.gd.
	var fake := FakeMain.new()
	fake.review = {"root": root_path, "relinked": composed["relinked"], "review": composed["review"], "bases": composed["bases"]}
	fake.files = index
	var pages := TabletPages.new()
	pages.setup({"main": fake}, null, null)
	var rows: Array = pages._references_rows()
	var by_id := {}
	for r in rows:
		by_id[r["id"]] = r
	_check(by_id.has("moved:root/o-frame") and by_id["moved:root/o-frame"]["state"] == "ok" and by_id["moved:root/o-frame"]["title"] == "Frame_A.didsa -> parts/frames/Frame_A.didsa",
		"a file found in a new place is listed as moved")
	var leg_row: Dictionary = by_id.get("ref:root/o-leg", {})
	_check(leg_row.get("state") == "warn" and leg_row["actions"].map(func(a): return a["label"]) == ["Locate...", "Leave missing"], "a reference to review has Locate... and Leave missing")
	var same: Dictionary = by_id.get("use:root/o-leg:%s" % DIR.path_join("left/Leg.didsa"), {})
	_check(not same.is_empty() and not same["actions"][0]["confirm"] and same["subtitle"] == "The placed part.", "a copy that is the placed part is used with one press")
	var other: Dictionary = by_id.get("use:root/o-plate:%s" % DIR.path_join("Plate.didsa"), {})
	_check(not other.is_empty() and other["actions"][0]["confirm"] and other["state"] == "warn", "a different part needs a second press (never a silent swap)")
	_check(by_id.get("ref:root/o-gone", {}).get("state") == "error", "a missing file is listed as an error")
	(same["actions"][0]["callback"] as Callable).call()
	_check(fake.chosen == [["root/o-leg", DIR.path_join("left/Leg.didsa")]], "Use passes the pick to main")
	(by_id["ref:root/o-gone"]["actions"][1]["callback"] as Callable).call()
	_check(fake.left == ["root/o-gone"], "Leave missing passes the key to main")
	(by_id["ref:root/o-gone"]["actions"][0]["callback"] as Callable).call()
	var locate: Array = pages._references_rows()
	_check(locate[0]["id"] == "locate" and locate.size() == index.size() + 1 and pages._references_status().begins_with("Locate the file for Gone.didsa"), "Locate... lists every model file in the searched folders")
	_check(locate.slice(1).all(func(r) -> bool: return r["actions"][0]["confirm"]), "...every one of them a different part, so each needs a second press")
	(locate[0]["actions"][0]["callback"] as Callable).call()
	_check(pages._references_rows()[0]["id"] != "locate", "Cancel goes back to the review list")

	fake.free()
	_remove_tree(DIR)
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
