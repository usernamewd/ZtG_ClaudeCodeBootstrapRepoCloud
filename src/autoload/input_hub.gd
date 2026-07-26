extends Node
## Bridge between input surfaces (touch UI, keyboard/mouse debug) and the
## player controller. Touch controls write state; the player consumes it once
## per physics tick. See docs/ARCHITECTURE.md.

var move: Vector2 = Vector2.ZERO
var look_delta: Vector2 = Vector2.ZERO
var fire_held: bool = false
var ads_held: bool = false
var crouch_held: bool = false
var interact_held: bool = false
var jump_pressed: bool = false
var reload_pressed: bool = false
var grenade_cycle_pressed: bool = false
var switch_slot_request: int = -1

var _mouse_captured: bool = false


func consume_look() -> Vector2:
	var d := look_delta
	look_delta = Vector2.ZERO
	return d


func consume_jump() -> bool:
	var v := jump_pressed
	jump_pressed = false
	return v


func consume_reload() -> bool:
	var v := reload_pressed
	reload_pressed = false
	return v


func consume_switch() -> int:
	var v := switch_slot_request
	switch_slot_request = -1
	return v


func consume_grenade_cycle() -> bool:
	var v := grenade_cycle_pressed
	grenade_cycle_pressed = false
	return v


func reset() -> void:
	move = Vector2.ZERO
	look_delta = Vector2.ZERO
	fire_held = false
	ads_held = false
	interact_held = false
	jump_pressed = false
	reload_pressed = false
	grenade_cycle_pressed = false
	switch_slot_request = -1


# ---- Desktop debug input (editor / xvfb testing only) ----

func _input(event: InputEvent) -> void:
	if OS.has_feature("mobile"):
		return
	if event is InputEventMouseMotion and _mouse_captured:
		look_delta += event.relative * Settings.look_sensitivity
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not _mouse_captured:
			_mouse_captured = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey:
		if event.keycode == KEY_ESCAPE and event.pressed:
			_mouse_captured = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(_dt: float) -> void:
	if OS.has_feature("mobile"):
		return
	# Keyboard movement for debug builds on desktop.
	var kb := Vector2.ZERO
	kb.x = ((1.0 if Input.is_physical_key_pressed(KEY_D) else 0.0)
		- (1.0 if Input.is_physical_key_pressed(KEY_A) else 0.0))
	kb.y = ((1.0 if Input.is_physical_key_pressed(KEY_W) else 0.0)
		- (1.0 if Input.is_physical_key_pressed(KEY_S) else 0.0))
	if kb != Vector2.ZERO or _mouse_captured:
		move = kb.limit_length(1.0)
	if _mouse_captured:
		fire_held = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		ads_held = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if Input.is_physical_key_pressed(KEY_SPACE):
		jump_pressed = true
	crouch_held = Input.is_physical_key_pressed(KEY_C)
	if Input.is_physical_key_pressed(KEY_R):
		reload_pressed = true
	for i in 4:
		if Input.is_physical_key_pressed(KEY_1 + i):
			switch_slot_request = i
