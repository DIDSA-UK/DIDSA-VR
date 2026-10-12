extends SceneTree
## The tool wheel in the real scene (main.tscn, no backend): the trigger + grip chord opens it and takes the hand's grip /
## stick (meta "wheel_open"), moving the hand picks a wedge, releasing runs it through the same ToolManager the tablet
## uses, the centre cancels, a greyed wedge does nothing, a sub-wheel opens when the hand travels out, the ring follows
## the open tool (Mates / Measure / Colour gun), the colour gun is a registered mode tool, and the Settings switches work.
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
	## The hand moves in the wheel's plane: up is world up; "right" is the wheel's own right.
	r.global_position = anchor + wheel._right * offset.x + Vector3.UP * offset.y
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
	print("SMOKE the root ring: constraint, measure, table, colour gun, shoot hide, section, visibility, undo: ", root_ids == ["mates", "measure", "table", "colour_gun", "shoot_hide", "sections", "visibility", "undo"])
	print("SMOKE nothing is active and the wheel is closed at the start: ", manager.active_id == "" and not wheel.is_open() and not r.wheel_is_open())

	# --- the chord takes the hand
	_open_at_anchor()
	print("SMOKE the chord opens the ring and sets the hand's wheel_open meta: ", wheel.is_open() and wheel.is_shown() and r.wheel_is_open())
	print("SMOKE while it is open the hand is 'manipulating', so the stick does not turn or walk you: ", r.is_manipulating())
	print("SMOKE while it is open the grip does not drag the world: ", not main._two_hand._hand_free_ignoring_button(r))
	print("SMOKE the laser is hidden while the wheel is open: ", (await _laser_hidden()))
	print("SMOKE nothing is hovered until the hand moves: ", wheel.hovered_index() == -1)
	_move(Vector2(0.01, 0.01))
	print("SMOKE a hand near the centre hovers nothing: ", wheel.hovered_index() == -1)
	_move(Vector2(0.0, 0.12))
	print("SMOKE moving the hand up hovers the first wedge (Constraint): ", wheel.hovered_index() == 0)
	_move(Vector2(0.12, 0.0))
	print("SMOKE moving it right hovers the third wedge (Summon table): ", wheel.hovered_index() == 2)

	# --- release on a wedge runs it
	_move(Vector2(0.0, 0.12))
	wheel._on_released("trigger_click") # one button up: the choice is made
	print("SMOKE releasing on Constraint switches the Mates tool on through the tool manager: ", manager.is_active("mates") and main._mates_tool.active and r.mates_tool_active)
	# (a real headset keeps the other button down, so the hand stays the wheel's until BOTH are up; headless has no
	# live button state, so the first release already counts as both)
	print("SMOKE after the release the ring is gone and the hand is its own again: ", not wheel.is_shown() and not wheel.is_open() and not r.wheel_is_open() and not r.is_manipulating())

	# --- the ring follows the open tool
	_open_at_anchor()
	var mate_ids: Array = _ids(wheel.current_entries())
	print("SMOKE with Mates on the ring is Create / Flip / Clear / Type / Done / All tools: ", mate_ids == ["mate_create", "mate_flip", "mate_clear", "mate_type", "mate_exit", "all_tools"])
	print("SMOKE Create is greyed until two parts are picked: ", not bool(wheel.current_entries()[0]["enabled"]))
	print("SMOKE the prompt leads the user through Mates: ", flows.prompt_text().begins_with("Constraint · Coincident") and "Pick a face" in flows.prompt_text())
	_move(Vector2(0.0, 0.12))
	wheel._on_released("trigger_click")
	wheel._on_released("grip_click")
	print("SMOKE releasing on a greyed wedge does nothing: ", main._mates_tool.active and not wheel.is_open())

	# --- choose the mate type from the sub-wheel, by moving out
	anchor = Vector3(0.3, 1.0, -0.3)
	_open_at_anchor()
	var type_index := mate_ids.find("mate_type")
	var type_angle := Vector2(sin(TAU * type_index / 6.0), cos(TAU * type_index / 6.0))
	_move(type_angle * 0.24)
	print("SMOKE travelling out towards the Type wedge opens the type ring: ", _ids(wheel.current_entries()) == ["type_coincident", "type_concentric", "type_parallel", "type_distance", "type_angle"])
	anchor = r.global_position # the new ring is centred where the hand is now
	_move(Vector2(0.0, 0.0))
	print("SMOKE the sub-wheel is centred where the hand is: ", wheel.hovered_index() == -1)
	var conc := Vector2(sin(TAU * 1.0 / 5.0), cos(TAU * 1.0 / 5.0))
	_move(conc * 0.12)
	wheel._on_released("trigger_click")
	wheel._on_released("grip_click")
	print("SMOKE releasing on Concentric sets the mate type: ", main._mates_tool.mate_type == "concentric")

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
	print("SMOKE the Measure ring is Clear / Tablet / Done / All tools: ", _ids(flows.entries()) == ["measure_clear", "measure_tablet", "measure_exit", "all_tools"])
	tablet.close_tablet()
	manager.deactivate()

	# --- Colour gun
	var tool_def = tablet.registry.tool_def("colour_gun")
	print("SMOKE the colour gun is a registered mode tool: ", tool_def != null and tool_def.is_mode())
	manager.activate("colour_gun")
	print("SMOKE switching it on arms the trigger on both hands: ", r.colour_gun_active and l_active(l))
	var swatch_ids: Array = _ids(flows.entries())
	print("SMOKE its ring is the palette plus Done and All tools: ", swatch_ids.size() == 10 and swatch_ids[0] == "colour_Red" and swatch_ids[8] == "colour_exit")
	tablet.pages.set_gun_colour("#3498db")
	print("SMOKE choosing a swatch sets the colour both hands fire: ", r.colour_gun_hex == "#3498db" and l.colour_gun_hex == "#3498db" and tablet.pages.gun_colour() == "#3498db")
	print("SMOKE the prompt names the colour: ", "#3498db" in flows.prompt_text())
	manager.deactivate()
	print("SMOKE switching it off disarms the trigger: ", not r.colour_gun_active)

	# --- visibility sub-wheel
	var vis: Array = flows.visibility_entries(false)
	print("SMOKE Visibility: show all, invert, isolate part (greyed with nothing selected): ", _ids(vis) == ["show_all", "invert", "isolate"] and not bool(vis[2]["enabled"]))
	print("SMOKE Visibility needs the design table open for its categories: ", not (_ids(vis).has("categories")))

	# --- Undo is greyed with an empty history
	var undo_entry: Dictionary = flows.root_entries()[7]
	print("SMOKE Undo is greyed while there is nothing to undo: ", undo_entry["id"] == "undo" and not bool(undo_entry["enabled"]))

	# --- a single press still behaves as before (only a chord makes the wheel)
	print("SMOKE the left hand never opens the wheel: ", not l.wheel_enabled)

	# --- themes: the ring takes its shape, glow and colours from the live theme, and re-skins if it changes while it is up
	var UiThemes = load("res://scripts/ui/ui_themes.gd")
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
	return l.colour_gun_active


func _laser_hidden() -> bool:
	await physics_frame
	await physics_frame
	return r._laser != null and not r._laser.visible
