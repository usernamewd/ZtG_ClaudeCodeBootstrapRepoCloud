class_name PlayerCharacter
extends CharacterBase
## The local human player. Owns the camera rig (body yaw + CamPivot pitch),
## InputHub-driven locomotion, the weapon mount, and the whole "feel" layer:
## per-shot recoil with recovery, speed-driven view bob, spring/damper weapon
## sway with idle breathing, landing dip / jump rise and the ADS FOV + viewmodel
## blend. Everything below is frame-rate independent and allocation free per
## frame: every vector/float it needs is a preallocated member.
##
## Scene contract (scenes/characters/player.tscn, built by tools/build_player.gd):
##   Player              CharacterBody3D, layer 2 (player), mask world|bot|clip,
##                       group "player"
##     BodyShape         CollisionShape3D capsule       (driven by CharacterBase)
##     Eye               Node3D, y driven by the crouch blend (CharacterBase)
##       CamPivot        Node3D — pitch, landing dip
##         Camera3D      fov / near from the scene; bob + roll live here
##           WeaponMount Node3D — holds the current Weapon node
##     Body              Node3D — Phase 2 full-body mesh (mesh_root_path)
##     Hitboxes          StaticBody3D children, group "hitbox", layer 4
##
## HUD API (see the "hud" section at the bottom): `hud_state_changed`,
## `weapon_equipped`, `hit_marker` plus get_health/get_armor/get_mag_ammo/
## get_reserve_ammo/get_weapon_id/get_spread_deg/get_ads_progress/...

## Emitted whenever something the HUD paints changed (health, armour, ammo,
## weapon, reload state). Never emitted from a per-frame path.
signal hud_state_changed()
## The Weapon node under WeaponMount changed. `weapon` may be null when the
## slot holds an id with no runtime Weapon implementation yet.
signal weapon_equipped(weapon: Node3D, weapon_id: String)
## Relay of the weapon's `hit_confirmed` for hitmarkers.
signal hit_marker(zone: int, died: bool)

const PITCH_LIMIT_DEG := 89.0

# --- Recoil ---------------------------------------------------------------
const RECOIL_RECOVER_DELAY := 0.12   # s after the last shot before recovery
const RECOIL_INDEX_RESET := 0.25     # s idle before the pattern restarts (Weapon does the same)
const RECOIL_SNAP := 26.0            # exp rate the view chases the kick goal
const RECOIL_ADS_MULT := 0.72
const RECOIL_KICK_MAX_DEG := 8.0     # sanity clamp on a single shot
const RECOIL_RECOVERY_FALLBACK := 22.0

# --- View bob -------------------------------------------------------------
const BOB_RATE := 11.0               # phase rad/s at full speed
const BOB_BLEND := 9.0
const BOB_AMP_X := 0.032
const BOB_AMP_Y := 0.024
const BOB_ROLL_DEG := 0.55
const LEAN_DEG := 1.35               # strafe lean
const LEAN_BLEND := 7.0

# --- Landing dip / jump rise ---------------------------------------------
const LAND_STIFF := 120.0
const LAND_DAMP := 15.0
const LAND_MAX := 0.22
const LAND_PER_SPEED := 0.11         # dip velocity per m/s of impact
const LAND_IMPULSE_MAX := 1.4
const JUMP_RISE := 0.35

# --- Weapon sway ----------------------------------------------------------
const SWAY_IMPULSE := 1.4            # sway deg/s per deg of look delta
const SWAY_STIFF := 95.0
const SWAY_DAMP := 15.0
const SWAY_MAX_DEG := 7.0
const SWAY_POS := 0.0035             # m of viewmodel slide per deg of sway
const BREATH_RATE := 1.15
const BREATH_DEG := 0.5
const BREATH_POS := 0.005
const PUNCH_STIFF := 260.0
const PUNCH_DAMP := 20.0
const PUNCH_PER_DEG := 0.012
const DRAW_DROP := 0.16              # m the viewmodel drops while drawing
const DRAW_TILT_DEG := 22.0

const WEAPON_SCRIPT_PATH := "res://src/weapons/weapon.gd"

