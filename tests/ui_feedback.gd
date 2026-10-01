extends SceneTree
## Haptics and sound hooks (scripts/ui/ui_feedback.gd), the comfort settings that drive them
## (scripts/app_settings.gd) and the Reduce motion flag every animation asks the theme about.
## No scene tree needed beyond a fake hand.
## Run: "$GODOT" --headless --path . --script res://tests/ui_feedback.gd  (see tests/README.md)

class FakeHand extends RefCounted:
	var pulses: Array = []
	func trigger_haptic_pulse(_action: String, _freq: float, amp: float, dur: float, _delay: float) -> void:
		pulses.append([amp, dur])

func _initialize() -> void:
	var Fb = load("res://scripts/ui/ui_feedback.gd")
	var hand := FakeHand.new()
	Fb.set_haptics_level(2)
	Fb.haptic(hand, "press")
	print("SMOKE Normal haptics: a press is the original 0.4 / 50 ms pulse: ", hand.pulses == [[0.4, 0.05]])
	Fb.haptic(hand, "nonsense")
	Fb.haptic(null, "press")
	print("SMOKE an unknown event or a null hand is ignored: ", hand.pulses.size() == 1)
	Fb.set_haptics_level(0)
	Fb.haptic(hand, "press")
	print("SMOKE haptics Off sends nothing: ", hand.pulses.size() == 1)
	Fb.set_haptics_level(1)
	Fb.haptic(hand, "press")
	print("SMOKE Low is half strength: ", is_equal_approx(hand.pulses[1][0], 0.2))
	Fb.set_haptics_level(3)
	Fb.haptic(hand, "error")
	print("SMOKE High is stronger but never over 1.0: ", hand.pulses[2][0] == 1.0)
	Fb.set_haptics_level(99)
	print("SMOKE an out-of-range level clamps: ", Fb.haptics_level == 3)
	Fb.set_haptics_level(2)

	print("SMOKE no sound is registered by default (nothing ships yet): ", not Fb.has_sound("press"))
	Fb.play("press", null) # must not crash
	var stream := AudioStreamGenerator.new()
	Fb.set_sound("press", stream)
	print("SMOKE a registered stream is remembered, and can be removed: ", Fb.has_sound("press"))
	Fb.set_sound("press", null)
	print("SMOKE ...removed: ", not Fb.has_sound("press"))

	var tokens: Resource = load("res://ui/didsa_ui_theme.tres")
	Fb.reduce_motion = false
	print("SMOKE the theme passes an animation duration through normally: ", is_equal_approx(tokens.duration(0.2), 0.2))
	Fb.reduce_motion = true
	print("SMOKE Reduce motion (runtime flag) makes every duration 0: ", tokens.duration(0.2) == 0.0)
	Fb.reduce_motion = false
	tokens.reduce_motion = true
	print("SMOKE ...and so does the theme resource's own flag: ", tokens.duration(0.2) == 0.0)
	tokens.reduce_motion = false

	# Persistence: round trip through the real settings file, then put the file back.
	var Settings = load("res://scripts/app_settings.gd")
	var before := FileAccess.file_exists(Settings.PATH)
	var backup := FileAccess.get_file_as_string(Settings.PATH) if before else ""
	var s = Settings.new()
	s.set_reduce_motion(true)
	s.set_haptics_level(3)
	s.set_sound_enabled(false)
	s.set_sound_volume(0.35)
	var s2 = Settings.new()
	s2.load_from_disk()
	print("SMOKE reduce motion and the haptics level survive a restart (settings file): ", s2.reduce_motion == true and s2.haptics_level == 3)
	print("SMOKE sound on/off and the volume survive a restart too: ", s2.sound_enabled == false and is_equal_approx(s2.sound_volume, 0.35))
	var d = Settings.new()
	print("SMOKE the defaults are motion on and Normal haptics: ", d.reduce_motion == false and d.haptics_level == 2)
	print("SMOKE ...and sound on at 70%: ", d.sound_enabled == true and is_equal_approx(d.sound_volume, 0.7))
	if before:
		var f := FileAccess.open(Settings.PATH, FileAccess.WRITE)
		f.store_string(backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Settings.PATH))
	quit()
