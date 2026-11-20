extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + Mesa llvmpipe): the Assembly Tree window's 480 px panel, drawn for real, with a tree of long names and every state.
## Asserts that no row's text is clipped (the name and its short hint fit beside the icon) and that the full reason shows in the bottom bar for the selected row.
## TREE_RENDER_DIR=/some/dir also writes tree_rows.png and tree_selected.png (the panel's viewport as drawn).
## A Mesa software render of the panel's own viewport: a layout check, not what the headset shows (lens, distance, reading size are not covered).
## Run: xvfb-run -a "$GODOT" --path . --script res://tests/assembly_tree_render.gd  (ci_render.sh)

const Model := preload("res://scripts/tree/occurrence_tree_model.gd")

var main
var window
const NODES := [
	["a", "Peg", "fixed", 0, false, false],
	["b", "Bracket left long name", "under_constrained", 2, false, false],
	["c", "lost_bracket", "missing", 0, false, true],
	["d", "Drive plate assembly", "over_constrained", 0, false, false],
	["e", "Spacer", "fully_constrained", 0, false, false],
	["f", "Housing cover with a long name", "under_constrained", 12, false, false],
]


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func tree() -> Dictionary:
	var kids: Array = []
	for n in NODES:
		var missing: bool = n[5]
		kids.append({
			"occurrence_id": n[0], "path": [n[0]], "external_ref": "x.didsa" if missing else null, "ref_part_id": null if missing else "P" + n[0], "resolved_part_id": null if missing else "P" + n[0],
			"part_name": null if missing else n[1], "name_override": n[1] if missing else null, "kind": "missing" if missing else "part",
			"fixed": n[2] == "fixed", "hidden": false, "suppressed": false, "color": null,
			"constraint": null if missing else {"status": n[2], "dof": n[3], "rigid_set": null, "broken_mates": 0, "near_mates": 0},
			"feature_count": 0, "placements": 1, "cycle": false, "truncated": false, "status_failed": false, "mates": null, "patterns": null, "problems": null, "children": [],
		})
	return {
		"part_id": "R", "part_name": "Test rig", "kind": "assembly", "feature_count": 0, "status_included": true,
		"mates": {"count": 0, "suppressed": 0, "broken": 0, "near": 0, "held": 0, "lost": 0}, "patterns": {"count": 0, "suppressed": 0},
		"problems": {"missing": 1, "cycles": 0, "broken": 0, "over_constrained": 1, "near": 0}, "children": kids, "truncated": false, "node_count": kids.size(),
		"max_depth": 32, "max_nodes": 10000, "truncated_depth": false, "truncated_nodes": false, "status_failed": false, "status_incomplete": false,
	}


func answer(method: int, path: String, _body) -> Dictionary:
	if method == HTTPClient.METHOD_GET and path.begins_with("/parts/R/assembly-tree"):
		return {"ok": true, "json": tree(), "error": ""}
	if method == HTTPClient.METHOD_GET and path == "/parts/R":
		return {"ok": true, "json": {"name": "Test rig"}, "error": ""}
	return {"ok": false, "json": null, "code": 404, "error": "404"}


func rail_buttons() -> Array:
	var out: Array = []
	for line in window._rows_box.get_children():
		for c in line.get_children():
			if c is Button and c.theme_type_variation == &"ButtonRail":
				out.append(c)
	return out


func clipped(b: Button) -> bool:
	## The text (with the icon and the button's own padding) is wider than the button.
	var font := b.get_theme_font("font")
	var size := b.get_theme_font_size("font_size")
	var w := font.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var icon_w := (b.icon.get_width() + 4.0) if b.icon != null else 0.0
	var pad := b.get_theme_stylebox("normal").get_minimum_size().x
	return w + icon_w + pad > b.size.x


func shoot(name: String) -> void:
	var dir := OS.get_environment("TREE_RENDER_DIR")
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	window._viewport.get_texture().get_image().save_png("%s/%s.png" % [dir, name])


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main._resolved_part_id = "R"
	window = main._assembly_tree_window
	window.request_hook = Callable(self, "answer")
	window.backend_url = "http://example.invalid"
	window.api_key = "k"
	window.open()
	for i in 30:
		await process_frame
	var buttons := rail_buttons()
	check("(setup) the rows are drawn (root and six parts)", buttons.size() == 7)
	await process_frame
	await RenderingServer.frame_post_draw
	shoot("tree_rows")
	var cut := buttons.filter(func(b): return clipped(b) and b.text.contains("  · "))
	check("no row's hint is cut off in the 480 px panel (cut: %s)" % ", ".join(cut.map(func(b): return b.text)), cut.is_empty())
	var long_alone := buttons.filter(func(b): return b.text == "Housing cover with a long name")
	check("a name too long even alone drops the hint (the bar has it) and ends in an ellipsis rather than being cut mid-letter", long_alone.size() == 1 and long_alone[0].text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS)
	check("the missing file's row reads name first, then 'missing'", buttons.any(func(b): return b.text == "lost_bracket  · missing"))
	window._on_row_selected(Model.find_row(window._tree, ["c"]))
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	shoot("tree_selected")
	check("the bottom bar gives the full reason for the selected row", window._bar_hint.text.begins_with("lost_bracket  ·  missing file"))
	check("...and it is not clipped either (it wraps or fits)", window._bar_hint.autowrap_mode != TextServer.AUTOWRAP_OFF or window._bar_hint.get_minimum_size().x <= window._bar_hint.size.x + 1.0)
	main.queue_free()
	await process_frame
	quit(0)
