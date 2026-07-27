class_name TouchButton
extends Control
## A single procedurally drawn touch control. Draws itself with `_draw` (no
## textures, no fonts beyond one short label) and reports finger state; it never
## touches InputHub — TouchControls owns that mapping.
##
## The button does NOT read raw input events. TouchControls hit-tests it and
## calls touch_down/touch_up, because multitouch ownership has to be decided in
## one place (a finger that lands on a button keeps it for its whole lifetime,
## and the look surface must ignore that finger).
##
## Layout: `hud_anchor` picks the corner/edge of the parent area the button
## hangs off, `hud_offset` is the unscaled pixel offset from that anchor point
## to the button's own matching anchor point. Everything is multiplied by
## Settings.hud_scale, plus a per-button `scale` from Settings.hud_layout, so a
## layout authored on one phone still reads on another.

signal pressed
signal released(hold_time: float)
signal held(active: bool)

enum Icon {
	NONE,
	FIRE,
	ADS,
	JUMP,
	CROUCH,
	RELOAD,
	INTERACT,
	RIFLE,
	PISTOL,
	KNIFE,
	GRENADE,
	GRENADE_CYCLE,
}

# Shared visual language: near-black translucent fill, thin light edge, warm
# accent (#FF7A1A) for anything live. Mirrors UITheme's palette but is kept
# local so a touch control never fails to draw because another screen's theme
# script changed.
const FILL_IDLE := Color(0.055, 0.062, 0.074, 0.42)
const FILL_LIT := Color(0.44, 0.20, 0.05, 0.62)
const EDGE_IDLE := Color(1.0, 1.0, 1.0, 0.20)
const EDGE_LIT := Color(1.0, 0.478, 0.102, 0.95)
const GLYPH_IDLE := Color(0.902, 0.925, 0.945, 0.88)
const GLYPH_LIT := Color(1.0, 0.62, 0.28, 1.0)
const ACCENT := Color(1.0, 0.478, 0.102)
const EDIT_TINT := Color(0.361, 0.686, 1.0)

const SCALE_MIN := 0.65
const SCALE_MAX := 2.0
const HANDLE_PX := 30.0
const FLASH_SPEED := 9.0
const HAPTIC_MS := 8

@export var hud_id: String = ""
@export var icon: Icon = Icon.NONE
@export var label_text: String = ""
@export var base_size: Vector2 = Vector2(92.0, 92.0)
@export var hud_anchor: Vector2 = Vector2(1.0, 1.0)
@export var hud_offset: Vector2 = Vector2(-32.0, -32.0)
@export var round_shape: bool = true
## Fire buttons set this: dragging the finger that holds the button also steers
## the camera, which is how mobile shooters let you aim while firing.
@export var look_passthrough: bool = false
@export var hit_pad: float = 6.0
@export var haptic: bool = true
@export var label_size: int = 12

var is_held: bool = false

var active: bool = false:
	set(v):
		if active == v:
			return
		active = v
		queue_redraw()

var disabled: bool = false:
	set(v):
		if disabled == v:
			return
		disabled = v
		if disabled and is_held:
			touch_up(true)
		queue_redraw()

var layout_scale: float = 1.0

var _flash: float = 0.0
var _hold_time: float = 0.0
var _editing: bool = false
var _box: StyleBoxFlat
var _pts: PackedVector2Array = PackedVector2Array()
var _mobile: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	_mobile = OS.has_feature("mobile")
	_box = StyleBoxFlat.new()
	_box.set_border_width_all(1)
	_pts.resize(4)
	add_to_group("hud_movable")
	set_meta("hud_id", hud_id)
	set_meta("hud_anchor", hud_anchor)
	set_meta("hud_default_pos", hud_offset)
	set_meta("hud_default_size", base_size)
	set_meta("hud_default_scale", 1.0)
	set_process(false)
	apply_hud_layout()


# --- input, driven by TouchControls -------------------------------------------

## Canvas-aware hit test. The position is in viewport coordinates; converting
## through the canvas transform keeps this correct if the HUD's CanvasLayer is
## offset or scaled.
func has_point(viewport_pos: Vector2) -> bool:
	if disabled or not is_visible_in_tree():
		return false
	var local := get_global_transform_with_canvas().affine_inverse() * viewport_pos
	return Rect2(Vector2.ZERO, size).grow(hit_pad).has_point(local)


