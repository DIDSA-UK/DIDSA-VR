extends SceneTree
## Phase 7.4: the other ways to make a circle, rectangle and line, and the point-on-ellipse constraint, against the fake backend (tests/helpers/fake_cad.gd). The geometry is pure
## (sketch_math.gd): the circle through three points, the rectangle from its centre and a corner or from one side and the width, a line's other end from its middle. The session makes
## each with the calls pinned: a 3-point circle is its computed centre and the first point as the radius point with the other two held on it (point-on-circle); a centre rectangle is
## axis aligned, a 3-point one is turned; a line from its middle is held at its midpoint. Each is one undo step. The Select menu offers On ellipse for a point and an ellipse.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_methods.gd  (see tests/README.md)

const Session := preload("res://scripts/design_table/sketch_session.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const SketchSelection := preload("res://scripts/design_table/sketch_selection.gd")

var fake: Fake
var s


func fresh(tool_id: String) -> void:
	fake = Fake.new()
	s = Session.new(Callable(fake, "handle"))
	s.owner_part_id = "P"
	await s.open_sketch({"fixed": "XY"})
	fake.calls.clear()
	s.set_tool(tool_id)


func tap(x: float, y: float) -> Dictionary:
	return await s.tap({"uv": Vector2(x, y), "id": ""})


func bodies_of(fragment: String) -> Array:
	return fake.calls.filter(func(c): return String(c[0]).contains(fragment) and String(c[0]).begins_with("POST")).map(func(c): return c[1])


func near(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.001


func _initialize() -> void:
	# --- pure geometry
	var fit := SketchMath.circumcircle(Vector2(0, 0), Vector2(10, 0), Vector2(0, 10))
	print("SMOKE The circle through (0,0), (10,0), (0,10) has its centre at (5,5) and radius 7.071: ", bool(fit["ok"]) and near(fit["centre"], Vector2(5, 5)) and absf(float(fit["radius"]) - 7.0710678) < 0.001)
	print("SMOKE ...three points in a line have no circle: ", not bool(SketchMath.circumcircle(Vector2(0, 0), Vector2(5, 5), Vector2(10, 10))["ok"]))
	var rc := SketchMath.rect_from_centre(Vector2(10, 10), Vector2(13, 12))
	print("SMOKE A rectangle from its centre (10,10) and a corner (13,12) is 6 x 4, corners in order: ", rc.size() == 4 and near(rc[0], Vector2(7, 8)) and near(rc[1], Vector2(13, 8)) and near(rc[2], Vector2(13, 12)) and near(rc[3], Vector2(7, 12)))
	print("SMOKE ...a corner level with the centre has no rectangle: ", SketchMath.rect_from_centre(Vector2(0, 0), Vector2(5, 0)).is_empty())
	var r3 := SketchMath.rect_from_three(Vector2(0, 0), Vector2(10, 0), Vector2(5, 4))
	print("SMOKE A rectangle from one side (0,0)-(10,0) and a point 4 above it is 10 x 4: ", r3.size() == 4 and near(r3[2], Vector2(10, 4)) and near(r3[3], Vector2(0, 4)))
	print("SMOKE ...a point below the side makes it on that side: ", near(SketchMath.rect_from_three(Vector2(0, 0), Vector2(10, 0), Vector2(5, -4))[2], Vector2(10, -4)))
	var turned := SketchMath.rect_from_three(Vector2(0, 0), Vector2(10, 10), Vector2(0, 10))
	print("SMOKE ...a slanted side gives a turned rectangle (all four angles square): ", turned.size() == 4 and absf((turned[1] - turned[0]).dot(turned[3] - turned[0])) < 0.001 and absf((turned[2] - turned[1]).dot(turned[1] - turned[0])) < 0.001)
	print("SMOKE ...no side, or a point on the side, has none: ", SketchMath.rect_from_three(Vector2(1, 1), Vector2(1, 1), Vector2(5, 5)).is_empty() and SketchMath.rect_from_three(Vector2(0, 0), Vector2(10, 0), Vector2(4, 0)).is_empty())
	print("SMOKE A line's other end is the first end reflected through its middle: ", near(SketchMath.mirrored_end(Vector2(5, 5), Vector2(8, 6)), Vector2(2, 4)))

	# --- 3-point circle
	await fresh("circle")
	print("SMOKE A circle takes two taps by default: ", s.taps_needed() == 2 and s.preview_id() == "circle")
	s.set_method("circle", "three")
	print("SMOKE ...three in 3 points mode, with its own rubber band: ", s.taps_needed() == 3 and s.preview_id() == "circle3")
	var r := await tap(0, 0)
	r = await tap(10, 0)
	print("SMOKE ...two taps make nothing yet: ", not r["done"] and fake.count("/circles") == 0)
	r = await tap(0, 10)
	print("SMOKE ...the third makes one circle and holds the second and third points on it: ", r["done"] and fake.count("/circles") == 1 and fake.count("/constraints") == 2, " ", fake.paths())
	var centre_post: Dictionary = bodies_of("/points").back()
	print("SMOKE ...the last point made is the computed centre (5, 5): ", absf(float(centre_post["x"]) - 5.0) < 0.001 and absf(float(centre_post["y"]) - 5.0) < 0.001, " ", centre_post)
	var cons: Array = bodies_of("/constraints")
	var circle_body: Dictionary = bodies_of("/circles")[0]
	print("SMOKE ...both constraints are point_on_circle for the circle just made, not for the radius point: ", cons.size() == 2 and cons.all(func(c): return c["type"] == "point_on_circle" and c["circle_or_arc_id"] != "" and c["point_id"] != circle_body["radius_point_id"]), " ", cons)
	var before_undo: int = fake.count("DELETE")
	await s.undo()
	print("SMOKE ...Undo takes the constraints and the circle back in one step: ", fake.count("DELETE") - before_undo == 3 and fake.count("/constraints/") >= 2 and not s.can_undo(), " ", fake.paths().slice(before_undo))
	fake.calls.clear()
	await tap(0, 0)
	await tap(5, 5)
	r = await tap(10, 10)
	print("SMOKE Three points in a line are refused with a reason and nothing is made: ", not r["ok"] and fake.count("/circles") == 0 and fake.count("/constraints") == 0 and fake.count("/points") == 0)
	s.set_method("circle", "centre")
	print("SMOKE Going back to Centre restores two taps and forgets taps placed: ", s.taps_needed() == 2 and s.pending.is_empty() and s.preview_id() == "circle")

	# --- rectangles
	await fresh("rectangle")
	s.set_method("rectangle", "centre")
	print("SMOKE A rectangle from its centre takes two taps and is axis aligned: ", s.taps_needed() == 2 and s.preview_id() == "rect_centre")
	await tap(10, 10)
	r = await tap(13, 12)
	var rb: Dictionary = bodies_of("/rectangles")[0]
	print("SMOKE ...it makes four corner points and one rectangle with axis_aligned true: ", r["done"] and fake.count("/points") == 4 and (rb["corner_point_ids"] as Array).size() == 4 and rb["axis_aligned"] == true)
	var xs: Array = bodies_of("/points").map(func(p): return [snappedf(float(p["x"]), 0.001), snappedf(float(p["y"]), 0.001)])
	print("SMOKE ...at 7,8 / 13,8 / 13,12 / 7,12: ", xs == [[7.0, 8.0], [13.0, 8.0], [13.0, 12.0], [7.0, 12.0]], " ", xs)
	await fresh("rectangle")
	s.set_method("rectangle", "centre")
	await tap(0, 0)
	r = await tap(5, 0)
	print("SMOKE ...a corner level with the centre is refused: ", not r["ok"] and fake.count("/rectangles") == 0)
	await fresh("rectangle")
	s.set_method("rectangle", "three")
	print("SMOKE A rectangle from one side and the width takes three taps: ", s.taps_needed() == 3 and s.preview_id() == "rect3")
	await tap(0, 0)
	await tap(10, 0)
	r = await tap(5, 4)
	rb = bodies_of("/rectangles")[0]
	xs = bodies_of("/points").map(func(p): return [snappedf(float(p["x"]), 0.001), snappedf(float(p["y"]), 0.001)])
	print("SMOKE ...it makes the four corners and a rectangle that is NOT axis aligned: ", r["done"] and rb["axis_aligned"] == false and xs == [[0.0, 0.0], [10.0, 0.0], [10.0, 4.0], [0.0, 4.0]], " ", xs)
	await fresh("rectangle")
	s.set_method("rectangle", "three")
	await tap(0, 0)
	await tap(10, 0)
	r = await tap(4, 0)
	print("SMOKE ...a third point on the side is refused: ", not r["ok"] and fake.count("/rectangles") == 0)
	await fresh("rectangle")
	s.set_method("rectangle", "three")
	await s.tap({"uv": Vector2(0, 0), "id": "pt_existing"})
	await s.tap({"uv": Vector2(10, 0), "id": ""})
	await s.tap({"uv": Vector2(5, 4), "id": ""})
	rb = bodies_of("/rectangles")[0]
	print("SMOKE ...a first tap on an existing point keeps that point as the first corner: ", (rb["corner_point_ids"] as Array)[0] == "pt_existing" and fake.count("/points") == 3, " ", rb)

	# --- line from its middle
	await fresh("line")
	print("SMOKE A line is end to end by default (chained): ", s.line_method == "ends" and s.taps_needed() == 2 and s.preview_id() == "line")
	s.set_method("line", "middle")
	print("SMOKE ...from the middle it has its own rubber band: ", s.preview_id() == "line_mid")
	await tap(5, 5)
	r = await tap(8, 5)
	var pts: Array = bodies_of("/points").map(func(p): return [snappedf(float(p["x"]), 0.001), snappedf(float(p["y"]), 0.001)])
	print("SMOKE ...the middle then one end make the middle, that end and the reflected end: ", r["done"] and pts == [[5.0, 5.0], [8.0, 5.0], [2.0, 5.0]], " ", pts)
	var line_body: Dictionary = bodies_of("/lines")[0]
	var mid_c: Dictionary = bodies_of("/constraints")[0]
	print("SMOKE ...one line from the far end to the tapped end, with the middle held at its midpoint: ", fake.count("/lines") == 1 and mid_c["type"] == "at_midpoint" and mid_c["line_id"] != "" and mid_c["point_id"] != line_body["start_point_id"] and mid_c["point_id"] != line_body["end_point_id"], " ", mid_c, " ", line_body)
	print("SMOKE ...it does not chain: the next tap starts afresh: ", s.pending.is_empty())
	before_undo = fake.count("DELETE")
	await s.undo()
	print("SMOKE ...Undo takes the constraint and the line back: ", fake.count("DELETE") - before_undo == 2)

	# --- point on ellipse
	await fresh("select")
	s.points = {"p1": Vector2(3, 0)}
	s.ellipses = {"e1": {"c": "pc", "ma": "pm", "mi": "pn", "construction": false}}
	s.selection = [{"kind": "point", "id": "p1"}, {"kind": "ellipse", "id": "e1"}]
	var ids := SketchSelection.constraint_ids(s.selection, s)
	print("SMOKE A point and an ellipse selected offer On ellipse: ", ids == ["point_on_ellipse"], " ", ids)
	print("SMOKE ...and no other pair does (a point and a circle still offer On curve): ", SketchSelection.constraint_ids([{"kind": "point", "id": "p1"}, {"kind": "circle", "id": "c1"}], s) == ["point_on_curve"] and SketchSelection.constraint_ids([{"kind": "ellipse", "id": "e1"}, {"kind": "ellipse", "id": "e2"}], s).is_empty())
	var labelled: Array = SketchSelection.options(s.selection, s, [])
	print("SMOKE ...labelled On ellipse in the menu: ", labelled.any(func(o): return o["id"] == "point_on_ellipse" and o["text"] == "On ellipse"))
	fake.calls.clear()
	r = await s.apply_menu("point_on_ellipse")
	print("SMOKE ...applying it posts point_on_ellipse with the point and the ellipse: ", bodies_of("/constraints") == [{"type": "point_on_ellipse", "point_id": "p1", "ellipse_id": "e1"}], " ", bodies_of("/constraints"))
	quit()
