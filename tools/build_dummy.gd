extends SceneTree
## Builds scenes/characters/dummy.tscn from code so the node tree, the hitbox
## metadata and the human proportions stay reproducible.
##   godot --headless --path . --script tools/build_dummy.gd
##
## Phase 1 graybox: the visual is a set of primitives under "Mesh" that mirror
## the hitbox volumes 1:1, so what you see is exactly what you can hit. Phase 2
## replaces the whole "Mesh" node with a rigged .glb and moves the StaticBody3D
## hitboxes under BoneAttachment3D nodes; nothing else in the tree changes.

const OUT_PATH := "res://scenes/characters/dummy.tscn"
const SCRIPT_PATH := "res://src/characters/dummy.gd"

# Layers (project.godot layer_names): world 1, player 2, bot 3, hitbox 4, clip 8.
const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_BOT := 4
const LAYER_HITBOX := 8
const LAYER_CLIP := 128

# CharacterBase.Zone
const ZONE_HEAD := 0
const ZONE_CHEST := 1
const ZONE_STOMACH := 2
const ZONE_LIMB := 3

# Proportions for a 1.8 m operator. Zones overlap by ~1 cm so no ray can slip
# between two hitboxes at a seam.
const BODY_RADIUS := 0.35
const STAND_HEIGHT := 1.8
const EYE_HEIGHT := 1.65

const HEAD_R := 0.13
const HEAD_Y := 1.66                      # spans 1.53 .. 1.79
const CHEST_SIZE := Vector3(0.44, 0.42, 0.24)
const CHEST_Y := 1.34                     # spans 1.13 .. 1.55
const STOMACH_SIZE := Vector3(0.38, 0.32, 0.22)
const STOMACH_Y := 0.98                   # spans 0.82 .. 1.14
const ARM_R := 0.075
const ARM_H := 0.62
const ARM_Y := 1.16                       # spans 0.85 .. 1.47
const ARM_X := 0.25
const LEG_R := 0.11
const LEG_H := 0.86
const LEG_Y := 0.43                       # spans 0.00 .. 0.86
const LEG_X := 0.115

var _root: CharacterBody3D
var _body_mat: StandardMaterial3D
var _head_mat: StandardMaterial3D


func _init() -> void:
	_body_mat = StandardMaterial3D.new()
	_body_mat.albedo_color = Color(0.56, 0.60, 0.66)
	_body_mat.roughness = 0.85
	_body_mat.metallic = 0.0
	_head_mat = StandardMaterial3D.new()
	_head_mat.albedo_color = Color(0.86, 0.34, 0.24)
	_head_mat.roughness = 0.8
	_head_mat.metallic = 0.0

	_root = CharacterBody3D.new()
	_root.name = "Dummy"
	_root.collision_layer = LAYER_BOT
	_root.collision_mask = LAYER_WORLD | LAYER_PLAYER | LAYER_BOT | LAYER_CLIP
	_root.floor_max_angle = deg_to_rad(46.0)
	_root.floor_snap_length = 0.35
	_root.set_script(load(SCRIPT_PATH))

	_build_body_shape()
	_build_eye()
	_build_mesh()
	_build_hitboxes()
	_build_damage_text()

	var packed := PackedScene.new()
	var err := packed.pack(_root)
	if err != OK:
		printerr("pack failed: ", err)
		quit(1)
		return
	err = ResourceSaver.save(packed, OUT_PATH)
	if err != OK:
		printerr("save failed: ", err)
		quit(1)
		return
	print("wrote ", OUT_PATH, " (", _count(_root), " nodes)")
	_root.free()
	quit(0)


func _add(parent: Node, n: Node, name_: String, pos := Vector3.ZERO) -> Node:
	n.name = name_
	parent.add_child(n)
	n.owner = _root
	if n is Node3D:
		(n as Node3D).position = pos
	return n


func _build_body_shape() -> void:
	var caps := CapsuleShape3D.new()
	caps.radius = BODY_RADIUS
	caps.height = STAND_HEIGHT
	var cs := CollisionShape3D.new()
	cs.shape = caps
	_add(_root, cs, "BodyShape", Vector3(0.0, STAND_HEIGHT * 0.5, 0.0))


func _build_eye() -> void:
	_add(_root, Node3D.new(), "Eye", Vector3(0.0, EYE_HEIGHT, 0.0))