func is_in_resize_handle(viewport_pos: Vector2) -> bool:
	var local := get_global_transform_with_canvas().affine_inverse() * viewport_pos
	var h := minf(HANDLE_PX, minf(size.x, size.y) * 0.45)
	return Rect2(size - Vector2(h, h), Vector2(h, h)).grow(6.0).has_point(local)


func touch_down(_viewport_pos: Vector2) -> void:
	if disabled or is_held:
		return
	is_held = true
	_hold_time = 0.0
	_flash = 1.0
	set_process(true)
	queue_redraw()
	if haptic and _mobile:
		Input.vibrate_handheld(HAPTIC_MS)
	AudioMgr.play_ui("ui_tap")
	pressed.emit()
	held.emit(true)


func touch_up(canceled: bool = false) -> void:
	if not is_held:
		return
	is_held = false
	set_process(true)
	queue_redraw()
	if not canceled:
		released.emit(_hold_time)
	held.emit(false)


func _process(delta: float) -> void:
	if is_held:
		_hold_time += delta
	var target := 1.0 if is_held else 0.0
	if is_equal_approx(_flash, target):
		_flash = target
		if not is_held:
			set_process(false)
		return
	_flash = move_toward(_flash, target, delta * FLASH_SPEED)
	queue_redraw()


# --- layout -------------------------------------------------------------------

func apply_hud_layout() -> void:
	var off := hud_offset
	var mult := 1.0
	if hud_id != "":
		var ov: Variant = Settings.hud_layout.get(hud_id)
		if ov is Dictionary:
			var d: Dictionary = ov
			if d.has("pos"):
				off = d["pos"]
			if d.has("scale"):
				mult = float(d["scale"])
	layout_scale = clampf(mult, SCALE_MIN, SCALE_MAX)
	var hs: float = Settings.hud_scale
	size = (base_size * hs * layout_scale).round()
	var area := get_parent_area_size()
	var anchor_pt := Vector2(area.x * hud_anchor.x, area.y * hud_anchor.y)
	position = (anchor_pt + off * hs - Vector2(size.x * hud_anchor.x, size.y * hud_anchor.y)).round()
	queue_redraw()


## Editor drag: `delta` is a movement in parent-local pixels.
func nudge(delta: Vector2) -> void:
	var area := get_parent_area_size()
	position = Vector2(
		clampf(position.x + delta.x, -size.x * 0.35, area.x - size.x * 0.65),
		clampf(position.y + delta.y, -size.y * 0.35, area.y - size.y * 0.65))
	_sync_offset_from_position()


func set_layout_scale(s: float) -> void:
	var centre := position + size * 0.5
	layout_scale = clampf(s, SCALE_MIN, SCALE_MAX)
	size = (base_size * Settings.hud_scale * layout_scale).round()
	position = (centre - size * 0.5).round()
	_sync_offset_from_position()
	queue_redraw()


func _sync_offset_from_position() -> void:
	var area := get_parent_area_size()
	var anchor_pt := Vector2(area.x * hud_anchor.x, area.y * hud_anchor.y)
	var own := position + Vector2(size.x * hud_anchor.x, size.y * hud_anchor.y)
	var hs: float = maxf(Settings.hud_scale, 0.01)
	hud_offset = (own - anchor_pt) / hs


func store_layout() -> void:
	if hud_id == "":
		return
	Settings.hud_layout[hud_id] = {"pos": hud_offset, "scale": layout_scale}


func reset_layout() -> void:
	if hud_id != "" and Settings.hud_layout.has(hud_id):
		Settings.hud_layout.erase(hud_id)
	hud_offset = get_meta("hud_default_pos", hud_offset)
	layout_scale = 1.0
	apply_hud_layout()


func set_editing(on: bool) -> void:
	if _editing == on:
		return
	_editing = on
	if on and is_held:
		touch_up(true)
	queue_redraw()


# --- drawing ------------------------------------------------------------------

