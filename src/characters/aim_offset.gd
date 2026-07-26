class_name AimOffset
extends SkeletonModifier3D
## Bends the spine so a character's upper body tracks where they are actually
## aiming, on top of whatever locomotion animation is playing.
##
## Without this, a third-person character aiming at the sky still holds their
## rifle level and the world model disagrees with where their bullets go. A
## SkeletonModifier3D runs *after* the AnimationTree writes its poses, which is
## the only place this can work — setting bone poses from _process gets
## overwritten by the animation every frame.
##
## The pitch is distributed across several spine bones so the bend looks like a
## body leaning rather than a hinge snapping at one joint.

## Bones that share the pitch, and how much of it each takes. Weights are
## normalized on resolve, so they read as relative contributions.
const SPINE_CHAIN := [
	{"bone": "Abdomen", "weight": 0.22},
	{"bone": "Torso", "weight": 0.48},
	{"bone": "Neck", "weight": 0.30},
]

## Clamp so the model can't fold in half at extreme pitches.
const MAX_UP_DEG := 55.0
const MAX_DOWN_DEG := 50.0

## Degrees the whole chain yaws to cover a body/aim yaw mismatch (bots and remote
## players turn their body toward the aim, so this stays small).
const MAX_YAW_DEG := 35.0

@export var pitch_deg: float = 0.0
@export var yaw_deg: float = 0.0
@export var lean_deg: float = 0.0          ## roll, used for a subtle strafe lean

var _bone_ids: PackedInt32Array = PackedInt32Array()
var _weights: PackedFloat32Array = PackedFloat32Array()
var _resolved := false


func _ready() -> void:
	# Resolve lazily: the skeleton may not be assigned yet on the first frame.
	_resolved = false


func _resolve() -> void:
	_resolved = true
	_bone_ids.clear()
	_weights.clear()
	var sk := get_skeleton()
	if sk == null:
		return
	var total := 0.0
	for entry in SPINE_CHAIN:
		var idx := sk.find_bone(String(entry.bone))
		if idx < 0:
			continue
		_bone_ids.append(idx)
		_weights.append(float(entry.weight))
		total += float(entry.weight)
	if total > 0.0:
		for i in _weights.size():
			_weights[i] = _weights[i] / total


func _process_modification() -> void:
	if not _resolved:
		_resolve()
	var sk := get_skeleton()
	if sk == null or _bone_ids.is_empty():
		return

	var pitch := deg_to_rad(clampf(pitch_deg, -MAX_DOWN_DEG, MAX_UP_DEG))
	var yaw := deg_to_rad(clampf(yaw_deg, -MAX_YAW_DEG, MAX_YAW_DEG))
	var roll := deg_to_rad(clampf(lean_deg, -12.0, 12.0))

	for i in _bone_ids.size():
		var bone: int = _bone_ids[i]
		var w: float = _weights[i]
		# Compose onto the animated pose rather than replacing it, so the
		# locomotion animation still drives the bone and we only add the bend.
		var extra := Quaternion(Vector3.RIGHT, -pitch * w) \
			* Quaternion(Vector3.UP, yaw * w) \
			* Quaternion(Vector3.FORWARD, roll * w)
		sk.set_bone_pose_rotation(bone, sk.get_bone_pose_rotation(bone) * extra)
