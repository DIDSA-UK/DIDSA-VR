extends RefCounted
## Frame-time statistics for the P0 spikes (docs/live-sessions-spikes.md): the numbers a pass / fail row reads.
## Feed it each frame's delta (seconds); summary() gives fps, mean / p95 / worst frame time (ms) and the share of frames over 33 ms.

var _ms: PackedFloat32Array = PackedFloat32Array()


func add(delta_s: float) -> void:
	_ms.append(delta_s * 1000.0)


func count() -> int:
	return _ms.size()


func clear() -> void:
	_ms = PackedFloat32Array()


func summary() -> Dictionary:
	if _ms.is_empty():
		return {"frames": 0, "fps": 0.0, "mean_ms": 0.0, "p95_ms": 0.0, "worst_ms": 0.0, "over_33ms_pct": 0.0}
	var sorted := _ms.duplicate()
	sorted.sort()
	var total := 0.0
	var over := 0
	for v in sorted:
		total += v
		if v > 33.3:
			over += 1
	var mean := total / sorted.size()
	var p95: float = sorted[mini(sorted.size() - 1, int(ceil(sorted.size() * 0.95)) - 1)]
	return {
		"frames": sorted.size(),
		"fps": 1000.0 / mean if mean > 0.0 else 0.0,
		"mean_ms": mean,
		"p95_ms": p95,
		"worst_ms": sorted[sorted.size() - 1],
		"over_33ms_pct": 100.0 * over / sorted.size(),
	}


static func line(s: Dictionary) -> String:
	return "%.1f fps, frame mean %.1f ms, p95 %.1f ms, worst %.1f ms, %.1f%% over 33 ms (%d frames)" % [
		s["fps"], s["mean_ms"], s["p95_ms"], s["worst_ms"], s["over_33ms_pct"], s["frames"]]


static func passes_60(s: Dictionary) -> bool:
	## C2 / C3's bar: p95 frame <= 16.7 ms and at most 1% of frames over 33 ms.
	return s["frames"] > 0 and s["p95_ms"] <= 16.7 and s["over_33ms_pct"] <= 1.0
