extends SceneTree
## section_tool.gd's pure logic: no network (this tool never touches the
## backend at all — see its own docstring for why), and no GPU rendering
## needed for any of this (the shader's own actual discard behaviour, which
## DOES need a real render, is checked separately by tests/section_render.gd
## under Xvfb, same "can't verify a real render --headless" split
## gpu_timing.gd already established for this project).
##
## Every Node3D here (the tool nodes themselves, and the plain Node3D hand
## stand-ins) has to actually be inside the SceneTree before global_position/
## global_transform can be read or written on it — same "await process_frame
## after add_child(), before touching its nodes" gotcha tests/README.md
## already documents for tablet_scene.gd's main.tscn instantiation, just
## hitting a bare Node3D here instead of a whole scene. Found the hard way:
## get_root().add_child(x) does NOT make x.is_inside_tree() true within the
## same _initialize() call in a --script SceneTree (unlike a normal running
## scene) — confirmed with a minimal repro. One await up front for
## everything this test ever adds to the tree, since it's all added before
## the first real assertion.
##
## Run: "$GODOT" --headless --path . --script res://tests/section_tool.gd

const SectionTool := preload("res://scripts/section_tool.gd")


func _tagged_mesh_part(name: String, albedo: Color = Color(0.7, 0.7, 0.7, 1.0)) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.name = name
	part.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	part.mesh.surface_set_material(0, mat)
	return part


