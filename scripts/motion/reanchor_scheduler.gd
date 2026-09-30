extends RefCounted
## Re-anchor policy, anchor acceptance and the "can't follow" cue (DIDSA-CAD
## docs/motion/projector-spec.md §7, §8, §11) with an INJECTED clock (a Callable
## returning milliseconds) so it is testable without real time.

const Se3 := preload("res://scripts/motion/se3.gd")

const REANCHOR_MS := 150.0
const REANCHOR_MS_NEAR_SINGULAR := 75.0
const SIGMA_GAP_LOW := 100.0 ## sigma_gap below this halves the interval (uncalibrated placeholder)
const MISSES_BEFORE_CUE := 3
const CUE_THROTTLE_MS := 1000.0
const RESIDUAL_TOL := 1e-6
const JUMP_REJECT_FACTOR := 1.0


## The pure re-anchor decision (what the golden vectors pin). max_step / sigma_gap may be null. Returns {"reanchor", "reason"}.
static func needs_reanchor(now_ms: float, anchor_ms: float, travel: float, max_step, sigma_gap, in_flight: bool) -> Dictionary:
	if in_flight:
		return {"reanchor": false, "reason": "in_flight"}
	var near_singular: bool = sigma_gap != null and float(sigma_gap) < SIGMA_GAP_LOW
	var interval := REANCHOR_MS_NEAR_SINGULAR if near_singular else REANCHOR_MS
	if now_ms - anchor_ms >= interval:
		return {"reanchor": true, "reason": "time_near_singular" if near_singular else "time"}
	if max_step != null and travel >= float(max_step):
		return {"reanchor": true, "reason": "distance"}
	return {"reanchor": false, "reason": "none"}


## Anchor acceptance (spec §7). `anchor_grabbed` = members[0].transform pose, `own_projection` = what the CURRENT model projects the SAME wish to
## (null for the very first anchor). residual_inf may be null. quality.jump from the wire is telemetry and never used here.
## Returns {"accept", "reason" ("ok" | "not_converged" | "residual" | "jump"), "client_jump" (float or null)}.
static func accept_anchor(converged: bool, residual_inf, anchor_grabbed, own_projection, lever: float) -> Dictionary:
	if not converged:
		return {"accept": false, "reason": "not_converged", "client_jump": null}
	if residual_inf == null or float(residual_inf) > RESIDUAL_TOL:
		return {"accept": false, "reason": "residual", "client_jump": null}
	var jump = null
	if own_projection != null and anchor_grabbed != null:
		jump = Se3.weighted_dist(anchor_grabbed, own_projection, lever)
		if jump > JUMP_REJECT_FACTOR * lever:
			return {"accept": false, "reason": "jump", "client_jump": jump}
	return {"accept": true, "reason": "ok", "client_jump": jump}


var _now: Callable
var in_flight := false
var anchor_ms := 0.0 ## SEND time of the request whose response was last accepted
var consecutive_misses := 0
var _pending_sent_ms := 0.0
var _max_step = null
var _sigma_gap = null
var _last_cue_ms = null


func _init(now_ms: Callable) -> void:
	_now = now_ms


func reset() -> void:
	in_flight = false
	anchor_ms = 0.0
	_max_step = null
	_sigma_gap = null
	consecutive_misses = 0
	_last_cue_ms = null


## Should a request go out now? `travel` = projector.travel(shown grabbed).
func check(travel: float) -> Dictionary:
	return needs_reanchor(float(_now.call()), anchor_ms, travel, _max_step, _sigma_gap, in_flight)


## Call when a request is sent. Returns false (and does nothing) if one is already in flight.
func on_request_sent() -> bool:
	if in_flight:
		return false
	in_flight = true
	_pending_sent_ms = float(_now.call())
	return true


## The in-flight request's response was accepted: its SEND time becomes t_anchor.
func on_accepted(max_step = null, sigma_gap = null) -> void:
	in_flight = false
	anchor_ms = _pending_sent_ms
	_max_step = max_step
	_sigma_gap = sigma_gap
	consecutive_misses = 0


## Rejected anchor, converged:false, or a transport error: a miss that does NOT restart the timer.
func on_miss() -> void:
	in_flight = false
	consecutive_misses += 1


## Drop the in-flight token (release): its response must be ignored by the caller.
func invalidate() -> void:
	in_flight = false


## True at most once per CUE_THROTTLE_MS while MISSES_BEFORE_CUE or more misses are pending (spec §11).
func take_cue() -> bool:
	if consecutive_misses < MISSES_BEFORE_CUE:
		return false
	var now := float(_now.call())
	if _last_cue_ms != null and now - float(_last_cue_ms) < CUE_THROTTLE_MS:
		return false
	_last_cue_ms = now
	return true
