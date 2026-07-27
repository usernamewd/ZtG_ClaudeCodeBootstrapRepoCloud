extends Node
## TEMPORARY verification harness for the HUD (deleted after the run).

var _hud: CanvasLayer = null
var _fake: FakePlayer = null
var _frames := 0
var _fails: Array[String] = []


class FakeWeapon extends Node3D:
	signal fired(recoil_kick: Vector2)
	signal ammo_changed(mag: int, reserve: int)
	signal reload_started(duration: float)
	signal reload_finished()
	signal hit_confirmed(zone: int, died: bool)
	var spread := 1.2
	func current_spread_deg() -> float:
		return spread
	func is_reloading() -> bool:
		return false
	func get_mag_size() -> int:
		return 30
	func is_melee() -> bool:
		return false


class FakePlayer extends Node3D:
	signal hud_state_changed()
	signal weapon_equipped(weapon: Node3D, weapon_id: String)
	signal hit_marker(zone: int, died: bool)
	signal damaged(amount: float, zone: int, attacker_id: int)
	signal died(attacker_id: int, weapon_id: String, headshot: bool)
	signal respawned()

	var last_damage_dir := Vector3.ZERO
	var current_slot := 0
	var health := 63.0
	var armor := 42.0
	var mag := 7
	var reserve := 90
	var cam: Camera3D = null
	var wpn: FakeWeapon = null
	var def := {"mag": 30, "reserve": 90, "display_name": "AR-77"}

	func get_health() -> float: return health
	func get_max_health() -> float: return 100.0
	func get_armor() -> float: return armor
	func get_helmet() -> bool: return true
	func get_weapon_display_name() -> String: return "AR-77"
	func get_weapon_node() -> Node3D: return wpn
	func get_weapon_id() -> String: return "ar77"
	func get_mag_ammo() -> int: return mag
	func get_reserve_ammo() -> int: return reserve
	func get_grenade_count() -> int: return 2
	func is_reloading() -> bool: return false
	func current_weapon_def() -> Dictionary: return def
	func get_camera() -> Camera3D: return cam


func _ready() -> void:
	Settings.show_fps = true
	Settings.crosshair_dynamic = true
	Settings.crosshair_dot = true
	Settings.hud_scale = 1.0

	var bg := ColorRect.new()
	bg.color = Color(0.28, 0.30, 0.33)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var band := ColorRect.new()
	band.color = Color(0.10, 0.11, 0.12)
	band.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	band.anchor_top = 0.5
	add_child(band)

	_fake = FakePlayer.new()
	_fake.cam = Camera3D.new()
	_fake.add_child(_fake.cam)
	_fake.wpn = FakeWeapon.new()
	_fake.add_child(_fake.wpn)
	add_child(_fake)

	var packed: PackedScene = load("res://scenes/ui/hud.tscn")
	_hud = packed.instantiate()
	add_child(_hud)
	_hud.bind_player(_fake)

	_check(_hud.get_node_or_null("Root/Widgets/Vitals") != null, "vitals built")
	_check(_hud.get_node_or_null("Root/Widgets/Ammo") != null, "ammo built")
	_check(_hud.get_node_or_null("Root/Widgets/Fps") != null, "fps built")
	_check(_hud.get_node_or_null("Root/TouchControls") != null, "touch instanced")
	_check(_hud.phase4_slot("Radar") != null, "phase4 slot Radar")
	_check(_hud.phase4_slot("KillFeed") != null, "phase4 slot KillFeed")
	_check(_hud.crosshair() != null, "crosshair accessor")
	_check(_hud.touch_controls() != null, "touch accessor")

	var movable := get_tree().get_nodes_in_group("hud_movable")
	var ids: Array[String] = []
	for n in movable:
		ids.append(String(n.get_meta("hud_id", "")))
	_check(ids.has("vitals") and ids.has("ammo") and ids.has("fps"),
		"hud_movable ids present: " + str(ids))

	var vit: Control = _hud.get_node("Root/Widgets/Vitals")
	var amm: Control = _hud.get_node("Root/Widgets/Ammo")
	_check(vit.position.x > 0.0 and vit.position.y > 300.0,
		"vitals bottom-left at " + str(vit.position))
	_check(amm.position.x > 800.0 and amm.position.y > 300.0,
		"ammo bottom-right at " + str(amm.position))

	# Exercise every signal path.
	_fake.hit_marker.emit(0, false)
	_fake.hit_marker.emit(1, true)
	_fake.last_damage_dir = Vector3(1, 0, 0)
	_fake.damaged.emit(34.0, 1, 3)
	_fake.last_damage_dir = Vector3(0, 0, 1)
	_fake.damaged.emit(12.0, 3, 4)
	_fake.last_damage_dir = Vector3(-0.7, 0, -0.7)
	_fake.damaged.emit(58.0, 0, 5)
	_fake.wpn.reload_started.emit(2.4)
	_fake.wpn.ammo_changed.emit(4, 86)
	_fake.health = 63.0
	_fake.hud_state_changed.emit()

	# Layout persistence round trip.
	Settings.hud_layout["fps"] = {"off": [0.0, 140.0], "scale": 1.2}
	_hud._relayout()
	var fps_w: Control = _hud.get_node("Root/Widgets/Fps")
	_check(is_equal_approx(fps_w.size.x, roundf(146.0 * 1.2)),
		"stored scale applied: " + str(fps_w.size))
	Settings.hud_layout.erase("fps")
	_hud._relayout()


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		_fails.append(what)
		printerr("  FAIL ", what)


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 20:
		_fake.mag = 3
		_fake.health = 18.0
		_fake.armor = 0.0
		_fake.hud_state_changed.emit()
		_fake.wpn.spread = 4.5
	if _frames == 40:
		var img := get_viewport().get_texture().get_image()
		img.save_png("user://hud_smoke.png")
		print("[hud_smoke] saved ", ProjectSettings.globalize_path("user://hud_smoke.png"))
		# knife mode
		_fake.def = {"display_name": "Knife"}
		_fake.hud_state_changed.emit()
	if _frames == 50:
		_fake.def = {"mag": 30, "reserve": 90}
		_fake.current_slot = 3
		_fake.hud_state_changed.emit()
	if _frames >= 60:
		if _fails.is_empty():
			print("[hud_smoke] ALL OK")
			get_tree().quit(0)
		else:
			printerr("[hud_smoke] FAILURES: ", _fails.size())
			get_tree().quit(1)
