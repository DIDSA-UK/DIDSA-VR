extends SceneTree
## `scripts/motion/pattern_copy_pose.gd` against the golden vectors GENERATED FROM THE BACKEND (DIDSA-CAD tools/motion_vectors/pattern_copy_pose_vectors.py;
## tests/fixtures/pattern_copy_pose_vectors.json is a copy of its output, refreshed by hand: see tests/fixtures/README.md). Every live copy of every
## pattern kind (Linear 1-D / 2-D grid with reverse flags, Circular orient true / false, a tilted axis, skip indices) x five source poses, translation and
## rotation matrix, to 1e-9 (SMOKE lines). Also the segment parser. Run: "$GODOT" --headless --path . --script res://tests/pattern_copy_pose.gd

const Se3 := preload("res://scripts/motion/se3.gd")
const Copy := preload("res://scripts/motion/pattern_copy_pose.gd")
const FIXTURE := "res://tests/fixtures/pattern_copy_pose_vectors.json"


func _initialize() -> void:
	var doc = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var tol := float(doc["tolerance"])
	var cases: Array = doc["cases"]
	var checks := 0
	var worst := 0.0
	var bad := 0
	var first := ""
	var live_ok := true
	for c in cases:
		var pattern: Dictionary = c["pattern"]
		var source := Se3.pose_from_json(c["source"])
		if Copy.live_indices(pattern) != (c["live_indices"] as Array).map(func(x): return int(x)):
			live_ok = false
		for e in c["expected"]:
			var got := Copy.copy_pose(pattern, source, int(e["index"]))
			var want := Se3.pose_from_out(e)
			for k in 3:
				var d := absf(got["t"][k] - want["t"][k])
				worst = maxf(worst, d)
				checks += 1
				if d > tol:
					bad += 1
					first = first if first != "" else "%s #%d t[%d] %s vs %s" % [c["id"], int(e["index"]), k, got["t"][k], want["t"][k]]
			for k in 9:
				var d := absf(got["r"][k] - want["r"][k])
				worst = maxf(worst, d)
				checks += 1
				if d > tol:
					bad += 1
					first = first if first != "" else "%s #%d r[%d] %s vs %s" % [c["id"], int(e["index"]), k, got["r"][k], want["r"][k]]
	print("SMOKE pattern_copy_pose cases in the fixture: ", cases.size(), " (>= 40: ", cases.size() >= 40, ")")
	print("SMOKE live indices (seed excluded, skipped copies left out) equal the backend's for every case: ", live_ok)
	print("SMOKE every golden copy pose (translation and rotation matrix) to 1e-9: ", bad == 0, " (", checks, " checks, worst diff ", worst, ")" if bad == 0 else " first: " + first)
	var seg := Copy.parse_segment("A#pattern:pat-1:3")
	var nested := Copy.parse_segment("S")
	print("SMOKE parse_segment reads source, pattern id and index (a plain segment gives nothing): ", seg == {"source": "A", "pattern": "pat-1", "index": 3} and nested.is_empty() and Copy.parse_segment("A#pattern:P:x").is_empty())
	var keep: Dictionary = {}
	var turned := Se3.pose_from_json({"translation": [200.0, 0.0, 0.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 30.0})
	var circ := {"pattern_type": "circular", "count_angular": 4, "angle_total": 360.0, "axis": {"origin": [0.0, 0.0, 0.0], "direction": [0.0, 0.0, 1.0]}, "orient_with_rotation": true}
	var oriented := Copy.copy_pose(circ, turned, 1)
	circ["orient_with_rotation"] = false
	keep = Copy.copy_pose(circ, turned, 1)
	print("SMOKE orient_with_rotation false keeps the source's rotation, true turns it with the step: ", absf(Se3.norm3(Se3.rotvec_from_rot(keep["r"])) - deg_to_rad(30.0)) < 1e-9 and absf(Se3.norm3(Se3.rotvec_from_rot(oriented["r"])) - deg_to_rad(120.0)) < 1e-9)
	if bad == 0 and live_ok:
		print("SMOKE PASSED: every pattern copy pose to 1e-9 (", checks, " checks)")
	else:
		print("SMOKE FAILED")
	quit()
