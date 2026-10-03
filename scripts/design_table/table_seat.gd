extends RefCounted
## The numbers behind putting a part on the design table and lifting it off again.
## Pure functions over transforms and boxes, no scene tree, so tests can pin them.
##
## Table space is the console's own frame: origin at the middle of the slab, +X to the
## user's right, +Y up out of the slab, +Z towards the user. The part floats at
## `hover` above the slab and is scaled so its bounding sphere has radius `fit_radius`
## (a sphere, so turning it to a sketch plane never makes it poke out of the table).


static func fit_scale(aabb: AABB, fit_radius: float) -> float:
	## Metres per model unit (the part's own mm) that makes the part's bounding sphere
	## `fit_radius` across. 0 for an empty box.
	var half_diagonal := aabb.size.length() * 0.5
	if half_diagonal <= 0.000001:
		return 0.0
	return fit_radius / half_diagonal


static func copy_offset(aabb: AABB, scale: float, basis: Basis) -> Vector3:
	## Where to put the scaled copy relative to the pivot so the middle of its bounds is AT the
	## pivot however the pivot is turned: -(rotation * scale * centre).
	return -(basis * (aabb.get_center() * scale))


static func in_drop_zone(local_point: Vector3, slab_size: Vector2, floor_y: float, ceiling_y: float) -> bool:
	## True if a point in console space is above the slab (inside its footprint, with a
	## little slack) and between the two heights.
	return absf(local_point.x) <= slab_size.x * 0.5 + 0.05 \
		and absf(local_point.z) <= slab_size.y * 0.5 + 0.05 \
		and local_point.y >= floor_y and local_point.y <= ceiling_y


static func lift_transform(parent_basis: Basis, original_local_basis: Basis, aabb: AABB, copy_centre_world: Vector3) -> Transform3D:
	## The world transform a part gets when it's lifted off: its ORIGINAL orientation and
	## the arena's CURRENT scale (parent_basis carries assembly_root's scale, so a model
	## resized while the part sat on the table still lifts back at the right size), placed so
	## the middle of its bounds is where the middle of the table copy was.
	var basis := parent_basis * original_local_basis
	var origin := copy_centre_world - basis * aabb.get_center()
	return Transform3D(basis, origin)
