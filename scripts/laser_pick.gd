extends RefCounted
## The laser's ray test against parts' real collision geometry, and "what would a pick take there", shared by
## everything that aims at a part: controller.gd (select, shoot-to-hide, Mates, Measure) and the design table
## (choosing a sketch plane, picking edges for a fillet). One copy of the ray loop, so a fix to it fixes all of them.
##
## A part is the PARENT of the StaticBody3D that create_trimesh_collision() adds. The caller's `classify` says
## what to do with each part the ray meets, nearest first:
##   HIT    this is the one: return it
##   SKIP   click-through (a hidden or held part): carry on to whatever is behind it
##   BLOCK  something solid that is not a target: stop, nothing was hit
## so a table copy or a panel in front of an arena part really does shield it.

const TopologyPick := preload("res://scripts/topology_pick.gd")

const HIT := 0
const SKIP := 1
const BLOCK := 2
const MAX_SKIPS := 8 ## generous, so a stack of hidden / held parts can't loop forever


static func ray(world: World3D, origin: Vector3, direction: Vector3, max_distance: float, classify: Callable, mask: int = 0xFFFFFFFF) -> Dictionary:
	## {} if nothing was hit, else {part, point (world), face_index, normal (world), distance}.
	var space_state := world.direct_space_state
	var excluded: Array[RID] = []
	for _attempt in MAX_SKIPS:
		var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * max_distance, mask)
		query.exclude = excluded
		var result := space_state.intersect_ray(query)
		if result.is_empty():
			return {}
		var collider: Object = result.get("collider")
		var part: Node3D = collider.get_parent() if collider is StaticBody3D else null
		var verdict: int = int(classify.call(part)) if part != null else BLOCK
		if verdict == BLOCK:
			return {}
		if verdict == SKIP:
			excluded.append((collider as StaticBody3D).get_rid())
			continue
		var point: Vector3 = result.get("position")
		return {"part": part, "point": point, "face_index": result.get("face_index", -1),
			"normal": result.get("normal", Vector3.ZERO), "distance": origin.distance_to(point)}
	return {}


static func entity_for(part: Node3D, hit: Dictionary, origin: Vector3, mates_only: bool = false) -> Dictionary:
	## What a pick at this ray hit would take: a vertex, an edge or the face (topology_pick.gd). {} if the
	## part has no face identity. `mates_only`: only edges a mate can use are candidates.
	if part == null or not hit.has("point"):
		return {}
	var distance := origin.distance_to(hit["point"])
	return TopologyPick.pick(part, int(hit.get("face_index", -1)), hit["point"], TopologyPick.reach_for(part as MeshInstance3D, distance), mates_only)
