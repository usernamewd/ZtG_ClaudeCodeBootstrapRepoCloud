class_name Weapon
extends Node3D
## Runtime firing system for one held weapon. Used unchanged by the local player
## (aim_source = its Camera3D) and by bots (aim_source = their Eye Node3D).
## All balance comes from WeaponDB.get_def(id); this file only turns a def plus a
## trigger state into hitscan damage, recoil and pooled effects.
##
## Integration (docs/ARCHITECTURE.md "Weapons"):
##   setup(id, character, aim_source)   once per equip (re-callable)
##   set_trigger(bool)                  player: pushed on change
##   try_fire()                         bots: one pulse per call, rate limited
##   start_reload() / reload()          both
##   camera_kick() -> Vector2           accumulated recoil, deg (x yaw, y pitch)
##   current_spread_deg() -> float      cone half-angle for the dynamic crosshair
##
## Node contract (all optional, looked up by name at setup, any depth):
##   Muzzle     Marker3D — muzzle flash origin / tracer start / fire sfx position
##   ShellPort  Marker3D — shell ejection origin
## Both arrive with the Phase 2 models; absent is fine and silent.

signal fired(recoil_kick: Vector2)
signal ammo_changed(mag: int, reserve: int)
signal reload_started(duration: float)
signal reload_finished()
signal hit_confirmed(zone: int, died: bool)
signal state_changed(state: int)

enum State { DRAWING, READY, FIRING, RELOADING }
## BULLET = hitscan gun, MELEE = knife swing, INERT = grenade/gear/unknown id
## (grenade throwing lives in the thrower, not here).
enum Mode { INERT, BULLET, MELEE }

# Physics layers, project.godot [layer_names]. Rays test world + hitbox; smoke
# (layer 7) is deliberately not in the mask, it only blocks vision.
const LAYER_WORLD := 1
const LAYER_HITBOX := 8
const RAY_MASK := LAYER_WORLD | LAYER_HITBOX

const MAX_RANGE := 300.0
## Idle time before the recoil pattern restarts and the kick starts decaying.
const RECOIL_RESET_DELAY := 0.25
## How much accumulated recoil bleeds into the cone. Small on purpose: the kick
## is already applied to the aim direction (bots) or the camera (player).
const RECOIL_SPREAD_MULT := 0.14
const PEN_MAX := 2
## Thickness a penetration of 1.0 can punch through (ARCHITECTURE.md: 0.35 m).
const PEN_THICKNESS_AT_FULL := 0.35
const PEN_DAMAGE_BASE := 0.5
const PEN_STEP := 0.01
const PEN_MIN_MULT := 0.06
const DRY_FIRE_DELAY := 0.3
const MELEE_RADIUS := 0.22
const MELEE_BACK_DOT := 0.35
const TRACER_MIN_DIST := 0.6
const MAX_TRACERS_PER_SHOT := 2
## One physics tick of slack, so the rate accumulator can carry a remainder
## without banking shots after an idle period.
const COOLDOWN_FLOOR := -0.034

const TRACER_POOL := "wpn_tracer"
const IMPACT_POOL := "wpn_impact"
## Filled by Phase 2 with the models; acquire() simply returns null until then.
const MUZZLE_POOL := "wpn_muzzleflash"
const SHELL_POOL := "wpn_shell"
const TRACER_SCENE_PATH := "res://scenes/weapons/tracer.tscn"
const IMPACT_SCENE_PATH := "res://scenes/weapons/impact.tscn"
const TRACER_POOL_SIZE := 16
const IMPACT_POOL_SIZE := 32

const EMPTY_PATTERN: Array[Vector2] = []

## Set false when the aim source already carries the recoil (the player camera
## does: it rotates by its own recoil offset, so adding it here would double it).
## setup() auto-detects that case from the "player" group.
@export var apply_recoil_to_aim: bool = true
## Mobile quality of life: pulling the trigger on an empty magazine reloads.
@export var auto_reload_on_empty: bool = true
## Re-run setup() when the owner draws a different slot (bots keep one Weapon
## node; the player builds a new one per switch and is unaffected).
@export var follow_owner_slot: bool = true

var weapon_id: String = ""
var weapon_def: Dictionary = {}
var owner_char: CharacterBase = null
var aim_source: Node3D = null

