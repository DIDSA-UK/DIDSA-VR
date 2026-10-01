extends RefCounted
## One place for the UI's haptic pulses and sounds, so intensity, an Off switch and (later)
## sound assets are changed in one spot instead of per call site. Static, no autoload and no
## scene-tree dependency: `--headless --script` tests (this repo's only runner) have no
## autoloads, and every caller already has the hand it wants to buzz.
##
##   UiFeedback.haptic(right_hand, "press")
##   UiFeedback.play("press", some_node3d)      # silent until a stream is registered
##
## Sounds are synthesised in code by ui_sounds.gd and registered at startup (main.gd);
## Settings > Comfort has Sound on/off and Volume.
##
## Events: hover (a very light tick as the laser crosses a button), press, grab (a panel
## handle), open, close, confirm, error. Sounds are deliberately NOT shipped yet: the plan keeps
## third-party and generated audio for the look-dev stage, where it can be tried by ear in the
## UI Lab first. Replace one with set_sound("press", load("res://.../click.ogg")) and every
## call site already plays it.

const _HAPTIC := { ## event -> [amplitude 0..1, seconds] at the Normal level
	"hover": [0.10, 0.012],
	"press": [0.40, 0.05],
	"grab": [0.40, 0.05],
	"open": [0.60, 0.08],
	"close": [0.35, 0.05],
	"confirm": [0.50, 0.07],
	"error": [0.80, 0.15],
}
const HAPTIC_LEVELS: Array[String] = ["Off", "Low", "Normal", "High"]
const _HAPTIC_SCALE := [0.0, 0.5, 1.0, 1.5]

static var haptics_level := 2 ## index into HAPTIC_LEVELS
static var reduce_motion := false ## honoured by DidsaUITheme.duration() and every animation
static var sound_enabled := true
static var volume := 0.7 ## linear 0..1 (Settings > Volume)
const MIN_INTERVAL_MS := 35 ## the same event can't retrigger faster than this (a laser sweeping a button row)
const MAX_VOICES := 8
static var _streams := {}
static var _last_ms := {}
static var _voices := 0


static func set_haptics_level(level: int) -> void:
	haptics_level = clampi(level, 0, HAPTIC_LEVELS.size() - 1)


static func haptic_scale() -> float:
	return _HAPTIC_SCALE[haptics_level]


static func haptic(hand: Object, event: String) -> void:
	if hand == null or not is_instance_valid(hand) or not _HAPTIC.has(event):
		return
	var scale := haptic_scale()
	if scale <= 0.0:
		return
	var spec: Array = _HAPTIC[event]
	hand.trigger_haptic_pulse("haptic", 0.0, clampf(float(spec[0]) * scale, 0.0, 1.0), float(spec[1]), 0.0)


static func set_sound(event: String, stream: AudioStream) -> void:
	if stream == null:
		_streams.erase(event)
	else:
		_streams[event] = stream


static func has_sound(event: String) -> bool:
	return _streams.has(event)


static func play(event: String, at: Node3D) -> void:
	## Plays the registered stream for `event` at `at`'s position; does nothing if sound is off,
	## the volume is 0, there's no stream, or the event just played / too many are sounding.
	if not sound_enabled or volume <= 0.001 or not _streams.has(event) or at == null or not is_instance_valid(at) or not at.is_inside_tree():
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_ms.get(event, -100000)) < MIN_INTERVAL_MS or _voices >= MAX_VOICES:
		return
	_last_ms[event] = now
	var player := AudioStreamPlayer3D.new()
	player.stream = _streams[event]
	player.volume_db = linear_to_db(volume)
	player.max_distance = 0.0
	player.finished.connect(func() -> void:
		_voices -= 1
		player.queue_free()
	)
	# Parented to the scene root (not `at`) so a window that closes — and frees itself — doesn't cut its own close sound.
	var tree := at.get_tree()
	tree.root.add_child(player)
	player.global_position = at.global_position
	_voices += 1
	player.play()


static func set_sound_enabled(on: bool) -> void:
	sound_enabled = on


static func set_volume(linear: float) -> void:
	volume = clampf(linear, 0.0, 1.0)
