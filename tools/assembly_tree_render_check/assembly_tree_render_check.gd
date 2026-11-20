extends SceneTree
## A5 check of the Assembly Tree window: real backend (DIDSA-CAD main, GET /parts/{id}/assembly-tree) AND, when there is a renderer, pictures.
## Fixtures are built through the backend's API (POST /import/native for the parts, POST /parts/{id}/mates, PATCH an occurrence's transform), from
## demo/assemblies/plate_and_peg/Plate_and_peg.didsa's two real parts plus generated feature-less parts; nothing is written to the repo.
## Eight scenarios (TREE_SCENARIOS=a,c,... picks some; default all), each asserted on the window's own rows (a SMOKE line) and, with a renderer, saved as PNG:
##   a  a two-level assembly just opened: the structure only (status held back), then after ?status=true has merged in
##   b  a collapsed parent with a missing file and an over-constrained part below it: the count bubble (then open)
##   c  one Part placed 4 times in a level: "Peg x4" closed, open, and with "Fold x4" off
##   d  a part fixed from the tree: the pin straight after Fix, after the refresh, then after Float ('updating' until the fresh status arrives, then the open lock)
##   e  a part selected in the world: the tree opens down to it through a folded group
##   f  a rigid-set part that is over-constrained: the red tint wins over the set colour (the set ids are SYNTHETIC, see _patch_rigid_sets)
##   g  an older backend (a stand-in that answers the framework's 404 for the call): no Fold button, one level per request
##   h  a generated tree of 2,000 occurrences: the window open and scrolled; the time the rows took to build is printed as "SMOKE TIMING ..." (a number, not an assertion)
## Pictures: TREE_RENDER_DIR=/some/dir  xvfb-run -a "$GODOT" --path . --script res://tools/assembly_tree_render_check/assembly_tree_render_check.gd   (Mesa software GL, the GL-compatibility
## driver, not the project's mobile renderer). <name>.png is the window's own pixels (what the panel texture holds), <name>_wide.png the view from eye height with
## the model, <name>.txt the rows as text. Under --headless (a headless run) there is nothing to draw: only the SMOKE lines on the rows are checked.
## Needs secrets.cfg (backend url + api_key) pointing at a running backend (tools/start_backend.sh); the run replaces the backend's document. Settings: set
## DIDSA_SETTINGS_PATH=user://settings_test.cfg (the CI scripts do) so the "Fold x4" switch does not touch the real settings.
## A Mesa picture on Xvfb is layout, text, colours and state. It is not legibility at arm's length, reach, feel or the Quest's frame rate.

const BackendSession := preload("res://scripts/backend_session.gd")
const Model := preload("res://scripts/tree/occurrence_tree_model.gd")
const SOURCE := "res://demo/assemblies/plate_and_peg/Plate_and_peg.didsa"
const PLATE_ID := "8e28a0bb-648e-4c30-959c-40288e4ec9c1"
const PEG_ID := "88264a70-f22f-4451-ab79-cafd66663959"

var main
var window
var url := ""
var key := ""
var out_dir := ""
var rendering := false
var base: Dictionary = {}
var plate_part: Dictionary = {}
var peg_part: Dictionary = {}
var plate_body := ""
var peg_body := ""
var hold_status := false ## the stand-in answers a ?status=true call only when this is false (scenario a: the structure alone on screen first)
var older_backend := false ## the tree call answers the framework's 404 (scenario g)
var patch_sets: Array = [] ## scenario f: occurrence ids that get the same (synthetic) rigid set
var eye: Camera3D
var failed_requests := 0


# --- plumbing -------------------------------------------------------------------------------------------------------------------------------------

func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func wait_for(cond: Callable, timeout_ms: int = 90000) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout_ms:
		if cond.call():
			return true
		await process_frame
	return false


func frames(n: int) -> void:
	for i in n:
		await process_frame


func live(method: int, path: String, body = null, raw_text := "") -> Dictionary:
	## One call to the backend, answered like the window's own _request_json: {ok, json, code, detail, error}.
	var req := HTTPRequest.new()
	root.add_child(req)
	var payload := raw_text if raw_text != "" else (JSON.stringify(body) if body != null else "")
	req.request(url + "/document" + path, BackendSession.headers(key, payload != ""), method, payload)
	var result: Array = await req.request_completed
	req.queue_free()
	var text := (result[3] as PackedByteArray).get_string_from_utf8()
	var parsed = JSON.parse_string(text) if text != "" else null
	var code := int(result[1])
	var ok := int(result[0]) == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	if not ok:
		failed_requests += 1
		print("NOTE a backend call failed: %s %s -> HTTP %d %s" % [method, path, code, text.left(200)])
	return {"ok": ok, "json": parsed if ok else null, "code": code, "detail": str(parsed.get("detail", "")) if parsed is Dictionary else "", "error": "" if ok else text.left(300)}