# Weapon duck-typing. The Weapon class is written in parallel, so it is bound by
# name once per equip and never inspected again (see _bind_weapon).
enum TrigMode { NONE, HOLD, DOWN_UP, PULSE }
const M_SET_TRIGGER := &"set_trigger"
const M_SET_FIRING := &"set_firing"
const M_SET_FIRE_HELD := &"set_fire_held"
const M_TRIGGER := &"trigger"
const M_TRIGGER_DOWN := &"trigger_down"
const M_TRIGGER_UP := &"trigger_up"
const M_FIRE := &"fire"
const M_CAMERA_KICK := &"camera_kick"
const M_CURRENT_SPREAD := &"current_spread_deg"
const M_IS_RELOADING := &"is_reloading"
const SETUP_NAMES: Array[StringName] = [&"setup", &"initialize", &"init_weapon", &"configure", &"equip"]
const PROP_OWNER: Array[String] = ["character", "owner_char", "owner_character", "holder",
	"shooter", "wielder", "user", "carrier"]
const PROP_AIM: Array[String] = ["camera", "cam", "aim_source", "ray_source", "ray_origin",
	"view_camera", "eye"]
const RELOAD_NAMES: Array[StringName] = [&"reload", &"try_reload", &"start_reload", &"begin_reload"]
const HOLD_NAMES: Array[StringName] = [M_SET_TRIGGER, M_SET_FIRING, M_SET_FIRE_HELD, M_TRIGGER]

@export_group("Rig")
@export var cam_pivot_path: NodePath = ^"Eye/CamPivot"
@export var camera_path: NodePath = ^"Eye/CamPivot/Camera3D"
@export var weapon_mount_path: NodePath = ^"Eye/CamPivot/Camera3D/WeaponMount"
@export var auto_activate_camera: bool = true

@export_group("Viewmodel")
@export var hip_position: Vector3 = Vector3(0.17, -0.14, -0.30)
@export var ads_position: Vector3 = Vector3(0.0, -0.055, -0.20)

@export_group("Feel")
@export_range(0.0, 2.0, 0.05) var recoil_camera_mult: float = 1.0
@export_range(0.0, 2.0, 0.05) var bob_scale: float = 1.0
@export_range(0.0, 2.0, 0.05) var sway_scale: float = 1.0
## Set when the Weapon's camera_kick() reports the *accumulated* kick instead of
## the kick of the shot that was just fired.
@export var weapon_kick_is_cumulative: bool = false

var _cam_pivot: Node3D = null
var _camera: Camera3D = null
var _weapon_mount: Node3D = null
var _weapon: Node3D = null
var _weapon_script: Script = null
var _rig_ok: bool = false

# Aim, degrees. The applied rotation is aim + recoil, clamped.
var _yaw_deg: float = 0.0
var _pitch_deg: float = 0.0

var _recoil_goal: Vector2 = Vector2.ZERO
var _recoil_view: Vector2 = Vector2.ZERO
var _recoil_index: int = 0
var _shot_idle: float = 99.0
var _kick_prev_raw: Vector2 = Vector2.ZERO

var _ads_goal: float = 0.0
var _ads_t: float = 0.0
var _ads_eased: float = 0.0

var _bob_phase: float = 0.0
var _bob_amp: float = 0.0
var _lean: float = 0.0
var _cam_fx_live: bool = false
var _applied_fov: float = -1.0
var _land_offset: float = 0.0
var _land_vel: float = 0.0
var _grounded: bool = true

var _sway: Vector2 = Vector2.ZERO
var _sway_vel: Vector2 = Vector2.ZERO
var _breath_a: float = 0.0
var _breath_b: float = 1.7
var _vm_punch: float = 0.0
var _vm_punch_vel: float = 0.0
var _draw_timer: float = 0.0

# Reused every frame so the hot paths never build a Vector3/Vector2.
var _cam_offset: Vector3 = Vector3.ZERO
var _vm_pos: Vector3 = Vector3.ZERO
var _vm_rot: Vector3 = Vector3.ZERO

