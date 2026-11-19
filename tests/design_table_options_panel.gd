extends SceneTree
## Parity follow-ups F2 (docs/parity-followups-investigation.md A2, B2): the Properties panel is the one options panel in a sketch.
##  * LAYOUT, measured: for every entry of the dimension catalogue (the Dimension tool's KIND list, two to a line) and for the longest Select menus (DIMENSIONS /
##    RELATIONS / EDIT), no button's text is wider than its button (the clip the investigation found: "Horizontal length" in a 110 px chip). The measuring is proven
##    on the old layout (a chip), which does clip. Every KIND list fits the panel without scrolling.
##  * THROUGH THE EDITOR: the Dimension tool's panel has a KIND group (one exclusive toggle per kind, the previewed one lit, in a two-column grid) and a SHOW group; no
##    Prev / Next / Back; Select shows the whole menu in its groups; the drawer in a sketch is the breadcrumb and the X.
##  * B2: dropping a dimension opens the pad at its dock and a leader line runs from the pad to the dropped dimension's label, which is lit; it goes with the pad.
## NOT checked: how it reads at arm's length on a headset (the tracker's checklist), the line's look, a real laser press.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_options_panel.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const SketchSelection := preload("res://scripts/design_table/sketch_selection.gd")
const CATALOGUE := "res://tests/fixtures/sketch_dimension_catalogue.json"

var failures := 0
var rig
var props


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _clipped(b: Button) -> bool:
	## The text is wider than the room inside its button.
	var font: Font = b.get_theme_font("font")
	var size: int = b.get_theme_font_size("font_size")
	var text_w: float = font.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var room: float = b.size.x - b.get_theme_stylebox("normal").get_minimum_size().x
	return text_w > room + 0.5


func _clipped_labels(options: Array) -> Array:
	props.set_options(options)
	await rig.frames(2)
	var out: Array = []
	for o in options:
		var b: Button = props.option_button(str(o["id"]))
		if b == null or b.size.x <= 0.0 or _clipped(b):
			out.append(str(o["text"]))
	return out


func _kind_list(entry: Dictionary) -> Array:
	var list: Array = []
	for o in entry["options"]:
		list.append({"id": "dk:%s" % o["key"], "text": str(o["label"]), "toggle": true, "per_row": 2, "group": "Kind", "pressed": o["key"] == entry["default"]})
	list.append({"id": "dk_all", "text": "All candidates", "toggle": true, "group": "Show"})
	return list


func _fits() -> bool:
	## Every button of the panel as it stands is whole, and the content needs no scroll.
	return props._rows.size.y <= props._scroll.size.y + 0.5


