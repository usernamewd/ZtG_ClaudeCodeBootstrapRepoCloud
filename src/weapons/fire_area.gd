class_name FireArea
extends Node3D
## Incendiary burn zone: denies ground for a duration, damaging anyone standing
## in it. Damage ticks on a timer rather than per frame so the cost is fixed
## regardless of frame rate, and so the damage numbers are frame-rate honest.
## Pooled.

const TICK := 0.25            ## s between damage applications

var radius: float = 4.0
var life: float = 7.0
var dps: float = 28.0
var owner_id: int = -1
var weapon_id: String = "incendiary"

var _age: float = 0.0
var _tick_accum: float = 0.0
var _active: bool = false
var _mesh: Node3D = null


func _ready() -> void:
	add_to_group("fire_area")
	_mesh = get_node_or_null("Mesh")
	set_process(false)


func on_pool_acquire() -> void:
	_age = 0.0
	_tick_accum = 0.0
	_active = false
	visible = false
	set_process(false)


func begin(p_radius: float, p_life: float, p_dps: float, p_owner: int,
		p_weapon: String) -> void:
	radius = p_radius
	life = p_life
	dps = p_dps
	owner_id = p_owner
	weapon_id = p_weapon
	_age = 0.0
	_tick_accum = 0.0
	_active = true
	visible = true
	if _mesh:
		_mesh.scale = Vector3(radius, 1.0, radius)
	set_process(true)
	AudioMgr.play_3d("fire_loop", global_position, -4.0)


func _process(delta: float) -> void:
	if not _active:
		return
	_age += delta
	_tick_accum += delta

	if _tick_accum >= TICK:
		_tick_accum -= TICK
		_apply_damage(TICK)

	if _age >= life:
		_active = false
		visible = false
		set_process(false)
		Pools.release(self)


func _apply_damage(dt: float) -> void:
	var r_sq := radius * radius
	for n in get_tree().get_nodes_in_group("combatant"):
		var c := n as CharacterBase
		if c == null or not c.alive:
			continue
		# Compare on the horizontal plane and allow a small vertical band, so a
		# player on a crate above the fire isn't burned through the crate.
		var d := c.global_position - global_position
		if absf(d.y) > 2.0:
			continue
		d.y = 0.0
		if d.length_squared() > r_sq:
			continue
		c.take_damage(dps * dt, CharacterBase.Zone.LIMB, owner_id, weapon_id,
			Vector3.UP, 1.0)


## Is this area covering a point? Used by bots to avoid walking into fire.
func covers(pos: Vector3) -> bool:
	if not _active:
		return false
	var d := pos - global_position
	if absf(d.y) > 2.0:
		return false
	d.y = 0.0
	return d.length_squared() <= radius * radius