# Cached from the current weapon def (never read the Dictionary per frame).
var _base_fov: float = 75.0
var _ads_fov: float = 75.0
var _ads_time: float = 0.15
var _ads_spread_mult: float = 1.0
var _spread_base: float = 0.0
var _spread_move: float = 0.0
var _spread_air: float = 0.0
var _recoil_recovery: float = RECOIL_RECOVERY_FALLBACK
var _draw_time: float = 0.0
var _is_auto: bool = false
var _can_ads: bool = false

var _trigger_mode: int = TrigMode.NONE
var _trigger_method: StringName = &""
var _reload_method: StringName = &""
var _has_kick_fn: bool = false
var _has_spread_fn: bool = false
var _has_reloading_fn: bool = false
var _fire_sent: bool = false

# Scratch containers for the (rare) weapon-bind path only.
var _setup_args: Array = []
var _weapon_props: Dictionary = {}


func _ready() -> void:
	# Set before super() so CharacterBase caches the right layer/mask for its
	# set_body_collision_enabled() toggle.
	collision_layer = LAYER_PLAYER
	collision_mask = LAYER_WORLD | LAYER_BOT | LAYER_CLIP
	super._ready()
	add_to_group(&"player")

	_cam_pivot = get_node_or_null(cam_pivot_path) as Node3D
	_camera = get_node_or_null(camera_path) as Camera3D
	_weapon_mount = get_node_or_null(weapon_mount_path) as Node3D
	_rig_ok = _cam_pivot != null and _camera != null and _weapon_mount != null
	if not _rig_ok:
		push_error("PlayerCharacter: camera rig incomplete (CamPivot/Camera3D/WeaponMount)")
		set_process(false)
		return
	if auto_activate_camera:
		_camera.current = true
	_base_fov = _camera.fov
	_ads_fov = _base_fov

	rotation = Vector3(0.0, rotation.y, 0.0)
	_yaw_deg = rad_to_deg(rotation.y)
	_pitch_deg = 0.0
	_cam_pivot.rotation = Vector3.ZERO
	_camera.rotation = Vector3.ZERO
	_vm_pos = hip_position
	_weapon_mount.position = _vm_pos
	_weapon_mount.rotation = Vector3.ZERO

	if ResourceLoader.exists(WEAPON_SCRIPT_PATH):
		_weapon_script = load(WEAPON_SCRIPT_PATH) as Script

	weapon_changed.connect(_on_weapon_changed)
	health_changed.connect(_on_health_changed)
	inventory_changed.connect(_on_inventory_changed)
	respawned.connect(_on_respawned)
	_equip_current()


# ------------------------------------------------------------------ per frame

func _process(delta: float) -> void:
	_update_ads(delta)
	_update_look(delta)
	_update_recoil(delta)
	_apply_view_rotation()
	_update_camera_feel(delta)
	_update_viewmodel(delta)


func _update_ads(delta: float) -> void:
	if _ads_time <= 0.0:
		_ads_t = _ads_goal
	else:
		_ads_t = move_toward(_ads_t, _ads_goal, delta / _ads_time)
	_ads_eased = _ads_t * _ads_t * (3.0 - 2.0 * _ads_t)
	var f := lerpf(_base_fov, _ads_fov, _ads_eased)
	if not is_equal_approx(f, _applied_fov):
		_applied_fov = f
		_camera.fov = f


func _update_look(_delta: float) -> void:
	var look := InputHub.consume_look()
	if not alive:
		return
	# InputHub (touch + mouse) already scaled by Settings.look_sensitivity; only
	# the ADS multiplier is applied here.
	var sens := lerpf(1.0, Settings.ads_sensitivity_mult, _ads_eased)
	var dx := look.x * sens
	var dy := look.y * sens
	if is_zero_approx(dx) and is_zero_approx(dy):
		return
	_yaw_deg = wrapf(_yaw_deg - dx, -180.0, 180.0)
	if Settings.invert_y:
		_pitch_deg += dy
	else:
		_pitch_deg -= dy
	_pitch_deg = clampf(_pitch_deg, -PITCH_LIMIT_DEG, PITCH_LIMIT_DEG)
	# The viewmodel lags the swing: feed the look as an impulse into the sway
	# spring, so the total kick over a swipe is frame-rate independent.
	var imp := SWAY_IMPULSE * sway_scale * (1.0 - _ads_eased * 0.65)
	_sway_vel.x -= dx * imp
	_sway_vel.y -= dy * imp


