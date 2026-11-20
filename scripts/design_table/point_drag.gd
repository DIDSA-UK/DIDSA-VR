extends RefCounted
## S10 of docs/dimension-constraint-parity-plan.md: one sketch-point drag (F6), the part of it that needs no scene tree. table_editor.gd owns the trigger, the laser and the
## redraw; this owns what the drag may move, the per-frame call of SketchProjector and its thread, and what the drop sends.
##
##   begin(session, point_id, press_uv)  -> false when the grab is refused (`refusal` says why: the origin, a reference, a point the part or a Fix holds, the pre-grab rule of
##                                          spec 13.5): no drag starts. A point of an intact circle, arc, ellipse, ellipse arc, rectangle, polygon or slot drags the WHOLE
##                                          shape by that shape's closed-form proposal, clamped by the projector when a user constraint touches it (F8, shape_proposals.gd)
##   begin_line(session, line_id, press_uv) -> a rigid line drag: both ends take the same delta (two anchors, one offset); a polygon edge or a slot side is the drag of its
##                                          first point, as the flat app does it
##   step(uv)                            -> the ids whose accepted position changed this frame (the editor lays them over session.points and redraws)
##   finish() / cancel()                 -> the drop's payload / the drag let go
##
## Each frame is one SketchProjector.project call, off the main thread (WorkerThreadPool) with at most ONE task in flight: a start takes deep copies of every
## input (points as [x, y] floats, constraints, lines, anchors, pinned, the reference) and the latest wish, nothing from the scene tree. A finished result of a drag
## that is still live is the ACCEPTED frame: its points go over the reference and are the next call's `reference` (as [x, y] floats, never Vector2: S9's rule).
## A result of a drag that was cancelled or ended is thrown away. `synchronous` runs the same call on the calling thread (the vector-tested answers, deterministic).
## `finish()` solves the last wish synchronously if no call has run with it (C2). `unsupported` (a spline tangent in the group): nothing moves during the drag; the drop still sends the wish and the backend's solve decides, as the flat app's fallback.

const SketchProjector := preload("res://scripts/motion/sketch_projector.gd")
const Shapes := preload("res://scripts/motion/shape_proposals.gd")
const MOVED_EPSILON := 1e-9 ## a point further than this (mm) from where the press found it is part of the wish

var synchronous := false
var live := false
var unsupported := false ## the last frame's answer: the projector cannot do this group
var grabbed: Array = [] ## the point ids held (anchors)
var refusal := "" ## why the last begin / begin_line returned false ("" when it started)
var shape_kind := "" ## the family of the shape being dragged ("" for a plain point or a line)
var hybrid := false ## a shape drag clamped by the projector (a user constraint touches the shape)
var frame_ms: Array = [] ## how long each finished projector call took, ms (the call itself, wherever it ran)
var frames_run := 0

var _press := Vector2.ZERO ## where the laser was at the press
var _anchor_start: Dictionary = {} ## grabbed id -> Vector2: where each held point was at the press; the wish is that plus the laser's move (so nothing jumps to the laser)
var _shape: Dictionary = {} ## shape_proposals.gd `locate`'s answer for the grabbed point ({} = no shape)
var _records: Dictionary = {}
var _start: Dictionary = {} ## id -> [x, y] at the press, all of the sketch's points (Undo, and what "moved" is measured from)
var _accepted: Dictionary = {} ## id -> [x, y]: the last accepted frame, all points (the next call's reference)
var _constraints: Array = [] ## what the thread may read are copies of these, taken at each start
var _lines: Dictionary = {}
var _pinned: Array = []
var _task := -1
var _box: Dictionary = {} ## the task's shared answer {result, ms}; read only once the task is completed
var _box_epoch := 0
var _epoch := 0 ## a new number for every drag: an answer from an older one is dropped
var _stale: Array = [] ## task ids of cancelled drags, waited for later (a task must always be waited for)
var _last_wish := Vector2(INF, INF) ## the laser move (the delta) the task in flight (or the last one) ran with
var _wish := Vector2(INF, INF) ## the latest laser move since the press


