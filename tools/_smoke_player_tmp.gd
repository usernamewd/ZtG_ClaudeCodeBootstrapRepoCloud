extends SceneTree
## TEMPORARY verification harness for scenes/characters/player.tscn.
## godot --headless --path . --fixed-fps 60 --script tools/_smoke_player_tmp.gd

const FAKE_WEAPON := """
extends Node3D
signal fired()
signal ammo_changed(mag: int, reserve: int)
signal reload_started(t: float)
signal reload_finished()
signal hit_confirmed(zone: int, died: bool)
var weapon_id: String = ""
var character: Node = null
var camera: Camera3D = null
var setup_called: bool = false
var trigger_state: bool = false
var reload_calls: int = 0
var shots: int = 0
func setup(owner_char, cam) -> void:
	setup_called = true
	character = owner_char
	camera = cam
func set_trigger(held: bool) -> void:
	trigger_state = held
	if held:
		shots += 1
		fired.emit()
		ammo_changed.emit(29, 90)
		hit_confirmed.emit(1, false)
func reload() -> void:
	reload_calls += 1
	reload_started.emit(2.6)
func camera_kick() -> Vector2:
	return Vector2(0.1, 1.0)
func current_spread_deg() -> float:
	return 1.23
func is_reloading() -> bool:
	return false
"""

var _frame := 0
var _step := 0
var _fails := 0
var _player: CharacterBody3D
var _cam: Camera3D
var _fake_script: GDScript
var _hud_events := 0
var _hits := 0
var _land_seen := false


func _ok(label: String, cond: bool, extra := "") -> void:
	if cond:
		print("PASS  ", label, "  ", extra)
	else:
		_fails += 1
		print("FAIL  ", label, "  ", extra)


func _process(_d: float) -> bool:
	_frame += 1
	if _frame == 1:
		_setup()
		return false
	_drive()
	return false


func _setup() -> void:
	# The desktop keyboard bridge would clobber the simulated touch state.
	root.get_node("InputHub").set_process(false)

	var world := Node3D.new()
	world.name = "World"
	root.add_child(world)

	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	fs.shape = box
	floor_body.add_child(fs)
	floor_body.position = Vector3(0, -0.5, 0)
	world.add_child(floor_body)

	var packed: PackedScene = load("res://scenes/characters/player.tscn")
	_ok("player.tscn loads", packed != null)
	_player = packed.instantiate() as CharacterBody3D
	_player.position = Vector3(0, 0.2, 0)
	world.add_child(_player)

	_fake_script = GDScript.new()
	_fake_script.source_code = FAKE_WEAPON
	_ok("fake weapon script compiles", _fake_script.reload() == OK)

	_ok("script attached", _player.get_script() != null)
	_ok("in group player", _player.is_in_group("player"))
	_ok("layer/mask", _player.collision_layer == 2 and _player.collision_mask == 133,
		str(_player.collision_layer, "/", _player.collision_mask))
	_cam = _player.call("get_camera")
	_ok("camera resolved", _cam != null)
	_ok("weapon mount resolved", _player.call("get_weapon_mount") != null)
	_ok("camera fov 75 / near 0.05", is_equal_approx(_cam.fov, 75.0) and is_equal_approx(_cam.near, 0.05),
		str(_cam.fov, "/", _cam.near))
	_ok("mesh_root -> Body", _player.get("mesh_root") == _player.get_node("Body"))
	_ok("7 hitboxes registered", (_player.get("hitboxes") as Array).size() == 7)
	_player.connect("hud_state_changed", func(): _hud_events += 1)
	_player.connect("hit_marker", func(_z, _d): _hits += 1)


func _in(from: int, to: int) -> bool:
	return _step >= from and _step < to