func _update_recoil(delta: float) -> void:
	if _shot_idle < 10.0:
		_shot_idle += delta
		if _shot_idle >= RECOIL_INDEX_RESET:
			_recoil_index = 0
			_kick_prev_raw = Vector2.ZERO
	if _shot_idle >= RECOIL_RECOVER_DELAY and _recoil_goal != Vector2.ZERO:
		_recoil_goal = _recoil_goal.move_toward(Vector2.ZERO, _recoil_recovery * delta)
	var k := 1.0 - exp(-RECOIL_SNAP * delta)
	_recoil_view.x += (_recoil_goal.x - _recoil_view.x) * k
	_recoil_view.y += (_recoil_goal.y - _recoil_view.y) * k


## Body carries yaw, CamPivot carries pitch. Recoil rides on top of the aim so
## recovery returns to exactly the pre-fire direction.
func _apply_view_rotation() -> void:
	rotation.y = deg_to_rad(_yaw_deg - _recoil_view.x)
	_cam_pivot.rotation.x = deg_to_rad(
		clampf(_pitch_deg + _recoil_view.y, -PITCH_LIMIT_DEG, PITCH_LIMIT_DEG))


func _update_camera_feel(delta: float) -> void:
	# Landing dip / jump rise: critically-ish damped spring on the pivot height.
	if not is_zero_approx(_land_offset) or not is_zero_approx(_land_vel):
		_land_vel += (-_land_offset * LAND_STIFF - _land_vel * LAND_DAMP) * delta
		_land_offset = clampf(_land_offset + _land_vel * delta, -LAND_MAX, LAND_MAX)
		_cam_pivot.position.y = _land_offset

	var ratio := 0.0
	if _grounded:
		ratio = clampf(planar_speed() / maxf(current_speed(), 0.01), 0.0, 1.0)
	_bob_phase = wrapf(_bob_phase + delta * BOB_RATE * ratio, 0.0, TAU)
	var want_bob := ratio * (1.0 - _ads_eased) * bob_scale
	if not _grounded:
		want_bob = 0.0
	_bob_amp += (want_bob - _bob_amp) * (1.0 - exp(-BOB_BLEND * delta))

	var want_lean := -InputHub.move.x * LEAN_DEG * (1.0 - _ads_eased)
	_lean += (want_lean - _lean) * (1.0 - exp(-LEAN_BLEND * delta))
	if _bob_amp < 0.0004:
		_bob_amp = 0.0
	if absf(_lean) < 0.0004:
		_lean = 0.0

	var s := sin(_bob_phase)
	_cam_offset.x = s * BOB_AMP_X * _bob_amp
	_cam_offset.y = sin(_bob_phase * 2.0) * BOB_AMP_Y * _bob_amp
	var roll := _lean + s * BOB_ROLL_DEG * _bob_amp
	# Skip the transform write entirely once bob and lean have fully settled.
	if _cam_fx_live or _cam_offset != Vector3.ZERO or roll != 0.0:
		_camera.position = _cam_offset
		_camera.rotation.z = deg_to_rad(roll)
		_cam_fx_live = _cam_offset != Vector3.ZERO or roll != 0.0


