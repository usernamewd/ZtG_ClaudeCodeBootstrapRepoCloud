class_name CharacterBase
extends CharacterBody3D
## Shared body for the local player, bots and the shooting-range dummy.
## Owns health/armour, the damage model, the inventory + ammo pools, the
## locomotion helper and the hitbox registry. Subclasses only decide *intent*
## (which direction to move, when to shoot) and call move_locomotion() once per
## physics tick. See docs/ARCHITECTURE.md "Characters".
##
## Well-known child nodes (all optional, overridable through the exported
## NodePaths):
##   Eye        Node3D  — aim/camera origin, y is driven by the crouch blend.
##                        Bots and Weapon rays fire from here.
##   BodyShape  CollisionShape3D with a CapsuleShape3D — the movement capsule,
##                        its height is driven by the crouch blend.
##   Hitboxes   Node3D  — parent of the StaticBody3D hitboxes (Phase 1 fixed
##                        shapes, Phase 2 BoneAttachment3D children). Any
##                        StaticBody3D in group "hitbox" anywhere below the
##                        character is picked up, at any depth.
##   Mesh       Node3D  — visual root, hidden while dead.

signal damaged(amount: float, zone: int, attacker_id: int)
signal died(attacker_id: int, weapon_id: String, headshot: bool)
## Not in the contract; convenience for HUD/bots so they do not poll.
signal health_changed(health: float, armor: float)
signal weapon_changed(slot: int, weapon_id: String)
signal inventory_changed()
signal respawned()

enum Zone { HEAD, CHEST, STOMACH, LIMB }
enum Slot { PRIMARY, SECONDARY, KNIFE, GRENADE }

# Movement (docs/ARCHITECTURE.md). All speeds are further scaled by
# speed_scale(); SPEED_RUN is the reference for that scale.
const SPEED_RUN := 5.2
const SPEED_WALK_ADS := 3.4
const SPEED_CROUCH := 2.4
const JUMP_VELOCITY := 5.4
const ACCEL_GROUND := 60.0
const ACCEL_AIR := 12.0
const DECEL := 55.0
const TERMINAL_FALL := 60.0
static var GRAVITY: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 16.0))

# Body metrics, metres. A standing operator is 1.8 m tall.
const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.25
const BODY_RADIUS := 0.35
const EYE_STAND := 1.65
const EYE_CROUCH := 1.1
const CROUCH_BLEND_SPEED := 7.0     # 0->1 crouch blend units per second

# Damage model.
const ZONE_MULT_CHEST := 1.0
const ZONE_MULT_STOMACH := 1.25
const ZONE_MULT_LIMB := 0.75
const HELMET_HEAD_MULT := 0.5       # scales headshot_mult while a helmet is worn
const ARMOR_ABSORB := 0.5           # fraction of body damage the vest soaks
const ARMOR_DURABILITY_LOSS := 0.5  # armour points burned per damage point soaked
const ARMOR_MAX := 100.0

# Physics layer bits (project.godot layer_names).
const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_BOT := 4
const LAYER_HITBOX := 8
const LAYER_CLIP := 128
const MASK_STAND_BLOCKERS := LAYER_WORLD | LAYER_CLIP

const MAX_GRENADES := 4
const KNIFE_ID := "knife"
## Draw order used by switch_to_best(); const so no array is built at runtime.
const GUN_SLOTS: Array[int] = [Slot.PRIMARY, Slot.SECONDARY, Slot.KNIFE]
const WEAPON_DB_PATH := "res://src/data/weapon_db.gd"

## WeaponDB.Cat, mirrored so this file parses before src/data/weapon_db.gd
## exists. The real enum is read out of the script when it is available.
const CAT_FALLBACK := {
	"PISTOL": 0, "SMG": 1, "RIFLE": 2, "HEAVY": 3,
	"KNIFE": 4, "GRENADE": 5, "GEAR": 6,
}
## Returned by _slot_for() for equipment, which lives outside the four slots.
const SLOT_GEAR := -1
const GEAR_ARMOR := "armor"
const GEAR_HELMET := "helmet"
const GEAR_DEFUSE_KIT := "defusekit"

