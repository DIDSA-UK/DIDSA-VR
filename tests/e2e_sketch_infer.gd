extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): the relationships the design
## table's sketcher infers while a line is drawn, against the REAL constraint schemas and solver. A new part and a sketch on XY; the snap resolver
## (scripts/design_table/snap_resolver.gd) is asked where each end lands and what it is inferred to be, and its pick is handed to the session as the
## table editor does: an L with a horizontal first leg and a perpendicular second leg; a line tangent to a circle; a line ending on a circle; a
## circle whose centre is put on another's (concentric); a point held at a sketch line's middle; the origin not welded. Each constraint is read back
## from the backend's own list and the solved geometry is checked.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_infer.gd   (DIDSA_NO_LANDING=1, secrets.cfg pointing at a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const SnapResolver := preload("res://scripts/design_table/snap_resolver.gd")

var main
var table
var s


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func snap(aim: Vector2, start: Variant = null, extra: Dictionary = {}) -> Dictionary:
	## The pick the editor would make: the resolver's answer at `aim`, in the shape `session.tap` takes.
	var opts := {"infer": true, "woken": []}
	if start != null:
		opts["start_id"] = str(extra.get("start_id", ""))
	opts.merge(extra, true)
	var r: Dictionary = SnapResolver.resolve(aim, s, 3.0, true, [], start, null, opts)
	var pick := {"uv": r["uv"], "id": r["id"]}
	if not (r["infer"] as Dictionary).is_empty():
		pick["infer"] = r["infer"]
	if r.has("target"):
		pick["target"] = r["target"]
		pick["snap"] = r["kind"]
	return pick


