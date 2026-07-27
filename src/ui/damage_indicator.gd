class_name DamageIndicator
extends Control
## Directional damage arcs around the crosshair: "you were shot from there".
##
## A fixed ring of MAX_ARCS slots is preallocated as three PackedFloat32Arrays,
## so taking fire never allocates — a hit either refreshes the arc it lines up
## with (fire from one angle thickens one arc instead of stacking six) or reuses
## the faintest slot. Everything fades out over FADE seconds and `_process`
## switches itself off once the last arc dies.
##
## Angle convention: 0 = straight ahead, positive clockwise on screen (so +PI/2
## is the player's right). The HUD converts world hit directions into that with
## the player's own basis; see src/ui/hud.gd `_on_player_damaged`.

const MAX_ARCS := 6
const FADE := 1.5
const MERGE_ANGLE := 0.30       # rad; hits closer than this share one arc
const RADIUS := 96.0            # px at hud_scale 1
const DRIFT := 14.0             # outward travel across the fade
const POINTS := 14
const THICK_MIN := 4.0
const THICK_MAX := 7.0
const HALF_WIDTH_MIN := 0.16    # rad
const HALF_WIDTH_MAX := 0.44
const HEAVY_DAMAGE := 55.0      # damage that produces the widest arc
const OUTLINE := Color(0.0, 0.0, 0.0, 0.5)
const QUARTER := 1.5707963267948966

var _angle: PackedFloat32Array = PackedFloat32Array()
var _life: PackedFloat32Array = PackedFloat32Array()
var _weight: PackedFloat32Array = PackedFloat32Array()
var _scale: float = 1.0
var _active: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_angle.resize(MAX_ARCS)
	_life.resize(MAX_ARCS)
	_weight.resize(MAX_ARCS)
	if not Settings.changed.is_connected(_apply_settings):
		Settings.changed.connect(_apply_settings)
	_apply_settings()
	set_process(false)


func _exit_tree() -> void:
	if Settings.changed.is_connected(_apply_settings):
		Settings.changed.disconnect(_apply_settings)


func _apply_settings() -> void:
	_scale = clampf(Settings.hud_scale, 0.6, 2.0)


## `angle_rad` follows the convention above; `amount` is the damage that landed
## and only controls how wide and bright the arc is.
func add_hit(angle_rad: float, amount: float) -> void:
	var a := wrapf(angle_rad, -PI, PI)
	var slot := -1
	var faintest := 0
	for i in MAX_ARCS:
		if _life[i] <= 0.0:
			if slot < 0:
				slot = i
			continue
		if absf(wrapf(_angle[i] - a, -PI, PI)) <= MERGE_ANGLE:
			# Same direction: reinforce rather than clutter the ring.
			_life[i] = FADE
			_weight[i] = minf(_weight[i] + maxf(amount, 1.0), HEAVY_DAMAGE * 1.5)
			_start()
			return
		if _life[i] < _life[faintest]:
			faintest = i
	if slot < 0:
		slot = faintest
	_angle[slot] = a
	_life[slot] = FADE
	_weight[slot] = maxf(amount, 1.0)
	_start()


func clear() -> void:
	for i in MAX_ARCS:
		_life[i] = 0.0
	_active = 0
	set_process(false)
	queue_redraw()


func _start() -> void:
	if not is_processing():
		set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	var live := 0
	for i in MAX_ARCS:
		if _life[i] <= 0.0:
			continue
		_life[i] = maxf(_life[i] - delta, 0.0)
		if _life[i] > 0.0:
			live += 1
	_active = live
	if live == 0:
		set_process(false)
	queue_redraw()


func _draw() -> void:
	var c := (size * 0.5).round()
	var base_r := RADIUS * _scale
	for i in MAX_ARCS:
		var life := _life[i]
		if life <= 0.0:
			continue
		var t := life / FADE
		var heat := clampf(_weight[i] / HEAVY_DAMAGE, 0.0, 1.0)
		var r := base_r + (1.0 - t) * DRIFT * _scale
		var half := lerpf(HALF_WIDTH_MIN, HALF_WIDTH_MAX, heat)
		var th := lerpf(THICK_MIN, THICK_MAX, heat) * _scale
		# Screen up is -Y, i.e. -PI/2 in draw_arc's frame; our angle is clockwise
		# from there.
		var mid := _angle[i] - QUARTER
		var col := UITheme.BAD
		col = col.lerp(Color(1.0, 0.85, 0.75), heat * 0.35)
		col.a = t * t * (0.55 + 0.45 * heat)
		var back := OUTLINE
		back.a = OUTLINE.a * t * t
		draw_arc(c, r, mid - half, mid + half, POINTS, back, th + 2.0, true)
		draw_arc(c, r, mid - half, mid + half, POINTS, col, th, true)