func stand_in(method: int, path: String, body) -> Dictionary:
	## window.request_hook: the live backend, except what a scenario changes (held status, the older backend's 404, synthetic rigid sets).
	if path.contains("/assembly-tree"):
		if older_backend:
			return {"ok": false, "json": null, "code": 404, "detail": "Not Found", "error": "{\"detail\":\"Not Found\"}"}
		if path.contains("status=true"):
			while hold_status:
				await process_frame
		var answer: Dictionary = await live(method, path, body)
		if answer["ok"] and not patch_sets.is_empty() and path.contains("status=true"):
			_patch_rigid_sets(answer["json"])
		return answer
	return await live(method, path, body)


func _patch_rigid_sets(node: Dictionary) -> void:
	## SYNTHETIC: the backend could not be made to answer a rigid set with a healthy over-constrained neighbour (a set needs 6 constraints between ungrounded parts
	## and the fixture parts have too few mate-able planar faces), so the ids of the set are written into the live answer after the fact. The states are the backend's.
	for child in node.get("children", []):
		if (patch_sets as Array).has(str(child["occurrence_id"])) and child.get("constraint") is Dictionary:
			child["constraint"]["rigid_set"] = str(patch_sets[0])
		_patch_rigid_sets(child)


# --- fixtures (the backend's API) ------------------------------------------------------------------------------------------------------------------

func load_source() -> bool:
	var text := FileAccess.get_file_as_string(SOURCE)
	base = JSON.parse_string(text) if text != "" else {}
	if base.is_empty():
		return false
	for p in base["document"]["parts"]:
		if str(p["id"]) == PLATE_ID:
			plate_part = p
		elif str(p["id"]) == PEG_ID:
			peg_part = p
	plate_part["name"] = "Plate"
	peg_part["name"] = "Peg"
	return not plate_part.is_empty() and not peg_part.is_empty()


func resolve_bodies() -> void:
	## The id of each part's body (what a mate's reference names), read from the backend after the import.
	for pair in [[PLATE_ID, "plate"], [PEG_ID, "peg"]]:
		var answer: Dictionary = await live(HTTPClient.METHOD_GET, "/parts/%s/mesh" % pair[0])
		var bodies: Array = answer["json"] if answer["ok"] and answer["json"] is Array else []
		var id: String = str(bodies[0]["body_id"]) if not bodies.is_empty() else ""
		if pair[1] == "plate":
			plate_body = id
		else:
			peg_body = id


func blank_part(id: String, part_name: String, occurrences: Array = []) -> Dictionary:
	return {"id": id, "name": part_name, "features": [], "occurrences": occurrences, "mates": [], "component_patterns": []}


func occ(id: String, part_id: Variant, ref: String, at := Vector3.ZERO, opts := {}) -> Dictionary:
	## One placed occurrence; part_id null = a file that cannot be found (kind "missing").
	return {"id": id, "external_ref": ref, "resolved_part_id": part_id, "name_override": opts.get("name", null),
		"transform": {"translation": [at.x, at.y, at.z], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0},
		"suppressed": bool(opts.get("suppressed", false)), "hidden": false, "fixed": bool(opts.get("fixed", false)), "color": null}


func import_doc(root_id: String, parts: Array) -> bool:
	var doc := {"schema_version": base["schema_version"], "document": {"id": "tree-a5-render", "root_part_id": root_id, "parts": [plate_part.duplicate(true), peg_part.duplicate(true)] + parts},
		"sketches": base.get("sketches", []), "hidden_feature_ids": base.get("hidden_feature_ids", []), "section_planes": base.get("section_planes", [])}
	var answer: Dictionary = await live(HTTPClient.METHOD_POST, "/import/native", null, whole_numbers(JSON.stringify(doc)))
	if bool(answer["ok"]) and plate_body == "":
		await resolve_bodies()
	return bool(answer["ok"])


func whole_numbers(text: String) -> String:
	## GDScript's JSON reads every number as a float and writes 3 back as 3.0, which the backend's integer fields (a sketch's rotation_quarter_turns, a face index) refuse
	## (the same trap tests/README.md names for re-serialising a file). A float with nothing after the point is written as the integer it is: valid for the float fields too.
	var re := RegEx.new()
	re.compile("(?<=[:\\[,])(-?\\d+)\\.0(?=[,\\]}])")
	return re.sub(text, "$1", true)


func add_mate(part_id: String, type: String, occ_a: String, body_a: String, face_a: int, occ_b: String, body_b: String, face_b: int, value = null) -> bool:
	var refs: Array = []
	for side in [[occ_a, body_a, face_a], [occ_b, body_b, face_b]]:
		refs.append({"occurrence_id": side[0], "subshape_ref": {"body_id": side[1], "shape_type": "face", "index": side[2]}})
	var body := {"type": type, "references": refs}
	if value != null:
		body["value"] = value
	return bool((await live(HTTPClient.METHOD_POST, "/parts/%s/mates" % part_id, body))["ok"])


func move(part_id: String, occ_id: String, at: Vector3, axis := Vector3(0, 0, 1), degrees := 0.0) -> bool:
	var body := {"transform": {"translation": [at.x, at.y, at.z], "rotation_axis": [axis.x, axis.y, axis.z], "rotation_angle_degrees": degrees}}
	return bool((await live(HTTPClient.METHOD_PATCH, "/parts/%s/occurrences/%s" % [part_id, occ_id], body))["ok"])


