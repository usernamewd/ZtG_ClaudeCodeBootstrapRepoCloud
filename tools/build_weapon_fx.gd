extends SceneTree
## Builds the pooled weapon VFX scenes used by src/weapons/weapon.gd:
##   res://scenes/weapons/tracer.tscn
##   res://scenes/weapons/impact.tscn
## Run: godot --headless --path . --script tools/build_weapon_fx.gd
## Untextured placeholder look on purpose — Phase 5 replaces the visuals, and the
## scripts only touch node transforms / colours, so swapping meshes is safe.

const TRACER_PATH := "res://scenes/weapons/tracer.tscn"
const IMPACT_PATH := "res://scenes/weapons/impact.tscn"
const TRACER_SCRIPT := "res://src/weapons/tracer.gd"
const IMPACT_SCRIPT := "res://src/weapons/impact.gd"


func _init() -> void:
	var fails := 0
	fails += _save(_build_tracer(), TRACER_PATH)
	fails += _save(_build_impact(), IMPACT_PATH)
	quit(1 if fails > 0 else 0)


func _save(root: Node3D, path: String) -> int:
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		printerr("PACK FAILED: ", path)
		root.free()
		return 1
	var err := ResourceSaver.save(packed, path)
	root.free()
	if err != OK:
		printerr("SAVE FAILED: ", path, " err ", err)
		return 1
	print("wrote ", path)
	return 0


func _build_tracer() -> Node3D:
	var root := Node3D.new()
	root.name = "Tracer"
	root.set_script(load(TRACER_SCRIPT))

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1.0, 0.86, 0.5, 0.8)
	mat.disable_receive_shadows = true
	mat.disable_ambient_light = true

	var box := BoxMesh.new()
	box.size = Vector3(0.035, 0.035, 1.0)

	var beam := MeshInstance3D.new()
	beam.name = "Beam"
	beam.mesh = box
	beam.material_override = mat
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.position = Vector3(0.0, 0.0, -0.5)
	root.add_child(beam)
	beam.owner = root
	return root


func _build_impact() -> Node3D:
	var root := Node3D.new()
	root.name = "Impact"
	root.set_script(load(IMPACT_SCRIPT))

	# --- sparks / dust ------------------------------------------------------
	var spark_mat := StandardMaterial3D.new()
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spark_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	spark_mat.vertex_color_use_as_albedo = true
	spark_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	spark_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	spark_mat.disable_receive_shadows = true
	spark_mat.disable_ambient_light = true

	var spark_mesh := BoxMesh.new()
	spark_mesh.size = Vector3(0.022, 0.022, 0.022)
	spark_mesh.material = spark_mat

	var sparks := CPUParticles3D.new()
	sparks.name = "Sparks"
	sparks.mesh = spark_mesh
	sparks.emitting = false
	sparks.one_shot = true
	sparks.amount = 8
	sparks.lifetime = 0.3
	sparks.explosiveness = 1.0
	sparks.local_coords = false
	sparks.direction = Vector3(0.0, 0.0, 1.0)   # local +Z = surface normal
	sparks.spread = 34.0
	sparks.initial_velocity_min = 2.0
	sparks.initial_velocity_max = 5.5
	sparks.gravity = Vector3(0.0, -9.0, 0.0)
	sparks.damping_min = 1.0
	sparks.damping_max = 3.0
	sparks.scale_amount_min = 0.6
	sparks.scale_amount_max = 1.2
	sparks.color = Color(1.0, 0.85, 0.55, 1.0)
	sparks.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	root.add_child(sparks)
	sparks.owner = root

	# --- decal-ish quad ----------------------------------------------------
	var decal_mat := StandardMaterial3D.new()
	decal_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	decal_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	decal_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	decal_mat.albedo_color = Color(0.05, 0.05, 0.06, 0.85)
	decal_mat.disable_receive_shadows = true
	decal_mat.disable_ambient_light = true
	decal_mat.no_depth_test = false

	var quad := QuadMesh.new()
	quad.size = Vector2(0.13, 0.13)

	var decal := MeshInstance3D.new()
	decal.name = "Decal"
	decal.mesh = quad
	decal.material_override = decal_mat
	decal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(decal)
	decal.owner = root
	return root
