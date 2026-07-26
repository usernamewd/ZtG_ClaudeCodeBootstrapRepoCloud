class_name BulletImpact
extends Node3D
## Pooled bullet impact: a one-shot spark/dust burst plus a decal-ish quad that
## fades out, then releases itself back to the Pools autoload.
##
## Scene contract (scenes/weapons/impact.tscn, built by tools/build_weapon_fx.gd):
##   Impact   Node3D  (this script)
##     Sparks CPUParticles3D — one_shot, emits along local +Z
##     Decal  MeshInstance3D — quad in the local XY plane (faces +Z)
## The node is oriented with +Z along the surface normal, so both children work
## in surface space. Visuals live entirely in the scene.

const LIFE := 1.1
const FADE_AT := 0.55
## Lifts the quad off the surface so it does not z-fight with the wall.
const NORMAL_OFFSET := 0.014
const FLESH_DECAL := Color(0.36, 0.02, 0.03, 0.0)
const FLESH_SPARK := Color(0.78, 0.10, 0.11)

var _sparks: CPUParticles3D = null
var _decal: MeshInstance3D = null
## Per-instance copy: pooled impacts must fade independently of each other.
var _mat: StandardMaterial3D = null
var _base_decal: Color = Color(0.05, 0.05, 0.06, 0.85)
var _base_spark: Color = Color(1.0, 0.85, 0.55)
var _alpha0: float = 0.85
var _t: float = 0.0


func _ready() -> void:
	_sparks = get_node_or_null(^"Sparks") as CPUParticles3D
	_decal = get_node_or_null(^"Decal") as MeshInstance3D
	if _decal != null:
		var src := _decal.material_override as StandardMaterial3D
		if src != null:
			_mat = src.duplicate() as StandardMaterial3D
			_decal.material_override = _mat
			_base_decal = _mat.albedo_color
	if _sparks != null:
		_base_spark = _sparks.color
		_sparks.emitting = false
	visible = false
	set_process(false)


func on_pool_acquire() -> void:
	_t = 0.0
	visible = false
	set_process(false)


## `normal` is the surface normal at the hit; `flesh` swaps to a blood-ish burst
## and drops the decal (bodies must not be left with holes stuck in mid-air).
func begin(pos: Vector3, normal: Vector3, flesh := false) -> void:
	var n := normal
	if n.length_squared() < 0.000001:
		n = Vector3.UP
	else:
		n = n.normalized()
	global_transform = Transform3D(_basis_facing(n), pos + n * NORMAL_OFFSET)
	if _decal != null:
		_decal.visible = not flesh
	if _mat != null:
		var c := FLESH_DECAL if flesh else _base_decal
		_alpha0 = c.a
		c.a = _alpha0
		_mat.albedo_color = c
	if _sparks != null:
		_sparks.color = FLESH_SPARK if flesh else _base_spark
		_sparks.restart()
	_t = 0.0
	visible = true
	set_process(true)


func _process(delta: float) -> void:
	_t += delta
	if _t >= LIFE:
		visible = false
		set_process(false)
		if _sparks != null:
			_sparks.emitting = false
		Pools.release(self)
		return
	if _mat != null and _t > FADE_AT:
		var c := _mat.albedo_color
		c.a = _alpha0 * (1.0 - (_t - FADE_AT) / (LIFE - FADE_AT))
		_mat.albedo_color = c


static func _basis_facing(z: Vector3) -> Basis:
	var up := Vector3.UP if absf(z.y) < 0.99 else Vector3.RIGHT
	var x := up.cross(z).normalized()
	var y := z.cross(x)
	return Basis(x, y, z)
