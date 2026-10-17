extends "res://scripts/mates_tool.gd"
## mates_tool.gd with its backend swapped for a little in-memory document (occurrences, mates, part names) and a record of every call made.
## Used by tests/nested_mates.gd. Not a test.

var doc_occurrences: Dictionary = {} ## Part id -> Array of OccurrenceResponse-shaped rows
var doc_mates: Dictionary = {} ## Part id -> Array of {id, references: [{occurrence_id}], suppressed}
var doc_names: Dictionary = {} ## Part id -> name
var solve_moves: Dictionary = {} ## "part|occurrence" -> the transform json a /solve stores for it
var solve_fails: Dictionary = {} ## "part|occurrence" -> the 422 detail a /solve answers with
var calls: Array = [] ## [{method, path}] in order


static func row(id: String, resolved: Variant, fixed: bool = false, translation: Array = [0.0, 0.0, 0.0], angle: float = 0.0) -> Dictionary:
	return {"id": id, "resolved_part_id": resolved, "name_override": null, "suppressed": false, "hidden": false, "fixed": fixed,
		"transform": {"translation": translation, "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": angle}}


func solves() -> Array:
	return calls.filter(func(c: Dictionary) -> bool: return c["method"] == HTTPClient.METHOD_POST and str(c["path"]).ends_with("/solve")).map(
		func(c: Dictionary) -> String: return str(c["path"]))


func _api_request(method: int, path: String, _body_dict) -> Dictionary:
	calls.append({"method": method, "path": path})
	var parts := path.split("?")[0].split("/", false) # parts, <id>, occurrences|mates, <occ>, solve
	if parts.size() < 2 or parts[0] != "parts":
		return {"ok": false, "code": 404, "json": {"detail": "Not Found"}, "error": "404"}
	var pid := parts[1]
	if parts.size() == 2 and method == HTTPClient.METHOD_GET:
		return {"ok": true, "code": 200, "json": {"id": pid, "name": doc_names.get(pid, "Part 1")}, "error": ""}
	if parts.size() == 3 and parts[2] == "occurrences" and method == HTTPClient.METHOD_GET:
		return {"ok": true, "code": 200, "json": (doc_occurrences.get(pid, []) as Array).duplicate(true), "error": ""}
	if parts.size() == 3 and parts[2] == "mates" and method == HTTPClient.METHOD_GET:
		return {"ok": true, "code": 200, "json": (doc_mates.get(pid, []) as Array).duplicate(true), "error": ""}
	if parts.size() == 5 and parts[2] == "occurrences" and parts[4] == "solve" and method == HTTPClient.METHOD_POST:
		var key := "%s|%s" % [pid, parts[3]]
		if solve_fails.has(key):
			return {"ok": false, "code": 422, "json": {"detail": solve_fails[key]}, "error": "422"}
		for r in doc_occurrences.get(pid, []):
			if str(r["id"]) == parts[3]:
				if solve_moves.has(key):
					r["transform"] = solve_moves[key]
				return {"ok": true, "code": 200, "json": r.duplicate(true), "error": ""}
		return {"ok": false, "code": 404, "json": {"detail": "Occurrence not found"}, "error": "404"}
	if parts.size() == 4 and parts[2] == "occurrences" and method == HTTPClient.METHOD_PATCH:
		return {"ok": true, "code": 200, "json": {}, "error": ""}
	return {"ok": false, "code": 404, "json": {"detail": "Not Found"}, "error": "404"}
