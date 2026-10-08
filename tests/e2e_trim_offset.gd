extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): TRIM and OFFSET (Phase 6.5). A 40 x 40 square on XY and a line from (-10, 20) to (50, 20) crossing two of its sides:
## Trim on the part of the line between the sides (split-trim) leaves two pieces (one more line, none of the old long one); Offset of a square side by 5 adds one line, and
## Undo takes that line away again.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_trim_offset.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	var main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	var table = main.design_table
	table.configure_backend(main.backend_url, main.api_key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	var s = ed.session
	table.manager.activate("rectangle")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(40, 40)})
	table.manager.activate("line")
	await s.tap({"uv": Vector2(-10, 20)})
	await s.tap({"uv": Vector2(50, 20)})
	s.finish_chain()
	var long_line := ""
	for id in s.lines:
		var l: Dictionary = s.lines[id]
		if absf(s.points[l["a"]].y - 20.0) < 0.01 and absf(s.points[l["b"]].y - 20.0) < 0.01:
			long_line = id
	var lines_before: int = s.lines.size()
	table.manager.activate("trim")
	var r: Dictionary = await s.trim_at({"kind": "line", "id": long_line}, Vector2(20, 20))
	print("SMOKE Trim on the stretch inside the square cuts it out (the real split-trim): two pieces, the long line is gone: ", r["ok"] and s.lines.size() == lines_before + 1 and not s.lines.has(long_line), " ", lines_before, " -> ", s.lines.size())
	var side := ""
	for id in s.lines:
		var l2: Dictionary = s.lines[id]
		if absf(s.points[l2["a"]].x) < 0.01 and absf(s.points[l2["b"]].x) < 0.01 and absf(absf(s.points[l2["a"]].y - s.points[l2["b"]].y) - 40.0) < 0.5:
			side = id
	var before_offset: int = s.lines.size()
	table.manager.activate("offset")
	var o: Dictionary = await s.offset_entity({"kind": "line", "id": side}, 5.0)
	print("SMOKE Offset of the left side by 5 adds one line (real route): ", o["ok"] and s.lines.size() == before_offset + 1, " ", before_offset, " -> ", s.lines.size())
	await s.undo()
	print("SMOKE Undo takes the offset line away: ", s.lines.size() == before_offset)
	quit()
