extends SceneTree
## Picking a whole BODY with the laser (Phase 5.3), for the tools that work on bodies (Pattern, Boolean, Merge, Split...): the laser lights
## the whole body under it (every triangle of the body, key "solid:<body>"), a pull picks it, a second pull lets it go, several bodies
## stack in the set colour, a limit replaces the oldest, Clear forgets them, and a body lit as a set / hover is the whole body, not a face.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_body_pick.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	# The fixture's box is one body: the top face's triangles are given to a second body, so the part has two to pick between.
	var top: Dictionary = rig.top_face()
	var ids: Array = table.table_copy.get_meta("body_ids").duplicate()
	var face_ids: Array = table.table_copy.get_meta("face_ids")
	for i in ids.size():
		if str(ids[i]) == str(top["body_id"]) and int(face_ids[i]) == int(top["index"]):
			ids[i] = "body_top"
	table.table_copy.set_meta("body_ids", ids)
	ed.highlight.invalidate(table.table_copy)
	var bodies_in_part: Array = []
	for id in table.table_copy.get_meta("body_ids"):
		if not bodies_in_part.has(str(id)):
			bodies_in_part.append(str(id))
	print("SMOKE the part has two bodies to pick between: ", bodies_in_part.size() == 2, " ", bodies_in_part)
	var e := TopologyPick.body_entity(rig.box, 0)
	print("SMOKE a body entity names the whole body, not a face: ", e["kind"] == "body" and e["index"] == -1 and e["key"] == "solid:" + str(e["body_id"]))
	ed.start_body_picks()
	print("SMOKE start_body_picks puts the editor in body picking: ", ed.state == "pick_bodies")
	await rig.aim_at_part()
	print("SMOKE aiming at the part lights a BODY: ", ed.hovering and ed._hover_face.get("kind") == "body")
	var node: MeshInstance3D = ed.highlight.hover_node(rig.r)
	var tris_lit: int = 0
	if node != null:
		tris_lit = (node.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3
	var tris_in_body := 0
	for id in table.table_copy.get_meta("body_ids"):
		if str(id) == str(ed._hover_face.get("body_id", "")):
			tris_in_body += 1
	print("SMOKE ...every triangle of that body is lit, and no other: ", node != null and tris_lit == tris_in_body and tris_lit > 0, " ", tris_lit, "/", tris_in_body)
	await rig.pull()
	print("SMOKE a pull picks it, lit in the set colour: ", ed.bodies.size() == 1 and ed.highlight.set_nodes().size() == 1)
	await rig.pull()
	print("SMOKE a second pull lets it go: ", ed.bodies.is_empty() and ed.highlight.set_nodes().is_empty())
	await rig.pull()
	var first_key: String = ed.bodies[0]["key"]
	# the other body: aim at the cylinder (the fixture's other solid) by sweeping the laser over the part until the lit body changes
	var other := ""
	var base: Vector3 = table.pivot.global_position
	for off in [Vector3(0.0, 0.02, 0.6), Vector3(0.0, 0.6, 0.05), Vector3(0.45, 0.1, 0.1), Vector3(-0.45, 0.1, 0.1), Vector3(0.0, -0.1, 0.5), Vector3(0.3, 0.3, 0.3)]:
		await rig.aim(base + table.global_transform.basis * off, base)
		if ed.hovering and ed._hover_face.get("kind") == "body" and ed._hover_face["key"] != first_key:
			other = ed._hover_face["key"]
			break
	print("SMOKE the laser can reach the other body: ", other != "")
	if other != "":
		await rig.pull()
		print("SMOKE ...pulling on it adds it (two bodies, in the set colour): ", ed.bodies.size() == 2 and ed.highlight.set_nodes().size() == 2 and ed.body_refs().size() == 2)
		ed.clear_picks()
		ed.body_limit = 1
		await rig.pull()
		var kept_first: String = ed.bodies[0]["key"]
		await rig.aim_at_part()
		await rig.pull()
		print("SMOKE with a limit of one a new pick replaces the one before: ", ed.bodies.size() == 1 and ed.bodies[0]["key"] != kept_first and ed.highlight.set_nodes().size() == 1)
	ed.clear_picks()
	print("SMOKE Clear forgets the bodies and unlights them: ", ed.bodies.is_empty() and ed.highlight.set_nodes().is_empty())
	table.manager.activate("fillet")
	print("SMOKE leaving for an edge tool leaves body picking: ", ed.state == "pick_edges")
	quit()
