extends SceneTree
## The design table's pure logic, no scene tree (scripts/design_table/): the tool-row
## pager ("More" slot), the tool registration (real DIDSA-CAD names, one active tool),
## the sketch-plane maths (fixed planes, turning a part to lie on the table, ray to
## sheet), the seat / lift numbers and the pose maths (two-hand move / turn / scale, stick, nudge, engagement).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_logic.gd  (see tests/README.md)

const Pager := preload("res://scripts/design_table/tool_pager.gd")
const SketchSelection := preload("res://scripts/design_table/sketch_selection.gd")
const SketchView := preload("res://scripts/design_table/sketch_view.gd")
const DimLayout := preload("res://scripts/design_table/dimension_layout.gd")
const TableTools := preload("res://scripts/design_table/table_tools.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TableSeat := preload("res://scripts/design_table/table_seat.gd")
const Snap := preload("res://scripts/design_table/snap_resolver.gd")
const TablePose := preload("res://scripts/design_table/table_pose.gd")
const TableResize := preload("res://scripts/design_table/table_resize.gd")


class Handler extends RefCounted:
	var log: Array = []
	func tool_activated(id: String) -> void: log.append("+" + id)
	func tool_deactivated(id: String) -> void: log.append("-" + id)


class SnapModel extends RefCounted:
	var points := {}
	var lines := {}
	var circles := {}
	var arcs := {}
	var origin_id := ""
	var references := {} ## id -> true: reference helpers (see sketch_session.gd reference_ids)

	func is_origin(id: String) -> bool:
		return origin_id != "" and id == origin_id

	func is_reference(id: String) -> bool:
		return references.has(id)


func _arrow_ok(view) -> bool:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	view._arrow(verts, colors, Vector2(10, 5), Vector2(0, 1), Color.WHITE)
	var length: float = view.ARROW_LENGTH / view.canvas_scale
	return verts.size() == 3 and colors.size() == 3 and Vector2(verts[0].x, verts[0].y).is_equal_approx(Vector2(10, 5)) and absf(verts[1].y - (5.0 - length)) < 0.001 and absf(verts[2].y - (5.0 - length)) < 0.001 and absf(verts[1].x - verts[2].x) > 0.1


func _near(a: Vector3, b: Vector3, eps := 0.0001) -> bool:
	return a.distance_to(b) < eps


func _initialize() -> void:
	# --- pager
	var six := ["a", "b", "c", "d", "e", "f"]
	var eleven := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"]
	var p6 := Pager.slots(six, 0)
	print("SMOKE six tools fit one page with no More: ", p6["tools"] == six and not p6["has_more"] and p6["pages"] == 1)
	var p3 := Pager.slots(["a", "b", "c"], 0)
	print("SMOKE fewer than six show as they are: ", p3["tools"].size() == 3 and not p3["has_more"])
	var p7 := Pager.slots(["1", "2", "3", "4", "5", "6", "7"], 0)
	print("SMOKE seven tools: five and a More slot, two pages: ", p7["tools"] == ["1", "2", "3", "4", "5"] and p7["has_more"] and p7["pages"] == 2)
	var p11 := Pager.slots(eleven, 2)
	print("SMOKE eleven tools, last page holds the last one: ", p11["tools"] == ["11"] and p11["pages"] == 3 and p11["page"] == 2)
	print("SMOKE a page past the end is clamped: ", Pager.slots(eleven, 9)["page"] == 2 and Pager.slots(eleven, -3)["page"] == 0)
	print("SMOKE More wraps round to the first page: ", Pager.next_page(0, 11) == 1 and Pager.next_page(2, 11) == 0 and Pager.next_page(0, 6) == 0)
	print("SMOKE the row never has more than six slots: ", Pager.slots(eleven, 0)["tools"].size() + 1 <= Pager.SLOTS)

	# --- tool registration
	var reg = load("res://scripts/ui/tablet_registry.gd").new()
	var mgr = load("res://scripts/ui/tool_manager.gd").new()
	var h := Handler.new()
	TableTools.register(reg, h)
	mgr.setup(reg)
	var ids: Array = []
	for c in reg.categories():
		for t in c.tools:
			ids.append(t.id)
	print("SMOKE categories are Sketch, Constrain, Feature: ", reg.categories().map(func(c): return c.label) == ["Sketch", "Constrain", "Feature"])
	print("SMOKE Sketch has Select first, then DIDSA-CAD's six drawing tools in the app's order: ", reg.category("sketch").tools.map(func(t): return t.id) == ["select", "line", "rectangle", "circle", "arc", "polygon", "point", "slot"])
	print("SMOKE only Sketch is over the six-slot row (eight tools, so it pages: Select, Line, Rectangle, Circle, Arc, More): ", reg.categories().filter(func(c): return c.tools.size() > Pager.SLOTS).map(func(c): return c.id) == ["sketch"] and Pager.slots(reg.category("sketch").tools, 0)["tools"].map(func(t): return t.id) == ["select", "line", "rectangle", "circle", "arc"])
	print("SMOKE five category slots are enough: ", reg.categories().size() <= 5)
	print("SMOKE every tool is a mode tool with a hint: ", reg.mode_tools().size() == ids.size() and ids.all(func(i): return reg.tool_def(i).hint != ""))
	mgr.activate("line")
	mgr.activate("dimension")
	print("SMOKE only one tool is active across categories: ", mgr.active_id == "dimension" and h.log == ["+line", "-line", "+dimension"])
	var missing: Array = ids.filter(func(i): return not load("res://scripts/ui/ui_icons.gd").has_icon(reg.tool_def(i).icon))
	print("SMOKE every tool has a real icon: ", missing.is_empty(), " ", missing)
	var cat_missing: Array = reg.categories().filter(func(c): return not load("res://scripts/ui/ui_icons.gd").has_icon(c.icon))
	print("SMOKE every category has a real icon: ", cat_missing.is_empty())

	# --- sketch maths
	for plane in ["XY", "XZ", "YZ"]:
		var b := SketchMath.fixed_basis(plane)
		print("SMOKE fixed plane %s is right-handed and orthonormal: " % plane, _near(b["x"].cross(b["y"]), b["n"]) and absf(b["x"].dot(b["y"])) < 0.0001)
	print("SMOKE XZ's x axis is -X (the backend's convention): ", _near(SketchMath.fixed_basis("XZ")["x"], Vector3(-1, 0, 0)))
	print("SMOKE an unknown plane gives nothing: ", SketchMath.fixed_basis("AB").is_empty())
	for plane in ["XY", "XZ", "YZ"]:
		var b2 := SketchMath.fixed_basis(plane)
		var r := SketchMath.orient_to_table(b2)
		print("SMOKE %s turned to the table: x to the right, y away, normal up: " % plane,
			_near(r * b2["x"], Vector3(1, 0, 0)) and _near(r * b2["y"], Vector3(0, 0, -1)) and _near(r * b2["n"], Vector3(0, 1, 0)))
	var tilted := {"origin": Vector3(5, 6, 7), "x": Vector3(0, 0, 1), "y": Vector3(1, 0, 0), "n": Vector3(0, 1, 0)}
	var rt := SketchMath.orient_to_table(tilted)
	print("SMOKE a custom plane also lies flat and the rotation is proper: ", _near(rt * tilted["n"], Vector3(0, 1, 0)) and absf(rt.determinant() - 1.0) < 0.0001)
	var from_resp := SketchMath.basis_from_plane_response({"origin": [1, 2, 3], "normal": [0, 0, 1], "x_axis": [1, 0, 0], "y_axis": [0, 1, 0]})
	print("SMOKE a create-plane response becomes a basis: ", _near(from_resp["origin"], Vector3(1, 2, 3)) and _near(from_resp["n"], Vector3(0, 0, 1)))
	print("SMOKE a response with null geometry gives nothing: ", SketchMath.basis_from_plane_response({"origin": null, "normal": null, "x_axis": null, "y_axis": null}).is_empty())
	var xy := SketchMath.fixed_basis("XY")
	var q := SketchMath.from_sheet(Vector2(10, 20), xy)
	print("SMOKE sheet to part and back: ", _near(q, Vector3(10, 20, 0)) and SketchMath.to_sheet(q, xy).is_equal_approx(Vector2(10, 20)))
	var xz := SketchMath.fixed_basis("XZ")
	print("SMOKE on XZ, sheet (10, 20) is part (-10, 0, 20): ", _near(SketchMath.from_sheet(Vector2(10, 20), xz), Vector3(-10, 0, 20)))
	var hit = SketchMath.ray_plane(Vector3(0, 5, 0), Vector3(0, -1, 0), Vector3.ZERO, Vector3(0, 1, 0))
	print("SMOKE a ray down onto the plane lands under the origin: ", hit != null and _near(hit, Vector3.ZERO))
	print("SMOKE a ray pointing away from the plane misses: ", SketchMath.ray_plane(Vector3(0, 5, 0), Vector3(0, 1, 0), Vector3.ZERO, Vector3(0, 1, 0)) == null)
	print("SMOKE a ray parallel to the plane misses: ", SketchMath.ray_plane(Vector3(0, 5, 0), Vector3(1, 0, 0), Vector3.ZERO, Vector3(0, 1, 0)) == null)
	var tri := PackedVector3Array([Vector3(0, 0, 2), Vector3(0, 4, 2), Vector3(4, 0, 2)]) # clockwise seen from +Z: Godot's front-face winding, so its outward normal is +Z
	var provisional := SketchMath.plane_from_face_triangles(tri)
	print("SMOKE a face's triangles give an outward normal: ", _near(provisional["n"], Vector3(0, 0, 1)) and absf(provisional["origin"].z - 2.0) < 0.0001)
	print("SMOKE ...and a right-handed basis: ", _near(provisional["x"].cross(provisional["y"]), provisional["n"]))
	print("SMOKE degenerate triangles give nothing: ", SketchMath.plane_from_face_triangles(PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])).is_empty())

	# --- seat / lift
	var box := AABB(Vector3(-10, -20, -30), Vector3(20, 40, 60))
	var s := TableSeat.fit_scale(box, 0.17)
	print("SMOKE the fitted part's bounding sphere is the fit radius: ", absf(box.size.length() * 0.5 * s - 0.17) < 0.0001)
	print("SMOKE an empty box fits at scale 0: ", TableSeat.fit_scale(AABB(), 0.17) == 0.0)
	var big := TableSeat.fit_scale(AABB(Vector3.ZERO, Vector3(1000, 1000, 1000)), 0.17)
	var small := TableSeat.fit_scale(AABB(Vector3.ZERO, Vector3(1, 1, 1)), 0.17)
	print("SMOKE a big part shrinks and a small part grows: ", big < 0.001 and small > 0.1)
	var off_box := AABB(Vector3(100, 0, 0), Vector3(10, 10, 10))
	var turn := Basis(Vector3.UP, deg_to_rad(90))
	var off := TableSeat.copy_offset(off_box, 0.01, turn)
	print("SMOKE the middle of the part's bounds sits at the pivot however it's turned: ", _near(turn * (off_box.get_center() * 0.01) + off, Vector3.ZERO))
	print("SMOKE the drop zone is above the slab: ", TableSeat.in_drop_zone(Vector3(0, 0.2, 0), Vector2(0.6, 0.4), -0.05, 0.5))
	print("SMOKE ...not beside it, below it or far above it: ", not TableSeat.in_drop_zone(Vector3(0.9, 0.2, 0), Vector2(0.6, 0.4), -0.05, 0.5) and not TableSeat.in_drop_zone(Vector3(0, -0.3, 0), Vector2(0.6, 0.4), -0.05, 0.5) and not TableSeat.in_drop_zone(Vector3(0, 1.0, 0), Vector2(0.6, 0.4), -0.05, 0.5))
	var arena := Basis.IDENTITY.scaled(Vector3.ONE * 0.002) # the model was scaled up after the part was seated
	var original := Basis(Vector3.RIGHT, deg_to_rad(30))
	var lifted := TableSeat.lift_transform(arena, original, box, Vector3(1, 2, 3))
	print("SMOKE a lifted part returns at the arena's current scale and its original orientation: ", lifted.basis.is_equal_approx(arena * original))
	print("SMOKE ...with the middle of its bounds where the table copy's middle was: ", _near(lifted * box.get_center(), Vector3(1, 2, 3)))

	# --- snapping (over a stand-in for the sketch session's model)
	var fake := SnapModel.new()
	fake.points = {"a": Vector2(0, 0), "b": Vector2(40, 0), "c": Vector2(40, 30), "m": Vector2(100, 100), "r": Vector2(110, 100)}
	fake.lines = {"l1": {"a": "a", "b": "b", "construction": false}, "l2": {"a": "b", "b": "c", "construction": false}}
	fake.circles = {"c1": {"c": "m", "p": "r", "k": ""}}
	var near_pt := Snap.resolve(Vector2(1.0, 0.5), fake, 3.0, true)
	print("SMOKE a point near an existing one snaps onto it and carries its id: ", near_pt["kind"] == "point" and near_pt["id"] == "a" and near_pt["uv"] == Vector2(0, 0))
	var mid := Snap.resolve(Vector2(20, 1.0), fake, 3.0, true)
	print("SMOKE near a line's middle snaps to the midpoint (position only, no id): ", mid["kind"] == "midpoint" and mid["uv"] == Vector2(20, 0) and mid["id"] == "")
	var on_line := Snap.resolve(Vector2(10, 1.2), fake, 3.0, true)
	print("SMOKE elsewhere along a line it lands ON the line: ", on_line["kind"] == "curve" and on_line["uv"].is_equal_approx(Vector2(10, 0)))
	var on_circle := Snap.resolve(Vector2(100, 111.0), fake, 3.0, true)
	print("SMOKE near a circle it lands on the circle: ", on_circle["kind"] == "curve" and on_circle["uv"].is_equal_approx(Vector2(100, 110)))
	var on_vertex := Snap.resolve(Vector2(200.5, 50.5), fake, 3.0, true, [Vector2(200, 50)])
	print("SMOKE a part vertex on the sheet snaps (position only): ", on_vertex["kind"] == "vertex" and on_vertex["uv"] == Vector2(200, 50) and on_vertex["id"] == "")
	print("SMOKE an existing point beats a vertex beside it: ", Snap.resolve(Vector2(0.2, 0.2), fake, 3.0, true, [Vector2(0.5, 0.5)])["kind"] == "point")
	print("SMOKE away from everything it stays free and untouched: ", Snap.resolve(Vector2(500, 500), fake, 3.0, true)["kind"] == "free" and Snap.resolve(Vector2(500, 500), fake, 3.0, true)["uv"] == Vector2(500, 500))
	print("SMOKE with Snap off nothing moves: ", Snap.resolve(Vector2(1.0, 0.5), fake, 3.0, false)["kind"] == "free" and Snap.resolve(Vector2(1.0, 0.5), fake, 3.0, false)["uv"] == Vector2(1.0, 0.5))
	var horiz := Snap.resolve(Vector2(200, 53.0), fake, 3.0, true, [], Vector2(100, 50))
	print("SMOKE a line end within 4 degrees of horizontal is pulled onto the axis and flagged: ", horiz["infer"] == "horizontal" and horiz["uv"] == Vector2(200, 50))
	var vert := Snap.resolve(Vector2(104.0, 250), fake, 3.0, true, [], Vector2(100, 50))
	print("SMOKE ...and likewise vertical: ", vert["infer"] == "vertical" and vert["uv"] == Vector2(100, 250))
	var back := Snap.resolve(Vector2(0, 52.0), fake, 3.0, true, [], Vector2(100, 50))
	print("SMOKE ...drawing right-to-left counts too: ", back["infer"] == "horizontal")
	var diagonal := Snap.resolve(Vector2(200, 150), fake, 3.0, true, [], Vector2(100, 50))
	print("SMOKE a diagonal is left alone: ", diagonal["infer"] == "" and diagonal["uv"] == Vector2(200, 150))
	print("SMOKE too close to the start to say which way it points: ", Snap.resolve(Vector2(101, 50.5), fake, 3.0, true, [], Vector2(100, 50))["infer"] == "")
	print("SMOKE with Snap off the axis is not inferred either: ", Snap.resolve(Vector2(200, 53.0), fake, 3.0, false, [], Vector2(100, 50))["infer"] == "")
	# --- handling the part on the table (table_pose.gd)
	var id := Basis.IDENTITY
	var spread := TablePose.two_hand(Vector3(-0.1, 0, 0), Vector3(0.1, 0, 0), Vector3(-0.15, 0, 0), Vector3(0.15, 0, 0), Vector3(0, 0.2, 0), id, 1.0)
	print("SMOKE spreading the hands 1.5x scales the part 1.5x about the midpoint: ", absf(spread["scale"] - 1.5) < 0.0001 and _near(spread["centre"], Vector3(0, 0.2, 0) * 1.5))
	var shift := TablePose.two_hand(Vector3(-0.1, 0, 0), Vector3(0.1, 0, 0), Vector3(0.0, 0, 0), Vector3(0.2, 0, 0), Vector3(0, 0.2, 0), id, 1.0)
	print("SMOKE moving both hands together carries the part along, without turning or scaling it: ", _near(shift["centre"], Vector3(0.1, 0.2, 0)) and absf(shift["scale"] - 1.0) < 0.0001 and (shift["rotation"] as Basis).is_equal_approx(id))
	var quarter := TablePose.two_hand(Vector3(-0.1, 0, 0), Vector3(0.1, 0, 0), Vector3(0, 0, 0.1), Vector3(0, 0, -0.1), Vector3(0.1, 0, 0), id, 1.0)
	print("SMOKE swinging the line a quarter turn turns the part a quarter turn about the midpoint (shortest arc): ", (quarter["rotation"] as Basis).is_equal_approx(Basis(Vector3.UP, deg_to_rad(90.0))) and _near(quarter["centre"], Vector3(0, 0, -0.1)))
	var huge := TablePose.two_hand(Vector3(-0.1, 0, 0), Vector3(0.1, 0, 0), Vector3(-5, 0, 0), Vector3(5, 0, 0), Vector3.ZERO, id, 1.0)
	print("SMOKE the scale is clamped at the top and the bottom: ", huge["scale"] == TablePose.MAX_SCALE and TablePose.two_hand(Vector3(-5, 0, 0), Vector3(5, 0, 0), Vector3(-0.03, 0, 0), Vector3(0.03, 0, 0), Vector3.ZERO, id, 1.0)["scale"] == TablePose.MIN_SCALE)
	print("SMOKE hands almost together make no swing or scale (too short a line to read): ", TablePose.two_hand(Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0, 0, 0), Vector3(0, 0.01, 0), Vector3.ZERO, id, 1.0)["scale"] == 1.0)
	var flipped := TablePose.swing(Vector3.RIGHT, Vector3.LEFT)
	print("SMOKE hands swapped through each other still gives a proper half turn: ", (flipped * Vector3.RIGHT).distance_to(Vector3.LEFT) < 0.001 and absf(flipped.determinant() - 1.0) < 0.001)
	var spun := TablePose.stick_turn(id, Vector2(1, 0), 1.0, 90.0)
	print("SMOKE the stick pushed right for a second spins the part a quarter turn about the slab's up axis: ", spun.is_equal_approx(Basis(Vector3.UP, deg_to_rad(90.0))))
	var tipped := TablePose.stick_turn(id, Vector2(0, 1), 0.5, 90.0)
	print("SMOKE ...and pushed up it tips the top away from you (towards -Z): ", (tipped * Vector3.UP).z < -0.5)
	print("SMOKE ...and rests when the stick does: ", TablePose.stick_turn(id, Vector2.ZERO, 1.0, 90.0).is_equal_approx(id))
	var slab := Vector2(0.6, 0.4)
	print("SMOKE a point is pulled back over the slab and above it: ", _near(TablePose.clamp_to_zone(Vector3(2, -1, -2), slab, 0.05, 0.6), Vector3(0.3, 0.05, -0.2)))
	var hand := Vector3(0, 0.5, 0.5)
	var centre := Vector3(0, 0.2, 0)
	var pushed := TablePose.nudge(centre, hand, Vector3(0, 0, -1), 1.0, 0.1, 1.0, 0.15)
	var pulled := TablePose.nudge(centre, hand, Vector3(0, 0, -1), -1.0, 0.1, 1.0, 0.15)
	print("SMOKE B pushes the part along the line from the hand, A pulls it back along it: ", pushed.distance_to(hand) > centre.distance_to(hand) + 0.09 and pulled.distance_to(hand) < centre.distance_to(hand) - 0.09 and _near((pushed - hand).normalized(), (centre - hand).normalized()))
	print("SMOKE A will not pull the part through your hand (it stays put once it is that close): ", TablePose.nudge(Vector3(0, 0.5, 0.4), hand, Vector3(0, 0, -1), -1.0, 5.0, 1.0, 0.15) == Vector3(0, 0.5, 0.4))
	print("SMOKE a part at the hand is pushed out along where you point: ", _near(TablePose.nudge(hand, hand, Vector3(0, 0, -1), 1.0, 0.1, 1.0, 0.15), hand + Vector3(0, 0, -0.1)))
	print("SMOKE the laser counts as on the part within its sphere and in front of the hand only: ", TablePose.ray_near_sphere(Vector3.ZERO, Vector3(0, 0, -1), Vector3(0.05, 0, -1), 0.1) and not TablePose.ray_near_sphere(Vector3.ZERO, Vector3(0, 0, -1), Vector3(0.5, 0, -1), 0.1) and not TablePose.ray_near_sphere(Vector3.ZERO, Vector3(0, 0, -1), Vector3(0, 0, 1), 0.1))
	# --- resizing the slab by a corner (table_resize.gd)
	var slab2 := Vector2(0.6, 0.4)
	print("SMOKE a point just outside a corner is that corner; inside the slab or far away is none: ", TableResize.corner_at(Vector2(0.35, 0.25), slab2) == 3 and TableResize.corner_at(Vector2(-0.35, -0.25), slab2) == 0 and TableResize.corner_at(Vector2(0.35, -0.25), slab2) == 1 and TableResize.corner_at(Vector2(-0.35, 0.25), slab2) == 2 and TableResize.corner_at(Vector2(0.1, 0.1), slab2) == -1 and TableResize.corner_at(Vector2(0.9, 0.9), slab2) == -1)
	var lo := Vector2(0.5, 0.3)
	var hi := Vector2(1.4, 1.0)
	var grown := TableResize.dragged(Vector2(0.6, 0.35), slab2, Vector2(1, 1), lo, hi)
	print("SMOKE dragging the front-right corner out grows the slab with the back-left corner fixed (the middle moves half the growth): ", (grown["size"] as Vector2).is_equal_approx(Vector2(0.9, 0.55)) and (grown["shift"] as Vector2).is_equal_approx(Vector2(0.15, 0.075)))
	var tl := TableResize.dragged(Vector2(-0.5, -0.3), slab2, Vector2(-1, -1), lo, hi)
	print("SMOKE ...and any corner works the same way (back-left, opposite corner front-right fixed): ", (tl["size"] as Vector2).is_equal_approx(Vector2(0.8, 0.5)) and (tl["shift"] as Vector2).is_equal_approx(Vector2(-0.1, -0.05)))
	print("SMOKE the size is clamped, and the middle shifts only by what the clamp allowed: ", (TableResize.dragged(Vector2(9, 9), slab2, Vector2(1, 1), lo, hi)["size"] as Vector2) == hi and (TableResize.dragged(Vector2(-9, -9), slab2, Vector2(1, 1), lo, hi)["size"] as Vector2) == lo and (TableResize.dragged(Vector2(-9, -9), slab2, Vector2(1, 1), lo, hi)["shift"] as Vector2).is_equal_approx(Vector2(-0.3 + 0.25, -0.2 + 0.15)))
	var bracket := TableResize._bracket_mesh(0.045, 0.012, 0.05, 0.01)
	var bb := bracket.get_aabb()
	print("SMOKE a corner bracket is a flat ribbon round the rounded corner (arc plus two arms, in the slab's plane): ", bb.size.y < 0.001 and bb.size.x > 0.07 and bb.size.z > 0.07 and bracket.get_surface_count() == 1)

	# --- the origin as a snap target, the grid step, locked-pose maths
	var with_origin := SnapModel.new()
	with_origin.points = {"o": Vector2.ZERO, "p": Vector2(40, 0)}
	with_origin.origin_id = "o"
	var near_origin := Snap.resolve(Vector2(1.0, -1.0), with_origin, 3.0, true)
	print("SMOKE near the sketch origin it snaps to it, kind 'origin', carrying the origin's id: ", near_origin["kind"] == "origin" and near_origin["id"] == "o" and near_origin["uv"] == Vector2.ZERO)
	print("SMOKE another existing point is still just a 'point': ", Snap.resolve(Vector2(40.5, 0.5), with_origin, 3.0, true)["kind"] == "point")
	print("SMOKE the grid step is the 1-2-5 spacing at or just above the target (3 -> 5, 5 -> 5, 6 -> 10, 0.07 -> 0.1, 12 -> 20, 130 -> 200): ", SketchMath.grid_step(3.0) == 5.0 and SketchMath.grid_step(5.0) == 5.0 and SketchMath.grid_step(6.0) == 10.0 and is_equal_approx(SketchMath.grid_step(0.07), 0.1) and SketchMath.grid_step(12.0) == 20.0 and SketchMath.grid_step(130.0) == 200.0)
	var still := TablePose.two_hand(Vector3(-0.1, 0, 0), Vector3(0.1, 0, 0), Vector3(0, 0, 0.1), Vector3(0, 0, -0.1), Vector3(0.1, 0, 0), Basis.IDENTITY, 1.0, false)
	print("SMOKE with the turn locked, a quarter swing of the hands does not turn the part (it only moves with the midpoint): ", still["rotation"].is_equal_approx(Basis.IDENTITY) and is_equal_approx(still["scale"], 1.0))
	var zoomed := TablePose.two_hand(Vector3(-0.1, 0, 0), Vector3(0.1, 0, 0), Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3.ZERO, Basis.IDENTITY, 1.0, false, TablePose.SKETCH_MAX_SCALE)
	print("SMOKE while sketching, hands five times as far apart zoom to 5x (the cap is 200x; ordinarily 3x): ", is_equal_approx(zoomed["scale"], 5.0) and TablePose.two_hand(Vector3(-0.1, 0, 0), Vector3(0.1, 0, 0), Vector3(-500, 0, 0), Vector3(500, 0, 0), Vector3.ZERO, Basis.IDENTITY, 1.0, false, TablePose.SKETCH_MAX_SCALE)["scale"] == TablePose.SKETCH_MAX_SCALE)
	print("SMOKE Fit scales a 100 x 50 mm sketch to fill 80% of a 0.8 x 0.4 m window (3.2 mm per mm at fit 0.003 is 1.07x), clamped to the cap: ", is_equal_approx(TablePose.fit_scale(Vector2(100, 50), Vector2(0.8, 0.4), 0.8, 0.003, 8.0), 0.0064 / 0.003) and TablePose.fit_scale(Vector2(1, 1), Vector2(0.8, 0.4), 0.8, 0.003, 8.0) == 8.0 and TablePose.fit_scale(Vector2(10000, 10000), Vector2(0.8, 0.4), 0.8, 0.003, 8.0) == TablePose.MIN_SCALE)

	var outline: Array = SketchView.slot_outline(Vector2(0, 0), Vector2(40, 0), 6.0, 8)
	var xs: Array = outline.map(func(p): return p.x)
	var ys: Array = outline.map(func(p): return p.y)
	print("SMOKE a slot's outline is two half circles round the end centres: 18 points, spanning x from -6 to 46 and y from -6 to 6: ", outline.size() == 18 and is_equal_approx(xs.min(), -6.0) and is_equal_approx(xs.max(), 46.0) and is_equal_approx(ys.min(), -6.0) and is_equal_approx(ys.max(), 6.0) and SketchView.slot_outline(Vector2.ZERO, Vector2.ZERO, 5.0, 8).is_empty())

	var slot_pts: Array = SketchView.slot_outline(Vector2(0, 0), Vector2(40, 0), 6.0, 8)
	var slot_xs: Array = slot_pts.map(func(p): return p.x)
	var slot_ys: Array = slot_pts.map(func(p): return p.y)
	print("SMOKE a slot's outline is two half circles round the end centres: 18 points, spanning x from -6 to 46 and y from -6 to 6: ", slot_pts.size() == 18 and is_equal_approx(slot_xs.min(), -6.0) and is_equal_approx(slot_xs.max(), 46.0) and is_equal_approx(slot_ys.min(), -6.0) and is_equal_approx(slot_ys.max(), 6.0) and SketchView.slot_outline(Vector2.ZERO, Vector2.ZERO, 5.0, 8).is_empty())


	# --- dimensions laid out like a drawing (dimension_layout.gd)
	var dp := {"offset": 10.0, "arrow": 3.0, "gap": 1.0, "over": 2.0, "centroid": Vector2(40, 20), "text_h": 4.0, "text_w": 8.0}
	var d_h := DimLayout.layout({"kind": "horizontal", "a": Vector2(0, 0), "b": Vector2(80, 0)}, dp)
	var d_h_line: Array = (d_h["segments"] as Array).filter(func(sg): return is_equal_approx(sg[0].y, sg[1].y) and absf(sg[0].x - sg[1].x) > 50.0)
	print("SMOKE a horizontal dimension: extension lines drop from both points (a gap off the geometry, an overshoot past the line), the dimension line runs between them 10 mm out, arrowheads sit on the extension lines pointing outward, the text is level above the middle: ", d_h["segments"].size() == 3 and d_h_line.size() == 1 and is_equal_approx(d_h_line[0][0].y, -10.0) and d_h["arrows"].size() == 2 and d_h["arrows"][0][0] == Vector2(0, -10) and d_h["arrows"][0][1] == Vector2(-1, 0) and d_h["arrows"][1][0] == Vector2(80, -10) and d_h["arrows"][1][1] == Vector2(1, 0) and is_equal_approx(d_h["text_angle"], 0.0) and absf(d_h["text_uv"].x - 40.0) < 0.001 and d_h["text_uv"].y > -10.0 and (d_h["segments"][0][0] as Vector2).is_equal_approx(Vector2(0, -1)) and (d_h["segments"][0][1] as Vector2).is_equal_approx(Vector2(0, -12)))
	var d_v := DimLayout.layout({"kind": "vertical", "a": Vector2(0, 0), "b": Vector2(0, 50)}, dp)
	print("SMOKE a vertical dimension goes to the outside (left, away from the middle of the sketch) with its text turned to read from the bottom up: ", is_equal_approx(d_v["arrows"][0][0].x, -10.0) and is_equal_approx(d_v["text_angle"], PI * 0.5) and (d_v["text_up"] as Vector2).is_equal_approx(Vector2(-1, 0)))
	var d_a := DimLayout.layout({"kind": "linear", "a": Vector2(0, 0), "b": Vector2(30, 40)}, {"offset": 10.0, "arrow": 3.0, "gap": 1.0, "over": 2.0, "centroid": Vector2(0, 40), "text_h": 4.0, "text_w": 8.0})
	var d_a_line: Array = (d_a["segments"] as Array).filter(func(sg): return absf((sg[1] - sg[0]).length() - 50.0) < 0.01)
	print("SMOKE an aligned dimension runs parallel to its line, offset 10 mm to the outside, the text turned along it: ", d_a_line.size() == 1 and absf(absf((d_a_line[0][1] - d_a_line[0][0]).normalized().dot(Vector2(0.6, 0.8))) - 1.0) < 0.001 and absf(absf(d_a["text_angle"]) - atan2(40.0, 30.0)) < 0.001)
	var d_t := DimLayout.layout({"kind": "horizontal", "a": Vector2(0, 0), "b": Vector2(5, 0)}, dp)
	print("SMOKE a dimension too short to hold its arrows puts them OUTSIDE, pointing in, with short tails: ", d_t["arrows"][0][1] == Vector2(1, 0) and d_t["arrows"][1][1] == Vector2(-1, 0) and d_t["segments"].size() == 5)
	var d_r := DimLayout.layout({"kind": "radius", "c": Vector2(10, 10), "r": 20.0, "u": Vector2(1, 1)}, dp)
	var tip: Vector2 = d_r["arrows"][0][0]
	print("SMOKE a radius is a leader from the centre out through the circle with the arrow tip ON the circle and the text beyond its end: ", d_r["arrows"].size() == 1 and absf(tip.distance_to(Vector2(10, 10)) - 20.0) < 0.001 and (d_r["arrows"][0][1] as Vector2).is_equal_approx(Vector2(1, 1).normalized()) and (d_r["text_uv"] as Vector2).distance_to(Vector2(10, 10)) > 20.0 + 3.0 * 2.5)
	var d_d := DimLayout.layout({"kind": "diameter", "c": Vector2(0, 0), "r": 15.0, "u": Vector2(1, 0)}, dp)
	print("SMOKE a diameter is a line through the centre with an arrow at each end on the circle, pointing outward: ", d_d["arrows"].size() == 2 and d_d["arrows"][0][0] == Vector2(-15, 0) and d_d["arrows"][1][0] == Vector2(15, 0) and d_d["arrows"][0][1] == Vector2(-1, 0))
	var d_n := DimLayout.layout({"kind": "angle", "apex": Vector2(0, 0), "d1": Vector2(1, 0), "d2": Vector2(0, 1), "r": 20.0}, dp)
	var n_pts: Array = d_n["arcs"][0]
	print("SMOKE an angle is an arc of the given radius from one line to the other about the apex (the short way), arrowheads at both ends, extension lines out to it, the value written level: ", n_pts.size() >= 6 and (n_pts[0] as Vector2).is_equal_approx(Vector2(20, 0)) and (n_pts[n_pts.size() - 1] as Vector2).distance_to(Vector2(0, 20)) < 0.001 and d_n["arrows"].size() == 2 and d_n["segments"].size() == 2 and is_equal_approx(d_n["text_angle"], 0.0))
	print("SMOKE text is always upright: directions fold into (-90, 90] degrees: ", is_equal_approx(DimLayout.upright(PI), 0.0) and is_equal_approx(DimLayout.upright(-PI * 0.75), PI * 0.25) and is_equal_approx(DimLayout.upright(PI * 0.5), PI * 0.5) and is_equal_approx(DimLayout.upright(-PI * 0.5), PI * 0.5) and is_equal_approx(DimLayout.upright(0.3), 0.3))
	var shape_params := {"offset": 10.0, "arrow": 3.0, "gap": 1.0, "over": 2.0, "centroid": Vector2(-50, 20), "interiors": [[Vector2(0, 0), Vector2(80, 0), Vector2(80, 60), Vector2(0, 60)]], "text_h": 4.0, "text_w": 8.0}
	var d_out := DimLayout.layout({"kind": "vertical", "a": Vector2(80, 0), "b": Vector2(80, 60)}, shape_params)
	print("SMOKE a dimension of a shape's edge goes OUTSIDE that shape even when the middle of the sketch is on the other side of it: ", is_equal_approx(d_out["arrows"][0][0].x, 90.0))
	var d_room := DimLayout.layout({"kind": "horizontal", "a": Vector2(0, 0), "b": Vector2(40, 0)}, {"offset": 10.0, "arrow": 3.0, "gap": 1.0, "over": 2.0, "centroid": Vector2(20, -30), "obstacle_segments": [[Vector2(-5, -12), Vector2(50, -12)]], "text_h": 4.0, "text_w": 8.0})
	print("SMOKE ...and it takes the side with room: a line of the sketch 12 mm below pushes it above, though the middle of the sketch is below: ", is_equal_approx(d_room["arrows"][0][0].y, 10.0))

	# --- the chain pattern of construction lines and the arrowheads, in the view
	var view := SketchView.new()
	var dash_verts := PackedVector3Array()
	var dash_colors := PackedColorArray()
	view.plane = {"origin": Vector3.ZERO, "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}
	view.canvas_scale = 0.01
	view._dashed(dash_verts, dash_colors, [Vector2(0, 0), Vector2(400, 0)], 0.002, Color.WHITE, false)
	var solid_verts := PackedVector3Array()
	var solid_colors := PackedColorArray()
	view._ribbon(solid_verts, solid_colors, Vector2(0, 0), Vector2(400, 0), 0.002, Color.WHITE)
	var covered := 0.0
	var pieces: int = dash_verts.size() / 6
	for i in pieces:
		covered += absf(dash_verts[i * 6 + 1].x - dash_verts[i * 6].x)
	print("SMOKE a construction line is drawn in a CHAIN (long dash, gap, dot, gap), not solid: many pieces, about two thirds of the length covered: ", pieces >= 20 and solid_verts.size() == 6 and covered > 400.0 * 0.55 and covered < 400.0 * 0.8)
	print("SMOKE an arrowhead is a filled triangle with its tip where it is told, pointing the way it is told: ", _arrow_ok(view))
	view.free()

	# --- the sketch window: fixed in the world, the part (and its sketch) slides and scales under it
	var cv := SketchView.new()
	var cplane := {"origin": Vector3.ZERO, "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}
	cv.setup(cplane, Vector2(0.8, 0.4), Vector2(10, 20), 0.002, load("res://ui/didsa_ui_theme.tres"))
	print("SMOKE a window 0.8 x 0.4 m of world at 0.002 m per mm spans 400 x 200 mm of sketch, around the spot it is centred on: ", cv.sheet_size.is_equal_approx(Vector2(400, 200)) and cv.contains(Vector2(10 + 199, 20)) and not cv.contains(Vector2(10 + 201, 20)))
	var zoomed_in: bool = cv.set_frame(0.008, Vector2(100, 50))
	print("SMOKE zooming reports that the drawing must be rebuilt, sliding alone does not: ", zoomed_in and not cv.set_frame(0.008, Vector2(120, 50)))
	print("SMOKE ...four times the zoom: the window spans a quarter as much sketch (100 x 50 mm) around the new spot: ", cv.sheet_size.is_equal_approx(Vector2(100, 50)) and cv.sheet_centre.is_equal_approx(Vector2(120, 50)) and cv.contains(Vector2(120 + 49, 50)) and not cv.contains(Vector2(120 + 51, 50)))
	print("SMOKE the grid and the line clip follow the window: ", is_equal_approx(cv.grid_step(), SketchMath.grid_step(0.016 / 0.008)) and (cv._line_material.get_shader_parameter("clip_half") as Vector2).is_equal_approx(Vector2(50, 25)) and (cv._line_material.get_shader_parameter("clip_centre") as Vector2).is_equal_approx(Vector2(120, 50)))
	print("SMOKE the corner line gives the grid spacing as a drawing would: 2 mm, 0.5 mm, 1.5 m, 50 mm: ", SketchView.format_length(2.0) == "2 mm" and SketchView.format_length(0.5) == "0.5 mm" and SketchView.format_length(1500.0) == "1.5 m" and SketchView.format_length(50.0) == "50 mm" and cv.readout_text().begins_with("Grid "))
	cv.free()
	var wide_in := TablePose.two_hand(Vector3(-0.1, 0, 0), Vector3(0.1, 0, 0), Vector3(-50, 0, 0), Vector3(50, 0, 0), Vector3.ZERO, Basis.IDENTITY, 1.0, false, TablePose.SKETCH_MAX_SCALE, TablePose.SKETCH_MIN_SCALE)
	var wide_out := TablePose.two_hand(Vector3(-1.0, 0, 0), Vector3(1.0, 0, 0), Vector3(-0.0101, 0, 0), Vector3(0.0101, 0, 0), Vector3.ZERO, Basis.IDENTITY, 1.0, false, TablePose.SKETCH_MAX_SCALE, TablePose.SKETCH_MIN_SCALE)
	print("SMOKE while sketching the part can be zoomed from 1/50 to 200 times (a tiny sketch to a huge one), and no further: ", is_equal_approx(wide_in["scale"], TablePose.SKETCH_MAX_SCALE) and is_equal_approx(wide_out["scale"], TablePose.SKETCH_MIN_SCALE) and TablePose.SKETCH_MIN_SCALE < TablePose.MIN_SCALE)

	# --- the Select tool's menu (sketch_selection.gd), mirroring the flat app's availableConstraintOptions
	var model := SnapModel.new()
	model.points = {"o": Vector2.ZERO}
	model.origin_id = "o"
	model.lines = {"l1": {"a": "p", "b": "q", "construction": false}, "l2": {"a": "q", "b": "r", "construction": true}}
	model.circles = {"c1": {"c": "m", "p": "n", "k": "", "construction": false}, "c2": {"c": "m", "p": "n", "k": "", "construction": false}}
	model.arcs = {"a1": {"c": "m", "s": "s1", "e": "e1", "k": "", "construction": false}, "a2": {"c": "m", "s": "e1", "e": "e2", "k": "", "construction": false}, "a3": {"c": "m", "s": "x", "e": "y", "k": "", "construction": false}}
	var sel_of := func(entities: Array) -> Array:
		return entities.map(func(e): return {"kind": e[0], "id": e[1]})
	var menu_ids := func(entities: Array) -> Array:
		return SketchSelection.options(sel_of.call(entities), model).map(func(o): return o["id"])
	print("SMOKE nothing selected, no menu: ", menu_ids.call([]).is_empty())
	print("SMOKE one line: Horizontal, Vertical, Fix, Construction, Delete, Clear: ", menu_ids.call([["line", "l1"]]) == ["horizontal", "vertical", "fix", "construction", "delete", "clear"])
	print("SMOKE two lines: Parallel, Perpendicular, Equal, Collinear (and the second being construction means the pair is not all-solid): ", menu_ids.call([["line", "l1"], ["line", "l2"]]).slice(0, 4) == ["parallel", "perpendicular", "equal_length", "collinear"] and SketchSelection.options(sel_of.call([["line", "l1"], ["line", "l2"]]), model).filter(func(o): return o["id"] == "construction")[0]["text"] == "Construction")
	print("SMOKE a construction line offers Solid: ", SketchSelection.options(sel_of.call([["line", "l2"]]), model).filter(func(o): return o["id"] == "construction")[0]["text"] == "Solid")
	print("SMOKE three lines: Equal and Collinear only (no pairwise ones): ", menu_ids.call([["line", "l1"], ["line", "l2"], ["line", "l1x"]]).slice(0, 2) == ["equal_length", "collinear"])
	print("SMOKE two points: Coincident; the origin and a point also; one point: only the generic ones: ", menu_ids.call([["point", "o"], ["point", "p"]]).slice(0, 1) == ["coincident"] and menu_ids.call([["point", "p"]]) == ["fix", "delete", "clear"])
	print("SMOKE the origin alone can be fixed and cleared but never deleted: ", menu_ids.call([["point", "o"]]) == ["fix", "clear"])
	print("SMOKE a point and a line: On line, Midpoint; a point and a circle: On curve; a line and a circle: Tangent: ", menu_ids.call([["point", "p"], ["line", "l1"]]).slice(0, 2) == ["point_on_line", "at_midpoint"] and menu_ids.call([["point", "p"], ["circle", "c1"]])[0] == "point_on_curve" and menu_ids.call([["line", "l1"], ["circle", "c1"]])[0] == "tangent")
	print("SMOKE two circles: Concentric and Equal radius; two arcs sharing an end add Tangent, arcs that do not share one do not: ", menu_ids.call([["circle", "c1"], ["circle", "c2"]]).slice(0, 2) == ["concentric", "equal_radius"] and not menu_ids.call([["circle", "c1"], ["circle", "c2"]]).has("tangent") and menu_ids.call([["arc", "a1"], ["arc", "a2"]]).has("tangent") and not menu_ids.call([["arc", "a1"], ["arc", "a3"]]).has("tangent"))
	print("SMOKE the dimension candidates come first, as 'dim:<key>' options with their value: ", SketchSelection.options(sel_of.call([["line", "l1"]]), model, [{"key": "length", "label": "Length", "value": 40.0}])[0] == {"id": "dim:length", "text": "Length 40.00"})
	var long_list: Array = []
	for i in 9:
		long_list.append({"id": "o%d" % i, "text": "O%d" % i})
	var p0 := SketchSelection.page(long_list, 0, 6)
	var p1 := SketchSelection.page(long_list, 1, 6)
	print("SMOKE a menu longer than the six-button row shows five and More, then the rest; a short one shows all: ", p0["items"].size() == 5 and p0["has_more"] and p0["pages"] == 2 and p1["items"].size() == 4 and p1["items"][0]["id"] == "o5" and SketchSelection.page(long_list.slice(0, 6), 0, 6)["has_more"] == false and SketchSelection.page(long_list, 9, 6)["page"] == 1)
	quit()
