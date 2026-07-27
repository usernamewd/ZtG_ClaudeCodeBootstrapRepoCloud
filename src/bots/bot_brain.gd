class_name BotBrain
extends CharacterBase
## An AI player. Perception, planning, movement and combat for one bot.
##
## Design and the fairness contract live in docs/BOT_AI.md — read it before
## changing behaviour. The short version: a bot may only act on information a
## human could have (FOV cone, line of sight, smoke blocks vision, reaction time
## before the first shot, and a decaying memory of a lost target).
##
## Cost control: perception runs at 10 Hz on a per-bot stagger, planning at 2 Hz.
## Only movement and aiming run every physics tick, and nothing in the hot path
## allocates.

const PERCEPTION_HZ := 10.0
const PLAN_HZ := 2.0

const FOV_MOVING_DEG := 100.0
const FOV_HOLDING_DEG := 70.0
const MAX_SIGHT := 60.0
const HEAR_RUN_RADIUS := 22.0
const HEAR_SHOT_RADIUS := 55.0

## Per-difficulty tuning. Index by GameState.cfg_bot_difficulty (0 easy .. 2 hard).
const DIFF := [
	{
		"reaction": 0.45, "aim_error": 6.0, "settle_rate": 1.1, "turn_rate": 240.0,
		"spray_control": 0.0, "head_pref": 0.05, "memory": 2.0, "utility": 0.15,
		"peek_discipline": 0.2, "burst_scale": 1.35, "accuracy_move_penalty": 1.0,
	},
	{
		"reaction": 0.28, "aim_error": 3.0, "settle_rate": 2.0, "turn_rate": 420.0,
		"spray_control": 0.5, "head_pref": 0.35, "memory": 4.0, "utility": 0.5,
		"peek_discipline": 0.6, "burst_scale": 1.0, "accuracy_move_penalty": 0.7,
	},
	{
		"reaction": 0.16, "aim_error": 1.4, "settle_rate": 3.4, "turn_rate": 640.0,
		"spray_control": 0.85, "head_pref": 0.75, "memory": 6.0, "utility": 0.85,
		"peek_discipline": 0.9, "burst_scale": 0.8, "accuracy_move_penalty": 0.45,
	},
]

enum Role { ENTRY, SUPPORT, LURK, CARRIER, ANCHOR, SITE_ANCHOR, FLEX, ANGLE, ROTATOR }
enum Goal { IDLE, BUY, MOVE_TO, HOLD, ENGAGE, INVESTIGATE, PLANT, DEFUSE, POST_PLANT, RETAKE }

@export var difficulty: int = 1

var role: int = Role.FLEX
var goal: int = Goal.IDLE
var blackboard: BotBlackboard = null
var map_info: Node = null            ## MapInfo, set by the match controller
var weapon: Node3D = null            ## Weapon runtime instance

# Perception state
var target: CharacterBase = null
var target_visible: bool = false
var target_last_seen_pos: Vector3 = Vector3.ZERO
var target_last_seen_time: float = -999.0
var time_target_acquired: float = -999.0
var settle: float = 0.0              ## 0..1 aim convergence on the current target
var investigate_pos: Vector3 = Vector3.ZERO
var has_investigate: bool = false

# Aim state
var aim_dir: Vector3 = Vector3.FORWARD
var _desired_dir: Vector3 = Vector3.FORWARD
var _wander_phase: float = 0.0
var _recoil_comp: Vector2 = Vector2.ZERO

# Movement state
var _agent: NavigationAgent3D = null
var _strafe_sign: float = 0.0
var _strafe_until: float = 0.0
var _want_run: bool = true
var _move_goal: Vector3 = Vector3.ZERO
var _has_move_goal: bool = false
var _stuck_time: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO

# Objective state
var _action_timer: float = 0.0       ## plant / defuse progress
var _action_kind: int = 0            ## 0 none, 1 plant, 2 defuse
var carrying_bomb: bool = false

# Scheduling
var _perception_accum: float = 0.0
var _plan_accum: float = 0.0
var _time: float = 0.0
var _fire_hold: float = 0.0          ## remaining burst time
var _fire_pause: float = 0.0         ## remaining pause between bursts
var _rng := RandomNumberGenerator.new()

# Preallocated so perception never allocates in the hot path.
var _ray_params: PhysicsRayQueryParameters3D = null
var _enemies: Array[CharacterBase] = []
var _tune: Dictionary = {}


