extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY — never against a shared backend): New assembly
## and New part end to end. A new empty assembly is started (a fresh backend document with ONE root part, the arena empty); New
## part puts an empty part on the table; a sketch is opened on the XY reference plane, a rectangle drawn and extruded (the real
## mesh arrives on the table and in the arena); the part is given back to the arena; a second part is made and discarded empty
## (its occurrence goes); the session is exported in the native format and read back in: one root first, the child parts, their
## occurrences with the ids and poses VR sent — the shape the flat app's bundle open reads.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_new_part.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var api


func req(method: int, path: String, body = null) -> Dictionary:
	return await api.request(method, path, body)


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg — this test needs a running local backend, see tests/README.md")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	var url := str(cfg.get_value("backend", "url"))
	var key := str(cfg.get_value("backend", "api_key"))
	main.backend_url = url
	main.api_key = key
	table = main.design_table
	table.configure_backend(url, key)
	api = table.api
	table.surface.settle_seconds = 0.0

	# --- a new assembly
	var made: bool = await main.new_assembly()
	var root_id: String = main.current_root_part_id()
	print("SMOKE New assembly succeeds against the real backend and the arena is empty: ", not made and root_id != "" and get_nodes_in_group("grabbable_parts").size() == 0, " ", main.status_text)
	var doc: Dictionary = await req(HTTPClient.METHOD_GET, "/document/export/native")
	var parts: Array = doc["json"]["document"]["parts"] if doc["ok"] and doc["json"] is Dictionary else []
	print("SMOKE ...the backend document is fresh: one part, the root, named Assembly, no occurrences: ", parts.size() == 1 and parts[0]["id"] == root_id and parts[0]["name"] == "Assembly" and (parts[0]["occurrences"] as Array).is_empty() and doc["json"]["document"]["root_part_id"] == root_id)

	# --- a new part on the table
	await table.new_part()
	var node: MeshInstance3D = table.seated
	var ready: bool = await wait_for(func() -> bool: return table.editor.state == "pick_plane")
	print("SMOKE New part puts Part 1 on the table, blank, and plane picking opens: ", node != null and node.name == "Part 1" and table.is_blank() and ready and table.editor.part_id != "", " ", table.status())
	var part_id: String = table.editor.part_id
	var occ_rows: Dictionary = await req(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % root_id)
	print("SMOKE the backend root holds the new occurrence, resolved to the new part, with the pose VR sent: ", occ_rows["ok"] and (occ_rows["json"] as Array).size() == 1 and occ_rows["json"][0]["resolved_part_id"] == part_id and occ_rows["json"][0]["id"] == node.get_meta("occurrence_id") and occ_rows["json"][0]["name_override"] == "Part 1" and absf(float(occ_rows["json"][0]["transform"]["translation"][0]) - node.transform.origin.x) < 0.01)

	# --- sketch on the XY reference plane, a rectangle, extrude
	var opened: bool = await table.editor.begin_sketch({"fixed": "XY"})
	table.manager.activate("rectangle")
	var c: Vector2 = table.editor.view.sheet_centre
	await table.editor.session.tap({"uv": Vector2(0, 0), "id": ""})
	await table.editor.session.tap({"uv": Vector2(60, 40), "id": ""})
	print("SMOKE a sketch opens on the XY plane of the empty part and a rectangle closes a loop: ", opened and table.editor.state == "sketch" and table.editor.session.profile_ok())
	table.manager.activate("extrude")
	table.editor.options["boss"] = true
	table.editor.options["depth"] = 12.0
	await table.editor.apply_feature()
	var got_mesh: bool = await wait_for(func() -> bool: return not table.is_blank())
	print("SMOKE extruding it gives the part its first geometry: the placeholder is replaced by a real mesh (~60 x 40 x 12 mm), on the table and in the arena node: ", got_mesh and node.mesh is ArrayMesh and absf(node.get_aabb().size.x - 60.0) < 0.5 and absf(node.get_aabb().size.y - 40.0) < 0.5 and absf(node.get_aabb().size.z - 12.0) < 0.5 and table.table_copy.layers == 1, " ", table.status())

	# --- give it back: it stays in the arena as a placed part
	table.return_to_arena()
	await process_frame
	print("SMOKE giving it back leaves a real placed part in the arena where it was put: ", table.seated == null and node.visible and node.is_in_group("grabbable_parts") and not node.get_meta("blank", true))
	var glb: Dictionary = await api.fetch_bytes("/document/parts/%s/assembly-mesh.glb?quality=0.5" % root_id)
	print("SMOKE ...and the backend's own view of the assembly now has a mesh node for it (the occurrence is real): ", glb["ok"] and glb["bytes"].size() > 2000)

	# --- a second part that nothing is drawn on is discarded
	await table.new_part()
	var second: MeshInstance3D = table.seated
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")
	var second_name := second.name
	var second_occ := str(second.get_meta("occurrence_id"))
	table.close()
	await wait_for(func() -> bool: return table.api.requests_sent > 0, 30)
	for i in 30:
		await process_frame
	var after: Dictionary = await req(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % root_id)
	print("SMOKE %s was named in order, and closing the table with it empty took its occurrence off the assembly: " % second_name, second_name == "Part 2" and after["ok"] and (after["json"] as Array).size() == 1 and not (after["json"] as Array).any(func(o): return o["id"] == second_occ))

	# --- the saved file: the shape the flat app's bundle open reads
	var exported: Dictionary = await req(HTTPClient.METHOD_GET, "/document/export/native")
	var native: Dictionary = exported["json"]
	var native_parts: Array = native["document"]["parts"]
	var root_part: Dictionary = native_parts[0]
	var child: Dictionary = {}
	for p in native_parts:
		if p["id"] == part_id:
			child = p
	var occ: Dictionary = (root_part["occurrences"] as Array)[0] if not (root_part["occurrences"] as Array).is_empty() else {}
	print("SMOKE the exported native file has the root FIRST (and as root_part_id), the drawn part with its sketch and extrude, and one occurrence resolved to it: ", native["document"]["root_part_id"] == root_id and root_part["id"] == root_id and not child.is_empty() and (child["features"] as Array).map(func(f): return f["type"]).has("extrude") and (child["features"] as Array).map(func(f): return f["type"]).has("sketch") and (root_part["occurrences"] as Array).size() == 1 and occ.get("resolved_part_id") == part_id and occ.get("name_override") == "Part 1")
	var again: Dictionary = await req(HTTPClient.METHOD_POST, "/document/import/native", native)
	var re_export: Dictionary = await req(HTTPClient.METHOD_GET, "/document/export/native")
	var re_parts: Array = re_export["json"]["document"]["parts"]
	var re_root: Dictionary = re_parts[0]
	print("SMOKE ...and importing it back (what the flat app's bundle open does) gives the same root, parts and occurrence: ", again["ok"] and re_export["json"]["document"]["root_part_id"] == root_id and re_parts.size() == native_parts.size() and (re_root["occurrences"] as Array).size() == 1 and re_root["occurrences"][0]["resolved_part_id"] == part_id and re_root["occurrences"][0]["id"] == occ["id"])

	# --- a second New assembly does not pile up
	main.document_dirty = false # (the edits above would otherwise make New assembly warn first, which work_loss.gd covers)
	await main.new_assembly()
	var fresh: Dictionary = await req(HTTPClient.METHOD_GET, "/document/export/native")
	print("SMOKE a second New assembly starts clean: one part again, none of the old ones: ", (fresh["json"]["document"]["parts"] as Array).size() == 1 and fresh["json"]["document"]["parts"][0]["id"] == main.current_root_part_id() and main.current_root_part_id() != root_id)

	# --- importing a file starts from a clean document too (it used to pile each import onto the last)
	var obj := "v 0 0 0\nv 20 0 0\nv 20 20 0\nv 0 20 0\nv 0 0 20\nv 20 0 20\nv 20 20 20\nv 0 20 20\n" \
		+ "f 1 3 2\nf 1 4 3\nf 5 6 7\nf 5 7 8\nf 1 2 6\nf 1 6 5\nf 2 3 7\nf 2 7 6\nf 3 4 8\nf 3 8 7\nf 4 1 5\nf 4 5 8\n"
	var obj_path := "user://e2e_cube.obj"
	var f := FileAccess.open(obj_path, FileAccess.WRITE)
	f.store_string(obj)
	f.close()
	main.document_dirty = false
	await main._import_external_file(obj_path, "obj")
	main.document_dirty = false
	await main._import_external_file(obj_path, "obj")
	var piled: Dictionary = await req(HTTPClient.METHOD_GET, "/document/export/native")
	print("SMOKE importing a file twice leaves ONE part in the backend document, not a pile: ", piled["ok"] and (piled["json"]["document"]["parts"] as Array).size() == 1 and get_nodes_in_group("grabbable_parts").size() >= 1, " ", (piled["json"]["document"]["parts"] as Array).size() if piled["ok"] else piled["error"])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(obj_path))
	quit()
