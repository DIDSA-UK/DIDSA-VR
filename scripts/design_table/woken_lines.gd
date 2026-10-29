extends RefCounted
## The sketch lines the laser has passed over lately: the only ones a new line may be inferred parallel or perpendicular to (besides the segment a run of lines is
## continuing). The flat app tests every line in the sketch, which with a mouse and 4 degrees is fine; a laser shakes by a few millimetres at arm's length, and a
## 40 mm line drawn near some unrelated line's angle would quietly become parallel to it. SOLIDWORKS and Onshape ask for the same: pass over the reference
## line first. Pure (the caller passes the clock), so it is unit-tested on its own (tests/design_table_logic.gd).

const KEEP := 3 ## the last three lines passed over
const LIFETIME_MS := 5000 ## each stays woken this long after the laser last passed over it

var _seen: Array = [] ## [{id, t}] oldest first


func touch(id: String, now_ms: int) -> void:
	## The laser is over line `id` now.
	if id == "":
		return
	for i in _seen.size():
		if _seen[i]["id"] == id:
			_seen.remove_at(i)
			break
	_seen.append({"id": id, "t": now_ms})
	while _seen.size() > KEEP:
		_seen.pop_front()


func active(now_ms: int) -> Array:
	## The ids still woken at `now_ms` (the expired ones are forgotten), oldest first.
	_seen = _seen.filter(func(e): return now_ms - int(e["t"]) <= LIFETIME_MS)
	return _seen.map(func(e): return e["id"])


func clear() -> void:
	_seen.clear()