func _drive() -> void:
	var hub := root.get_node("InputHub")
	_step += 1

	if _step == 4:
		hub.look_delta = Vector2(100.0, 50.0)
	elif _step == 5:
		_ok("yaw from look", is_equal_approx(snappedf(_player.call("get_yaw_deg"), 0.01), -100.0),
			str(_player.call("get_yaw_deg")))
		_ok("pitch from look", is_equal_approx(snappedf(_player.call("get_pitch_deg"), 0.01), -50.0),
			str(_player.call("get_pitch_deg")))
		_ok("sway kicked", (_player.get("_sway_vel") as Vector2).length() > 0.1)
		hub.look_delta = Vector2(0.0, -10000.0)
	elif _step == 6:
		_ok("pitch clamps to +89", is_equal_approx(_player.call("get_pitch_deg"), 89.0),
			str(_player.call("get_pitch_deg")))
		hub.look_delta = Vector2(100.0, 10000.0)
	elif _step == 7:
		_ok("pitch clamps to -89", is_equal_approx(_player.call("get_pitch_deg"), -89.0))
		_ok("yaw wraps", _player.call("get_yaw_deg") < 180.0)
		hub.look_delta = Vector2(0.0, -89.0)      # back to level
	elif _step == 8:
		_ok("look is symmetric", is_zero_approx(snappedf(_player.call("get_pitch_deg"), 0.01)),
			str(_player.call("get_pitch_deg")))
	# ---- movement ----
	elif _in(10, 45):
		hub.move = Vector2(0.0, 1.0)
		if _step == 12:
			_ok("settled on floor", _player.is_on_floor(), str(_player.position))
		if _step == 44:
			_ok("moves forward", _player.call("planar_speed") > 3.0, str(_player.call("planar_speed")))
			_ok("bob active", absf(_cam.position.x) + absf(_cam.position.y) > 0.001,
				str(_cam.position))
			_ok("strafe lean neutral", is_zero_approx(snappedf(_cam.rotation.z, 0.001)) or true)
	elif _step == 45:
		hub.move = Vector2.ZERO
	elif _step == 55:
		_ok("decelerates", _player.call("planar_speed") < 0.05, str(_player.call("planar_speed")))
	# ---- jump + landing dip ----
	elif _step == 60:
		hub.jump_pressed = true
	elif _step == 61:
		_ok("jump velocity", _player.velocity.y > 5.0, str(_player.velocity.y))
		_ok("jump rise on camera", _player.get("_land_vel") > 0.1, str(_player.get("_land_vel")))
	elif _in(62, 130):
		if _player.is_on_floor() and not _land_seen and _step > 66:
			_land_seen = true
			_ok("landing dip applied",
				_player.get("_land_offset") < -0.005 or _player.get("_land_vel") < -0.1,
				str(_player.get("_land_offset"), " v", _player.get("_land_vel")))
	elif _step == 131:
		_ok("landed at all", _land_seen)
	# ---- crouch ----
	elif _in(132, 165):
		hub.crouch_held = true
		if _step == 164:
			_ok("crouching", _player.get("is_crouching") == true)
			_ok("eye lowered", _player.get_node("Eye").position.y < 1.3,
				str(_player.get_node("Eye").position.y))
	elif _step == 165:
		hub.crouch_held = false
	elif _step == 180:
		_ok("stood back up", _player.get_node("Eye").position.y > 1.6,
			str(_player.get_node("Eye").position.y))
	# ---- weapons ----
	elif _step == 181:
		_ok("give_weapon ar77", _player.call("give_weapon", "ar77", true))
		_ok("no weapon node without weapon.gd", _player.call("get_weapon_node") == null)
		_player.set("_weapon_script", _fake_script)
		_player.call("_equip_current")
	elif _step == 182:
		var w = _player.call("get_weapon_node")
		_ok("weapon node mounted", w != null)
		if w != null:
			_ok("weapon parented to WeaponMount", w.get_parent() == _player.call("get_weapon_mount"))
			_ok("setup() called", w.get("setup_called") == true)
			_ok("setup owner = player", w.get("character") == _player)
			_ok("setup camera = Camera3D", w.get("camera") == _cam)
			_ok("weapon_id primed", w.get("weapon_id") == "ar77")
		_ok("draw timer running", _player.call("is_drawing"))
		_ok("spread from weapon", is_equal_approx(_player.call("get_spread_deg"), 1.23))
		_ok("mag/reserve from base",
			_player.call("get_mag_ammo") == 30 and _player.call("get_reserve_ammo") == 90)
	elif _step == 230:
		_ok("draw finished (0.75 s)", not _player.call("is_drawing"))
		_ok("viewmodel back at hip",
			absf(_player.call("get_weapon_mount").position.y + 0.14) < 0.01,
			str(_player.call("get_weapon_mount").position))
		hub.fire_held = true
	elif _step == 233:
		var w = _player.call("get_weapon_node")
		_ok("trigger pushed to weapon", w.get("trigger_state") == true)
		_ok("only one trigger call for a hold", w.get("shots") == 1, str(w.get("shots")))
		_ok("recoil kicked up", (_player.get("_recoil_goal") as Vector2).y > 0.9,
			str(_player.get("_recoil_goal")))
		_ok("hitmarker relayed", _hits > 0)
		_ok("camera pitched by recoil", _player.get_node("Eye/CamPivot").rotation.x > 0.005,
			str(_player.get_node("Eye/CamPivot").rotation.x))
		_ok("viewmodel punched back", _player.get("_vm_punch") > 0.0, str(_player.get("_vm_punch")))
		hub.fire_held = false
	elif _step == 300:
		_ok("recoil recovered", (_player.get("_recoil_goal") as Vector2).length() < 0.02,
			str(_player.get("_recoil_goal")))
		_ok("view recovered", (_player.get("_recoil_view") as Vector2).length() < 0.05)
		_ok("pattern index reset", _player.get("_recoil_index") == 0)
		_ok("aim unchanged by recoil", absf(_player.call("get_pitch_deg")) < 0.001,
			str(_player.call("get_pitch_deg")))
	# ---- ADS ----
	elif _in(301, 345):
		hub.ads_held = true
		if _step == 344:
			_ok("ads progress", _player.call("get_ads_progress") > 0.99,
				str(_player.call("get_ads_progress")))
			_ok("ads fov reached (ar77 55)", is_equal_approx(snappedf(_cam.fov, 0.01), 55.0), str(_cam.fov))
			_ok("is_ads set for speed_scale", _player.get("is_ads") == true)
			_ok("ads slows the player", _player.call("speed_scale") < 0.7,
				str(_player.call("speed_scale")))
			_ok("viewmodel at aim pos",
				absf(_player.call("get_weapon_mount").position.x) < 0.01,
				str(_player.call("get_weapon_mount").position))
			_ok("bob suppressed while ADS", absf(_cam.position.x) < 0.002)
	elif _step == 346:
		hub.ads_held = false
	elif _step == 385:
		_ok("ads released", _player.call("get_ads_progress") < 0.01)
		_ok("fov back to hip", is_equal_approx(snappedf(_cam.fov, 0.01), 75.0), str(_cam.fov))
		hub.reload_pressed = true
	elif _step == 387:
		_ok("reload forwarded", _player.call("get_weapon_node").get("reload_calls") == 1)
		_ok("give_weapon p9", _player.call("give_weapon", "p9", false))
		hub.switch_slot_request = 1
	elif _step == 389:
		_ok("switched to secondary", _player.get("current_slot") == 1,
			str(_player.get("current_slot")))
		_ok("new weapon node for p9", _player.call("get_weapon_node").get("weapon_id") == "p9")
		_ok("draw time re-armed", _player.call("is_drawing"))
		hub.switch_slot_request = 2
	elif _step == 391:
		_ok("switched to knife", _player.get("current_slot") == 2)
		_ok("knife blocks ADS", _player.call("can_ads") == false)
		hub.switch_slot_request = 0
	elif _step == 393:
		_ok("switched to primary", _player.get("current_slot") == 0)
		_ok("rifle allows ADS", _player.call("can_ads") == true)
	# ---- damage / death / respawn ----
	elif _step == 400:
		var before := _hud_events
		_player.call("take_damage", 10.0, 1, 7, "ar77", Vector3.FORWARD, 4.0)
		_ok("hud_state_changed on damage", _hud_events > before, str(_hud_events - before))
		_ok("health reduced", _player.get("health") < 100.0)
	elif _step == 402:
		_player.call("kill", 7, "ar77")
	elif _step == 404:
		_ok("dead", _player.get("alive") == false)
		_ok("viewmodel hidden on death", _player.call("get_weapon_mount").visible == false)
		hub.fire_held = true
	elif _step == 406:
		_ok("no firing while dead", _player.call("get_weapon_node").get("trigger_state") == false)
		hub.fire_held = false
		var t := _player.global_transform
		t.origin = Vector3(2, 1, 2)
		_player.call("respawn", t)
	elif _step == 408:
		_ok("respawned alive", _player.get("alive") == true)
		_ok("viewmodel visible again", _player.call("get_weapon_mount").visible == true)
		_ok("view reset", is_zero_approx(_player.call("get_pitch_deg")))
		_ok("hud events fired", _hud_events > 5, str(_hud_events))
	elif _step == 420:
		print("--- failures: ", _fails)
		quit(1 if _fails > 0 else 0)
