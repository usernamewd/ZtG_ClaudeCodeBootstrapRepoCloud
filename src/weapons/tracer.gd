class_name BulletTracer
extends Node3D
## Pooled bullet tracer: a thin stretched box that runs from the muzzle to the
## impact point in TRAVEL_TIME, then releases itself back to the Pools autoload.
## Acquired through Pools, never instantiated per shot.
##
## Scene contract (scenes/weapons/tracer.tscn, built by tools/build_weapon_fx.gd):
##   Tracer  Node3D  (this script)
##     Beam  MeshInstance3D — unit-length box along -Z, unshaded additive.
## All look-and-feel lives in the scene; this script only moves and scales it.

const TRAVEL_TIME := 0.04
## Visible length of the streak; short shots show the whole segment.
const TRAIL_MAX := 7.0
const TRAIL_MIN := 1.0
const TRAIL_FRACTION := 0.35
const MIN_LENGTH := 0.05

var _beam: MeshInstance3D = null
var _dist: float = 0.0
var _trail: float = 0.0
var _t: float = 0.0


func _ready() -> void:
	_beam = get_node_or_null(^"Beam") as MeshInstance3D
	visible = false
	set_process(false)


func on_pool_acquire() -> void:
	_t = 0.0
	_dist = 0.0
	visible = false
	set_process(false)


## from/to are world space. Called right after Pools.acquire().
func begin(from: Vector3, to: Vector3) -> void:
	if _beam == null:
		Pools.release(self)
		return
	var delta := to - from
	_dist = delta.length()
	if _dist < MIN_LENGTH:
		Pools.release(self)
		return
	var dir := delta / _dist
	global_transform = Transform3D(_basis_facing(-dir), from)
	_trail = clampf(_dist * TRAIL_FRACTION, TRAIL_MIN, TRAIL_MAX)
	_t = 0.0
	visible = true
	_apply()
	set_process(true)


func _process(delta: float) -> void:
	_t += delta
	if _t >= TRAVEL_TIME:
		visible = false
		set_process(false)
		Pools.release(self)
		return
	_apply()


## Stretches the beam between the tail and the head of the streak. -Z is
## forward, so both offsets are negative.
func _apply() -> void:
	var head: float = minf(_dist * (_t / TRAVEL_TIME), _dist)
	var tail: float = maxf(head - _trail, 0.0)
	var length: float = head - tail
	if length < MIN_LENGTH:
		length = MIN_LENGTH
	_beam.scale.z = length
	_beam.position.z = -(tail + length * 0.5)


## Orthonormal basis whose Z axis is `z`, avoiding the colinear-up case that
## makes look_at() error out on vertical shots.
static func _basis_facing(z: Vector3) -> Basis:
	var up := Vector3.UP if absf(z.y) < 0.99 else Vector3.RIGHT
	var x := up.cross(z).normalized()
	var y := z.cross(x)
	return Basis(x, y, z)
