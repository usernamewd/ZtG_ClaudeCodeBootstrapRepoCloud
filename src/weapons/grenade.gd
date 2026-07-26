class_name Grenade
extends RigidBody3D
## Thrown equipment: frag, flash, smoke, incendiary. One script, four behaviours
## driven by the WeaponDB definition, so balance lives in the database.
##
## Pooled via the Pools autoload — never queue_free, always Pools.release(self).

signal detonated(kind: String, pos: Vector3)

const BOUNCE_SFX := ["grenade_bounce_1", "grenade_bounce_2", "grenade_bounce_3"]

var kind: String = "frag"
var thrower_id: int = -1
var thrower_team: int = -1

var _def: Dictionary = {}
var _fuse: float = 0.0
var _armed: bool = false
var _bounce_cooldown: float = 0.0
var _thrower: CharacterBase = null

@onready var _mesh: Node3D = get_node_or_null("Mesh")


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 4
	gravity_scale = 1.0
	continuous_cd = true
	body_entered.connect(_on_body_entered)
	set_physics_process(false)


func on_pool_acquire() -> void:
	_armed = false
	_fuse = 0.0
	_bounce_cooldown = 0.0
	freeze = false
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	set_physics_process(false)


func throw(p_kind: String, from: Vector3, dir: Vector3, thrower: CharacterBase,
		charge := 1.0) -> void:
	kind = p_kind
	_def = WeaponDB.get_def(p_kind)
	_thrower = thrower
	thrower_id = thrower.player_id if thrower else -1
	thrower_team = thrower.team if thrower else -1

	global_position = from
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3(
		randf_range(-6.0, 6.0), randf_range(-6.0, 6.0), randf_range(-6.0, 6.0))

	var speed: float = float(_def.get("throw_speed", 18.0)) * clampf(charge, 0.35, 1.0)
	var up: float = float(_def.get("throw_up", 2.6))
	linear_velocity = dir.normalized() * speed + Vector3.UP * up
	# Inherit the thrower's momentum so running throws travel further, the way a
	# player expects.
	if thrower:
		linear_velocity += Vector3(thrower.velocity.x, 0.0, thrower.velocity.z) * 0.5

	physics_material_override = physics_material_override if physics_material_override else PhysicsMaterial.new()
	physics_material_override.bounce = float(_def.get("bounce", 0.35))
	physics_material_override.friction = 0.6

	_fuse = float(_def.get("fuse_time", 2.0))
	_armed = true
	set_physics_process(true)
	AudioMgr.play_3d("grenade_pin", from)


func _physics_process(delta: float) -> void:
	if not _armed:
		return
	_bounce_cooldown = maxf(0.0, _bounce_cooldown - delta)
	_fuse -= delta
	if _fuse <= 0.0:
		_detonate()


func _on_body_entered(_body: Node) -> void:
	if not _armed:
		return
	if bool(_def.get("detonate_on_impact", false)):
		_detonate()
		return
	if _bounce_cooldown <= 0.0 and linear_velocity.length() > 2.0:
		_bounce_cooldown = 0.12
		AudioMgr.play_3d(BOUNCE_SFX[randi() % BOUNCE_SFX.size()], global_position,
			-6.0, randf_range(0.9, 1.1))


func _detonate() -> void:
	_armed = false
	set_physics_process(false)
	var pos := global_position
	detonated.emit(kind, pos)

	match kind:
		"frag":
			_do_frag(pos)
		"flash":
			_do_flash(pos)
		"smoke":
			_do_smoke(pos)
		"incendiary":
			_do_incendiary(pos)

	Pools.release(self)


# --- Effects ---------------------------------------------------------------

func _do_frag(pos: Vector3) -> void:
	AudioMgr.play_3d("frag_explode", pos, 4.0)
	_spawn_effect("frag_blast", pos)
	var radius: float = float(_def.get("blast_radius", 7.0))
	var max_dmg: float = float(_def.get("max_damage", 98.0))
	for n in _combatants():
		var c := n as CharacterBase
		if c == null or not c.alive:
			continue
		var d: float = c.global_position.distance_to(pos)
		if d > radius:
			continue
		# Cover blocks blast: no damage through a wall.
		if not _blast_reaches(pos, c):
			continue
		# Quadratic falloff reads better than linear — close is lethal, the edge
		# is a scratch.
		var t: float = 1.0 - d / radius
		var dmg: float = max_dmg * t * t
		if dmg < 1.0:
			continue
		var dir: Vector3 = (c.global_position - pos).normalized()
		c.take_damage(dmg, CharacterBase.Zone.CHEST, thrower_id, kind, dir, 1.0)


func _do_flash(pos: Vector3) -> void:
	AudioMgr.play_3d("flash_bang", pos, 6.0)
	_spawn_effect("flash_blast", pos)
	var radius: float = float(_def.get("blast_radius", 14.0))
	var full_time: float = float(_def.get("effect_time", 3.4))
	for n in _combatants():
		var c := n as CharacterBase
		if c == null or not c.alive:
			continue
		var d: float = c.global_position.distance_to(pos)
		if d > radius:
			continue
		if not _blast_reaches(pos, c):
			continue
		# Blindness scales with how much the victim was looking at the flash and
		# how close it was — turning away must actually help.
		var to_flash: Vector3 = pos - c.eye_position()
		if to_flash.length_squared() < 0.0001:
			continue
		to_flash = to_flash.normalized()
		var facing: Vector3 = -c.global_transform.basis.z
		if c.has_method("look_direction"):
			facing = c.look_direction()
		var dot: float = facing.dot(to_flash)
		if dot <= 0.0:
			continue                       # fully turned away
		var view_factor: float = clampf((dot - 0.1) / 0.9, 0.0, 1.0)
		var dist_factor: float = 1.0 - d / radius
		var duration: float = full_time * view_factor * dist_factor
		if duration < 0.25:
			continue
		if c.has_method("apply_flash"):
			c.apply_flash(duration)


func _do_smoke(pos: Vector3) -> void:
	AudioMgr.play_3d("smoke_pop", pos, 0.0)
	# The smoke volume is a real, persistent, vision-blocking node: bots test
	# their line of sight against it and the shader renders it.
	var vol := _spawn_effect("smoke_volume", pos)
	if vol and vol.has_method("begin"):
		vol.begin(float(_def.get("blast_radius", 4.6)),
			float(_def.get("effect_time", 16.0)))


func _do_incendiary(pos: Vector3) -> void:
	AudioMgr.play_3d("incendiary_ignite", pos, 2.0)
	var fire := _spawn_effect("fire_area", pos)
	if fire and fire.has_method("begin"):
		fire.begin(float(_def.get("blast_radius", 4.0)),
			float(_def.get("effect_time", 7.0)),
			float(_def.get("dps", 28.0)),
			thrower_id, kind)


# --- Helpers ---------------------------------------------------------------

func _combatants() -> Array:
	return get_tree().get_nodes_in_group("combatant")


func _blast_reaches(from: Vector3, c: CharacterBase) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		from, c.global_position + Vector3.UP * 0.9,
		CharacterBase.LAYER_WORLD | CharacterBase.LAYER_CLIP)
	q.exclude = [get_rid()]
	return space.intersect_ray(q).is_empty()


func _spawn_effect(pool_key: String, pos: Vector3) -> Node:
	var n := Pools.acquire(pool_key, get_tree().current_scene)
	if n is Node3D:
		(n as Node3D).global_position = pos
	return n
