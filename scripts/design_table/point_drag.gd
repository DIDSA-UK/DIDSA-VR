extends RefCounted
## S10 of docs/dimension-constraint-parity-plan.md: one sketch-point drag (F6), the part of it that needs no scene tree. table_editor.gd owns the trigger, the laser and the
## redraw; this owns what the drag may move, the per-frame call of SketchProjector and its thread, and what the drop sends.
##
##   begin(session, point_id, press_uv)  -> false when the point is pinned (the origin, a reference, a point the part or a Fix holds): no drag starts
##   step(uv)                            -> the ids whose accepted position changed this frame (the editor lays them over session.points and redraws)
##   finish() / cancel()                 -> the drop's payload / the drag let go
##
## Each frame is one SketchProjector.project call, off the main thread (WorkerThreadPool) with at most ONE task in flight: a start takes deep copies of every
## input (points as [x, y] floats, constraints, lines, anchors, pinned, the reference) and the latest wish, nothing from the scene tree. A finished result of a drag
## that is still live is the ACCEPTED frame: its points go over the reference and are the next call's `reference` (as [x, y] floats, never Vector2: S9's rule).
## A result of a drag that was cancelled or ended is thrown away. `synchronous` runs the same call on the calling thread (the vector-tested answers, deterministic).
## `unsupported` (a spline tangent in the group): nothing moves during the drag; the drop still sends the wish and the backend's solve decides, as the flat app's fallback.

const SketchProjector := preload("res://scripts/motion/sketch_projector.gd")
const MOVED_EPSILON := 1e-9 ## a point further than this (mm) from where the press found it is part of the wish

var synchronous := false
var live := false
var unsupported := false ## the last frame's answer: the projector cannot do this group
var grabbed: Array = [] ## the point ids held (anchors)
var frame_ms: Array = [] ## how long each finished projector call took, ms (the call itself, wherever it ran)
var frames_run := 0

var _offset := Vector2.ZERO ## where the point is minus where the laser was at the press: the drag keeps it, so the point does not jump to the laser
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
var _last_wish := Vector2(INF, INF) ## the wish the task in flight (or the last one) ran with
var _wish := Vector2(INF, INF) ## the latest laser wish


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


func begin(session, point_id: String, press_uv: Vector2) -> bool:
	## Starts a drag of one point. False (and nothing started) when it cannot move.
	cancel()
	_reap()
	if session == null or not session.points.has(point_id):
		return false
	_pinned = pinned_ids(session)
	if point_id in _pinned:
		return false
	_start = {}
	for id in session.points:
		var exact: Variant = session.point_xy.get(id)
		var here: Vector2 = session.points[id]
		# the backend's 64-bit numbers when the session still holds them (a Vector2 is 32-bit: about 1e-5 off at 100 mm, above the projector's tolerance)
		_start[str(id)] = [float(exact[0]), float(exact[1])] if exact is Array and absf(float(exact[0]) - here.x) < 1e-3 and absf(float(exact[1]) - here.y) < 1e-3 else [float(here.x), float(here.y)]
	_accepted = _start.duplicate(true)
	_constraints = (session.constraints.values() as Array).duplicate(true)
	_lines = (session.lines as Dictionary).duplicate(true)
	grabbed = [point_id]
	var at: Array = _start[point_id]
	_offset = Vector2(at[0], at[1]) - press_uv
	unsupported = false
	frame_ms = []
	frames_run = 0
	_epoch += 1
	_last_wish = Vector2(INF, INF)
	_wish = press_uv + _offset
	live = true
	return true


func step(uv: Variant) -> Array:
	## One frame: the laser is at `uv` (sketch mm; null: it is off the sheet, the wish stays). Takes in a finished answer, and starts the next call if the wish changed and
	## none is in flight. Returns the ids whose accepted position changed.
	if not live:
		return []
	_reap()
	if uv is Vector2:
		_wish = (uv as Vector2) + _offset
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
		WorkerThreadPool.wait_for_task_completion(_task)
		_collect()
	live = false
	var updates: Dictionary = moved()
	if unsupported:
		updates = {}
		for id in grabbed:
			updates[id] = [_wish.x, _wish.y]
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
		points[id] = [wish.x, wish.y]
	return {"points": points, "constraints": _constraints.duplicate(true), "lines": _lines.duplicate(true), "anchors": grabbed.duplicate(),
		"pinned": _pinned.duplicate(), "reference": _accepted.duplicate(true)}


static func _run(inputs: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var result: Dictionary = SketchProjector.project(inputs["points"], inputs["constraints"], inputs["lines"], inputs["anchors"], inputs["pinned"], [], inputs["reference"])
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
