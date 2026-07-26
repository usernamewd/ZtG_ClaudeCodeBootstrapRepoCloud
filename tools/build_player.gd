extends SceneTree
## Builds scenes/characters/player.tscn from code so the camera rig, the capsule
## and the hitbox metadata stay reproducible.
##   godot --headless --path . --script tools/build_player.gd
##
## Phase 1: no visible mesh. "Body" is the empty placeholder the Phase 2
## full-body operator mesh drops into (player.gd points CharacterBase's
## mesh_root_path at it), and the hitboxes mirror the dummy 1:1 so bots can
## shoot the player with the exact same zone volumes.

const OUT_PATH := "res://scenes/characters/player.tscn"
const SCRIPT_PATH := "res://src/characters/player.gd"

# project.godot layer_names: world 1, player 2, bot 3, hitbox 4, clip 8.
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

# Must match CharacterBase.STAND_HEIGHT / BODY_RADIUS / EYE_STAND: the base class
# rewrites the capsule on the first crouch blend, so authoring anything else
# would just pop on spawn.
const BODY_RADIUS := 0.35
const STAND_HEIGHT := 1.8
const EYE_HEIGHT := 1.65

const CAMERA_FOV := 75.0
const CAMERA_NEAR := 0.05
const CAMERA_FAR := 300.0

const HIP_POS := Vector3(0.17, -0.14, -0.30)

# Same proportions as tools/build_dummy.gd (1 cm overlap at the seams).
const HEAD_R := 0.13
const HEAD_Y := 1.66
const CHEST_SIZE := Vector3(0.44, 0.42, 0.24)
const CHEST_Y := 1.34
const STOMACH_SIZE := Vector3(0.38, 0.32, 0.22)
const STOMACH_Y := 0.98
const ARM_R := 0.075
const ARM_H := 0.62
const ARM_Y := 1.16
const ARM_X := 0.25
const LEG_R := 0.11
const LEG_H := 0.86
const LEG_Y := 0.43
const LEG_X := 0.115

var _root: CharacterBody3D
var _done: bool = false


## Autoloads are only registered on the SceneTree *after* _init() returns, and
## player.gd references InputHub/Settings, so the build has to happen on the
## first processed frame or set_script() would silently get a null script.
func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_build()
	return true


func _build() -> void:
	_root = CharacterBody3D.new()
	_root.name = "Player"
	_root.collision_layer = LAYER_PLAYER
	_root.collision_mask = LAYER_WORLD | LAYER_BOT | LAYER_CLIP
	_root.floor_max_angle = deg_to_rad(46.0)
	_root.floor_snap_length = 0.35
	var scr := load(SCRIPT_PATH) as Script
	if scr == null:
		printerr("could not load ", SCRIPT_PATH, " — refusing to write a scriptless scene")
		quit(1)
		return
	_root.set_script(scr)
	_root.add_to_group("player", true)

	_build_body_shape()
	_build_rig()
	_build_body_placeholder()
	_build_hitboxes()

	# Exported overrides: the Phase 2 mesh lands under "Body", not "Mesh".
	_root.set("mesh_root_path", NodePath("Body"))
	_root.set("eye_path", NodePath("Eye"))
	_root.set("body_shape_path", NodePath("BodyShape"))
	_root.set("cam_pivot_path", NodePath("Eye/CamPivot"))
	_root.set("camera_path", NodePath("Eye/CamPivot/Camera3D"))
	_root.set("weapon_mount_path", NodePath("Eye/CamPivot/Camera3D/WeaponMount"))
	_root.set("hip_position", HIP_POS)

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


## Eye (crouch blend, CharacterBase) -> CamPivot (pitch + landing dip) ->
## Camera3D (view bob + roll) -> WeaponMount (sway, ADS slide, the Weapon node).
func _build_rig() -> void:
	var eye := _add(_root, Node3D.new(), "Eye", Vector3(0.0, EYE_HEIGHT, 0.0))
	var pivot := _add(eye, Node3D.new(), "CamPivot")
	var cam := Camera3D.new()
	cam.fov = CAMERA_FOV
	cam.near = CAMERA_NEAR
	cam.far = CAMERA_FAR
	cam.current = true
	_add(pivot, cam, "Camera3D")
	_add(cam, Node3D.new(), "WeaponMount", HIP_POS)


func _build_body_placeholder() -> void:
	# Phase 2: rigged operator .glb goes in here; hitboxes then move onto
	# BoneAttachment3D nodes and nothing else in this tree changes.
	_add(_root, Node3D.new(), "Body")


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


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