func _update_viewmodel(delta: float) -> void:
	# Sway spring back to rest (the look impulse is injected in _update_look).
	_sway_vel.x += (-_sway.x * SWAY_STIFF - _sway_vel.x * SWAY_DAMP) * delta
	_sway_vel.y += (-_sway.y * SWAY_STIFF - _sway_vel.y * SWAY_DAMP) * delta
	_sway.x = clampf(_sway.x + _sway_vel.x * delta, -SWAY_MAX_DEG, SWAY_MAX_DEG)
	_sway.y = clampf(_sway.y + _sway_vel.y * delta, -SWAY_MAX_DEG, SWAY_MAX_DEG)

	_breath_a = wrapf(_breath_a + delta * BREATH_RATE, 0.0, TAU)
	_breath_b = wrapf(_breath_b + delta * BREATH_RATE * 0.63, 0.0, TAU)
	var idle := (1.0 - _ads_eased * 0.8) * (1.0 - _bob_amp * 0.6)
	var br_x := sin(_breath_a) * BREATH_DEG * idle
	var br_y := sin(_breath_b) * BREATH_DEG * 0.7 * idle

	_vm_punch_vel += (-_vm_punch * PUNCH_STIFF - _vm_punch_vel * PUNCH_DAMP) * delta
	_vm_punch += _vm_punch_vel * delta

	var damp := 1.0 - _ads_eased
	var rx := -_sway.y * damp + br_y
	var ry := _sway.x * damp + br_x
	var rz := _sway.x * 0.3 * damp

	var t := _ads_eased
	_vm_pos.x = lerpf(hip_position.x, ads_position.x, t) + _sway.x * SWAY_POS * damp
	_vm_pos.y = lerpf(hip_position.y, ads_position.y, t) - _sway.y * SWAY_POS * damp \
		+ sin(_breath_b) * BREATH_POS * idle
	_vm_pos.z = lerpf(hip_position.z, ads_position.z, t) + _vm_punch

	if _draw_timer > 0.0 and _draw_time > 0.0:
		var d := clampf(_draw_timer / _draw_time, 0.0, 1.0)
		var d2 := d * d
		_vm_pos.y -= d2 * DRAW_DROP
		rx -= d2 * DRAW_TILT_DEG

	_vm_rot.x = deg_to_rad(rx)
	_vm_rot.y = deg_to_rad(ry)
	_vm_rot.z = deg_to_rad(rz)
	_weapon_mount.position = _vm_pos
	_weapon_mount.rotation = _vm_rot


# ---------------------------------------------------------------- per physics

func _physics_process(delta: float) -> void:
	if _draw_timer > 0.0:
		_draw_timer = maxf(_draw_timer - delta, 0.0)

	if not alive:
		_ads_goal = 0.0
		_send_trigger(false)
		# Drop the one-shots so a press made while dead does not fire on respawn.
		InputHub.consume_jump()
		InputHub.consume_reload()
		InputHub.consume_switch()
		InputHub.grenade_cycle_pressed = false
		move_locomotion(delta, Vector2.ZERO, false, false)
		_grounded = is_on_floor()
		return

	is_ads = _can_ads and InputHub.ads_held
	_ads_goal = 1.0 if is_ads else 0.0

	_handle_weapon_input()

	var want_jump := InputHub.consume_jump()
	var fall_speed := velocity.y
	var was_grounded := is_on_floor()
	move_locomotion(delta, InputHub.move, want_jump, InputHub.crouch_held)
	_grounded = is_on_floor()

	if _grounded and not was_grounded:
		_land_vel -= clampf(absf(fall_speed) * LAND_PER_SPEED, 0.0, LAND_IMPULSE_MAX)
	elif was_grounded and not _grounded and velocity.y > 0.1:
		_land_vel += JUMP_RISE


func _handle_weapon_input() -> void:
	var slot := InputHub.consume_switch()
	if slot >= 0:
		if slot == Slot.GRENADE and current_slot == Slot.GRENADE:
			cycle_grenade()
		else:
			switch_slot(slot)
	if InputHub.grenade_cycle_pressed:
		InputHub.grenade_cycle_pressed = false
		cycle_grenade()
	if InputHub.consume_reload():
		_try_reload()
	_send_trigger(InputHub.fire_held and _draw_timer <= 0.0)


## Trigger state is pushed on change only (PULSE weapons excepted), so the
## physics tick stays free of dynamic calls while nothing happens.
func _send_trigger(held: bool) -> void:
	if _weapon == null or _trigger_mode == TrigMode.NONE:
		_fire_sent = false
		return
	match _trigger_mode:
		TrigMode.HOLD:
			if held != _fire_sent:
				_weapon.call(_trigger_method, held)
				_fire_sent = held
		TrigMode.DOWN_UP:
			if held != _fire_sent:
				_weapon.call(M_TRIGGER_DOWN if held else M_TRIGGER_UP)
				_fire_sent = held
		TrigMode.PULSE:
			# Only `fire()` exists: the weapon owns the rate gate, we own the
			# semi-auto "one shot per press" rule.
			if held and (_is_auto or not _fire_sent):
				_weapon.call(M_FIRE)
			_fire_sent = held


