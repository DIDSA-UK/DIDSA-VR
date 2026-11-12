extends SceneTree
## The Appearance tool (scripts/appearance_tool.gd, DIDSA-CAD docs/appearance-tool-scope.md V2) against an in-memory backend
## (tests/fake_appearance_api.gd), no scene, no network: the breadcrumb's rows for a part in a sub-assembly, a pattern copy and
## the assembly's own body; a click's Body paint (one PUT, the mesh split into one surface per look with the face ids and the
## collider kept in step); undo; painting onto a level that already has paint (merged); Clear; the live preview and its end;
## the sandbox's temporary paint (nothing sent, gone on Return parts); the eyedropper; a refused paint; and group_index.gd
## placing pattern copies by their instance_path.
## Run: "$GODOT" --headless --path . --script res://tests/appearance_tool.gd

const Tool := preload("res://scripts/appearance_tool.gd")
const Look := preload("res://scripts/appearance/appearance_look.gd")
const Rule := preload("res://scripts/appearance/appearance_rule.gd")
const FakeApi := preload("res://tests/fake_appearance_api.gd")
const CommandStack := preload("res://scripts/command_stack.gd")
const GroupIndex := preload("res://scripts/group_index.gd")

var failures := 0


class FakeMates extends Node:
	signal sandbox_changed(on: bool)
	var relaxed := false


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _node(holder: Node, label: String, owner: String, occ: String, instance_path: String, names: Array, two_bodies: bool) -> MeshInstance3D:
	## A box whose 12 triangles are 6 faces (two triangles each) of one body, or of two (faces 0-2 body 1, faces 3-5 body 2).
	var n := MeshInstance3D.new()
	n.name = label
	n.mesh = BoxMesh.new()
	var faces: Array = []
	var bodies: Array = []
	var tri_count: int = n.mesh.get_faces().size() / 3
	for t in tri_count:
		var f := t / 2
		faces.append(f % 3 if two_bodies else f)
		bodies.append(("%s1" % label.to_lower().left(1)) if not two_bodies or f < 3 else ("%s2" % label.to_lower().left(1)))
	n.set_meta("face_ids", faces)
	n.set_meta("body_ids", bodies)
	n.set_meta("owner_part_id", owner)
	n.set_meta("occurrence_id", occ)
	n.set_meta("instance_path", instance_path)
	n.set_meta("group_root", "R")
	n.set_meta("group_names", names)
	n.add_to_group("grabbable_parts")
	holder.add_child(n)
	n.create_trimesh_collision()
	return n


func _albedo(n: MeshInstance3D) -> Variant:
	var m := n.material_override as StandardMaterial3D
	return m.albedo_color if m != null else null


func _ids(rows: Array) -> Array:
	return rows.map(func(r: Dictionary) -> String: return str(r["id"]))


func _consistent(n: MeshInstance3D) -> bool:
	## The face identity metas still line up with the mesh's triangles (get_faces() order) and a collider is there.
	var tri := n.mesh.get_faces().size() / 3
	var has_collider := n.get_children().any(func(c) -> bool: return c is StaticBody3D)
	return (n.get_meta("face_ids") as Array).size() == tri and (n.get_meta("body_ids") as Array).size() == tri and has_collider


