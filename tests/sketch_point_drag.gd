extends SceneTree
## S10 of docs/dimension-constraint-parity-plan.md, the logic half (no scene tree, no backend): scripts/design_table/point_drag.gd on a dimensioned rectangle.
## Synchronous mode (the vector-tested answers, deterministic): every frame of a drag keeps the dimensions, the horizontals and the verticals within tolerance; a pinned
## point (the origin, one the part holds, a Fix's) is never moved and a press on it starts no drag; a drag of a point the others hang from moves the group. The worker
## thread: the same path, each answer waited for, ends where the synchronous drag does; at most one task is ever in flight; an answer of a cancelled drag is thrown away;
## a drop waits for the task in flight. `unsupported` (a spline tangent in the group): nothing moves and the drop sends the wish. The frame times seen are printed.
## NOT checked: the feel, a real laser's rate, a Quest's CPU.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_point_drag.gd  (see tests/README.md)

const Session := preload("res://scripts/design_table/sketch_session.gd")
const PointDrag := preload("res://scripts/design_table/point_drag.gd")

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _rect_session() -> Object:
	## O (origin) and a rectangle A B C D, 40 wide and 20 high, hung from nothing but its own dimensions.
	var s = Session.new(Callable())
	s.origin_id = "O"
	var xy := {"O": [0.0, 0.0], "A": [10.0, 10.0], "B": [50.0, 10.0], "C": [50.0, 30.0], "D": [10.0, 30.0]}
	for id in xy:
		s.points[id] = Vector2(xy[id][0], xy[id][1])
		s.point_xy[id] = xy[id]
		s.point_locked[id] = false
	s.lines = {"ab": {"a": "A", "b": "B"}, "bc": {"a": "B", "b": "C"}, "cd": {"a": "C", "b": "D"}, "da": {"a": "D", "b": "A"}}
	s.constraints = {
		"h1": {"id": "h1", "type": "horizontal", "point_a_id": "A", "point_b_id": "B"},
		"v1": {"id": "v1", "type": "vertical", "point_a_id": "B", "point_b_id": "C"},
		"h2": {"id": "h2", "type": "horizontal", "point_a_id": "C", "point_b_id": "D"},
		"v2": {"id": "v2", "type": "vertical", "point_a_id": "D", "point_b_id": "A"},
		"w": {"id": "w", "type": "distance", "point_a_id": "A", "point_b_id": "B", "distance": 40.0, "orientation": "linear"},
		"hh": {"id": "hh", "type": "distance", "point_a_id": "B", "point_b_id": "C", "distance": 20.0, "orientation": "linear"},
	}
	return s


func _off(drag: PointDrag, a: String, b: String) -> Vector2:
	var pa: Array = drag.accepted_point(a)
	var pb: Array = drag.accepted_point(b)
	return Vector2(pb[0] - pa[0], pb[1] - pa[1])


## The worst deviation of the rectangle's dimensions and orientations in the drag's accepted frame.
func _worst(drag: PointDrag) -> float:
	var w := _off(drag, "A", "B")
	var h := _off(drag, "B", "C")
	var top := _off(drag, "D", "C")
	var left := _off(drag, "A", "D")
	return maxf(maxf(absf(w.length() - 40.0), absf(h.length() - 20.0)), maxf(maxf(absf(w.y), absf(h.x)), maxf(absf(top.y), absf(left.x))))


func _path(from: Vector2, to: Vector2, n: int) -> Array:
	var out: Array = []
	for i in range(1, n + 1):
		out.append(from.lerp(to, float(i) / n))
	return out