func _initialize() -> void:
	var tool := SectionTool.new()
	var hand := Node3D.new()
	var stack := preload("res://scripts/command_stack.gd").new()
	var tool2 := SectionTool.new()
	var hand2 := Node3D.new()
	var stack3 := preload("res://scripts/command_stack.gd").new()
	var tool3 := SectionTool.new()
	var hand3 := Node3D.new()
	for n in [tool, hand, tool2, hand2, tool3, hand3]:
		get_root().add_child(n)
	await process_frame

	tool2.setup(stack)
	tool3.setup(stack3)

	# --- inactive by default; grabbing/releasing/reconciling are all no-ops
	print("SMOKE starts inactive: ", tool.active == false)
	print("SMOKE try_grab no-ops while inactive: ", tool.try_grab(hand) == false)

	# --- turning it on spawns a gizmo with no camera given (headless
	# stand-in for the real camera-relative placement popup_keyboard.gd's own
	# _place_in_front_of_camera() uses — see section_tool.gd's _place_in_front_of())
	tool.set_active(true, null)
	print("SMOKE activating spawns a gizmo: ", tool.gizmo() != null)
	print("SMOKE gizmo starts unflipped, normal is its own local -Z: ", tool.effective_normal().is_equal_approx(-tool.gizmo().global_transform.basis.z.normalized()))

	# --- flip negates the effective normal without moving the gizmo
	var gizmo_pos_before: Vector3 = tool.gizmo().global_position
	tool.set_flipped(true)
	print("SMOKE flip negates the normal: ", tool.effective_normal().is_equal_approx(tool.gizmo().global_transform.basis.z.normalized()))
	print("SMOKE flip doesn't move the gizmo: ", tool.gizmo().global_position.is_equal_approx(gizmo_pos_before))
	tool.set_flipped(false)

	# --- grab/drag/release: a hand far away can't grab it...
	hand.global_position = tool.gizmo().global_position + Vector3(0, 0, 5.0)
	print("SMOKE far hand can't grab the gizmo: ", tool.try_grab(hand) == false)

	# --- ...but a hand right at it can, and moving the hand drags the gizmo
	# 1:1 (steadiness off, so no filter lag to account for; hand and gizmo
	# both start with identity rotation here, so the grab offset is exactly
	# identity and the gizmo should track the hand's movement exactly)
	hand.global_position = tool.gizmo().global_position
	var grabbed_at: Vector3 = hand.global_position
	print("SMOKE near hand grabs the gizmo: ", tool.try_grab(hand) == true)
	# --- grabbing sets section_gizmo_held on the hand, so two_hand_model.gd's
	# _hand_free() knows this hand is busy with the gizmo and won't also drag
	# the whole model on the same grip press (see two_hand_model.gd's own
	# _hand_free() docstring for the real-headset bug this meta convention fixes)
	print("SMOKE grabbing sets the section_gizmo_held meta on the hand: ", hand.has_meta("section_gizmo_held") and hand.get_meta("section_gizmo_held") == true)
	print("SMOKE a second hand can't also grab it: ", tool.try_grab(Node3D.new()) == false)
	var drag := Vector3(0.3, 0, 0)
	hand.global_position += drag
	tool.update_held(hand, 0.016, false)
	print("SMOKE dragging the held hand moves the gizmo by the same amount: ", tool.gizmo().global_position.is_equal_approx(grabbed_at + drag))

	# --- release drops it; a different hand's release is a no-op
	print("SMOKE an uninvolved hand's release is a no-op: ", tool.release(Node3D.new()) == false)
	print("SMOKE the holding hand's release succeeds: ", tool.release(hand) == true)
	print("SMOKE released hand can't release again: ", tool.release(hand) == false)
	print("SMOKE releasing clears the section_gizmo_held meta: ", hand.get_meta("section_gizmo_held") == false)

	# --- undo/redo: one command per grab/drag gesture, mirroring
	# two_hand_model.gd's own _begin_gesture()/_end_gesture() precedent
	tool2.set_active(true, null)
	var start_pos: Vector3 = tool2.gizmo().global_position
	hand2.global_position = start_pos
	tool2.try_grab(hand2)
	hand2.global_position += Vector3(0, 0.5, 0)
	tool2.update_held(hand2, 0.016, false)
	tool2.release(hand2)
	print("SMOKE a real drag pushes one undo command: ", stack.can_undo())
	var moved_pos: Vector3 = tool2.gizmo().global_position
	stack.undo()
	print("SMOKE undo restores the plane's earlier position: ", tool2.gizmo().global_position.is_equal_approx(start_pos))
	stack.redo()
	print("SMOKE redo reapplies the move: ", tool2.gizmo().global_position.is_equal_approx(moved_pos))

	# --- a grab/release with no net movement pushes nothing (same "no-op
	# gesture" precedent as controller.gd's own _push_move_command())
	tool3.set_active(true, null)
	hand3.global_position = tool3.gizmo().global_position
	tool3.try_grab(hand3)
	tool3.release(hand3)
	print("SMOKE a no-op grab+release pushes nothing: ", stack3.can_undo() == false)

	# --- deactivating while still gripping the gizmo (never calling
	# release()) must still clear section_gizmo_held, or that hand would be
	# permanently locked out of whole-model dragging — the bug caught by
	# re-reading set_active()'s own deactivate branch during this round's fix
	tool3.try_grab(hand3)
	print("SMOKE re-grabbing sets the meta again: ", hand3.get_meta("section_gizmo_held") == true)
	tool3.set_active(false)
	print("SMOKE deactivating mid-grab clears the meta: ", hand3.get_meta("section_gizmo_held") == false)

	# --- reconcile(): wraps a fresh part, preserving its own albedo, and
	# leaves an already-wrapped, untouched part alone (no needless rebuild)
	var part_a := _tagged_mesh_part("PartA", Color(0.2, 0.6, 0.9, 1.0))
	tool.reconcile([part_a])
	print("SMOKE reconcile wraps an unwrapped part: ", part_a.material_override is ShaderMaterial)
	print("SMOKE the wrap preserves the part's own albedo: ", (part_a.material_override as ShaderMaterial).get_shader_parameter("albedo_color").is_equal_approx(Color(0.2, 0.6, 0.9, 1.0)))
	var wrapped_ref: Material = part_a.material_override
	tool.reconcile([part_a])
	print("SMOKE an already-wrapped, untouched part isn't rebuilt: ", part_a.material_override == wrapped_ref)

	# --- reconcile() picks up a colour_tool.gd-style change made while active
	# (the real design problem this tool works around — see its own
	# docstring's "colour_tool.gd already owns material_override" paragraph)
	var flat := StandardMaterial3D.new()
	flat.albedo_color = Color(1.0, 0.0, 0.0, 1.0)
	part_a.material_override = flat # simulates colour_tool.gd's own _apply_local_color()
	tool.reconcile([part_a])
	print("SMOKE a colour change made while active gets re-wrapped: ", part_a.material_override is ShaderMaterial and part_a.material_override != wrapped_ref)
	print("SMOKE the re-wrap picks up the NEW colour: ", (part_a.material_override as ShaderMaterial).get_shader_parameter("albedo_color").is_equal_approx(Color(1.0, 0.0, 0.0, 1.0)))

	# --- turning the tool off restores exactly what was there before wrapping
	tool.set_active(false)
	print("SMOKE deactivating restores the pre-wrap material_override: ", part_a.material_override == flat)
	print("SMOKE deactivating drops the gizmo: ", tool.gizmo() == null)

	# --- a part that was never touched by colour_tool (material_override
	# null) unwraps back to null, not to some placeholder
	var part_b := _tagged_mesh_part("PartB")
	tool.set_active(true, null)
	tool.reconcile([part_b])
	print("SMOKE an untouched part's own glTF-style albedo is read correctly: ", (part_b.material_override as ShaderMaterial).get_shader_parameter("albedo_color").is_equal_approx(Color(0.7, 0.7, 0.7, 1.0)))
	tool.set_active(false)
	print("SMOKE it unwraps back to null (no override at all), not a placeholder: ", part_b.material_override == null)

	# --- reset() (called on model reload, before the old parts are freed)
	# clears tracking without touching active/gizmo state — mirrors
	# mates_tool_active staying on across a reload
	tool.set_active(true, null)
	tool.reconcile([part_b])
	tool.reset()
	print("SMOKE reset() leaves the tool active: ", tool.active == true)
	print("SMOKE reset() leaves the gizmo in place: ", tool.gizmo() != null)
	tool.reconcile([part_b])
	print("SMOKE reconcile() re-wraps cleanly after reset(): ", part_b.material_override is ShaderMaterial)

	for n in [part_a, part_b]:
		n.free()
	tool.set_active(false)
	for n in [tool, hand, tool2, hand2, tool3, hand3]:
		n.free()
	# stack/stack3 are command_stack.gd (extends RefCounted) — RefCounted
	# frees itself when unreferenced, not via .free() (that errors, and the
	# error was silently swallowing this test's own quit() call below).
	quit()