func _try_reload() -> void:
	if _weapon != null and _reload_method != &"":
		_weapon.call(_reload_method)
		hud_state_changed.emit()


# ------------------------------------------------------------------- weapons

func _on_weapon_changed(_slot: int, _weapon_id: String) -> void:
	_equip_current()
	hud_state_changed.emit()


func _on_inventory_changed() -> void:
	hud_state_changed.emit()


func _on_health_changed(_h: float, _a: float) -> void:
	hud_state_changed.emit()


func _on_respawned() -> void:
	_recoil_goal = Vector2.ZERO
	_recoil_view = Vector2.ZERO
	_recoil_index = 0
	_shot_idle = 99.0
	_land_offset = 0.0
	_land_vel = 0.0
	_bob_amp = 0.0
	_sway = Vector2.ZERO
	_sway_vel = Vector2.ZERO
	_vm_punch = 0.0
	_vm_punch_vel = 0.0
	_ads_goal = 0.0
	_ads_t = 0.0
	_ads_eased = 0.0
	_pitch_deg = 0.0
	if _rig_ok:
		_cam_pivot.position.y = 0.0
	_equip_current()
	hud_state_changed.emit()


func _on_death(_attacker_id: int, _weapon_id: String, _headshot: bool) -> void:
	_send_trigger(false)
	_ads_goal = 0.0
	if _weapon_mount != null:
		_weapon_mount.visible = false
	hud_state_changed.emit()


func _equip_current() -> void:
	if not _rig_ok:
		return
	_clear_weapon()
	_cache_weapon_def()
	_weapon_mount.visible = alive
	var id := current_weapon_id()
	if id.is_empty():
		weapon_equipped.emit(null, id)
		return

	var node := _instantiate_weapon(current_weapon_def())
	if node != null:
		_prime_weapon_properties(node)
		_weapon_mount.add_child(node)
		_weapon = node
		_bind_weapon(node)
	_draw_timer = _draw_time
	_fire_sent = false
	_vm_punch = 0.0
	_vm_punch_vel = 0.0
	weapon_equipped.emit(_weapon, id)


func _instantiate_weapon(def: Dictionary) -> Node3D:
	var node: Node3D = null
	var vm_path := String(def.get("vm_scene", ""))
	if not vm_path.is_empty() and ResourceLoader.exists(vm_path):
		var packed := load(vm_path) as PackedScene
		if packed != null:
			node = packed.instantiate() as Node3D
	if node == null and _weapon_script != null:
		node = Node3D.new()
		node.set_script(_weapon_script)
	elif node != null and node.get_script() == null and _weapon_script != null:
		node.set_script(_weapon_script)
	return node


## Fills whichever of the well-known properties the Weapon actually declares,
## before it enters the tree, so its _ready() already sees a valid owner/camera.
func _prime_weapon_properties(w: Node) -> void:
	_weapon_props.clear()
	for p in w.get_property_list():
		_weapon_props[String(p.get("name", ""))] = true
	_set_if_present(w, "weapon_id", current_weapon_id())
	_set_if_present(w, "id", current_weapon_id())
	_set_if_present(w, "def", current_weapon_def())
	_set_if_present(w, "weapon_def", current_weapon_def())
	for n in PROP_OWNER:
		_set_if_present(w, n, self)
	for n in PROP_AIM:
		_set_if_present(w, n, _camera)


func _set_if_present(w: Node, prop: String, value: Variant) -> void:
	if _weapon_props.has(prop):
		w.set(prop, value)