static var _wdb = null
static var _wdb_resolved := false
static var _cat: Dictionary = CAT_FALLBACK

@export var team: int = -1              # GameState.Team.ATK / DEF, -1 unassigned
@export var player_id: int = -1
@export var max_health: float = 100.0
@export var health: float = 100.0
@export var armor: float = 0.0
@export var has_helmet: bool = false
@export var has_defuse_kit: bool = false
@export var eye_path: NodePath = ^"Eye"
@export var body_shape_path: NodePath = ^"BodyShape"
@export var mesh_root_path: NodePath = ^"Mesh"

var alive: bool = true
var is_crouching: bool = false
var is_ads: bool = false
var last_damage_dir: Vector3 = Vector3.ZERO   # world dir the last hit travelled in

## [primary_id, secondary_id, "knife", Array grenade_ids]
var slots: Array = ["", "", KNIFE_ID, []]
## weapon_id -> {"mag": int, "reserve": int}
var ammo: Dictionary = {}
var current_slot: int = Slot.KNIFE
var current_grenade: int = 0            # index into slots[Slot.GRENADE]

var eye: Node3D = null
var mesh_root: Node3D = null
var hitboxes: Array[StaticBody3D] = []

var _body_shape: CollisionShape3D = null
var _capsule: CapsuleShape3D = null
var _stand_probe: ShapeCast3D = null
var _crouch_blend: float = 0.0          # 0 standing .. 1 crouched
var _applied_blend: float = -1.0
var _hitboxes_enabled: bool = true
var _body_layer: int = 0
var _body_mask: int = 0
var _current_def: Dictionary = {}
var _weapon_move_mult: float = 1.0


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	up_direction = Vector3.UP
	floor_stop_on_slope = true
	floor_constant_speed = true
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.35
	slide_on_ceiling = true
	_body_layer = collision_layer
	_body_mask = collision_mask
	_resolve_nodes()
	_build_stand_probe()
	register_hitboxes()
	_refresh_weapon_cache()
	_apply_crouch_blend(true)


func _notification(what: int) -> void:
	# The hitbox -> character NodePath meta is absolute, so it has to be
	# re-stamped whenever this character moves in the tree.
	if what == NOTIFICATION_PATH_RENAMED and is_inside_tree() and not hitboxes.is_empty():
		_stamp_hitboxes()


