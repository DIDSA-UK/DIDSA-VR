extends SceneTree
## The synthesised UI sounds (scripts/ui/ui_sounds.gd) and how ui_feedback.gd plays them.
## Checks the SAMPLES (the only thing a headless run can hear): every event has a sound, it is
## 16-bit mono, short, audible but never clipping, starts and ends at silence (no click),
## deterministic; the hover tick is quieter than the press click. Then playback rules with a
## real node in the tree: sound off / volume 0 / no stream = silent, volume maps to dB, the same
## event can't retrigger within the minimum interval, and voices are capped.
## Run: "$GODOT" --headless --path . --script res://tests/ui_sounds.gd  (see tests/README.md)

func _peak(s: AudioStreamWAV) -> int:
	var p := 0
	for i in range(0, s.data.size(), 2):
		p = maxi(p, absi(s.data.decode_s16(i)))
	return p

func _players() -> Array:
	var out := []
	for c in root.get_children():
		if c is AudioStreamPlayer3D:
			out.append(c)
	return out

func _initialize() -> void:
	var Sounds = load("res://scripts/ui/ui_sounds.gd")
	var Fb = load("res://scripts/ui/ui_feedback.gd")
	var all_ok := true
	var peaks := {}
	var details := []
	for e in Sounds.EVENTS:
		var s: AudioStreamWAV = Sounds.make(e)
		var n: int = s.data.size() / 2
		var ms: float = 1000.0 * n / s.mix_rate
		var pk := _peak(s)
		peaks[e] = pk
		var first: int = absi(s.data.decode_s16(0))
		var last: int = absi(s.data.decode_s16((n - 1) * 2))
		var ok: bool = s.format == AudioStreamWAV.FORMAT_16_BITS and not s.stereo and s.mix_rate == 44100 and ms >= 15.0 and ms <= 400.0 \
			and pk > 0.05 * 32767.0 and pk < 0.85 * 32767.0 and first < 0.02 * 32767.0 and last < 0.02 * 32767.0
		if not ok:
			all_ok = false
			details.append("%s (ms=%.0f peak=%d first=%d last=%d)" % [e, ms, pk, first, last])
	print("SMOKE all seven events have a sound: 16-bit mono 44.1 kHz, 15-400 ms, audible, never clipping, silent at both ends: ", all_ok, " ", details)
	print("SMOKE the hover tick is much quieter than the press click: ", peaks["hover"] < peaks["press"] * 0.5)
	print("SMOKE synthesis is deterministic (same bytes twice): ", Sounds.make("press").data == Sounds.make("press").data)
	print("SMOKE different events sound different: ", Sounds.make("open").data != Sounds.make("close").data and Sounds.make("confirm").data != Sounds.make("error").data)

	Sounds.register_all()
	var all_registered := true
	for e in Sounds.EVENTS:
		all_registered = all_registered and Fb.has_sound(e)
	print("SMOKE register_all() hands every sound to ui_feedback: ", all_registered)

	var spot := Node3D.new()
	root.add_child(spot)
	spot.global_position = Vector3(1, 2, 3)
	await process_frame
	Fb.set_sound_enabled(true)
	Fb.set_volume(0.5)
	Fb.play("error", spot) # a long one (~300 ms), so it is still sounding when we count
	var ps := _players()
	print("SMOKE playing puts a spatial player at the node's position: ", ps.size() == 1 and (ps[0] as Node3D).global_position.is_equal_approx(Vector3(1, 2, 3)))
	print("SMOKE ...at the volume setting (linear 0.5 = -6 dB): ", ps.size() == 1 and absf((ps[0] as AudioStreamPlayer3D).volume_db - linear_to_db(0.5)) < 0.01)
	var t0: int = Fb._last_ms["error"]
	Fb.play("error", spot)
	print("SMOKE the same event can't retrigger inside the minimum interval: ", Fb._last_ms["error"] == t0)
	while Time.get_ticks_msec() - t0 < 80: # wall-clock: a headless run's timers can run faster than real time
		await process_frame
	Fb.play("error", spot)
	print("SMOKE ...but can once it has passed: ", Fb._last_ms["error"] > t0)
	for p in _players():
		p.queue_free()
	await process_frame
	await process_frame

	Fb.set_sound_enabled(false)
	Fb.play("grab", spot)
	print("SMOKE Sound off: nothing plays: ", _players().is_empty())
	Fb.set_sound_enabled(true)
	Fb.set_volume(0.0)
	Fb.play("grab", spot)
	print("SMOKE Volume 0: nothing plays: ", _players().is_empty())
	Fb.set_volume(2.5)
	print("SMOKE the volume clamps to 0..1: ", Fb.volume == 1.0)
	Fb.set_volume(0.7)
	Fb.play("not_an_event", spot)
	print("SMOKE an event with no sound is silent, not an error: ", _players().is_empty())

	# Voice cap: many different events at once can't pile up unbounded.
	var mixed: Array = Sounds.EVENTS.duplicate()
	for round in 3:
		for e in mixed:
			Fb._last_ms.erase(e)
			Fb.play(e, spot)
	print("SMOKE no more than %d sounds ever play at once: " % Fb.MAX_VOICES, _players().size() <= Fb.MAX_VOICES and _players().size() >= 1)
	quit()
