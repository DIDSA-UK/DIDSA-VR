extends SceneTree
## The clip shader's copy of a part's look (scripts/clip_look.gd), as the section tool and the Assembly Room clip put it on parts,
## headless: a one-look part keeps its whole look in the wrap (colour with opacity, metal, shine, glow; a see-through look gets the
## alpha variant); a part split by appearance (the real backend glb tests/fixtures/appearance_split.glb, two surfaces) is wrapped
## surface by surface so each body keeps its look; the room clip and the section tool wrap, adopt and give it back.
## Run: "$GODOT" --headless --path . --script res://tests/clip_look.gd

const ClipLook := preload("res://scripts/clip_look.gd")
const RoomClip := preload("res://scripts/room/room_clip.gd")
const SectionTool := preload("res://scripts/section_tool.gd")
const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const Look := preload("res://scripts/appearance/appearance_look.gd")

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _split_part() -> MeshInstance3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_buffer(FileAccess.get_file_as_bytes("res://tests/fixtures/appearance_split.glb"), "", state)
	var scene := doc.generate_scene(state)
	MeshIdentity.tag_scene(state, scene)
	root.add_child(scene)
	return scene.get_child(0) as MeshInstance3D


func _param(m: Material, name: String):
	return (m as ShaderMaterial).get_shader_parameter(name)


func _initialize() -> void:
	await process_frame
	# --- one look: the whole look goes into the clip material
	var metal := Look.material_for({"colour": "#3498DB", "metallic": 0.9, "roughness": 0.2, "emission_strength": 3.0})
	var wrap := ClipLook.clip_for(metal)
	_check(wrap.shader == ClipLook.ClipShader and (_param(wrap, "albedo_color") as Color).is_equal_approx(Color.html("#3498DB")), "a one-look wrap keeps the colour (opaque clip shader)")
	_check(is_equal_approx(_param(wrap, "metallic"), 0.9) and is_equal_approx(_param(wrap, "roughness"), 0.2), "...and metal and shine")
	_check(is_equal_approx(_param(wrap, "emission_energy"), 3.0) and (_param(wrap, "emission_color") as Color).is_equal_approx(Color.html("#3498DB")), "...and the glow")
	var glass := ClipLook.clip_for(Look.material_for({"colour": "#F5F5F5", "opacity": 0.25}))
	_check(glass.shader == ClipLook.ClipShaderAlpha and is_equal_approx((_param(glass, "albedo_color") as Color).a, 0.25), "a see-through look gets the alpha clip shader with its opacity")
	_check(ClipLook.is_clip(wrap) and ClipLook.is_clip(glass) and not ClipLook.is_clip(metal), "both clip shaders count as the clip")
	var bare := ClipLook.clip_for(null)
	_check((_param(bare, "albedo_color") as Color).is_equal_approx(ClipLook.DEFAULT_COLOUR), "a part with no material gets the neutral grey, as before")

	# --- a part split by appearance: per surface
	var part := _split_part()
	_check(ClipLook.per_surface(part), "a real glb part with one body painted is wrapped per surface")
	RoomClip.assign(part, 2)
	var painted := -1
	for s in part.mesh.get_surface_count():
		var m := part.get_surface_override_material(s)
		if ClipLook.is_clip(m) and m.shader == ClipLook.ClipShaderAlpha:
			painted = s
	_check(part.material_override == null and ClipLook.surfaces_wrapped(part), "the room clip wraps each surface and leaves material_override alone")
	_check(painted >= 0 and (_param(part.get_surface_override_material(painted), "albedo_color") as Color).is_equal_approx(Color(Color.html("#E63946"), 0.5)), "...the painted body's surface keeps its red at half opacity (alpha clip)")
	_check(not ClipLook.is_clip(part.get_surface_override_material(1 - painted)) or part.get_surface_override_material(1 - painted).shader == ClipLook.ClipShader, "...the other surface its own plain look (opaque clip)")
	_check(int(part.get_instance_shader_parameter("room_slot")) == 2, "...and the part carries its room slot")
	var tool := SectionTool.new()
	root.add_child(tool)
	await process_frame
	tool.set_active(true, null)
	tool.reconcile([part])
	_check(ClipLook.surfaces_wrapped(part) and tool._adopted_surfaces.has(part), "the section tool adopts the room's per-surface wrap")
	tool.set_active(false, null)
	_check(ClipLook.surfaces_wrapped(part), "...and leaves it when it goes off (the room still needs it)")
	RoomClip.release(part)
	_check(not part.has_meta(ClipLook.SURFACES) and part.get_surface_override_material(0) == null and part.get_surface_override_material(1) == null, "releasing the room gives each surface its own look back")
	tool.set_active(true, null)
	tool.reconcile([part])
	_check(ClipLook.surfaces_wrapped(part) and not tool._adopted_surfaces.has(part), "the section tool alone wraps per surface too")
	tool.set_active(false, null)
	_check(not ClipLook.surfaces_wrapped(part) and part.get_surface_override_material(0) == null, "...and unwraps when it goes off")
	# A paint (appearance_look.gd) on a part the section tool has wrapped is picked up on the next reconcile.
	tool.set_active(true, null)
	tool.reconcile([part])
	Look.restyle(part, {}, {"colour": "#2ECC71"})
	tool.reconcile([part])
	_check(ClipLook.is_clip(part.material_override) and (_param(part.material_override, "albedo_color") as Color).is_equal_approx(Color.html("#2ECC71")), "a one-look paint while sectioning is wrapped again with the new look")
	tool.set_active(false, null)
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
