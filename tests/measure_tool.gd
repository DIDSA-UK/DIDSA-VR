extends SceneTree
## measure_tool.gd's pure logic (pick validation - deliberately looser than
## mates_tool.gd's own, see that script's docstring for why root content and
## same-occurrence picks are both valid Measure targets) - no real backend
## needed: `backend_url`/`api_key` are left unconfigured (both default ""),
## so `_run_measure()`'s own `_api_request()` call fails synchronously at
## `HTTPRequest.request()`'s own URL-parse step (a relative, host-less URL)
## with no real network round trip and no suspension - the same "runs to
## completion in one synchronous call, no tree/backend needed" property
## mates_tool.gd's own test relies on for its (never-awaited) network-
## touching paths. Confirmed empirically, not just reasoned about: this test
## finishes and calls quit() rather than hanging on an unawaited await.
## The real end-to-end network path (a genuine measurement result) is
## e2e_measure.gd, same split as mates_tool.gd/e2e_mates.gd.
## Run: "$GODOT" --headless --path . --script res://tests/measure_tool.gd

const MeasureTool := preload("res://scripts/measure_tool.gd")


func _tagged_part(owner_part_id: String, occurrence_id: String, body_id: String, face_ids: Array, name: String) -> Node3D:
	var part := Node3D.new()
	part.name = name
	part.set_meta("owner_part_id", owner_part_id)
	part.set_meta("occurrence_id", occurrence_id)
	part.set_meta("face_ids", face_ids)
	part.set_meta("body_ids", _repeat(body_id, face_ids.size()))
	return part


func _repeat(value: String, count: int) -> Array:
	var out := []
	for _i in count:
		out.append(value)
	return out


func _initialize() -> void:
	var tool := MeasureTool.new()
	tool.set_active(true) # try_pick() is a no-op entirely while inactive - see the dedicated check near the end

	# --- a part with no face identity at all (e.g. a bare local .glb) is rejected
	var untagged := Node3D.new()
	tool.try_pick(untagged, 0)
	print("SMOKE untagged part pick rejected: ", tool.status_text().begins_with("This part has no backend identity"))
	print("SMOKE nothing left busy after a synchronous no-backend attempt: ", not tool.is_busy())

	# --- root content (occurrence_id "") IS a valid Measure target, unlike
	# Mates - a valid pick always triggers _run_measure() (see try_pick()'s
	# own docstring), which in this no-backend test environment fails fast
	# and synchronously (empty backend_url -> request_raw()'s own
	# !is_inside_tree() guard, confirmed by the harness rather than assumed -
	# see this file's own top docstring), overwriting status_text() with
	# that failure rather than the optimistic "pick a second entity" prompt;
	# is_busy() correctly settling back to false either way is the real
	# behaviour worth asserting here, not the exact wording of a message
	# that's about to be overwritten by a real (if instantly-failing) call.
	var root_content := _tagged_part("part-root", "", "body-1", [0, 1], "RootContent")
	tool.try_pick(root_content, 0)
	print("SMOKE root content pick accepted: ", tool.picked_labels() == ["RootContent"])
	print("SMOKE failed measure attempt surfaces its own error, not left busy: ", tool.status_text().begins_with("Couldn't measure") and not tool.is_busy())
	tool.clear_picks()

	# --- a valid first pick
	var part_a := _tagged_part("part-root", "occ-a", "body-a", [0, 1, 2], "Bracket")
	tool.try_pick(part_a, 1)
	print("SMOKE first valid pick recorded: ", tool.picked_labels() == ["Bracket"])

	# --- a second pick on the SAME occurrence is accepted, unlike Mates
	# (measuring across two features of one part is the common case)
	var part_a_again := _tagged_part("part-root", "occ-a", "body-a", [0, 1, 2], "Bracket")
	tool.try_pick(part_a_again, 2)
	print("SMOKE same-occurrence second pick accepted: ", tool.picked_labels() == ["Bracket", "Bracket"])
	tool.clear_picks()

	# --- a part from a different assembly (different owner_part_id) is rejected
	tool.try_pick(part_a, 1)
	var other_assembly := _tagged_part("part-OTHER-root", "occ-x", "body-x", [0], "Elsewhere")
	tool.try_pick(other_assembly, 0)
	print("SMOKE cross-assembly pick rejected: ", tool.picked_labels().size() == 1 and tool.status_text().begins_with("Both entities must belong"))

	# --- a valid second pick completes the pair
	var part_b := _tagged_part("part-root", "occ-b", "body-b", [0, 1], "Bolt")
	tool.try_pick(part_b, 0)
	print("SMOKE second valid pick completes the pair: ", tool.picked_labels() == ["Bracket", "Bolt"])

	# --- a third pick starts a fresh measurement instead of being ignored
	# (unlike Mates' cap-at-2-and-ignore - Measure is for picking through
	# several things in a row)
	var part_c := _tagged_part("part-root", "occ-c", "body-c", [0], "Washer")
	tool.try_pick(part_c, 0)
	print("SMOKE third pick starts fresh, not ignored: ", tool.picked_labels() == ["Washer"])

	# --- clear_picks resets everything, including any stale result
	tool.clear_picks()
	print("SMOKE clear_picks empties the picks: ", tool.picked_labels().is_empty())
	print("SMOKE clear_picks empties the result: ", tool.result.is_empty())
	print("SMOKE status resets to the first-pick prompt: ", tool.status_text().begins_with("Pick a vertex"))

	# --- deactivating the tool also clears picks
	tool.try_pick(part_a, 1)
	tool.set_active(false)
	print("SMOKE deactivating clears any in-progress pick: ", tool.picked_labels().is_empty())

	# --- while inactive, a trigger pull is a no-op (controller.gd only calls
	# try_pick while measure_tool_active is true, but try_pick itself is also
	# defensive about it directly)
	tool.try_pick(part_a, 1)
	print("SMOKE try_pick no-ops while inactive: ", tool.picked_labels().is_empty())

	for n in [untagged, root_content, part_a, part_a_again, other_assembly, part_b, part_c]:
		n.free()
	tool.free()
	quit()