func tree_of(part_id: String, with_status := true) -> Dictionary:
	var answer: Dictionary = await live(HTTPClient.METHOD_GET, "/parts/%s/assembly-tree%s" % [part_id, "?status=true" if with_status else ""])
	return answer["json"] if answer["ok"] and answer["json"] is Dictionary else {}


func child_of(node: Dictionary, occurrence_id: String) -> Dictionary:
	for c in node.get("children", []):
		if str(c["occurrence_id"]) == occurrence_id:
			return c
	return {}


# --- the app ----------------------------------------------------------------------------------------------------------------------------------------

func fresh() -> void:
	## Before a scenario replaces the backend's document: the window is closed and its pending live refresh has run, so nothing asks for the old root.
	if window.is_open():
		window.close()
	older_backend = false
	hold_status = false
	patch_sets = []
	await create_timer(0.8).timeout
	await frames(2)


func show_in_app(root_id: String, with_world: bool) -> void:
	## Makes the fixture the loaded document: the world's mesh (when wanted) and a fresh, closed window.
	if window.is_open():
		window.close()
	window.request_hook = Callable(self, "stand_in")
	main._resolved_part_id = root_id
	main.document_dirty = false
	if with_world:
		main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * main.spawn_scale), Vector3(0.05, 0.9, 0.0)) # (a reload keeps the world's pose: this is where it stands, mm scaled to metres)
		await main.reload_world_model(false)
		main.document_dirty = false
	window.mark_stale()
	await frames(2)


func open_window_and_wait(status := true) -> void:
	window.open()
	await wait_for(func() -> bool: return not window._stale and not window._resp.is_empty() and (not status or bool(window._resp.get("status_included", false))))
	await frames(3)


func open_rows(paths: Array) -> void:
	for p in paths:
		var row: Dictionary = Model.find_row(window._tree, p)
		if not row.is_empty():
			row["expanded"] = true
	window._rebuild_rows()
	await frames(3)


func lines() -> Array:
	## What the window draws, row by row: {text, depth, colour, bubble, bubble_colour, icon, selected, dimmed}.
	var out: Array = []
	for line in window._rows_box.get_children():
		if not (line is HBoxContainer) or line.get_child_count() < 3 or not (line.get_child(2) is Button):
			if line is Label:
				out.append({"text": (line as Label).text, "depth": 0, "colour": Color.WHITE, "bubble": "", "bubble_colour": Color.WHITE, "icon": false, "selected": false, "dimmed": false})
			continue
		var b: Button = line.get_child(2)
		var bubble := ""
		var bubble_colour := Color.WHITE
		for i in range(3, line.get_child_count()):
			if line.get_child(i) is Label:
				bubble = (line.get_child(i) as Label).text
				bubble_colour = (line.get_child(i) as Label).get_theme_color("font_color")
		out.append({"text": b.text, "depth": int(round((line.get_child(0) as Control).custom_minimum_size.x / 24.0)), "colour": b.get_theme_color("font_color"),
			"bubble": bubble, "bubble_colour": bubble_colour, "icon": b.icon != null, "selected": b.button_pressed, "dimmed": b.modulate.a < 0.9})
	return out


func line_with(text: String) -> Dictionary:
	for l in lines():
		if str(l["text"]).begins_with(text) or str(l["text"]).contains(text):
			return l
	return {}


func texts() -> Array:
	return lines().map(func(l): return str(l["text"]))


