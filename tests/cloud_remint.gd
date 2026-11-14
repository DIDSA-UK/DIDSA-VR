extends SceneTree
## S3: the GDScript twin of DIDSA-CAD's remint_identity.dart (scripts/cloud/cloud_remint.gd), which "Save mine as a copy" uses so the copy never shares a Part id with the
## file it came from. Same cases as the Dart tests: a fresh document id, Part id and sketch id, every reference following (a string VALUE equal to an old id, wherever it is),
## object KEYS left alone, feature / entity ids (scoped to their Part) kept, a non-native file returned as it was, and every number written back exactly as it was read.
## NOT covered: the flat app's own copy (its tests are in DIDSA-CAD).
## Run: "$GODOT" --headless --path . --script res://tests/cloud_remint.gd  (see tests/README.md)

const CloudRemint := preload("res://scripts/cloud/cloud_remint.gd")


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _initialize() -> void:
	var text := '{"schema_version": 1, "document": {"id": "doc-1", "root_part_id": "part-a", "parts": [{"id": "part-a", "name": "A", "features": [{"id": "feat-1", "sketch_id": "sk-1", "depth": 20.0, "count": 0}], "occurrences": [{"id": "occ-1", "resolved_part_id": "part-b", "external_ref": "B.didsa", "transform": {"translation": [0, 0.5, 1e-05]}}]}, {"id": "part-b", "name": "B", "occurrences": []}], "by_part": {"part-a": "keyed by a part id"}}, "sketches": [{"id": "sk-1", "entities": [{"id": "e1"}]}], "hidden_feature_ids": ["feat-1"]}'
	var counter := [0]
	var out := CloudRemint.remint_text(text, func() -> String:
		counter[0] += 1
		return "new-%d" % counter[0])
	var doc: Dictionary = JSON.parse_string(out)
	var part_a: Dictionary = doc["document"]["parts"][0]
	var part_b: Dictionary = doc["document"]["parts"][1]
	_check(doc["document"]["id"] != "doc-1" and part_a["id"] != "part-a" and part_b["id"] != "part-b" and doc["sketches"][0]["id"] != "sk-1", "the document id, every Part id and every sketch id are new")
	_check(doc["document"]["root_part_id"] == part_a["id"] and part_a["occurrences"][0]["resolved_part_id"] == part_b["id"] and part_a["features"][0]["sketch_id"] == doc["sketches"][0]["id"], "...and every reference to one of them followed (root_part_id, resolved_part_id, sketch_id)")
	_check(part_a["features"][0]["id"] == "feat-1" and doc["sketches"][0]["entities"][0]["id"] == "e1" and part_a["occurrences"][0]["id"] == "occ-1" and doc["hidden_feature_ids"] == ["feat-1"], "feature, entity and occurrence ids (scoped to their Part or sketch) are kept, and so are keys the backend does not know")
	_check(doc["document"]["by_part"].has("part-a") and not doc["document"]["by_part"].has(part_a["id"]), "an object KEY equal to an old id is left alone")
	_check(out.contains('"depth":20.0') and out.contains('"count":0}') and out.contains('1e-05') and out.contains('"translation":[0,0.5,1e-05]'), "numbers come back exactly as written (20.0 stays 20.0, 0 stays 0, 1e-05 stays 1e-05)")
	_check(out.contains('"external_ref":"B.didsa"') and out.contains('"name":"A"'), "...and nothing else in the file changed")
	var again := CloudRemint.remint_text(text)
	var doc2: Dictionary = JSON.parse_string(again)
	_check(doc2["document"]["id"] != doc["document"]["id"] and doc2["document"]["root_part_id"] != doc["document"]["root_part_id"], "with no generator, real random ids are made, different every time")
	var uuid := CloudRemint.new_uuid()
	var parts := uuid.split("-")
	_check(parts.size() == 5 and parts[0].length() == 8 and parts[2].begins_with("4") and uuid.length() == 36, "a made id is a version 4 UUID (%s)" % uuid)
	_check(CloudRemint.remint_text("not json at all") == "not json at all" and CloudRemint.remint_text('{"other": 1}') == '{"other": 1}', "a file that is not native is returned as it was")
	var bytes := "STEP-FILE-BYTES".to_utf8_buffer()
	_check(CloudRemint.remint_bytes(bytes) == bytes, "bytes that are not a native file come back identical")
	var ids := CloudRemint.collect_ids(JSON.parse_string(text))
	ids.sort()
	_check(ids == ["doc-1", "part-a", "part-b", "sk-1"], "the ids that are session-global are exactly the document, Part and sketch ids")
	quit(0)