## Resolves the Weapon's API by name exactly once per equip and caches it, so
## nothing in _process/_physics_process has to introspect.
func _bind_weapon(w: Node) -> void:
	_trigger_mode = TrigMode.NONE
	_trigger_method = &""
	_reload_method = &""
	_has_kick_fn = w.has_method(M_CAMERA_KICK)
	_has_spread_fn = w.has_method(M_CURRENT_SPREAD)
	_has_reloading_fn = w.has_method(M_IS_RELOADING)

	_call_weapon_setup(w)

	for n in HOLD_NAMES:
		if w.has_method(n):
			_trigger_mode = TrigMode.HOLD
			_trigger_method = n
			break
	if _trigger_mode == TrigMode.NONE:
		if w.has_method(M_TRIGGER_DOWN) and w.has_method(M_TRIGGER_UP):
			_trigger_mode = TrigMode.DOWN_UP
		elif w.has_method(M_FIRE):
			_trigger_mode = TrigMode.PULSE
	for n in RELOAD_NAMES:
		if w.has_method(n):
			_reload_method = n
			break

	_connect_weapon_signal(w, &"fired", _on_weapon_fired, 0)
	_connect_weapon_signal(w, &"ammo_changed", _on_weapon_state, 0)
	_connect_weapon_signal(w, &"reload_started", _on_weapon_state, 0)
	_connect_weapon_signal(w, &"reload_finished", _on_weapon_state, 0)
	if not _connect_weapon_signal(w, &"hit_confirmed", _on_weapon_hit, 2):
		_connect_weapon_signal(w, &"hit_confirmed", _on_weapon_hit_unknown, 0)


## Calls the Weapon's init entry point, matching its declared parameter names
## (falling back to positional owner/camera/id) so either signature works.
func _call_weapon_setup(w: Node) -> bool:
	for m in w.get_method_list():
		var mname := StringName(m.get("name", ""))
		if not SETUP_NAMES.has(mname):
			continue
		var margs: Array = m.get("args", [])
		_setup_args.clear()
		for a in margs:
			_setup_args.append(_setup_value_for(String(a.get("name", "")), _setup_args.size()))
		w.callv(mname, _setup_args)
		return true
	return false


func _setup_value_for(param_name: String, index: int) -> Variant:
	var n := param_name.to_lower()
	if n.contains("cam") or n.contains("aim") or n.contains("eye") or n.contains("ray") \
			or n.contains("source") or n.contains("view"):
		return _camera
	if n.contains("char") or n.contains("owner") or n.contains("holder") \
			or n.contains("shooter") or n.contains("wielder") or n.contains("user") \
			or n.contains("carrier"):
		return self
	if n.contains("def"):
		return current_weapon_def()
	if n.contains("id"):
		return current_weapon_id()
	match index:
		0:
			return self
		1:
			return _camera
		2:
			return current_weapon_id()
	return null


func _connect_weapon_signal(w: Object, sig: StringName, cb: Callable, expected: int) -> bool:
	if not w.has_signal(sig):
		return false
	var n := -1
	for s in w.get_signal_list():
		if StringName(s.get("name", "")) == sig:
			n = (s.get("args", []) as Array).size()
			break
	if n < expected:
		return false
	var c := cb if n == expected else cb.unbind(n - expected)
	if w.is_connected(sig, c):
		return true
	return w.connect(sig, c) == OK


func _clear_weapon() -> void:
	if _weapon != null and is_instance_valid(_weapon):
		_weapon.queue_free()
	_weapon = null
	_trigger_mode = TrigMode.NONE
	_trigger_method = &""
	_reload_method = &""
	_has_kick_fn = false
	_has_spread_fn = false
	_has_reloading_fn = false
	_fire_sent = false
	_kick_prev_raw = Vector2.ZERO


func _cache_weapon_def() -> void:
	var d := current_weapon_def()
	_ads_fov = float(d.get("ads_fov", _base_fov))
	_ads_time = maxf(float(d.get("ads_time", 0.15)), 0.01)
	_ads_spread_mult = float(d.get("ads_spread_mult", 1.0))
	_spread_base = float(d.get("spread_base", 0.0))
	_spread_move = float(d.get("spread_move_add", 0.0))
	_spread_air = float(d.get("spread_air_add", 0.0))
	_recoil_recovery = maxf(float(d.get("recoil_recovery", RECOIL_RECOVERY_FALLBACK)), 1.0)
	_draw_time = float(d.get("draw_time", 0.0))
	_is_auto = bool(d.get("auto", false))
	# Knives, grenades and anything whose ads_fov is not a zoom cannot aim.
	_can_ads = _ads_fov < _base_fov - 0.5


# --------------------------------------------------------------------- recoil

