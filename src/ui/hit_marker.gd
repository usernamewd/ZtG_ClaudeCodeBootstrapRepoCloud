class_name HitMarker
extends Control
## The confirmation flash on the crosshair. One node, reused for every hit: a
## `flash()` call only writes floats, so a full-auto magazine allocates nothing.
##
## Three readings, distinguishable at a glance on a phone without reading text:
##   body     — white X, short
##   headshot — accent X, longer arms plus a tick on each arm
##   kill     — red X, longer still, wrapped in a ring
## A kill outranks a headshot, because "they are down" is the more useful fact.

enum Kind { BODY, HEAD, KILL }

const DUR_BODY := 0.26
const DUR_HEAD := 0.32
const DUR_KILL := 0.46

const ZONE_HEAD := 0            # CharacterBase.Zone.HEAD

const INNER := 5.0              # arm start radius, px at hud_scale 1
const LEN_BODY := 8.0
const LEN_HEAD := 11.0
const LEN_KILL := 13.0
const PUNCH := 4.0              # extra outward travel at the start of the flash
const THICK := 2.0
const OUTLINE := Color(0.0, 0.0, 0.0, 0.6)
const RING_RADIUS := 20.0
const RING_POINTS := 20

const COL_BODY := Color(1.0, 1.0, 1.0, 0.95)
const SFX_HIT := "hit_marker"
const SFX_KILL := "hit_kill"

var _kind: int = Kind.BODY
var _life: float = 0.0
var _dur: float = DUR_BODY
var _scale: float = 1.0
var _dirs: PackedVector2Array = PackedVector2Array()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var d := 0.70710678    # unit diagonal
	_dirs.resize(4)
	_dirs[0] = Vector2(-d, -d)
	_dirs[1] = Vector2(d, -d)
	_dirs[2] = Vector2(-d, d)
	_dirs[3] = Vector2(d, d)
	if not Settings.changed.is_connected(_apply_settings):
		Settings.changed.connect(_apply_settings)
	_apply_settings()
	set_process(false)


func _exit_tree() -> void:
	if Settings.changed.is_connected(_apply_settings):
		Settings.changed.disconnect(_apply_settings)


func _apply_settings() -> void:
	_scale = clampf(Settings.hud_scale, 0.6, 2.0)


## Fed by `PlayerCharacter.hit_marker` (which relays `Weapon.hit_confirmed`), or
## by the weapon signal directly when no relay exists.
func flash(zone: int, died: bool) -> void:
	if died:
		_kind = Kind.KILL
		_dur = DUR_KILL
	elif zone == ZONE_HEAD:
		_kind = Kind.HEAD
		_dur = DUR_HEAD
	else:
		_kind = Kind.BODY
		_dur = DUR_BODY
	_life = _dur
	set_process(true)
	queue_redraw()
	AudioMgr.play_ui(SFX_KILL if died else SFX_HIT)


func clear() -> void:
	if _life <= 0.0:
		return
	_life = 0.0
	set_process(false)
	queue_redraw()


func _process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		_life = 0.0
		set_process(false)
	queue_redraw()


func _draw() -> void:
	if _life <= 0.0:
		return
	var t := _life / _dur                     # 1 at the hit, 0 when finished
	var fade := t * t                         # ease-out so the tail is short
	var punch := (1.0 - t) * PUNCH * _scale

	var col := COL_BODY
	var arm := LEN_BODY
	match _kind:
		Kind.HEAD:
			col = UITheme.ACCENT
			arm = LEN_HEAD
		Kind.KILL:
			col = UITheme.BAD
			arm = LEN_KILL
	col.a = fade

	var c := (size * 0.5).round()
	var r0 := INNER * _scale + punch
	var r1 := (INNER + arm) * _scale + punch
	var th := THICK * _scale
	var back := OUTLINE
	back.a = OUTLINE.a * fade

	for i in _dirs.size():
		var d := _dirs[i]
		draw_line(c + d * r0, c + d * r1, back, th + 2.0)
	for i in _dirs.size():
		var d := _dirs[i]
		draw_line(c + d * r0, c + d * r1, col, th)

	if _kind == Kind.HEAD:
		# A cross-tick near the tip of each arm — reads as "headshot" even when
		# the accent colour is hard to judge against a warm wall.
		var tick := 3.0 * _scale
		for i in _dirs.size():
			var d := _dirs[i]
			var p := c + d * (r1 - tick)
			var n := Vector2(-d.y, d.x) * tick
			draw_line(p - n, p + n, col, th)
	elif _kind == Kind.KILL:
		var ring := col
		ring.a = fade * 0.75
		draw_arc(c, (RING_RADIUS * _scale) + punch * 2.0, 0.0, TAU, RING_POINTS,
			ring, th, true)
