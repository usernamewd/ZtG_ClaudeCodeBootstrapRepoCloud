class_name Bomb
extends Node3D
## The plantable objective. Original design — a boxy demolition charge with a
## keypad and antenna (see tools/assets/build_weapons.py).
##
## Lifecycle: carried by an attacker -> planted in a site Area3D -> ticks down ->
## explodes, unless a defender completes a defuse. The match controller owns the
## round outcome; this node owns the device's own state, its beeping and its
## explosion.

signal planted(site: String)
signal defused(defuser_id: int)
signal exploded
signal defuse_progress(fraction: float)

enum State { CARRIED, DROPPED, PLANTED, DEFUSED, EXPLODED }

const BEEP_SLOW := 1.0        ## s between beeps just after the plant
const BEEP_FAST := 0.12       ## s between beeps at zero
const EXPLOSION_RADIUS := 22.0
const EXPLOSION_MAX_DAMAGE := 500.0

var state: int = State.CARRIED
var site: String = ""
var fuse_left: float = 0.0
var carrier: CharacterBase = null

## Defuse state — a defuse is interruptible and loses all progress, so a
## defender who gets shot off the bomb has to start over.
var defuser: CharacterBase = null
var defuse_elapsed: float = 0.0
var defuse_needed: float = 0.0

var _beep_accum: float = 0.0
var _light: Node3D = null


func _ready() -> void:
	add_to_group("bomb")
	_light = get_node_or_null("Blinker")
	set_physics_process(false)


func attach_to(c: CharacterBase) -> void:
	state = State.CARRIED
	carrier = c
	visible = false
	set_physics_process(false)


func drop_at(pos: Vector3) -> void:
	state = State.DROPPED
	carrier = null
	global_position = pos
	visible = true
	set_physics_process(false)
	add_to_group("dropped_bomb")


func plant(at: Vector3, p_site: String, fuse: float) -> void:
	remove_from_group("dropped_bomb")
	add_to_group("planted_bomb")
	state = State.PLANTED
	site = p_site
	fuse_left = fuse
	carrier = null
	global_position = at
	# Sit flat on the ground regardless of how the planter was facing.
	rotation = Vector3(0.0, rotation.y, 0.0)
	visible = true
	_beep_accum = 0.0
	set_physics_process(true)
	AudioMgr.play_3d("bomb_plant", at, 2.0)
	planted.emit(site)


func _physics_process(delta: float) -> void:
	if state != State.PLANTED:
		return

	fuse_left -= delta

	# The beep interval collapses as the fuse runs out — the audible clock that
	# tells everyone how long a retake has.
	var t := 1.0 - clampf(fuse_left / maxf(GameState.cfg_bomb_time, 0.01), 0.0, 1.0)
	var interval := lerpf(BEEP_SLOW, BEEP_FAST, t * t)
	_beep_accum += delta
	if _beep_accum >= interval:
		_beep_accum = 0.0
		AudioMgr.play_3d("bomb_beep", global_position, -2.0, lerpf(1.0, 1.6, t))
		if _light:
			_light.visible = not _light.visible

	if defuser != null:
		_tick_defuse(delta)

	if fuse_left <= 0.0:
		_explode()


func _tick_defuse(delta: float) -> void:
	if not is_instance_valid(defuser) or not defuser.alive:
		cancel_defuse()
		return
	# Walking off the bomb cancels, same as taking the hands off it.
	if defuser.global_position.distance_to(global_position) > 2.2:
		cancel_defuse()
		return
	defuse_elapsed += delta
	defuse_progress.emit(clampf(defuse_elapsed / maxf(defuse_needed, 0.01), 0.0, 1.0))
	if defuse_elapsed >= defuse_needed:
		_complete_defuse()


func begin_defuse(c: CharacterBase) -> bool:
	if state != State.PLANTED or defuser != null:
		return false
	if c.global_position.distance_to(global_position) > 2.2:
		return false
	defuser = c
	defuse_elapsed = 0.0
	defuse_needed = GameState.cfg_defuse_kit_time if c.has_defuse_kit else GameState.cfg_defuse_time
	AudioMgr.play_3d("defuse_loop", global_position, -4.0)
	return true


func cancel_defuse() -> void:
	if defuser == null:
		return
	defuser = null
	defuse_elapsed = 0.0
	defuse_progress.emit(0.0)


## Would this defuser actually finish in time? Bots use this to avoid starting a
## 10 s defuse with 6 s on the clock.
func defuse_would_succeed(c: CharacterBase) -> bool:
	var need: float = GameState.cfg_defuse_kit_time if c.has_defuse_kit else GameState.cfg_defuse_time
	return fuse_left >= need


func _complete_defuse() -> void:
	var id := defuser.player_id if defuser else -1
	state = State.DEFUSED
	set_physics_process(false)
	if _light:
		_light.visible = false
	AudioMgr.play_3d("defuse_complete", global_position, 2.0)
	defused.emit(id)


func _explode() -> void:
	state = State.EXPLODED
	set_physics_process(false)
	var pos := global_position
	AudioMgr.play_3d("bomb_explode", pos, 8.0)
	var fx := Pools.acquire("bomb_blast", get_tree().current_scene)
	if fx is Node3D:
		(fx as Node3D).global_position = pos
	visible = false

	# Everyone near the site dies; the falloff only matters at the edge.
	for n in get_tree().get_nodes_in_group("combatant"):
		var c := n as CharacterBase
		if c == null or not c.alive:
			continue
		var d := c.global_position.distance_to(pos)
		if d > EXPLOSION_RADIUS:
			continue
		var t := 1.0 - d / EXPLOSION_RADIUS
		c.take_damage(EXPLOSION_MAX_DAMAGE * t, CharacterBase.Zone.CHEST, -1,
			"bomb", (c.global_position - pos).normalized(), 1.0)

	exploded.emit()


func reset() -> void:
	remove_from_group("planted_bomb")
	remove_from_group("dropped_bomb")
	state = State.CARRIED
	site = ""
	fuse_left = 0.0
	carrier = null
	defuser = null
	defuse_elapsed = 0.0
	visible = false
	set_physics_process(false)
	if _light:
		_light.visible = false
