extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): S10 of docs/dimension-constraint-parity-plan.md, a sketch
## point dragged, on a real sketch (a new part, a sketch on XY). A rectangle with a width dimension is drawn; a corner is dragged through PointDrag (the projector, off the
## main thread) and dropped with SketchSession.drop_points (ONE solve-and-refresh: point_updates + the anchor).
##   * Every frame of the drag keeps the width; the drop's positions are the backend's: its stored points equal the session's and the dimension still reads 40.
##   * Undo puts every point back (the backend's stored points are the old ones).
##   * (F3, C2) The drop lands where the laser was at the release: a wish the thread never ran is solved at the drop, and the backend stores that point.
##   * A Fix on a corner pins it: a press on it starts no drag, and dragging another corner leaves it exactly where it was, in the backend too.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_point_drag.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const PointDrag := preload("res://scripts/design_table/point_drag.gd")

var main
var table
var api
var ed
var s
var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func backend_points() -> Dictionary:
	var r: Dictionary = await s.api.call(HTTPClient.METHOD_GET, "/sketch/sketches/" + s.sketch_id + "/points", null)
	var out := {}
	if r["ok"] and r["json"] is Array:
		for p in r["json"]:
			out[str(p["id"])] = Vector2(float(p["x"]), float(p["y"]))
	return out


func corner_near(uv: Vector2) -> String:
	for id in s.points:
		if (s.points[id] as Vector2).distance_to(uv) < 0.5 and not s.is_origin(str(id)):
			return str(id)
	return ""


