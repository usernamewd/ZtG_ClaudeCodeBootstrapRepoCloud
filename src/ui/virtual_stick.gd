class_name VirtualStick
extends Control
## Left-hand movement stick with a dynamic origin: the ring appears wherever the
## finger lands inside this Control's rect, so there is nothing to aim at. The
## rect IS the stick zone — TouchControls routes a touch-down inside it to this
## node, which means moving/resizing the zone in the HUD editor also moves the
## input region, with no second definition of "left 40%" to keep in sync.
##
## Writes InputHub.move only: x = strafe right, y = forward (screen up), length
## clamped to 1 with a small deadzone. One finger owns the stick for its whole
## lifetime; TouchControls guarantees that.

signal value_changed(value: Vector2)

const FILL_RING := Color(0.055, 0.062, 0.074, 0.34)
const EDGE_RING := Color(1.0, 1.0, 1.0, 0.22)
const EDGE_RING_IDLE := Color(1.0, 1.0, 1.0, 0.13)
const KNOB_FILL := Color(0.90, 0.925, 0.945, 0.30)
const KNOB_EDGE := Color(0.95, 0.96, 0.97, 0.72)
const ACCENT := Color(1.0, 0.478, 0.102)
const EDIT_TINT := Color(0.361, 0.686, 1.0)

const SCALE_MIN := 0.65
const SCALE_MAX := 2.0
const HANDLE_PX := 30.0

@export var hud_id: String = "stick"
## Unscaled travel radius in pixels; multiplied by Settings.hud_scale and the
## per-control layout scale.
@export var radius: float = 120.0
@export var deadzone: float = 0.14
@export var dynamic_origin: bool = true
## Zone size as a fraction of the parent area (default: left 40%, lower 78%).
@export var zone_ratio: Vector2 = Vector2(0.40, 0.78)
@export var hud_anchor: Vector2 = Vector2(0.0, 1.0)
@export var hud_offset: Vector2 = Vector2(0.0, 0.0)

var value: Vector2 = Vector2.ZERO
var layout_scale: float = 1.0

var _active: bool = false
var _origin: Vector2 = Vector2.ZERO
var _knob: Vector2 = Vector2.ZERO
var _home: Vector2 = Vector2.ZERO
var _editing: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	add_to_group("hud_movable")
	set_meta("hud_id", hud_id)
	set_meta("hud_anchor", hud_anchor)
	set_meta("hud_default_pos", hud_offset)
	set_meta("hud_default_size", Vector2(radius * 2.0, radius * 2.0))
	set_meta("hud_default_scale", 1.0)
	apply_hud_layout()


func radius_px() -> float:
	return radius * Settings.hud_scale * layout_scale


func contains(viewport_pos: Vector2) -> bool:
	if not is_visible_in_tree():
		return false
	return Rect2(Vector2.ZERO, size).has_point(_local_of(viewport_pos))


# --- input, driven by TouchControls -------------------------------------------

func begin(viewport_pos: Vector2) -> void:
	var p := _local_of(viewport_pos)
	_origin = p if dynamic_origin else _home
	_knob = p
	_active = true
	_update_value()
	queue_redraw()


func drag(viewport_pos: Vector2) -> void:
	if not _active:
		return
	var p := _local_of(viewport_pos)
	if p.distance_squared_to(_knob) < 0.25:
		return
	_knob = p
	_update_value()
	queue_redraw()


func end() -> void:
	if not _active:
		return
	_active = false
	_knob = _origin
	value = Vector2.ZERO
	InputHub.move = Vector2.ZERO
	value_changed.emit(value)
	queue_redraw()


func _update_value() -> void:
	var r := radius_px()
	var d := _knob - _origin
	var dist := d.length()
	var out := Vector2.ZERO
	if r > 1.0 and dist > r * deadzone:
		var mag: float = clampf((dist - r * deadzone) / (r * (1.0 - deadzone)), 0.0, 1.0)
		out = d / dist * mag
	if out == value:
		return
	value = out
	# Screen +y is down; forward is up.
	InputHub.move = Vector2(out.x, -out.y)
	value_changed.emit(value)


