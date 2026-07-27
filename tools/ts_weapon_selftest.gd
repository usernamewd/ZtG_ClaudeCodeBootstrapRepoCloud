extends Node
## Runtime self-test for src/weapons/weapon.gd. Runs as a SCENE (not --script)
## so the autoloads resolve:
##   godot --headless --path . tools/ts_weapon_selftest.tscn
## Builds a floor, a grounded shooter, a target with zone hitboxes and a few
## walls, then fires real shots through the real physics server and checks the
## damage / ammo / penetration results. Exits non-zero on any failed expectation.

const LAYER_WORLD := 1
const LAYER_BOT := 4
const LAYER_HITBOX := 8
const CHAR_SCRIPT := "res://src/characters/character_base.gd"

const NEAR_Z := -6.0
const FAR_Z := -80.0

var _fails: int = 0
var _shooter: CharacterBase = null
var _eye: Node3D = null
var _target: CharacterBase = null
var _far_target: CharacterBase = null
var _weapon: Weapon = null
var _walls: Node3D = null
var _hits: int = 0
var _last_zone: int = -1
var _last_died: bool = false
var _watchdog: float = 0.0
var _drive: bool = false


func _ready() -> void:
	_build_world()
	_drive = true
	await _settle(6)
	_weapon = Weapon.create_for(_shooter, _shooter, _eye)
	_weapon.hit_confirmed.connect(_on_hit)
	_check(_shooter.is_on_floor(), "test shooter is grounded (spread_base only)")
	await _test_basic_hit()
	await _test_headshot()
	await _test_falloff()
	await _test_thick_wall_blocks()
	await _test_thin_wall_penetrates()
	await _test_semi_needs_release()
	await _test_ammo_and_reload()
	await _test_fx_pooled()
	await _test_recoil()
	await _test_knife()
	await _test_shotgun_pellets()
	await _test_burst_and_dryfire()
	await _test_player_binding()
	print("[ts_weapon] %s (%d failures)" % ["FAIL" if _fails > 0 else "ALL OK", _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _physics_process(delta: float) -> void:
	# Real locomotion tick: the weapon reads is_on_floor()/planar_speed() for the
	# movement spread, and those only update through move_and_slide().
	if _drive and _shooter != null:
		_shooter.move_locomotion(delta, Vector2.ZERO, false, false)


func _process(delta: float) -> void:
	_watchdog += delta
	if _watchdog > 120.0:
		printerr("[ts_weapon] TIMEOUT")
		get_tree().quit(2)


# --------------------------------------------------------------------- harness

func _build_world() -> void:
	var char_script := load(CHAR_SCRIPT)

	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = LAYER_WORLD
	floor_body.collision_mask = 0
	floor_body.position = Vector3(0.0, -0.5, -40.0)
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(40.0, 1.0, 200.0)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	add_child(floor_body)

	var shooter_body := CharacterBody3D.new()
	shooter_body.set_script(char_script)
	_shooter = shooter_body as CharacterBase
	_shooter.name = "Shooter"
	_shooter.collision_layer = LAYER_BOT
	_shooter.collision_mask = LAYER_WORLD
	var cap := CollisionShape3D.new()
	cap.name = "BodyShape"
	var caps := CapsuleShape3D.new()
	caps.radius = 0.35
	caps.height = 1.8
	cap.shape = caps
	cap.position = Vector3(0.0, 0.9, 0.0)
	_shooter.add_child(cap)
	_eye = Node3D.new()
	_eye.name = "Eye"
	_eye.position = Vector3(0.0, 1.65, 0.0)
	_shooter.add_child(_eye)
	_shooter.position = Vector3(0.0, 0.05, 0.0)
	add_child(_shooter)
	_shooter.player_id = 7
	_shooter.team = 0

	_target = _make_target("Target", Vector3(0.0, 0.0, NEAR_Z))
	_add_hitbox(_target, "Head", Vector3(0.0, 1.7, 0.0), Vector3(0.3, 0.3, 0.3))
	_add_hitbox(_target, "Chest", Vector3(0.0, 1.2, 0.0), Vector3(0.6, 0.7, 0.35))
	add_child(_target)
	_target.player_id = 9
	_target.team = 1

	# 80 m out the base cone is already ±1.2 m wide, so the far target is a plate.
	_far_target = _make_target("FarTarget", Vector3(10.0, 0.0, FAR_Z))
	_add_hitbox(_far_target, "Chest", Vector3(0.0, 1.2, 0.0), Vector3(6.0, 6.0, 0.4))
	add_child(_far_target)
	_far_target.player_id = 11
	_far_target.team = 1

	_walls = Node3D.new()
	_walls.name = "Walls"
	add_child(_walls)


func _make_target(n: String, pos: Vector3) -> CharacterBase:
	var body := CharacterBody3D.new()
	body.set_script(load(CHAR_SCRIPT))
	var c := body as CharacterBase
	c.name = n
	c.collision_layer = LAYER_BOT
	c.collision_mask = 0
	c.position = pos
	return c


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


func _add_wall(z: float, thickness: float) -> void:
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
		if _weapon != null and _weapon.is_ready() and _weapon.can_fire():
			return
		await get_tree().physics_frame


## Waits out the recoil so single-shot precision tests are not thrown off by
## the previous shot's kick (which this weapon applies to the aim for bots).
func _recover() -> void:
	for i in 400:
		if _weapon.camera_kick().length() < 0.001 and _weapon.can_fire():
			return
		await get_tree().physics_frame


func _aim_at(p: Vector3) -> void:
	_eye.look_at(p, Vector3.UP)
	await get_tree().physics_frame


func _reset() -> void:
	_target.reset_state()
	_far_target.reset_state()
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


func _chest_of(c: CharacterBase) -> Vector3:
	return c.global_position + Vector3(0.0, 1.2, 0.0)


# ----------------------------------------------------------------------- tests

func _test_basic_hit() -> void:
	print("[ts_weapon] chest hit / damage")
	await _equip("ar77")
	_reset()
	await _aim_at(_chest_of(_target))
	var before := _target.health
	_check(_weapon.try_fire(), "try_fire returns true when ready")
	await _settle(1)
	_check(_about(before - _target.health, 36.0), "chest damage is 36",
		str(before - _target.health))
	_check(_hits == 1 and _last_zone == CharacterBase.Zone.CHEST, "hit_confirmed CHEST",
		"%d hits zone %d" % [_hits, _last_zone])
	_check(_shooter.get_mag("ar77") == 29, "mag spent one round",
		str(_shooter.get_mag("ar77")))
	_check(not _weapon.try_fire(), "fire rate gate blocks the next tick")


func _test_headshot() -> void:
	print("[ts_weapon] headshot")
	_reset()
	await _recover()
	await _aim_at(_target.global_position + Vector3(0.0, 1.7, 0.0))
	_weapon.try_fire()
	await _settle(1)
	_check(not _target.alive, "36 x 4 headshot kills a 100 hp target",
		str(_target.health))
	_check(_last_zone == CharacterBase.Zone.HEAD and _last_died, "hit_confirmed HEAD + died",
		"zone %d died %s" % [_last_zone, _last_died])
	_reset()


func _test_falloff() -> void:
	print("[ts_weapon] range falloff")
	_reset()
	await _recover()
	await _aim_at(_chest_of(_far_target))
	var before := _far_target.health
	_weapon.try_fire()
	await _settle(1)
	var dmg := before - _far_target.health
	_check(_about(dmg, 36.0 * 0.72, 0.6), "damage floors at falloff_min_mult (0.72)", str(dmg))


func _test_thick_wall_blocks() -> void:
	print("[ts_weapon] thick wall blocks")
	_clear_walls()
	_add_wall(NEAR_Z * 0.5, 1.0)
	_reset()
	await _settle(3)
	await _recover()
	await _aim_at(_chest_of(_target))
	var before := _target.health
	_weapon.try_fire()
	await _settle(1)
	_check(is_equal_approx(before, _target.health), "no damage through a 1 m wall",
		str(before - _target.health))
	_check(_hits == 0, "no hit_confirmed through a wall", str(_hits))
	var impacts := _count_impacts()
	_check(impacts >= 1, "impact spawned on the wall", str(impacts))


func _test_thin_wall_penetrates() -> void:
	print("[ts_weapon] thin wall penetration")
	_clear_walls()
	# ar77 penetration 0.62 -> punches up to 0.35 * 0.62 = 0.217 m.
	_add_wall(NEAR_Z * 0.5, 0.12)
	_reset()
	await _settle(3)
	await _recover()
	await _aim_at(_chest_of(_target))
	var before := _target.health
	_weapon.try_fire()
	await _settle(1)
	var dmg := before - _target.health
	_check(_about(dmg, 36.0 * 0.5 * 0.62, 0.6), "wallbang damage is dmg * 0.5 * penetration",
		str(dmg))
	_check(_last_zone == CharacterBase.Zone.CHEST, "wallbang still resolves the zone",
		str(_last_zone))
	_clear_walls()
	await _settle(2)


func _test_semi_needs_release() -> void:
	print("[ts_weapon] semi vs auto trigger")
	await _equip("p9")
	_reset()
	await _aim_at(_chest_of(_target))
	var mag0 := _shooter.get_mag("p9")
	_weapon.set_trigger(true)
	await _settle(30)                     # 0.5 s held: a semi fires exactly once
	var spent := mag0 - _shooter.get_mag("p9")
	_check(spent == 1, "held semi fires once", str(spent))
	_weapon.set_trigger(false)
	await _settle(1)
	_weapon.set_trigger(true)
	await _settle(2)
	_check(mag0 - _shooter.get_mag("p9") == 2, "second pull fires again",
		str(mag0 - _shooter.get_mag("p9")))
	_weapon.set_trigger(false)

	await _equip("mk9")
	_reset()
	await _aim_at(_chest_of(_target))
	var m0 := _shooter.get_mag("mk9")
	_weapon.set_trigger(true)
	await _settle(61)                     # ~1 s at 13.5 rps
	_weapon.set_trigger(false)
	var n := m0 - _shooter.get_mag("mk9")
	_check(n >= 12 and n <= 15, "auto fires at ~fire_rate rounds/s", str(n))
	_check(not _target.alive, "a full auto burst kills the target")


func _test_ammo_and_reload() -> void:
	print("[ts_weapon] ammo + reload")
	await _equip("ar77")
	_shooter.set_ammo("ar77", 4, 10)
	var started := [0.0]
	_weapon.reload_started.connect(
		func(d: float) -> void: started[0] = d, CONNECT_ONE_SHOT)
	_check(_weapon.start_reload(), "reload starts when the mag is short")
	_check(_weapon.is_reloading(), "state is RELOADING")
	_check(not _weapon.start_reload(), "no double reload")
	_check(not _weapon.try_fire(), "cannot fire while reloading")
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
	_shooter.set_ammo("ar77", 30, 0)
	_check(not _weapon.start_reload(), "no reload with an empty reserve")

	# Shell-by-shell gun: one shell per reload_shell_time, interruptible.
	await _equip("breacher12")
	_shooter.set_ammo("breacher12", 0, 8)
	_check(_weapon.start_reload(), "shotgun reload starts")
	await _settle(40)                     # 0.55 s per shell -> 1 shell in
	var mag := _shooter.get_mag("breacher12")
	_check(mag >= 1 and mag <= 2, "shells arrive one at a time", str(mag))
	_weapon.set_trigger(true)
	await _settle(2)
	_weapon.set_trigger(false)
	_check(not _weapon.is_reloading(), "firing interrupts a shell reload")


func _test_fx_pooled() -> void:
	print("[ts_weapon] pooled tracer + impact")
	await _equip("ar77")
	_reset()
	_add_wall(NEAR_Z * 0.5, 1.0)
	await _settle(3)
	await _ready_up()
	await _aim_at(_chest_of(_target))
	_weapon.try_fire()
	await _settle(1)
	_check(_count_impacts() >= 1, "impact acquired from the pool",
		str(_count_impacts()))
	_check(_count_tracers() >= 1, "tracer acquired from the pool",
		str(_count_tracers()))
	await _settle(12)                     # tracer lives ~40 ms
	_check(_count_tracers() == 0, "tracer released itself back to the pool",
		str(_count_tracers()))
	await _settle(80)                     # impact lives 1.1 s
	_check(_count_impacts() == 0, "impact released itself back to the pool",
		str(_count_impacts()))
	_clear_walls()
	await _settle(2)


func _test_recoil() -> void:
	print("[ts_weapon] recoil accumulation + recovery")
	await _equip("ar77")
	_reset()
	await _aim_at(_chest_of(_target))
	_check(_weapon.camera_kick() == Vector2.ZERO, "kick starts at zero")
	_weapon.set_trigger(true)
	await _settle(30)
	_weapon.set_trigger(false)
	var kick := _weapon.camera_kick()
	var spread := _weapon.current_spread_deg()
	_check(kick.y > 1.0, "pitch kick accumulates while spraying", str(kick))
	_check(spread > 0.85, "spread blooms above spread_base", str(spread))
	_check(_weapon.get_state() == Weapon.State.FIRING, "state is FIRING while shooting",
		str(_weapon.get_state()))
	await _settle(180)                    # 3 s of recovery
	_check(_weapon.camera_kick().length() < 0.01, "kick decays back to zero",
		str(_weapon.camera_kick()))
	_check(_about(_weapon.current_spread_deg(), 0.85, 0.02), "spread returns to base",
		str(_weapon.current_spread_deg()))
	_check(_weapon.get_state() == Weapon.State.READY, "state returns to READY")


func _test_knife() -> void:
	print("[ts_weapon] knife melee")
	_target.position = Vector3(0.0, 0.0, -1.2)
	_target.rotation.y = PI          # facing the shooter: no backstab bonus
	_reset()
	await _settle(2)
	await _equip("knife")
	_check(_weapon.is_melee(), "knife runs in melee mode")
	await _aim_at(_chest_of(_target))
	var before := _target.health
	_weapon.try_fire()
	await _settle(1)
	_check(_about(before - _target.health, 42.0), "light swing does damage x1 zone",
		str(before - _target.health))
	_check(not _weapon.start_reload(), "knife cannot reload")
	_check(not _weapon.try_fire(), "melee has its own cooldown")
	# Out of range: no damage.
	_target.position = Vector3(0.0, 0.0, -6.0)
	_reset()
	await _settle(2)
	await _ready_up()
	await _aim_at(_chest_of(_target))
	var h := _target.health
	_weapon.try_fire()
	await _settle(1)
	_check(is_equal_approx(h, _target.health), "swing misses beyond melee_range",
		str(h - _target.health))
	# Heavy swing.
	_target.position = Vector3(0.0, 0.0, -1.2)
	_reset()
	await _settle(2)
	await _ready_up()
	await _aim_at(_chest_of(_target))
	var h2 := _target.health
	_check(_weapon.melee_heavy(), "heavy swing fires")
	await _settle(1)
	_check(_about(h2 - _target.health, 78.0), "heavy swing uses damage_heavy",
		str(h2 - _target.health))
	# Facing away: back_mult 2.4 turns the light swing lethal.
	_target.rotation.y = 0.0
	_reset()
	await _settle(2)
	await _ready_up()
	await _aim_at(_chest_of(_target))
	_weapon.try_fire()
	await _settle(1)
	_check(not _target.alive, "backstab (42 x 2.4) kills", str(_target.health))


## Pooled nodes are renamed to @Node3D@NN when a sibling already owns their
## name, so they are counted by type, not by name.
func _test_shotgun_pellets() -> void:
	print("[ts_weapon] shotgun pellets")
	_target.position = Vector3(0.0, 0.0, -4.0)
	_target.rotation.y = PI
	_reset()
	await _settle(2)
	await _equip("breacher12")
	await _recover()
	await _aim_at(_chest_of(_target))
	var before := _target.health
	_weapon.try_fire()
	await _settle(1)
	var dmg := before - _target.health
	# 9 pellets x 24 point blank; some of the cone misses a 0.6 x 0.7 chest, so
	# only "several pellets connected" is asserted.
	_check(dmg > 24.0 * 2.0, "several pellets of one shell connect", str(dmg))
	_check(_hits >= 3, "one hit_confirmed per connecting pellet", str(_hits))
	_check(_count_tracers() <= 2, "at most 2 tracers per shell", str(_count_tracers()))
	_target.position = Vector3(0.0, 0.0, NEAR_Z)
	await _settle(2)


func _test_burst_and_dryfire() -> void:
	print("[ts_weapon] burst mode + dry fire")
	_reset()
	await _equip("snub")               # burst_count 3, burst_rate 12
	await _recover()
	await _aim_at(_chest_of(_target))
	var mag0 := _shooter.get_mag("snub")
	_weapon.set_trigger(true)
	await _settle(24)                  # 3 shots take 0.17 s; the trigger stays held
	var spent := mag0 - _shooter.get_mag("snub")
	_check(spent == 3, "one pull fires exactly burst_count shots", str(spent))
	await _settle(20)
	_check(mag0 - _shooter.get_mag("snub") == 3, "held trigger does not restart the burst",
		str(mag0 - _shooter.get_mag("snub")))
	_weapon.set_trigger(false)

	await _equip("ar77")
	await _recover()
	_shooter.set_ammo("ar77", 1, 30)
	_weapon.set_trigger(true)
	await _settle(20)
	_weapon.set_trigger(false)
	_check(_shooter.get_mag("ar77") == 0, "last round leaves the mag",
		str(_shooter.get_mag("ar77")))
	_check(_weapon.is_reloading(), "an empty mag auto-reloads on the next pull")
	for i in 300:
		if not _weapon.is_reloading():
			break
		await get_tree().physics_frame
	# 1 in the mag + 30 spare, one round fired: the whole reserve goes in.
	_check(_shooter.get_mag("ar77") == 30 and _shooter.get_reserve("ar77") == 0,
		"auto reload refills from the reserve",
		"%d/%d" % [_shooter.get_mag("ar77"), _shooter.get_reserve("ar77")])


## The player binds weapons by duck-typing (src/characters/player.gd), so the
## real scene is exercised here rather than trusting the signature by eye.
func _test_player_binding() -> void:
	print("[ts_weapon] player.tscn integration")
	if not ResourceLoader.exists("res://scenes/characters/player.tscn"):
		print("  SKIP  player.tscn not present")
		return
	var packed: PackedScene = load("res://scenes/characters/player.tscn")
	var player := packed.instantiate() as CharacterBase
	player.position = Vector3(3.0, 0.05, 0.0)
	add_child(player)
	player.player_id = 21
	player.team = 0
	await _settle(2)
	player.give_weapon("ar77")
	await _settle(4)
	var pw: Weapon = null
	if player.has_method("get_weapon_node"):
		pw = player.get_weapon_node() as Weapon
	_check(pw != null, "player built a Weapon node", str(pw))
	if pw == null:
		player.queue_free()
		return
	_check(pw.weapon_id == "ar77", "player called setup() with the weapon id", pw.weapon_id)
	_check(pw.owner_char == player, "setup() bound the owner")
	_check(pw.aim_source == player.get_camera(), "setup() bound the camera as aim source")
	_check(not pw.apply_recoil_to_aim,
		"recoil is not double-applied for the player camera")
	# Full input path: InputHub -> player -> Weapon.set_trigger -> shots.
	for i in 90:
		if not pw.is_drawing():
			break
		await get_tree().physics_frame
	var mag0 := player.get_mag("ar77")
	InputHub.fire_held = true
	await _settle(40)
	InputHub.fire_held = false
	var spent := mag0 - player.get_mag("ar77")
	_check(spent >= 4, "holding InputHub.fire_held sprays through the player", str(spent))
	_check(player.get_spread_deg() > 0.0, "player.get_spread_deg() reads the weapon",
		str(player.get_spread_deg()))
	InputHub.reset()
	player.queue_free()
	await _settle(2)


func _count_tracers() -> int:
	var n := 0
	for c in get_children():
		if c is BulletTracer:
			n += 1
	return n


func _count_impacts() -> int:
	var n := 0
	for c in get_children():
		if c is BulletImpact:
			n += 1
	return n