## Drags `id` from where it is to `to` in 20 frames; returns the worst width error seen.
func drag(d: PointDrag, id: String, to: Vector2, a: String, b: String) -> float:
	var from: Vector2 = s.points[id]
	var worst := 0.0
	for i in range(1, 21):
		d.step(from.lerp(to, float(i) / 20.0))
		var spin := 0
		while d.in_flight() and spin < 20000:
			spin += 1
			await process_frame
			d.step(null)
		var pa: Array = d.accepted_point(a)
		var pb: Array = d.accepted_point(b)
		worst = maxf(worst, absf(Vector2(pa[0], pa[1]).distance_to(Vector2(pb[0], pb[1])) - 40.0))
	return worst


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	var url := str(cfg.get_value("backend", "url"))
	var key := str(cfg.get_value("backend", "api_key"))
	main.backend_url = url
	main.api_key = key
	table = main.design_table
	table.configure_backend(url, key)
	api = table.api
	table.surface.settle_seconds = 0.0
	ed = table.editor

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var opened: bool = await ed.begin_sketch({"fixed": "XY"})
	s = ed.session
	print("SMOKE a sketch opens on XY: ", opened)

	_check(opened, "a sketch opens on XY")
	s.set_tool("rectangle")
	await s.tap({"uv": Vector2(10, 10)})
	await s.tap({"uv": Vector2(50, 30)})
	var a := corner_near(Vector2(10, 10))
	var b := corner_near(Vector2(50, 10))
	var c := corner_near(Vector2(50, 30))
	var dd := corner_near(Vector2(10, 30))
	_check(a != "" and b != "" and c != "" and dd != "", "a rectangle with four corner points")
	var bottom := ""
	for id in s.lines:
		var l: Dictionary = s.lines[id]
		if [l["a"], l["b"]].has(a) and [l["a"], l["b"]].has(b):
			bottom = str(id)
	s.set_tool("dimension")
	s.clear_selection()
	await s.select({"kind": "line", "id": bottom})
	var made: Dictionary = await s.confirm_ghost("length", 40.0)
	_check(bool(made["ok"]), "a width dimension of 40 on the bottom line")
	a = corner_near(Vector2(10, 10)) if corner_near(Vector2(10, 10)) != "" else a # the dimension may have rescaled the sketch about its first point
	var width_now: float = (s.points[a] as Vector2).distance_to(s.points[b])
	print("SMOKE width after the dimension: %.4f (a %s, b %s)" % [width_now, a, b])

	# --- a drag and a drop
	s.set_tool("select")
	var before_backend: Dictionary = await backend_points()
	var pinned: Array = PointDrag.pinned_ids(s)
	var d := PointDrag.new()
	var start_c: Vector2 = s.points[c]
	_check(d.begin(s, c, start_c), "a press on a free corner starts a drag (pinned: %s)" % str(pinned))
	var target := start_c + Vector2(18, 12)
	var worst: float = await drag(d, c, target, a, b)
	_check(worst < 1e-3, "every frame of the drag keeps the width at 40 (worst error %s)" % str(worst))
	print("SMOKE frame times (ms) on the thread: mean %.3f worst %.3f over %d calls" % [_mean(d.frame_ms), _max(d.frame_ms), d.frame_ms.size()])
	var drop: Dictionary = d.finish()
	var result: Dictionary = await s.drop_points(drop)
	_check(bool(result["ok"]), "the drop is accepted by the backend (%s)" % str(result["message"]))
	var after_backend: Dictionary = await backend_points()
	var same := true
	for id in s.points:
		if not after_backend.has(id) or (after_backend[id] as Vector2).distance_to(s.points[id]) > 1e-3:
			same = false
	_check(same, "the session shows the backend's stored points")
	var w: float = (after_backend[a] as Vector2).distance_to(after_backend[b])
	_check(absf(w - width_now) < 1e-3, "the backend's width still reads what it did (%.4f)" % w)
	var c_end: Vector2 = after_backend[c]
	print("SMOKE the grabbed corner went from %s to %s for a wish of %s" % [str(start_c), str(c_end), str(target)])
	_check(c_end.distance_to(target) < 0.5, "the dragged corner is where it was dropped (the backend's answer)")
	_check(s.dof >= 0 and s.constraint_state() != "over", "the DOF state is the backend's (dof %d, %s)" % [s.dof, s.constraint_state()])
	_check(s.can_undo() and s.undo_label() == "point move", "the drop is one Undo step")
	await s.undo()
	var back: Dictionary = await backend_points()
	var restored := true
	for id in before_backend:
		if not back.has(id) or (back[id] as Vector2).distance_to(before_backend[id]) > 1e-3:
			restored = false
	_check(restored, "Undo puts every point back (the backend's stored points are the old ones)")

	# --- a Fix pins a corner
	var fx: Dictionary = await s.api.call(HTTPClient.METHOD_POST, "/sketch/sketches/" + s.sketch_id + "/constraints", {"type": "fixed", "entity_id": a})
	await s.refresh(false)
	pinned = PointDrag.pinned_ids(s)
	var press := PointDrag.new()
	_check(bool(fx["ok"]) and a in pinned and not press.begin(s, a, s.points[a]), "a Fix on a corner pins it: a press on it starts no drag")
	var a_at: Vector2 = s.points[a]
	var d2 := PointDrag.new()
	d2.begin(s, c, s.points[c])
	var worst2: float = await drag(d2, c, (s.points[c] as Vector2) + Vector2(10, 10), a, b)
	var drop2: Dictionary = d2.finish()
	var result2: Dictionary = await s.drop_points(drop2)
	var fixed_back: Dictionary = await backend_points()
	_check(not (drop2["updates"] as Dictionary).has(a) and (fixed_back[a] as Vector2).distance_to(a_at) < 1e-6 and worst2 < 1e-3,
		"dragging another corner leaves the fixed one exactly where it was, and the width held (%s)" % str(result2["ok"]))

	# --- F3 / C2: the drop lands where the laser was at the release. A free end of a line is dragged on the thread: the first call is running when the laser moves on, so the
	# later wish is stored, never run (the poke stands for a second step that found a task in flight); the drop solves it, and the backend's stored point is the release point
	s.set_tool("line")
	await s.tap({"uv": Vector2(70, 5)})
	await s.tap({"uv": Vector2(95, 12)})
	s.set_tool("select")
	var free := corner_near(Vector2(95, 12))
	_check(free != "" and not (free in PointDrag.pinned_ids(s)), "a free line end to drag (%s)" % free)
	var d3 := PointDrag.new()
	var from3: Vector2 = s.points[free]
	d3.begin(s, free, from3)
	var wish1 := from3 + Vector2(6, 4)
	var release := from3 + Vector2(14, -9)
	d3.step(wish1)
	d3._wish = release
	var drop3: Dictionary = d3.finish()
	var at_release: Array = drop3["updates"].get(free, [INF, INF])
	_check(Vector2(at_release[0], at_release[1]).distance_to(release) < 1e-6, "the drop carries the release point, not the first call's answer (%s for %s)" % [str(at_release), str(release)])
	var result3: Dictionary = await s.drop_points(drop3)
	var stored3: Dictionary = await backend_points()
	_check(bool(result3["ok"]) and stored3.has(free) and (stored3[free] as Vector2).distance_to(release) < 1e-3 and (s.points[free] as Vector2).distance_to(release) < 1e-3,
		"the backend stored the dragged point at the release point (%s for %s)" % [str(stored3.get(free)), str(release)])
	d3.wait_all()

	d.wait_all()
	d2.wait_all()
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)


func _mean(arr: Array) -> float:
	var t := 0.0
	for v in arr:
		t += float(v)
	return t / maxf(1.0, arr.size())


func _max(arr: Array) -> float:
	var m := 0.0
	for v in arr:
		m = maxf(m, float(v))
	return m