func _draw() -> void:
	if size.x < 4.0 or size.y < 4.0:
		return
	var lit := maxf(_flash, 0.85 if active else 0.0)
	var fill := FILL_IDLE.lerp(FILL_LIT, lit)
	var edge := EDGE_IDLE.lerp(EDGE_LIT, lit)
	var glyph := GLYPH_IDLE.lerp(GLYPH_LIT, lit)
	if disabled:
		fill.a *= 0.35
		edge.a *= 0.35
		glyph.a *= 0.30
	var r := Rect2(Vector2.ZERO, size).grow(-(1.0 + _flash * 2.0))
	if round_shape:
		var c := r.get_center()
		var rad := minf(r.size.x, r.size.y) * 0.5
		draw_circle(c, rad, fill)
		draw_arc(c, rad - 0.8, 0.0, TAU, 44, edge, 1.6, true)
	else:
		_box.bg_color = fill
		_box.border_color = edge
		_box.set_corner_radius_all(int(minf(r.size.y * 0.30, 14.0)))
		draw_style_box(_box, r)

	var has_label := label_text != ""
	var icon_c := r.get_center()
	var icon_r := minf(r.size.x, r.size.y) * 0.5
	if has_label:
		icon_c.y -= r.size.y * 0.10
		icon_r *= 0.80
	if icon != Icon.NONE:
		_draw_icon(icon_c, icon_r * 0.62, glyph)
	if has_label:
		var f := get_theme_default_font()
		var fs := int(maxf(9.0, label_size * Settings.hud_scale * layout_scale))
		var w := f.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var base_y := r.position.y + r.size.y - maxf(6.0, r.size.y * 0.09)
		if icon == Icon.NONE:
			base_y = r.get_center().y + fs * 0.36
		draw_string(f, Vector2(r.get_center().x - w * 0.5, base_y), label_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, glyph)
	if _editing:
		_draw_edit_overlay()


func _draw_edit_overlay() -> void:
	var r := Rect2(Vector2.ZERO, size)
	_draw_brackets(r, EDIT_TINT, minf(16.0, minf(size.x, size.y) * 0.4), 2.0)
	var h := minf(HANDLE_PX, minf(size.x, size.y) * 0.45)
	var hr := Rect2(size - Vector2(h, h), Vector2(h, h))
	draw_rect(hr, Color(EDIT_TINT.r, EDIT_TINT.g, EDIT_TINT.b, 0.22), true)
	draw_rect(hr, EDIT_TINT, false, 1.5)
	draw_line(hr.position + Vector2(h * 0.25, h * 0.75),
		hr.position + Vector2(h * 0.75, h * 0.25), EDIT_TINT, 1.5, true)


func _draw_brackets(r: Rect2, col: Color, length: float, width: float) -> void:
	var l := minf(length, minf(r.size.x, r.size.y) * 0.45)
	draw_line(r.position, r.position + Vector2(l, 0.0), col, width, true)
	draw_line(r.position, r.position + Vector2(0.0, l), col, width, true)
	var tr := Vector2(r.end.x, r.position.y)
	draw_line(tr, tr + Vector2(-l, 0.0), col, width, true)
	draw_line(tr, tr + Vector2(0.0, l), col, width, true)
	var bl := Vector2(r.position.x, r.end.y)
	draw_line(bl, bl + Vector2(l, 0.0), col, width, true)
	draw_line(bl, bl + Vector2(0.0, -l), col, width, true)
	draw_line(r.end, r.end + Vector2(-l, 0.0), col, width, true)
	draw_line(r.end, r.end + Vector2(0.0, -l), col, width, true)


# --- procedural icons ---------------------------------------------------------
# All glyphs are built from arcs, lines and convex quads in a normalised
# [-1..1] box around `c` scaled by `s`, so they stay sharp at any button size
# and need no imported art.

func _draw_icon(c: Vector2, s: float, col: Color) -> void:
	match icon:
		Icon.FIRE:
			_icon_fire(c, s, col)
		Icon.ADS:
			_icon_ads(c, s, col)
		Icon.JUMP:
			_icon_arrow(c, s, col, true)
		Icon.CROUCH:
			_icon_arrow(c, s, col, false)
		Icon.RELOAD:
			_icon_reload(c, s, col)
		Icon.INTERACT:
			_icon_interact(c, s, col)
		Icon.RIFLE:
			_icon_rifle(c, s, col)
		Icon.PISTOL:
			_icon_pistol(c, s, col)
		Icon.KNIFE:
			_icon_knife(c, s, col)
		Icon.GRENADE:
			_icon_grenade(c, s, col, 0.0)
		Icon.GRENADE_CYCLE:
			_icon_grenade(c, s, col, 0.78)
			_icon_cycle_arrow(c, s, col)


func _p(c: Vector2, s: float, x: float, y: float) -> Vector2:
	return Vector2(c.x + x * s, c.y + y * s)


func _quad(c: Vector2, s: float, a: Vector2, b: Vector2, d: Vector2, e: Vector2, col: Color) -> void:
	_pts.set(0, _p(c, s, a.x, a.y))
	_pts.set(1, _p(c, s, b.x, b.y))
	_pts.set(2, _p(c, s, d.x, d.y))
	_pts.set(3, _p(c, s, e.x, e.y))
	draw_colored_polygon(_pts, col)