static func pinned_ids(session) -> Array:
	## The points a drag never moves: the origin, the sketch's reference points, the points the part holds (locked), and every point a Fix holds (a `fixed` constraint is
	## not something the projector skips by its own choice: the caller pins its points).
	var out := {}
	if session.origin_id != "":
		out[session.origin_id] = true
	for id in session.reference_ids:
		if session.points.has(id):
			out[id] = true
	for id in session.point_locked:
		if bool(session.point_locked[id]):
			out[id] = true
	for cid in session.constraints:
		var c: Dictionary = session.constraints[cid]
		if str(c.get("type", "")) == "fixed":
			for id in session.constraint_point_ids(c):
				out[id] = true
	return out.keys()


static func _exact_points(session) -> Dictionary:
	## id -> [x, y] floats: the backend's 64-bit numbers when the session still holds them (a Vector2 is 32-bit: about 1e-5 off at 100 mm, above the projector's tolerance).
	var out := {}
	for id in session.points:
		var exact: Variant = session.point_xy.get(id)
		var here: Vector2 = session.points[id]
		out[str(id)] = [float(exact[0]), float(exact[1])] if exact is Array and absf(float(exact[0]) - here.x) < 1e-3 and absf(float(exact[1]) - here.y) < 1e-3 else [float(here.x), float(here.y)]
	return out


static func _exists(session) -> Dictionary:
	var out := {}
	for id in session.lines:
		out[str(id)] = true
	for id in session.arcs:
		out[str(id)] = true
	return out


static func shape_of(session, point_id: String) -> Dictionary:
	## The intact closed-form shape the point belongs to (shape_proposals.gd `locate`), {} for a plain point.
	return Shapes.locate(session.shape_records, _exact_points(session), _exists(session), point_id)


static func refusal_for(session, point_ids: Array, shape: Dictionary = {}) -> String:
	## The pre-grab rule (spec 13.5): "" or the sentence that says why this grab does nothing. Over-constrained = the rigidity count (`session.point_rigidity`, F7), the solve's
	## failed list or a contradictory line; immobile = the mobility oracle of 13.6 says 0 (when it has no answer, the rule's own fallback: the whole sketch is fully constrained,
	## or the count says fully constrained or pinned).
	var pinned := pinned_ids(session)
	for id in point_ids:
		if id in pinned:
			return "That point is held in place (the origin, the part, or a Fix): it does not move."
	var failed: Dictionary = session.failed_point_ids()
	var whole_sketch_pinned: bool = session.dof == 0 and session.converged and session.points.size() > 1 and session.sketch_grounded()
	for id in point_ids:
		var state: String = session.point_rigidity(str(id))
		var fully := whole_sketch_pinned or state == "fully" or state == "pinned"
		var over: bool = state == "over" or failed.has(id) or session.on_contradictory_line(str(id))
		var mobility: int = SketchProjector.mobility(_exact_points(session), session.constraints.values(), session.lines, str(id), pinned)
		var immobile: bool = (mobility == 0) if mobility >= 0 else fully
		if shape.is_empty():
			if over:
				return "That point is over-constrained: it does not move."
			if immobile:
				return "That point is fully constrained: it does not move."
			continue
		var rec: Dictionary = shape["rec"]
		var role: Dictionary = shape["role"]
		var centre_id := str(rec.get("center_point_id", rec.get("center1_point_id", "")))
		var centre_state: String = session.point_rigidity(centre_id)
		var centre_pinned := whole_sketch_pinned or centre_state == "fully" or centre_state == "pinned"
		var kind: String = shape["kind"]
		var r: String = role["r"]
		var why: String = Shapes.grab_refusal(shape, session.constraints.values(), session.shape_records)
		if why != "":
			return why
		if r == "centre" and kind in ["circle", "arc", "polygon"] and centre_pinned:
			return "That shape's centre is fully constrained: it does not move."
		if kind in ["circle", "arc"] and r in ["rim", "end"] and Shapes.size_of(shape, "radius", session.constraints.values(), session.shape_records) != null and centre_pinned:
			return "That shape's centre is fixed and its size is dimensioned: this point does not move."
		if kind == "arc" and r == "end" and (state == "fully" or state == "pinned"):
			return "That point is fully constrained: it does not move."
		if (over or immobile) and Shapes.is_hybrid(shape, session.constraints.values(), session.shape_records):
			return "That point is over-constrained or fully constrained: it does not move." # 13.5 step 4: a clamped drag has nothing to clamp to
	return ""