func _ready() -> void:
	super._ready()
	add_to_group("bot")
	_rng.randomize()
	difficulty = clampi(difficulty, 0, DIFF.size() - 1)
	_tune = DIFF[difficulty]

	_ray_params = PhysicsRayQueryParameters3D.new()
	_ray_params.collide_with_areas = false
	_ray_params.collide_with_bodies = true
	_ray_params.collision_mask = LAYER_WORLD | LAYER_CLIP | LAYER_HITBOX

	_agent = get_node_or_null("NavAgent")
	if _agent == null:
		_agent = NavigationAgent3D.new()
		_agent.name = "NavAgent"
		add_child(_agent)
	_agent.path_desired_distance = 0.8
	_agent.target_desired_distance = 1.0
	_agent.radius = BODY_RADIUS
	_agent.avoidance_enabled = true
	_agent.neighbor_distance = 6.0
	_agent.max_neighbors = 6
	_agent.max_speed = SPEED_RUN

	# Stagger thinking so N bots never all run perception on the same frame.
	_perception_accum = _rng.randf() / PERCEPTION_HZ
	_plan_accum = _rng.randf() / PLAN_HZ
	_wander_phase = _rng.randf() * TAU
	_last_pos = global_position
	aim_dir = -global_transform.basis.z

	died.connect(_on_bot_died)


func setup(p_team: int, p_id: int, p_difficulty: int, p_blackboard: BotBlackboard,
		p_map: Node) -> void:
	team = p_team
	player_id = p_id
	difficulty = clampi(p_difficulty, 0, DIFF.size() - 1)
	_tune = DIFF[difficulty]
	blackboard = p_blackboard
	map_info = p_map


func _physics_process(delta: float) -> void:
	if not alive:
		return
	_time += delta

	_perception_accum -= delta
	if _perception_accum <= 0.0:
		_perception_accum += 1.0 / PERCEPTION_HZ
		_update_perception()

	_plan_accum -= delta
	if _plan_accum <= 0.0:
		_plan_accum += 1.0 / PLAN_HZ
		_replan()

	_update_aim(delta)
	_update_combat(delta)
	_update_movement(delta)
	_update_action(delta)


# ---------------------------------------------------------------------------
# Perception
# ---------------------------------------------------------------------------

func _update_perception() -> void:
	var best: CharacterBase = null
	var best_score := -1.0
	var eye_pos := eye_position()

	_gather_enemies()
	for e in _enemies:
		if e == null or not e.alive:
			continue
		if not _can_see(e, eye_pos):
			continue
		# Prefer close, centred, low-health targets.
		var to_e := e.global_position - global_position
		var dist := to_e.length()
		var centred := aim_dir.dot(to_e / maxf(dist, 0.001))
		var score := (1.0 - dist / MAX_SIGHT) * 1.4 + centred * 0.8
		score += (1.0 - e.health / maxf(e.max_health, 1.0)) * 0.5
		if e == target:
			score += 0.35    # hysteresis: don't flip-flop between equal targets
		if score > best_score:
			best_score = score
			best = e

	if best != null:
		if best != target:
			target = best
			time_target_acquired = _time
			settle = 0.0
		target_visible = true
		target_last_seen_pos = best.global_position
		target_last_seen_time = _time
		if blackboard:
			blackboard.report_contact(best.player_id, best.global_position, player_id, true)
			_note_enemy_site(best.global_position)
	else:
		target_visible = false
		# Memory decay: keep chasing the last known position for a while, then
		# give up entirely rather than tracking through walls forever.
		if target != null and _time - target_last_seen_time > float(_tune.memory):
			target = null
			settle = 0.0


func _gather_enemies() -> void:
	_enemies.clear()
	for n in get_tree().get_nodes_in_group("combatant"):
		var c := n as CharacterBase
		if c != null and c != self and c.team != team and c.alive:
			_enemies.append(c)


func _can_see(e: CharacterBase, eye_pos: Vector3) -> bool:
	var to_e := e.global_position - global_position
	var dist := to_e.length()
	if dist > MAX_SIGHT:
		return false
	var fov := FOV_HOLDING_DEG if goal == Goal.HOLD else FOV_MOVING_DEG
	if rad_to_deg(aim_dir.angle_to(to_e / maxf(dist, 0.001))) > fov * 0.5:
		return false
	# Test the actual hitboxes so a bot can see a head over cover without
	# "seeing" a fully-covered body.
	for hb in e.hitboxes:
		if not is_instance_valid(hb):
			continue
		if _clear_line(eye_pos, hb.global_position, e):
			return true
	return _clear_line(eye_pos, e.global_position + Vector3.UP * 1.2, e)


