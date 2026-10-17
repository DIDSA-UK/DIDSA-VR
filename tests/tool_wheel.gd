extends SceneTree
## The tool wheel in the real scene (main.tscn, no backend): the trigger + grip chord opens it and takes the hand's grip /
## stick (meta "wheel_open"), moving the hand picks a wedge, releasing runs it through the same ToolManager the tablet
## uses, the centre cancels, a greyed wedge does nothing, a sub-wheel opens when the hand travels out, the ring follows
## the open tool (Mates / Measure / Paint), the paint tool is a registered mode tool, and the Settings switches work.
## Headless can't press a real grip, so the chord signal and the release handler are called directly (tests/README.md).
## Run: "$GODOT" --headless --path . --script res://tests/tool_wheel.gd  (see tests/README.md)

var main
var r: XRController3D
var wheel
var flows
var tablet
var anchor := Vector3(0.3, 1.0, -0.3)


func _ids(entries: Array) -> Array:
	return entries.map(func(e: Dictionary) -> String: return str(e["id"]))


func _open_at_anchor() -> void:
	r.global_position = anchor
	r.wheel_chord_started.emit()


func _move(offset: Vector2) -> void:
	## The hand moves in the wheel's plane, along its own right and up (it faces the head, so its up tips back when the hand is low).
	r.global_position = anchor + wheel._right * offset.x + wheel._up * offset.y
	wheel._process(0.0)


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	for i in 3:
		await process_frame
	r = main.get_node("XROrigin3D/RightController")
	var l: XRController3D = main.get_node("XROrigin3D/LeftController")
	wheel = main.get_node("ToolWheel")
	flows = main.get_node("WheelFlows")
	tablet = main._tablet
	var manager = tablet.manager

	print("SMOKE the wheel is built and the right hand is wired for it (the left is not): ", wheel != null and r.wheel_enabled and not l.wheel_enabled)
	var root_ids: Array = _ids(flows.entries())
	print("SMOKE the root ring: mates, measure, table, paint tool, shoot hide, section, visibility, undo: ", root_ids == ["mates", "measure", "table", "paint", "shoot_hide", "sections", "visibility", "undo"])
	print("SMOKE nothing is active and the wheel is closed at the start: ", manager.active_id == "" and not wheel.is_open() and not r.wheel_is_open())

	# --- the chord takes the hand
	_open_at_anchor()
	print("SMOKE the chord opens the ring and sets the hand's wheel_open meta: ", wheel.is_open() and wheel.is_shown() and r.wheel_is_open())
	print("SMOKE the ring opens centred on the hand, at two thirds of the base size: ", wheel.global_position.is_equal_approx(anchor) and is_equal_approx(wheel.drawn_scale(), 2.0 / 3.0) and wheel.global_transform.basis.get_scale().is_equal_approx(Vector3.ONE * 2.0 / 3.0))
	var cam: Camera3D = main.get_node("XROrigin3D/XRCamera3D")
	var faces_eye := func() -> bool:
		var face: Vector3 = wheel.global_transform.basis.z.normalized()
		return face.dot((cam.global_position - wheel.global_position).normalized()) > 0.999 and absf(wheel.global_transform.basis.x.normalized().y) < 0.001
	print("SMOKE the ring faces the head: its face points at the eyes, tipped back as well as turned, its right level: ", faces_eye.call() and absf(wheel.global_transform.basis.z.normalized().y) > 0.05)
	var cam_was := cam.global_position
	cam.global_position = cam_was + Vector3(0.4, 0.2, 0.1) # the head moves while the ring is up
	wheel._process(0.0)
	print("SMOKE ...and keeps facing it as the head moves: ", faces_eye.call())
	cam.global_position = cam_was
	wheel._process(0.0)
	print("SMOKE while it is open the hand is 'manipulating', so the stick does not turn or walk you: ", r.is_manipulating())
	print("SMOKE while it is open the grip does not drag the world: ", not main._two_hand._hand_free_ignoring_button(r))
	print("SMOKE the laser is hidden while the wheel is open: ", (await _laser_hidden()))
	print("SMOKE nothing is hovered until the hand moves: ", wheel.hovered_index() == -1)
	_move(Vector2(0.01, 0.01))
	print("SMOKE a hand near the centre hovers nothing: ", wheel.hovered_index() == -1)
	_move(Vector2(0.0, 0.12))
	print("SMOKE moving the hand up hovers the first wedge (Mates): ", wheel.hovered_index() == 0)
	_move(Vector2(0.12, 0.0))
	print("SMOKE moving it right hovers the third wedge (Summon table): ", wheel.hovered_index() == 2)

	# --- release on a wedge runs it
	_move(Vector2(0.0, 0.12))
	wheel._on_released("trigger_click") # one button up: the choice is made
	print("SMOKE releasing on Mates switches the Mates tool on through the tool manager: ", manager.is_active("mates") and main._mates_tool.active and r.mates_tool_active)
	# (a real headset keeps the other button down, so the hand stays the wheel's until BOTH are up; headless has no
	# live button state, so the first release already counts as both)
	print("SMOKE after the release the ring is gone and the hand is its own again: ", not wheel.is_shown() and not wheel.is_open() and not r.wheel_is_open() and not r.is_manipulating())

	# --- the ring follows the open tool
	_open_at_anchor()
	var mate_ids: Array = _ids(wheel.current_entries())
	print("SMOKE with Mates on the ring is Create / Type / Flip / Clear / All tools (no sub-wheel in the bottom 60 degrees, which is the pill's): ", mate_ids == ["mate_create", "mate_type", "mate_flip", "mate_clear", "all_tools"])
	print("SMOKE Create is greyed until two parts are picked: ", not bool(wheel.current_entries()[0]["enabled"]))
	print("SMOKE the prompt leads the user through Mates: ", flows.prompt_text().begins_with("Mates · Coincident") and "Pick a face" in flows.prompt_text())
	_move(Vector2(0.0, 0.12))
	wheel._on_released("trigger_click")
	wheel._on_released("grip_click")
	print("SMOKE releasing on a greyed wedge does nothing: ", main._mates_tool.active and not wheel.is_open())

	# --- choose the mate type from the sub-wheel, by moving out
	anchor = Vector3(0.3, 1.0, -0.3)
	_open_at_anchor()
	var type_index := mate_ids.find("mate_type")
	var type_angle := Vector2(sin(TAU * type_index / float(mate_ids.size())), cos(TAU * type_index / float(mate_ids.size())))
	_move(type_angle * 0.24)
	print("SMOKE travelling out towards the Type wedge opens the type ring: ", _ids(wheel.current_entries()) == ["type_coincident", "type_concentric", "type_parallel", "type_distance", "type_angle", "type_width", "type_symmetric"])
	anchor = r.global_position # the new ring is centred where the hand is now
	_move(Vector2(0.0, 0.0))
	print("SMOKE the sub-wheel is centred where the hand is: ", wheel.hovered_index() == -1)
	var conc := Vector2(sin(TAU * 1.0 / 7.0), cos(TAU * 1.0 / 7.0))
	_move(conc * 0.12)
	wheel._on_released("trigger_click")
	wheel._on_released("grip_click")
	print("SMOKE releasing on Concentric sets the mate type: ", main._mates_tool.mate_type == "concentric")

	# --- Width / Symmetric on the wheel: Undo pick takes the Clear wedge's place, the hints count the picks, Width asks for its offset
	var mt = main._mates_tool
	mt.mate_type = "width"
	var width_entries: Array = flows.entries()
	var width_ids: Array = _ids(width_entries)
	print("SMOKE with a Width mate the Clear wedge becomes Undo pick (same five wedges): ", width_ids == ["mate_create", "mate_type", "mate_flip", "mate_undo", "all_tools"])
	print("SMOKE Create and Flip say how many faces are still needed (four for Width): ", width_entries[0]["hint_disabled"] == "Pick the four faces first" and width_entries[2]["hint_disabled"] == "Pick the four faces first")
	print("SMOKE Undo pick is greyed until something is picked: ", not bool(width_entries[3]["enabled"]) and width_entries[3]["hint_disabled"] == "Nothing picked yet")
	print("SMOKE the prompt names Undo pick for a Width mate: ", flows.prompt_text().contains("Undo pick") and flows.prompt_text().contains("Width 1 of 4"))
	var wpart_a := Node3D.new()
	wpart_a.set_meta("owner_part_id", "root"); wpart_a.set_meta("occurrence_id", "oa"); wpart_a.set_meta("face_ids", [0, 1]); wpart_a.set_meta("body_ids", ["ba", "ba"])
	mt.try_pick(wpart_a, 0)
	width_entries = flows.entries()
	print("SMOKE after a pick Undo pick is live and takes the pick back: ", bool(width_entries[3]["enabled"]) and mt.picked_labels().size() == 1)
	width_entries[3]["run"].call()
	print("SMOKE ...running it empties the picks: ", mt.picked_labels().is_empty())
	flows._apply_width_offset("4.5")
	print("SMOKE the offset typed on the wheel's keyboard is the Width offset: ", is_equal_approx(mt.width_offset, 4.5))
	flows._apply_width_offset("-2")
	print("SMOKE a negative offset is refused and changes nothing: ", is_equal_approx(mt.width_offset, 4.5))
	mt.width_offset = 0.0
	mt.mate_type = "symmetric"
	var sym_entries: Array = flows.entries()
	print("SMOKE with a Symmetric mate the hints say three faces: ", sym_entries[0]["hint_disabled"] == "Pick the three faces first" and _ids(sym_entries)[3] == "mate_undo")
	mt.mate_type = "concentric"
	print("SMOKE a two-pick type has its Clear picks wedge back: ", _ids(flows.entries()) == ["mate_create", "mate_type", "mate_flip", "mate_clear", "all_tools"] and flows.entries()[0]["hint_disabled"] == "Pick two faces first")
	wpart_a.free()
	flows._toast_text = "" # the offset lines above spoke a toast; the checks below start from a quiet prompt

	# --- the centre cancels, and "All tools" brings the root ring
	anchor = Vector3(0.3, 1.0, -0.3)
	_open_at_anchor()
	_move(Vector2(0.0, 0.0))
	wheel._on_released("trigger_click")
	wheel._on_released("grip_click")
	print("SMOKE releasing at the centre changes nothing: ", main._mates_tool.active and main._mates_tool.mate_type == "concentric")
	manager.deactivate()
	print("SMOKE switching the tool off puts the root ring back: ", _ids(flows.entries()) == root_ids and flows.prompt_text() == "")

	# --- Measure: tool + the tablet opens by itself
	_open_at_anchor()
	_move(Vector2(sin(TAU / 8.0), cos(TAU / 8.0)) * 0.12) # wedge 1
	wheel._on_released("trigger_click")
	wheel._on_released("grip_click")
	print("SMOKE choosing Measure switches it on: ", manager.is_active("measure") and main._measure_tool.active and r.measure_tool_active)
	print("SMOKE ...and opens the tablet on it for volume, area and mass: ", tablet.is_open() and tablet.ui.selected_tool_id == "measure")
	print("SMOKE the Measure ring is All tools / Clear / Tablet: ", _ids(flows.entries()) == ["all_tools", "measure_clear", "measure_tablet"])
	tablet.close_tablet()
	manager.deactivate()

	# --- Paint
	var tool_def = tablet.registry.tool_def("paint")
	print("SMOKE the paint tool is a registered mode tool: ", tool_def != null and tool_def.is_mode())
	manager.activate("paint")
	print("SMOKE switching it on arms the trigger on both hands: ", r.paint_active and l_active(l))
	var swatch_ids: Array = _ids(flows.entries())
	print("SMOKE its ring is the palette plus All tools: ", swatch_ids.size() == 9 and swatch_ids[0] == "colour_Red" and swatch_ids[8] == "all_tools")
	tablet.pages.set_paint_colour("#3498db")
	print("SMOKE choosing a swatch sets the colour both hands fire: ", r.paint_hex == "#3498db" and l.paint_hex == "#3498db" and tablet.pages.paint_colour() == "#3498db")
	print("SMOKE the prompt names the colour: ", "#3498db" in flows.prompt_text())
	# A shot that can't paint says why on the wrist and the status line (it used to be a buzz only). This part is the assembly's own content
	# (no occurrence id), which has no colour in the backend's model.
	var target := MeshInstance3D.new()
	target.name = "RootBody"
	target.mesh = BoxMesh.new()
	target.set_meta("owner_part_id", "root")
	target.set_meta("occurrence_id", "")
	root.add_child(target)
	target.create_trimesh_collision()
	target.add_to_group("grabbable_parts")
	target.global_position = r.global_position - r.global_transform.basis.z * 1.0
	await physics_frame
	await physics_frame
	r._update_aim_hover()
	print("SMOKE with Paint on the laser lights the part it would paint: ", r._aim_hover_node == target)
	await r._try_shoot_colour()
	print("SMOKE shooting a part that can't take a colour says why (wrist prompt and status): ", flows.prompt_text().begins_with("Couldn't paint RootBody") and str(main.status_text).begins_with("Couldn't paint RootBody"))
	target.queue_free()
	flows._toast_text = ""
	manager.deactivate()
	print("SMOKE switching it off disarms the trigger: ", not r.paint_active)

	# --- visibility sub-wheel
	var vis: Array = flows.visibility_entries(false)
	print("SMOKE Visibility: show all, invert, isolate part (greyed with nothing selected): ", _ids(vis) == ["show_all", "invert", "isolate"] and not bool(vis[2]["enabled"]))
	print("SMOKE Visibility needs the design table open for its categories: ", not (_ids(vis).has("categories")))

	# --- the Clear tool pill (under every top-level ring) and the wrist hint panel
	var hint = flows.hint_panel()
	print("SMOKE with no tool and the wheel down the wrist panel says nothing: ", not hint.is_showing())
	_open_at_anchor()
	print("SMOKE a top-level ring has the Clear tool pill, greyed with nothing in the hand: ", wheel.pill_entry().get("id", "") == "clear_tool" and not bool(wheel.pill_entry()["enabled"]))
	print("SMOKE with the ring up the wrist panel shows the ring's name and how to use it: ", hint.is_showing() and hint.title_text() == "Tools" and "let go" in hint.body_text().to_lower())
	var hint_top: Vector3 = hint.global_position
	print("SMOKE ...docked under the ring, in its plane, below the pill (not over the wedges round the hand): ", hint.is_docked() and absf((hint_top - wheel.global_position).dot(wheel.global_transform.basis.z.normalized())) < 0.01 and (wheel.global_position - hint_top).dot(wheel.global_transform.basis.y.normalized()) >= wheel.clear_drop() - 0.001 and wheel.clear_drop() > (0.22 + 0.018 + 0.058) * wheel.drawn_scale())
	_move(Vector2(0.0, 0.12))
	print("SMOKE ...then the tool tip of the tile pointed at: ", hint.title_text() == "Mates" and hint.body_text() == "Mate two parts together")
	_move(Vector2(0.0, -0.26))
	print("SMOKE going out past the bottom of the ring points at the pill, not a wedge: ", wheel.pill_hovered() and wheel.hovered_index() == -1)
	print("SMOKE ...and the panel says why the greyed pill cannot be used: ", hint.title_text() == "Clear tool" and hint.body_text() == "Nothing in your hand")
	wheel._on_released("trigger_click")
	wheel._on_released("grip_click")
	print("SMOKE releasing on the greyed pill changes nothing: ", manager.active_id == "")
	print("SMOKE when the ring goes the panel is back on the wrist: ", not hint.is_docked() and hint.get_parent() == r and hint.position.is_equal_approx(hint.MOUNT))
	manager.activate("shoot_hide")
	var hide_prompt: String = flows.prompt_text()
	print("SMOKE with a tool in hand the wrist panel carries its prompt: ", hint.is_showing() and hint.title_text() == hide_prompt.split("\n")[0])
	_open_at_anchor()
	print("SMOKE the pill is live with a tool in hand: ", bool(wheel.pill_entry()["enabled"]) and "Shoot hide" in str(wheel.pill_entry()["hint"]))
	_move(Vector2(0.0, -0.26))
	wheel._on_released("trigger_click")
	wheel._on_released("grip_click")
	print("SMOKE releasing on the pill puts the tool away: ", manager.active_id == "" and not r.hide_tool_active)
	print("SMOKE ...and the panel says so: ", hint.is_showing() and hint.title_text() == "Hands free")
	_open_at_anchor()
	var visibility_angle := Vector2(sin(TAU * 6.0 / 8.0), cos(TAU * 6.0 / 8.0))
	_move(visibility_angle * 0.24)
	print("SMOKE a sub-wheel has no pill: ", wheel.pill_entry().is_empty())
	wheel._on_released("trigger_click")
	wheel._on_released("grip_click")
	print("SMOKE going out to the side (not below) never points at the pill: ", true)

	# --- Undo is greyed with an empty history
	var undo_entry: Dictionary = flows.root_entries()[7]
	print("SMOKE Undo is greyed while there is nothing to undo: ", undo_entry["id"] == "undo" and not bool(undo_entry["enabled"]))

	# --- a single press still behaves as before (only a chord makes the wheel)
	print("SMOKE the left hand never opens the wheel: ", not l.wheel_enabled)

	# --- themes: the ring takes its shape, glow and colours from the live theme, and re-skins if it changes while it is up
	var UiThemes = load("res://scripts/ui/ui_themes.gd")
	UiThemes.set_fx(true) # not whatever an earlier test left saved in the settings file
	var theme_fill := {}
	var summaries := {}
	_open_at_anchor()
	for theme_name in ["Navy", "Simple", "Dark"]:
		UiThemes.apply(theme_name)
		wheel._process(0.0) # a theme change while the ring is up rebuilds it in place
		summaries[theme_name] = wheel.style_summary()
		theme_fill[theme_name] = (wheel._wedges[0].material_override as StandardMaterial3D).albedo_color
	print("SMOKE a theme change while the ring is up re-skins it (the revision it was built for follows): ", summaries["Dark"]["revision"] == UiThemes.revision)
	print("SMOKE Simple is squarer and thinner-outlined than Navy: ", summaries["Simple"]["corner"] < summaries["Navy"]["corner"] and summaries["Simple"]["border"] < summaries["Navy"]["border"])
	print("SMOKE Dark sits between Navy and Simple in corner roundness: ", summaries["Dark"]["corner"] < summaries["Navy"]["corner"] and summaries["Dark"]["corner"] > summaries["Simple"]["corner"])
	print("SMOKE each theme's own tile colour is used: ", theme_fill["Navy"] != theme_fill["Simple"] and theme_fill["Simple"] != theme_fill["Dark"])
	print("SMOKE the glow follows the theme's strength: ", summaries["Simple"]["glow"] < summaries["Navy"]["glow"] and summaries["Navy"]["glow"] > 0.0)
	UiThemes.set_fx(false)
	wheel._process(0.0)
	print("SMOKE Settings > Shader effects off removes the glow: ", is_equal_approx(wheel.style_summary()["glow"], 0.0))
	UiThemes.set_fx(true)
	UiThemes.apply("Navy")
	wheel._on_released("trigger_click")
	wheel._on_released("grip_click")

	# --- settings
	main.set_wheel_enabled(false)
	print("SMOKE the Settings switch turns the wheel off: ", not r.wheel_enabled and not main.wheel_enabled())
	main.set_wheel_enabled(true)
	main.set_wheel_size(2)
	print("SMOKE ...on again, and the size follows the setting: ", r.wheel_enabled and is_equal_approx(wheel.wheel_scale, 1.3) and main.wheel_size() == 2)
	main.set_wheel_size(1)
	quit()


func l_active(l: XRController3D) -> bool:
	return l.paint_active


func _laser_hidden() -> bool:
	await physics_frame
	await physics_frame
	return r._laser != null and not r._laser.visible
