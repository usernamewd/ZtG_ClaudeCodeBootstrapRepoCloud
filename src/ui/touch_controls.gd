class_name TouchControls
extends Control
## The whole mobile control layer. Owns multitouch routing and is the ONLY node
## here that writes to InputHub; the player controller reads InputHub and never
## sees this scene.
##
## Routing rules (docs/ARCHITECTURE.md, "Touch controls"):
##  - every active finger is tracked by its event `index` in a preallocated
##    table; whatever it grabbed on touch-down owns it until it lifts, so
##    dragging or releasing one finger can never disturb another;
##  - a touch-down is offered to the buttons first (topmost wins), then to the
##    stick zone if no finger already holds the stick, and otherwise becomes a
##    look drag. Buttons therefore cannot be "eaten" by the look surface and the
##    look surface cannot be "eaten" by the buttons;
##  - events are taken in `_unhandled_input`, so any real Control above this
##    layer (buy menu, scoreboard, pause) consumes its touches first, and every
##    node in this scene keeps MOUSE_FILTER_IGNORE so the HUD above stays
##    clickable.
##
## Desktop testing works because project.godot enables
## `input_devices/pointing/emulate_touch_from_mouse`, so a mouse drag arrives as
## touch index 0.

signal layout_changed(hud_id: String)

const MAX_TOUCHES := 10

const KIND_NONE := 0
const KIND_STICK := 1
const KIND_LOOK := 2
const KIND_BUTTON := 3
const KIND_EDIT_MOVE := 4
const KIND_EDIT_SCALE := 5

## Extra inset applied on top of the display safe area (gesture bars, rounded
## corners) so nothing lands under a system UI element.
const EDGE_PAD := 10.0
const RAD_TO_DEG := 57.29577951308232

@export var safe_area_path: NodePath = NodePath("Safe")
@export var slot_ids: PackedStringArray = PackedStringArray(
	["slot_primary", "slot_secondary", "slot_knife", "slot_grenade"])

var _safe: Control
var _stick: VirtualStick
var _fire: TouchButton
var _fire_left: TouchButton
var _jump: TouchButton
var _crouch: TouchButton
var _ads: TouchButton
var _interact: TouchButton

var _buttons: Array[TouchButton] = []
var _movables: Array[Control] = []
var _by_id: Dictionary = {}

## index -> _TouchState. Preallocated once; the state objects are reused for the
## lifetime of the scene so no touch ever allocates.
var _touches: Dictionary = {}

var _editing: bool = false
var _input_enabled: bool = true
var _ads_lit: bool = false
var _crouch_lit: bool = false
var _slot_lit: int = -1
var _safe_rect: Rect2 = Rect2()


class _TouchState extends RefCounted:
	var active: bool = false
	var kind: int = 0
	var button: TouchButton = null
	var edit_target: Control = null
	var start: Vector2 = Vector2.ZERO
	var last: Vector2 = Vector2.ZERO
	var scale0: float = 1.0
	var base_dist: float = 1.0

	func clear() -> void:
		active = false
		kind = 0  # KIND_NONE; inner classes cannot see the outer class constants.
		button = null
		edit_target = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for i in MAX_TOUCHES:
		_touches[i] = _TouchState.new()
	_safe = get_node_or_null(safe_area_path) as Control
	if _safe == null:
		_safe = self
	_safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_collect(_safe)
	_stick = _by_id.get("stick") as VirtualStick
	_fire = _by_id.get("fire") as TouchButton
	_fire_left = _by_id.get("fire_left") as TouchButton
	_jump = _by_id.get("jump") as TouchButton
	_crouch = _by_id.get("crouch") as TouchButton
	_ads = _by_id.get("ads") as TouchButton
	_interact = _by_id.get("interact") as TouchButton
	for b in _buttons:
		b.pressed.connect(_on_button_pressed.bind(b))
		b.held.connect(_on_button_held.bind(b))
	if not Settings.changed.is_connected(_on_settings_changed):
		Settings.changed.connect(_on_settings_changed)
	get_viewport().size_changed.connect(_relayout)
	resized.connect(_relayout)
	_apply_settings()
	_relayout()
	set_process(true)


func _exit_tree() -> void:
	release_all()
	if Settings.changed.is_connected(_on_settings_changed):
		Settings.changed.disconnect(_on_settings_changed)