func _clear_line(from: Vector3, to: Vector3, ignore_char: CharacterBase) -> bool:
	if _smoke_blocks(from, to):
		return false
	_ray_params.from = from
	_ray_params.to = to
	_ray_params.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(_ray_params)
	if hit.is_empty():
		return true
	var col = hit.get("collider")
	if col == null:
		return true
	# Hitting the target's own hitbox counts as seeing it. CharacterBase stamps
	# both "char" (a NodePath) and "char_ref" (the object); use the reference so
	# this is a plain identity test.
	if col.has_meta("char_ref"):
		if col.get_meta("char_ref") == ignore_char:
			return true
	elif col.has_meta("char"):
		var p = col.get_meta("char")
		if p is NodePath and get_node_or_null(p) == ignore_char:
			return true
	return false


func _smoke_blocks(from: Vector3, to: Vector3) -> bool:
	for n in get_tree().get_nodes_in_group("smoke_volume"):
		if not (n is Node3D):
			continue
		var radius: float = n.get_meta("radius", 4.0)
		if _segment_hits_sphere(from, to, (n as Node3D).global_position, radius):
			return true
	return false


func _segment_hits_sphere(a: Vector3, b: Vector3, c: Vector3, r: float) -> bool:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return a.distance_squared_to(c) < r * r
	var t := clampf((c - a).dot(ab) / len_sq, 0.0, 1.0)
	return (a + ab * t).distance_squared_to(c) < r * r


func _note_enemy_site(pos: Vector3) -> void:
	if map_info == null or not map_info.has_method("site_containing"):
		return
	var site: String = map_info.site_containing(pos)
	if site != "" and blackboard:
		blackboard.note_enemy_at_site(site)


## Called by the match/weapon layer when a noise is made near this bot.
func hear_noise(pos: Vector3, loudness: float) -> void:
	if not alive:
		return
	var d := global_position.distance_to(pos)
	var radius: float = HEAR_SHOT_RADIUS if loudness > 0.5 else HEAR_RUN_RADIUS
	if d > radius:
		return
	if target_visible:
		return   # eyes beat ears
	# Error grows with distance: bots turn toward a noise, they don't pinpoint it.
	var err := (d / radius) * 6.0
	investigate_pos = pos + Vector3(
		_rng.randf_range(-err, err), 0.0, _rng.randf_range(-err, err))
	has_investigate = true
	if blackboard:
		blackboard.report_contact(-1, investigate_pos, player_id, false)


# ---------------------------------------------------------------------------
# Planning
# ---------------------------------------------------------------------------

func _replan() -> void:
	if not alive:
		return
	if target != null and (target_visible or _time - target_last_seen_time < 1.5):
		goal = Goal.ENGAGE
		return

	match GameState.phase:
		GameState.Phase.FREEZE_BUY:
			goal = Goal.BUY
			_want_run = false
			return
		GameState.Phase.PLANTED:
			_plan_planted()
			return
		_:
			_plan_live()


func _plan_live() -> void:
	if team == GameState.Team.ATK:
		if carrying_bomb and _in_target_site():
			goal = Goal.PLANT
			return
		match role:
			Role.LURK:
				goal = Goal.MOVE_TO
				_set_goal_marker("rotate", _other_site())
			Role.ANCHOR:
				goal = Goal.HOLD
				_set_goal_marker("hold", "")
			_:
				goal = Goal.MOVE_TO
				_set_goal_site(_called_site())
	else:
		if has_investigate:
			goal = Goal.INVESTIGATE
			_move_to(investigate_pos)
			return
		match role:
			Role.SITE_ANCHOR, Role.ANGLE:
				goal = Goal.HOLD
				_set_goal_marker("hold", "")
			Role.ROTATOR, Role.FLEX:
				if blackboard and blackboard.contact_count() > 0:
					var c := blackboard.newest_contact()
					if c != null:
						goal = Goal.MOVE_TO
						_move_to(c.pos)
						return
				goal = Goal.HOLD
				_set_goal_marker("hold", "")
			_:
				goal = Goal.HOLD
				_set_goal_marker("hold", "")


