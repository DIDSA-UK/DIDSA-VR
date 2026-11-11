extends RefCounted
## Pure maths for sketching on the design table: where a sketch plane sits in the
## part, how the part is turned so that plane faces up on the table, and how a
## laser ray becomes a (u, v) point on the sketch sheet. No scene tree.
##
## A plane basis is a Dictionary {origin, x, y, n} of Vector3 in the PART's own
## frame (millimetres, DIDSA-CAD's frame), right-handed: x cross y = n. A point on
## the sheet at (u, v) is origin + u*x + v*y — the backend's own formula
## (app.document.plane_geometry.basis_point).
##
## The fixed reference planes are copied from DIDSA-CAD's plane_geometry.py
## (_PLANE_BASIS). XZ's x axis is -X on purpose: it keeps the basis right-handed
## with the normal pointing along +Y.

const FIXED := {
	"XY": {"x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)},
	"XZ": {"x": Vector3(-1, 0, 0), "y": Vector3(0, 0, 1), "n": Vector3(0, 1, 0)},
	"YZ": {"x": Vector3(0, 1, 0), "y": Vector3(0, 0, 1), "n": Vector3(1, 0, 0)},
}

## On the table a sketch plane lies flat: its x axis runs to the user's right, its
## y axis runs away from the user (console -Z) and its normal points up (console
## +Y). Written as the console-frame basis columns.
const TABLE_X := Vector3(1, 0, 0)
const TABLE_Y := Vector3(0, 0, -1)
const TABLE_N := Vector3(0, 1, 0)


static func fixed_basis(plane: String) -> Dictionary:
	## {origin, x, y, n} for "XY" | "XZ" | "YZ" (the origin is the part's origin), or {} if unknown.
	if not FIXED.has(plane):
		return {}
	var f: Dictionary = FIXED[plane]
	return {"origin": Vector3.ZERO, "x": f["x"], "y": f["y"], "n": f["n"]}


static func basis_from_plane_response(response: Dictionary) -> Dictionary:
	## From a create-plane-features response: origin / normal / x_axis / y_axis as
	## 3-arrays. {} if any is missing (the backend sends null when it can't resolve it).
	for key in ["origin", "normal", "x_axis", "y_axis"]:
		if not (response.get(key) is Array) or (response[key] as Array).size() != 3:
			return {}
	return {
		"origin": _vec(response["origin"]),
		"x": _vec(response["x_axis"]).normalized(),
		"y": _vec(response["y_axis"]).normalized(),
		"n": _vec(response["normal"]).normalized(),
	}


static func has_frame(row: Dictionary) -> bool:
	## Does the backend's sketch-feature row carry the whole resolved frame (DIDSA-CAD flutter-testing plan item 2: `resolved_frame_origin`,
	## `resolved_x_axis`, `resolved_y_axis`, `resolved_normal`, each [x, y, z] in the part's frame)? An older backend sends none of them.
	for key in ["resolved_frame_origin", "resolved_x_axis", "resolved_y_axis", "resolved_normal"]:
		if not (row.get(key) is Array) or (row[key] as Array).size() != 3:
			return false
	return true


static func with_frame(basis: Dictionary, row: Dictionary) -> Dictionary:
	## The sketch's frame in the part: the backend's resolved frame when the row carries one (anchor plane -> alignment to an edge or line ->
	## flip / turns -> origin: the exact vectors `basis_for_sketch` draws and extrudes with, so a point at (u, v) is origin + u*x + v*y), else
	## `basis` with `with_origin` (an older backend). `basis` may be empty when the row has a frame (the plane need not be found at all).
	## A FLIPPED frame is left-handed (x cross y = -normal): `n` here is always x cross y, so the table layout (`orient_to_table`) stays a
	## rotation and the sheet is simply seen from the other side, X right and Y away exactly as the flat app's 2D view shows them; `mirrored`
	## says so. Unit vectors are re-normalised (the wire rounds them).
	if not has_frame(row):
		return with_origin(basis, row)
	var x := _vec(row["resolved_x_axis"]).normalized()
	var y := _vec(row["resolved_y_axis"]).normalized()
	var normal := _vec(row["resolved_normal"]).normalized()
	var n := x.cross(y).normalized()
	return {"origin": _vec(row["resolved_frame_origin"]), "x": x, "y": y, "n": n, "mirrored": n.dot(normal) < 0.0}


static func with_origin(basis: Dictionary, row: Dictionary) -> Dictionary:
	## `basis` with its origin moved to the sketch's own origin, when the backend's sketch-feature row carries one: `resolved_origin`
	## (DIDSA-CAD's sketch origin, [x, y, z] in the part's frame, already projected onto the plane). The axes and the normal stay the plane's.
	## A row with no `resolved_origin` key is a sketch from before the origin existed (an older backend), and a `resolved_origin` of null is
	## an origin the backend could not resolve and fell back from: both keep the plane's own origin, which is what the backend drew with too.
	## An empty basis stays empty.
	var moved = row.get("resolved_origin")
	if basis.is_empty() or not (moved is Array) or (moved as Array).size() != 3:
		return basis
	var out := basis.duplicate()
	out["origin"] = _vec(moved)
	return out


static func orient_to_table(plane: Dictionary) -> Basis:
	## The rotation to give the part (in console space) so the sketch plane lies flat on the
	## table with its x axis to the right: maps plane x -> console +X, plane y -> console -Z,
	## plane n -> console +Y.
	var from_plane := Basis(plane["x"], plane["y"], plane["n"])
	var to_table := Basis(TABLE_X, TABLE_Y, TABLE_N)
	return (to_table * from_plane.inverse()).orthonormalized()


static func grid_step(target_mm: float) -> float:
	## The sketch grid's minor spacing: the 1-2-5 step (..., 0.5, 1, 2, 5, 10, 20, 50, ...) at or just above `target_mm`, so the lines
	## stay about the same distance apart on screen whatever the zoom.
	var t := maxf(target_mm, 0.0001)
	var decade := pow(10.0, floorf(log(t) / log(10.0)))
	for m in [1.0, 2.0, 5.0, 10.0]:
		if decade * m >= t * 0.999:
			return decade * m
	return decade * 10.0


static func ray_plane(origin: Vector3, dir: Vector3, plane_point: Vector3, plane_normal: Vector3) -> Variant:
	## The point where a ray meets a plane, or null if it's parallel or behind the origin.
	var denom := dir.dot(plane_normal)
	if absf(denom) < 0.000001:
		return null
	var t := (plane_point - origin).dot(plane_normal) / denom
	if t < 0.0:
		return null
	return origin + dir * t


static func to_sheet(part_point: Vector3, plane: Dictionary) -> Vector2:
	## A point in the part's frame -> (u, v) on the sheet (its distance off the plane is dropped).
	var d: Vector3 = part_point - (plane["origin"] as Vector3)
	return Vector2(d.dot(plane["x"]), d.dot(plane["y"]))


static func from_sheet(uv: Vector2, plane: Dictionary) -> Vector3:
	return (plane["origin"] as Vector3) + (plane["x"] as Vector3) * uv.x + (plane["y"] as Vector3) * uv.y


static func plane_from_face_triangles(points: PackedVector3Array) -> Dictionary:
	## A provisional basis for a planar face from its triangles' corner points (3 per
	## triangle in the mesh's own winding, part frame): origin = the mean, n = the area-weighted outward normal, x/y
	## picked deterministically. Used only to turn the part to face the plane while the
	## backend creates the real one; the backend's response replaces it.
	if points.size() < 3:
		return {}
	var centre := Vector3.ZERO
	var normal := Vector3.ZERO
	for i in range(0, points.size() - 2, 3):
		var a := points[i]
		var b := points[i + 1]
		var c := points[i + 2]
		normal += (c - a).cross(b - a) # Godot front faces are clockwise, so this is the outward normal (twice the triangle's area long)
		centre += a + b + c
	centre /= float(points.size())
	if normal.length() < 0.000001:
		return {}
	normal = normal.normalized()
	var helper := Vector3(0, 0, 1) if absf(normal.z) < 0.9 else Vector3(1, 0, 0)
	var x := helper.cross(normal).normalized()
	var y := normal.cross(x).normalized()
	return {"origin": centre, "x": x, "y": y, "n": normal}


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


# --- Construction methods (Phase 7.4): the maths of the shapes made from taps other than the plain ones ----------------

static func circumcircle(a: Vector2, b: Vector2, c: Vector2) -> Dictionary:
	## The circle through three points: {ok, centre, radius}. ok is false when they are in a line (or two coincide).
	var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
	if absf(d) < 1e-6:
		return {"ok": false, "centre": Vector2.ZERO, "radius": 0.0}
	var a2 := a.length_squared()
	var b2 := b.length_squared()
	var c2 := c.length_squared()
	var centre := Vector2((a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d, (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
	return {"ok": true, "centre": centre, "radius": centre.distance_to(a)}


static func rect_from_centre(centre: Vector2, corner: Vector2) -> Array:
	## The four corners, in order, of the axis-aligned rectangle with this centre and one corner. [] when it has no width or no height.
	var dx := absf(corner.x - centre.x)
	var dy := absf(corner.y - centre.y)
	if dx < 0.01 or dy < 0.01:
		return []
	return [centre + Vector2(-dx, -dy), centre + Vector2(dx, -dy), centre + Vector2(dx, dy), centre + Vector2(-dx, dy)]


static func rect_from_three(p1: Vector2, p2: Vector2, p3: Vector2) -> Array:
	## The four corners, in order, of the rectangle whose first side is p1 to p2 and whose width reaches p3's side of that line (a turned rectangle).
	## [] when the first side has no length or p3 is on the line.
	var side := p2 - p1
	if side.length() < 0.01:
		return []
	var normal := Vector2(-side.y, side.x).normalized()
	var width := (p3 - p1).dot(normal)
	if absf(width) < 0.01:
		return []
	return [p1, p2, p2 + normal * width, p1 + normal * width]


static func mirrored_end(centre: Vector2, end: Vector2) -> Vector2:
	## The other end of a line drawn from its middle: the first end reflected through the centre.
	return centre * 2.0 - end