func _collect(n: Node) -> void:
	for ch in n.get_children():
		var c := ch as Control
		if c != null:
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var b := ch as TouchButton
		if b != null:
			_buttons.append(b)
			_movables.append(b)
			_by_id[b.hud_id] = b
		else:
			var s := ch as VirtualStick
			if s != null:
				_movables.append(s)
				_by_id[s.hud_id] = s
		if ch.get_child_count() > 0:
			_collect(ch)


# --- multitouch routing -------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _input_enabled or not is_visible_in_tree():
		return
	var touch := event as InputEventScreenTouch
	if touch != null:
		if touch.pressed:
			_touch_down(touch.index, touch.position)
		else:
			_touch_up(touch.index)
		return
	var drag := event as InputEventScreenDrag
	if drag != null:
		_touch_move(drag.index, drag.position)


func _state(index: int) -> _TouchState:
	if index < 0 or index >= MAX_TOUCHES:
		return null
	return _touches[index] as _TouchState


func _touch_down(index: int, pos: Vector2) -> void:
	var st := _state(index)
	if st == null:
		return
	if st.active:
		_finish(st)
	st.start = pos
	st.last = pos
	st.kind = KIND_NONE

	if _editing:
		var target := _movable_at(pos)
		if target == null:
			return
		st.edit_target = target
		st.active = true
		if _mv_in_handle(target, pos):
			st.kind = KIND_EDIT_SCALE
			st.scale0 = _mv_scale(target)
			st.base_dist = maxf((pos - _mv_center(target)).length(), 8.0)
		else:
			st.kind = KIND_EDIT_MOVE
		_accept()
		return

	var b := _button_at(pos)
	if b != null:
		st.kind = KIND_BUTTON
		st.button = b
		st.active = true
		b.touch_down(pos)
		_accept()
		return

	if _stick != null and not _stick_owned() and _stick.contains(pos):
		st.kind = KIND_STICK
		st.active = true
		_stick.begin(pos)
		_accept()
		return

	st.kind = KIND_LOOK
	st.active = true
	_accept()


func _touch_move(index: int, pos: Vector2) -> void:
	var st := _state(index)
	if st == null or not st.active:
		return
	match st.kind:
		KIND_STICK:
			if _stick != null:
				_stick.drag(pos)
		KIND_LOOK:
			_add_look(pos - st.last)
		KIND_BUTTON:
			# Fire buttons let you keep aiming with the shooting thumb.
			if st.button != null and st.button.look_passthrough:
				_add_look(pos - st.last)
		KIND_EDIT_MOVE:
			if st.edit_target != null:
				_mv_nudge(st.edit_target, _parent_delta(pos - st.last))
		KIND_EDIT_SCALE:
			if st.edit_target != null:
				var d := (pos - _mv_center(st.edit_target)).length()
				_mv_set_scale(st.edit_target, st.scale0 * (d / st.base_dist))
	st.last = pos
	_accept()


func _touch_up(index: int) -> void:
	var st := _state(index)
	if st == null or not st.active:
		return
	_finish(st)
	_accept()


func _finish(st: _TouchState) -> void:
	match st.kind:
		KIND_STICK:
			if _stick != null:
				_stick.end()
		KIND_BUTTON:
			if st.button != null:
				st.button.touch_up()
		KIND_EDIT_MOVE, KIND_EDIT_SCALE:
			if st.edit_target != null:
				_mv_store(st.edit_target)
				layout_changed.emit(_mv_hud_id(st.edit_target))
	st.clear()


func _accept() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.set_input_as_handled()


func _add_look(delta_px: Vector2) -> void:
	InputHub.look_delta += delta_px * Settings.look_sensitivity


func _stick_owned() -> bool:
	for i in MAX_TOUCHES:
		var st: _TouchState = _touches[i]
		if st.active and st.kind == KIND_STICK:
			return true
	return false


func _button_at(pos: Vector2) -> TouchButton:
	# Reverse tree order: the button drawn last (on top) claims the finger.
	for i in range(_buttons.size() - 1, -1, -1):
		var b: TouchButton = _buttons[i]
		if b.has_point(pos):
			return b
	return null


func _movable_at(pos: Vector2) -> Control:
	for i in range(_movables.size() - 1, -1, -1):
		var c: Control = _movables[i]
		if not c.is_visible_in_tree():
			continue
		var local := c.get_global_transform_with_canvas().affine_inverse() * pos
		if Rect2(Vector2.ZERO, c.size).grow(8.0).has_point(local):
			return c
	return null


func release_all() -> void:
	for i in MAX_TOUCHES:
		var st: _TouchState = _touches[i]
		if st.active:
			_finish(st)
	if _stick != null:
		_stick.end()
	InputHub.move = Vector2.ZERO
	InputHub.fire_held = false
	InputHub.interact_held = false
	for b in _buttons:
		if b.is_held:
			b.touch_up(true)