var state: int = State.DRAWING
## Index into recoil_pattern; climbs per shot, resets after RECOIL_RESET_DELAY.
var recoil_index: int = 0

# --- cached def ------------------------------------------------------------
var _mode: int = Mode.INERT
var _damage: float = 0.0
var _pellets: int = 1
var _fire_interval: float = 0.1
var _auto: bool = false
var _mag_size: int = 0
var _reload_time: float = 0.0
var _draw_time: float = 0.0
var _spread_base: float = 0.0
var _spread_move: float = 0.0
var _spread_air: float = 0.0
var _ads_spread_mult: float = 1.0
var _ads_time: float = 0.15
var _recoil_recovery: float = 20.0
var _pattern: Array = EMPTY_PATTERN
var _penetration: float = 0.0
var _pen_thickness: float = 0.0
var _fall_start: float = 30.0
var _fall_end: float = 60.0
var _fall_min: float = 1.0
var _headshot_mult: float = 4.0
var _burst_count: int = 0
var _burst_interval: float = 0.08
var _burst_delay: float = 0.0
var _shell_reload: bool = false
var _shell_time: float = 0.5
var _melee_range: float = 1.9
var _melee_heavy_damage: float = 0.0
var _melee_heavy_interval: float = 1.2
var _back_mult: float = 1.0
var _fire_sfx: String = ""
var _reload_sfx: String = ""
var _draw_sfx: String = ""
var _empty_sfx: String = ""

# --- live state ------------------------------------------------------------
var _cooldown: float = 0.0
var _draw_left: float = 0.0
var _reload_left: float = 0.0
var _shell_left: float = 0.0
var _shot_idle: float = 99.0
var _recoil: Vector2 = Vector2.ZERO
var _last_kick: Vector2 = Vector2.ZERO
var _trigger_held: bool = false
var _trigger_pulled: bool = false
var _burst_left: int = 0
var _ads_blend: float = 0.0
var _dry_left: float = 0.0

# --- preallocated scratch (never rebuilt per shot) -------------------------
var _query: PhysicsRayQueryParameters3D = null
var _exclude: Array[RID] = []
var _rng: RandomNumberGenerator = null
var _muzzle: Node3D = null
var _shell_port: Node3D = null
var _melee_cast: ShapeCast3D = null
var _dir: Vector3 = Vector3.FORWARD
var _origin: Vector3 = Vector3.ZERO
var _fwd: Vector3 = Vector3.FORWARD
var _right: Vector3 = Vector3.RIGHT
var _up: Vector3 = Vector3.UP
var _exit_point: Vector3 = Vector3.ZERO
var _tracer_end: Vector3 = Vector3.ZERO
var _runtime_ready: bool = false
var _owner_connected: bool = false

static var _fx_pools_ready: bool = false
static var _fx_pools_failed: bool = false


func _ready() -> void:
	_ensure_runtime()
	if not weapon_id.is_empty() and weapon_def.is_empty():
		# Properties were primed by the holder without a setup() call.
		setup(weapon_id, owner_char, aim_source)


func _ensure_runtime() -> void:
	if _runtime_ready:
		return
	_runtime_ready = true
	_query = PhysicsRayQueryParameters3D.new()
	_query.collide_with_bodies = true
	_query.collide_with_areas = false
	_query.hit_from_inside = false
	_query.collision_mask = RAY_MASK
	_rng = RandomNumberGenerator.new()
	_rng.randomize()


## Bind this weapon to a holder. Safe to call again to swap the held weapon.
## Parameter names are p_-prefixed only to avoid shadowing the members of the
## same name; the positional order is (weapon_id, owner_char, aim_source).
func setup(p_weapon_id: String, p_owner_char: CharacterBase, p_aim_source: Node3D) -> void:
	_ensure_runtime()
	weapon_id = p_weapon_id
	if p_owner_char != null:
		owner_char = p_owner_char
	if p_aim_source != null:
		aim_source = p_aim_source
	weapon_def = WeaponDB.get_def(weapon_id)
	_cache_def()
	_resolve_nodes()
	refresh_exclusions()
	_connect_owner()

	# The player camera is rotated by its own recoil offset already.
	if owner_char != null and owner_char.is_in_group(&"player"):
		apply_recoil_to_aim = false

	_cooldown = 0.0
	_reload_left = 0.0
	_shell_left = 0.0
	_burst_left = 0
	_trigger_held = false
	_trigger_pulled = false
	_dry_left = 0.0
	_recoil = Vector2.ZERO
	_last_kick = Vector2.ZERO
	recoil_index = 0
	_shot_idle = 99.0
	_ads_blend = 0.0
	set_physics_process(_mode != Mode.INERT)

	_draw_left = _draw_time
	if _draw_left > 0.0:
		_set_state(State.DRAWING)
		if not _draw_sfx.is_empty():
			AudioMgr.play_3d(_draw_sfx, _aim_origin())
	else:
		_set_state(State.READY)
	ammo_changed.emit(get_mag(), get_reserve())


