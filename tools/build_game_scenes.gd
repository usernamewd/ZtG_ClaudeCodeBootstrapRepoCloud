extends Node
## Generates the gameplay scenes that are pure structure rather than authored
## content: the bot, the bomb, and the pooled blast effects.
##
##   godot --headless --path . tools/build_game_scenes.tscn
##
## Building these in code keeps them consistent with CharacterBase's expectations
## (well-known child names, hitboxes in group "hitbox" on layer 4, the crouch
## capsule metrics) instead of relying on hand-edited .tscn text.

const OUT_CHARACTERS := "res://scenes/characters"
const OUT_GAME := "res://scenes/game"
const OUT_WEAPONS := "res://scenes/weapons"

const CHARACTER_GLB := {
	"havoc": "res://assets/characters/havoc.glb",
	"aegis": "res://assets/characters/aegis.glb",
}
const BOMB_GLB := "res://assets/weapons/bomb/tp.glb"

# Must match CharacterBase.
const STAND_HEIGHT := 1.8
const BODY_RADIUS := 0.35
const EYE_STAND := 1.65
const LAYER_HITBOX := 8


func _ready() -> void:
	for d in [OUT_CHARACTERS, OUT_GAME, OUT_WEAPONS]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))
	var made := 0
	made += 1 if _build_bot() else 0
	made += 1 if _build_bomb() else 0
	made += _build_effects()
	print("[build_scenes] wrote %d scenes" % made)
	get_tree().quit(0)


# ---------------------------------------------------------------------------

func _build_bot() -> bool:
	var root := CharacterBody3D.new()
	root.name = "Bot"
	root.set_script(load("res://src/bots/bot_brain.gd"))
	# Bots live on layer 3 (bit 4) and collide with world, clip, player, bots.
	root.collision_layer = 4
	root.collision_mask = 1 | 2 | 4 | 128

	var shape := CollisionShape3D.new()
	shape.name = "BodyShape"
	var capsule := CapsuleShape3D.new()
	capsule.radius = BODY_RADIUS
	capsule.height = STAND_HEIGHT
	shape.shape = capsule
	shape.position = Vector3(0.0, STAND_HEIGHT * 0.5, 0.0)
	root.add_child(shape)

	var eye := Node3D.new()
	eye.name = "Eye"
	eye.position = Vector3(0.0, EYE_STAND, 0.0)
	root.add_child(eye)

	# The visual is a CharacterVisual wrapping the imported rig, so bots get the
	# same animation state machine, aim offset and hand attachment as the player.
	var visual := Node3D.new()
	visual.name = "Mesh"
	visual.set_script(load("res://src/characters/character_visual.gd"))
	root.add_child(visual)
	var glb_path := String(CHARACTER_GLB["havoc"])
	if ResourceLoader.exists(glb_path):
		var model := (load(glb_path) as PackedScene).instantiate()
		model.name = "Model"
		visual.add_child(model)
		visual.set("model_path", NodePath("Model"))
	else:
		push_warning("[build_scenes] %s missing; bot will have no mesh" % glb_path)

	root.add_child(_make_hitboxes())

	var agent := NavigationAgent3D.new()
	agent.name = "NavAgent"
	root.add_child(agent)

	return _save(root, "%s/bot.tscn" % OUT_CHARACTERS)


## Hitbox rig matching a 1.8 m humanoid. Phase 2 moves these onto
## BoneAttachment3D; the group and metadata contract is identical either way.
func _make_hitboxes() -> Node3D:
	var holder := Node3D.new()
	holder.name = "Hitboxes"
	var specs := [
		["HeadHB", CharacterBase.Zone.HEAD, Vector3(0, 1.66, 0), Vector3(0.22, 0.24, 0.22)],
		["ChestHB", CharacterBase.Zone.CHEST, Vector3(0, 1.28, 0), Vector3(0.44, 0.44, 0.28)],
		["StomachHB", CharacterBase.Zone.STOMACH, Vector3(0, 0.95, 0), Vector3(0.38, 0.30, 0.26)],
		["ArmLHB", CharacterBase.Zone.LIMB, Vector3(-0.30, 1.24, 0), Vector3(0.16, 0.52, 0.18)],
		["ArmRHB", CharacterBase.Zone.LIMB, Vector3(0.30, 1.24, 0), Vector3(0.16, 0.52, 0.18)],
		["LegLHB", CharacterBase.Zone.LIMB, Vector3(-0.13, 0.44, 0), Vector3(0.20, 0.86, 0.22)],
		["LegRHB", CharacterBase.Zone.LIMB, Vector3(0.13, 0.44, 0), Vector3(0.20, 0.86, 0.22)],
	]
	for spec in specs:
		var body := StaticBody3D.new()
		body.name = String(spec[0])
		# Layer 4 only, mask 0: hitboxes are ray targets, never colliders.
		body.collision_layer = LAYER_HITBOX
		body.collision_mask = 0
		body.add_to_group("hitbox", true)
		body.set_meta("zone", int(spec[1]))
		body.position = spec[2]
		var cs := CollisionShape3D.new()
		cs.name = "Shape"
		var box := BoxShape3D.new()
		box.size = spec[3]
		cs.shape = box
		body.add_child(cs)
		holder.add_child(body)
	return holder