func _local_of(viewport_pos: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * viewport_pos


# --- layout -------------------------------------------------------------------

func apply_hud_layout() -> void:
	var off := hud_offset
	var mult := 1.0
	if hud_id != "":
		var ov: Variant = Settings.hud_layout.get(hud_id)
		if ov is Dictionary:
			var d: Dictionary = ov
			if d.has("pos"):
				off = to_vec2(d["pos"], off)
			if d.has("scale"):
				mult = float(d["scale"])
	layout_scale = clampf(mult, SCALE_MIN, SCALE_MAX)
	var area := get_parent_area_size()
	var r := radius_px()
	var want := Vector2(area.x * zone_ratio.x, area.y * zone_ratio.y)
	size = Vector2(
		clampf(want.x, minf(r * 2.0 + 32.0, area.x), area.x),
		clampf(want.y, minf(r * 2.0 + 32.0, area.y), area.y)).round()
	var anchor_pt := Vector2(area.x * hud_anchor.x, area.y * hud_anchor.y)
	position = (anchor_pt + off * Settings.hud_scale
		- Vector2(size.x * hud_anchor.x, size.y * hud_anchor.y)).round()
	_recompute_home()
	queue_redraw()


## Settings persist through JSON, which turns a Vector2 into the string "(x, y)";
## a stored layout must therefore be parsed tolerantly. Duplicated in
## touch_button.gd on purpose so neither control depends on the other.
static func to_vec2(v: Variant, fallback: Vector2) -> Vector2:
	match typeof(v):
		TYPE_VECTOR2:
			return v
		TYPE_VECTOR2I:
			return Vector2(v)
		TYPE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY:
			var a: Array = Array(v)
			if a.size() >= 2:
				return Vector2(float(a[0]), float(a[1]))
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(v).strip_edges()
			if not s.begins_with("Vector2"):
				s = "Vector2" + s
			var parsed: Variant = str_to_var(s)
			if parsed is Vector2:
				return parsed
	return fallback


func _recompute_home() -> void:
	var r := radius_px()
	var min_x: float = minf(r + 14.0, size.x * 0.5)
	var min_y: float = minf(r + 14.0, size.y * 0.5)
	_home = Vector2(
		clampf(size.x * 0.34, min_x, maxf(min_x, size.x - min_x)),
		clampf(size.y - r - 22.0, min_y, maxf(min_y, size.y - min_y)))
	if not _active:
		_origin = _home
		_knob = _home


func nudge(delta: Vector2) -> void:
	var area := get_parent_area_size()
	position = Vector2(
		clampf(position.x + delta.x, -size.x * 0.35, area.x - size.x * 0.65),
		clampf(position.y + delta.y, -size.y * 0.35, area.y - size.y * 0.65))
	_sync_offset_from_position()


func set_layout_scale(s: float) -> void:
	layout_scale = clampf(s, SCALE_MIN, SCALE_MAX)
	_recompute_home()
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


func is_in_resize_handle(viewport_pos: Vector2) -> bool:
	var local := _local_of(viewport_pos)
	var h := minf(HANDLE_PX, minf(size.x, size.y) * 0.45)
	return Rect2(size - Vector2(h, h), Vector2(h, h)).grow(6.0).has_point(local)


func set_editing(on: bool) -> void:
	if _editing == on:
		return
	_editing = on
	if on:
		end()
	queue_redraw()


# --- drawing ------------------------------------------------------------------

func _draw() -> void:
	var r := radius_px()
	if _editing:
		_draw_edit_overlay()
	if r < 8.0:
		return
	if not _active:
		# Resting hint so the stick is discoverable: dim ring, four ticks, dot.
		draw_circle(_home, r, Color(FILL_RING.r, FILL_RING.g, FILL_RING.b, FILL_RING.a * 0.55))
		draw_arc(_home, r - 1.0, 0.0, TAU, 52, EDGE_RING_IDLE, 1.6, true)
		var tick := Color(1.0, 1.0, 1.0, 0.16)
		draw_line(_home + Vector2(0.0, -r * 0.86), _home + Vector2(0.0, -r * 0.62), tick, 2.0, true)
		draw_line(_home + Vector2(0.0, r * 0.86), _home + Vector2(0.0, r * 0.62), tick, 2.0, true)
		draw_line(_home + Vector2(-r * 0.86, 0.0), _home + Vector2(-r * 0.62, 0.0), tick, 2.0, true)
		draw_line(_home + Vector2(r * 0.86, 0.0), _home + Vector2(r * 0.62, 0.0), tick, 2.0, true)
		draw_circle(_home, r * 0.26, Color(0.90, 0.925, 0.945, 0.16))
		draw_arc(_home, r * 0.26, 0.0, TAU, 26, Color(1.0, 1.0, 1.0, 0.24), 1.4, true)
		return

	var d := _knob - _origin
	var dist := d.length()
	var knob_pos := _origin + (d / dist * minf(dist, r) if dist > 0.001 else Vector2.ZERO)
	var full: bool = value.length() > 0.985

	draw_circle(_origin, r, FILL_RING)
	draw_arc(_origin, r - 1.0, 0.0, TAU, 52, ACCENT if full else EDGE_RING, 2.0, true)
	# Travel line + direction wedge on the ring edge.
	if dist > 1.0:
		draw_line(_origin, knob_pos, Color(1.0, 1.0, 1.0, 0.22), 2.0, true)
		var ang := d.angle()
		draw_arc(_origin, r - 1.0, ang - 0.32, ang + 0.32, 12, ACCENT, 3.0, true)
	var kr := r * 0.34
	draw_circle(knob_pos, kr, KNOB_FILL)
	draw_arc(knob_pos, kr - 0.8, 0.0, TAU, 32, KNOB_EDGE, 2.0, true)
	draw_circle(knob_pos, kr * 0.16, Color(1.0, 1.0, 1.0, 0.55))


func _draw_edit_overlay() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var col := Color(EDIT_TINT.r, EDIT_TINT.g, EDIT_TINT.b, 0.55)
	var step := 12.0
	var x := rect.position.x
	while x < rect.end.x:
		draw_line(Vector2(x, rect.position.y), Vector2(minf(x + 6.0, rect.end.x), rect.position.y), col, 1.5)
		draw_line(Vector2(x, rect.end.y - 1.0), Vector2(minf(x + 6.0, rect.end.x), rect.end.y - 1.0), col, 1.5)
		x += step
	var y := rect.position.y
	while y < rect.end.y:
		draw_line(Vector2(rect.position.x, y), Vector2(rect.position.x, minf(y + 6.0, rect.end.y)), col, 1.5)
		draw_line(Vector2(rect.end.x - 1.0, y), Vector2(rect.end.x - 1.0, minf(y + 6.0, rect.end.y)), col, 1.5)
		y += step
	var f := get_theme_default_font()
	draw_string(f, rect.position + Vector2(10.0, 22.0), "MOVE ZONE",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, EDIT_TINT)
	var h := minf(HANDLE_PX, minf(size.x, size.y) * 0.45)
	var hr := Rect2(size - Vector2(h, h), Vector2(h, h))
	draw_rect(hr, Color(EDIT_TINT.r, EDIT_TINT.g, EDIT_TINT.b, 0.22), true)
	draw_rect(hr, EDIT_TINT, false, 1.5)
	draw_line(hr.position + Vector2(h * 0.25, h * 0.75), hr.position + Vector2(h * 0.75, h * 0.25),
		EDIT_TINT, 1.5, true)