## Convenience for spawners (bots): build, parent and bind in one call.
static func create_for(p_owner_char: CharacterBase, p_parent: Node,
		p_aim_source: Node3D) -> Weapon:
	if p_owner_char == null or p_parent == null:
		return null
	var w := Weapon.new()
	w.name = "Weapon"
	p_parent.add_child(w)
	w.setup(p_owner_char.current_weapon_id(), p_owner_char, p_aim_source)
	return w


func _cache_def() -> void:
	var d := weapon_def
	var cat := int(d.get("category", -1))
	if d.is_empty():
		_mode = Mode.INERT
	elif cat == WeaponDB.Cat.KNIFE:
		_mode = Mode.MELEE
	elif cat == WeaponDB.Cat.GRENADE or cat == WeaponDB.Cat.GEAR:
		_mode = Mode.INERT
	else:
		_mode = Mode.BULLET

	_damage = float(d.get("damage", 0.0))
	_pellets = maxi(int(d.get("pellets", 1)), 1)
	var rate: float = maxf(float(d.get("fire_rate", 6.0)), 0.01)
	_fire_interval = 1.0 / rate
	_auto = bool(d.get("auto", false))
	_mag_size = maxi(int(d.get("mag", 0)), 0)
	_reload_time = maxf(float(d.get("reload_time", 0.0)), 0.0)
	_draw_time = maxf(float(d.get("draw_time", 0.0)), 0.0)
	_spread_base = maxf(float(d.get("spread_base", 0.0)), 0.0)
	_spread_move = maxf(float(d.get("spread_move_add", 0.0)), 0.0)
	_spread_air = maxf(float(d.get("spread_air_add", 0.0)), 0.0)
	_ads_spread_mult = clampf(float(d.get("ads_spread_mult", 1.0)), 0.0, 4.0)
	_ads_time = maxf(float(d.get("ads_time", 0.15)), 0.01)
	_recoil_recovery = maxf(float(d.get("recoil_recovery", 20.0)), 0.0)
	var pat = d.get("recoil_pattern", EMPTY_PATTERN)
	_pattern = pat if pat is Array else EMPTY_PATTERN
	_penetration = clampf(float(d.get("penetration", 0.0)), 0.0, 1.0)
	_pen_thickness = PEN_THICKNESS_AT_FULL * _penetration
	_fall_start = maxf(float(d.get("range_falloff_start", 30.0)), 0.0)
	_fall_end = maxf(float(d.get("range_falloff_end", _fall_start)), _fall_start)
	_fall_min = clampf(float(d.get("falloff_min_mult", 1.0)), 0.0, 1.0)
	_headshot_mult = float(d.get("headshot_mult", WeaponDB.DEFAULT_HEADSHOT_MULT))
	_burst_count = maxi(int(d.get("burst_count", 0)), 0)
	_burst_interval = 1.0 / maxf(float(d.get("burst_rate", rate)), 0.01)
	_burst_delay = maxf(float(d.get("burst_delay", 0.0)), 0.0)
	_shell_reload = bool(d.get("shell_reload", false))
	_shell_time = maxf(float(d.get("reload_shell_time", 0.5)), 0.05)
	_melee_range = maxf(float(d.get("melee_range", 1.9)), 0.2)
	_melee_heavy_damage = float(d.get("damage_heavy", _damage * 1.8))
	_melee_heavy_interval = 1.0 / maxf(float(d.get("rate_heavy", 0.85)), 0.01)
	_back_mult = maxf(float(d.get("back_mult", 1.0)), 1.0)
	_fire_sfx = String(d.get("fire_sfx", ""))
	_reload_sfx = String(d.get("reload_sfx", ""))
	_draw_sfx = String(d.get("draw_sfx", ""))
	_empty_sfx = String(d.get("empty_sfx", ""))


