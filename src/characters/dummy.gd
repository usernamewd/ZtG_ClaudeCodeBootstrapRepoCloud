class_name Dummy
extends CharacterBase
## Phase 1 shooting-range target. No AI: it stands where it is spawned, takes
## damage through the normal CharacterBase hitbox path (so hitmarkers, damage
## numbers and kill feed all work), then respawns at full health at its spawn
## transform after `respawn_delay` seconds.

signal respawn_pending(seconds: float)

@export var respawn_delay: float = 3.0
## Floating damage readout above the head (scenes/characters/dummy.tscn ships
## one named DamageText). Purely cosmetic; missing node is fine.
@export var damage_text_path: NodePath = ^"DamageText"
@export var damage_text_time: float = 1.1

var _spawn_xform: Transform3D = Transform3D.IDENTITY
var _spawn_captured: bool = false
var _respawn_timer: float = 0.0
var _damage_text: Label3D = null
var _text_timer: float = 0.0
var _text_accum: float = 0.0


func _ready() -> void:
	super._ready()
	_damage_text = get_node_or_null(damage_text_path) as Label3D
	if _damage_text != null:
		_damage_text.visible = false
	damaged.connect(_on_damaged)


## Where the dummy returns to. Call it if the spawner moves the dummy after the
## first physics tick; otherwise the pose at that tick is captured automatically.
func set_spawn_transform(xform: Transform3D) -> void:
	_spawn_xform = xform
	_spawn_captured = true


func _physics_process(delta: float) -> void:
	if not _spawn_captured:
		_spawn_captured = true
		_spawn_xform = global_transform

	_update_damage_text(delta)

	if not alive:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			respawn(_spawn_xform)
		return

	# Stands still, but still runs the shared locomotion so gravity settles it
	# onto the floor and it inherits the standard capsule/eye behaviour.
	move_locomotion(delta, Vector2.ZERO, false, false)


func _on_death(_attacker_id: int, _weapon_id: String, _headshot: bool) -> void:
	_respawn_timer = respawn_delay
	set_body_collision_enabled(false)
	if mesh_root != null:
		mesh_root.visible = false
	if _damage_text != null:
		_damage_text.visible = false
		_text_timer = 0.0
		_text_accum = 0.0
	respawn_pending.emit(respawn_delay)


func _on_damaged(amount: float, _zone: int, _attacker_id: int) -> void:
	if _damage_text == null:
		return
	if _text_timer <= 0.0:
		_text_accum = 0.0
	_text_accum += amount
	_text_timer = damage_text_time
	_damage_text.text = str(int(round(_text_accum)))
	_damage_text.visible = true


func _update_damage_text(delta: float) -> void:
	if _damage_text == null or _text_timer <= 0.0:
		return
	_text_timer -= delta
	if _text_timer <= 0.0:
		_damage_text.visible = false
		return
	var t := _text_timer / maxf(damage_text_time, 0.001)
	_damage_text.modulate.a = clampf(t * 2.0, 0.0, 1.0)
	_damage_text.position.y = EYE_STAND + 0.35 + (1.0 - t) * 0.45
