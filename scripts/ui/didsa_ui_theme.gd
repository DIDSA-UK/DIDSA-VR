extends Resource
## The one place the redesigned tablet, floating windows and popup keyboard get
## their look from: colour, radius, spacing, type size and motion tokens, plus
## builders that turn them into a Godot `Theme` and a few shared styleboxes.
##
## It is a Resource on purpose: open `res://ui/didsa_ui_theme.tres` in the Godot
## editor, change a value in the Inspector, and anything built from it (the UI
## Lab scene, `res://lab/ui_lab.tscn`) shows the change the next time it runs.
## No code needed to tune the look.
##
## Deliberately NOT a `class_name`: `--headless --script` runs (every test in
## this repo) don't have the editor's global-class cache, so scripts here are
## always reached by `preload()`, the repo's existing convention.
##
## Theme "type variations" (set `control.theme_type_variation = &"LabelDim"`)
## give the few roles that recur: LabelDim, LabelSmall, LabelTitle, ButtonAccent,
## ButtonDanger, ButtonRail, PanelRaised.

# --- Colour -----------------------------------------------------------------
@export_group("Colour")
@export var bg_panel := Color(0.050, 0.075, 0.120) ## main panel fill
@export var bg_raised := Color(0.085, 0.120, 0.180) ## cards, list rows, inset areas
@export var surface := Color(0.110, 0.155, 0.225) ## buttons at rest
@export var surface_hover := Color(0.150, 0.210, 0.300)
@export var border := Color(0.190, 0.290, 0.400) ## panel and control outlines at rest
@export var accent := Color(0.310, 0.770, 1.000) ## the one restrained highlight colour (cyan)
@export var accent_deep := Color(0.080, 0.300, 0.400) ## a selected/pressed control's fill
@export var text := Color(0.920, 0.950, 0.980)
@export var text_dim := Color(0.600, 0.700, 0.800)
@export var text_disabled := Color(0.380, 0.450, 0.530)
@export var warn := Color(0.960, 0.690, 0.250) ## amber: needs attention
@export var danger := Color(0.950, 0.400, 0.400) ## destructive actions, errors
@export var ok := Color(0.400, 0.900, 0.600)

# --- Shape and spacing ------------------------------------------------------
@export_group("Shape")
@export var radius_panel := 22
@export var radius_control := 12
@export var radius_small := 8
@export var border_width := 2
@export var pad_panel := 18 ## inside a panel's edge
@export var pad_control := 10 ## inside a button
@export var gap := 8 ## between neighbouring controls

# --- Type -------------------------------------------------------------------
@export_group("Type")
@export var font: Font ## null = Godot's default font
@export var font_body := 24
@export var font_small := 18
@export var font_title := 30
@export var font_tiny := 16

# --- Motion (used from Phase 4; kept here so every duration is tunable in one place)
@export_group("Motion")
@export var reduce_motion := false
@export var anim_fast := 0.08 ## hover glow
@export var anim_medium := 0.18 ## category / tool switch
@export var anim_slow := 0.25 ## open, stow, list slide


func duration(seconds: float) -> float:
	## Every animation asks here, so Reduce motion is honoured in one place.
	return 0.0 if reduce_motion else seconds


# --- Styleboxes -------------------------------------------------------------

