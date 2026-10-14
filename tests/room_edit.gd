extends SceneTree
## Assembly Rooms, drop-to-add and delete: the editing logic (scripts/room/room_edit.gd) against a fake document, so every call it makes is visible.
## The guards the real server lacks (a Part into itself or into one that contains it, an unknown Part id), the pose it sends (the room's millimetres, the
## room's scale dropped), adding from a file (the file's text sent as it is, then placed), delete (what it counts and snapshots) and restore.
## Run: "$GODOT" --headless --path . --script res://tests/room_edit.gd  (see tests/README.md)

const RoomEdit := preload("res://scripts/room/room_edit.gd")
const FakeApi := preload("res://tests/fake_room_api.gd")


func tagged(parent: Node, owner: String, occ: String) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = BoxMesh.new()
	m.set_meta("owner_part_id", owner)
	m.set_meta("occurrence_id", occ)
	parent.add_child(m)
	return m


func _initialize() -> void:
	var api := FakeApi.new()
	# The document: root R holds sub-assembly S (occurrence "s1") and a loose bolt (occurrence "b1"); S holds bracket K ("k1") which holds the bolt Part B too.
	api.occurrences = {
		"R": [api.row("s1", "S"), api.row("b1", "B")],
		"S": [api.row("k1", "K")],
		"K": [api.row("kb", "B")],
		"B": [],
	}
	api.mates = {"S": [{"references": [{"occurrence_id": "k1"}, {"occurrence_id": ""}]}], "R": []}
	var e := RoomEdit.new(api)
	var holder := Node3D.new()
	root.add_child(holder)
	var bolt_in_world := tagged(holder, "R", "b1") # shows Part B
	var sub_in_world := tagged(holder, "R", "s1") # shows Part S
	var root_content := tagged(holder, "R", "")
	var unknown := tagged(holder, "R", "nope")

	# --- which Part does a node show
	print("SMOKE a placed node shows the Part its occurrence points at: ", await e.definition_of(bolt_in_world) == "B" and await e.definition_of(sub_in_world) == "S")
	print("SMOKE root content and an unknown occurrence show no Part (nothing to copy): ", await e.definition_of(root_content) == "" and await e.definition_of(unknown) == "")
	var reads_before := api.count(HTTPClient.METHOD_GET, "/parts/R/occurrences")
	await e.definition_of(bolt_in_world)
	print("SMOKE ...and the owner's list is read once and cached: ", api.count(HTTPClient.METHOD_GET, "/parts/R/occurrences") == reads_before)

	# --- the guards the server does not have
	print("SMOKE a Part can't go into itself: ", await e.check_addable("S", "S") != "")
	print("SMOKE ...nor into a Part nested inside what it contains, however deep (S holds K holds B, so S can't be added to B or to K): ", await e.check_addable("B", "S") != "" and await e.check_addable("K", "S") != "")
	print("SMOKE a Part that doesn't contain the room's Part may be added (B into S, a bolt next to the bracket): ", await e.check_addable("S", "B") == "")
	print("SMOKE ...but no Part at all is refused with its own reason: ", (await e.check_addable("S", "")).contains("no source Part"))

	# --- the pose: the room's millimetres, the room's scale dropped
	var content := Node3D.new()
	holder.add_child(content)
	content.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.01), Vector3(0, 1, -3)) # 1 mm = 1 cm: a 10:1 room
	await process_frame
	var world_pose := Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)).scaled(Vector3.ONE * 0.001), Vector3(0.5, 1.0, -3.0)) # the carried part is at the WORLD's scale (0.001), turned 90 degrees
	var pose := RoomEdit.pose_in_room(world_pose, content)
	var t: Array = pose["translation"]
	print("SMOKE 0.5 m along the room's x is 50 mm in the room's Part (10:1 room), whatever scale the carried part had: ", absf(t[0] - 50.0) < 0.001 and absf(t[1]) < 0.001 and absf(t[2]) < 0.001)
	print("SMOKE ...and its turn is kept (90 degrees about the vertical): ", absf(float(pose["rotation_angle_degrees"]) - 90.0) < 0.01 and absf(absf(pose["rotation_axis"][1]) - 1.0) < 0.001)

	# --- adding a copy
	var added: Dictionary = await e.add_copy("S", bolt_in_world, world_pose, content, "")
	var post := api.last(HTTPClient.METHOD_POST, "/parts/S/occurrences")
	print("SMOKE adding a bolt to S posts a new occurrence of Part B with a client-made id and the pose: ", added["ok"] and post["body"]["resolved_part_id"] == "B" and str(post["body"]["id"]).begins_with("occ_") and post["body"]["id"] == added["occurrence_id"] and absf(post["body"]["transform"]["translation"][0] - 50.0) < 0.001)
	print("SMOKE ...and the backend's list for S now holds it (the cache was dropped): ", (await e.occurrences_of("S")).any(func(r): return r["id"] == added["occurrence_id"]))
	var posts_before := api.count(HTTPClient.METHOD_POST, "/occurrences")
	var cyc: Dictionary = await e.add_copy("S", sub_in_world, world_pose, content, "")
	print("SMOKE adding S to S is refused before any call is made: ", not cyc["ok"] and cyc["error"].contains("can't hold itself") and api.count(HTTPClient.METHOD_POST, "/occurrences") == posts_before)
	var rootless: Dictionary = await e.add_copy("S", root_content, world_pose, content, "")
	print("SMOKE ...and so is adding the assembly's own root content: ", not rootless["ok"] and api.count(HTTPClient.METHOD_POST, "/occurrences") == posts_before)
	api.fail_next_post = true
	var failed: Dictionary = await e.add_copy("S", bolt_in_world, world_pose, content, "")
	print("SMOKE a failed post says so and leaves nothing half-done: ", not failed["ok"] and failed["error"].contains("boom"))

	# --- adding from a file
	var file_text := '{"schema_version": 1, "document": {"root_part_id": "x", "parts": []}}'
	var from_file: Dictionary = await e.add_file("S", file_text, {"translation": [1.0, 2.0, 3.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}, "Plate")
	var add_call := api.last(HTTPClient.METHOD_POST, "/parts/S/add-component")
	var patch_call := api.last(HTTPClient.METHOD_PATCH, "/parts/S/occurrences/")
	print("SMOKE a file is sent to add-component as its own text, unchanged: ", from_file["ok"] and add_call["body"] is String and (add_call["body"] as String).contains(file_text))
	print("SMOKE ...and the new occurrence is then placed (and named): ", patch_call["path"].ends_with(from_file["occurrence_id"]) and patch_call["body"]["transform"]["translation"][2] == 3.0 and patch_call["body"]["name_override"] == "Plate")

	# --- a file that would put the assembly inside itself
	var calls_before := api.count(HTTPClient.METHOD_POST, "/add-component")
	var own_root := '{"schema_version": 1, "document": {"root_part_id": "S", "parts": [{"id": "S", "occurrences": []}]}}'
	var holds_it := '{"schema_version": 1, "document": {"root_part_id": "F", "parts": [{"id": "F", "occurrences": [{"id": "o1", "resolved_part_id": "G"}]}, {"id": "G", "occurrences": [{"id": "o2", "resolved_part_id": "S"}]}]}}'
	var via_document := '{"schema_version": 1, "document": {"root_part_id": "F", "parts": [{"id": "F", "occurrences": [{"id": "o1", "resolved_part_id": "R"}]}]}}'
	var unrelated := '{"schema_version": 1, "document": {"root_part_id": "Q", "parts": [{"id": "Q", "occurrences": [{"id": "o1", "resolved_part_id": "Z"}]}, {"id": "Z", "occurrences": []}]}}'
	print("SMOKE a file whose root is the assembly itself is refused: ", (await e.file_conflict("S", own_root)).contains("can't hold itself") or (await e.file_conflict("S", own_root)).contains("Can't add"))
	print("SMOKE ...so is one that holds it deeper down (the server would accept it): ", (await e.file_conflict("S", holds_it)) != "")
	print("SMOKE ...and one that holds a Part the document already has that contains it: ", (await e.file_conflict("S", via_document)) != "")
	print("SMOKE ...an unrelated file is allowed: ", (await e.file_conflict("S", unrelated)) == "")
	print("SMOKE ...something that isn't a native file is refused: ", (await e.file_conflict("S", "[1, 2]")).contains("native"))
	var refused: Dictionary = await e.add_file("S", holds_it, {"translation": [0.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0})
	print("SMOKE adding such a file makes no call to the backend and says why: ", not refused["ok"] and refused["error"].contains("itself") and api.count(HTTPClient.METHOD_POST, "/add-component") == calls_before)

	# --- delete and restore
	var gone: Dictionary = await e.delete_occurrence("S", "k1")
	print("SMOKE deleting a part snapshots it and counts the Mates that go with it: ", gone["ok"] and gone["snapshot"]["id"] == "k1" and gone["snapshot"]["resolved_part_id"] == "K" and gone["mates_removed"] == 1)
	print("SMOKE ...and it is gone from the backend's list: ", not (await e.occurrences_of("S")).any(func(r): return r["id"] == "k1"))
	var restored: Dictionary = await e.restore_occurrence("S", gone["snapshot"])
	var restore_call := api.last(HTTPClient.METHOD_POST, "/parts/S/occurrences")
	print("SMOKE restoring posts it back with its old id and what it had, and nothing else: ", restored["ok"] and restore_call["body"]["id"] == "k1" and restore_call["body"]["resolved_part_id"] == "K" and restore_call["body"].has("fixed") and not restore_call["body"].has("document_id"))
	print("SMOKE ...the Mates the delete took do not come back (it says so by not trying): ", api.mates["S"].is_empty())
	var missing: Dictionary = await e.delete_occurrence("S", "never-existed")
	var deletes_before := api.count(HTTPClient.METHOD_DELETE, "/occurrences")
	print("SMOKE deleting a part that isn't there fails cleanly with no delete call: ", not missing["ok"] and api.count(HTTPClient.METHOD_DELETE, "/occurrences") == deletes_before)
	print("SMOKE undoing an add removes exactly that occurrence: ", await e.remove_added("S", added["occurrence_id"]) and not (await e.occurrences_of("S")).any(func(r): return r["id"] == added["occurrence_id"]))

	# --- the room's mesh
	e.mesh_quality = 0.75
	e.mesh_tier = "coarse"
	e.mesh_include_hidden = true
	api.glb = PackedByteArray([1, 2, 3])
	var bytes := await e.fetch_part_glb("S")
	var mesh_call: Dictionary = api.calls.back()
	print("SMOKE a room's mesh is the Part's own glb with the app's quality, tier and hidden settings: ", bytes.size() == 3 and mesh_call["path"] == "/document/parts/S/assembly-mesh.glb?quality=0.75&include_hidden=true&tier=coarse")
	api.glb = PackedByteArray()
	print("SMOKE ...and an unreadable one comes back empty: ", (await e.fetch_part_glb("S")).is_empty())
	quit()