func _plan_planted() -> void:
	if team == GameState.Team.ATK:
		goal = Goal.POST_PLANT
		_set_goal_marker("plant", GameState.bomb_planted_site)
	else:
		# Only start a defuse we can actually finish.
		var need: float = GameState.cfg_defuse_kit_time if has_defuse_kit else GameState.cfg_defuse_time
		if _at_bomb() and (GameState.phase_time_left > need or _is_last_alive()):
			goal = Goal.DEFUSE
		else:
			goal = Goal.RETAKE
			_set_goal_marker("retake", GameState.bomb_planted_site)


func _called_site() -> String:
	if blackboard == null:
		return "A"
	return blackboard.choose_site(_rng)


func _other_site() -> String:
	return "B" if _called_site() == "A" else "A"


func _set_goal_site(site: String) -> void:
	if map_info == null:
		return
	var sites: Dictionary = map_info.get("bomb_sites") if map_info.get("bomb_sites") != null else {}
	var area = sites.get(site)
	if area is Node3D:
		_move_to((area as Node3D).global_position)


func _set_goal_marker(tag: String, site: String) -> void:
	if map_info == null or not map_info.has_method("pick_bot_point"):
		return
	var p = map_info.pick_bot_point(tag, team, site, player_id)
	if p is Vector3:
		_move_to(p)


func _move_to(pos: Vector3) -> void:
	_move_goal = pos
	_has_move_goal = true
	if _agent:
		_agent.target_position = pos


func _in_target_site() -> bool:
	if map_info == null or not map_info.has_method("site_containing"):
		return false
	return map_info.site_containing(global_position) != ""


func _at_bomb() -> bool:
	var bomb := get_tree().get_first_node_in_group("planted_bomb")
	if bomb == null or not (bomb is Node3D):
		return false
	return global_position.distance_to((bomb as Node3D).global_position) < 1.8


func _is_last_alive() -> bool:
	return GameState.alive_count(team) <= 1


# ---------------------------------------------------------------------------
# Aiming
# ---------------------------------------------------------------------------

func _update_aim(delta: float) -> void:
	_wander_phase += delta * 1.7

	if target != null and (target_visible or _time - target_last_seen_time < float(_tune.memory)):
		var aim_point := _target_aim_point()
		if target_visible:
			settle = minf(1.0, settle + delta * float(_tune.settle_rate))
		else:
			settle = maxf(0.0, settle - delta * 0.8)
		var err_deg: float = float(_tune.aim_error) * (1.0 - settle * 0.85)
		# Smooth low-frequency drift so the crosshair breathes instead of
		# sitting on a perfect point.
		var wob := Vector3(
			sin(_wander_phase * 1.3) * 0.6 + sin(_wander_phase * 0.41) * 0.4,
			cos(_wander_phase * 1.1) * 0.5 + cos(_wander_phase * 0.37) * 0.3,
			0.0) * deg_to_rad(err_deg)
		var to_target := (aim_point - eye_position()).normalized()
		_desired_dir = to_target.rotated(Vector3.UP, wob.x)
		var right := _desired_dir.cross(Vector3.UP).normalized()
		if right.length_squared() > 0.0001:
			_desired_dir = _desired_dir.rotated(right, wob.y)
	elif has_investigate:
		var d := investigate_pos - eye_position()
		if d.length_squared() > 0.01:
			_desired_dir = d.normalized()
	elif _has_move_goal:
		var d2 := _move_goal - global_position
		d2.y = 0.0
		if d2.length_squared() > 0.01:
			_desired_dir = d2.normalized()

	var max_turn := deg_to_rad(float(_tune.turn_rate)) * delta
	var angle := aim_dir.angle_to(_desired_dir)
	if angle > 0.0001:
		aim_dir = aim_dir.slerp(_desired_dir, minf(1.0, max_turn / angle)).normalized()

	# Body yaw follows aim; the eye carries the pitch.
	var flat := Vector3(aim_dir.x, 0.0, aim_dir.z)
	if flat.length_squared() > 0.0001:
		flat = flat.normalized()
		rotation.y = atan2(-flat.x, -flat.z)
	if eye:
		eye.rotation.x = clampf(asin(clampf(aim_dir.y, -1.0, 1.0)), -1.5, 1.5)