func dump(name: String) -> void:
	if out_dir == "":
		return
	var rows := PackedStringArray()
	for l in lines():
		var colour: Color = l["colour"]
		rows.append("%s%s%s%s  [text %s]" % ["  ".repeat(int(l["depth"])), "> " if l["selected"] else "", l["text"], ("   (" + str(l["bubble"]) + ")") if l["bubble"] != "" else "", colour.to_html(false)])
	var f := FileAccess.open(out_dir.path_join(name + ".txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(rows) + "\nstatus line: %s\n" % window._status_label.text)


func shot(name: String, wide := false) -> void:
	## The window's own panel texture (and, wide = true, the 3D view from eye height with the model). Saves nothing without TREE_RENDER_DIR or a renderer.
	await frames(4)
	dump(name)
	if not rendering or out_dir == "":
		return
	var img: Image = window._viewport.get_texture().get_image()
	if img != null and not img.is_empty():
		img.save_png(out_dir.path_join(name + ".png"))
	if wide:
		eye.global_position = Vector3(0.25, 1.4, 1.2) # (the panel stays where it opened, in front of the XR camera; this eye looks at the panel and the model together)
		eye.look_at(Vector3(-0.1, 1.15, 0.1))
		await frames(3)
		var full: Image = root.get_texture().get_image()
		if full != null and not full.is_empty():
			full.save_png(out_dir.path_join(name + "_wide.png"))


func window_has_pixels() -> bool:
	## Not blank: the panel texture has several distinct colours (it can't be judged more than that here).
	if not rendering:
		return true
	var img: Image = window._viewport.get_texture().get_image()
	if img == null or img.is_empty():
		return false
	var seen := {}
	for y in range(0, img.get_height(), 6):
		for x in range(0, img.get_width(), 6):
			seen[img.get_pixel(x, y).to_html(false)] = true
	return seen.size() > 6


func is_danger(c: Color) -> bool:
	return c.is_equal_approx(window.tokens.danger)


func is_warn(c: Color) -> bool:
	return c.is_equal_approx(window.tokens.warn)


# --- scenarios --------------------------------------------------------------------------------------------------------------------------------------

func fixture_two_level() -> String:
	## Top "Pin Assembly": the Plate (fixed), a "Carrier" sub-assembly placed twice, a loose Peg. The Carrier holds a fixed Plate and a Peg held parallel to it.
	var carrier := blank_part("carrier-part", "Carrier", [occ("c_plate", PLATE_ID, "parts/plate.didsa", Vector3.ZERO, {"fixed": true}), occ("c_peg", PEG_ID, "parts/peg.didsa", Vector3(10, 0, 0))])
	var top := blank_part("top-part", "Pin Assembly", [occ("base", PLATE_ID, "parts/plate.didsa", Vector3.ZERO, {"fixed": true}), occ("carrier1", "carrier-part", "parts/carrier.didsa", Vector3(0, 0, 80)),
		occ("carrier2", "carrier-part", "parts/carrier.didsa", Vector3(0, 0, 160)), occ("loose", PEG_ID, "parts/peg.didsa", Vector3(60, 0, 0))])
	if not await import_doc("top-part", [top, carrier]):
		return ""
	await add_mate("carrier-part", "parallel", "c_plate", plate_body, 3, "c_peg", peg_body, 0)
	return "top-part"


func where() -> void:
	var box := AABB()
	var first := true
	for n in get_nodes_in_group("grabbable_parts"):
		if n is MeshInstance3D:
			var b: AABB = (n as MeshInstance3D).global_transform * (n as MeshInstance3D).get_aabb()
			box = b if first else box.merge(b)
			first = false
	for n in get_nodes_in_group("grabbable_parts"):
		print("NOTE part ", n.get_meta("occurrence_id", "?"), " at ", n.global_position, " scale ", n.global_transform.basis.get_scale())
	print("NOTE assembly_root: ", main.assembly_root.global_transform, " ", main.assembly_root.get_child_count(), " children")
	print("NOTE world parts AABB: ", box, " window at ", window.global_position, " eye ", eye.global_position)


func scenario_a() -> void:
	await fresh()
	print("== a: two-level assembly, structure then status")
	var root_id := await fixture_two_level()
	check("a: the fixture is on the backend", root_id != "")
	hold_status = true
	await show_in_app(root_id, true)
	window.open()
	await wait_for(func() -> bool: return not window._stale and not window._resp.is_empty())
	await open_rows([["carrier1"], ["carrier2"]])
	check("a: the structure alone is drawn while status is held back (no status in the answer)", not bool(window._resp.get("status_included", true)))
	var names := texts()
	check("a: rows read Pin Assembly, Plate, Carrier <1> and <2> (with Plate and Peg below each), Peg", names.size() >= 9 and names[0].begins_with("Pin Assembly") and names.any(func(t): return str(t).contains("Carrier <1>")) and names.any(func(t): return str(t).contains("Carrier <2>")))
	check("a: no state icon yet except the fixed pin the flag itself gives", not (line_with("Peg")["icon"] as bool) and (line_with("Plate")["icon"] as bool))
	where()
	check("a: the panel is drawn", window_has_pixels())
	await shot("a1_structure_only", true)
	hold_status = false
	await wait_for(func() -> bool: return bool(window._resp.get("status_included", false)))
	await open_rows([["carrier1"], ["carrier2"]])
	var nested: Dictionary = Model.find_row(window._tree, ["carrier1", "c_peg"])
	check("a: after status merged in, the nested Peg reads under-constrained (open lock) and the open rows were kept", not nested.is_empty() and nested["state"] == "under_constrained" and Model.find_row(window._tree, ["carrier2"])["expanded"])
	check("a: the status line has no error text", window._status_label.text == "")
	await shot("a2_status_merged", true)


func fixture_problems() -> String:
	## "Arm" -> a Plate (fixed) and "Linkage" (a sub-assembly): inside, a Plate (fixed), a Peg and a suppressed second Peg held parallel to it, then turned (the mate no
	## longer holds: the Peg reads over-constrained and no mate of its own is broken), a healthy Pin B, and a placement of a file that cannot be found.
	var linkage := blank_part("linkage-part", "Linkage", [occ("l_plate", PLATE_ID, "parts/plate.didsa", Vector3.ZERO, {"fixed": true}), occ("peg", PEG_ID, "parts/peg.didsa", Vector3(10, 0, 0), {"name": "Peg A"}),
		occ("spare", PEG_ID, "parts/peg.didsa", Vector3(40, 0, 0), {"suppressed": true, "name": "Spare peg"}), occ("pin_b", PEG_ID, "parts/peg.didsa", Vector3(70, 0, 0), {"name": "Pin B"}), occ("lost", null, "parts/lost_bracket.didsa")])
	var arm := blank_part("arm-part", "Arm", [occ("arm_plate", PLATE_ID, "parts/plate.didsa", Vector3.ZERO, {"fixed": true}), occ("linkage", "linkage-part", "parts/linkage.didsa", Vector3(0, 0, 80))])
	if not await import_doc("arm-part", [arm, linkage]):
		return ""
	await add_mate("linkage-part", "parallel", "peg", peg_body, 0, "spare", peg_body, 0)
	await add_mate("linkage-part", "parallel", "l_plate", plate_body, 3, "pin_b", peg_body, 0)
	await move("linkage-part", "spare", Vector3(40, 0, 0), Vector3(1, 0, 0), 30.0)
	return "arm-part"


func scenario_b() -> void:
	await fresh()
	print("== b: a collapsed parent with a missing file and an over-constrained part below it")
	var root_id := await fixture_problems()
	check("b: the fixture is on the backend", root_id != "")
	var live_tree := await tree_of(root_id)
	var linkage := child_of(live_tree, "linkage")
	check("b: the backend counts 1 missing and 1 over-constrained below the Linkage, none broken (%s)" % str(linkage.get("problems", {})), (linkage.get("problems", {}) as Dictionary).get("missing", -1) == 1 and (linkage["problems"] as Dictionary).get("over_constrained", -1) == 1 and (linkage["problems"] as Dictionary).get("broken", -1) == 0)
	await show_in_app(root_id, true)
	await open_window_and_wait()
	var closed := line_with("Linkage")
	check("b: the collapsed Linkage wears a red bubble of 2 (missing + over-constrained)", str(closed.get("bubble", "")) == "2" and is_danger(closed.get("bubble_colour", Color.WHITE)))
	check("b: the Plate row has no bubble", str(line_with("Plate").get("bubble", "x")) == "")
	await shot("b1_collapsed_bubble", true)
	await open_rows([["linkage"]])
	var peg := line_with("Peg A")
	var lost := line_with("lost_bracket")
	check("b: open, the Linkage's own bubble goes (its level has no broken or near mates)", str(line_with("Linkage").get("bubble", "x")) == "")
	check("b: the over-constrained Peg is red and the missing file's row is red", not peg.is_empty() and is_danger(peg["colour"]) and not lost.is_empty() and is_danger(lost["colour"]))
	await shot("b2_open", true)


func scenario_c() -> void:
	await fresh()
	print("== c: one Part placed four times: Fold x4 on (closed, open) and off")
	var rack := blank_part("rack-part", "Peg Rack", [occ("base", PLATE_ID, "parts/plate.didsa", Vector3.ZERO, {"fixed": true}), occ("p1", PEG_ID, "parts/peg.didsa", Vector3(0, 0, 60)),
		occ("p2", PEG_ID, "parts/peg.didsa", Vector3(40, 0, 60)), occ("p3", PEG_ID, "parts/peg.didsa", Vector3(80, 0, 60)), occ("p4", PEG_ID, "parts/peg.didsa", Vector3(120, 0, 60)),
		occ("w1", null, "parts/washer.didsa"), occ("w2", null, "parts/washer.didsa"), occ("named", PEG_ID, "parts/peg.didsa", Vector3(160, 0, 60), {"name": "Pin (renamed)"})])
	check("c: the fixture is on the backend", await import_doc("rack-part", [rack]))
	await show_in_app("rack-part", true)
	main.set_tree_grouping(true)
	await open_window_and_wait()
	check("c: the switch is on by default and the button is shown", main.tree_grouping() and window._fold_button.visible and window._fold_button.button_pressed)
	var folded := texts()
	check("c: four Pegs fold into one 'Peg x4' row; the renamed one and the two missing washers (2 only) stay out of it", folded.any(func(t): return str(t).begins_with("Peg x4")) and not folded.any(func(t): return str(t).begins_with("Peg <")) and folded.any(func(t): return str(t).contains("Pin (renamed)")) and folded.any(func(t): return str(t).contains("washer <1>")))
	await shot("c1_fold_on_closed", true)
	window._open_groups["#group:p1"] = true
	window._rebuild_rows()
	await frames(3)
	var open_texts := texts()
	check("c: opened, the group lists Peg <1> .. Peg <4> one level deeper", ["Peg <1>", "Peg <2>", "Peg <3>", "Peg <4>"].all(func(n): return open_texts.any(func(t): return str(t).contains(n))))
	await shot("c2_fold_on_open", true)
	window._set_grouping(false)
	await frames(3)
	var unfolded := texts()
	check("c: with Fold off there is no group row and the same names are listed one per row", not unfolded.any(func(t): return str(t).contains(" x4")) and ["Peg <1>", "Peg <2>", "Peg <3>", "Peg <4>"].all(func(n): return unfolded.any(func(t): return str(t).contains(n))) and not window._fold_button.button_pressed)
	await shot("c3_fold_off", true)
	window._set_grouping(true)


func scenario_d() -> void:
	await fresh()
	print("== d: a part fixed from the tree: Fix, the refresh, Float")
	var top := blank_part("fix-part", "Fix Test", [occ("base", PLATE_ID, "parts/plate.didsa", Vector3.ZERO, {"fixed": true}), occ("peg1", PEG_ID, "parts/peg.didsa", Vector3(30, 0, 60)), occ("peg2", PEG_ID, "parts/peg.didsa", Vector3(90, 0, 60))])
	check("d: the fixture is on the backend", await import_doc("fix-part", [top]))
	await show_in_app("fix-part", true)
	await open_window_and_wait()
	var row: Dictionary = Model.find_row(window._tree, ["peg1"])
	window._on_row_selected(row)
	await frames(3)
	check("d: before: Peg <1> is selected and floating (open lock), not pinned", not row.is_empty() and row["state"] == "under_constrained" and Model.state_icon(row) == "lock_open")
	await shot("d0_before", true)
	window._resp["_marker"] = true
	await window._on_bar_action("fix", row, {})
	var now_row: Dictionary = Model.find_row(window._tree, ["peg1"])
	check("d: straight after Fix the row is a pin (the refresh it asks for %s)" % ("had not come back yet" if window._resp.has("_marker") else "had already come back: the live signal beat this line"), now_row["state"] == "fixed" and Model.state_icon(now_row) == "pin")
	await shot("d1_fix_straight_after", true)
	await wait_for(func() -> bool: return not window._resp.has("_marker") and bool(window._resp.get("status_included", false)), 20000)
	await frames(2)
	var refreshed: Dictionary = Model.find_row(window._tree, ["peg1"])
	var server_fixed: bool = bool((child_of(await tree_of("fix-part", false), "peg1")).get("fixed", false))
	check("d: after the refresh it is still a pin (the backend agrees), and the selection stayed", refreshed["state"] == "fixed" and server_fixed and window._has_selected and window._selected == ["peg1"])
	await shot("d2_fix_refreshed", true)
	window._resp["_marker"] = true
	await window._on_bar_action("fix", refreshed, {})
	var floated: Dictionary = Model.find_row(window._tree, ["peg1"])
	await shot("d3_float_straight_after", true)
	check("d: straight after Float (hints are fitted a frame after the rows are built) the row shows the 'updating' state (not a pin, not blank)", str(line_with("Peg <1>").get("text", "")).contains("updating") and not str(line_with("Peg <1>").get("text", "")).contains("fixed"))
	await wait_for(func() -> bool: return not window._resp.has("_marker") and bool(window._resp.get("status_included", false)), 20000)
	await frames(2)
	var after: Dictionary = Model.find_row(window._tree, ["peg1"])
	var server_after := bool((child_of(await tree_of("fix-part", false), "peg1")).get("fixed", true))
	print("NOTE d after Float: state=%s fixed_flag=%s server_fixed=%s" % [after["state"], str(after.get("fixed")), str(server_after)])
	check("d: after the refresh it is open-lock again (under-constrained) and the backend agrees", after["state"] == "under_constrained" and not server_after)
	await shot("d4_float_refreshed", true)


func world_node(path: Array) -> Node3D:
	for n in get_nodes_in_group("grabbable_parts"):
		var p: Array = n.get_meta("group_path", [])
		if p.is_empty():
			p = [str(n.get_meta("occurrence_id", ""))]
		if p == path:
			return n
	return null


func scenario_e() -> void:
	await fresh()
	print("== e: a part selected in the world: the tree opens down to it through a folded group")
	var rack := blank_part("rack-sub", "Peg Row", [occ("rp1", PEG_ID, "parts/peg.didsa", Vector3(0, 0, 0)), occ("rp2", PEG_ID, "parts/peg.didsa", Vector3(40, 0, 0)), occ("rp3", PEG_ID, "parts/peg.didsa", Vector3(80, 0, 0)), occ("rp4", PEG_ID, "parts/peg.didsa", Vector3(120, 0, 0))])
	var top := blank_part("reveal-part", "Reveal Test", [occ("base", PLATE_ID, "parts/plate.didsa", Vector3.ZERO, {"fixed": true}), occ("row1", "rack-sub", "parts/peg_row.didsa", Vector3(0, 0, 60)), occ("extra", PEG_ID, "parts/peg.didsa", Vector3(0, 60, 60))])
	check("e: the fixture is on the backend", await import_doc("reveal-part", [top, rack]))
	await show_in_app("reveal-part", true)
	main.set_tree_grouping(true)
	await open_window_and_wait()
	check("e: first nothing is open: Reveal Test, Plate, Peg Row, Peg", texts().size() == 4)
	await shot("e0_closed", true)
	await wait_for(func() -> bool: return world_node(["row1", "rp3"]) != null, 15000) # (the world's nodes get their paths from the room manager's index, a moment after the load)
	var node: Node3D = world_node(["row1", "rp3"])
	check("e: the third Peg of the row is in the world under its path", node != null)
	if node == null:
		return
	window._on_world_selection(node, {"depth": 2, "prefix": ["row1", "rp3"], "label": "Peg"})
	await wait_for(func() -> bool: return line_with("Peg <3>").get("selected", false), 8000)
	await frames(3)
	var t := texts()
	check("e: the Peg Row is open, its folded group 'Peg x4' is open, and Peg <3> is the selected row (%s)" % " | ".join(t), t.any(func(x): return str(x).begins_with("Peg Row")) and t.any(func(x): return str(x).begins_with("Peg x4")) and bool(line_with("Peg <3>").get("selected", false)) and bool(window._open_groups.get("row1/#group:rp1", false)))
	check("e: Peg <3> sits one level below the group (depth 3)", int(line_with("Peg <3>").get("depth", -1)) == 3)
	await shot("e1_revealed", true)


func scenario_f() -> void:
	await fresh()
	print("== f: a rigid-set part that is over-constrained: the red tint over the set colour (set ids synthetic)")
	var root_id := await fixture_problems()
	check("f: the fixture is on the backend", root_id != "")
	patch_sets = ["peg", "pin_b"]
	await show_in_app(root_id, false)
	await open_window_and_wait()
	await open_rows([["linkage"]])
	var peg := line_with("Peg A")
	var pin_b := line_with("Pin B")
	var rows_peg: Dictionary = Model.find_row(window._tree, ["linkage", "peg"])
	var rows_pin: Dictionary = Model.find_row(window._tree, ["linkage", "pin_b"])
	check("f: the over-constrained Peg and Pin B are in one rigid set (set slots %s / %s)" % [str(rows_peg.get("set_slot")), str(rows_pin.get("set_slot"))], int(rows_peg.get("set_slot", -1)) >= 0 and int(rows_peg.get("set_slot", -2)) == int(rows_pin.get("set_slot", -3)))
	check("f: the Peg's text is the danger red, not the set colour", rows_peg["state"] == "over_constrained" and is_danger(peg["colour"]))
	check("f: Pin B (the healthy member) carries the set colour, which is not red", not is_danger(pin_b["colour"]) and not is_warn(pin_b["colour"]) and pin_b["colour"] != Color.WHITE)
	await shot("f_rigid_set_over_constrained", false)
	patch_sets = []


func scenario_g() -> void:
	await fresh()
	print("== g: an older backend (the framework's 404 for the call): per-level rows, no Fold button")
	var root_id := await fixture_two_level()
	check("g: the fixture is on the backend", root_id != "")
	older_backend = true
	await show_in_app(root_id, true)
	await open_window_and_wait(false)
	check("g: the window remembers the route is missing and falls back to one level at a time", window._endpoint_missing and window._resp.is_empty())
	check("g: there is no Fold x4 button", window._fold_button != null and not window._fold_button.visible)
	var names := texts()
	check("g: the top level lists Plate, Carrier <1>, Carrier <2>, Peg by name (%s)" % " | ".join(names), names.size() >= 5 and names.any(func(t): return str(t).contains("Carrier <1>")) and names.any(func(t): return str(t).contains("Carrier <2>")))
	await open_rows([])
	var carrier_row: Dictionary = Model.find_row(window._tree, ["carrier1"])
	if not carrier_row.is_empty():
		await window._expand_row(carrier_row)
		await wait_for(func() -> bool: return carrier_row["children"] != null)
	await frames(4)
	check("g: opening a Carrier reads its own level (its Plate and Peg appear below it)", carrier_row["children"] != null and (carrier_row["children"] as Array).size() == 2)
	await shot("g_older_backend", true)
	older_backend = false


func scenario_h() -> void:
	await fresh()
	print("== h: a generated tree of 2,000 occurrences")
	var items: Array = []
	var module_occs: Array = []
	for i in 49:
		var id := "item-%02d" % (i + 1)
		items.append(blank_part(id, "Item %02d" % (i + 1)))
		module_occs.append(occ("i%02d" % (i + 1), id, "parts/item_%02d.didsa" % (i + 1)))
	var module := blank_part("module-part", "Module", module_occs)
	var top_occs: Array = []
	for m in 40:
		top_occs.append(occ("m%02d" % (m + 1), "module-part", "parts/module.didsa"))
	var top := blank_part("big-part", "Big Assembly", top_occs)
	var t0 := Time.get_ticks_msec()
	check("h: the fixture is on the backend (49 parts, a Module of 49 placed 40 times)", await import_doc("big-part", [top, module] + items))
	print("SMOKE TIMING h: building and importing the fixture through the API took %d ms" % (Time.get_ticks_msec() - t0))
	await show_in_app("big-part", false)
	var t1 := Time.get_ticks_msec()
	window.open()
	await wait_for(func() -> bool: return not window._stale and not window._resp.is_empty())
	var structure_ms := Time.get_ticks_msec() - t1
	await wait_for(func() -> bool: return bool(window._resp.get("status_included", false)))
	var status_ms := Time.get_ticks_msec() - t1
	await frames(3)
	print("SMOKE TIMING h: open to the structure drawn (request, parse, 41 rows) %d ms; to the status merged and redrawn %d ms (%d nodes, truncated: %s)" % [structure_ms, status_ms, int(window._resp.get("node_count", 0)), str(window._resp.get("truncated_nodes", false))])
	check("h: the call answered all 2,000 occurrences (40 Modules and 1,960 Items), not cut off", int(window._resp.get("node_count", 0)) == 2000 and not bool(window._resp.get("truncated_nodes", true)))
	check("h: the 40 identical Modules fold into one 'Module x40' row: the window lists the root and that row", window._rows_box.get_child_count() == 2 and texts()[1].begins_with("Module x40"))
	await shot("h1_folded", false)
	window._open_groups["#group:m01"] = true
	for m in 40:
		(Model.find_row(window._tree, ["m%02d" % (m + 1)]))["expanded"] = false
	var t5 := Time.get_ticks_usec()
	window._rebuild_rows()
	print("SMOKE TIMING h: _rebuild_rows with the group open, every Module closed: %d rows in %.1f ms" % [window._rows_box.get_child_count(), (Time.get_ticks_usec() - t5) / 1000.0])
	check("h: the group open lists the root, the group and its 40 Modules", window._rows_box.get_child_count() == 42)
	for m in 40:
		(Model.find_row(window._tree, ["m%02d" % (m + 1)]))["expanded"] = true
	var t2 := Time.get_ticks_usec()
	window._rebuild_rows()
	var build_us := Time.get_ticks_usec() - t2
	var count: int = window._rows_box.get_child_count()
	print("SMOKE TIMING h: _rebuild_rows with every Module open: %d rows in %.1f ms (%.3f ms a row), in the frame it ran" % [count, build_us / 1000.0, build_us / 1000.0 / maxf(1.0, count)])
	var t3 := Time.get_ticks_usec()
	var spec_rows: Array = Model.visible_rows(window._resp, window._spec_open_keys(), window._grouping(), [])
	print("SMOKE TIMING h: Model.visible_rows alone (no controls): %d rows in %.1f ms" % [spec_rows.size(), (Time.get_ticks_usec() - t3) / 1000.0])
	check("h: every Module open lists 2,002 rows (root, the group, 40 Modules, 1,960 Items)", count == 2002)
	var t4 := Time.get_ticks_msec()
	await frames(2)
	print("SMOKE TIMING h: the two frames after that rebuild took %d ms (layout of %d rows)" % [Time.get_ticks_msec() - t4, count])
	await shot("h2_all_open_top", false)
	var bar: ScrollBar = window.scroll_target.get_v_scroll_bar()
	window.scroll_target.scroll_vertical = int(bar.max_value * 0.5)
	await frames(4)
	check("h: the window scrolls: the list is taller than the window and scrolled into the middle (%d of %d)" % [window.scroll_target.scroll_vertical, int(bar.max_value)], bar.max_value > 50000 and window.scroll_target.scroll_vertical > 10000)
	await shot("h3_scrolled_middle", true)
	window.scroll_target.scroll_vertical = int(bar.max_value)
	await frames(4)
	await shot("h4_scrolled_end", false)


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend)")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	url = str(secrets.get_value("backend", "url", ""))
	key = str(secrets.get_value("backend", "api_key", ""))
	rendering = DisplayServer.get_name() != "headless"
	out_dir = OS.get_environment("TREE_RENDER_DIR")
	if out_dir != "":
		DirAccess.make_dir_recursive_absolute(out_dir)
	if rendering:
		DisplayServer.window_set_size(Vector2i(1280, 720))
	await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg" # (the real secrets.cfg is never read by the app: the backend is set by hand below)
	root.add_child(main)
	await process_frame
	main.backend_url = url
	main.api_key = key
	main._apply_backend()
	window = main._assembly_tree_window
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	eye = Camera3D.new()
	eye.fov = 75.0
	main.add_child(eye)
	eye.make_current()
	eye.global_position = Vector3(0.0, 1.5, 0.9)
	eye.look_at(Vector3(0.0, 1.0, -0.3))
	origin.get_node("XRCamera3D").global_position = eye.global_position
	origin.get_node("XRCamera3D").global_rotation = eye.global_rotation
	await frames(3)
	if not load_source():
		check("the fixture source loads", false)
		quit(1)
		return
	var wanted := OS.get_environment("TREE_SCENARIOS")
	var picks: PackedStringArray = wanted.split(",", false) if wanted != "" else PackedStringArray(["a", "b", "c", "d", "e", "f", "g", "h"])
	for s in picks:
		window.request_hook = Callable(self, "stand_in")
		match s:
			"a": await scenario_a()
			"b": await scenario_b()
			"c": await scenario_c()
			"d": await scenario_d()
			"e": await scenario_e()
			"f": await scenario_f()
			"g": await scenario_g()
			"h": await scenario_h()
	if rendering:
		check("the panel was drawn with pixels in the last scenario", window_has_pixels())
	check("no request to the backend failed outside the 404 stand-in", failed_requests == 0)
	quit(0)