func begin(session, point_id: String, press_uv: Vector2) -> bool:
	## Starts a drag of one point (the whole shape when it belongs to one). False (and nothing started; `refusal` says why) when it cannot move.
	cancel()
	_reap()
	refusal = ""
	if session == null or not session.points.has(point_id):
		return false
	var shape := shape_of(session, point_id)
	refusal = refusal_for(session, [point_id], shape)
	if refusal != "":
		return false
	return _begin_with(session, [point_id], press_uv, shape)


func begin_line(session, line_id: String, press_uv: Vector2) -> bool:
	## Starts a rigid drag of a line: both ends move by the same delta (the drop's solve settles the rest). A polygon edge or a slot side drags its first point instead
	## (the flat app's redirect: a chord's translation fights the equal-radius chain).
	cancel()
	_reap()
	refusal = ""
	if session == null or not session.lines.has(line_id):
		return false
	var l: Dictionary = session.lines[line_id]
	var a := str(l["a"])
	var b := str(l["b"])
	if not session.points.has(a) or not session.points.has(b):
		return false
	var first := shape_of(session, a)
	if not first.is_empty() and first["kind"] in ["polygon", "slot"]:
		return begin(session, a, press_uv)
	refusal = refusal_for(session, [a, b])
	if refusal != "":
		return false
	return _begin_with(session, [a, b], press_uv, {})


func _begin_with(session, ids: Array, press_uv: Vector2, shape: Dictionary) -> bool:
	_pinned = pinned_ids(session)
	_start = _exact_points(session)
	_accepted = _start.duplicate(true)
	_constraints = (session.constraints.values() as Array).duplicate(true)
	_lines = (session.lines as Dictionary).duplicate(true)
	_records = (session.shape_records as Dictionary).duplicate(true)
	_shape = shape
	shape_kind = str(shape.get("kind", ""))
	hybrid = not shape.is_empty() and Shapes.is_hybrid(shape, _constraints, _records)
	grabbed = ids.duplicate()
	_anchor_start = {}
	for id in ids:
		var at: Array = _start[id]
		_anchor_start[id] = Vector2(at[0], at[1])
	_press = press_uv
	unsupported = false
	frame_ms = []
	frames_run = 0
	_epoch += 1
	_last_wish = Vector2(INF, INF)
	_wish = Vector2.ZERO
	live = true
	return true


func step(uv: Variant) -> Array:
	## One frame: the laser is at `uv` (sketch mm; null: it is off the sheet, the wish stays). Takes in a finished answer, and starts the next call if the wish changed and
	## none is in flight. Returns the ids whose accepted position changed.
	if not live:
		return []
	_reap()
	if uv is Vector2:
		_wish = (uv as Vector2) - _press
	var changed: Array = []
	if synchronous:
		if _wish != _last_wish:
			_last_wish = _wish
			changed = _accept(_run(_inputs(_wish)))
		return changed
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		changed = _collect()
	if _task < 0 and _wish != _last_wish:
		_start_task()
	return changed


func in_flight() -> bool:
	return _task >= 0


func moved() -> Dictionary:
	## id -> [x, y]: the points whose accepted position is not where the press found them.
	var out := {}
	for id in _accepted:
		var a: Array = _accepted[id]
		var s: Array = _start[id]
		if absf(float(a[0]) - float(s[0])) > MOVED_EPSILON or absf(float(a[1]) - float(s[1])) > MOVED_EPSILON:
			out[id] = a
	return out


func accepted_point(id: String) -> Variant:
	return _accepted.get(id)


func start_point(id: String) -> Variant:
	return _start.get(id)


func finish() -> Dictionary:
	## The drop: waits for a task in flight (its answer counts, the drag is still live), then returns what to send: {updates: id -> [x, y], anchors, old: id -> [x, y] of
	## the press, unsupported}. With `unsupported` the wish itself (the grabbed points at the laser) is what goes, and the backend's solve decides.
	if _task >= 0:
		_collect() # (waits for the task itself; waiting here as well made the second wait an "Invalid Task ID")
	if live and _wish != _last_wish:
		# C2: the laser moved on after the last call started (at most one is in flight), so its last frames were never solved: one synchronous call from the last accepted frame,
		# and the point is dropped where the laser was at release, not a frame or more before it (about 0.5 ms; 10-20 ms for a 20-point group, once)
		_last_wish = _wish
		_accept(_run(_inputs(_wish)))
	live = false
	var updates: Dictionary = moved()
	if unsupported:
		updates = {}
		for id in grabbed:
			updates[id] = [_anchor_start[id].x + _wish.x, _anchor_start[id].y + _wish.y]
	var old := {}
	for id in updates:
		old[id] = _start[id]
	return {"updates": updates, "anchors": grabbed.duplicate(), "old": old, "unsupported": unsupported}


