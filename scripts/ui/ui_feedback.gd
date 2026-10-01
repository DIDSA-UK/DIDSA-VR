extends RefCounted
## One place for the UI's haptic pulses and sounds, so intensity, an Off switch and (later)
## sound assets are changed in one spot instead of per call site. Static, no autoload and no
## scene-tree dependency: `--headless --script` tests (this repo's only runner) have no
## autoloads, and every caller already has the hand it wants to buzz.
##
##   UiFeedback.haptic(right_hand, "press")
##   UiFeedback.play("press", some_node3d)      # silent until a stream is registered
##
## Events: hover (a very light tick as the laser crosses a button), press, grab (a panel
## handle), open, close, confirm, error. Sounds are deliberately NOT shipped yet: the plan keeps
## third-party and generated audio for the look-dev stage, where it can be tried by ear in the
## UI Lab first. Register one with set_sound("press", load("res://.../click.ogg")) and every
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
static var volume_db := 0.0
static var _streams := {}


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
	## Plays the registered stream for `event` at `at`; does nothing if there isn't one.
	if not _streams.has(event) or at == null or not at.is_inside_tree():
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = _streams[event]
	player.volume_db = volume_db
	player.finished.connect(player.queue_free)
	at.add_child(player)
	player.play()
