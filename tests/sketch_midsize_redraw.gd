extends SceneTree
## F3 of docs/parity-followups-investigation.md (C1): what redrawing a mid-size sketch does and costs, on the real backend's answers for it (tests/fixtures/sketch_midsize_state.json:
## 10 dimensioned rectangles with a circle each and a 20-point dimensioned chain, made by tests/helpers/make_sketch_midsize_fixture.gd) loaded into the editor's session, no backend.
## What is ASSERTED is deterministic (tests/README.md: no test decides on elapsed time): counts of what the redraws did (view.stats: dimension passes, layouts, room scans, labels
## made, entities drawn), and that nothing kept between redraws is stale (the warm drawing equals a cold one, mesh for mesh and label for label).
##   * `_refresh_view` makes ONE dimension pass (it made two) and, with nothing changed, no layout, no scan, no label and no entity drawing; a hover between two labels makes no label
##     and no layout; a picked entity redraws that entity.
##   * a drag frame redraws the entities of the moved points, lays out only the dimensions that touch them, scans nothing for room (each keeps its side) and makes no label.
##   * mid-drag the geometry and the glyphs are exactly a cold redraw's, every dimension is a cold layout's (or the same on the other side of its line), and B puts it all back.
## What is PRINTED (`SMOKE BENCH`): `_refresh_view`, a hover, and a drag frame's redraw in ms, headless on a dummy renderer (script time only, no GPU upload or draw cost). With
## DIDSA_ENFORCE_TIMING=1 they are also gated: `_refresh_view` under a fifth of the 38.4 ms the investigation measured (43.1 ms measured again before F3 on the machine these were
## written on) and a drag frame's redraw under 3 ms, both scaled by how much slower a calibration workload runs here.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_midsize_redraw.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")

const REFRESH_CEILING_MS := 7.6 ## a fifth of 38.4 ms
const DRAG_CEILING_MS := 3.0
const WORKLOAD_REFERENCE_MS := 12.5 ## the calibration workload on the machine the numbers in docs/parity-followups-investigation.md (tracker row F3) were taken on

var rig
var ed
var s
var failures := 0
var enforce := OS.get_environment("DIDSA_ENFORCE_TIMING") == "1"


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _gate(ok: bool, label: String) -> void:
	## A timing: printed always, a failure only when DIDSA_ENFORCE_TIMING=1.
	if enforce:
		_check(ok, label)
	else:
		print("SMOKE BENCH ", label, " (not enforced; DIDSA_ENFORCE_TIMING=1 enforces): ", "within" if ok else "OVER")


func median(arr: Array) -> float:
	var a := arr.duplicate()
	a.sort()
	return float(a[a.size() / 2]) if not a.is_empty() else 0.0


func quiet(arr: Array) -> float:
	## The lower quartile: a shared CPU's stalls land in the slow half of the runs, so this is what the code costs when nothing else is running (the gates use it).
	var a := arr.duplicate()
	a.sort()
	return float(a[a.size() / 4]) if not a.is_empty() else 0.0


func worst(arr: Array) -> float:
	var m := 0.0
	for v in arr:
		m = maxf(m, float(v))
	return m


func time_ms(callable: Callable, runs: int) -> Array:
	var out: Array = []
	for i in runs:
		var t0 := Time.get_ticks_usec()
		callable.call()
		out.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	return out


func speed_factor() -> float:
	## How many times slower than the machine these numbers were taken on this one is (never below 1): a fixed GDScript workload of the kind the redraw is made of (vector
	## maths in a loop, dictionary lookups), the median of five runs.
	var runs: Array = []
	for r in 5:
		var t0 := Time.get_ticks_usec()
		var acc := 0.0
		var d := {}
		for i in 60000:
			var a := Vector2(float(i), 1.5)
			var b := Vector2(2.0, float(i % 97))
			acc += a.distance_to(b) + a.dot(b)
			d[i % 211] = a
			if d.has((i + 7) % 211):
				acc += (d[(i + 7) % 211] as Vector2).x
		runs.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	var ms := median(runs)
	print("SMOKE BENCH the calibration workload takes %.2f ms here against %.2f ms on the machine the ceilings were set on" % [ms, WORKLOAD_REFERENCE_MS])
	return maxf(1.0, ms / WORKLOAD_REFERENCE_MS)


