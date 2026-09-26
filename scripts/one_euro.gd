extends RefCounted
## "One Euro" filter for a Vector3 (Casiez et al.): the standard answer to
## "steady when I hold still, but not laggy when I move".
##
## A plain low-pass filter has to choose: smooth enough to hide hand tremor
## means visibly lagging every deliberate move. This one changes its own
## strength with speed: when the signal is nearly still it smooths hard (the
## cutoff drops to min_cutoff, killing the few-mm shake of a held hand); as it
## speeds up the cutoff rises (by `beta` Hz per m/s) so the output keeps up and
## fast moves feel direct.
##
##   min_cutoff  Hz. Lower = steadier when still, but slower to settle. ~0.8-3.
##   beta        Hz per (m/s). Higher = less lag when moving, but lets more
##               shake through at speed. ~5-20 for hands measured in metres.
##   d_cutoff    Hz, smoothing of the speed estimate itself.

var min_cutoff := 1.5
var beta := 10.0
var d_cutoff := 1.0

var _has_previous := false
var _x_hat := Vector3.ZERO
var _dx_hat := Vector3.ZERO


func reset(value: Vector3) -> void:
	## Start from `value` with no history (call when a gesture begins).
	_has_previous = true
	_x_hat = value
	_dx_hat = Vector3.ZERO


func filter(value: Vector3, delta: float) -> Vector3:
	if not _has_previous or delta <= 0.0:
		reset(value)
		return value
	var speed_estimate := (value - _x_hat) / delta
	_dx_hat = _dx_hat.lerp(speed_estimate, _alpha(d_cutoff, delta))
	var cutoff := min_cutoff + beta * _dx_hat.length()
	_x_hat = _x_hat.lerp(value, _alpha(cutoff, delta))
	return _x_hat


func _alpha(cutoff: float, delta: float) -> float:
	var tau := 1.0 / (TAU * cutoff)
	return 1.0 / (1.0 + tau / delta)