func _initialize() -> void:
	var s = _rect_session()
	var pinned: Array = PointDrag.pinned_ids(s)
	_check("O" in pinned and pinned.size() == 1, "pinned: only the origin on a plain sketch")
	s.point_locked["A"] = true
	s.reference_ids["R"] = true
	s.points["R"] = Vector2(5, 5)
	s.constraints["fx"] = {"id": "fx", "type": "fixed", "entity_id": "ab"}
	pinned = PointDrag.pinned_ids(s)
	_check("A" in pinned and "R" in pinned and "B" in pinned, "pinned: a locked point, a reference point and the points of a Fix (a Fix on a line pins both ends)")
	s = _rect_session()

	# --- every frame keeps the dimensions (synchronous)
	var drag := PointDrag.new()
	drag.synchronous = true
	_check(drag.begin(s, "C", Vector2(50.5, 30.5)), "a press on a free corner starts a drag")
	var worst := 0.0
	var moved_frames := 0
	for uv in _path(Vector2(50.5, 30.5), Vector2(75.5, 49.5), 25):
		var changed: Array = drag.step(uv)
		worst = maxf(worst, _worst(drag))
		if not changed.is_empty():
			moved_frames += 1
	_check(worst < 1e-4 and moved_frames >= 20, "25 frames of a drag: width 40, height 20, every horizontal and vertical hold within 1e-4 at every frame (worst %s, %d frames moved)" % [str(worst), moved_frames])
	var c_at: Array = drag.accepted_point("C")
	_check(Vector2(c_at[0], c_at[1]).distance_to(Vector2(75.0, 49.0)) < 1e-3, "the grabbed corner ends at the laser plus the grab offset (no jump at the press): %s" % str(c_at))
	var a_at: Array = drag.accepted_point("A")
	_check(Vector2(a_at[0], a_at[1]).distance_to(Vector2(35.0, 29.0)) < 1e-3, "the rest of the rectangle followed")
	var origin_at: Array = drag.accepted_point("O")
	_check(origin_at[0] == 0.0 and origin_at[1] == 0.0, "the origin did not move")
	var out: Dictionary = drag.finish()
	_check((out["updates"] as Dictionary).size() == 4 and not (out["updates"] as Dictionary).has("O") and out["anchors"] == ["C"] and not bool(out["unsupported"]), "the drop's wish: the four corners that moved (not the origin), anchored on the grabbed one")
	var old_a: Array = out["old"]["A"]
	_check(old_a[0] == 10.0 and old_a[1] == 10.0, "...with the press positions kept for Undo")

	# --- a pinned point does not move, and a press on one starts no drag
	s.point_locked["A"] = true
	drag = PointDrag.new()
	drag.synchronous = true
	_check(not drag.begin(s, "A", Vector2(10, 10)) and not drag.live, "a press on a locked point starts no drag")
	_check(not drag.begin(s, "O", Vector2(0, 0)), "...nor on the origin")
	# F7: the rigidity count now answers the pre-grab rule. A rectangle with a locked corner and all its dimensions has nothing left to move, so a press on another corner is
	# refused with a reason (before F7 the press started a drag that went nowhere).
	_check(not drag.begin(s, "C", Vector2(50, 30)) and not drag.live and drag.refusal.contains("fully constrained"), "a corner of a rectangle that is pinned at one corner and fully dimensioned is refused as fully constrained: %s" % drag.refusal)
	_check(s.point_rigidity("C") == "fully", "...by the rigidity count (not by a dof)")
	s.point_locked["A"] = false

	# --- a free corner of a loosened shape moves alone along its freedom (drop the width dimension)
	s.constraints.erase("w")
	drag = PointDrag.new()
	drag.synchronous = true
	drag.begin(s, "C", Vector2(50, 30))
	for uv in _path(Vector2(50, 30), Vector2(60, 30), 10):
		drag.step(uv)
	var worst2 := _worst2(drag)
	_check(worst2 < 1e-4, "with the width free the rectangle stays square-cornered and 20 high while it stretches (worst %s)" % str(worst2))
	drag.cancel()

	# --- the thread
	var path := _path(Vector2(50.5, 30.5), Vector2(75.5, 49.5), 12)
	s = _rect_session()
	var sync := PointDrag.new()
	sync.synchronous = true
	sync.begin(s, "C", Vector2(50.5, 30.5))
	for uv in path:
		sync.step(uv)
	var threaded := PointDrag.new()
	threaded.begin(s, "C", Vector2(50.5, 30.5))
	var in_flight_max := 0
	var guard := 0
	for uv in path:
		threaded.step(uv)
		in_flight_max = maxi(in_flight_max, 1 if threaded.in_flight() else 0)
		while threaded.in_flight() and guard < 100000: # let the task land, as frames would
			guard += 1
			OS.delay_usec(200)
			threaded.step(null)
	var same := true
	for id in ["A", "B", "C", "D", "O"]:
		var x: Array = sync.accepted_point(id)
		var y: Array = threaded.accepted_point(id)
		if absf(x[0] - y[0]) > 1e-6 or absf(x[1] - y[1]) > 1e-6:
			same = false
	_check(same and threaded.frames_run >= 1, "a drag off the main thread ends where the synchronous one does (%d calls on the thread against %d)" % [threaded.frames_run, sync.frames_run])
	_check(in_flight_max <= 1, "at most one task in flight")
	print("SMOKE frame times (ms): sync mean %.3f max %.3f; thread mean %.3f max %.3f over %d / %d calls" % [_mean(sync.frame_ms), _max(sync.frame_ms), _mean(threaded.frame_ms), _max(threaded.frame_ms), sync.frame_ms.size(), threaded.frame_ms.size()])
	var dropped: Dictionary = threaded.finish()
	_check((dropped["updates"] as Dictionary).size() == 4, "the threaded drop sends the same four points")

	# a result of a cancelled drag is thrown away; a drop waits for the task in flight
	var cancelled := PointDrag.new()
	cancelled.begin(s, "C", Vector2(50.5, 30.5))
	cancelled.step(Vector2(60, 40))
	var started: bool = cancelled.in_flight()
	cancelled.cancel()
	cancelled.wait_all()
	_check(started and not cancelled.live and cancelled.moved().is_empty() and cancelled.frames_run == 0, "a cancelled drag's answer is discarded (nothing accepted)")
	var waited := PointDrag.new()
	waited.begin(s, "C", Vector2(50.5, 30.5))
	waited.step(Vector2(60, 40))
	var drop: Dictionary = waited.finish()
	_check((drop["updates"] as Dictionary).size() == 4 and not waited.in_flight(), "a drop waits for the task in flight and sends its answer")

	# --- unsupported: nothing moves, the drop still sends the wish
	var u = Session.new(Callable())
	for id in ["a0", "a1", "a2", "a3", "b0", "b1", "b2", "b3"]:
		u.points[id] = Vector2.ZERO
		u.point_xy[id] = [0.0, 0.0]
		u.point_locked[id] = false
	u.constraints = {"k": {"id": "k", "type": "spline_tangent", "spline_id": "s", "segment_a_p0": "a0", "segment_a_p1": "a1", "segment_a_p2": "a2", "segment_a_p3": "a3",
		"segment_b_p0": "b0", "segment_b_p1": "b1", "segment_b_p2": "b2", "segment_b_p3": "b3"}}
	var un := PointDrag.new()
	un.synchronous = true
	un.begin(u, "a3", Vector2.ZERO)
	var ch: Array = un.step(Vector2(1, 1))
	var res: Dictionary = un.finish()
	_check(un.unsupported and ch.is_empty() and (res["updates"] as Dictionary).has("a3") and res["updates"]["a3"] == [1.0, 1.0] and bool(res["unsupported"]),
		"unsupported: the point does not move during the drag; the drop sends the wish at the laser")

	# --- the slowest vector (S9's scene-chain-20-curled), through the drag: the frame times on a 20-point group, on the thread and not
	var fixture: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/sketch_vectors.json"))
	for case in fixture["cases"]:
		if str(case["id"]) != "scene-chain-20-curled":
			continue
		for mode in ["synchronous", "thread"]:
			var big = Session.new(Callable())
			var start: Dictionary = case["input"]["start"]
			for id in start:
				big.points[id] = Vector2(start[id][0], start[id][1])
				big.point_xy[id] = [float(start[id][0]), float(start[id][1])]
				big.point_locked[id] = false
			big.lines = case["input"]["lines"]
			for c in case["input"]["constraints"]:
				big.constraints[str(c["id"])] = c
			for id in case["input"]["pinned"]:
				big.point_locked[id] = true
			var anchor := str(case["input"]["anchors"][0])
			var d := PointDrag.new()
			d.synchronous = mode == "synchronous"
			d.begin(big, anchor, Vector2(start[anchor][0], start[anchor][1]))
			for f in case["frames"]:
				d.step(Vector2(f["wish"][anchor][0], f["wish"][anchor][1]))
				var spin := 0
				while d.in_flight() and spin < 100000:
					spin += 1
					OS.delay_usec(200)
					d.step(null)
			d.wait_all()
			print("SMOKE scene-chain-20-curled %s: %d calls, mean %.2f ms, worst %.2f ms (a 90 Hz frame is 11.1 ms; the call is on the main thread only when synchronous)" % [mode, d.frame_ms.size(), _mean(d.frame_ms), _max(d.frame_ms)])
			_check(d.frame_ms.size() >= 1, "the 20-point chain ran through the drag (%s)" % mode)

	# --- C2: the drop solves the laser's last wish. On the slow 20-point group the first call is still running when the laser moves on, so the second wish is stored, not run; before
	# F3 the drop sent the first call's answer (the point a frame or more short of the release), now one synchronous call from that answer settles it, as a synchronous drag does
	for case in fixture["cases"]:
		if str(case["id"]) != "scene-chain-20-curled":
			continue
		var anchor2 := str(case["input"]["anchors"][0])
		var first := Vector2(case["frames"][0]["wish"][anchor2][0], case["frames"][0]["wish"][anchor2][1])
		var last := Vector2(case["frames"][-1]["wish"][anchor2][0], case["frames"][-1]["wish"][anchor2][1])
		var start2: Dictionary = case["input"]["start"]
		var at := Vector2(start2[anchor2][0], start2[anchor2][1])
		var reference := PointDrag.new()
		reference.synchronous = true
		reference.begin(_chain_session(case), anchor2, at)
		reference.step(first)
		reference.step(last)
		var late := PointDrag.new()
		late.begin(_chain_session(case), anchor2, at)
		late.step(first)
		late.step(last)
		var still_running: bool = late.in_flight()
		var settled: Dictionary = late.finish()
		var ref_drop: Dictionary = reference.finish()
		var same_end := true
		for id in (ref_drop["updates"] as Dictionary):
			var a: Array = settled["updates"].get(id, [INF, INF])
			var b: Array = ref_drop["updates"][id]
			if absf(float(a[0]) - float(b[0])) > 1e-9 or absf(float(a[1]) - float(b[1])) > 1e-9:
				same_end = false
		_check(still_running, "the first call is still running when the laser moves on (the last wish is stored, not run)")
		_check(same_end and (settled["updates"] as Dictionary).size() == (ref_drop["updates"] as Dictionary).size() and not (settled["updates"] as Dictionary).is_empty(),
			"the drop settles the last wish: the same points at the same places as a drag that ran every wish (%d points)" % (settled["updates"] as Dictionary).size())
		var only_first := PointDrag.new()
		only_first.synchronous = true
		only_first.begin(_chain_session(case), anchor2, at)
		only_first.step(first)
		var short: Array = only_first.finish()["updates"].get(anchor2, [INF, INF])
		var end: Array = settled["updates"].get(anchor2, [INF, INF])
		_check(Vector2(end[0], end[1]).distance_to(Vector2(short[0], short[1])) > 0.5, "...and that is not where the first call's answer would have dropped it (%s against %s)" % [str(Vector2(end[0], end[1])), str(Vector2(short[0], short[1]))])
		late.wait_all()
		reference.wait_all()

	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)


func _chain_session(case: Dictionary) -> Object:
	## The session of a vector case (S9's scene-chain-20-curled): its points, lines, constraints and pinned points.
	var big = Session.new(Callable())
	var start: Dictionary = case["input"]["start"]
	for id in start:
		big.points[id] = Vector2(start[id][0], start[id][1])
		big.point_xy[id] = [float(start[id][0]), float(start[id][1])]
		big.point_locked[id] = false
	big.lines = case["input"]["lines"]
	for c in case["input"]["constraints"]:
		big.constraints[str(c["id"])] = c
	for id in case["input"]["pinned"]:
		big.point_locked[id] = true
	return big


func _worst2(drag: PointDrag) -> float:
	var h := _off(drag, "B", "C")
	var top := _off(drag, "D", "C")
	var left := _off(drag, "A", "D")
	var w := _off(drag, "A", "B")
	return maxf(maxf(absf(h.length() - 20.0), absf(w.y)), maxf(maxf(absf(h.x), absf(top.y)), absf(left.x)))


func _mean(a: Array) -> float:
	var t := 0.0
	for v in a:
		t += float(v)
	return t / maxf(1.0, a.size())


func _max(a: Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, float(v))
	return m
