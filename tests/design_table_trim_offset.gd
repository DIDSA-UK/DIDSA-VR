extends SceneTree
## TRIM and OFFSET sketch tools (Phase 6.5), fake backend. Trim: the laser picks a line, circle or arc (nothing else); a tap on a line tries split-trim at the tap
## and, when the backend says there is nothing to cut between, trims the NEARER end instead; a circle is cut at the tap; an arc's nearer end moves; a refusal says why;
## the status admits it can't be undone. Offset: a distance and Reverse in the panel; a pick on a line or arc posts the signed distance and the copy is ONE step
## on Undo (it deletes the new line); a circle is refused.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_trim_offset.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	await rig.draw_rectangle()
	var s = ed.session
	var line_id: String = s.lines.keys()[0]
	var l: Dictionary = s.lines[line_id]
	var a: Vector2 = s.points[l["a"]]
	var b: Vector2 = s.points[l["b"]]
	var near_b: Vector2 = a.lerp(b, 0.8)
	table.manager.activate("trim")
	await rig.frames(3)
	print("SMOKE Trim is on the Sketch row and the session takes it as a tool: ", s.tool == "trim" and preload("res://scripts/design_table/table_tools.gd").SKETCH_TOOLS.any(func(t): return t[0] == "trim") and preload("res://scripts/design_table/table_tools.gd").SKETCH_TOOLS.any(func(t): return t[0] == "offset"))
	var r: Dictionary = await s.trim_at({"kind": "line", "id": line_id}, a.lerp(b, 0.5))
	var calls: Array = rig.calls_to("/lines/%s/" % line_id)
	print("SMOKE a tap on a line tries split-trim at the tap first (click position sent): ", r["ok"] and calls.size() == 1 and String(calls[0][0]).ends_with("/split-trim") and absf(float(calls[0][1]["click_x"]) - a.lerp(b, 0.5).x) < 0.001)
	print("SMOKE ...and says Trim can't be undone, taking no Undo step: ", table.status().contains("can't be undone") or String(r["message"]).contains("can't be undone"))
	fake.split_trim_fails = true
	fake.calls.clear()
	r = await s.trim_at({"kind": "line", "id": line_id}, near_b)
	calls = rig.calls_to("/lines/%s/" % line_id)
	print("SMOKE when split-trim finds nothing to cut it trims the NEARER end (the one at 80% along): ", r["ok"] and calls.size() == 2 and String(calls[1][0]).ends_with("/trim") and calls[1][1]["moved_point_id"] == l["b"], " ", calls)
	fake.split_trim_fails = false
	fake.trim_fails = true
	fake.split_trim_fails = true
	r = await s.trim_at({"kind": "line", "id": line_id}, a.lerp(b, 0.5))
	print("SMOKE with nothing to trim to it says so in words: ", not r["ok"] and String(r["message"]).contains("nothing to trim"), " ", r["message"])
	fake.trim_fails = false
	fake.split_trim_fails = false
	r = await s.trim_at({"kind": "point", "id": "x"}, Vector2.ZERO)
	print("SMOKE a point is not trimmable: ", not r["ok"] and String(r["message"]).contains("line, circle or arc"))
	s.circles["c1"] = {"c": l["a"], "p": l["b"], "k": "", "construction": false}
	fake.calls.clear()
	r = await s.trim_at({"kind": "circle", "id": "c1"}, Vector2(3, 4))
	print("SMOKE a circle is cut at the tap (POST .../circles/c1/trim with the click): ", r["ok"] and rig.calls_to("/circles/c1/trim").size() == 1 and rig.calls_to("/circles/c1/trim")[0][1] == {"click_x": 3.0, "click_y": 4.0})
	s.arcs["a1"] = {"c": l["a"], "s": l["a"], "e": l["b"], "k": "", "construction": false}
	fake.calls.clear()
	r = await s.trim_at({"kind": "arc", "id": "a1"}, b)
	print("SMOKE an arc's nearer end moves (the end near the tap): ", r["ok"] and rig.calls_to("/arcs/a1/trim")[0][1]["moved_point_id"] == l["b"])
	# the laser: only lines / circles / arcs are offered to Trim
	print("SMOKE the laser picks lines, circles and arcs for Trim and lines and arcs for Offset: ", ed.EDIT_TOOLS == ["trim", "offset"])

	# --- Offset
	table.manager.activate("offset")
	await rig.frames(3)
	print("SMOKE Offset's panel shows Distance and Reverse: ", table.props.option_ids() == ["offset_dist", "offset_flip"])
	ed.option_typed("offset_dist", "7")
	await ed.on_option("offset_flip")
	fake.calls.clear()
	var done: Dictionary = await s.offset_entity({"kind": "line", "id": line_id}, 7.0 * -1.0)
	var off: Array = rig.calls_to("/lines/%s/offset" % line_id)
	print("SMOKE a pick on a line posts the offset with the signed distance (Reverse makes it negative): ", done["ok"] and off.size() == 1 and off[0][1] == {"distance": -7.0, "construction": false}, " ", off)
	print("SMOKE ...it is one step on Undo and Undo deletes the new line: ", s.can_undo() and s.undo_label() == "offset")
	fake.calls.clear()
	await s.undo()
	print("SMOKE ...(the delete)", not rig.calls_to("DELETE").is_empty() and String(rig.calls_to("DELETE")[0][0]).contains("/lines/off"), " ", rig.calls_to("DELETE").map(func(c): return c[0]))
	done = await s.offset_entity({"kind": "circle", "id": "c1"}, 3.0)
	print("SMOKE a circle is refused for Offset, saying so: ", not done["ok"] and String(done["message"]).contains("line or an arc"))
	done = await s.offset_entity({"kind": "line", "id": line_id}, 0.0)
	print("SMOKE a zero distance is refused: ", not done["ok"])
	quit()
