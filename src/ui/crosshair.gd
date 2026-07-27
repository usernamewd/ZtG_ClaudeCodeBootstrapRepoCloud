class_name Crosshair
extends Control
## The aiming reticle: four lines and an optional centre dot, drawn with exactly
## the geometry the settings preview uses (src/ui/settings_screen.gd,
## CrosshairPreview) so what the player tunes is what they get in a match.
##
## When Settings.crosshair_dynamic is on, the gap tracks the weapon's real cone.
## `Weapon.current_spread_deg()` is a half-angle, so it is projected to pixels
## through the live camera FOV — the gap then genuinely marks where the next
## bullet can land instead of being a decorative wobble. It snaps outward on a
## shot and eases back in.
##
## Cost: `_process` does float maths only (no allocation) and calls
## `queue_redraw()` only when the gap moves by at least REDRAW_EPS pixels, so a
## standing player with a settled cone repaints zero times per second. With a
## static crosshair `_process` is disabled outright.

## Every line's dark backing, so the reticle stays legible over a bright wall.
const OUTLINE := Color(0.0, 0.0, 0.0, 0.55)
const OUTLINE_GROW := 2.0

const SHRINK_RATE := 9.0        # exponential ease-in rate, units/s
const REDRAW_EPS := 0.35        # px of gap movement that justifies a repaint
const SETTLE_EPS := 0.05
const MAX_GAP := 260.0
const FALLBACK_FOV := 70.0
const MIN_SPREAD_DEG := 0.01

const M_WEAPON_SPREAD := &"current_spread_deg"
const M_PLAYER_SPREAD := &"get_spread_deg"
const M_PLAYER_CAMERA := &"get_camera"

var _weapon: Node = null
var _player: Node = null
var _camera: Camera3D = null
var _has_weapon_spread: bool = false
var _has_player_spread: bool = false

# Cached copy of Settings, refreshed on `Settings.changed` only.
var _color: Color = Color(0.2, 1.0, 0.4, 0.9)
var _len: float = 12.0
var _base_gap: float = 4.0
var _thick: float = 2.0
var _dot: bool = false
var _dynamic: bool = true

var _gap: float = 4.0
var _gap_drawn: float = -1.0
var _dirs: PackedVector2Array = PackedVector2Array()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dirs.resize(4)
	_dirs[0] = Vector2.UP
	_dirs[1] = Vector2.DOWN
	_dirs[2] = Vector2.LEFT
	_dirs[3] = Vector2.RIGHT
	if not Settings.changed.is_connected(_apply_settings):
		Settings.changed.connect(_apply_settings)
	_apply_settings()


func _exit_tree() -> void:
	if Settings.changed.is_connected(_apply_settings):
		Settings.changed.disconnect(_apply_settings)


# --- binding ------------------------------------------------------------------

## The Weapon node currently held. Null (knife, dead, empty slot) falls back to
## the player's own spread model.
func set_weapon(w: Node) -> void:
	_weapon = w
	_has_weapon_spread = w != null and w.has_method(M_WEAPON_SPREAD)
	_gap = _base_gap
	_force_redraw()


func set_player(p: Node) -> void:
	_player = p
	_has_player_spread = p != null and p.has_method(M_PLAYER_SPREAD)
	_camera = null
	if p != null and p.has_method(M_PLAYER_CAMERA):
		_camera = p.call(M_PLAYER_CAMERA) as Camera3D
	_gap = _base_gap
	_force_redraw()


func set_camera(cam: Camera3D) -> void:
	_camera = cam


# --- settings -----------------------------------------------------------------

func _apply_settings() -> void:
	_color = Settings.crosshair_color
	_len = maxf(Settings.crosshair_size, 1.0)
	_base_gap = maxf(Settings.crosshair_gap, 0.0)
	_thick = maxf(Settings.crosshair_thickness, 1.0)
	_dot = Settings.crosshair_dot
	_dynamic = Settings.crosshair_dynamic
	if not _dynamic:
		_gap = _base_gap
	set_process(_dynamic)
	_force_redraw()


func _force_redraw() -> void:
	_gap_drawn = -1.0
	queue_redraw()


# --- dynamic gap --------------------------------------------------------------

func _process(delta: float) -> void:
	var target := _base_gap + _spread_px()
	if target > _gap:
		# A shot must be visible on the very frame it happens.
		_gap = target
	else:
		_gap = lerpf(_gap, target, 1.0 - exp(-SHRINK_RATE * delta))
		if absf(_gap - target) < SETTLE_EPS:
			_gap = target
	if absf(_gap - _gap_drawn) >= REDRAW_EPS:
		_gap_drawn = _gap
		queue_redraw()


## Half-angle of the current cone projected onto the screen. Godot's Camera3D
## keeps vertical FOV by default, so the viewport height is the right reference.
func _spread_px() -> float:
	var deg := 0.0
	if _has_weapon_spread and is_instance_valid(_weapon):
		deg = float(_weapon.call(M_WEAPON_SPREAD))
	elif _has_player_spread and is_instance_valid(_player):
		deg = float(_player.call(M_PLAYER_SPREAD))
	if deg <= MIN_SPREAD_DEG:
		return 0.0
	var fov := FALLBACK_FOV
	if _camera != null and is_instance_valid(_camera):
		fov = _camera.fov
	var half := tan(deg_to_rad(clampf(fov, 20.0, 130.0) * 0.5))
	if half <= 0.0:
		return 0.0
	return minf(tan(deg_to_rad(minf(deg, 45.0))) / half * size.y * 0.5, MAX_GAP)


# --- drawing ------------------------------------------------------------------

func _draw() -> void:
	var c := (size * 0.5).round()
	var g: float = _gap if _dynamic else _base_gap
	var outer := g + _len
	var back := _thick + OUTLINE_GROW
	for i in _dirs.size():
		var d := _dirs[i]
		draw_line(c + d * g, c + d * outer, OUTLINE, back)
	for i in _dirs.size():
		var d := _dirs[i]
		draw_line(c + d * g, c + d * outer, _color, _thick)
	if _dot:
		var half := _thick * 0.5
		draw_rect(Rect2(c.x - half - 1.0, c.y - half - 1.0,
			_thick + 2.0, _thick + 2.0), OUTLINE)
		draw_rect(Rect2(c.x - half, c.y - half, _thick, _thick), _color)
