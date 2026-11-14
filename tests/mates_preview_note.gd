extends SceneTree
## V-4 (docs/vr-feedback-2026-11-11-plan.md), the "why is there no ghost" note, no backend (a fake answers the preview): a preview that comes back `converged: false`,
## a refused request, a converged answer naming a part that is not on screen, and a fixed driven part each leave a note ("No preview: ..."), shown by status_text() in place
## of "Ready - choose a mate type and Create"; a converged answer with its part on screen draws the ghost and leaves no note; the note goes with the picks. Each case also
## prints a "DIDSA VR: preview:" line (the logcat line the owner sends back). NOT covered: the real backend's timing, the stale pose (the V-4 fix, not in this PR).
## Run: "$GODOT" --headless --path . --script res://tests/mates_preview_note.gd  (see tests/README.md)

const MatesTool := preload("res://scripts/mates_tool.gd")


class FakePreviewTool extends "res://scripts/mates_tool.gd":
	var answer := {}
	var ok := true

	func _api_request(_method: int, path: String, _body) -> Dictionary:
		if path.contains("preview-mate-solve"):
			if not ok:
				return {"ok": false, "code": 422, "json": {"detail": {"type": "mate_solve_did_not_converge"}}, "error": "422"}
			return {"ok": true, "code": 200, "json": answer, "error": ""}
		return {"ok": false, "code": 404, "json": {}, "error": "404"}


func _part(owner: String, occurrence: String, name: String) -> Node3D:
	var part := Node3D.new()
	part.name = name
	part.set_meta("owner_part_id", owner)
	part.set_meta("occurrence_id", occurrence)
	part.set_meta("face_ids", [0])
	part.set_meta("body_ids", ["b"])
	part.set_meta("topology", {"b": {"face_kinds": ["plane"], "edge_kinds": {}}})
	part.add_to_group("grabbable_parts")
	return part


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _pose() -> Dictionary:
	return {"translation": [0, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0}


func _initialize() -> void:
	var a := _part("root", "occ-a", "A")
	var b := _part("root", "occ-b", "B")
	root.add_child(a)
	root.add_child(b)
	var tool := FakePreviewTool.new()
	root.add_child(tool)
	await process_frame
	tool.backend_url = "http://example.invalid"
	tool.set_active(true)
	tool.mate_type = "coincident"

	tool.answer = {"converged": false}
	tool.try_pick(a, 0)
	tool.try_pick(b, 0)
	await _frames(10)
	print("SMOKE converged:false leaves a note instead of Ready: ", not tool.preview_visible() and tool._preview_note.begins_with("No preview:") and tool.status_text() == tool._preview_note and not tool.status_text().begins_with("Ready"))
	print("SMOKE ...it says the solver found no placement and why it can't say more: ", tool.status_text().contains("found no placement"))

	tool.answer = {"converged": false, "reason": "mate_value_required"}
	tool.request_preview()
	await _frames(10)
	print("SMOKE ...a `reason` from the backend (when it gives one) is quoted: ", tool.status_text().contains("mate_value_required"))

	tool.ok = false
	tool.request_preview()
	await _frames(10)
	print("SMOKE a refused request says the backend refused, in friendly words: ", tool.status_text().begins_with("No preview: the backend refused the preview") and tool.status_text().contains("can't all be satisfied"))
	tool.ok = true

	tool.answer = {"converged": true, "transform": _pose(), "members": [{"occurrence_id": "occ-gone", "transform": _pose()}]}
	tool.request_preview()
	await _frames(10)
	print("SMOKE a converged answer naming a part that is not on screen says so: ", not tool.preview_visible() and tool.status_text().contains("not on screen") and tool.status_text().contains("occ-gone"))

	tool.answer = {"converged": true, "transform": _pose(), "members": [{"occurrence_id": "occ-b", "transform": _pose()}]}
	tool.request_preview()
	await _frames(10)
	print("SMOKE a converged answer with its part on screen draws the ghost and leaves no note: ", tool.preview_visible() and tool._preview_note == "" and (tool.status_text().begins_with("Preview shown in blue") or tool.status_text().begins_with("Preview: the part has moved")))

	tool.answer = {"converged": true, "members": []}
	tool.request_preview()
	await _frames(10)
	print("SMOKE a converged answer that moves nothing says so: ", tool.status_text().contains("moved nothing"))

	# M2: `budget_exhausted` (M1.1: the preview ran out of its time budget; an older backend omits it = false) is shown as a note after what the status already says
	var note: String = MatesTool.BUDGET_NOTE
	print("SMOKE the note is the agreed sentence: ", note == "Search stopped early: there may be more solutions.")
	tool.answer = {"converged": true, "transform": _pose(), "members": [{"occurrence_id": "occ-b", "transform": _pose()}], "budget_exhausted": true}
	tool.request_preview()
	await _frames(10)
	print("SMOKE budget_exhausted: true with a ghost says so after the usual line, not instead of it: ", tool.preview_budget_exhausted and tool.preview_visible() and (tool.status_text().begins_with("Preview shown in blue") or tool.status_text().begins_with("Preview: the part has moved")) and tool.status_text().ends_with(note))
	tool.answer = {"converged": true, "transform": _pose(), "members": [{"occurrence_id": "occ-b", "transform": _pose()}], "budget_exhausted": false}
	tool.request_preview()
	await _frames(10)
	print("SMOKE a budget_exhausted of false adds nothing: ", not tool.preview_budget_exhausted and not tool.status_text().contains("Search stopped"))
	tool.answer = {"converged": true, "transform": _pose(), "members": [{"occurrence_id": "occ-b", "transform": _pose()}]}
	tool.request_preview()
	await _frames(10)
	print("SMOKE an older backend without the field reads as false: ", not tool.preview_budget_exhausted and not tool.status_text().contains("Search stopped"))
	tool.answer = {"converged": false, "conflicting": ["m2"], "budget_exhausted": true}
	tool.mates = [{"id": "m2", "type": "distance"}]
	tool.request_preview()
	await _frames(10)
	print("SMOKE ...also with a conflict sentence (the note comes after it): ", tool.status_text().contains("conflicts with an earlier mate") and tool.status_text().ends_with(note), " | ", tool.status_text())
	tool.answer = {"converged": false, "budget_exhausted": true}
	tool.mates = []
	tool.request_preview()
	await _frames(10)
	print("SMOKE ...and with no placement (the reason, then the note): ", tool.status_text().begins_with("No preview:") and tool.status_text().ends_with(note))
	tool.ok = false
	tool.request_preview()
	await _frames(10)
	print("SMOKE a refused request clears the flag (nothing was searched): ", not tool.preview_budget_exhausted and not tool.status_text().contains("Search stopped"))
	tool.ok = true
	tool.answer = {"converged": true, "transform": _pose(), "members": [{"occurrence_id": "occ-b", "transform": _pose()}], "budget_exhausted": true}
	tool.request_preview()
	await _frames(10)
	tool.clear_picks()
	print("SMOKE clearing the picks clears the flag and the note: ", not tool.preview_budget_exhausted and not tool.status_text().contains("Search stopped"))

	tool.clear_picks()
	print("SMOKE clearing the picks clears the note: ", tool._preview_note == "")
	quit(0)