func _build_mesh() -> void:
	var mesh_root := _add(_root, Node3D.new(), "Mesh")

	var head := SphereMesh.new()
	head.radius = HEAD_R
	head.height = HEAD_R * 2.0
	head.radial_segments = 16
	head.rings = 8
	_mesh_node(mesh_root, "HeadMesh", head, Vector3(0.0, HEAD_Y, 0.0), _head_mat)

	var chest := BoxMesh.new()
	chest.size = CHEST_SIZE
	_mesh_node(mesh_root, "ChestMesh", chest, Vector3(0.0, CHEST_Y, 0.0), _body_mat)

	var stomach := BoxMesh.new()
	stomach.size = STOMACH_SIZE
	_mesh_node(mesh_root, "StomachMesh", stomach, Vector3(0.0, STOMACH_Y, 0.0), _body_mat)

	var arm := CapsuleMesh.new()
	arm.radius = ARM_R
	arm.height = ARM_H
	arm.radial_segments = 10
	arm.rings = 3
	_mesh_node(mesh_root, "ArmLMesh", arm, Vector3(-ARM_X, ARM_Y, 0.0), _body_mat)
	_mesh_node(mesh_root, "ArmRMesh", arm, Vector3(ARM_X, ARM_Y, 0.0), _body_mat)

	var leg := CapsuleMesh.new()
	leg.radius = LEG_R
	leg.height = LEG_H
	leg.radial_segments = 10
	leg.rings = 3
	_mesh_node(mesh_root, "LegLMesh", leg, Vector3(-LEG_X, LEG_Y, 0.0), _body_mat)
	_mesh_node(mesh_root, "LegRMesh", leg, Vector3(LEG_X, LEG_Y, 0.0), _body_mat)

	# Facing marker so you can tell front from back on the graybox.
	var visor := BoxMesh.new()
	visor.size = Vector3(0.18, 0.05, 0.02)
	_mesh_node(mesh_root, "VisorMesh", visor, Vector3(0.0, HEAD_Y + 0.02, -HEAD_R), _body_mat)


func _mesh_node(parent: Node, name_: String, mesh: Mesh, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	_add(parent, mi, name_, pos)


func _build_hitboxes() -> void:
	var hb_root := _add(_root, Node3D.new(), "Hitboxes")

	var head := SphereShape3D.new()
	head.radius = HEAD_R
	_hitbox(hb_root, "HeadHB", ZONE_HEAD, head, Vector3(0.0, HEAD_Y, 0.0))

	var chest := BoxShape3D.new()
	chest.size = CHEST_SIZE
	_hitbox(hb_root, "ChestHB", ZONE_CHEST, chest, Vector3(0.0, CHEST_Y, 0.0))

	var stomach := BoxShape3D.new()
	stomach.size = STOMACH_SIZE
	_hitbox(hb_root, "StomachHB", ZONE_STOMACH, stomach, Vector3(0.0, STOMACH_Y, 0.0))

	var arm := CapsuleShape3D.new()
	arm.radius = ARM_R
	arm.height = ARM_H
	_hitbox(hb_root, "LimbArmLHB", ZONE_LIMB, arm, Vector3(-ARM_X, ARM_Y, 0.0))
	_hitbox(hb_root, "LimbArmRHB", ZONE_LIMB, arm, Vector3(ARM_X, ARM_Y, 0.0))

	var leg := CapsuleShape3D.new()
	leg.radius = LEG_R
	leg.height = LEG_H
	_hitbox(hb_root, "LimbLegLHB", ZONE_LIMB, leg, Vector3(-LEG_X, LEG_Y, 0.0))
	_hitbox(hb_root, "LimbLegRHB", ZONE_LIMB, leg, Vector3(LEG_X, LEG_Y, 0.0))


## One zone hitbox: StaticBody3D on the hitbox layer with no mask, in group
## "hitbox", carrying its zone as metadata. CharacterBase.register_hitboxes()
## stamps the owning-character metadata on top at runtime.
func _hitbox(parent: Node, name_: String, zone: int, shape: Shape3D, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_HITBOX
	body.collision_mask = 0
	body.set_meta("zone", zone)
	body.add_to_group("hitbox", true)
	_add(parent, body, name_, pos)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	_add(body, cs, "Shape")


func _build_damage_text() -> void:
	var l := Label3D.new()
	l.text = "0"
	l.font_size = 96
	l.outline_size = 24
	l.pixel_size = 0.0016
	l.modulate = Color(1.0, 0.86, 0.35, 1.0)
	l.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = false
	l.visible = false
	_add(_root, l, "DamageText", Vector3(0.0, STAND_HEIGHT + 0.2, 0.0))


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