func _build_bomb() -> bool:
	var root := Node3D.new()
	root.name = "Bomb"
	root.set_script(load("res://src/game/bomb.gd"))

	if ResourceLoader.exists(BOMB_GLB):
		var model := (load(BOMB_GLB) as PackedScene).instantiate()
		model.name = "Model"
		root.add_child(model)
	else:
		push_warning("[build_scenes] %s missing; bomb will be invisible" % BOMB_GLB)

	# Blinking indicator light the fuse toggles — the visual half of the beep.
	var blinker := OmniLight3D.new()
	blinker.name = "Blinker"
	blinker.light_color = Color(1.0, 0.22, 0.16)
	blinker.light_energy = 2.4
	blinker.omni_range = 5.0
	blinker.position = Vector3(0.0, 0.22, 0.0)
	blinker.visible = false
	root.add_child(blinker)

	return _save(root, "%s/bomb.tscn" % OUT_GAME)


## Pooled one-shot blasts. Each releases itself back to Pools when finished, per
## the contract in src/autoload/pools.gd.
func _build_effects() -> int:
	var made := 0
	var specs := [
		{"name": "frag_blast", "color": Color(1.0, 0.62, 0.22), "count": 48,
			"lifetime": 0.7, "velocity": 14.0, "scale": 0.16, "light": 4.0},
		{"name": "flash_blast", "color": Color(1.0, 1.0, 0.96), "count": 30,
			"lifetime": 0.45, "velocity": 9.0, "scale": 0.2, "light": 12.0},
		{"name": "bomb_blast", "color": Color(1.0, 0.48, 0.14), "count": 96,
			"lifetime": 1.5, "velocity": 26.0, "scale": 0.4, "light": 9.0},
	]
	for spec in specs:
		var root := Node3D.new()
		root.name = String(spec.name).to_pascal_case()
		root.set_script(load("res://src/weapons/blast_effect.gd"))

		var particles := GPUParticles3D.new()
		particles.name = "Particles"
		particles.amount = int(spec.count)
		particles.lifetime = float(spec.lifetime)
		particles.one_shot = true
		particles.explosiveness = 1.0
		particles.emitting = false

		var mat := ParticleProcessMaterial.new()
		mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		mat.emission_sphere_radius = 0.3
		mat.direction = Vector3(0, 1, 0)
		mat.spread = 180.0
		mat.initial_velocity_min = float(spec.velocity) * 0.45
		mat.initial_velocity_max = float(spec.velocity)
		mat.gravity = Vector3(0, -9.0, 0)
		mat.scale_min = float(spec.scale) * 0.5
		mat.scale_max = float(spec.scale)
		mat.color = spec.color
		# Fade and shrink so the burst dissipates instead of popping out.
		var curve := Curve.new()
		curve.add_point(Vector2(0.0, 1.0))
		curve.add_point(Vector2(1.0, 0.0))
		var ct := CurveTexture.new()
		ct.curve = curve
		mat.scale_curve = ct
		particles.process_material = mat

		var quad := QuadMesh.new()
		quad.size = Vector2(0.5, 0.5)
		var qmat := StandardMaterial3D.new()
		qmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		qmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		qmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		qmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		qmat.vertex_color_use_as_albedo = true
		qmat.albedo_color = spec.color
		quad.material = qmat
		particles.draw_pass_1 = quad
		root.add_child(particles)

		var light := OmniLight3D.new()
		light.name = "Flash"
		light.light_color = spec.color
		light.light_energy = float(spec.light)
		light.omni_range = 14.0
		light.visible = false
		root.add_child(light)

		if _save(root, "%s/%s.tscn" % [OUT_WEAPONS, String(spec.name)]):
			made += 1
	return made


# ---------------------------------------------------------------------------

func _save(root: Node, path: String) -> bool:
	_own(root, root)
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		printerr("[build_scenes] pack failed: ", path)
		root.free()
		return false
	if ResourceSaver.save(packed, path) != OK:
		printerr("[build_scenes] save failed: ", path)
		root.free()
		return false
	print("[build_scenes] ", path)
	root.free()
	return true


func _own(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		if c.scene_file_path == "":
			_own(c, owner_node)
