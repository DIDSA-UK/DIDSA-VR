extends RefCounted
## The UI's sounds, synthesised in code: nothing to download, no licences, no editor import
## step (so tests and exports need no audio files) and every sound is tunable here. Small,
## soft, synthetic "instrument" tones — hover tick, press click, grab thunk, open / close
## sweeps, confirm and error — built once at startup into 16-bit mono AudioStreamWAVs and
## registered with ui_feedback.gd, whose call sites already trigger them.
##
## Deterministic (a fixed noise seed), so the same bytes come out every time. To change a
## sound, edit its recipe in _build(); to use a recorded file for one event instead, call
## UiFeedback.set_sound("press", load("res://audio/click.ogg")) after register_all().

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const RATE := 44100
const EVENTS: Array[String] = ["hover", "press", "grab", "open", "close", "confirm", "error"]


static func register_all() -> void:
	for event in EVENTS:
		UiFeedback.set_sound(event, make(event))


static func make(event: String) -> AudioStreamWAV:
	var samples := _build(event)
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = bytes
	return stream


static func _build(event: String) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	match event:
		"hover": # a barely-there tick
			_add(out, _tone(2600.0, 2600.0, 22, 0.10, 0.006))
		"press": # a soft click: a quick falling blip plus a tiny noise transient
			_add(out, _tone(1500.0, 900.0, 60, 0.42, 0.014))
			_add(out, _noise(9, 0.16, 0.003))
		"grab": # a low, short thunk
			_add(out, _tone(260.0, 165.0, 110, 0.50, 0.034))
			_add(out, _tone(520.0, 330.0, 70, 0.14, 0.020))
		"open": # a rising two-partial sweep
			_add(out, _tone(520.0, 880.0, 170, 0.34, 0.07, true))
			_add(out, _tone(1040.0, 1760.0, 170, 0.10, 0.07, true))
		"close": # the same, falling and quicker
			_add(out, _tone(780.0, 430.0, 150, 0.32, 0.06, true))
		"confirm": # two rising notes
			_add(out, _tone(660.0, 660.0, 120, 0.36, 0.045))
			_add(out, _tone(990.0, 990.0, 150, 0.36, 0.055), 0.085)
		"error": # two low falling notes with a slightly rough edge
			_add(out, _tone(330.0, 320.0, 130, 0.30, 0.06, false, 0.35))
			_add(out, _tone(247.0, 235.0, 190, 0.32, 0.08, false, 0.35), 0.12)
	return out


static func _tone(f_start: float, f_end: float, ms: int, amp: float, tau: float, hump: bool = false, rough: float = 0.0) -> PackedFloat32Array:
	## A sine sweep (or, with `rough`, a sine blended with a triangle) with a 3 ms attack and an
	## exponential decay of time-constant `tau` seconds; `hump` swaps the decay for a smooth
	## rise-and-fall envelope (sweeps). The last 6 ms always fade to exactly zero (no click).
	var n := int(RATE * ms / 1000.0)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var u := float(i) / maxf(float(n - 1), 1.0)
		phase += TAU * lerpf(f_start, f_end, u) / RATE
		var s := sin(phase)
		if rough > 0.0:
			var tri := 2.0 * absf(2.0 * (phase / TAU - floorf(phase / TAU + 0.5))) - 1.0
			s = lerpf(s, tri, rough)
		var env := sin(PI * u) if hump else exp(-t / tau)
		env *= minf(t / 0.003, 1.0)
		env *= minf(float(n - 1 - i) / (RATE * 0.006), 1.0)
		out[i] = s * env * amp
	return out


static func _noise(ms: int, amp: float, tau: float) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261001 # fixed: the same sound every run
	var n := int(RATE * ms / 1000.0)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / RATE
		out[i] = rng.randf_range(-1.0, 1.0) * amp * exp(-t / tau) * minf(t / 0.001, 1.0) * minf(float(n - 1 - i) / (RATE * 0.003), 1.0)
	return out


static func _add(into: PackedFloat32Array, layer: PackedFloat32Array, offset_seconds: float = 0.0) -> void:
	var start := int(offset_seconds * RATE)
	if into.size() < start + layer.size():
		into.resize(start + layer.size())
	for i in layer.size():
		into[start + i] += layer[i]
