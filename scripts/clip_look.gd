extends RefCounted
## The clip shader's copy of a part's look, shared by the section tool (section_tool.gd) and the Assembly Room clip
## (room/room_clip.gd). Both have to put shaders/section_clip.gdshader on a part (a plain StandardMaterial3D can't discard by a
## uniform), and that used to carry only the base colour. Now it carries the whole look the Appearance tool paints: colour with
## opacity (a see-through look gets section_clip_alpha.gdshader), metallic, roughness and glow.
##
## A part with ONE look (a material override, or a single-surface mesh) is wrapped as before, through `material_override`.
## A part whose mesh is split by appearance (one surface per look: a body or face painted differently, from the glb or from
## appearance_look.gd) is wrapped per SURFACE (`set_surface_override_material`), so each body / face keeps its look while cut;
## `wrap_surfaces` / `surfaces_wrapped` / `unwrap_surfaces`, recognised by the meta SURFACES (the mesh it was built for: a
## rebuilt mesh is wrapped again).

const ClipShader := preload("res://shaders/section_clip.gdshader")
const ClipShaderAlpha := preload("res://shaders/section_clip_alpha.gdshader")
const SURFACES := "clip_surfaces" ## meta: the instance id of the mesh whose surfaces wear clip materials
const DEFAULT_COLOUR := Color(0.7, 0.7, 0.7, 1.0) ## a part with no material at all


static func is_clip(m: Material) -> bool:
	return m is ShaderMaterial and ((m as ShaderMaterial).shader == ClipShader or (m as ShaderMaterial).shader == ClipShaderAlpha)


static func look_of(source: Material, part: MeshInstance3D = null) -> Material:
	## The material whose look a wrap copies: `source` if it is a real look, else the part's own first surface.
	if source is BaseMaterial3D:
		return source
	if part != null and part.mesh != null and part.mesh.get_surface_count() > 0:
		var base := part.mesh.surface_get_material(0)
		if base is BaseMaterial3D:
			return base
	return null


static func clip_for(source: Material, part: MeshInstance3D = null) -> ShaderMaterial:
	## A clip material wearing `source`'s look (see look_of): albedo with alpha, metallic, roughness, emission.
	var look := look_of(source, part) as BaseMaterial3D
	var see_through := look != null and (look.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or look.albedo_color.a < 0.999)
	var mat := ShaderMaterial.new()
	mat.shader = ClipShaderAlpha if see_through else ClipShader
	if look == null:
		mat.set_shader_parameter("albedo_color", DEFAULT_COLOUR)
		return mat
	mat.set_shader_parameter("albedo_color", look.albedo_color)
	mat.set_shader_parameter("metallic", look.metallic)
	mat.set_shader_parameter("roughness", look.roughness)
	if look.emission_enabled:
		mat.set_shader_parameter("emission_color", look.emission)
		mat.set_shader_parameter("emission_energy", look.emission_energy_multiplier)
	return mat


static func per_surface(part: MeshInstance3D) -> bool:
	## The part's look lives in its mesh's surfaces and they differ (no override over them): it is wrapped surface by surface.
	if part.material_override != null or part.mesh == null or part.mesh.get_surface_count() < 2:
		return false
	var first := part.mesh.surface_get_material(0)
	for s in range(1, part.mesh.get_surface_count()):
		if part.mesh.surface_get_material(s) != first:
			return true
	return false


static func wrap_surfaces(part: MeshInstance3D) -> void:
	for s in part.mesh.get_surface_count():
		part.set_surface_override_material(s, clip_for(part.mesh.surface_get_material(s)))
	part.set_meta(SURFACES, part.mesh.get_instance_id())


static func surfaces_wrapped(part: MeshInstance3D) -> bool:
	if not part.has_meta(SURFACES) or part.mesh == null or int(part.get_meta(SURFACES)) != part.mesh.get_instance_id():
		return false
	for s in part.mesh.get_surface_count():
		if not is_clip(part.get_surface_override_material(s)):
			return false
	return true


static func unwrap_surfaces(part: MeshInstance3D) -> void:
	if not part.has_meta(SURFACES):
		return
	if part.mesh != null:
		for s in part.mesh.get_surface_count():
			if is_clip(part.get_surface_override_material(s)):
				part.set_surface_override_material(s, null)
	part.remove_meta(SURFACES)
