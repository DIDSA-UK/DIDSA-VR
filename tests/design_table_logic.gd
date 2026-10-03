extends SceneTree
## The design table's pure logic, no scene tree (scripts/design_table/): the tool-row
## pager ("More" slot), the tool registration (real DIDSA-CAD names, one active tool),
## the sketch-plane maths (fixed planes, turning a part to lie on the table, ray to
## sheet) and the seat / lift numbers.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_logic.gd  (see tests/README.md)

const Pager := preload("res://scripts/design_table/tool_pager.gd")
const TableTools := preload("res://scripts/design_table/table_tools.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TableSeat := preload("res://scripts/design_table/table_seat.gd")
const Snap := preload("res://scripts/design_table/snap_resolver.gd")


class Handler extends RefCounted:
	var log: Array = []
	func tool_activated(id: String) -> void: log.append("+" + id)
	func tool_deactivated(id: String) -> void: log.append("-" + id)


class SnapModel extends RefCounted:
	var points := {}
	var lines := {}
	var circles := {}
	var arcs := {}


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
	print("SMOKE Sketch has DIDSA-CAD's six drawing tools in the app's order: ", reg.category("sketch").tools.map(func(t): return t.id) == ["line", "rectangle", "circle", "arc", "polygon", "point"])
	print("SMOKE no category is over the six-slot row yet: ", reg.categories().all(func(c): return c.tools.size() <= Pager.SLOTS))
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
	quit()