func _initialize() -> void:
	rig = Rig.new()
	await rig.boot(self)
	var table = rig.table
	var ed = rig.ed
	props = table.props
	table.sketch_sheet_front = false # (as the other laser tests: aim_uv aims at the sheet where the part's own plane puts it)
	ed.selection_first = false # (the drawer's own check, last, turns it on)
	await rig.draw_rectangle()
	table.manager.activate("dimension")
	await rig.frames(3)

	# --- the measuring itself: the old layout (a 110 px chip) clips a long kind, the new one (half the panel) does not
	var old_clip: Array = await _clipped_labels([
		{"id": "a", "text": "Length", "toggle": true}, {"id": "b", "text": "Horizontal length", "toggle": true}, {"id": "c", "text": "Vertical length", "toggle": true},
		{"id": "d", "text": "Angle to horizontal", "toggle": true}, {"id": "e", "text": "All at once", "toggle": true}])
	_check(old_clip.has("Horizontal length") and old_clip.has("Angle to horizontal") and not old_clip.has("Length"), "the measure sees the old layout's clip: five chips clip 'Horizontal length' and 'Angle to horizontal' (%s)" % str(old_clip))
	var width_of_half: float = 0.0

	# --- every catalogue entry's KIND list
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CATALOGUE))
	var worst_kinds := 0
	var all_clean := true
	var all_fit := true
	var named: Array = []
	for entry in data["entries"]:
		var list := _kind_list(entry)
		var clipped: Array = await _clipped_labels(list)
		worst_kinds = maxi(worst_kinds, (entry["options"] as Array).size())
		if not clipped.is_empty():
			all_clean = false
			named.append([entry["picks"], clipped])
		if not _fits():
			all_fit = false
		var first: Button = props.option_button("dk:%s" % entry["options"][0]["key"])
		width_of_half = first.size.x
	_check(all_clean, "no kind label of any of the %d catalogue entries is clipped (the widest is one button of half the panel, %.0f px) %s" % [(data["entries"] as Array).size(), width_of_half, str(named)])
	_check(all_fit, "every entry's KIND list (up to %d kinds and the SHOW toggle) fits the panel without scrolling" % worst_kinds)

	# --- the longest Select menus: every dimension candidate of the biggest entry with a long number, every relation, every edit item
	var dims: Array = []
	var most: Dictionary = {}
	for entry in data["entries"]:
		if most.is_empty() or (entry["options"] as Array).size() > (most["options"] as Array).size():
			most = entry
	for o in most["options"]:
		dims.append({"id": "dim:%s" % o["key"], "text": "%s %.2f" % [o["label"], 1234.56], "group": "Dimensions"})
	var longest_label := 0
	for entry in data["entries"]:
		for o in entry["options"]:
			longest_label = maxi(longest_label, str("%s %.2f" % [o["label"], 1234.56]).length())
	var relations: Array = []
	for id in ["horizontal", "vertical", "parallel", "perpendicular", "equal_length", "collinear", "concentric", "equal_radius", "tangent", "coincident", "merge", "point_on_line", "at_midpoint", "point_on_curve", "point_on_ellipse"]:
		relations.append({"id": id, "text": SketchSelection.TEXT[id], "group": "Relations"})
	var edit: Array = []
	for pair in [["fix", "Fix"], ["unfix", "Unfix"], ["construction", "Construction"], ["delete", "Delete"], ["clear", "Clear"], ["edit_value", "Edit value"], ["diameter_toggle", "Show diameter"], ["angle_side", "Other side"]]:
		edit.append({"id": pair[0], "text": pair[1], "group": "Edit"})
	var clipped_menu: Array = await _clipped_labels(dims + relations + edit)
	_check(clipped_menu.is_empty(), "the longest Select menu (%d dimension candidates with a six-figure value, every relation, every edit item) has no clipped label %s" % [dims.size(), str(clipped_menu)])
	var long_dims: Array = []
	for entry in data["entries"]:
		for o in entry["options"]:
			long_dims.append({"id": "dim:%s_%s" % [o["key"], long_dims.size()], "text": "%s %.2f" % [o["label"], 1234.56], "group": "Dimensions"})
	var clipped_long: Array = await _clipped_labels(long_dims)
	_check(clipped_long.is_empty(), "...and every catalogue label as a Select-menu candidate with its value (%d chars at most) %s" % [longest_label, str(clipped_long)])

	# --- through the editor: the Dimension tool on a picked line
	props.set_options([])
	var ed_session = ed.session
	var lo := Vector2(INF, INF) # the rectangle table_rig.draw_rectangle made (the sheet's centre has moved since, so find it from the points)
	var hi := Vector2(-INF, -INF)
	for id in ed_session.points:
		if not ed_session.is_origin(id):
			lo = Vector2(minf(lo.x, ed_session.points[id].x), minf(lo.y, ed_session.points[id].y))
			hi = Vector2(maxf(hi.x, ed_session.points[id].x), maxf(hi.y, ed_session.points[id].y))
	var edge_uv := Vector2((lo.x + hi.x) * 0.5, lo.y) # the middle of its bottom edge
	await rig.aim_uv(edge_uv)
	await rig.pull()
	await rig.settle(func() -> bool: return not ed_session.busy)
	await rig.aim_uv(edge_uv + Vector2(2, -14))
	var ids: Array = props.option_ids()
	_check(ed_session.selection.size() == 1 and ed.dim_flow.live(), "(setup) a line is picked with the Dimension tool and a preview is live")
	_check(ids == ["dk:length", "dk:h", "dk:v", "dk:horizontalAngle", "dk_all"], "the Dimension tool's panel lists the line's four kinds and 'All candidates', and no Prev / Next / Back: %s" % str(ids))
	var kinds_parent = props.option_button("dk:length").get_parent()
	_check(kinds_parent is GridContainer and kinds_parent.columns == 2 and props.option_button("dk:h").get_parent() == kinds_parent and props.option_button("dk:v").get_parent() != props.option_button("dk_all").get_parent(),
		"...the kinds are toggles in one two-column grid under a KIND caption; the SHOW toggle is its own group")
	_check(_captions() == ["KIND", "SHOW"], "...captions: %s" % str(_captions()))
	_check(props.option_button("dk:length").button_pressed and not props.option_button("dk:h").button_pressed and props.option_button("dk_all").text == "All candidates", "...the previewed kind is lit")
	await rig.frames(2)
	_check(not _clipped(props.option_button("dk:horizontalAngle")) and not _clipped(props.option_button("dk:h")), "...and in the real panel 'Angle to horizontal' and 'Horizontal length' read whole")
	ed.on_option("dk:horizontalAngle")
	await rig.frames(2)
	_check(props.option_button("dk:horizontalAngle").button_pressed and not props.option_button("dk:length").button_pressed, "a press on a kind lights it (the exclusive group)")
	ed.on_option("dk:length")

	# --- B2: drop it: the pad at its dock, the leader line from the pad to the label, the label lit
	var leader = ed.pad_leader
	leader.update_line()
	_check(leader != null and not leader.drawn, "before a drop there is no leader line")
	await ed.intent_select()
	await rig.frames(2)
	leader.update_line()
	var keyboard_top: Variant = table.keyboard_top_centre()
	var label_point: Variant = ed.view.dimension_preview_world_point()
	_check(table.keyboard_open() and ed.dim_flow.stage == "pad" and keyboard_top != null and label_point != null, "dropping opens the pad at its dock (V-8) with the dropped label on the sheet")
	_check(leader.drawn and leader.visible and leader.drawn_from.distance_to(keyboard_top) < 0.001 and leader.drawn_to.distance_to(label_point) < 0.001, "a leader line runs from the pad's top edge to the dropped dimension's label")
	var label: Label3D = ed.view._dim_preview_label
	_check(label.modulate.is_equal_approx(Color(1, 1, 1)) and label.outline_size > 12, "...and the label is lit")
	_check(table.manip != null and props.option_button("dk:length") != null and props.option_button("dk_back") == null, "...the panel still lists the kinds, with no Back button (the pad's own Cancel, B and a second pull step back)")
	ed.intent_back()
	await rig.frames(2)
	leader.update_line()
	_check(not leader.drawn and not leader.visible and not table.keyboard_open(), "stepping back closes the pad and the leader line goes")
	await ed.intent_select()
	await rig.frames(2)
	leader.update_line()
	_check(leader.drawn, "(dropped again: the line is back)")
	rig.main._keyboard._text = "33"
	rig.main._keyboard._confirm()
	await rig.settle(func() -> bool: return not rig.calls_to("/label").is_empty() and not ed_session.busy)
	await rig.frames(2)
	leader.update_line()
	_check(not leader.drawn and not table.keyboard_open(), "typing the value makes the dimension, closes the pad and the line goes with it")

	# --- Select: the whole menu, in groups, and the drawer is the breadcrumb and the X
	table.manager.activate("select")
	await rig.frames(3)
	ed_session.clear_selection()
	ed.selection_first = true
	await rig.aim_uv(edge_uv)
	await rig.pull()
	await rig.settle(func() -> bool: return not ed_session.busy)
	var select_ids: Array = props.option_ids()
	_check(["horizontal", "vertical", "fix", "construction", "delete", "clear"].all(func(i): return select_ids.has(i)) and select_ids.any(func(i): return str(i).begins_with("dim:")) and not select_ids.has("menu_more"),
		"Select: a picked line's whole menu is in the panel (no More): %s" % str(select_ids))
	_check(_captions() == ["DIMENSIONS", "RELATIONS", "EDIT"], "...under DIMENSIONS, RELATIONS and EDIT captions: %s" % str(_captions()))
	var all_whole := true
	for id in select_ids:
		var b: Button = props.option_button(str(id))
		all_whole = all_whole and b != null and not _clipped(b)
	_check(all_whole, "...every button of it reads whole")
	await rig.frames(2)
	# Information, not an assertion: a line's whole menu (ten items, three captions) needs more than the scroll area shows (the area is what is left of the 688 px panel under the
	# title, the hint and the Selected list), so a long Select menu scrolls (the scroll is the last resort the brief keeps). The KIND lists above are asserted to fit.
	print("SMOKE (info) the picked line's whole Select menu needs %.0f px, the panel's scroll area shows %.0f px" % [props._rows.size.y, props._scroll.size.y])
	_check(table.drawer.shown and table.drawer.actions.is_empty() and table.drawer.button_named("Close") != null and table.drawer.button_named("More") == null, "the drawer in a sketch shows the breadcrumb and the X only")

	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)


func _captions() -> Array:
	var out: Array = []
	for child in props._rows.get_children():
		if child is Label:
			out.append(str(child.text))
	return out