func _target_aim_point() -> Vector3:
	if target == null:
		return global_position + aim_dir * 10.0
	var base := target.global_position
	# Head preference rises with difficulty and falls off at long range.
	var dist := global_position.distance_to(base)
	var head_chance: float = float(_tune.head_pref) * clampf(1.4 - dist / 30.0, 0.15, 1.0)
	var want_head := _rng.randf() < head_chance
	var h: float = target.EYE_CROUCH if target.is_crouching else target.EYE_STAND
	return base + Vector3.UP * (h if want_head else h * 0.72)


# ---------------------------------------------------------------------------
# Combat
# ---------------------------------------------------------------------------

func _update_combat(delta: float) -> void:
	if weapon == null or target == null or not target_visible:
		_fire_hold = 0.0
		return
	# Reaction time: a bot cannot shoot the instant a target appears.
	if _time - time_target_acquired < float(_tune.reaction):
		return
	if not _aim_is_on_target():
		return
	if _should_reload():
		if weapon.has_method("start_reload"):
			weapon.start_reload()
		return

	if _fire_pause > 0.0:
		_fire_pause -= delta
		return

	var def := current_weapon_def()
	if def.is_empty():
		return

	if _fire_hold <= 0.0:
		_fire_hold = _burst_duration(def)
	_fire_hold -= delta

	if weapon.has_method("try_fire"):
		weapon.try_fire()
	_apply_spray_control(def)

	if _fire_hold <= 0.0:
		# Pause long enough for the recoil pattern to recover — the same reason
		# a good player stops spraying.
		_fire_pause = _rng.randf_range(0.22, 0.45) * float(_tune.burst_scale)


func _aim_is_on_target() -> bool:
	if target == null:
		return false
	var to_t := (_target_aim_point() - eye_position())
	var dist := to_t.length()
	if dist < 0.01:
		return true
	var off_deg := rad_to_deg(aim_dir.angle_to(to_t / dist))
	# Tolerance scales with how big the target is at this range plus how
	# inaccurate we currently are: don't fire wildly off-angle.
	var subtend := rad_to_deg(atan2(0.5, maxf(dist, 1.0)))
	var allow := subtend + float(_tune.aim_error) * (1.0 - settle) * 0.5
	if planar_speed() > SPEED_CROUCH:
		allow *= float(_tune.accuracy_move_penalty)
	return off_deg <= allow


func _burst_duration(def: Dictionary) -> float:
	if not bool(def.get("auto", false)):
		return 0.05
	var dist := global_position.distance_to(target.global_position) if target else 20.0
	var rounds := 2.0
	if dist < 10.0:
		rounds = 8.0
	elif dist < 20.0:
		rounds = 5.0
	elif dist < 32.0:
		rounds = 3.0
	var rate: float = maxf(float(def.get("fire_rate", 8.0)), 0.1)
	return (rounds / rate) * float(_tune.burst_scale)


func _apply_spray_control(def: Dictionary) -> void:
	# Pull against the weapon's own recoil pattern by spray_control. Easy bots
	# compensate not at all, so their shots climb exactly like a bad player's.
	var control: float = float(_tune.spray_control)
	if control <= 0.0 or weapon == null:
		return
	if not weapon.has_method("camera_kick"):
		return
	var kick: Vector2 = weapon.camera_kick()
	_recoil_comp = _recoil_comp.lerp(-kick * control, 0.5)
	var right := aim_dir.cross(Vector3.UP).normalized()
	if right.length_squared() > 0.0001:
		aim_dir = aim_dir.rotated(right, deg_to_rad(_recoil_comp.y)) \
			.rotated(Vector3.UP, deg_to_rad(_recoil_comp.x)).normalized()


func _should_reload() -> bool:
	var id := current_weapon_id()
	if id == "" or id == KNIFE_ID:
		return false
	var def := current_weapon_def()
	if def.is_empty() or not bool(def.get("is_gun", true)):
		pass
	var mag := get_mag(id)
	var cap := int(def.get("mag", 1))
	if get_reserve(id) <= 0:
		return false
	if mag <= 0:
		return true
	# Top up between fights, not mid-duel.
	return not target_visible and float(mag) / maxf(float(cap), 1.0) < 0.35


# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------