func _resolve_nodes() -> void:
	_muzzle = find_child("Muzzle", true, false) as Node3D
	_shell_port = find_child("ShellPort", true, false) as Node3D
	if _mode == Mode.MELEE and _melee_cast == null:
		_build_melee_cast()


func _build_melee_cast() -> void:
	var sphere := SphereShape3D.new()
	sphere.radius = MELEE_RADIUS
	_melee_cast = ShapeCast3D.new()
	_melee_cast.name = "MeleeCast"
	_melee_cast.shape = sphere
	_melee_cast.enabled = false          # driven manually, never per frame
	_melee_cast.collide_with_areas = false
	_melee_cast.collide_with_bodies = true
	_melee_cast.collision_mask = RAY_MASK
	_melee_cast.max_results = 8
	add_child(_melee_cast)


## Rebuild the shooter's self-exclusion list (body + own hitboxes). Call again
## after the holder re-registers its hitboxes (model swap).
func refresh_exclusions() -> void:
	_exclude.clear()
	if owner_char != null:
		_exclude.append(owner_char.get_rid())
		for hb in owner_char.hitboxes:
			if hb != null:
				_exclude.append(hb.get_rid())
		if _melee_cast != null:
			_melee_cast.clear_exceptions()
			_melee_cast.add_exception(owner_char)
			for hb in owner_char.hitboxes:
				if hb != null:
					_melee_cast.add_exception(hb)
	if _query != null:
		# Assigned after filling: the setter copies, so mutating _exclude later
		# would not reach the query.
		_query.exclude = _exclude


func _connect_owner() -> void:
	if _owner_connected or owner_char == null or not follow_owner_slot:
		return
	if owner_char.has_signal(&"weapon_changed"):
		owner_char.weapon_changed.connect(_on_owner_weapon_changed)
		_owner_connected = true


func _on_owner_weapon_changed(_slot: int, new_id: String) -> void:
	if is_queued_for_deletion() or new_id == weapon_id:
		return
	setup(new_id, owner_char, aim_source)


# --------------------------------------------------------------------- ticking

func _physics_process(delta: float) -> void:
	if _cooldown > COOLDOWN_FLOOR:
		_cooldown = maxf(_cooldown - delta, COOLDOWN_FLOOR)
	if _dry_left > 0.0:
		_dry_left -= delta
	_update_ads(delta)
	_update_recoil(delta)

	match state:
		State.DRAWING:
			_draw_left -= delta
			if _draw_left <= 0.0:
				_draw_left = 0.0
				_set_state(State.READY)
		State.RELOADING:
			_tick_reload(delta)
			# Shell-by-shell guns can break off the reload to fire.
			if state == State.RELOADING and _shell_reload and _trigger_held and get_mag() > 0:
				_cancel_reload()
		_:
			if _burst_left > 0:
				_shoot_if_ready(true)
			elif _trigger_held and (_auto or _trigger_pulled):
				_shoot_if_ready(false)
			elif state == State.FIRING and _cooldown <= 0.0:
				_set_state(State.READY)


func _update_ads(delta: float) -> void:
	var goal := 1.0 if (owner_char != null and owner_char.is_ads) else 0.0
	if not is_equal_approx(_ads_blend, goal):
		_ads_blend = move_toward(_ads_blend, goal, delta / _ads_time)


func _update_recoil(delta: float) -> void:
	if _shot_idle < 10.0:
		_shot_idle += delta
		if _shot_idle >= RECOIL_RESET_DELAY:
			recoil_index = 0
	if _shot_idle >= RECOIL_RESET_DELAY and _recoil != Vector2.ZERO:
		_recoil = _recoil.move_toward(Vector2.ZERO, _recoil_recovery * delta)


func _set_state(s: int) -> void:
	if state == s:
		return
	state = s
	state_changed.emit(s)


# --------------------------------------------------------------------- trigger

## Player path: the held state is pushed on change. Semi-autos need a release.
func set_trigger(held: bool) -> void:
	if held == _trigger_held:
		return
	_trigger_held = held
	# Releasing does not cancel an in-flight burst: those shots are committed.
	_trigger_pulled = held


## Bot / single-pulse path: one attempt now, honouring rate and state. Returns
## true when a shot (or swing) actually left the weapon.
func try_fire() -> bool:
	return _shoot_if_ready(true)


