class_name CharacterVisual
extends Node3D
## Drives everything you can SEE about a character: the animation state machine,
## the aim offset, the weapon in the hands, and first-person self-visibility.
##
## Owns the imported character GLB (see docs/ASSET_PIPELINE.md for its shape):
##
##   <glb root>
##     CharacterArmature/Skeleton3D
##       Head_2 (BoneAttachment3D) > Head (MeshInstance3D)   <- separate mesh
##       Body (MeshInstance3D, skinned)
##     AnimationPlayer
##
## Because Head is its own mesh node, full-body first person costs nothing: hide
## Head and collapse the arm bones, and the local player sees their own legs and
## torso when they look down while the viewmodel arms render on top.
##
## The animation tree is built in code rather than authored as a .tres so it
## adapts to whichever animations the GLB actually ships, and so a missing
## animation degrades to a fallback instead of erroring.

signal footstep(foot: int)   ## 0 left, 1 right — emitted from locomotion phase

enum Stance { STAND, CROUCH, AIR }

## Locomotion animation names, with fallbacks in preference order. The first one
## present in the AnimationPlayer wins, so the rig can ship a reduced set.
const ANIM_CANDIDATES := {
	"idle": ["Idle_Shoot", "Idle"],
	"walk": ["Walk_Shoot", "Walk"],
	"run": ["Run_Gun", "Run_Shoot", "Run"],
	"back": ["Walk_Back", "Walk_Shoot", "Walk"],
	"strafe_l": ["Strafe_L", "Walk_Shoot", "Walk"],
	"strafe_r": ["Strafe_R", "Walk_Shoot", "Walk"],
	"crouch_idle": ["Crouch_Idle", "Duck"],
	"crouch_walk": ["Crouch_Walk", "Duck"],
	"air": ["Jump_Idle", "Jump"],
	"land": ["Land", "Jump_Land"],
	"reload": ["Reload"],
	"draw": ["Draw"],
	"plant": ["Plant"],
	"defuse": ["Defuse"],
	"hit": ["HitReact"],
	"death": ["Death_Front", "Death"],
	"death_back": ["Death_Back", "Death"],
	"death_head": ["Death_Head", "Death"],
}

## Hand bone the weapon attaches to, with fallbacks across naming conventions.
const HAND_BONE_CANDIDATES := ["Middle1.R", "LowerArm.R", "Hand.R", "hand.R", "mixamorig:RightHand"]
## Bones collapsed to hide the player's own arms in first person.
const FP_HIDE_BONES := ["Shoulder.L", "Shoulder.R"]

@export var model_path: NodePath
@export var first_person: bool = false

var skeleton: Skeleton3D = null
var anim_player: AnimationPlayer = null
var anim_tree: AnimationTree = null
var aim_offset: AimOffset = null
var hand_attach: BoneAttachment3D = null

var stance: int = Stance.STAND
var _model: Node3D = null
var _head_mesh: GeometryInstance3D = null
var _body_meshes: Array[GeometryInstance3D] = []
var _resolved := {}                        ## logical name -> real animation name
var _playback: AnimationNodeStateMachinePlayback = null

# Locomotion parameter smoothing so the blend space doesn't jitter.
var _blend_pos := Vector2.ZERO
var _crouch_amount := 0.0
var _air_amount := 0.0
var _stride_phase := 0.0
var _last_foot := 1

const PARAM_LOCO := "parameters/loco/blend_position"
const PARAM_CROUCH_LOCO := "parameters/crouch_loco/blend_position"
const PARAM_CROUCH_MIX := "parameters/crouch_mix/blend_amount"
const PARAM_AIR_MIX := "parameters/air_mix/blend_amount"
const PARAM_ACTION := "parameters/action/request"
const PARAM_ACTION_ACTIVE := "parameters/action/active"


func _ready() -> void:
	_model = get_node_or_null(model_path) as Node3D
	if _model == null:
		_model = _find_first_model()
	if _model == null:
		push_warning("CharacterVisual: no character model found under %s" % name)
		return
	_resolve_model_parts()
	_resolve_animation_names()
	_build_animation_tree()
	_setup_aim_offset()
	_setup_hand_attachment()
	set_first_person(first_person)


func _find_first_model() -> Node3D:
	for c in get_children():
		if c is Node3D and c.get_child_count() > 0:
			return c as Node3D
	return null