func _initialize() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	await process_frame

	var api := FakeApi.new()
	api.parts = {
		"R": {"name": "Rig", "occurrences": [FakeApi.row("frame", "F"), FakeApi.row("bolt", "B"), FakeApi.row("leg1", "L"), FakeApi.row("leg2", "L")],
			"patterns": [{"id": "p1", "source_occurrence_ids": ["bolt"], "suppressed": false}]},
		"F": {"name": "Frame", "occurrences": [FakeApi.row("barA", "A"), FakeApi.row("barB", "A")]},
		"A": {"name": "Bar", "appearance": {"roughness": 0.6}},
		"B": {"name": "Bolt"},
		"L": {"name": "Leg"},
	}
	var mates := FakeMates.new()
	holder.add_child(mates)
	var stack := CommandStack.new()
	var tool := Tool.new()
	tool.mates_tool = mates
	tool.command_stack = stack
	holder.add_child(tool)
	tool.configure(api)
	tool.world_root = "R"

	var own := _node(holder, "Rig", "R", "", "", [], false)
	var bar_a := _node(holder, "BarA", "F", "barA", "frame/barA", ["Frame", "Bar A"], true)
	var bar_b := _node(holder, "BarB", "F", "barB", "frame/barB", ["Frame", "Bar B"], true)
	var bolt := _node(holder, "Bolt", "R", "bolt", "bolt", ["Bolt"], false)
	var bolt_copy := _node(holder, "Copy", "R", "", "bolt#pattern:p1:2", ["Bolt (copy 2)"], false)
	var bolt_copy_1 := _node(holder, "Copy1", "R", "", "bolt#pattern:p1:1", ["Bolt (copy 1)"], false)
	var leg1 := _node(holder, "Leg1", "R", "leg1", "leg1", ["Leg"], false)
	var leg2 := _node(holder, "Leg2", "R", "leg2", "leg2", ["Leg"], false)
	var scope: Array = [own, bar_a, bar_b, bolt, bolt_copy, bolt_copy_1, leg1, leg2]
	await tool.ensure_loaded("R")
	_check((tool.model()["parts"] as Dictionary).size() == 5 and tool.part_name("A") == "Bar", "the model holds every Part under the root, read from the backend")

	# --- the breadcrumb's rows
	var rows_a: Array = tool.rows_for(bar_a, 0, scope, "R")
	_check(_ids(rows_a) == ["face", "body", "part", "same_part", "sub_1", "whole"], "a bar in the frame: Face, Body, Part, Every Bar (2), the frame, Whole assembly (%s)" % str(_ids(rows_a)))
	_check(rows_a[3]["label"] == "Every Bar (2)" and (rows_a[3]["members"] as Array).size() == 2 and rows_a[4]["record"] == {"path": "frame"}, "...every placement counts both bars; the sub-assembly row names the frame")
	_check(rows_a[0]["record"] == {"path": "frame/barA", "body_id": "b1", "face": {"body_id": "b1", "shape_type": "face", "index": 0}} and rows_a[1]["record"] == {"path": "frame/barA", "body_id": "b1"}, "...Face and Body name the triangle's face and body on that placement")
	var rows_copy: Array = tool.rows_for(bolt_copy, 0, scope, "R")
	_check(_ids(rows_copy) == ["face", "body", "part", "pattern_p1", "same_part", "whole"], "a pattern copy: Face, Body, Part, Pattern (all N), Every Bolt, Whole (%s)" % str(_ids(rows_copy)))
	_check(rows_copy[3]["label"] == "Pattern (all 3)" and rows_copy[3]["record"] == {"path": "bolt", "scope": "pattern", "pattern_id": "p1"}, "...the pattern row covers the source and its two copies, stored on the source with scope pattern")
	_check(rows_copy[2]["record"] == {"path": "bolt#pattern:p1:2"}, "...its Part row names the one copy (#pattern: path)")
	_check(_ids(tool.rows_for(bolt, 0, scope, "R")).has("pattern_p1"), "the pattern's source gets the Pattern row too")
	_check(_ids(tool.rows_for(own, 0, scope, "R")) == ["face", "body", "whole"], "the assembly's own body: Face, Body, Whole (painting it as a part is the assembly)")
	_check(not _ids(tool.rows_for(leg1, 0, scope, "R")).has("pattern_p1") and _ids(tool.rows_for(leg1, 0, scope, "R")).has("same_part"), "a part placed twice gets Every <part> but no Pattern row")

	# --- a click paints the body (one PUT, on release); only that body of the bar changes
	tool.brush = {"colour": "#E63946"}
	var body_row: Dictionary = rows_a[1]
	var result: Dictionary = await tool.apply(body_row, "R", scope, "R")
	var put: Dictionary = api.puts().back()
	_check(result["ok"] and api.puts().size() == 1 and put["path"] == "/document/parts/R/appearance-overrides" and put["body"] == {"path": "frame/barA", "body_id": "b1", "appearance": {"colour": "#E63946"}}, "a Body paint is one PUT to the root's overrides naming the placement and body")
	_check(bar_a.mesh.get_surface_count() == 2 and bar_a.material_override == null and _consistent(bar_a), "...the bar's mesh is split into one surface per look, face ids and collider kept in step")
	var painted_surface := -1
	for s in bar_a.mesh.get_surface_count():
		var m := bar_a.mesh.surface_get_material(s) as StandardMaterial3D
		if m != null and m.albedo_color.is_equal_approx(Color.html("#E63946")):
			painted_surface = s
	_check(painted_surface >= 0 and is_equal_approx((bar_a.mesh.surface_get_material(1 - painted_surface) as StandardMaterial3D).roughness, 0.6), "...the painted body wears the colour, the other keeps the part's own look (roughness 0.6)")
	var keys := Look.triangle_keys(bar_a)
	var first_painted := 0 if painted_surface == 0 else 6
	_check(keys[first_painted].begins_with("b1:") and keys[6 - first_painted].begins_with("b2:"), "...and the face ids follow the new triangle order (painted body's triangles in its surface)")
	_check(bar_b.mesh.get_surface_count() == 1 and _albedo(bar_b) == Color.html("#C8C8C8") and is_equal_approx((bar_b.material_override as StandardMaterial3D).roughness, 0.6), "the other bar keeps its look (the part's own roughness, default colour)")
	_check(stack.can_undo() and stack.undo_label() == "paint Body", "a paint is one undo step")

	# --- undo PUTs back what was there (nothing: a clear), and the bar shows one look again
	stack.undo()
	await _wait_puts(api, 2)
	_check(api.puts().back()["body"] == {"path": "frame/barA", "body_id": "b1", "appearance": null}, "undo clears the body's paint on the backend")
	var undone := bar_a.material_override as StandardMaterial3D
	_check(undone != null and is_equal_approx(undone.roughness, 0.6) and undone.albedo_color.is_equal_approx(Color.html("#C8C8C8")) and _consistent(bar_a), "...and the whole bar wears one look again (the part's own)")
	stack.redo()
	await _wait_puts(api, 3)
	_check(api.puts().back()["body"]["appearance"] == {"colour": "#E63946"}, "redo paints it again")

	# --- painting a level that has paint merges the brush into it; Clear removes it (and the legacy colour the backend mirrored)
	tool.brush = {"colour": "#3498DB"}
	var part_row: Dictionary = tool.rows_for(leg1, 0, scope, "R").filter(func(r) -> bool: return r["id"] == "part")[0]
	await tool.apply(part_row, "R", scope, "R")
	tool.brush = {"opacity": 0.5}
	await tool.apply(part_row, "R", scope, "R")
	_check(api.puts().back()["body"] == {"path": "leg1", "appearance": {"colour": "#3498DB", "opacity": 0.5}}, "an opacity-only brush on a painted level keeps its colour (merged)")
	var leg_mat := leg1.material_override as StandardMaterial3D
	_check(leg_mat != null and leg_mat.albedo_color.is_equal_approx(Color(Color.html("#3498DB"), 0.5)) and leg_mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS, "...the leg is half see-through blue (alpha with a depth pre-pass)")
	_check(api.parts["R"]["occurrences"][2]["color"] == "#3498DB", "...the backend mirrored the leg's colour into its occurrence (the legacy alias)")
	tool.brush = {}
	await tool.apply(part_row, "R", scope, "R")
	_check(api.puts().back()["body"] == {"path": "leg1", "appearance": null} and leg1.material_override == Look.plain(), "Clear removes that level's paint (and the leg shows its own, unpainted look)")
	_check(not (tool.model()["parts"]["R"]["occurrences"]["leg1"] as Dictionary).get("color"), "...and the model's copy of the legacy colour goes too (it doesn't come back)")

	# --- live preview: the target takes the brush, everything else keeps its own; ending it puts every look back
	tool.brush = {"colour": "#2ECC71"}
	var frame_row: Dictionary = tool.rows_for(bar_b, 0, scope, "R").filter(func(r) -> bool: return r["id"] == "sub_1")[0]
	var puts_before := api.puts().size()
	tool.preview(frame_row, "R", scope, "R")
	_check(_albedo(bar_b) == Color.html("#2ECC71") and (leg2.material_override == null or leg2.material_override == Look.plain()) and api.puts().size() == puts_before, "previewing the frame shows its bars green, the legs untouched, nothing sent")
	var a_green := false
	for s in bar_a.mesh.get_surface_count():
		var m := bar_a.mesh.surface_get_material(s) as StandardMaterial3D
		a_green = a_green or (m != null and m.albedo_color.is_equal_approx(Color.html("#2ECC71")))
	var a_red := false
	for s in bar_a.mesh.get_surface_count():
		var m := bar_a.mesh.surface_get_material(s) as StandardMaterial3D
		a_red = a_red or (m != null and m.albedo_color.is_equal_approx(Color.html("#E63946")))
	_check(a_green and a_red, "...the bar's own red body stays red inside the green frame (inheritance is visible)")
	tool.end_preview(scope, "R")
	_check(bar_b.material_override != null and _albedo(bar_b) == Color.html("#C8C8C8"), "ending the preview puts the frame's looks back")

	# --- the eyedropper takes everything the face shows
	tool.eyedropper = true
	var got: Dictionary = tool.take_from(bar_a, 0, "R")
	_check(Rule.same(got, {"colour": "#E63946", "roughness": 0.6}) and not tool.eyedropper, "the eyedropper takes the face's look (colour and the part's roughness) and disarms")

	# --- the sandbox: painting is temporary, nothing is sent, and it goes back with the parts
	mates.relaxed = true
	tool.brush = {"colour": "#F1C40F"}
	puts_before = api.puts().size()
	var whole_row: Dictionary = tool.rows_for(leg2, 0, scope, "R").filter(func(r) -> bool: return r["id"] == "whole")[0]
	var temp: Dictionary = await tool.apply(whole_row, "R", scope, "R")
	_check(temp["ok"] and temp["temporary"] and api.puts().size() == puts_before and _albedo(leg2) == Color.html("#F1C40F"), "relaxed: a Whole assembly paint shows on screen and sends nothing")
	_check(tool.panel_title() == "Painting · temporary (mates relaxed)", "...the panel says the paint is temporary")
	_check(not stack._undo_stack.back()["persists"], "...its undo step doesn't mark the document unsaved")
	mates.relaxed = false
	mates.sandbox_changed.emit(false)
	_check(leg2.material_override == Look.plain() and api.puts().size() == puts_before, "Return parts: the temporary paint goes, nothing was ever sent")

	# --- a refused paint says why and changes nothing
	api.fail_puts = true
	tool.brush = {"colour": "#9B59B6"}
	var refused: Dictionary = await tool.apply(part_row, "R", scope, "R")
	_check(not refused["ok"] and str(refused["error"]).contains("refused") and leg1.material_override == Look.plain(), "a paint the backend refuses reports its reason and leaves the part as it was")
	api.fail_puts = false

	# --- group_index.gd places a pattern copy by its instance_path (it has no occurrence id of its own)
	var rows_by_part := {"R": api.parts["R"]["occurrences"], "F": api.parts["F"]["occurrences"], "A": [], "B": [], "L": []}
	var entries := GroupIndex.replay(rows_by_part, "R", {"F": "Frame", "A": "Bar", "B": "Bolt", "L": "Leg"})
	var fresh_copy := MeshInstance3D.new()
	fresh_copy.set_meta("owner_part_id", "R")
	fresh_copy.set_meta("occurrence_id", "")
	fresh_copy.set_meta("instance_path", "bolt#pattern:p1:2")
	holder.add_child(fresh_copy)
	GroupIndex.assign([fresh_copy], entries, "R")
	_check(fresh_copy.get_meta("group_path", []) == ["bolt#pattern:p1:2"] and fresh_copy.get_meta("group_parts", []) == ["B"] and fresh_copy.get_meta("group_names", []) == ["Bolt (copy 2)"], "group_index tags a pattern copy with its #pattern: path, the source's Part and a copy name")

	# --- V-3: a slow first read must not clobber a paint that landed while it was on its way, and a second ensure_loaded awaits the first
	var slow_api := FakeApi.new()
	slow_api.parts = {"R": {"name": "Rig", "occurrences": [FakeApi.row("bolt", "B")]}, "B": {"name": "Bolt"}}
	slow_api.get_delay = 6
	var slow_tool := Tool.new()
	slow_tool.command_stack = CommandStack.new()
	holder.add_child(slow_tool)
	slow_tool.configure(slow_api)
	slow_tool.world_root = "R"
	var slow_bolt := _node(holder, "SlowBolt", "R", "bolt", "bolt", ["Bolt"], false)
	slow_tool.ensure_loaded("R") # (not awaited: what the trigger-down does)
	slow_tool.ensure_loaded("R") # (a second caller: must wait for the first, not start another read)
	await process_frame
	_check(slow_tool.is_busy() and not slow_tool.is_saving(), "V-3: while a read is running the tool is busy but not saving (a paint waits for the read instead of being refused)")
	for i in 80:
		if slow_api.calls.any(func(c: Dictionary) -> bool: return c["method"] == HTTPClient.METHOD_GET and str(c["path"]).ends_with("/R/appearance-overrides")):
			break
		await process_frame
	await process_frame # (the overrides were READ, empty, and the answer is still in flight)
	slow_tool.brush = {"colour": "#2A9D8F"}
	var slow_result: Dictionary = await slow_tool.apply({"id": "part", "label": "Bolt", "record": {"path": "bolt"}, "members": [slow_bolt]}, "R", [slow_bolt], "R")
	_check(slow_result["ok"] and slow_api.puts().size() == 1, "V-3: a paint through the breadcrumb path while the first read is still running is stored")
	await slow_tool.ensure_loaded("R") # (waits for the running read)
	var slow_list: Array = ((slow_tool.model()["parts"] as Dictionary)["R"] as Dictionary).get("appearance_overrides", [])
	_check(slow_list.size() == 1 and slow_list[0]["appearance"] == {"colour": "#2A9D8F"}, "V-3: the read that finished after the paint did not erase it from the model (%s)" % str(slow_list))
	_check(_albedo(slow_bolt) == Color.html("#2A9D8F"), "V-3: ...and the node still wears it")
	var r_reads := slow_api.calls.filter(func(c: Dictionary) -> bool: return c["method"] == HTTPClient.METHOD_GET and str(c["path"]) == "/document/parts/R")
	_check(r_reads.size() == 1, "V-3: two ensure_loaded calls made one read of the Part, not two (%d)" % r_reads.size())
	_check(not slow_tool.is_busy(), "V-3: busy clears once the read and the save are done")
	slow_tool.brush = {"colour": "#E9C46A"}
	await slow_tool.apply({"id": "part", "label": "Bolt", "record": {"path": "bolt"}, "members": [slow_bolt]}, "R", [slow_bolt], "R")
	slow_list = ((slow_tool.model()["parts"] as Dictionary)["R"] as Dictionary).get("appearance_overrides", [])
	_check(slow_list.size() == 1 and slow_list[0]["appearance"] == {"colour": "#E9C46A"} and _albedo(slow_bolt) == Color.html("#E9C46A"), "V-3: two quick paints in a row: the second one is the one shown and kept")

	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)


func _wait_puts(api, count: int) -> void:
	for i in 60:
		if api.puts().size() >= count:
			for k in 3:
				await process_frame
			return
		await process_frame