func _update_movement(delta: float) -> void:
	var wish := Vector3.ZERO
	var want_crouch := false
	_want_run = true

	match goal:
		Goal.ENGAGE:
			wish = _combat_movement(delta)
			_want_run = false
		Goal.HOLD:
			if _has_move_goal and global_position.distance_to(_move_goal) > 1.5:
				wish = _path_direction()
				# Approach a held angle quietly.
				_want_run = global_position.distance_to(_move_goal) > 12.0
			else:
				want_crouch = float(_tune.peek_discipline) > 0.5 and target == null
		Goal.PLANT, Goal.DEFUSE:
			wish = Vector3.ZERO
			want_crouch = true
		Goal.BUY:
			wish = Vector3.ZERO
		_:
			if _has_move_goal:
				wish = _path_direction()

	_check_stuck(delta)
	move_locomotion_world(delta, wish, false, want_crouch)


func _path_direction() -> Vector3:
	if _agent == null or _agent.is_navigation_finished():
		_has_move_goal = false
		return Vector3.ZERO
	var next := _agent.get_next_path_position()
	var d := next - global_position
	d.y = 0.0
	if d.length_squared() < 0.0001:
		return Vector3.ZERO
	return d.normalized()


func _combat_movement(delta: float) -> Vector3:
	# Stop to take an accurate shot; strafe otherwise, flipping direction on a
	# timer so the motion isn't a predictable metronome.
	if target_visible and _aim_is_on_target() and _fire_pause <= 0.0:
		return Vector3.ZERO
	_strafe_until -= delta
	if _strafe_until <= 0.0:
		_strafe_until = _rng.randf_range(0.3, 0.8)
		_strafe_sign = 1.0 if _rng.randf() < 0.5 else -1.0
	if target == null:
		return Vector3.ZERO
	var to_t := target.global_position - global_position
	to_t.y = 0.0
	if to_t.length_squared() < 0.0001:
		return Vector3.ZERO
	to_t = to_t.normalized()
	var right := to_t.cross(Vector3.UP).normalized()
	var dist := global_position.distance_to(target.global_position)
	# Close the gap with a shotgun, keep distance with a rifle.
	var approach := 0.0
	var def := current_weapon_def()
	var ideal: float = float(def.get("range_falloff_start", 20.0)) * 0.6
	if dist > ideal * 1.5:
		approach = 0.6
	elif dist < ideal * 0.4:
		approach = -0.5
	return (right * _strafe_sign + to_t * approach).normalized()


func _check_stuck(delta: float) -> void:
	if not _has_move_goal:
		_stuck_time = 0.0
		return
	if global_position.distance_squared_to(_last_pos) < 0.0004:
		_stuck_time += delta
		if _stuck_time > 1.2:
			# Nudge sideways and re-path rather than grinding into geometry.
			_stuck_time = 0.0
			if _agent:
				_agent.target_position = _move_goal + Vector3(
					_rng.randf_range(-2.0, 2.0), 0.0, _rng.randf_range(-2.0, 2.0))
	else:
		_stuck_time = 0.0
	_last_pos = global_position


# ---------------------------------------------------------------------------
# Objective actions
# ---------------------------------------------------------------------------

func _update_action(delta: float) -> void:
	if goal == Goal.PLANT and carrying_bomb:
		if _action_kind != 1:
			_action_kind = 1
			_action_timer = 0.0
		_action_timer += delta
		if _action_timer >= GameState.cfg_plant_time:
			_finish_plant()
	elif goal == Goal.DEFUSE:
		if _action_kind != 2:
			_action_kind = 2
			_action_timer = 0.0
		_action_timer += delta
		var need: float = GameState.cfg_defuse_kit_time if has_defuse_kit else GameState.cfg_defuse_time
		if _action_timer >= need:
			_finish_defuse()
	else:
		_action_kind = 0
		_action_timer = 0.0


func action_progress() -> float:
	if _action_kind == 1:
		return clampf(_action_timer / maxf(GameState.cfg_plant_time, 0.01), 0.0, 1.0)
	if _action_kind == 2:
		var need: float = GameState.cfg_defuse_kit_time if has_defuse_kit else GameState.cfg_defuse_time
		return clampf(_action_timer / maxf(need, 0.01), 0.0, 1.0)
	return 0.0