func mesh_signature(node: MeshInstance3D) -> int:
	## A hash of every vertex and colour of a drawing node's one surface (0: none).
	if node.mesh == null:
		return 0
	var arrays: Array = (node.mesh as ArrayMesh).surface_get_arrays(0)
	return hash([hash(arrays[Mesh.ARRAY_VERTEX]), hash(arrays[Mesh.ARRAY_COLOR])])


func labels_signature(parent: Node) -> int:
	## The text, place, colour and outline of every label under `parent`, in child order, hashed.
	var rows: Array = []
	for l in parent.get_children():
		var lab := l as Label3D
		rows.append([lab.text, lab.transform, lab.modulate, lab.outline_size, lab.outline_modulate, lab.visible])
	return hash(rows)


func drawing_signature() -> Array:
	var v = ed.view
	return [mesh_signature(v._geo), mesh_signature(v._dims), labels_signature(v._labels), labels_signature(v._constraint_labels), v._labels.get_child_count(), v._constraint_labels.get_child_count(), v._annotation_hits.size()]


func stats_now() -> Dictionary:
	return (ed.view.stats as Dictionary).duplicate()


func since(before: Dictionary, key: String) -> int:
	return int(ed.view.stats[key]) - int(before[key])


func _initialize() -> void:
	rig = Rig.new()
	await rig.boot(self)
	ed = rig.ed
	await rig.draw_rectangle() # a sketch open on the fake backend: the fixture's answers replace what it holds
	s = ed.session
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/sketch_midsize_state.json"))
	s._ingest_state(fx["state"])
	s._ingest_entities(fx["export"])
	s.origin_id = str(fx["origin_point_id"])
	s.clear_selection()
	rig.table.manager.activate("select")
	await rig.frames(3)
	ed._refresh_view()
	var n_dims: int = s.dimension_items().size()
	var n_glyphs: int = s.constraint_items().size()
	print("SMOKE the fixture in the session: %d points, %d lines, %d circles, %d constraints, %d dimensions drawn, %d glyphs drawn" % [s.points.size(), s.lines.size(), s.circles.size(), s.constraints.size(), n_dims, n_glyphs])
	_check(s.points.size() > 100 and s.lines.size() > 70 and s.circles.size() == 10 and n_dims > 35 and n_glyphs > 60, "the mid-size sketch is a mid-size sketch")
	_check(ed.view._labels.get_child_count() == n_dims and ed.view._constraint_labels.get_child_count() == n_glyphs, "a label for every dimension and every glyph")
	var speed := speed_factor()
	var cold_sig := drawing_signature()
	print("SMOKE drawing signature: ", cold_sig)

	# --- _refresh_view: one dimension pass; with nothing changed nothing is laid out, scanned, made or drawn again
	var before := stats_now()
	ed._refresh_view()
	_check(since(before, "passes") == 1, "one _refresh_view makes ONE dimension pass (%d)" % since(before, "passes"))
	_check(since(before, "layouts") == 0 and since(before, "scans") == 0 and since(before, "labels_made") == 0 and since(before, "pieces_drawn") == 0,
		"...and with nothing changed no layout, no room scan, no label and no entity is made again (%d / %d / %d / %d)" % [since(before, "layouts"), since(before, "scans"), since(before, "labels_made"), since(before, "pieces_drawn")])
	_check(drawing_signature() == cold_sig, "the redraws change nothing: the same meshes and labels")
	for i in 3:
		ed._refresh_view() # warm up
	var refresh: Array = time_ms(func() -> void: ed._refresh_view(), 40)
	var rebuild: Array = time_ms(func() -> void: ed.view.rebuild(s, [], {}), 20)
	var dim_items: Array = time_ms(func() -> void: s.dimension_items(), 20)
	var glyph_items: Array = time_ms(func() -> void: s.constraint_items(), 20)
	print("SMOKE BENCH _refresh_view: median %.2f ms, lower quartile %.2f ms, worst %.2f ms" % [median(refresh), quiet(refresh), worst(refresh)])
	print("SMOKE BENCH view.rebuild alone: median %.2f ms; dimension_items %.2f ms, constraint_items %.2f ms (medians)" % [median(rebuild), median(dim_items), median(glyph_items)])
	_gate(quiet(refresh) < REFRESH_CEILING_MS * speed, "_refresh_view lower quartile %.2f ms against %.1f ms (a fifth of the 38.4 ms before F3, scaled by %.2f)" % [quiet(refresh), REFRESH_CEILING_MS * speed, speed])

	# --- a hover between two labels, a picked entity
	var ids: Array = []
	for it in s.dimension_items():
		ids.append(str(it["id"]))
	before = stats_now()
	var hover_ms: Array = []
	for i in 20:
		var t0 := Time.get_ticks_usec()
		ed.view.set_annotation_hover("dimension:%s" % ids[i % 2])
		hover_ms.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	print("SMOKE BENCH a hover change between two labels: median %.2f ms, worst %.2f ms" % [median(hover_ms), worst(hover_ms)])
	_check(since(before, "labels_made") == 0 and since(before, "layouts") == 0 and since(before, "scans") == 0 and since(before, "passes") == 20,
		"hovering between two labels makes no label, no layout and no scan, one pass per change (%d / %d / %d / %d)" % [since(before, "labels_made"), since(before, "layouts"), since(before, "scans"), since(before, "passes")])
	_check(since(before, "pieces_drawn") < 20 * 12, "...and redraws only what it lights (%d entities over 20 changes, of %d)" % [since(before, "pieces_drawn"), ed.view._geo_pieces.size()])
	ed.view.set_annotation_hover("")
	_check(drawing_signature() == cold_sig, "after the hover is gone the drawing is the cold one again")
	var some_line := str(s.lines.keys()[3])
	before = stats_now()
	s.selection = [{"kind": "line", "id": some_line}]
	ed._refresh_view()
	_check(since(before, "pieces_drawn") <= 4 and since(before, "layouts") == 0, "picking a line redraws that line, not the sketch (%d entities, %d layouts)" % [since(before, "pieces_drawn"), since(before, "layouts")])
	s.clear_selection()
	ed._refresh_view()
	_check(drawing_signature() == cold_sig, "...and letting go puts the drawing back")

	# --- drag frames: the 20-point chain (grab its 10th point), then a rectangle corner
	ed.point_drag.synchronous = true
	var xs: Array = []
	for id in s.points:
		if (s.points[id] as Vector2).y < -30.0:
			xs.append([(s.points[id] as Vector2).x, str(id)])
	xs.sort_custom(func(a, b): return a[0] < b[0])
	var chain_point := str(xs[10][1])
	var corner := ""
	for id in s.points:
		if (s.points[id] as Vector2).distance_to(Vector2(-90.0 + 18.0, 30.0 + 10.0)) < 0.5:
			corner = str(id)
	_check(chain_point != "" and corner != "" and xs.size() >= 20, "setup: a chain point (%d chain points) and a rectangle corner to grab" % xs.size())
	for grab in [chain_point, corner]:
		var from: Vector2 = s.points[grab]
		ed._hover_uv = from
		ed._begin_point_hold({"kind": "point", "id": grab})
		var held: bool = not ed._label_hold.is_empty()
		var totals: Array = []
		var drag_before := stats_now()
		for i in 31:
			var angle := float(i) * 0.4
			var uv := from + Vector2(8.0, 0.0) + Vector2(cos(angle) - 1.0, sin(angle)) * 2.0 + Vector2(0.1 * i, 0.0)
			var t0 := Time.get_ticks_usec()
			ed._point_drag_move(uv)
			totals.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		var projector: Array = ed.point_drag.frame_ms.duplicate() # (cleared when the drag begins)
		var redraw: Array = ed.drag_redraw_ms.duplicate()
		var frames_redrawn: int = since(drag_before, "moved_passes")
		print("SMOKE drag of %s: held %s, %d projector frames, %d redraws" % [grab, str(held), projector.size(), redraw.size()])
		print("SMOKE BENCH drag of %s: projector median %.2f ms (worst %.2f), frame total median %.2f ms (worst %.2f)" % [grab, median(projector), worst(projector), median(totals), worst(totals)])
		print("SMOKE BENCH ...redraw after the projector: median %.2f ms, lower quartile %.2f ms, worst %.2f ms (%d frames; the first builds the index of what each point touches)" % [median(redraw), quiet(redraw), worst(redraw), redraw.size()])
		_check(held and ed.point_dragging() and projector.size() >= 10 and frames_redrawn == redraw.size() and frames_redrawn >= 10, "the drag of %s ran (%d projector frames, %d frames redrawn by redraw_moved)" % [grab, projector.size(), frames_redrawn])
		_check(since(drag_before, "passes") == 0 and since(drag_before, "scans") == 0 and since(drag_before, "labels_made") == 0,
			"a drag frame makes no full pass, scans no room (a dimension keeps its side) and makes no label (%d / %d / %d)" % [since(drag_before, "passes"), since(drag_before, "scans"), since(drag_before, "labels_made")])
		_check(since(drag_before, "layouts") <= 20 * frames_redrawn and since(drag_before, "pieces_drawn") <= 80 * frames_redrawn,
			"...only what the moved points touch is laid out and drawn (%d layouts and %d entities over %d frames, of %d dimensions and %d entities)" % [since(drag_before, "layouts"), since(drag_before, "pieces_drawn"), frames_redrawn, n_dims, ed.view._geo_pieces.size()])
		_gate(quiet(redraw) < DRAG_CEILING_MS * speed, "a drag frame's redraw of %s: lower quartile %.2f ms against %.1f ms" % [grab, quiet(redraw), DRAG_CEILING_MS * speed])
		# mid-drag, what the incremental redraw kept is not stale: every dimension is laid out as a cold layout lays it out, except that it keeps the side it stood on (a drag
		# does not flip a dimension to the other side of its line, the drop's full redraw settles it), and the geometry and every glyph are exactly what a cold redraw draws
		var wrong := 0
		var other_side := 0
		for item in s.dimension_items():
			var entry: Dictionary = ed.view._dim_cache.get("dimension:" + str(item["id"]), {})
			var cold_layout: Dictionary = ed.view._layout_for(item["spec"], str(item["text"]), s)
			if entry.is_empty() or entry["spec"] != item["spec"]:
				wrong += 1
			elif entry["layout"]["text_uv"] != cold_layout["text_uv"] or entry["layout"]["segments"] != cold_layout["segments"]:
				if cold_layout.has("side") and entry["layout"].get("side", 0.0) != cold_layout["side"]:
					other_side += 1
				else:
					wrong += 1
		_check(wrong == 0, "mid-drag every dimension is as a cold layout lays it out (%d kept the other side of their line, %d wrong)" % [other_side, wrong])
		var mid_geo := mesh_signature(ed.view._geo)
		var mid_glyphs := labels_signature(ed.view._constraint_labels)
		ed.view.invalidate_caches()
		ed.view.rebuild(s, s.selection, {})
		_check(mesh_signature(ed.view._geo) == mid_geo and labels_signature(ed.view._constraint_labels) == mid_glyphs, "mid-drag the geometry and the glyphs are exactly what a cold redraw of the same points draws")
		ed._cancel_point_hold()
		await rig.frames(2)
		_check(drawing_signature() == cold_sig, "put back (B): the drawing is the cold one again")

	ed.point_drag.wait_all()
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