func _on_weapon_fired() -> void:
	var kick := _shot_kick()
	_recoil_index += 1
	_shot_idle = 0.0
	if kick != Vector2.ZERO:
		var m := recoil_camera_mult * lerpf(1.0, RECOIL_ADS_MULT, _ads_eased)
		_recoil_goal.x += kick.x * m
		_recoil_goal.y += kick.y * m
		_vm_punch_vel += kick.length() * PUNCH_PER_DEG * 26.0
	hud_state_changed.emit()


## Per-shot kick in degrees, x = yaw drift (+ right), y = pitch up. The pattern
## in WeaponDB is authoritative; camera_kick() is only used for ids the DB has
## no pattern for.
func _shot_kick() -> Vector2:
	var id := current_weapon_id()
	var kick := Vector2.ZERO
	if not id.is_empty() and WeaponDB.has_def(id):
		kick = WeaponDB.recoil_at(id, _recoil_index)
	if kick == Vector2.ZERO and _has_kick_fn:
		var raw: Vector2 = _weapon.call(M_CAMERA_KICK)
		if weapon_kick_is_cumulative:
			kick = raw - _kick_prev_raw
			_kick_prev_raw = raw
		else:
			kick = raw
	var l := kick.length()
	if l > RECOIL_KICK_MAX_DEG:
		kick *= RECOIL_KICK_MAX_DEG / l
	return kick


func _on_weapon_state() -> void:
	hud_state_changed.emit()


func _on_weapon_hit(zone: int, died: bool) -> void:
	hit_marker.emit(zone, died)


func _on_weapon_hit_unknown() -> void:
	hit_marker.emit(Zone.CHEST, false)


# ------------------------------------------------------------------- HUD API
# Everything the Phase 1 HUD needs. All cheap; safe to poll once per frame, but
# `hud_state_changed` fires on every meaningful change so polling is optional.

func get_health() -> float:
	return health


func get_max_health() -> float:
	return max_health


func get_armor() -> float:
	return armor


func get_helmet() -> bool:
	return has_helmet


func get_weapon_id() -> String:
	return current_weapon_id()


func get_weapon_display_name() -> String:
	return String(current_weapon_def().get("display_name", current_weapon_id()))


func get_weapon_node() -> Node3D:
	return _weapon


func get_mag_ammo() -> int:
	return get_mag(current_weapon_id())


func get_reserve_ammo() -> int:
	return get_reserve(current_weapon_id())


func get_grenade_count() -> int:
	return (slots[Slot.GRENADE] as Array).size()


## Current cone half-angle in degrees for the dynamic crosshair. Uses the
## weapon's own value when it exposes one, otherwise the WeaponDB model.
func get_spread_deg() -> float:
	if _weapon != null and _has_spread_fn:
		return float(_weapon.call(M_CURRENT_SPREAD))
	var s := _spread_base
	if not _grounded:
		s += _spread_air
	else:
		s += _spread_move * clampf(planar_speed() / maxf(current_speed(), 0.01), 0.0, 1.0)
	return lerpf(s, s * _ads_spread_mult, _ads_eased)


func is_reloading() -> bool:
	if _weapon != null and _has_reloading_fn:
		return bool(_weapon.call(M_IS_RELOADING))
	return false


func is_drawing() -> bool:
	return _draw_timer > 0.0


func get_ads_progress() -> float:
	return _ads_eased


func can_ads() -> bool:
	return _can_ads


func get_camera() -> Camera3D:
	return _camera


func get_weapon_mount() -> Node3D:
	return _weapon_mount


func get_yaw_deg() -> float:
	return _yaw_deg


func get_pitch_deg() -> float:
	return _pitch_deg


## Face the player at a world point (spawn orientation, kill cam, teleports).
func look_at_point(target: Vector3) -> void:
	var to := target - eye_position()
	var flat := Vector2(to.x, to.z).length()
	_yaw_deg = rad_to_deg(atan2(-to.x, -to.z))
	_pitch_deg = clampf(rad_to_deg(atan2(to.y, flat)), -PITCH_LIMIT_DEG, PITCH_LIMIT_DEG)
	if _rig_ok:
		_apply_view_rotation()


## Drop all aim state (used on respawn by the match code).
func reset_view() -> void:
	_on_respawned()