func _resolve_model_parts() -> void:
	skeleton = _find_node_of_type(_model, "Skeleton3D") as Skeleton3D
	anim_player = _find_node_of_type(_model, "AnimationPlayer") as AnimationPlayer
	if skeleton == null:
		return
	for n in _all_descendants(skeleton):
		if n is GeometryInstance3D:
			var gi := n as GeometryInstance3D
			if gi.name.to_lower().begins_with("head"):
				_head_mesh = gi
			else:
				_body_meshes.append(gi)


func _resolve_animation_names() -> void:
	_resolved.clear()
	if anim_player == null:
		return
	var have := anim_player.get_animation_list()
	for logical in ANIM_CANDIDATES:
		for candidate in ANIM_CANDIDATES[logical]:
			if have.has(candidate):
				_resolved[logical] = candidate
				break


func anim_name(logical: String) -> String:
	return String(_resolved.get(logical, ""))


func has_anim(logical: String) -> bool:
	return _resolved.has(logical)


# ---------------------------------------------------------------------------
# Animation tree
# ---------------------------------------------------------------------------

func _build_animation_tree() -> void:
	if anim_player == null or skeleton == null:
		return

	# Locomotion loops must actually loop; the glTF importer leaves them as
	# ANIMATION_LOOP_NONE, which makes a walk cycle hitch every stride.
	for logical in ["idle", "walk", "run", "back", "strafe_l", "strafe_r",
			"crouch_idle", "crouch_walk", "air"]:
		var n := anim_name(logical)
		if n != "":
			var a := anim_player.get_animation(n)
			if a:
				a.loop_mode = Animation.LOOP_LINEAR

	var tree := AnimationNodeBlendTree.new()

	# Standing locomotion: x = strafe (-1 left .. 1 right), y = forward
	# (-1 back .. 1 run). Walk sits at 0.5 so the walk->run ramp is smooth.
	var loco := AnimationNodeBlendSpace2D.new()
	loco.min_space = Vector2(-1.0, -1.0)
	loco.max_space = Vector2(1.0, 1.0)
	loco.blend_mode = AnimationNodeBlendSpace2D.BLEND_MODE_INTERPOLATED
	_add_blend_point(loco, "idle", Vector2(0.0, 0.0))
	_add_blend_point(loco, "walk", Vector2(0.0, 0.5))
	_add_blend_point(loco, "run", Vector2(0.0, 1.0))
	_add_blend_point(loco, "back", Vector2(0.0, -1.0))
	_add_blend_point(loco, "strafe_l", Vector2(-1.0, 0.35))
	_add_blend_point(loco, "strafe_r", Vector2(1.0, 0.35))
	# Diagonals: reuse the strafe clips pushed forward so a diagonal run doesn't
	# collapse to a pure sidestep.
	_add_blend_point(loco, "strafe_l", Vector2(-0.7, 1.0))
	_add_blend_point(loco, "strafe_r", Vector2(0.7, 1.0))
	tree.add_node("loco", loco, Vector2(0, 0))

	var crouch_loco := AnimationNodeBlendSpace2D.new()
	crouch_loco.min_space = Vector2(-1.0, -1.0)
	crouch_loco.max_space = Vector2(1.0, 1.0)
	_add_blend_point(crouch_loco, "crouch_idle", Vector2(0.0, 0.0))
	_add_blend_point(crouch_loco, "crouch_walk", Vector2(0.0, 1.0))
	_add_blend_point(crouch_loco, "crouch_walk", Vector2(0.0, -1.0))
	_add_blend_point(crouch_loco, "crouch_walk", Vector2(-1.0, 0.4))
	_add_blend_point(crouch_loco, "crouch_walk", Vector2(1.0, 0.4))
	tree.add_node("crouch_loco", crouch_loco, Vector2(0, 200))

	var crouch_mix := AnimationNodeBlend2.new()
	tree.add_node("crouch_mix", crouch_mix, Vector2(300, 80))
	tree.connect_node("crouch_mix", 0, "loco")
	tree.connect_node("crouch_mix", 1, "crouch_loco")

	var air := AnimationNodeAnimation.new()
	air.animation = anim_name("air") if has_anim("air") else anim_name("idle")
	tree.add_node("air", air, Vector2(300, 300))

	var air_mix := AnimationNodeBlend2.new()
	tree.add_node("air_mix", air_mix, Vector2(560, 140))
	tree.connect_node("air_mix", 0, "crouch_mix")
	tree.connect_node("air_mix", 1, "air")

	# One-shot overlay for reload / draw / plant / defuse / hit reactions. The
	# animation it plays is swapped before each request.
	var action := AnimationNodeOneShot.new()
	action.fadein_time = 0.12
	action.fadeout_time = 0.18
	action.break_loop_at_end = true
	tree.add_node("action", action, Vector2(820, 140))
	var action_anim := AnimationNodeAnimation.new()
	action_anim.animation = anim_name("reload") if has_anim("reload") else anim_name("idle")
	tree.add_node("action_anim", action_anim, Vector2(820, 340))
	tree.connect_node("action", 0, "air_mix")
	tree.connect_node("action", 1, "action_anim")

	tree.connect_node("output", 0, "action")

	anim_tree = AnimationTree.new()
	anim_tree.name = "AnimTree"
	anim_tree.tree_root = tree
	anim_tree.anim_player = anim_tree.get_path_to(anim_player)
	anim_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	add_child(anim_tree)
	# anim_player lives under the model, so the path must be re-resolved once
	# the tree is in the scene.
	anim_tree.anim_player = anim_tree.get_path_to(anim_player)
	anim_tree.active = true