func fire() -> bool:
	return _shoot_if_ready(true)


func trigger_down() -> void:
	set_trigger(true)


func trigger_up() -> void:
	set_trigger(false)


func _shoot_if_ready(pulse: bool) -> bool:
	if _mode == Mode.INERT or owner_char == null or not owner_char.alive:
		return false
	if state == State.DRAWING:
		return false
	if state == State.RELOADING:
		if _shell_reload and get_mag() > 0:
			_cancel_reload()
		else:
			return false
	if _cooldown > 0.0:
		return false
	if _mode == Mode.MELEE:
		_trigger_pulled = false
		return _melee_swing(false)
	if _mag_size > 0 and get_mag() <= 0:
		_trigger_pulled = false
		_dry_fire()
		return false
	if _burst_count > 0 and _burst_left <= 0 and (pulse or _trigger_pulled):
		_burst_left = _burst_count
	_trigger_pulled = false
	_shoot()
	return true


func _dry_fire() -> void:
	# A burst that runs the magazine dry ends there; it must not resume after the
	# reload without a fresh trigger pull.
	_burst_left = 0
	if _dry_left > 0.0:
		return
	_dry_left = DRY_FIRE_DELAY
	if not _empty_sfx.is_empty():
		AudioMgr.play_3d(_empty_sfx, _aim_origin(), -6.0)
	if auto_reload_on_empty:
		start_reload()


# ---------------------------------------------------------------------- firing

func _shoot() -> void:
	if _mag_size > 0:
		owner_char.consume_ammo(weapon_id, 1)
	_cache_aim()
	var kick := _kick_for_shot()
	recoil_index += 1
	_shot_idle = 0.0
	_last_kick = kick
	_recoil += kick

	var spread := deg_to_rad(current_spread_deg())
	var tracers: int = mini(_pellets, MAX_TRACERS_PER_SHOT)
	for i in _pellets:
		_fire_pellet(spread, i < tracers)

	if _burst_left > 0:
		_burst_left -= 1
		_cooldown += _burst_interval if _burst_left > 0 else maxf(_burst_delay, _fire_interval)
	else:
		_cooldown += _fire_interval
	_cooldown = maxf(_cooldown, COOLDOWN_FLOOR)
	_set_state(State.FIRING)
	_muzzle_effects()
	ammo_changed.emit(get_mag(), get_reserve())
	fired.emit(kick)


func _kick_for_shot() -> Vector2:
	var n: int = _pattern.size()
	if n == 0:
		return Vector2.ZERO
	return _pattern[clampi(recoil_index, 0, n - 1)]


## Aim frame for this shot: origin plus an orthonormal basis, with the
## accumulated recoil folded in when the aim source does not carry it.
func _cache_aim() -> void:
	var b := Basis.IDENTITY
	if aim_source != null:
		b = aim_source.global_transform.basis.orthonormalized()
		_origin = aim_source.global_position
	elif owner_char != null:
		b = owner_char.global_transform.basis.orthonormalized()
		_origin = owner_char.eye_position()
	else:
		b = global_transform.basis.orthonormalized()
		_origin = global_position
	_right = b.x
	_up = b.y
	_fwd = -b.z
	if apply_recoil_to_aim and _recoil != Vector2.ZERO:
		_fwd = _fwd.rotated(_right, deg_to_rad(_recoil.y)).rotated(_up, deg_to_rad(-_recoil.x))


func _fire_pellet(spread_rad: float, want_tracer: bool) -> void:
	_dir = _fwd
	if spread_rad > 0.0:
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * spread_rad
		_dir = _dir.rotated(_right, r * sin(a)).rotated(_up, r * cos(a))
	_trace(want_tracer)