func _resolve_nodes() -> void:
	eye = get_node_or_null(eye_path) as Node3D
	if eye == null:
		eye = get_node_or_null(^"Eye") as Node3D
	if eye == null:
		eye = Node3D.new()
		eye.name = "Eye"
		add_child(eye)
	mesh_root = get_node_or_null(mesh_root_path) as Node3D
	_body_shape = get_node_or_null(body_shape_path) as CollisionShape3D
	if _body_shape == null:
		for c in get_children():
			if c is CollisionShape3D:
				_body_shape = c
				break
	if _body_shape != null and _body_shape.shape is CapsuleShape3D:
		# Unique per instance: the crouch blend writes into it every tick.
		_capsule = (_body_shape.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
		_body_shape.shape = _capsule


## Overlap probe for the volume between the crouched and standing capsule tops.
## Built in code so every character scene gets it without authoring it.
func _build_stand_probe() -> void:
	var r := BODY_RADIUS
	if _capsule != null:
		r = _capsule.radius
	r = maxf(r * 0.95, 0.05)
	var sphere := SphereShape3D.new()
	sphere.radius = r
	_stand_probe = ShapeCast3D.new()
	_stand_probe.name = "StandProbe"
	_stand_probe.shape = sphere
	_stand_probe.enabled = false            # queried manually, never per frame
	_stand_probe.collide_with_areas = false
	_stand_probe.collide_with_bodies = true
	_stand_probe.collision_mask = MASK_STAND_BLOCKERS
	_stand_probe.max_results = 1
	_stand_probe.position = Vector3(0.0, CROUCH_HEIGHT - r, 0.0)
	_stand_probe.target_position = Vector3(0.0, STAND_HEIGHT - CROUCH_HEIGHT, 0.0)
	add_child(_stand_probe)
	_stand_probe.add_exception(self)


# ---------------------------------------------------------------- locomotion

## Main locomotion entry point. `wish_local` matches InputHub.move
## (x = strafe right, y = forward), length <= 1 and used as an analog throttle.
func move_locomotion(delta: float, wish_local: Vector2, want_jump: bool, want_crouch: bool) -> void:
	var b := global_basis
	var wish := b.x * wish_local.x - b.z * wish_local.y
	move_locomotion_world(delta, wish, want_jump, want_crouch)


## Same, with an already world-space direction (bots feed navigation output).
func move_locomotion_world(delta: float, wish_world: Vector3, want_jump: bool, want_crouch: bool) -> void:
	_update_crouch(delta, want_crouch)

	var grounded := is_on_floor()
	if grounded:
		if velocity.y < 0.0:
			velocity.y = 0.0
		if want_jump:
			velocity.y = JUMP_VELOCITY
			grounded = false
	else:
		velocity.y = maxf(velocity.y - GRAVITY * delta, -TERMINAL_FALL)

	var wish := wish_world
	wish.y = 0.0
	var throttle := wish.length()
	if throttle > 1.0:
		wish /= throttle
		throttle = 1.0

	var hvel := Vector3(velocity.x, 0.0, velocity.z)
	if throttle > 0.001:
		var target := wish * (SPEED_RUN * speed_scale())
		hvel = hvel.move_toward(target, (ACCEL_GROUND if grounded else ACCEL_AIR) * delta)
	elif grounded:
		hvel = hvel.move_toward(Vector3.ZERO, DECEL * delta)
	velocity.x = hvel.x
	velocity.z = hvel.z

	move_and_slide()


## Multiplier on SPEED_RUN: current weapon, crouch and ADS combined.
func speed_scale() -> float:
	var s := _weapon_move_mult
	if is_crouching:
		s *= SPEED_CROUCH / SPEED_RUN
	elif is_ads:
		s *= SPEED_WALK_ADS / SPEED_RUN
	return s


func current_speed() -> float:
	return SPEED_RUN * speed_scale()


## Horizontal speed, for spread/footstep code.
func planar_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func _update_crouch(delta: float, want_crouch: bool) -> void:
	var crouch := want_crouch
	# Also re-checked mid stand-up blend, so a ceiling appearing while rising
	# (a closing door, a moving player) pushes the character back down.
	if not crouch and _crouch_blend > 0.0 and _stand_blocked():
		crouch = true
	is_crouching = crouch
	var goal := 1.0 if crouch else 0.0
	if not is_equal_approx(_crouch_blend, goal):
		_crouch_blend = move_toward(_crouch_blend, goal, CROUCH_BLEND_SPEED * delta)
		_apply_crouch_blend(false)


func _apply_crouch_blend(force: bool) -> void:
	if not force and is_equal_approx(_applied_blend, _crouch_blend):
		return
	_applied_blend = _crouch_blend
	var h: float = lerpf(STAND_HEIGHT, CROUCH_HEIGHT, _crouch_blend)
	if _capsule != null:
		_capsule.height = maxf(h, _capsule.radius * 2.0)
		_body_shape.position.y = h * 0.5
	if eye != null:
		eye.position.y = lerpf(EYE_STAND, EYE_CROUCH, _crouch_blend)


## True when something occupies the head-room needed to stand back up.
func _stand_blocked() -> bool:
	if _stand_probe == null:
		return false
	_stand_probe.force_shapecast_update()
	return _stand_probe.is_colliding()


# -------------------------------------------------------------------- damage

func take_damage(raw: float, zone: int, attacker_id: int, weapon_id: String,
		dir: Vector3, headshot_mult := 4.0) -> void:
	if not alive or raw <= 0.0:
		return
	last_damage_dir = dir
	var headshot := zone == Zone.HEAD
	var dmg := raw
	if headshot:
		var m := headshot_mult
		if has_helmet:
			m *= HELMET_HEAD_MULT
		dmg *= m
		if has_helmet and armor > 0.0:
			dmg = _absorb_with_armor(dmg)
	else:
		match zone:
			Zone.STOMACH:
				dmg *= ZONE_MULT_STOMACH
			Zone.LIMB:
				dmg *= ZONE_MULT_LIMB
			_:
				dmg *= ZONE_MULT_CHEST
		if armor > 0.0:
			dmg = _absorb_with_armor(dmg)

	health = maxf(health - dmg, 0.0)
	damaged.emit(dmg, zone, attacker_id)
	health_changed.emit(health, armor)
	if health <= 0.0:
		_die(attacker_id, weapon_id, headshot)


## Soaks ARMOR_ABSORB of the incoming damage while durability lasts, burning
## armour as it goes. A vest that runs out mid-hit only covers what it can pay
## for. Returns the damage that reaches health.
func _absorb_with_armor(dmg: float) -> float:
	var absorbed := dmg * ARMOR_ABSORB
	var cost := absorbed * ARMOR_DURABILITY_LOSS
	if cost > armor:
		absorbed = armor / ARMOR_DURABILITY_LOSS
		cost = armor
	armor = maxf(armor - cost, 0.0)
	return maxf(dmg - absorbed, 0.0)


## Force a death (round end, out of bounds, suicide).
func kill(attacker_id := -1, weapon_id := "") -> void:
	if not alive:
		return
	health = 0.0
	health_changed.emit(health, armor)
	_die(attacker_id, weapon_id, false)


func _die(attacker_id: int, weapon_id: String, headshot: bool) -> void:
	alive = false
	health = 0.0
	velocity = Vector3.ZERO
	is_ads = false
	set_hitboxes_enabled(false)
	died.emit(attacker_id, weapon_id, headshot)
	_on_death(attacker_id, weapon_id, headshot)


## Subclass hook; base implementation intentionally does nothing.
func _on_death(_attacker_id: int, _weapon_id: String, _headshot: bool) -> void:
	pass


func heal(amount: float) -> void:
	if not alive or amount <= 0.0:
		return
	health = minf(health + amount, max_health)
	health_changed.emit(health, armor)


func give_armor(amount := ARMOR_MAX, helmet := false) -> void:
	armor = clampf(maxf(armor, amount), 0.0, ARMOR_MAX)
	if helmet:
		has_helmet = true
	health_changed.emit(health, armor)


## Full reset in place: health, posture, hitboxes, collision. Inventory,
## armour and helmet are deliberately kept (they carry across rounds).
func reset_state() -> void:
	alive = true
	health = max_health
	velocity = Vector3.ZERO
	is_crouching = false
	is_ads = false
	_crouch_blend = 0.0
	_apply_crouch_blend(true)
	set_hitboxes_enabled(true)
	set_body_collision_enabled(true)
	if mesh_root != null:
		mesh_root.visible = true
	health_changed.emit(health, armor)
	respawned.emit()


func respawn(xform: Transform3D) -> void:
	global_transform = xform
	reset_state()


# ------------------------------------------------------------------ hitboxes

## Walks every StaticBody3D in group "hitbox" below this character (Phase 1:
## fixed shapes under Hitboxes; Phase 2: under BoneAttachment3D nodes), forces
## it onto the hitbox layer with no mask and stamps the metadata Weapon rays
## read back: `zone` (int, Zone) and `char` (NodePath to this CharacterBase).
## `char_ref` is stamped too so weapon code can skip the get_node().
## Safe to call again after swapping the character model.
func register_hitboxes() -> void:
	hitboxes.clear()
	_collect_hitboxes(self)
	_stamp_hitboxes()
	set_hitboxes_enabled(_hitboxes_enabled)


func _collect_hitboxes(n: Node) -> void:
	for c in n.get_children():
		if c is StaticBody3D and c.is_in_group("hitbox"):
			hitboxes.append(c)
		if c is CharacterBase:
			continue      # never steal a nested character's hitboxes
		_collect_hitboxes(c)


func _stamp_hitboxes() -> void:
	var path := get_path() if is_inside_tree() else NodePath()
	for hb in hitboxes:
		if not hb.has_meta("zone"):
			hb.set_meta("zone", _zone_from_name(hb.name))
		hb.set_meta("char", path)
		hb.set_meta("char_ref", self)
		hb.collision_layer = LAYER_HITBOX
		hb.collision_mask = 0


func set_hitboxes_enabled(b: bool) -> void:
	_hitboxes_enabled = b
	var layer := LAYER_HITBOX if b else 0
	for hb in hitboxes:
		hb.collision_layer = layer


func set_body_collision_enabled(b: bool) -> void:
	collision_layer = _body_layer if b else 0
	collision_mask = _body_mask if b else 0


static func _zone_from_name(n: String) -> int:
	var s := n.to_lower()
	if s.begins_with("head"):
		return Zone.HEAD
	if s.begins_with("chest") or s.begins_with("torso") or s.begins_with("upper"):
		return Zone.CHEST
	if s.begins_with("stomach") or s.begins_with("pelvis") or s.begins_with("abdomen"):
		return Zone.STOMACH
	return Zone.LIMB


## Convenience for Weapon: resolve the character a ray hit through a hitbox.
static func from_hitbox(body: Object) -> CharacterBase:
	if body == null or not (body is Node):
		return null
	var n := body as Node
	if n.has_meta("char_ref"):
		var c = n.get_meta("char_ref")
		if is_instance_valid(c) and c is CharacterBase:
			return c
	if n.has_meta("char"):
		return n.get_node_or_null(n.get_meta("char")) as CharacterBase
	return null


## Aim/camera origin. Bots raycast from here; the crouch blend drives its height.
func eye_position() -> Vector3:
	return eye.global_position if eye != null else global_position


# ----------------------------------------------------------------- weapon db

static func _weapon_db():
	if not _wdb_resolved:
		_wdb_resolved = true
		if ResourceLoader.exists(WEAPON_DB_PATH):
			_wdb = load(WEAPON_DB_PATH)
			if _wdb is GDScript:
				var consts: Dictionary = (_wdb as GDScript).get_script_constant_map()
				var c = consts.get("Cat")
				if c is Dictionary and not (c as Dictionary).is_empty():
					_cat = c
	return _wdb


static func weapon_def(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	var db = _weapon_db()
	if db == null:
		return {}
	return db.get_def(id)


static func _cat_id(name: String) -> int:
	return int(_cat.get(name, CAT_FALLBACK.get(name, -1)))


# ----------------------------------------------------------------- inventory

## Adds a weapon (or gear item) and, by default, draws it. Ammo is filled from
## the WeaponDB def. Returns false for unknown ids and for grenades that would
## exceed the per-type `max_carry` or the total MAX_GRENADES.
func give_weapon(id: String, make_current := true) -> bool:
	if id.is_empty():
		return false
	var def := weapon_def(id)
	var slot := _slot_for(id, def)
	if slot == SLOT_GEAR:
		return give_gear(id, def)
	if slot == Slot.GRENADE:
		var nades: Array = slots[Slot.GRENADE]
		if nades.size() >= MAX_GRENADES:
			return false
		var carry := int(def.get("max_carry", MAX_GRENADES))
		if carry > 0 and nades.count(id) >= carry:
			return false
		nades.append(id)
		current_grenade = nades.size() - 1
	else:
		slots[slot] = id
	refill_ammo(id)
	inventory_changed.emit()
	if make_current and switch_slot(slot):
		return true
	if slot == current_slot:
		# Replaced the weapon we are already holding: re-announce it so the
		# viewmodel and HUD swap over.
		_refresh_weapon_cache()
		weapon_changed.emit(current_slot, current_weapon_id())
	return true


## Equips a GEAR item. Driven by the def when WeaponDB has one
## (`armor_points`, `grants_helmet`), by the id otherwise.
func give_gear(id: String, def := {}) -> bool:
	if def.is_empty():
		def = weapon_def(id)
	var applied := false
	var points := float(def.get("armor_points", 0.0))
	if points > 0.0:
		give_armor(points, false)
		applied = true
	if bool(def.get("grants_helmet", false)):
		has_helmet = true
		applied = true
	match id:
		GEAR_ARMOR:
			if not applied:
				give_armor(ARMOR_MAX, false)
				applied = true
		GEAR_HELMET:
			if not applied:
				has_helmet = true
				applied = true
		GEAR_DEFUSE_KIT:
			has_defuse_kit = true
			applied = true
	if not applied:
		return false
	health_changed.emit(health, armor)
	inventory_changed.emit()
	return true


func _is_gear_id(id: String) -> bool:
	return id == GEAR_ARMOR or id == GEAR_HELMET or id == GEAR_DEFUSE_KIT


## Resolves the inventory slot for an id, or SLOT_GEAR for equipment.
## WeaponDB defs carry an explicit `slot` (its Slot enum shares our 0..3 values
## and adds GEAR above them); category and then the raw id are the fallbacks.
func _slot_for(id: String, def: Dictionary) -> int:
	if def.has("slot"):
		var s := int(def["slot"])
		return s if s >= 0 and s <= Slot.GRENADE else SLOT_GEAR
	var cat := int(def.get("category", -1))
	if cat >= 0:
		if cat == _cat_id("GEAR"):
			return SLOT_GEAR
		if cat == _cat_id("KNIFE"):
			return Slot.KNIFE
		if cat == _cat_id("GRENADE"):
			return Slot.GRENADE
		if cat == _cat_id("PISTOL"):
			return Slot.SECONDARY
		return Slot.PRIMARY
	# WeaponDB unavailable (or unknown id): fall back to the id itself.
	if _is_gear_id(id):
		return SLOT_GEAR
	if id == KNIFE_ID:
		return Slot.KNIFE
	if id.begins_with("frag") or id.begins_with("flash") or id.begins_with("smoke") \
			or id.begins_with("incend") or id.begins_with("molo"):
		return Slot.GRENADE
	return Slot.PRIMARY


func remove_weapon(id: String) -> void:
	if id.is_empty():
		return
	var nades: Array = slots[Slot.GRENADE]
	var idx := nades.find(id)
	if idx >= 0:
		nades.remove_at(idx)
		current_grenade = clampi(current_grenade, 0, maxi(nades.size() - 1, 0))
	if slots[Slot.PRIMARY] == id:
		slots[Slot.PRIMARY] = ""
	if slots[Slot.SECONDARY] == id:
		slots[Slot.SECONDARY] = ""
	ammo.erase(id)
	inventory_changed.emit()
	if current_weapon_id().is_empty():
		switch_to_best()


func clear_inventory() -> void:
	slots[Slot.PRIMARY] = ""
	slots[Slot.SECONDARY] = ""
	slots[Slot.KNIFE] = KNIFE_ID
	(slots[Slot.GRENADE] as Array).clear()
	ammo.clear()
	current_grenade = 0
	armor = 0.0
	has_helmet = false
	has_defuse_kit = false
	current_slot = Slot.KNIFE
	_refresh_weapon_cache()
	inventory_changed.emit()
	weapon_changed.emit(current_slot, current_weapon_id())


func has_weapon(id: String) -> bool:
	if id.is_empty():
		return false
	if slots[Slot.PRIMARY] == id or slots[Slot.SECONDARY] == id or slots[Slot.KNIFE] == id:
		return true
	return (slots[Slot.GRENADE] as Array).has(id)


func weapon_in_slot(slot: int) -> String:
	if slot < 0 or slot > Slot.GRENADE:
		return ""
	if slot == Slot.GRENADE:
		var nades: Array = slots[Slot.GRENADE]
		if nades.is_empty():
			return ""
		return nades[clampi(current_grenade, 0, nades.size() - 1)]
	return slots[slot]


func current_weapon_id() -> String:
	return weapon_in_slot(current_slot)


func current_weapon_def() -> Dictionary:
	return _current_def


func has_slot(slot: int) -> bool:
	return not weapon_in_slot(slot).is_empty()


## Draw the given slot. Returns false when the slot is empty or already drawn.
func switch_slot(slot: int) -> bool:
	if slot < 0 or slot > Slot.GRENADE:
		return false
	if not has_slot(slot):
		return false
	if slot == current_slot:
		return false
	current_slot = slot
	_refresh_weapon_cache()
	weapon_changed.emit(current_slot, current_weapon_id())
	return true


## Primary > secondary > knife, used after dropping/throwing the held item.
func switch_to_best() -> void:
	for s in GUN_SLOTS:
		if has_slot(s):
			current_slot = s
			_refresh_weapon_cache()
			weapon_changed.emit(current_slot, current_weapon_id())
			return


## Next grenade in the carried set. Also draws the grenade slot.
func cycle_grenade() -> String:
	var nades: Array = slots[Slot.GRENADE]
	if nades.is_empty():
		return ""
	if current_slot == Slot.GRENADE:
		current_grenade = (current_grenade + 1) % nades.size()
	else:
		current_grenade = clampi(current_grenade, 0, nades.size() - 1)
		current_slot = Slot.GRENADE
	_refresh_weapon_cache()
	weapon_changed.emit(current_slot, current_weapon_id())
	return current_weapon_id()


## Consume the held grenade after a throw and fall back to a gun.
func consume_current_grenade() -> void:
	var nades: Array = slots[Slot.GRENADE]
	if current_slot != Slot.GRENADE or nades.is_empty():
		return
	nades.remove_at(clampi(current_grenade, 0, nades.size() - 1))
	current_grenade = clampi(current_grenade, 0, maxi(nades.size() - 1, 0))
	inventory_changed.emit()
	if nades.is_empty():
		switch_to_best()
	else:
		_refresh_weapon_cache()
		weapon_changed.emit(current_slot, current_weapon_id())


func _refresh_weapon_cache() -> void:
	_current_def = weapon_def(current_weapon_id())
	_weapon_move_mult = float(_current_def.get("move_speed_mult", 1.0))


# --------------------------------------------------------------------- ammo

## Mag + reserve back to the def values. Called on give_weapon and on buy.
func refill_ammo(id: String) -> void:
	if id.is_empty():
		return
	var def := weapon_def(id)
	if def.is_empty():
		return
	if not def.has("mag"):
		return          # knife / gear carry no ammo
	var mag := int(def.get("mag", 0))
	var reserve := int(def.get("reserve", 0))
	if mag <= 0 and reserve <= 0:
		return          # melee: no ammo entry at all, so the HUD can hide it
	var entry = ammo.get(id)
	if entry is Dictionary:
		entry["mag"] = mag
		entry["reserve"] = reserve
	else:
		ammo[id] = {"mag": mag, "reserve": reserve}


func refill_all_ammo() -> void:
	refill_ammo(slots[Slot.PRIMARY])
	refill_ammo(slots[Slot.SECONDARY])
	for id in (slots[Slot.GRENADE] as Array):
		refill_ammo(id)


func get_mag(id: String) -> int:
	var e = ammo.get(id)
	return int(e["mag"]) if e is Dictionary else 0


func get_reserve(id: String) -> int:
	var e = ammo.get(id)
	return int(e["reserve"]) if e is Dictionary else 0


func set_ammo(id: String, mag: int, reserve: int) -> void:
	var e = ammo.get(id)
	if e is Dictionary:
		e["mag"] = maxi(mag, 0)
		e["reserve"] = maxi(reserve, 0)
	else:
		ammo[id] = {"mag": maxi(mag, 0), "reserve": maxi(reserve, 0)}


func add_reserve(id: String, amount: int) -> void:
	var e = ammo.get(id)
	if e is Dictionary:
		e["reserve"] = maxi(int(e["reserve"]) + amount, 0)


## Spend rounds out of the magazine. False when there are not enough.
func consume_ammo(id: String, amount := 1) -> bool:
	var e = ammo.get(id)
	if not (e is Dictionary):
		return false
	var mag := int(e["mag"])
	if mag < amount:
		return false
	e["mag"] = mag - amount
	return true


## Move rounds from the reserve into the magazine. Returns how many moved, so
## the Weapon can decide whether a reload is worth playing.
func pull_from_reserve(id: String) -> int:
	var e = ammo.get(id)
	if not (e is Dictionary):
		return 0
	var def := weapon_def(id)
	var mag_size := int(def.get("mag", int(e["mag"])))
	var want := mag_size - int(e["mag"])
	if want <= 0:
		return 0
	var take: int = mini(want, int(e["reserve"]))
	if take <= 0:
		return 0
	e["mag"] = int(e["mag"]) + take
	e["reserve"] = int(e["reserve"]) - take
	return take