func _add_blend_point(space: AnimationNodeBlendSpace2D, logical: String, at: Vector2) -> void:
	var n := anim_name(logical)
	if n == "":
		return
	var node := AnimationNodeAnimation.new()
	node.animation = n
	space.add_blend_point(node, at)


func _setup_aim_offset() -> void:
	if skeleton == null:
		return
	aim_offset = AimOffset.new()
	aim_offset.name = "AimOffset"
	skeleton.add_child(aim_offset)


func _setup_hand_attachment() -> void:
	if skeleton == null:
		return
	var bone := -1
	for candidate in HAND_BONE_CANDIDATES:
		bone = skeleton.find_bone(candidate)
		if bone >= 0:
			break
	if bone < 0:
		push_warning("CharacterVisual: no hand bone found for weapon attachment")
		return
	hand_attach = BoneAttachment3D.new()
	hand_attach.name = "WeaponHand"
	skeleton.add_child(hand_attach)
	hand_attach.bone_idx = bone


# ---------------------------------------------------------------------------
# Per-frame drive
# ---------------------------------------------------------------------------

## Called every frame by the owning character.
## `local_velocity` is the character's velocity in its own basis (x strafe,
## z forward, negative z = forward in Godot).
func update_locomotion(delta: float, local_velocity: Vector3, on_floor: bool,
		crouching: bool, run_speed: float) -> void:
	if anim_tree == null:
		return

	var speed_ref := maxf(run_speed, 0.01)
	# Godot forward is -Z, but the blend space's +Y means "forward".
	var target := Vector2(
		clampf(local_velocity.x / speed_ref, -1.0, 1.0),
		clampf(-local_velocity.z / speed_ref, -1.0, 1.0))

	# Smooth toward the target so a direction flip cross-fades instead of
	# popping between clips.
	_blend_pos = _blend_pos.lerp(target, clampf(delta * 9.0, 0.0, 1.0))
	_crouch_amount = lerpf(_crouch_amount, 1.0 if crouching else 0.0,
		clampf(delta * 10.0, 0.0, 1.0))
	_air_amount = lerpf(_air_amount, 0.0 if on_floor else 1.0,
		clampf(delta * 12.0, 0.0, 1.0))

	anim_tree.set(PARAM_LOCO, _blend_pos)
	anim_tree.set(PARAM_CROUCH_LOCO, _blend_pos)
	anim_tree.set(PARAM_CROUCH_MIX, _crouch_amount)
	anim_tree.set(PARAM_AIR_MIX, _air_amount)

	_update_footsteps(delta, local_velocity, on_floor, crouching, speed_ref)
	stance = Stance.AIR if not on_floor else (Stance.CROUCH if crouching else Stance.STAND)


## Footsteps are derived from distance travelled rather than from animation
## tracks, so they stay in step across every blend and never double-fire.
func _update_footsteps(delta: float, local_velocity: Vector3, on_floor: bool,
		crouching: bool, speed_ref: float) -> void:
	if not on_floor:
		_stride_phase = 0.0
		return
	var planar := Vector2(local_velocity.x, local_velocity.z).length()
	if planar < 0.6:
		_stride_phase = 0.0
		return
	# Longer stride when running, shorter when crouched.
	var stride := 1.9 if not crouching else 1.15
	_stride_phase += (planar * delta) / stride
	if _stride_phase >= 1.0:
		_stride_phase -= 1.0
		_last_foot = 1 - _last_foot
		footstep.emit(_last_foot)


