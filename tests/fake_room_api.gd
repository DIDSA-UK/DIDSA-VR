extends RefCounted
## A stand-in for design_table/cad_api.gd with just the routes room_edit.gd uses, backed by a little in-memory document, and a record of every call made.
## Used by tests/room_edit.gd and tests/room_drop.gd. Not a test.

var occurrences: Dictionary = {} ## owner Part id -> Array of OccurrenceResponse-shaped dictionaries
var unreadable: Array = [] ## owner Part ids whose occurrences read fails (a 500)
var mates: Dictionary = {} ## owner Part id -> Array of {references: [{occurrence_id}, ...]}
var names: Dictionary = {} ## Part id -> its name (GET /document/parts/{id})
var calls: Array = [] ## [{method, path, body}] in order
var glb := PackedByteArray() ## what fetch_bytes returns for any mesh path
var glb_by_part: Dictionary = {} ## Part id -> bytes, when a test needs different meshes
var fail_next_post := false
var next_added := 1


func row(id: String, resolved: String, fixed: bool = false) -> Dictionary:
	return {"id": id, "external_ref": null, "resolved_part_id": resolved, "name_override": null,
		"transform": {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0},
		"suppressed": false, "hidden": false, "fixed": fixed, "color": null}


func count(method: int, fragment: String) -> int:
	var n := 0
	for c in calls:
		if c["method"] == method and str(c["path"]).contains(fragment):
			n += 1
	return n


func last(method: int, fragment: String) -> Dictionary:
	for i in range(calls.size() - 1, -1, -1):
		if calls[i]["method"] == method and str(calls[i]["path"]).contains(fragment):
			return calls[i]
	return {}


func request(method: int, path: String, body = null) -> Dictionary:
	calls.append({"method": method, "path": path, "body": body})
	if method == HTTPClient.METHOD_POST and path == "/document/parts": # a new, empty Part (New part, New room)
		var id := "new-part-%d" % next_added
		next_added += 1
		names[id] = str(body.get("name", ""))
		occurrences[id] = []
		return _ok({"id": id, "name": names[id]}, 201)
	var parts := path.trim_prefix("/document/parts/").split("/")
	var owner := parts[0]
	var tail := "/".join(parts.slice(1))
	if method == HTTPClient.METHOD_GET and tail == "" and names.has(owner):
		return _ok({"id": owner, "name": names[owner]})
	if method == HTTPClient.METHOD_GET and tail == "occurrences" and unreadable.has(owner):
		return {"ok": false, "code": 500, "json": null, "error": "boom"}
	if method == HTTPClient.METHOD_GET and tail == "occurrences":
		return _ok(occurrences.get(owner, []).duplicate(true))
	if method == HTTPClient.METHOD_GET and tail == "mates":
		return _ok(mates.get(owner, []))
	if method == HTTPClient.METHOD_POST and tail == "occurrences":
		if fail_next_post:
			fail_next_post = false
			return {"ok": false, "code": 500, "json": null, "error": "boom"}
		for r in occurrences.get(owner, []):
			if r["id"] == body["id"]:
				return {"ok": false, "code": 409, "json": null, "error": "Occurrence '%s' already exists" % body["id"]}
		var made := row(str(body["id"]), str(body.get("resolved_part_id", "")))
		for key in body:
			if body[key] != null:
				made[key] = body[key]
		var list: Array = occurrences.get(owner, [])
		list.append(made)
		occurrences[owner] = list
		return _ok(made, 201)
	if method == HTTPClient.METHOD_POST and tail == "add-component":
		var id := "added%d" % next_added
		next_added += 1
		var list2: Array = occurrences.get(owner, [])
		list2.append(row(id, "component-part", list2.is_empty())) # like the backend: the first occurrence put into an empty Part is grounded (fixed)
		occurrences[owner] = list2
		return _ok({"document_id": "d", "part_ids": ["component-part"], "occurrence_id": id})
	if method == HTTPClient.METHOD_PATCH and tail.begins_with("occurrences/"):
		var occ_id := tail.trim_prefix("occurrences/")
		for r in occurrences.get(owner, []):
			if r["id"] == occ_id:
				if body.has("transform") and bool(body.get("fixed", r.get("fixed", false))):
					return {"ok": false, "code": 422, "json": null, "error": "occurrence_is_fixed"} # like the backend: a fixed occurrence can't be moved
				for key in body:
					r[key] = body[key]
				return _ok(r)
		return {"ok": false, "code": 404, "json": null, "error": "no such occurrence"}
	if method == HTTPClient.METHOD_DELETE and tail.begins_with("occurrences/"):
		var del_id := tail.trim_prefix("occurrences/")
		var kept: Array = []
		var found := false
		for r in occurrences.get(owner, []):
			if r["id"] == del_id:
				found = true
			else:
				kept.append(r)
		occurrences[owner] = kept
		var remaining: Array = []
		for m in mates.get(owner, []):
			if not m["references"].any(func(ref): return ref["occurrence_id"] == del_id):
				remaining.append(m)
		mates[owner] = remaining
		return _ok(null, 204) if found else {"ok": false, "code": 404, "json": null, "error": "no such occurrence"}
	return {"ok": false, "code": 404, "json": null, "error": "unhandled route %s" % path}


func fetch_bytes(path: String) -> Dictionary:
	calls.append({"method": HTTPClient.METHOD_GET, "path": path, "body": null})
	var part := path.trim_prefix("/document/parts/").split("/")[0]
	var bytes: PackedByteArray = glb_by_part.get(part, glb)
	return {"ok": not bytes.is_empty(), "code": 200, "bytes": bytes, "error": ""}


func _ok(json, code: int = 200) -> Dictionary:
	return {"ok": true, "code": code, "json": json, "error": ""}
