extends SceneTree
## mates_tool.gd's pure logic (pick validation, payload building) - no
## network needed for any of this, so it's tested directly against
## manually-tagged Node3D stand-ins (set_meta, the same convention
## mesh_identity.gd's tag_scene() itself uses) rather than a real loaded
## model. The network-touching half (create/list/delete/solve against a
## real backend) is tests/e2e_mates.gd, same split as e2e_backend.gd/
## e2e_step_import.gd for the rest of this project.
## Run: "$GODOT" --headless --path . --script res://tests/mates_tool.gd

const MatesTool := preload("res://scripts/mates_tool.gd")


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
	var tool := MatesTool.new()
	tool.set_active(true) # try_pick() is a no-op entirely while inactive - see the dedicated check near the end

	# --- root content (occurrence_id "") is never mateable
	var root_content := _tagged_part("part-a", "", "body-1", [0, 1], "RootContent")
	tool.try_pick(root_content, 0)
	print("SMOKE root content pick rejected: ", tool.status_text().begins_with("Can't mate the assembly's own root content"))

	# --- a part with no face identity (e.g. a bare local .glb) is rejected
	var untagged := Node3D.new()
	tool.try_pick(untagged, 0)
	print("SMOKE untagged part pick rejected: ", tool.status_text().begins_with("This part has no backend identity"))

	# --- a valid first pick
	var part_a := _tagged_part("part-root", "occ-a", "body-a", [0, 1, 2], "Bracket")
	tool.try_pick(part_a, 1)
	print("SMOKE first valid pick recorded: ", tool.picked_labels() == ["Bracket"])
	print("SMOKE status asks for the second pick: ", tool.status_text().begins_with("Pick a face, edge or corner on the second"))
	print("SMOKE can't create with only one pick: ", tool.can_create() == false)

	# --- picking the same part again is rejected, doesn't add a second pick
	tool.try_pick(part_a, 1)
	print("SMOKE same-part-twice rejected: ", tool.picked_labels().size() == 1 and tool.status_text().begins_with("Pick two different parts"))

	# --- a part from a different assembly (different owner_part_id) is rejected
	var other_assembly := _tagged_part("part-OTHER-root", "occ-x", "body-x", [0], "Elsewhere")
	tool.try_pick(other_assembly, 0)
	print("SMOKE cross-assembly pick rejected: ", tool.picked_labels().size() == 1 and tool.status_text().begins_with("Both parts must belong"))

	# --- a valid second pick completes the pair
	var part_b := _tagged_part("part-root", "occ-b", "body-b", [0, 1], "Bolt")
	tool.try_pick(part_b, 0)
	print("SMOKE second valid pick completes the pair: ", tool.picked_labels() == ["Bracket", "Bolt"])
	print("SMOKE ready to create: ", tool.can_create() == true)
	print("SMOKE status shows ready: ", tool.status_text().begins_with("Ready"))

	# --- a third pick is ignored once full
	var part_c := _tagged_part("part-root", "occ-c", "body-c", [0], "Washer")
	tool.try_pick(part_c, 0)
	print("SMOKE third pick ignored once full: ", tool.picked_labels().size() == 2)

	# --- payload shape for a value-less type (coincident)
	tool.mate_type = "coincident"
	tool.mate_allow_rotation = false
	tool.mate_alignment = "aligned"
	tool.mate_secondary_flip = 1
	var payload: Dictionary = tool.build_create_payload()
	var expected_refs := [
		{"occurrence_id": "occ-a", "subshape_ref": {"body_id": "body-a", "shape_type": "face", "index": 1}},
		{"occurrence_id": "occ-b", "subshape_ref": {"body_id": "body-b", "shape_type": "face", "index": 0}},
	]
	print("SMOKE coincident payload references match exactly: ", payload["references"] == expected_refs)
	print("SMOKE coincident payload carries the named branch and allow_rotation: ", payload["alignment"] == "aligned" and payload["secondary_flip"] == true and payload["allow_rotation"] == false and not payload.has("flipped"))
	print("SMOKE coincident payload omits value entirely: ", not payload.has("value"))

	# --- payload shape for a value type (distance)
	tool.mate_type = "distance"
	tool.mate_value = 12.5
	var distance_payload: Dictionary = tool.build_create_payload()
	print("SMOKE distance payload includes the real value: ", distance_payload.get("value") == 12.5)

	# --- clear_picks resets everything
	tool.clear_picks()
	print("SMOKE clear_picks empties the pair: ", tool.picked_labels().is_empty())
	print("SMOKE status resets to the first-pick prompt: ", tool.status_text().begins_with("Pick a face, edge or corner on the first"))

	# --- deactivating the tool also clears picks
	tool.try_pick(part_a, 1)
	tool.set_active(false)
	print("SMOKE deactivating clears any in-progress pick: ", tool.picked_labels().is_empty())

	# --- while inactive, a trigger pull is a no-op (controller.gd only calls
	# try_pick while mates_tool_active is true, but try_pick itself is also
	# defensive about it directly)
	tool.try_pick(part_a, 1)
	print("SMOKE try_pick no-ops while inactive: ", tool.picked_labels().is_empty())

	# --- movement mode: Minimal movement (default) is the backend's `auto`, off is `group` (the flat client's _mateMovement)
	print("SMOKE minimal movement is on by default and means auto: ", tool.mate_minimal_movement and tool.movement_param() == "auto")
	tool.mate_minimal_movement = false
	print("SMOKE minimal movement off means group: ", tool.movement_param() == "group")
	tool.mate_minimal_movement = true

	# --- preview members: every part the preview moves (driven first), or just the driven one from an older backend's `transform`
	var pose_a := {"translation": [1.0, 2.0, 3.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}
	var pose_b := {"translation": [9.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}
	var grouped: Array = MatesTool.preview_members({"converged": true, "transform": pose_a, "members": [{"occurrence_id": "occ-b", "transform": pose_a}, {"occurrence_id": "occ-c", "transform": pose_b}]}, "occ-b")
	print("SMOKE preview lists the driven part and the follower: ", grouped.size() == 2 and grouped[0]["occurrence_id"] == "occ-b" and grouped[1]["occurrence_id"] == "occ-c" and grouped[1]["transform"] == pose_b)
	var legacy: Array = MatesTool.preview_members({"converged": true, "transform": pose_a}, "occ-b")
	print("SMOKE preview without members falls back to the driven part: ", legacy.size() == 1 and legacy[0]["occurrence_id"] == "occ-b" and legacy[0]["transform"] == pose_a)
	print("SMOKE an unconverged preview moves nothing: ", MatesTool.preview_members({"converged": false, "transform": null, "members": []}, "occ-b").is_empty())

	# --- atomic create/edit query
	print("SMOKE atomic query names the movement and the driven occurrence: ", MatesTool.atomic_query("auto", "occ b") == "solve=auto&occurrence_id=occ%20b")

	# --- branch search (Phase 2b): the preview's branch_changes are named, confirmed without `from`, and sent only with Create
	var known_mates := [{"id": "m1", "type": "distance"}, {"id": "m2", "type": "angle"}]
	var flip := {"mate_id": "m1", "field": "secondary_flip", "from": false, "to": true}
	var one_notice := MatesTool.branch_notice([flip], [], [], known_mates)
	print("SMOKE branch notice names the one earlier mate that moves: ", one_notice.contains("Distance mate") and one_notice.contains("Create applies it"))
	var two_notice := MatesTool.branch_notice([flip, {"mate_id": "m1", "field": "alignment", "from": "aligned", "to": "anti_aligned"}, {"mate_id": "m2", "field": "secondary_flip", "from": true, "to": false}], [], [], known_mates)
	print("SMOKE branch notice counts each mate once: ", two_notice.contains("2 earlier mates") and two_notice.contains("Distance mate, Angle mate"))
	print("SMOKE branch notice for a user-set mate in the way and for a conflict: ", MatesTool.branch_notice([], ["m1"], [], known_mates).contains("you set") and MatesTool.branch_notice([], [], ["m2"], known_mates).contains("conflicts"))
	print("SMOKE branch notice is empty with nothing to say and falls back to a mate: ", MatesTool.branch_notice([], [], [], known_mates) == "" and MatesTool.branch_notice([flip], [], [], []).contains("a mate"))
	var confirmed: Array = MatesTool.confirmed_changes([flip])
	print("SMOKE confirmed changes drop `from`: ", confirmed == [{"mate_id": "m1", "field": "secondary_flip", "to": true}])
	print("SMOKE the create payload carries no branch_changes unless confirming one: ", not tool.build_create_payload().has("branch_changes") and not tool.build_create_payload(true).has("branch_changes"))

	# --- Phase 3: branch controls from the preview, Next solution, and what is sent
	var alts := [
		{"alignment": "anti_aligned", "secondary_flip": true, "members": [], "movement_cost": 1.0},
		{"alignment": "anti_aligned", "secondary_flip": false, "members": [], "movement_cost": 2.0},
		{"alignment": "aligned", "secondary_flip": true, "members": [], "movement_cost": 3.0},
	]
	print("SMOKE the flip label says what the flag means: ", MatesTool.secondary_flip_label("distance") == "Flip side" and MatesTool.secondary_flip_label("concentric") == "Flip spin" and MatesTool.secondary_flip_label("angle") == "Supplement")
	var both := ["alignment", "secondary_flip"]
	var resolved := {"alignment": "anti_aligned", "secondary_flip": true}
	print("SMOKE the shown branch is the choice, else the resolved value, and nothing for a control the geometry lacks: ",
		MatesTool.effective_alignment(both, "", resolved) == "anti_aligned" and MatesTool.effective_alignment(both, "aligned", resolved) == "aligned" and MatesTool.effective_alignment(["secondary_flip"], "", resolved) == "" and
		MatesTool.effective_secondary_flip(both, -1, resolved) == 1 and MatesTool.effective_secondary_flip(both, 0, resolved) == 0 and MatesTool.effective_secondary_flip(["alignment"], -1, resolved) == -1)
	print("SMOKE the shown placement is found among the alternatives: ", MatesTool.alternative_index(alts, "aligned", 1) == 2 and MatesTool.alternative_index(alts, "aligned", 0) == -1)
	print("SMOKE Next solution steps, wraps, starts at the nearest when nothing matches, and needs two: ",
		MatesTool.next_alternative(alts, "anti_aligned", 1)["secondary_flip"] == false and MatesTool.next_alternative(alts, "aligned", 1)["alignment"] == "anti_aligned" and
		MatesTool.next_alternative(alts, "aligned", 0)["secondary_flip"] == true and MatesTool.next_alternative([alts[0]], "anti_aligned", 1).is_empty() and MatesTool.next_alternative([], "", -1).is_empty())
	print("SMOKE an ANGLE's alignment is the swing direction (+ / -), everything else Aligned / Anti-aligned: ", MatesTool.alignment_title("angle") == "Swing" and MatesTool.alignment_label("angle", "aligned") == "+" and MatesTool.alignment_label("angle", "anti_aligned") == "-" and MatesTool.alignment_title("distance") == "Orientation" and MatesTool.alignment_label("distance", "anti_aligned") == "Anti-aligned")
	tool.reset_branch_choice()
	tool.mate_type = "distance"
	tool.branch_controls = both
	tool.branch_resolved = resolved
	tool.branch_alternatives = alts
	print("SMOKE the branch line shows auto values and the solution number: ", tool.branch_text() == "Anti-aligned (auto) · Flip side: on (auto) · solution 1 of 3")
	print("SMOKE with nothing picked the payload names no branch (Closest): ", not tool.build_create_payload().has("alignment") and not tool.build_create_payload().has("secondary_flip"))
	tool.toggle_alignment()
	print("SMOKE toggling the orientation names the other one: ", tool.mate_alignment == "aligned" and tool.build_create_payload()["alignment"] == "aligned" and not tool.build_create_payload().has("secondary_flip"))
	tool.toggle_secondary_flip()
	print("SMOKE toggling the side names the other one: ", tool.mate_secondary_flip == 0 and tool.build_create_payload()["secondary_flip"] == false)
	# aligned + side off is not among the alternatives, so the next one is the nearest: anti-aligned + side on
	var stepped: bool = tool.next_solution()
	print("SMOKE Next solution names both fields of the next placement: ", stepped and tool.mate_alignment == "anti_aligned" and tool.mate_secondary_flip == 1)
	tool.branch_controls = ["secondary_flip"]
	tool.flip_mate()
	print("SMOKE the wheel's Flip turns the side when there is no orientation: ", tool.mate_secondary_flip == 0 and tool.mate_alignment == "anti_aligned")
	tool.mate_type = "angle"
	print("SMOKE another mate type goes back to Closest: ", tool.mate_alignment == "" and tool.mate_secondary_flip == -1)
	tool.branch_controls = []
	tool.branch_resolved = {}
	tool.branch_alternatives = []
	print("SMOKE no controls means no branch line and no Next solution: ", tool.branch_text() == "" and not tool.next_solution())

	for n in [root_content, untagged, part_a, other_assembly, part_b, part_c]:
		n.free()
	tool.free()
	quit()