## Hitscan with wall penetration. Everything it needs lives in members, so a
## shot allocates nothing beyond the Dictionary the physics server returns.
func _trace(want_tracer: bool) -> void:
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var from := _origin
	var dmg_mult := 1.0
	var travelled := 0.0
	var pens := 0
	_tracer_end = _origin + _dir * MAX_RANGE
	while true:
		var reach := MAX_RANGE - travelled
		if reach <= 0.0:
			break
		_query.from = from
		_query.to = from + _dir * reach
		var hit: Dictionary = space.intersect_ray(_query)
		if hit.is_empty():
			if pens == 0:
				_tracer_end = _query.to
			break
		var point: Vector3 = hit["position"]
		var normal: Vector3 = hit["normal"]
		var collider: Object = hit["collider"]
		if pens == 0:
			_tracer_end = point
		var dist := travelled + from.distance_to(point)
		if _is_hitbox(collider):
			_hit_character(collider, point, normal, dist, dmg_mult)
			break
		_spawn_impact(point, normal, false)
		if pens >= PEN_MAX or _pen_thickness <= 0.0:
			break
		if not _probe_exit(space, point):
			break
		_spawn_impact(_exit_point, -normal, false)
		from = _exit_point + _dir * PEN_STEP
		travelled = _origin.distance_to(from)
		dmg_mult *= PEN_DAMAGE_BASE * _penetration
		pens += 1
		if dmg_mult <= PEN_MIN_MULT:
			break
	if want_tracer:
		_spawn_tracer(_tracer_end)


static func _is_hitbox(collider: Object) -> bool:
	if collider == null or not (collider is Node):
		return false
	var n := collider as Node
	return n.has_meta(&"zone") and (n.has_meta(&"char") or n.has_meta(&"char_ref"))


## Looks for the back face of the surface just entered by casting backwards from
## beyond the maximum punchable thickness. No hit = the wall is too thick (or
## the ray started inside it), which blocks the bullet.
func _probe_exit(space: PhysicsDirectSpaceState3D, entry: Vector3) -> bool:
	_query.collision_mask = LAYER_WORLD
	_query.hit_back_faces = false
	_query.from = entry + _dir * (_pen_thickness + PEN_STEP)
	_query.to = entry + _dir * PEN_STEP
	var hit: Dictionary = space.intersect_ray(_query)
	_query.collision_mask = RAY_MASK
	_query.hit_back_faces = true
	if hit.is_empty():
		return false
	_exit_point = hit["position"]
	return true


func _hit_character(collider: Object, point: Vector3, normal: Vector3,
		dist: float, dmg_mult: float) -> void:
	_spawn_impact(point, normal, true)
	var ch := CharacterBase.from_hitbox(collider)
	if ch == null or ch == owner_char or not ch.alive:
		return
	var zone := int((collider as Node).get_meta(&"zone", CharacterBase.Zone.CHEST))
	var dmg := _damage * dmg_mult * _falloff(dist)
	if dmg <= 0.0:
		return
	ch.take_damage(dmg, zone, owner_char.player_id, weapon_id, _dir, _headshot_mult)
	hit_confirmed.emit(zone, not ch.alive)


func _falloff(dist: float) -> float:
	if dist <= _fall_start:
		return 1.0
	if dist >= _fall_end or _fall_end <= _fall_start:
		return _fall_min
	return lerpf(1.0, _fall_min, (dist - _fall_start) / (_fall_end - _fall_start))


# ----------------------------------------------------------------------- melee

## Short sphere sweep in front of the eye. `heavy` uses damage_heavy/rate_heavy
## from the def (alt swing; no input is bound to it in Phase 1).
func _melee_swing(heavy: bool) -> bool:
	if _melee_cast == null:
		_build_melee_cast()
	_cache_aim()
	_dir = _fwd
	_cooldown += _melee_heavy_interval if heavy else _fire_interval
	_cooldown = maxf(_cooldown, COOLDOWN_FLOOR)
	_shot_idle = 0.0
	_last_kick = Vector2.ZERO
	_set_state(State.FIRING)
	if not _fire_sfx.is_empty():
		AudioMgr.play_3d(_fire_sfx, _origin)
	fired.emit(Vector2.ZERO)

	_melee_cast.global_transform = Transform3D(Basis.IDENTITY, _origin)
	_melee_cast.target_position = _dir * _melee_range
	_melee_cast.force_shapecast_update()
	var count := _melee_cast.get_collision_count()
	if count <= 0:
		return true

	var best: CharacterBase = null
	var best_zone := int(CharacterBase.Zone.CHEST)
	var best_dist := INF
	var world_point := Vector3.ZERO
	var world_normal := Vector3.UP
	var have_world := false
	for i in count:
		var col := _melee_cast.get_collider(i)
		var p := _melee_cast.get_collision_point(i)
		var d := _origin.distance_to(p)
		if _is_hitbox(col):
			var ch := CharacterBase.from_hitbox(col)
			if ch == null or ch == owner_char or not ch.alive:
				continue
			if d < best_dist:
				best_dist = d
				best = ch
				best_zone = int((col as Node).get_meta(&"zone", CharacterBase.Zone.CHEST))
		elif not have_world:
			have_world = true
			world_point = p
			world_normal = _melee_cast.get_collision_normal(i)

	if best != null:
		var dmg := _melee_heavy_damage if heavy else _damage
		# Behind the target: their forward points the same way the blade travels.
		if _back_mult > 1.0 and _dir.dot(-best.global_transform.basis.z) > MELEE_BACK_DOT:
			dmg *= _back_mult
		best.take_damage(dmg, best_zone, owner_char.player_id, weapon_id, _dir, _headshot_mult)
		hit_confirmed.emit(best_zone, not best.alive)
	elif have_world:
		_spawn_impact(world_point, world_normal, false)
	return true


