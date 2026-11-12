extends RefCounted
## An in-memory stand-in for the DIDSA-CAD routes appearance_tool.gd calls (`request(method, path, body)`, a coroutine returning
## {ok, code, json, error}, like design_table/cad_api.gd):
##   GET /document/parts/{id}                       {id, name, appearance, body_appearances, face_appearances}
##   GET /document/parts/{id}/occurrences           the occurrence rows
##   GET /document/parts/{id}/component-patterns    the pattern rows
##   GET/PUT /document/parts/{id}/appearance-overrides   the list; PUT sets / replaces / (appearance null) clears one target,
##       and mirrors a top-level occurrence's own colour into its row's `color`, as the backend does.
## `parts`: {id: {name, appearance?, body_appearances?, occurrences: [rows], patterns: [rows], overrides: [records]}}.
##   GET/POST /document/parts/{id}/scenes, PATCH/DELETE /document/parts/{id}/scenes/{scene id}   a Part's `scenes` (scenes_tool.gd):
##       POST mints the id; PATCH replaces each field it is given.
## Every call is recorded in `calls`; set `fail_puts` to make every PUT a 422.

var parts: Dictionary = {}
var calls: Array = []
var fail_puts := false
var get_delay := 0 ## frames a GET's answer is held back AFTER it was computed (a slow network: the answer is stale when it arrives)


static func row(id: String, part_id: String, color: Variant = null) -> Dictionary:
	return {"id": id, "resolved_part_id": part_id, "suppressed": false, "hidden": false, "color": color}


func puts() -> Array:
	return calls.filter(func(c: Dictionary) -> bool: return c["method"] == HTTPClient.METHOD_PUT)


static func _key(r: Dictionary) -> String:
	var face = r.get("face")
	return str([str(r.get("path", "")), r.get("scope"), r.get("pattern_id"), r.get("part_id"), r.get("body_id"), int(face["index"]) if face is Dictionary else null])


func request(method: int, path: String, body = null) -> Dictionary:
	var answer: Dictionary = await _request_now(method, path, body)
	if method == HTTPClient.METHOD_GET:
		for i in get_delay:
			await Engine.get_main_loop().process_frame
	return answer


func _request_now(method: int, path: String, body = null) -> Dictionary:
	calls.append({"method": method, "path": path, "body": body})
	await Engine.get_main_loop().process_frame
	var bits := path.trim_prefix("/document/parts/").split("/")
	var pid := bits[0]
	if not parts.has(pid):
		return {"ok": false, "code": 404, "json": {"detail": "Part not found"}, "error": "404"}
	var part: Dictionary = parts[pid]
	if bits.size() == 1:
		return _ok({"id": pid, "name": part.get("name", pid), "appearance": part.get("appearance"),
			"body_appearances": part.get("body_appearances", {}), "face_appearances": part.get("face_appearances", [])})
	match bits[1]:
		"occurrences":
			return _ok(part.get("occurrences", []))
		"component-patterns":
			return _ok(part.get("patterns", []))
		"appearance-overrides":
			if method == HTTPClient.METHOD_PUT:
				if fail_puts:
					return {"ok": false, "code": 422, "json": {"detail": "refused"}, "error": "{\"detail\":\"refused\"}"}
				var record: Dictionary = (body as Dictionary).duplicate(true)
				var appearance = record.get("appearance")
				record.erase("appearance")
				var list: Array = (part.get("overrides", []) as Array).filter(func(r) -> bool: return _key(r) != _key(record))
				if appearance != null:
					record["appearance"] = appearance
					list.append(record)
				part["overrides"] = list
				var p := str(record.get("path", ""))
				if p != "" and not p.contains("/") and not p.contains("#") and record.get("scope") == null and record.get("body_id") == null and record.get("face") == null:
					for occ in part.get("occurrences", []):
						if occ["id"] == p:
							if appearance == null:
								occ["color"] = null
							elif (appearance as Dictionary).has("colour"):
								occ["color"] = appearance["colour"]
			return _ok({"overrides": (part.get("overrides", []) as Array).map(func(r) -> Dictionary:
				var out := (r as Dictionary).duplicate(true)
				for k in ["scope", "pattern_id", "part_id", "body_id", "face"]:
					if not out.has(k):
						out[k] = null
				out["legacy"] = false
				out["unresolved"] = null
				out["face_current_index"] = int(r["face"]["index"]) if r.get("face") is Dictionary else null
				return out)})
		"scenes":
			var scenes: Array = part.get("scenes", [])
			part["scenes"] = scenes
			if bits.size() == 2 and method == HTTPClient.METHOD_GET:
				return _ok(scenes.duplicate(true))
			if bits.size() == 2 and method == HTTPClient.METHOD_POST:
				var scene := {"id": "scene-%d" % (scenes.size() + 1), "name": str(body.get("name", "")), "overrides": (body.get("overrides", []) as Array).duplicate(true),
					"section_planes": body.get("section_planes", []), "viewpoint": body.get("viewpoint"), "unresolved": []}
				scenes.append(scene)
				return {"ok": true, "code": 201, "json": scene.duplicate(true), "error": ""}
			for scene in scenes:
				if bits.size() == 3 and scene["id"] == bits[2]:
					if method == HTTPClient.METHOD_DELETE:
						scenes.erase(scene)
						return {"ok": true, "code": 204, "json": null, "error": ""}
					if method == HTTPClient.METHOD_PATCH:
						for k in body:
							scene[k] = body[k]
						return _ok(scene.duplicate(true))
					return _ok(scene.duplicate(true))
			return {"ok": false, "code": 404, "json": {"detail": "Scene not found"}, "error": "404"}
	return {"ok": false, "code": 404, "json": null, "error": "no route"}


static func _ok(json) -> Dictionary:
	return {"ok": true, "code": 200, "json": json, "error": ""}
