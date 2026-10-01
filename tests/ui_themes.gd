extends SceneTree
## Themes and shader effects (scripts/ui/ui_themes.gd, didsa_ui_theme.gd, fx_overlay.gd), no XR:
## the three presets load and differ; every preset keeps readable contrast (WCAG ratios for body
## text, dim text, accent, warn/danger, selected and accent-button labels); applying a preset copies
## it into the ONE shared resource in place and bumps the revision UIs watch; unknown names change
## nothing; the effects switch bumps the revision once per real change, adds/removes the button
## glow in the built Theme, and shows/hides the glass overlay; the overlay passes the theme's
## numbers to the shader and follows its size; theme + effects choices persist.
## Run: "$GODOT" --headless --path . --script res://tests/ui_themes.gd  (see tests/README.md)

const Themes := preload("res://scripts/ui/ui_themes.gd")
const FxOverlay := preload("res://scripts/ui/fx_overlay.gd")

func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)

func _lum(c: Color) -> float:
	return 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b)

func _contrast(a: Color, b: Color) -> float:
	var la := _lum(a); var lb := _lum(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)

func _initialize() -> void:
	var live: Resource = Themes.live()
	print("SMOKE there are three themes (Navy, Simple, Dark) and each preset loads with its own name: ", Themes.ORDER == ["Navy", "Simple", "Dark"] and Themes.ORDER.all(func(n): return Themes.preset(n) != null and Themes.preset(n).display_name == n))
	print("SMOKE the presets really differ (panel colours all distinct): ", Themes.preset("Navy").bg_panel != Themes.preset("Simple").bg_panel and Themes.preset("Simple").bg_panel != Themes.preset("Dark").bg_panel and Themes.preset("Navy").bg_panel != Themes.preset("Dark").bg_panel)

	var worst := {}
	var all_ok := true
	for n in Themes.ORDER:
		var t: Resource = Themes.preset(n)
		var sel: Color = t.accent.darkened(0.62)
		var checks := {
			"text/panel >= 7": _contrast(t.text, t.bg_panel) >= 7.0,
			"text/button >= 7": _contrast(t.text, t.surface) >= 7.0,
			"dim/panel >= 4.5": _contrast(t.text_dim, t.bg_panel) >= 4.5,
			"dim/raised >= 4.5": _contrast(t.text_dim, t.bg_raised) >= 4.5,
			"accent/panel >= 3": _contrast(t.accent, t.bg_panel) >= 3.0,
			"warn/raised >= 4.5": _contrast(t.warn, t.bg_raised) >= 4.5,
			"danger/panel >= 4.5": _contrast(t.danger, t.bg_panel) >= 4.5,
			"text/selected >= 4.5": _contrast(t.text, sel) >= 4.5,
			"accent-button label >= 4.5": _contrast(t.bg_panel, t.accent.darkened(0.15)) >= 4.5,
		}
		for k in checks:
			if not checks[k]:
				all_ok = false
				worst[n] = worst.get(n, []) + [k]
	print("SMOKE every theme keeps readable contrast (text, dim text, accent, warn, danger, selected, accent button): ", all_ok, " ", worst)

	# --- applying a preset: in place, one shared resource, revision bump
	var rev0: int = Themes.revision
	var ok1: bool = Themes.apply("Dark")
	print("SMOKE applying Dark copies it into the SHARED resource in place: ", ok1 and Themes.live() == live and live.bg_panel == Themes.preset("Dark").bg_panel and live.radius_panel == 18 and Themes.current == "Dark")
	print("SMOKE ...and bumps the revision the UIs watch: ", Themes.revision == rev0 + 1)
	var rev1: int = Themes.revision
	var bad: bool = Themes.apply("Nonsense")
	print("SMOKE an unknown theme name is refused and changes nothing: ", not bad and Themes.revision == rev1 and Themes.current == "Dark" and live.bg_panel == Themes.preset("Dark").bg_panel)
	Themes.apply("Simple")
	print("SMOKE Simple is flat and square-ish (thin outline, smaller radius than Navy): ", live.border_width == 1 and live.radius_panel < Themes.preset("Navy").radius_panel)
	Themes.apply("Navy")
	var script_default = load("res://scripts/ui/didsa_ui_theme.gd").new()
	print("SMOKE Navy is the original look (equals the script defaults): ", live.bg_panel == script_default.bg_panel and live.accent == script_default.accent and live.radius_panel == script_default.radius_panel and live.fx_glow_strength == script_default.fx_glow_strength)

	# --- effects switch
	Themes.set_fx(true)
	var r2: int = Themes.revision
	Themes.set_fx(true)
	print("SMOKE setting effects to what they already are is not a change: ", Themes.revision == r2)
	var on_theme: Theme = live.build_theme()
	var hover_on: StyleBoxFlat = on_theme.get_stylebox("hover", "Button")
	var sel_on: StyleBoxFlat = on_theme.get_stylebox("pressed", "Button")
	print("SMOKE with effects ON hovered and selected buttons have a soft glow: ", hover_on.shadow_size > 0 and sel_on.shadow_size > 0 and sel_on.shadow_color.a > 0.0)
	Themes.set_fx(false)
	var off_theme: Theme = live.build_theme()
	print("SMOKE with effects OFF they don't: ", (off_theme.get_stylebox("hover", "Button") as StyleBoxFlat).shadow_size == 0 and (off_theme.get_stylebox("pressed", "Button") as StyleBoxFlat).shadow_size == 0)
	print("SMOKE ...and switching bumped the revision once: ", Themes.revision == r2 + 1)
	Themes.set_fx(true)
	var keep: float = live.fx_button_glow
	live.fx_button_glow = 0.0
	print("SMOKE a theme that asks for no glow gets none even with effects on: ", (live.build_theme().get_stylebox("hover", "Button") as StyleBoxFlat).shadow_size == 0)
	live.fx_button_glow = keep

	# --- the glass overlay
	var host := Control.new() # the overlay is anchored full-rect to its panel's root Control, as in every real UI
	host.size = Vector2(800, 500)
	root.add_child(host)
	var ov := FxOverlay.new()
	host.add_child(ov)
	ov.setup(live)
	await process_frame
	var mat: ShaderMaterial = ov.material
	print("SMOKE the glass shader is a canvas-item shader with code: ", FxOverlay.SHADER.get_mode() == Shader.MODE_CANVAS_ITEM and FxOverlay.SHADER.code.length() > 100)
	print("SMOKE the overlay is click-through and sits over its panel without taking input: ", ov.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	print("SMOKE with effects ON the overlay is shown, carrying the theme's numbers and the panel's size: ", ov.visible and is_equal_approx(mat.get_shader_parameter("glow_strength"), live.fx_glow_strength) and is_equal_approx(mat.get_shader_parameter("radius"), float(live.radius_panel)) and mat.get_shader_parameter("rect_size") == Vector2(800, 500))
	host.size = Vector2(300, 200)
	await process_frame
	print("SMOKE ...and follows a resize (windows are resizable): ", mat.get_shader_parameter("rect_size") == Vector2(300, 200))
	Themes.set_fx(false)
	ov.refresh(live)
	print("SMOKE with effects OFF the overlay is hidden (costs nothing): ", not ov.visible)
	Themes.set_fx(true)
	var gs: float = live.fx_glow_strength; var ss: float = live.fx_sheen_strength
	live.fx_glow_strength = 0.0; live.fx_sheen_strength = 0.0
	ov.refresh(live)
	print("SMOKE a theme with no glow and no sheen hides it too: ", not ov.visible)
	live.fx_glow_strength = gs; live.fx_sheen_strength = ss
	ov.refresh(live)
	print("SMOKE ...and it comes back when the theme asks for effects: ", ov.visible)

	# --- persistence
	var Settings = load("res://scripts/app_settings.gd")
	var before := FileAccess.file_exists(Settings.PATH)
	var backup := FileAccess.get_file_as_string(Settings.PATH) if before else ""
	var s = Settings.new()
	print("SMOKE the defaults are the Navy theme with effects on: ", s.ui_theme == "Navy" and s.fx_enabled == true)
	s.set_ui_theme("Dark")
	s.set_fx_enabled(false)
	var s2 = Settings.new()
	s2.load_from_disk()
	print("SMOKE the chosen theme and the effects switch survive a restart: ", s2.ui_theme == "Dark" and s2.fx_enabled == false)
	if before:
		var f := FileAccess.open(Settings.PATH, FileAccess.WRITE)
		f.store_string(backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Settings.PATH))
	Themes.apply("Navy")
	quit()
