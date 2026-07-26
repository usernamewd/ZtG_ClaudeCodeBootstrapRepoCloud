extends Node
## Runtime self-test for src/weapons/weapon.gd. Runs as a SCENE (not --script)
## so the autoloads resolve:
##   godot --headless --path . tools/ts_weapon_selftest.tscn
## Builds a shooter, a target with zone hitboxes and a few walls, then fires real
## shots through the real physics server and checks the damage/ammo/penetration
## results. Exits non-zero on the first failed expectation.

const LAYER_WORLD := 1
const LAYER_BOT := 4
const LAYER_HITBOX := 8
const CHAR_SCRIPT := "res://src/characters/character_base.gd"
const WEAPON_SCRIPT := "res://src/weapons/weapon.gd"

var _fails: int = 0
var _shooter: CharacterBase = null
var _eye: Node3D = null
var _target: CharacterBase = null
var _weapon: Weapon = null
var _walls: Node3D = null
var _hits: int = 0
var _last_zone: int = -1
var _last_died: bool = false


func _ready() -> void:
	_build_world()
	await _settle(4)
	_weapon = Weapon.create_for(_shooter, _shooter, _eye)
	_weapon.hit_confirmed.connect(_on_hit)
	await _test_basic_hit()
	await _test_headshot()
	await _test_falloff()
	await _test_thick_wall_blocks()
	await _test_thin_wall_penetrates()
	await _test_semi_needs_release()
	await _test_ammo_and_reload()
	await _test_fx_pooled()
	await _test_knife()
	print("[ts_weapon] %s (%d failures)" % ["FAIL" if _fails > 0 else "ALL OK", _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# --------------------------------------------------------------------- harness

func _build_world() -> void:
	var char_script := load(CHAR_SCRIPT)

	_shooter = CharacterBody3D.new() as CharacterBody3D
	_shooter.set_script(char_script)
	_shooter.name = "Shooter"
	_shooter.collision_layer = LAYER_BOT
	_shooter.collision_mask = LAYER_WORLD
	_eye = Node3D.new()
	_eye.name = "Eye"
	_eye.position = Vector3(0.0, 1.65, 0.0)
	_shooter.add_child(_eye)
	add_child(_shooter)
	_shooter.player_id = 7
	_shooter.team = 0

	_target = CharacterBody3D.new() as CharacterBody3D
	_target.set_script(char_script)
	_target.name = "Target"
	_target.collision_layer = LAYER_BOT
	_target.collision_mask = 0
	_target.position = Vector3(0.0, 0.0, -10.0)
	_add_hitbox(_target, "Head", Vector3(0.0, 1.66, 0.0), Vector3(0.24, 0.24, 0.24))
	_add_hitbox(_target, "Chest", Vector3(0.0, 1.25, 0.0), Vector3(0.5, 0.5, 0.32))
	add_child(_target)
	_target.player_id = 9
	_target.team = 1

	_walls = Node3D.new()
	_walls.name = "Walls"
	add_child(_walls)


func _add_hitbox(host: Node3D, zone_name: String, pos: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = zone_name
	body.collision_layer = LAYER_HITBOX
	body.collision_mask = 0
	body.position = pos
	body.add_to_group(&"hitbox")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	host.add_child(body)


func _add_wall(z: float, thickness: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Wall"
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	body.position = Vector3(0.0, 1.3, z)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 3.0, thickness)
	shape.shape = box
	body.add_child(shape)
	_walls.add_child(body)
	return body


func _clear_walls() -> void:
	for c in _walls.get_children():
		_walls.remove_child(c)
		c.free()


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


func _equip(id: String) -> void:
	_shooter.give_weapon(id)
	_shooter.refill_ammo(id)
	await _ready_up()


func _ready_up() -> void:
	for i in 300:
		if _weapon != null and _weapon.is_ready():
			return
		await get_tree().physics_frame


func _aim_at(p: Vector3) -> void:
	_eye.look_at(p, Vector3.UP)
	await get_tree().physics_frame


func _reset_target() -> void:
	_target.reset_state()
	_hits = 0
	_last_zone = -1
	_last_died = false


func _on_hit(zone: int, died: bool) -> void:
	_hits += 1
	_last_zone = zone
	_last_died = died


func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		print("  PASS  ", label)
	else:
		_fails += 1
		printerr("  FAIL  ", label, "  ", detail)


func _about(a: float, b: float, tol := 0.5) -> bool:
	return absf(a - b) <= tol


# ----------------------------------------------------------------------- tests

func _test_basic_hit() -> void:
	print("[ts_weapon] chest hit / damage")
	await _equip("ar77")
	_reset_target()
	await _aim_at(_target.global_position + Vector3(0.0, 1.25, 0.0))
	var before := _target.health
	_check(_weapon.try_fire(), "try_fire returns true when ready")
	await _settle(1)
	_check(_about(before - _target.health, 36.0), "chest damage is 36",
		str(before - _target.health))
	_check(_hits == 1 and _last_zone == CharacterBase.Zone.CHEST, "hit_confirmed CHEST")
	_check(_shooter.get_mag("ar77") == 29, "mag spent one round",
		str(_shooter.get_mag("ar77")))


func _test_headshot() -> void:
	print("[ts_weapon] headshot")
	_reset_target()
	await _ready_up()
	await _aim_at(_target.global_position + Vector3(0.0, 1.66, 0.0))
	_weapon.try_fire()
	await _settle(1)
	_check(not _target.alive, "36 x 4 headshot kills a 100 hp target")
	_check(_last_zone == CharacterBase.Zone.HEAD and _last_died, "hit_confirmed HEAD + died")
	_reset_target()


func _test_falloff() -> void:
	print("[ts_weapon] range falloff")
	_target.position = Vector3(0.0, 0.0, -80.0)   # past range_falloff_end (72)
	_reset_target()
	await _settle(2)
	await _ready_up()
	await _aim_at(_target.global_position + Vector3(0.0, 1.25, 0.0))
	var before := _target.health
	_weapon.try_fire()
	await _settle(1)
	var dmg := before - _target.health
	_check(_about(dmg, 36.0 * 0.72, 0.6), "damage floors at falloff_min_mult", str(dmg))
	_target.position = Vector3(0.0, 0.0, -10.0)
	await _settle(2)


func _test_thick_wall_blocks() -> void:
	print("[ts_weapon] thick wall blocks")
	_clear_walls()
	_add_wall(-5.0, 1.0)
	_reset_target()
	await _settle(3)
	await _ready_up()
	await _aim_at(_target.global_position + Vector3(0.0, 1.25, 0.0))
	var before := _target.health
	_weapon.try_fire()
	await _settle(1)
	_check(is_equal_approx(before, _target.health), "no damage through a 1 m wall",
		str(before - _target.health))
	_check(_hits == 0, "no hit_confirmed through a wall")


func _test_thin_wall_penetrates() -> void:
	print("[ts_weapon] thin wall penetration")
	_clear_walls()
	# ar77 penetration 0.62 -> punches up to 0.217 m.
	_add_wall(-5.0, 0.12)
	_reset_target()
	await _settle(3)
	await _ready_up()
	await _aim_at(_target.global_position + Vector3(0.0, 1.25, 0.0))
	var before := _target.health
	_weapon.try_fire()
	await _settle(1)
	var dmg := before - _target.health
	_check(_about(dmg, 36.0 * 0.5 * 0.62, 0.6), "wallbang damage is dmg * 0.5 * penetration",
		str(dmg))
	_clear_walls()
	await _settle(2)


func _test_semi_needs_release() -> void:
	print("[ts_weapon] semi vs auto trigger")
	await _equip("p9")
	_reset_target()
	await _aim_at(_target.global_position + Vector3(0.0, 1.25, 0.0))
	var mag0 := _shooter.get_mag("p9")
	_weapon.set_trigger(true)
	await _settle(30)                     # 0.5 s held: a semi fires exactly once
	var spent := mag0 - _shooter.get_mag("p9")
	_check(spent == 1, "held semi fires once", str(spent))
	_weapon.set_trigger(false)
	await _settle(1)
	_weapon.set_trigger(true)
	await _settle(2)
	_check(mag0 - _shooter.get_mag("p9") == 2, "second pull fires again")
	_weapon.set_trigger(false)

	await _equip("mk9")
	_reset_target()
	await _aim_at(_target.global_position + Vector3(0.0, 1.25, 0.0))
	var m0 := _shooter.get_mag("mk9")
	_weapon.set_trigger(true)
	await _settle(61)                     # ~1 s at 13.5 rps
	_weapon.set_trigger(false)
	var n := m0 - _shooter.get_mag("mk9")
	_check(n >= 12 and n <= 15, "auto fires at ~fire_rate rounds/s", str(n))


func _test_ammo_and_reload() -> void:
	print("[ts_weapon] ammo + reload")
	await _equip("ar77")
	_shooter.set_ammo("ar77", 4, 10)
	var started := [0.0]
	_weapon.reload_started.connect(func(d: float) -> void: started[0] = d, CONNECT_ONE_SHOT)
	_check(_weapon.start_reload(), "reload starts when the mag is short")
	_check(_weapon.is_reloading(), "state is RELOADING")
	_check(not _weapon.start_reload(), "no double reload")
	for i in 300:
		if not _weapon.is_reloading():
			break
		await get_tree().physics_frame
	_check(_about(float(started[0]), 2.6, 0.01), "reload_started carries reload_time",
		str(started[0]))
	_check(_shooter.get_mag("ar77") == 14 and _shooter.get_reserve("ar77") == 0,
		"partial reload pulls only what the reserve has",
		"%d/%d" % [_shooter.get_mag("ar77"), _shooter.get_reserve("ar77")])
	_shooter.refill_ammo("ar77")
	_check(not _weapon.start_reload(), "no reload on a full mag")


func _test_fx_pooled() -> void:
	print("[ts_weapon] pooled tracer + impact")
	_reset_target()
	await _ready_up()
	await _aim_at(_target.global_position + Vector3(0.0, 1.25, 0.0))
	_weapon.try_fire()
	await _settle(1)
	var impacts := 0
	var tracers := 0
	for c in get_children():
		if c.name.begins_with("Impact"):
			impacts += 1
		elif c.name.begins_with("Tracer"):
			tracers += 1
	_check(impacts >= 1, "impact acquired from the pool", str(impacts))
	_check(tracers >= 1, "tracer acquired from the pool", str(tracers))
	# The tracer releases itself after ~40 ms.
	await _settle(12)
	var live := 0
	for c in get_children():
		if c.name.begins_with("Tracer"):
			live += 1
	_check(live == 0, "tracer released itself back to the pool", str(live))


func _test_knife() -> void:
	print("[ts_weapon] knife melee")
	_target.position = Vector3(0.0, 0.0, -1.2)
	_reset_target()
	await _settle(2)
	await _equip("knife")
	_check(_weapon.is_melee(), "knife runs in melee mode")
	await _aim_at(_target.global_position + Vector3(0.0, 1.25, 0.0))
	var before := _target.health
	_weapon.try_fire()
	await _settle(1)
	var dmg := before - _target.health
	_check(dmg > 0.0, "light swing damages a target in range", str(dmg))
	_check(not _weapon.start_reload(), "knife cannot reload")
	# Out of range: no damage.
	_target.position = Vector3(0.0, 0.0, -6.0)
	_reset_target()
	await _settle(2)
	await _ready_up()
	await _aim_at(_target.global_position + Vector3(0.0, 1.25, 0.0))
	var h := _target.health
	_weapon.try_fire()
	await _settle(1)
	_check(is_equal_approx(h, _target.health), "swing misses beyond melee_range")
