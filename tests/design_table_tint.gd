extends SceneTree
## The tint of a sketch's closed shapes (sketch_picks.gd fill_polygons), pure: holes are left open. A square with a circular hole is filled with the area of
## the square minus the hole; two holes, a hole touching nothing else and an island inside a hole (filled again) are right too; a plain loop is filled whole; no
## piece overlaps another loop's hole. No scene.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_tint.gd  (see tests/README.md)

const Picks := preload("res://scripts/design_table/sketch_picks.gd")


func square(c: Vector2, half: float) -> Array:
	return [c + Vector2(-half, -half), c + Vector2(half, -half), c + Vector2(half, half), c + Vector2(-half, half)]


func ring(c: Vector2, r: float, n := 48) -> Array:
	var out: Array = []
	for i in n:
		out.append(c + Vector2(cos(TAU * i / n), sin(TAU * i / n)) * r)
	return out


func filled_area(loops: Array) -> float:
	var total := 0.0
	for poly in Picks.fill_polygons(loops):
		var tri: PackedInt32Array = Geometry2D.triangulate_polygon(PackedVector2Array(poly))
		for i in range(0, tri.size(), 3):
			var a: Vector2 = poly[tri[i]]
			var b: Vector2 = poly[tri[i + 1]]
			var c: Vector2 = poly[tri[i + 2]]
			total += absf((b - a).cross(c - a)) * 0.5
	return total


func area_of(poly: Array) -> float:
	return absf(Picks._signed_area(PackedVector2Array(poly)))


func near(a: float, b: float, tol := 0.01) -> bool:
	return absf(a - b) <= tol * maxf(absf(b), 1.0)


func _initialize() -> void:
	var outer := square(Vector2.ZERO, 50.0)
	print("SMOKE a plain loop is filled whole: ", near(filled_area([outer]), 10000.0))
	var hole := ring(Vector2(10, 5), 20.0)
	print("SMOKE a square with a circular hole is filled with the square's area minus the hole's: ", near(filled_area([outer, hole]), 10000.0 - area_of(hole)), " ", filled_area([outer, hole]), " ", 10000.0 - area_of(hole))
	var hole_b := ring(Vector2(-30, -30), 8.0)
	print("SMOKE two holes are both left open: ", near(filled_area([outer, hole, hole_b]), 10000.0 - area_of(hole) - area_of(hole_b)))
	var island := ring(Vector2(10, 5), 8.0)
	print("SMOKE an island inside a hole is filled again: ", near(filled_area([outer, hole, island]), 10000.0 - area_of(hole) + area_of(island)))
	var apart := square(Vector2(200, 0), 20.0)
	print("SMOKE two separate shapes are each filled: ", near(filled_area([outer, apart]), 10000.0 + 1600.0))
	var pieces: Array = Picks.fill_polygons([outer, hole])
	var covered := false
	for poly in pieces:
		if Geometry2D.is_point_in_polygon(Vector2(10, 5), PackedVector2Array(poly)):
			covered = true
	print("SMOKE no filled piece covers the middle of the hole: ", not covered)
	quit()