func _box_n(c: Vector2, s: float, x0: float, y0: float, x1: float, y1: float, col: Color) -> void:
	_quad(c, s, Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1), col)


## Reticle: ring, four outer ticks, centre dot.
func _icon_fire(c: Vector2, s: float, col: Color) -> void:
	draw_arc(c, s * 0.62, 0.0, TAU, 40, col, maxf(1.5, s * 0.10), true)
	var w := maxf(1.5, s * 0.11)
	draw_line(_p(c, s, 0.0, -1.05), _p(c, s, 0.0, -0.78), col, w, true)
	draw_line(_p(c, s, 0.0, 1.05), _p(c, s, 0.0, 0.78), col, w, true)
	draw_line(_p(c, s, -1.05, 0.0), _p(c, s, -0.78, 0.0), col, w, true)
	draw_line(_p(c, s, 1.05, 0.0), _p(c, s, 0.78, 0.0), col, w, true)
	draw_circle(c, maxf(1.5, s * 0.15), col)


## Scope: full-width crosshair through a ring.
func _icon_ads(c: Vector2, s: float, col: Color) -> void:
	var w := maxf(1.4, s * 0.09)
	draw_arc(c, s * 0.95, 0.0, TAU, 48, col, w, true)
	draw_line(_p(c, s, -0.95, 0.0), _p(c, s, -0.22, 0.0), col, w, true)
	draw_line(_p(c, s, 0.95, 0.0), _p(c, s, 0.22, 0.0), col, w, true)
	draw_line(_p(c, s, 0.0, -0.95), _p(c, s, 0.0, -0.22), col, w, true)
	draw_line(_p(c, s, 0.0, 0.95), _p(c, s, 0.0, 0.22), col, w, true)
	draw_circle(c, maxf(1.2, s * 0.10), col)


## Two chevrons over a ground line: up = jump, down = crouch. The line always
## stays at the bottom so the pair reads as "leave the floor" / "get low".
func _icon_arrow(c: Vector2, s: float, col: Color, up: bool) -> void:
	var w := maxf(2.0, s * 0.16)
	var step := 0.58 if up else -0.58
	var t1 := -0.85 if up else 0.52
	var a1 := t1 + (0.66 if up else -0.66)
	draw_line(_p(c, s, -0.72, a1), _p(c, s, 0.0, t1), col, w, true)
	draw_line(_p(c, s, 0.72, a1), _p(c, s, 0.0, t1), col, w, true)
	draw_line(_p(c, s, -0.66, a1 + step), _p(c, s, 0.0, t1 + step), col, w * 0.78, true)
	draw_line(_p(c, s, 0.66, a1 + step), _p(c, s, 0.0, t1 + step), col, w * 0.78, true)
	draw_line(_p(c, s, -0.85, 0.95), _p(c, s, 0.85, 0.95), col, w * 0.9, true)


## Arrowhead sitting on a circle at `angle`, pointing along the arc.
func _arc_head(c: Vector2, s: float, rad: float, angle: float, ccw: bool, col: Color) -> void:
	var nrm := Vector2(cos(angle), sin(angle))
	var tangent := Vector2(-nrm.y, nrm.x) * (1.0 if ccw else -1.0)
	var base := c + nrm * rad
	_pts.set(0, base + tangent * s * 0.46)
	_pts.set(1, base + nrm * s * 0.26)
	_pts.set(2, base - nrm * s * 0.26)
	_pts.set(3, base + tangent * s * 0.46)
	draw_colored_polygon(_pts, col)


## Magazine with a circular arrow around it.
func _icon_reload(c: Vector2, s: float, col: Color) -> void:
	var w := maxf(1.6, s * 0.12)
	var a0 := deg_to_rad(-52.0)
	draw_arc(c, s * 0.94, a0, deg_to_rad(248.0), 40, col, w, true)
	_arc_head(c, s, s * 0.94, a0, false, col)
	_box_n(c, s, -0.28, -0.46, 0.28, 0.28, col)
	_box_n(c, s, -0.21, 0.28, 0.21, 0.54, Color(col.r, col.g, col.b, col.a * 0.55))