## Point the upper body where the character is aiming.
func set_aim(pitch_deg: float, body_yaw_error_deg := 0.0, lean_deg := 0.0) -> void:
	if aim_offset:
		aim_offset.pitch_deg = pitch_deg
		aim_offset.yaw_deg = body_yaw_error_deg
		aim_offset.lean_deg = lean_deg


## Fire a one-shot overlay (reload / draw / plant / defuse / hit).
func play_action(logical: String, speed := 1.0) -> void:
	if anim_tree == null or not has_anim(logical):
		return
	var node := anim_tree.tree_root.get_node("action_anim") as AnimationNodeAnimation
	if node == null:
		return
	node.animation = anim_name(logical)
	# Match the clip length to the gameplay duration when a speed is supplied,
	# so a 2.2 s reload animation covers a 2.2 s reload.
	anim_tree.set("parameters/action/time_scale", maxf(speed, 0.05)) # ignored if absent
	anim_tree.set(PARAM_ACTION, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func abort_action() -> void:
	if anim_tree:
		anim_tree.set(PARAM_ACTION, AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)


func is_action_playing() -> bool:
	return anim_tree != null and bool(anim_tree.get(PARAM_ACTION_ACTIVE))


## Play a death animation chosen by the killing blow, then stop the tree so the
## body holds its final pose instead of snapping back to idle.
func play_death(zone: int) -> void:
	if anim_player == null:
		return
	if anim_tree:
		anim_tree.active = false
	var logical := "death"
	if zone == CharacterBase.Zone.HEAD:
		logical = "death_head"
	elif zone == CharacterBase.Zone.LIMB:
		logical = "death_back"
	var n := anim_name(logical)
	if n == "":
		n = anim_name("death")
	if n != "":
		var a := anim_player.get_animation(n)
		if a:
			a.loop_mode = Animation.LOOP_NONE
		anim_player.play(n, 0.08)


func revive() -> void:
	if anim_tree:
		anim_tree.active = true


# ---------------------------------------------------------------------------
# First person self-visibility
# ---------------------------------------------------------------------------

## In first person the local player must see their own legs and torso but not
## their head (the camera is inside it) or their third-person arms (the
## viewmodel provides those). Collapsing the shoulder bones removes the arms
## without a second mesh or a shader variant.
func set_first_person(enabled: bool) -> void:
	first_person = enabled
	if _head_mesh:
		_head_mesh.visible = not enabled
	if skeleton:
		for bone_name in FP_HIDE_BONES:
			var idx := skeleton.find_bone(bone_name)
			if idx >= 0:
				# Scaling to a hair above zero keeps the skinning matrices
				# well-conditioned; exact zero can produce NaNs on some drivers.
				skeleton.set_bone_pose_scale(idx, Vector3.ONE * (0.001 if enabled else 1.0))
	# The body must still cast a shadow and be visible to the camera, so only
	# the head is hidden — never the whole mesh.
	for m in _body_meshes:
		m.visible = true
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


## Third-person visibility for other players (and for the local player in a
## kill-cam or spectator view).
func set_third_person() -> void:
	set_first_person(false)


## Swap the palette atlas for a team/variant skin. Materials come out of the
## pipeline as a single atlas-textured material per mesh.
func set_skin(atlas: Texture2D) -> void:
	if atlas == null:
		return
	for m in _body_meshes:
		_apply_atlas(m, atlas)
	if _head_mesh:
		_apply_atlas(_head_mesh, atlas)


func _apply_atlas(gi: GeometryInstance3D, atlas: Texture2D) -> void:
	var mi := gi as MeshInstance3D
	if mi == null or mi.mesh == null:
		return
	for s in mi.mesh.get_surface_count():
		var base := mi.get_active_material(s)
		if base is StandardMaterial3D:
			var m := (base as StandardMaterial3D).duplicate() as StandardMaterial3D
			m.albedo_texture = atlas
			mi.set_surface_override_material(s, m)


# ---------------------------------------------------------------------------

func _find_node_of_type(root: Node, type_name: String) -> Node:
	if root == null:
		return null
	if root.is_class(type_name):
		return root
	for c in root.get_children():
		var r := _find_node_of_type(c, type_name)
		if r:
			return r
	return null


func _all_descendants(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	_gather(root, out)
	return out


func _gather(n: Node, out: Array[Node]) -> void:
	for c in n.get_children():
		out.append(c)
		_gather(c, out)
