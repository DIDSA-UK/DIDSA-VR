extends SceneTree
## M3 (DIDSA-CAD plan mates-storage-sessions-plan-2026-11-12.md): the glide preview, no backend (a fake answers). The REAL part moves from its stored pose to the
## preview's pose (an outline stays at the start), a new preview glides from where it is, a failed or empty one sends it home, Clear / Cancel glide it back, Confirm
## keeps it there and PATCHes the STORED pose (never the previewed one) with the undo entry starting from the stored pose, and an EDIT of a stored mate is previewed the same way
## (Apply stores, Cancel puts it back). The glide's own time is not judged here: only that it reaches its target exactly. Feel is the owner's, on the headset.
## Run: "$GODOT" --headless --path . --script res://tests/mate_glide.gd  (see tests/README.md)

const MatesTool := preload("res://scripts/mates_tool.gd")


class FakeTool extends "res://scripts/mates_tool.gd":
	var answer := {}
	var requests: Array = []
	var stored := {} ## occurrence id -> transform json the fake backend holds

	func _api_request(method: int, path: String, body_dict) -> Dictionary:
		requests.append({"method": method, "path": path, "body": body_dict})
		if path.contains("preview-mate-solve"):
			return {"ok": true, "code": 200, "json": answer, "error": ""}
		if method == HTTPClient.METHOD_PATCH and path.contains("/occurrences/"):
			return {"ok": true, "code": 200, "json": {}, "error": ""}
		if (method == HTTPClient.METHOD_POST and path.contains("/mates")) or (method == HTTPClient.METHOD_PATCH and path.contains("/mates/")):
			for member in answer.get("members", []):
				stored[member["occurrence_id"]] = member["transform"] # the atomic solve stores what the preview showed
			return {"ok": true, "code": 200, "json": {}, "error": ""}
		if method == HTTPClient.METHOD_GET and path.ends_with("/occurrences"):
			var out: Array = []
			for id in stored:
				out.append({"id": id, "transform": stored[id]})
			return {"ok": true, "code": 200, "json": out, "error": ""}
		if method == HTTPClient.METHOD_GET and path.ends_with("/mates"):
			return {"ok": true, "code": 200, "json": mates, "error": ""}
		return {"ok": false, "code": 404, "json": {}, "error": "404"}


func _part(occurrence: String, at: Vector3) -> Node3D:
	var part := Node3D.new()
	part.name = occurrence
	part.transform = Transform3D(Basis.IDENTITY, at)
	part.set_meta("owner_part_id", "root")
	part.set_meta("occurrence_id", occurrence)
	part.set_meta("face_ids", [0])
	part.set_meta("body_ids", ["b"])
	part.set_meta("topology", {"b": {"face_kinds": ["plane"], "edge_kinds": {}}})
	part.add_to_group("grabbable_parts")
	return part