func _finish_plant() -> void:
	_action_kind = 0
	_action_timer = 0.0
	carrying_bomb = false
	var site := ""
	if map_info and map_info.has_method("site_containing"):
		site = map_info.site_containing(global_position)
	var match_node := get_tree().get_first_node_in_group("match_controller")
	if match_node and match_node.has_method("plant_bomb"):
		match_node.plant_bomb(self, site if site != "" else "A", global_position)


func _finish_defuse() -> void:
	_action_kind = 0
	_action_timer = 0.0
	var match_node := get_tree().get_first_node_in_group("match_controller")
	if match_node and match_node.has_method("defuse_bomb"):
		match_node.defuse_bomb(self)


# ---------------------------------------------------------------------------
# Economy
# ---------------------------------------------------------------------------

## Buy for this round. Called by the match controller during FREEZE_BUY.
func run_buy_logic() -> void:
	var money := Economy.get_money(player_id)
	var saving: bool = blackboard != null and blackboard.eco_round
	var forcing: bool = blackboard != null and blackboard.force_round

	if saving and money < 4000:
		# Save, but a defusing team still wants a kit if it's nearly free.
		if team == GameState.Team.DEF and money >= 3000:
			_try_buy("defusekit")
		return

	if not forcing and money >= 3900:
		_buy_armor()
		_buy_primary_for_role(true)
		if team == GameState.Team.DEF:
			_try_buy("defusekit")
		_buy_utility()
	elif money >= 2200:
		_buy_armor()
		_buy_primary_for_role(false)
		_buy_utility()
	else:
		if money >= 900:
			_try_buy("talon")
		_buy_utility()


func _buy_armor() -> void:
	if armor <= 0.0:
		if not _try_buy("armor_helmet"):
			_try_buy("armor")
	if not has_helmet:
		_try_buy("helmet")


func _buy_primary_for_role(full: bool) -> void:
	if weapon_in_slot(Slot.PRIMARY) != "":
		return
	var wants: Array[String] = []
	if full:
		match role:
			Role.ANGLE:
				wants = ["sr1", "br52", "ar77"]
			Role.ENTRY:
				wants = ["ar77", "br52", "mk9"]
			Role.LURK:
				wants = ["br52", "ar77", "viper45"]
			_:
				wants = ["br52", "ar77"] if team == GameState.Team.DEF else ["ar77", "br52"]
	else:
		wants = ["viper45", "mk9", "breacher12"]
	for id in wants:
		if _try_buy(id):
			return


func _buy_utility() -> void:
	if _rng.randf() > float(_tune.utility):
		return
	_try_buy("flash")
	if _rng.randf() < float(_tune.utility):
		_try_buy("smoke")
	if _rng.randf() < float(_tune.utility) * 0.7:
		_try_buy("frag")


func _try_buy(id: String) -> bool:
	var def := _weapon_def(id)
	if def.is_empty():
		return false
	var price := int(def.get("price", 0))
	if not Economy.can_afford(player_id, price):
		return false
	var ok := false
	if _is_gear_id(id):
		ok = give_gear(id, def)
	else:
		ok = give_weapon(id, false)
	if ok:
		Economy.try_spend(player_id, price)
	return ok


func _weapon_def(id: String) -> Dictionary:
	return WeaponDB.get_def(id)


# ---------------------------------------------------------------------------

func _on_bot_died(_attacker_id: int, _weapon_id: String, _headshot: bool) -> void:
	target = null
	target_visible = false
	has_investigate = false
	_has_move_goal = false
	_fire_hold = 0.0
	_action_kind = 0
	if blackboard and carrying_bomb:
		blackboard.bomb_is_dropped = true
		blackboard.bomb_dropped_pos = global_position
	carrying_bomb = false


## Re-seed the aim from the spawn transform; the aim direction is what drives
## body yaw every tick, so a respawn without this leaves the bot facing wherever
## it was looking when it died.
func respawn(xform: Transform3D) -> void:
	super.respawn(xform)
	aim_dir = -xform.basis.z
	_desired_dir = aim_dir
	if eye:
		eye.rotation.x = 0.0


func reset_for_round() -> void:
	target = null
	target_visible = false
	settle = 0.0
	has_investigate = false
	_has_move_goal = false
	_fire_hold = 0.0
	_fire_pause = 0.0
	_action_kind = 0
	_action_timer = 0.0
	_recoil_comp = Vector2.ZERO
	goal = Goal.IDLE
	_last_pos = global_position