func constraints_of(type: String) -> Array:
	return s.constraints.values().filter(func(c): return str(c.get("type", "")) == type)


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
	table.surface.settle_seconds = 0.0

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")
	var opened: bool = await table.editor.begin_sketch({"fixed": "XY"})
	s = table.editor.session
	print("SMOKE a sketch opens on XY: ", opened and s.is_open())

	# --- a horizontal line, then an L whose second leg is perpendicular to the first
	s.set_tool("line")
	await s.tap({"uv": Vector2(20, 20)})
	var aim_end := Vector2(80, 21.5) # 1.4 degrees off flat
	var first_end := snap(aim_end, Vector2(20, 20), {"start_id": str(s.pending[0].get("id", ""))})
	print("SMOKE the resolver pulls a line's end onto the axis and calls it horizontal: ", first_end.get("infer", {}).get("kind", "") == "horizontal" and first_end["uv"] == Vector2(80, 20))
	await s.tap(first_end)
	var flat: String = s.lines.keys()[0]
	print("SMOKE ...and the backend holds the line horizontal: ", constraints_of("horizontal").size() == 1 and constraints_of("horizontal")[0]["line_id"] == flat and s.converged)
	s.finish_chain()
	await s.tap({"uv": Vector2(20, 60)})
	var leg1_pick := snap(Vector2(80, 85), Vector2(20, 60), {"start_id": str(s.pending[0].get("id", ""))})
	await s.tap(leg1_pick)
	var leg1: String = s.lines.keys().back()
	var leg1_end: String = s.lines[leg1]["b"]
	var leg1_dir: Vector2 = (s.points[leg1_end] - s.points[s.lines[leg1]["a"]]).normalized()
	var turned := leg1_dir.rotated(deg_to_rad(-90.0 + 2.0)) # a little off a right angle to the first leg, from its end
	var second_end := snap(s.points[leg1_end] + turned * 45.0, s.points[leg1_end], {"start_id": leg1_end, "woken": []})
	print("SMOKE continuing the run, a second leg at right angles to the first (the segment the run continues, no waking needed) is inferred perpendicular: ", second_end.get("infer", {}).get("kind", "") == "perpendicular" and second_end["infer"]["target"]["id"] == leg1)
	await s.tap(second_end)
	var leg2: String = s.lines.keys().back()
	var perp := constraints_of("perpendicular")
	var d1: Vector2 = s.points[s.lines[leg1]["b"]] - s.points[s.lines[leg1]["a"]]
	var d2: Vector2 = s.points[s.lines[leg2]["b"]] - s.points[s.lines[leg2]["a"]]
	print("SMOKE ...the backend keeps it: ONE perpendicular constraint between the two legs, solved: ", perp.size() == 1 and [str(perp[0]["line1_id"]), str(perp[0]["line2_id"])].has(leg1) and [str(perp[0]["line1_id"]), str(perp[0]["line2_id"])].has(leg2) and s.converged and absf(d1.normalized().dot(d2.normalized())) < 0.001)
	s.finish_chain()

	# --- a line tangent to a circle
	s.set_tool("circle")
	await s.tap({"uv": Vector2(150, 60)})
	await s.tap({"uv": Vector2(170, 60)})
	var circle: String = s.circles.keys()[0]
	s.set_tool("line")
	await s.tap({"uv": Vector2(100, 0)})
	var start_pick: Dictionary = s.pending[0]
	var to_centre := Vector2(150, 60) - Vector2(100, 0)
	var tangent_dir := to_centre.rotated(-asin(20.0 / to_centre.length())) # one of the two tangent lines, the lower one
	var tangent_aim := Vector2(100, 0) + tangent_dir.rotated(deg_to_rad(2.0)).normalized() * 70.0
	var tangent_pick := snap(tangent_aim, Vector2(100, 0), {"start_id": str(start_pick.get("id", ""))})
	print("SMOKE aiming a little off a tangent from the line's start, the resolver finds the tangent to the circle: ", tangent_pick.get("infer", {}).get("kind", "") == "tangent" and tangent_pick["infer"]["target"]["id"] == circle)
	await s.tap(tangent_pick)
	var tangent_line: String = s.lines.keys().back()
	var la: Vector2 = s.points[s.lines[tangent_line]["a"]]
	var lb: Vector2 = s.points[s.lines[tangent_line]["b"]]
	var centre: Vector2 = s.points[s.circles[circle]["c"]]
	var radius: float = centre.distance_to(s.points[s.circles[circle]["p"]])
	print("SMOKE ...the backend makes the line really tangent: one tangent constraint, solved, the centre is a radius from the line: ", constraints_of("tangent").size() == 1 and s.converged and absf(absf((centre - la).cross((lb - la).normalized())) - radius) < 0.05)
	s.finish_chain()

	# --- a line ending on a circle
	await s.tap({"uv": Vector2(150, 140)})
	var on_start: Dictionary = s.pending[0]
	var on_pick := snap(Vector2(150, 83.5), Vector2(150, 140), {"start_id": str(on_start.get("id", ""))})
	print("SMOKE a line aimed at the circle from above ends ON it, inferred as a point on the curve: ", on_pick.get("infer", {}).get("kind", "") == "on_curve" and on_pick["infer"]["target"]["id"] == circle)
	await s.tap(on_pick)
	var on_line: String = s.lines.keys().back()
	var on_end: Vector2 = s.points[s.lines[on_line]["b"]]
	print("SMOKE ...held there by the backend (a point-on-circle constraint on the end), and the end is on the circle: ", constraints_of("point_on_circle").size() >= 1 and s.converged and absf(on_end.distance_to(centre) - radius) < 0.05)
	s.finish_chain()

	# --- a circle whose centre is put on another's
	s.set_tool("circle")
	var conc_pick := snap(Vector2(153.2, 60), null, {"concentric": true})
	print("SMOKE a centre placed a little off the first circle's centre (outside the point snap) is put exactly on it and inferred concentric: ", conc_pick.get("infer", {}).get("kind", "") == "concentric" and conc_pick["uv"].is_equal_approx(centre))
	await s.tap(conc_pick)
	await s.tap({"uv": Vector2(158, 60)})
	var second_circle: String = s.circles.keys().back()
	var c2: Vector2 = s.points[s.circles[second_circle]["c"]]
	print("SMOKE ...and the backend holds the two concentric: ", constraints_of("concentric").size() == 1 and s.converged and c2.distance_to(centre) < 0.01)

	# --- the origin is not welded; the middle of a line holds a point
	s.set_tool("line")
	var origin_pick := snap(Vector2(0.4, 0.3), null, {})
	await s.tap(origin_pick)
	var o_end := snap(Vector2(40, 30), s.pending[0]["uv"], {"start_id": str(s.pending[0].get("id", ""))})
	await s.tap(o_end)
	var from_origin: String = s.lines.keys().back()
	var weld: String = s.lines[from_origin]["a"]
	var coincident_to_origin := constraints_of("coincident").filter(func(c): return [str(c["point_a_id"]), str(c["point_b_id"])].has(weld) and [str(c["point_a_id"]), str(c["point_b_id"])].has(s.origin_id))
	print("SMOKE a line from the origin gets a start point of its own, held on the origin: ", weld != s.origin_id and s.points[weld] == Vector2.ZERO and coincident_to_origin.size() == 1)
	s.finish_chain()
	var mid_pick := snap(Vector2(20.5, 15.5), null, {})
	print("SMOKE aiming at that line's middle snaps to it and names the line: ", mid_pick.get("snap", "") == "midpoint" and mid_pick["target"]["id"] == from_origin)
	s.set_tool("point")
	await s.tap(mid_pick)
	var held: Array = constraints_of("at_midpoint").filter(func(c): return str(c["line_id"]) == from_origin)
	print("SMOKE ...and the point there is held by an at-midpoint constraint: ", held.size() == 1 and s.converged)
	print("SMOKE e2e done: ", true)
	quit()