# --- per-frame sync (no allocations) ------------------------------------------

func _process(delta: float) -> void:
	if _editing:
		return
	if _ads != null and _ads_lit != InputHub.ads_held:
		_ads_lit = InputHub.ads_held
		_ads.active = _ads_lit
	if _crouch != null and _crouch_lit != InputHub.crouch_held:
		_crouch_lit = InputHub.crouch_held
		_crouch.active = _crouch_lit
	# Holding jump keeps re-arming the one-shot so the player hops as soon as it
	# lands, the way holding space does on desktop.
	if _jump != null and _jump.is_held:
		InputHub.jump_pressed = true
	if Settings.gyro_enabled:
		_apply_gyro(delta)


## Landscape mapping: rotation about the screen-up axis yaws, about the
## screen-right axis pitches. Gyro is rad/s, and InputHub.look_delta is in
## degrees, so it is NOT scaled by look_sensitivity (a 1:1 physical turn).
func _apply_gyro(delta: float) -> void:
	var g := Input.get_gyroscope()
	if g == Vector3.ZERO:
		return
	var k := Settings.gyro_sensitivity * RAD_TO_DEG * delta
	InputHub.look_delta.x -= g.y * k
	InputHub.look_delta.y -= g.x * k


# --- button wiring ------------------------------------------------------------

func _on_button_pressed(b: TouchButton) -> void:
	if _editing:
		return
	match b.hud_id:
		"jump":
			InputHub.jump_pressed = true
		"reload":
			InputHub.reload_pressed = true
		"ads":
			InputHub.ads_held = not InputHub.ads_held
			_ads_lit = InputHub.ads_held
			b.active = _ads_lit
		"crouch":
			if Settings.crouch_is_toggle:
				InputHub.crouch_held = not InputHub.crouch_held
				_crouch_lit = InputHub.crouch_held
				b.active = _crouch_lit
		"grenade_cycle":
			InputHub.grenade_cycle_pressed = true
		_:
			var slot := slot_ids.find(b.hud_id)
			if slot >= 0:
				InputHub.switch_slot_request = slot
				set_current_slot(slot)


func _on_button_held(active: bool, b: TouchButton) -> void:
	if _editing:
		return
	match b.hud_id:
		"fire", "fire_left":
			InputHub.fire_held = _fire_down()
			b.active = active
		"interact":
			InputHub.interact_held = active
			b.active = active
		"crouch":
			if not Settings.crouch_is_toggle:
				InputHub.crouch_held = active
				_crouch_lit = active
				b.active = active


func _fire_down() -> bool:
	if _fire != null and _fire.is_held:
		return true
	if _fire_left != null and _fire_left.is_held:
		return true
	return false


# --- public API for the HUD / layout editor -----------------------------------

func get_control(hud_id: String) -> Control:
	return _by_id.get(hud_id) as Control


func set_control_visible(hud_id: String, on: bool) -> void:
	var c := get_control(hud_id)
	if c == null:
		return
	if not on:
		var b := c as TouchButton
		if b != null and b.is_held:
			b.touch_up(true)
			InputHub.fire_held = _fire_down()
	c.visible = on


func set_control_enabled(hud_id: String, on: bool) -> void:
	var b := get_control(hud_id) as TouchButton
	if b != null:
		b.disabled = not on


## Authoritative slot highlight; the player/HUD calls this after a real switch.
func set_current_slot(slot: int) -> void:
	if _slot_lit == slot:
		return
	_slot_lit = slot
	for i in slot_ids.size():
		var b := _by_id.get(slot_ids[i]) as TouchButton
		if b != null:
			b.active = i == slot


## Contextual plant/defuse button: hidden until the player is on a bomb site.
func show_interact(on: bool, label: String = "") -> void:
	if _interact == null:
		return
	if label != "" and _interact.label_text != label:
		_interact.label_text = label
		_interact.queue_redraw()
	if not on and _interact.is_held:
		_interact.touch_up(true)
		InputHub.interact_held = false
	_interact.visible = on


## Hide the whole layer (buy menu / scoreboard / death cam) and drop every
## finger so nothing stays stuck held.
func set_active(on: bool) -> void:
	if visible == on:
		return
	visible = on
	if not on:
		release_all()


func set_input_enabled(on: bool) -> void:
	_input_enabled = on
	if not on:
		release_all()


