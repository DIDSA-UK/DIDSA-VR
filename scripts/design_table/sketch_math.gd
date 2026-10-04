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