func _json(x: float) -> Dictionary:
	return {"translation": [x, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}


func _answer(members: Array) -> Dictionary:
	return {"converged": true, "transform": members[0]["transform"], "members": members}


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	var a := _part("occ-a", Vector3(0, 0, 0))
	var b := _part("occ-b", Vector3(5, 0, 0))
	root.add_child(a)
	root.add_child(b)
	var tool := FakeTool.new()
	root.add_child(tool)
	await process_frame
	tool.backend_url = "http://example.invalid"
	tool.set_active(true)
	tool.mate_type = "coincident"
	tool.preview_glide_s = 0.0 # at once, except where a test says otherwise
	tool.occurrences = {"occ-a": {"fixed": false}, "occ-b": {"fixed": false}}

	# --- start: the real part moves, an outline stays
	tool.answer = _answer([{"occurrence_id": "occ-b", "transform": _json(20)}])
	tool.try_pick(a, 0)
	tool.try_pick(b, 0)
	await _frames(8)
	print("SMOKE the preview moves the REAL part to the previewed pose: ", absf(b.transform.origin.x - 20.0) < 1e-9 and tool.preview_visible())
	print("SMOKE ...its stored pose is still where it started, an outline (not a second part) stays there: ", absf(tool.stored_pose(b).origin.x - 5.0) < 1e-9 and tool._glide_outlines.size() == 1 and tool._glide_outlines[0].transform.origin.x == 5.0 and tool._ghosts.is_empty())
	print("SMOKE ...and the part not in the answer has not moved: ", a.transform.origin.x == 0.0)

	# --- replace: a new preview glides from where the part is; the start does not change
	tool.answer = _answer([{"occurrence_id": "occ-b", "transform": _json(-7)}])
	tool.request_preview()
	await _frames(8)
	print("SMOKE a new preview takes the part to the new pose and keeps the ORIGINAL start (the backend still has it): ", absf(b.transform.origin.x + 7.0) < 1e-9 and absf(tool.stored_pose(b).origin.x - 5.0) < 1e-9 and tool._glide_outlines.size() == 1)
	var asked_from_stored: bool = true
	for r in tool.requests:
		if str(r["path"]).contains("preview-mate-solve") and r["body"].has("transform"):
			asked_from_stored = false # (a preview request carries no pose: the backend solves from what it has stored)
	print("SMOKE every preview asks the backend from the stored poses (no pose is sent): ", asked_from_stored)

	# --- a different set of moved parts: the one no longer moved goes home, the other glides
	tool.answer = _answer([{"occurrence_id": "occ-a", "transform": _json(3)}])
	tool.request_preview()
	await _frames(8)
	print("SMOKE when another part is the one moved, the first returns to its start and the other glides: ", absf(b.transform.origin.x - 5.0) < 1e-9 and absf(a.transform.origin.x - 3.0) < 1e-9 and tool._glide_outlines.size() == 1)

	# --- a failed / empty preview leaves every part at its start
	tool.answer = {"converged": false}
	tool.request_preview()
	await _frames(8)
	print("SMOKE a preview that does not converge sends every part home and shows no outline: ", absf(a.transform.origin.x) < 1e-9 and absf(b.transform.origin.x - 5.0) < 1e-9 and not tool.preview_visible() and tool._glide_outlines.is_empty())
	tool.answer = {"converged": true, "members": []}
	tool.request_preview()
	await _frames(8)
	print("SMOKE ...and so does one that moves nothing: ", a.transform.origin.x == 0.0 and b.transform.origin.x == 5.0 and not tool.preview_visible())

	# --- the glide takes time and ends exactly there (feel is judged on the headset)
	tool.preview_glide_s = 0.2
	tool.answer = _answer([{"occurrence_id": "occ-b", "transform": _json(25)}])
	tool.request_preview()
	await _frames(3)
	var mid: float = b.transform.origin.x
	await create_timer(0.5).timeout
	print("SMOKE with a glide time the part is between its start and its target on the way (", snappedf(mid, 0.01), ") and exactly on the target at the end: ", mid > 5.0 and mid < 25.0 and absf(b.transform.origin.x - 25.0) < 1e-9)
	tool.clear_picks() # Cancel: it glides back
	await create_timer(0.5).timeout
	print("SMOKE Clear picks (Cancel) glides the part back to exactly its start, the outline goes: ", absf(b.transform.origin.x - 5.0) < 1e-9 and not tool.preview_visible() and tool._glide_outlines.is_empty())
	tool.preview_glide_s = 0.0

	# --- couplers and limits place nothing: no glide
	tool.mate_type = "gear"
	tool.try_pick(a, 0)
	tool.try_pick(b, 0)
	tool.answer = _answer([{"occurrence_id": "occ-b", "transform": _json(99)}])
	tool.request_preview()
	await _frames(8)
	print("SMOKE a coupler (or limit) preview moves nothing: ", b.transform.origin.x == 5.0 and not tool.preview_visible())
	tool.clear_picks()
	tool.mate_type = "coincident"

	# --- Confirm: the parts stay, the STORED pose is PATCHed, the undo entry starts from the stored pose
	tool.command_stack = preload("res://scripts/command_stack.gd").new() if ResourceLoader.exists("res://scripts/command_stack.gd") else null
	tool.try_pick(a, 0)
	tool.try_pick(b, 0)
	tool.answer = _answer([{"occurrence_id": "occ-b", "transform": _json(20)}])
	tool.request_preview()
	await _frames(8)
	tool.requests.clear()
	var created: Dictionary = await tool.create_mate()
	var patched_x := -999.0
	for r in tool.requests:
		if r["method"] == HTTPClient.METHOD_PATCH and str(r["path"]).contains("/occurrences/occ-b"):
			patched_x = float(r["body"]["transform"]["translation"][0])
	print("SMOKE Confirm PATCHes the STORED pose (5), not the previewed one (20): ", created["ok"] and absf(patched_x - 5.0) < 1e-6, " ", patched_x)
	print("SMOKE ...the part is already where the mate put it and nothing glides back: ", absf(b.transform.origin.x - 20.0) < 1e-9 and tool._glide_start.is_empty() and tool._glide_outlines.is_empty() and tool._commit_starts.is_empty())
	if tool.command_stack != null:
		tool.command_stack.undo()
		print("SMOKE ...and Undo puts the part back at its STORED start (5), not at the previewed pose: ", absf(b.transform.origin.x - 5.0) < 1e-9)
		tool.command_stack.redo()
	b.transform = Transform3D(Basis.IDENTITY, Vector3(5, 0, 0))
	tool.stored = {}

	# --- editing a stored mate: previewed (the part glides), Apply stores, Cancel puts it back
	tool.mates = [{"id": "m1", "type": "distance", "value": 4.0, "allow_rotation": true, "alignment": "aligned", "secondary_flip": false,
		"references": [{"occurrence_id": "occ-a", "subshape_ref": {"body_id": "b", "shape_type": "face", "index": 0}}, {"occurrence_id": "occ-b", "subshape_ref": {"body_id": "b", "shape_type": "face", "index": 1}}]}]
	print("SMOKE a flip or a value of a distance mate can be previewed; a suppress, a coupler or a limit cannot: ", tool.can_preview_edit("m1", {"secondary_flip": true}) and tool.can_preview_edit("m1", {"value": 6.0}) and not tool.can_preview_edit("m1", {"suppressed": true}) and not tool.can_preview_edit("nope", {"value": 1.0}))
	var body := MatesTool.edit_payload(tool.mates[0], {"secondary_flip": true, "value": 6.0})
	print("SMOKE the preview body is the stored mate with the edit applied: ", body["type"] == "distance" and body["value"] == 6.0 and body["secondary_flip"] == true and body["alignment"] == "aligned" and body["references"].size() == 2)
	tool.answer = _answer([{"occurrence_id": "occ-b", "transform": _json(30)}])
	tool.requests.clear()
	var edit: Dictionary = await tool.preview_edit("root", "m1", {"value": 6.0})
	await _frames(4)
	var preview_path := ""
	for r in tool.requests:
		if str(r["path"]).contains("preview-mate-solve"):
			preview_path = str(r["path"])
	print("SMOKE an edit is previewed with replace_mate_id (the stored mate left out of the solve) on the driven part: ", edit["ok"] and preview_path.contains("replace_mate_id=m1") and preview_path.contains("/occurrences/occ-b/"), " ", preview_path)
	print("SMOKE ...the part has glided to show it, an Apply / Cancel state is pending with its sentence: ", absf(b.transform.origin.x - 30.0) < 1e-9 and tool.edit_preview_pending() and tool.edit_preview_text().contains("Apply"))
	tool.cancel_edit_preview()
	await _frames(4)
	print("SMOKE Cancel glides it back and stores nothing: ", absf(b.transform.origin.x - 5.0) < 1e-9 and not tool.edit_preview_pending() and not tool.requests.any(func(r: Dictionary) -> bool: return r["method"] == HTTPClient.METHOD_PATCH and str(r["path"]).contains("/mates/")))
	await tool.preview_edit("root", "m1", {"value": 6.0})
	tool.requests.clear()
	var applied: Dictionary = await tool.confirm_edit_preview()
	var patched_mate := false
	var patched_pose := -999.0
	for r in tool.requests:
		if r["method"] == HTTPClient.METHOD_PATCH and str(r["path"]).contains("/mates/m1"):
			patched_mate = r["body"].get("value") == 6.0
		if r["method"] == HTTPClient.METHOD_PATCH and str(r["path"]).contains("/occurrences/occ-b"):
			patched_pose = float(r["body"]["transform"]["translation"][0])
	print("SMOKE Apply stores the edit from the STORED pose and the part stays: ", applied["ok"] and patched_mate and absf(patched_pose - 5.0) < 1e-6 and absf(b.transform.origin.x - 30.0) < 1e-9 and not tool.edit_preview_pending() and tool._glide_start.is_empty(), " ", patched_pose)
	b.transform = Transform3D(Basis.IDENTITY, Vector3(5, 0, 0))
	tool.answer = {"converged": false, "reason": "no way"}
	var refused: Dictionary = await tool.preview_edit("root", "m1", {"value": 600.0})
	print("SMOKE an edit that cannot be met says so, moves nothing and leaves no pending edit: ", not refused["ok"] and refused["error"] != "" and b.transform.origin.x == 5.0 and not tool.edit_preview_pending())

	for n in [a, b]:
		n.free()
	tool.free()
	quit()