func box(fill: Color, outline: Color = Color(0, 0, 0, 0), radius: int = -1, margin: int = -1, outline_width: int = -1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = outline
	sb.set_border_width_all(border_width if outline_width < 0 else outline_width)
	if outline.a <= 0.0:
		sb.set_border_width_all(0)
	sb.set_corner_radius_all(radius_control if radius < 0 else radius)
	sb.set_content_margin_all(pad_control if margin < 0 else margin)
	sb.anti_aliasing = true
	return sb


func panel_box() -> StyleBoxFlat:
	## The chrome of every top-level surface: tablet, floating window, keyboard.
	return box(bg_panel, border, radius_panel, pad_panel)


func raised_box() -> StyleBoxFlat:
	return box(bg_raised, border.darkened(0.35), radius_control, pad_control, 1)


func selected_box(accent_colour: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	## A selected / toggled-on control: deep fill and a bright outline. Pass a
	## category accent to tint it; the default is the global accent.
	var a := accent if accent_colour.a <= 0.0 else accent_colour
	return box(a.darkened(0.62), a, radius_control, pad_control, border_width)


# --- Theme ------------------------------------------------------------------

func build_theme() -> Theme:
	var t := Theme.new()
	if font:
		t.default_font = font
	t.default_font_size = font_body

	# Label
	t.set_color("font_color", "Label", text)
	_variation(t, &"LabelDim", &"Label")
	t.set_color("font_color", "LabelDim", text_dim)
	t.set_font_size("font_size", "LabelDim", font_small)
	_variation(t, &"LabelSmall", &"Label")
	t.set_color("font_color", "LabelSmall", text_dim)
	t.set_font_size("font_size", "LabelSmall", font_tiny)
	_variation(t, &"LabelTitle", &"Label")
	t.set_color("font_color", "LabelTitle", text)
	t.set_font_size("font_size", "LabelTitle", font_title)

	# Button
	_button_states(t, "Button", surface, border, accent)
	_variation(t, &"ButtonAccent", &"Button")
	_button_states(t, "ButtonAccent", accent.darkened(0.15), accent, accent, bg_panel)
	_variation(t, &"ButtonDanger", &"Button")
	_button_states(t, "ButtonDanger", surface, danger.darkened(0.2), danger, danger)
	_variation(t, &"ButtonRail", &"Button")
	_button_states(t, "ButtonRail", bg_raised, border.darkened(0.35), accent)
	_variation(t, &"ButtonRailLive", &"Button") ## a mode tool that is switched on, not currently being viewed
	_button_states(t, "ButtonRailLive", bg_raised, accent, accent)
	t.set_constant("h_separation", "Button", gap)

	# Containers and chrome
	t.set_stylebox("panel", "PanelContainer", panel_box())
	_variation(t, &"PanelRaised", &"PanelContainer")
	t.set_stylebox("panel", "PanelRaised", raised_box())

	# Slider: a fat track and a big knob, readable and grabbable at arm's length.
	var track := box(bg_raised, border.darkened(0.2), radius_small, 0, 1)
	track.content_margin_top = 7
	track.content_margin_bottom = 7
	var filled := box(accent_deep, accent_deep, radius_small, 0, 0)
	filled.content_margin_top = 7
	filled.content_margin_bottom = 7
	var filled_hot := filled.duplicate() as StyleBoxFlat
	filled_hot.bg_color = accent.darkened(0.35)
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", filled)
	t.set_stylebox("grabber_area_highlight", "HSlider", filled_hot)
	var knob := knob_texture(40, accent.lightened(0.55))
	var knob_hot := knob_texture(40, Color.WHITE)
	t.set_icon("grabber", "HSlider", knob)
	t.set_icon("grabber_highlight", "HSlider", knob_hot)
	t.set_icon("grabber_disabled", "HSlider", knob)

	# Scroll bars: thin and quiet (the tablet scrolls with the right thumbstick).
	for bar in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", bar, box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), radius_small, 0, 0))
		t.set_stylebox("grabber", bar, box(border, Color(0, 0, 0, 0), radius_small, 0, 0))
		t.set_stylebox("grabber_highlight", bar, box(accent.darkened(0.3), Color(0, 0, 0, 0), radius_small, 0, 0))
		t.set_stylebox("grabber_pressed", bar, box(accent, Color(0, 0, 0, 0), radius_small, 0, 0))
	return t


func _variation(t: Theme, variation: StringName, base: StringName) -> void:
	t.set_type_variation(variation, base)


func _button_states(t: Theme, type: String, fill: Color, outline: Color, selected_accent: Color, label_colour: Color = Color(0, 0, 0, 0)) -> void:
	## normal / hover / pressed (= toggled on) / disabled, plus matching label and
	## icon tints. A pressed state must never rely on colour alone to read as
	## "on": it has a visibly heavier outline AND a deeper fill.
	var ink := text if label_colour.a <= 0.0 else label_colour
	var hover_fill := fill.lightened(0.12)
	t.set_stylebox("normal", type, box(fill, outline))
	t.set_stylebox("hover", type, box(hover_fill, selected_accent.darkened(0.2)))
	var on := selected_box(selected_accent)
	t.set_stylebox("pressed", type, on)
	t.set_stylebox("hover_pressed", type, on)
	t.set_stylebox("disabled", type, box(fill.darkened(0.35), outline.darkened(0.5), -1, -1, 1))
	t.set_stylebox("focus", type, StyleBoxEmpty.new())
	for state in ["font_color", "font_hover_color", "font_focus_color"]:
		t.set_color(state, type, ink)
	t.set_color("font_pressed_color", type, ink)
	t.set_color("font_hover_pressed_color", type, ink)
	t.set_color("font_disabled_color", type, text_disabled)
	t.set_color("icon_normal_color", type, ink)
	t.set_color("icon_hover_color", type, ink)
	t.set_color("icon_pressed_color", type, selected_accent)
	t.set_color("icon_hover_pressed_color", type, selected_accent)
	t.set_color("icon_disabled_color", type, text_disabled)


static func knob_texture(diameter: int, colour: Color) -> ImageTexture:
	## A round slider knob with a one-pixel antialiased rim and a darker edge.
	var img := Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	var c := (diameter - 1) * 0.5
	var radius := diameter * 0.5 - 1.0
	for y in diameter:
		for x in diameter:
			var d := Vector2(x - c, y - c).length()
			if d <= radius:
				var edge := clampf(radius - d, 0.0, 1.0)
				var shade := colour if d < radius - 3.0 else colour.darkened(0.35)
				img.set_pixel(x, y, Color(shade.r, shade.g, shade.b, edge))
	return ImageTexture.create_from_image(img)