## Charge panel: keypad body, four keys, wire lead. Reads for plant and defuse,
## which is why the button also carries a PLANT/DEFUSE label.
func _icon_interact(c: Vector2, s: float, col: Color) -> void:
	var w := maxf(1.4, s * 0.11)
	draw_rect(Rect2(_p(c, s, -0.80, -0.56), Vector2(s * 1.60, s * 1.30)), col, false, w)
	var dim := Color(col.r, col.g, col.b, col.a * 0.88)
	draw_rect(Rect2(_p(c, s, -0.56, -0.32), Vector2(s * 0.46, s * 0.40)), dim, true)
	draw_rect(Rect2(_p(c, s, 0.10, -0.32), Vector2(s * 0.46, s * 0.40)), dim, true)
	draw_rect(Rect2(_p(c, s, -0.56, 0.20), Vector2(s * 0.46, s * 0.40)), dim, true)
	draw_rect(Rect2(_p(c, s, 0.10, 0.20), Vector2(s * 0.46, s * 0.40)), dim, true)
	draw_line(_p(c, s, 0.44, -0.56), _p(c, s, 0.84, -0.96), col, w, true)
	draw_circle(_p(c, s, 0.88, -1.00), maxf(1.4, s * 0.14), col)


func _icon_rifle(c: Vector2, s: float, col: Color) -> void:
	_quad(c, s, Vector2(-1.00, 0.02), Vector2(-0.62, -0.10), Vector2(-0.62, 0.12), Vector2(-1.00, 0.26), col)
	_box_n(c, s, -0.62, -0.12, 0.34, 0.10, col)
	_box_n(c, s, 0.34, -0.06, 1.00, 0.04, col)
	_box_n(c, s, -0.30, -0.30, -0.08, -0.12, col)
	_quad(c, s, Vector2(-0.36, 0.10), Vector2(-0.16, 0.10), Vector2(-0.26, 0.52), Vector2(-0.48, 0.52), col)
	_quad(c, s, Vector2(-0.04, 0.10), Vector2(0.18, 0.10), Vector2(0.14, 0.62), Vector2(-0.08, 0.62), col)


func _icon_pistol(c: Vector2, s: float, col: Color) -> void:
	_box_n(c, s, -0.62, -0.44, 0.62, -0.16, col)
	_box_n(c, s, 0.62, -0.38, 0.82, -0.22, col)
	_quad(c, s, Vector2(-0.62, -0.16), Vector2(0.10, -0.16), Vector2(0.04, 0.04), Vector2(-0.56, 0.04), col)
	_quad(c, s, Vector2(-0.56, 0.00), Vector2(-0.18, 0.00), Vector2(0.02, 0.72), Vector2(-0.40, 0.72), col)
	draw_arc(_p(c, s, -0.16, 0.16), s * 0.20, deg_to_rad(-30.0), deg_to_rad(200.0), 16, col,
		maxf(1.2, s * 0.09), true)


## Tapered blade (triangle) + guard bar + thick handle, drawn on the diagonal so
## it cannot be mistaken for the gun silhouettes next to it.
func _icon_knife(c: Vector2, s: float, col: Color) -> void:
	_pts.set(0, _p(c, s, 0.98, -0.80))
	_pts.set(1, _p(c, s, 0.16, 0.30))
	_pts.set(2, _p(c, s, -0.16, -0.06))
	_pts.set(3, _p(c, s, 0.98, -0.80))
	draw_colored_polygon(_pts, col)
	draw_line(_p(c, s, -0.28, -0.12), _p(c, s, 0.22, 0.36), col, maxf(2.0, s * 0.15), true)
	draw_line(_p(c, s, -0.06, 0.10), _p(c, s, -0.68, 0.74), col, maxf(2.5, s * 0.28), true)


func _icon_grenade(c: Vector2, s: float, col: Color, shrink: float) -> void:
	var k := 1.0 - shrink * 0.30
	var body := _p(c, s, -0.06 * k, 0.22 * k)
	draw_circle(body, s * 0.52 * k, col)
	_box_n(c, s * k, -0.22, -0.62, 0.16, -0.32, col)
	draw_arc(_p(c, s * k, 0.36, -0.62), s * k * 0.22, deg_to_rad(-140.0), deg_to_rad(140.0), 18, col,
		maxf(1.2, s * k * 0.11), true)
	draw_line(_p(c, s * k, 0.16, -0.52), _p(c, s * k, 0.34, -0.62), col, maxf(1.2, s * k * 0.10), true)


func _icon_cycle_arrow(c: Vector2, s: float, col: Color) -> void:
	var w := maxf(1.4, s * 0.11)
	var a0 := deg_to_rad(118.0)
	draw_arc(c, s * 0.98, a0, deg_to_rad(424.0), 36, col, w, true)
	_arc_head(c, s, s * 0.98, a0, false, col)