func cancel() -> void:
	## The drag is let go (B, or the sketch closed): the answer of a call in flight is dropped when it lands.
	if _task >= 0:
		_stale.append(_task)
		_task = -1
	live = false
	_epoch += 1


func wait_all_frames() -> void:
	## Waits for the task in flight and takes its answer in (a test that drives the thread path one frame at a time).
	if _task >= 0:
		while not WorkerThreadPool.is_task_completed(_task):
			OS.delay_usec(200)
		_collect() # (it waits for the finished task and takes its answer)


func wait_all() -> void:
	## Blocks until no task of this drag (cancelled ones too) is running. For the end of a test, or leaving the sketch.
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	for t in _stale:
		WorkerThreadPool.wait_for_task_completion(t)
	_stale.clear()


# --- the projector call ------------------------------------------------------------------------

func _inputs(wish: Vector2) -> Dictionary:
	var points: Dictionary = _accepted.duplicate(true)
	for id in grabbed:
		var at: Vector2 = _anchor_start[id] + wish
		points[id] = [at.x, at.y]
	var inputs := {"points": points, "constraints": _constraints.duplicate(true), "lines": _lines.duplicate(true), "anchors": grabbed.duplicate(),
		"pinned": _pinned.duplicate(), "reference": _accepted.duplicate(true)}
	if not _shape.is_empty():
		# F8: a shape point takes the shape's proposal (the target is the grabbed point's own wish), clamped when `hybrid`
		var at: Array = points[grabbed[0]]
		inputs["shape"] = {"shape": _shape, "grabbed": str(grabbed[0]), "target": [at[0], at[1]], "records": _records, "hybrid": hybrid}
	return inputs


static func _run(inputs: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var result: Dictionary
	if inputs.has("shape"):
		var sh: Dictionary = inputs["shape"]
		var f: Dictionary = Shapes.frame(sh["shape"], sh["grabbed"], inputs["reference"], sh["target"], inputs["constraints"], inputs["lines"], inputs["pinned"], sh["records"], sh["hybrid"])
		# nothing moves this frame when the proposal is none or the clamp is rejected: an empty result, a converged answer that changes no point
		result = {"unsupported": false, "converged": true, "points": f["result"], "clamp": f["clamp"]}
	else:
		result = SketchProjector.project(inputs["points"], inputs["constraints"], inputs["lines"], inputs["anchors"], inputs["pinned"], [], inputs["reference"])
	result["ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	return result


static func _work(box: Dictionary, inputs: Dictionary) -> void:
	box["result"] = _run(inputs)


func _start_task() -> void:
	_last_wish = _wish
	_box = {}
	_box_epoch = _epoch
	_task = WorkerThreadPool.add_task(_work.bind(_box, _inputs(_wish)), false, "sketch point drag")


func _collect() -> Array:
	var task := _task
	_task = -1
	WorkerThreadPool.wait_for_task_completion(task)
	if _box_epoch != _epoch or not live or not _box.has("result"):
		return [] # a cancelled or ended drag's answer
	return _accept(_box["result"])


func _accept(result: Dictionary) -> Array:
	frames_run += 1
	frame_ms.append(float(result.get("ms", 0.0)))
	unsupported = bool(result["unsupported"])
	if unsupported:
		return [] # no answer: the point does not move during the drag
	var changed: Array = []
	var group: Dictionary = result["points"]
	for id in group:
		var p: Array = group[id]
		var old: Array = _accepted[id]
		if p[0] != old[0] or p[1] != old[1]:
			changed.append(id)
		_accepted[id] = [float(p[0]), float(p[1])]
	return changed


func _reap() -> void:
	var rest: Array = []
	for t in _stale:
		if WorkerThreadPool.is_task_completed(t):
			WorkerThreadPool.wait_for_task_completion(t)
		else:
			rest.append(t)
	_stale = rest