## Alt (heavy) knife swing, for whoever binds a second melee button.
func melee_heavy() -> bool:
	if _mode != Mode.MELEE or owner_char == null or not owner_char.alive:
		return false
	if state == State.DRAWING or state == State.RELOADING or _cooldown > 0.0:
		return false
	return _melee_swing(true)


# ---------------------------------------------------------------------- reload

func reload() -> bool:
	return start_reload()


func start_reload() -> bool:
	if _mode != Mode.BULLET or _mag_size <= 0 or owner_char == null:
		return false
	if state == State.DRAWING or state == State.RELOADING:
		return false
	if get_mag() >= _mag_size or get_reserve() <= 0:
		return false
	_burst_left = 0
	_trigger_pulled = false
	if _shell_reload:
		_shell_left = _shell_time
		_reload_left = _shell_time * float(_shells_pending())
	else:
		_reload_left = _reload_time
	_set_state(State.RELOADING)
	if not _reload_sfx.is_empty():
		AudioMgr.play_3d(_reload_sfx, _aim_origin())
	reload_started.emit(_reload_left)
	return true


func cancel_reload() -> void:
	if state == State.RELOADING:
		_cancel_reload()


func _cancel_reload() -> void:
	_reload_left = 0.0
	_shell_left = 0.0
	_set_state(State.READY)
	reload_finished.emit()


func _shells_pending() -> int:
	return mini(_mag_size - get_mag(), get_reserve())


func _tick_reload(delta: float) -> void:
	_reload_left = maxf(_reload_left - delta, 0.0)
	if _shell_reload:
		_shell_left -= delta
		if _shell_left <= 0.0:
			_shell_left += _shell_time
			owner_char.set_ammo(weapon_id, get_mag() + 1, get_reserve() - 1)
			ammo_changed.emit(get_mag(), get_reserve())
			if not _reload_sfx.is_empty():
				AudioMgr.play_3d(_reload_sfx, _aim_origin(), -3.0)
			if _shells_pending() <= 0:
				_finish_reload()
				return
		_reload_left = maxf(_reload_left, _shell_time * float(_shells_pending() - 1))
		return
	if _reload_left <= 0.0:
		owner_char.pull_from_reserve(weapon_id)
		_finish_reload()


func _finish_reload() -> void:
	_reload_left = 0.0
	_shell_left = 0.0
	_set_state(State.READY)
	ammo_changed.emit(get_mag(), get_reserve())
	reload_finished.emit()


# ------------------------------------------------------------------- accessors

## Accumulated recoil in degrees (x = yaw drift, + right; y = pitch up). The
## player uses the WeaponDB pattern directly and only falls back to this; bots
## compensate their aim against it, which needs the running total.
func camera_kick() -> Vector2:
	return _recoil


## Kick of the shot that was just fired, i.e. the payload of `fired`.
func last_shot_kick() -> Vector2:
	return _last_kick


## Cone half-angle in degrees: base + movement/air + recoil bloom, ADS scaled.
func current_spread_deg() -> float:
	var s := _spread_base
	if owner_char != null:
		if not owner_char.is_on_floor():
			s += _spread_air
		elif _spread_move > 0.0:
			var top := maxf(owner_char.current_speed(), 0.01)
			s += _spread_move * clampf(owner_char.planar_speed() / top, 0.0, 1.0)
	s += _recoil.length() * RECOIL_SPREAD_MULT
	if _ads_blend > 0.0:
		s = lerpf(s, s * _ads_spread_mult, _ads_blend)
	return s


