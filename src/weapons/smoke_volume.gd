class_name SmokeVolume
extends Node3D
## A real vision-blocking smoke cloud, not a particle decoration.
##
## Three consumers rely on this node:
##   - bots test line of sight against group "smoke_volume" using meta "radius"
##   - the player's weapon rays terminate vision the same way
##   - the renderer draws the billowing sphere
## Pooled: release back to Pools, never queue_free.

const GROW_TIME := 1.1        ## s to reach full radius after the pop
const FADE_TIME := 2.0        ## s of dissipation at the end

var radius: float = 4.6
var life: float = 16.0

var _age: float = 0.0
var _active: bool = false
var _mesh: MeshInstance3D = null
var _base_scale: float = 1.0


func _ready() -> void:
	add_to_group("smoke_volume")
	_mesh = get_node_or_null("Mesh")
	set_process(false)
	set_meta("radius", 0.0)


func on_pool_acquire() -> void:
	_age = 0.0
	_active = false
	set_meta("radius", 0.0)
	visible = false
	set_process(false)


func begin(p_radius: float, p_life: float) -> void:
	radius = p_radius
	life = p_life
	_age = 0.0
	_active = true
	visible = true
	set_process(true)
	AudioMgr.play_3d("smoke_hiss_loop", global_position, -8.0)


func _process(delta: float) -> void:
	if not _active:
		return
	_age += delta

	# Grow in, hold, then dissipate. The blocking radius follows the visual
	# exactly — a cloud that looks thin must not still block bot vision.
	var r := radius
	if _age < GROW_TIME:
		r = radius * ease(_age / GROW_TIME, 0.4)
	elif _age > life - FADE_TIME:
		var t := clampf((life - _age) / FADE_TIME, 0.0, 1.0)
		r = radius * t
	set_meta("radius", r)

	if _mesh:
		_mesh.scale = Vector3.ONE * maxf(r, 0.001)
		# Slow churn so the cloud reads as volume rather than a static ball.
		_mesh.rotation.y += delta * 0.12
		var mat := _mesh.get_active_material(0)
		if mat is StandardMaterial3D:
			var a := 1.0
			if _age > life - FADE_TIME:
				a = clampf((life - _age) / FADE_TIME, 0.0, 1.0)
			(mat as StandardMaterial3D).albedo_color.a = a * 0.94

	if _age >= life:
		_active = false
		set_meta("radius", 0.0)
		visible = false
		set_process(false)
		Pools.release(self)


## Does this cloud block the segment a->b right now?
func blocks_segment(a: Vector3, b: Vector3) -> bool:
	var r: float = get_meta("radius", 0.0)
	if r <= 0.01:
		return false
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return a.distance_squared_to(global_position) < r * r
	var t := clampf((global_position - a).dot(ab) / len_sq, 0.0, 1.0)
	return (a + ab * t).distance_squared_to(global_position) < r * r
