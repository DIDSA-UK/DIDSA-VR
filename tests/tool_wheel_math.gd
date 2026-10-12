extends SceneTree
## The tool wheel's pure geometry (scripts/ui/tool_wheel_math.gd): which wedge a hand offset points at (wedge 0 straight up,
## clockwise), the dead zone, wedge outlines, and projecting a hand movement onto the wheel's plane. No scene tree.
## Run: "$GODOT" --headless --path . --script res://tests/tool_wheel_math.gd  (see tests/README.md)

const Math := preload("res://scripts/ui/tool_wheel_math.gd")


func _initialize() -> void:
	print("SMOKE inside the dead zone nothing is chosen: ", Math.wedge_for(Vector2(0.01, 0.01), 8) == -1 and Math.wedge_for(Vector2.ZERO, 8) == -1)
	print("SMOKE no wedges = nothing to choose: ", Math.wedge_for(Vector2(0, 0.2), 0) == -1)
	print("SMOKE straight up is wedge 0: ", Math.wedge_for(Vector2(0, 0.1), 8) == 0)
	print("SMOKE right is wedge 2, down 4, left 6 (8 wedges, clockwise): ", [Math.wedge_for(Vector2(0.1, 0), 8), Math.wedge_for(Vector2(0, -0.1), 8), Math.wedge_for(Vector2(-0.1, 0), 8)] == [2, 4, 6])
	print("SMOKE up-right diagonal is wedge 1, up-left is wedge 7: ", Math.wedge_for(Vector2(0.1, 0.1), 8) == 1 and Math.wedge_for(Vector2(-0.1, 0.1), 8) == 7)
	var edge_ok := true
	for i in 8: # a hair either side of each wedge's centre direction stays in that wedge
		var c := Math.centre_direction(i, 8)
		for sign: float in [-1.0, 1.0]:
			var a: float = Math.centre_angle(i, 8) + sign * deg_to_rad(20.0)
			edge_ok = edge_ok and Math.wedge_for(Vector2(sin(a), cos(a)) * 0.12, 8) == i
		edge_ok = edge_ok and Math.wedge_for(c * 0.12, 8) == i
	print("SMOKE every wedge owns the +-20 degrees around its centre: ", edge_ok)
	print("SMOKE 2 wedges: top half is 0, bottom half is 1: ", Math.wedge_for(Vector2(0.01, 0.1), 2) == 0 and Math.wedge_for(Vector2(0.01, -0.1), 2) == 1)
	print("SMOKE 3 wedges: up 0, lower-right 1, lower-left 2: ", [Math.wedge_for(Vector2(0, 0.1), 3), Math.wedge_for(Vector2(0.1, -0.05), 3), Math.wedge_for(Vector2(-0.1, -0.05), 3)] == [0, 1, 2])
	print("SMOKE a bigger dead zone swallows a bigger offset: ", Math.wedge_for(Vector2(0, 0.06), 8, 0.08) == -1 and Math.wedge_for(Vector2(0, 0.06), 8, 0.04) == 0)
	print("SMOKE centre direction of wedge 2 is to the right: ", Math.centre_direction(2, 8).is_equal_approx(Vector2(1, 0)))

	var outline := Math.wedge_outline(0, 8)
	var inside := Geometry2D.is_point_in_polygon(Vector2(0, (Math.INNER_RADIUS + Math.OUTER_RADIUS) * 0.5), outline)
	var outside := Geometry2D.is_point_in_polygon(Vector2(0.1, 0.0), outline)
	var radii_ok := true
	for p in outline:
		radii_ok = radii_ok and p.length() >= Math.INNER_RADIUS - 0.0001 and p.length() <= Math.OUTER_RADIUS + 0.0001
	print("SMOKE a wedge outline holds its own middle and not its neighbour's: ", inside and not outside)
	print("SMOKE a wedge outline stays between the inner and outer radius: ", radii_ok)
	print("SMOKE a wedge outline triangulates: ", not Geometry2D.triangulate_polygon(outline).is_empty())
	print("SMOKE no wedges = an empty outline: ", Math.wedge_outline(0, 0).is_empty())

	var proj := Math.project_offset(Vector3(0.3, 1.4, -0.2), Vector3(0.1, 1.2, 0.0), Vector3.RIGHT)
	print("SMOKE hand movement projects to (right, up) and ignores depth: ", proj.is_equal_approx(Vector2(0.2, 0.2)))
	print("SMOKE drilling starts at the drill distance: ", not Math.is_drilling(Vector2(0, 0.1)) and Math.is_drilling(Vector2(0, Math.DRILL_DISTANCE + 0.01)))

	var square := PackedVector2Array([Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)])
	print("SMOKE text in a square tile has the square's width: ", is_equal_approx(Math.horizontal_room(square, 0.5, -0.5, 0.0), 2.0))
	print("SMOKE text off to one side only has twice the room to the nearer edge: ", is_equal_approx(Math.horizontal_room(square, 0.5, -0.5, 0.5), 1.0))
	print("SMOKE text above the tile has no room: ", Math.horizontal_room(square, 3.0, 2.0, 0.0) == 0.0)
	var wedge := Math.wedge_outline(0, 8)
	var high := Math.horizontal_room(wedge, 0.20, 0.19, 0.0)
	var low := Math.horizontal_room(wedge, 0.10, 0.09, 0.0)
	print("SMOKE the top wedge is narrower near the hub than further out: ", low > 0.0 and high > low)
	print("SMOKE a name gets the tightest of its slices (a tall name is no wider than its lowest line): ", Math.horizontal_room(wedge, 0.20, 0.09, 0.0) <= low + 0.0001)

	print("SMOKE straight below and past the ring is the pill: ", Math.in_pill(Vector2(0, -0.26)))
	print("SMOKE inside the ring, above it or to the side is not: ", not Math.in_pill(Vector2(0, -0.15)) and not Math.in_pill(Vector2(0, 0.26)) and not Math.in_pill(Vector2(0.26, 0)) and not Math.in_pill(Vector2(-0.26, 0)))
	print("SMOKE the pill spans 120 degrees (60 either side of straight down): ", Math.in_pill(Vector2(sin(deg_to_rad(125)), cos(deg_to_rad(125))) * 0.26) and not Math.in_pill(Vector2(sin(deg_to_rad(115)), cos(deg_to_rad(115))) * 0.26) and Math.in_pill(Vector2(sin(deg_to_rad(-125)), cos(deg_to_rad(-125))) * 0.26))
	var pill := Math.pill_outline()
	var in_band := true
	for p in pill:
		in_band = in_band and p.length() >= Math.OUTER_RADIUS + Math.PILL_GAP - 0.001 and p.length() <= Math.OUTER_RADIUS + Math.PILL_GAP + Math.PILL_DEPTH + 0.001 and p.y < 0.0
	print("SMOKE the pill's outline is a band just outside the ring, below its centre: ", in_band and not pill.is_empty())
	print("SMOKE the pill triangulates and holds its own centre: ", not Geometry2D.triangulate_polygon(pill).is_empty() and Geometry2D.is_point_in_polygon(Math.pill_centre(), pill))
	quit()