func get_state() -> int:
	return state


func is_reloading() -> bool:
	return state == State.RELOADING


func is_drawing() -> bool:
	return state == State.DRAWING


func is_ready() -> bool:
	return state == State.READY or state == State.FIRING


func can_fire() -> bool:
	if _mode == Mode.INERT or owner_char == null or not owner_char.alive:
		return false
	if state == State.DRAWING or state == State.RELOADING or _cooldown > 0.0:
		return false
	return _mode == Mode.MELEE or _mag_size <= 0 or get_mag() > 0


func get_mag() -> int:
	return owner_char.get_mag(weapon_id) if owner_char != null else 0


func get_reserve() -> int:
	return owner_char.get_reserve(weapon_id) if owner_char != null else 0


func get_mag_size() -> int:
	return _mag_size


func is_melee() -> bool:
	return _mode == Mode.MELEE


func get_muzzle_position() -> Vector3:
	if _muzzle != null:
		return _muzzle.global_position
	return _aim_origin() + _aim_forward() * 0.35


func _aim_origin() -> Vector3:
	if aim_source != null:
		return aim_source.global_position
	if owner_char != null:
		return owner_char.eye_position()
	return global_position


func _aim_forward() -> Vector3:
	if aim_source != null:
		return -aim_source.global_transform.basis.z.normalized()
	if owner_char != null:
		return -owner_char.global_transform.basis.z.normalized()
	return -global_transform.basis.z.normalized()


# ------------------------------------------------------------------ pooled fx

func _fx_parent() -> Node:
	var t := get_tree()
	if t == null:
		return null
	if t.current_scene != null:
		return t.current_scene
	return t.root


func _ensure_fx_pools() -> void:
	if _fx_pools_ready or _fx_pools_failed:
		return
	var tracer: PackedScene = null
	var impact: PackedScene = null
	if ResourceLoader.exists(TRACER_SCENE_PATH):
		tracer = load(TRACER_SCENE_PATH) as PackedScene
	if ResourceLoader.exists(IMPACT_SCENE_PATH):
		impact = load(IMPACT_SCENE_PATH) as PackedScene
	if tracer == null or impact == null:
		_fx_pools_failed = true
		return
	Pools.create_pool(TRACER_POOL, tracer, TRACER_POOL_SIZE)
	Pools.create_pool(IMPACT_POOL, impact, IMPACT_POOL_SIZE)
	_fx_pools_ready = true


func _acquire_fx(key: String) -> Node:
	var parent := _fx_parent()
	if parent == null:
		return null
	var n := Pools.acquire(key, parent)
	if n != null:
		return n
	if _fx_pools_failed:
		return null
	# Missing pool: either first use, or Pools.clear_all() ran between matches.
	_fx_pools_ready = false
	_ensure_fx_pools()
	if _fx_pools_failed:
		return null
	return Pools.acquire(key, parent)


func _spawn_impact(point: Vector3, normal: Vector3, flesh: bool) -> void:
	var n := _acquire_fx(IMPACT_POOL)
	if n == null:
		return
	if n.has_method(&"begin"):
		n.call(&"begin", point, normal, flesh)
	elif n is Node3D:
		(n as Node3D).global_position = point


func _spawn_tracer(to: Vector3) -> void:
	var from := get_muzzle_position()
	if from.distance_to(to) < TRACER_MIN_DIST:
		return
	var n := _acquire_fx(TRACER_POOL)
	if n == null:
		return
	if n.has_method(&"begin"):
		n.call(&"begin", from, to)


## Muzzle flash, shell eject and the fire sound. Pooled effects are parented to
## the scene, never to this weapon: the holder frees the weapon on every switch
## and a pooled node must outlive it.
func _muzzle_effects() -> void:
	var pos := get_muzzle_position()
	if not _fire_sfx.is_empty():
		AudioMgr.play_3d(_fire_sfx, pos)
	var parent := _fx_parent()
	if parent == null:
		return
	if _muzzle != null:
		var flash := Pools.acquire(MUZZLE_POOL, parent)
		if flash is Node3D:
			(flash as Node3D).global_transform = _muzzle.global_transform
	if _shell_port != null:
		var shell := Pools.acquire(SHELL_POOL, parent)
		if shell is Node3D:
			(shell as Node3D).global_transform = _shell_port.global_transform