func set_editing(enabled: bool) -> void:
	if _editing == enabled:
		return
	release_all()
	_editing = enabled
	for c in _movables:
		_mv_set_editing(c, enabled)


func reset_layout() -> void:
	for c in _movables:
		_mv_reset(c)
		layout_changed.emit(_mv_hud_id(c))


func save_layout() -> void:
	for c in _movables:
		_mv_store(c)
	Settings.save_to_disk()


# --- layout -------------------------------------------------------------------

func _on_settings_changed() -> void:
	_apply_settings()
	_relayout()


func _apply_settings() -> void:
	if _fire_left != null:
		_fire_left.visible = Settings.fire_left_mirror
	if _crouch != null:
		_crouch.active = InputHub.crouch_held
	if _ads != null:
		_ads.active = InputHub.ads_held


func _relayout() -> void:
	_safe_rect = _compute_safe_rect()
	if _safe != self:
		_safe.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		_safe.position = _safe_rect.position
		_safe.size = _safe_rect.size
	for c in _movables:
		_mv_apply_layout(c)


## Display safe area in viewport pixels. DisplayServer reports it in window
## pixels, which differ from viewport pixels under the canvas_items stretch
## mode, so it is rescaled and sanity-checked before use.
func _compute_safe_rect() -> Rect2:
	var vp := get_viewport_rect().size
	var r := Rect2(Vector2.ZERO, vp)
	var win := Vector2(DisplayServer.window_get_size())
	if win.x > 1.0 and win.y > 1.0:
		var sa := Rect2(DisplayServer.get_display_safe_area())
		if sa.size.x > 1.0 and sa.size.y > 1.0:
			var s := Vector2(vp.x / win.x, vp.y / win.y)
			var conv := Rect2(sa.position * s, sa.size * s).intersection(r)
			if conv.size.x >= vp.x * 0.5 and conv.size.y >= vp.y * 0.5:
				r = conv
	return r.grow(-EDGE_PAD * Settings.hud_scale)


func _parent_delta(delta_px: Vector2) -> Vector2:
	return _safe.get_global_transform_with_canvas().affine_inverse().basis_xform(delta_px)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_VISIBILITY_CHANGED:
			if not visible:
				release_all()
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			release_all()


# --- movable helpers ----------------------------------------------------------
# TouchButton and VirtualStick share an interface but not a base class, so these
# keep every call statically typed instead of duck-typing through Control.

func _mv_hud_id(c: Control) -> String:
	var b := c as TouchButton
	if b != null:
		return b.hud_id
	var s := c as VirtualStick
	if s != null:
		return s.hud_id
	return ""


func _mv_apply_layout(c: Control) -> void:
	var b := c as TouchButton
	if b != null:
		b.apply_hud_layout()
		return
	var s := c as VirtualStick
	if s != null:
		s.apply_hud_layout()


func _mv_nudge(c: Control, delta: Vector2) -> void:
	var b := c as TouchButton
	if b != null:
		b.nudge(delta)
		return
	var s := c as VirtualStick
	if s != null:
		s.nudge(delta)


func _mv_scale(c: Control) -> float:
	var b := c as TouchButton
	if b != null:
		return b.layout_scale
	var s := c as VirtualStick
	if s != null:
		return s.layout_scale
	return 1.0


func _mv_set_scale(c: Control, v: float) -> void:
	var b := c as TouchButton
	if b != null:
		b.set_layout_scale(v)
		return
	var s := c as VirtualStick
	if s != null:
		s.set_layout_scale(v)


func _mv_store(c: Control) -> void:
	var b := c as TouchButton
	if b != null:
		b.store_layout()
		return
	var s := c as VirtualStick
	if s != null:
		s.store_layout()


func _mv_reset(c: Control) -> void:
	var b := c as TouchButton
	if b != null:
		b.reset_layout()
		return
	var s := c as VirtualStick
	if s != null:
		s.reset_layout()


func _mv_set_editing(c: Control, on: bool) -> void:
	var b := c as TouchButton
	if b != null:
		b.set_editing(on)
		return
	var s := c as VirtualStick
	if s != null:
		s.set_editing(on)


func _mv_in_handle(c: Control, pos: Vector2) -> bool:
	var b := c as TouchButton
	if b != null:
		return b.is_in_resize_handle(pos)
	var s := c as VirtualStick
	if s != null:
		return s.is_in_resize_handle(pos)
	return false


func _mv_center(c: Control) -> Vector2:
	return c.get_global_transform_with_canvas() * (c.size * 0.5)
