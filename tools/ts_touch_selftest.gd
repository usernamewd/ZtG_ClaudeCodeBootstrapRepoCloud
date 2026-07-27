extends Node
## Drives scenes/ui/touch_controls.tscn with synthetic multitouch and asserts the
## resulting InputHub state. Runs as a SCENE (not `--script`) so the autoloads
## the touch controls talk to are registered before anything compiles.
##
##   godot --headless --path . tools/ts_touch_selftest.tscn
##   godot --headless --path . tools/ts_touch_selftest.tscn -- shot out.png
##
## In "shot" mode it holds a stick drag + fire + ADS and captures a frame, which
## is how the drawing is verified to be visible rather than just parseable.

const SCENE := "res://scenes/ui/touch_controls.tscn"

var _tc: TouchControls
var _fail: int = 0
var _frames: int = 0
var _shot_path: String = ""
var _shot_frames: int = 0
var _layout_events: PackedStringArray = PackedStringArray()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2 and String(args[0]) == "shot":
		_shot_path = String(args[1])
	var packed: PackedScene = load(SCENE)
	if packed == null:
		printerr("[touch] cannot load ", SCENE)
		get_tree().quit(1)
		return
	_tc = packed.instantiate() as TouchControls
	if _tc == null:
		printerr("[touch] root is not a TouchControls")
		get_tree().quit(1)
		return
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	layer.add_child(_tc)
	_tc.layout_changed.connect(func(id: String) -> void: _layout_events.append(id))


func _process(_delta: float) -> void:
	_frames += 1
	if _shot_path != "":
		if _frames == 2:
			_pose_for_shot()
		if _frames >= 2:
			_shot_frames += 1
			if _shot_frames >= 12:
				var img := get_viewport().get_texture().get_image()
				var err := img.save_png(_shot_path)
				print("[touch] shot ", _shot_path, " err=", err, " ",
					img.get_width(), "x", img.get_height())
				get_tree().quit(0 if err == OK else 1)
		return
	if _frames < 2:
		return
	_run()
	print("[touch] failures: ", _fail)
	get_tree().quit(0 if _fail == 0 else 1)


# --- helpers ------------------------------------------------------------------

func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	get_viewport().push_input(e, true)


func _drag(index: int, from: Vector2, to: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = to
	e.relative = to - from
	get_viewport().push_input(e, true)


func _ck(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  ", label)
	else:
		_fail += 1
		printerr("  FAIL  ", label)


func _near(a: Vector2, b: Vector2, eps: float = 0.02) -> bool:
	return a.distance_to(b) <= eps


func _centre(c: Control) -> Vector2:
	return c.get_global_transform_with_canvas() * (c.size * 0.5)


func _btn(id: String) -> TouchButton:
	return _tc.get_control(id) as TouchButton


func _tap(id: String) -> void:
	var b := _btn(id)
	_touch(7, _centre(b), true)


func _untap() -> void:
	_touch(7, Vector2.ZERO, false)


# --- the suite ----------------------------------------------------------------

func _run() -> void:
	InputHub.reset()
	var vp := get_viewport().get_visible_rect().size
	print("[touch] viewport ", vp, "  scale ", Settings.hud_scale)

	var stick := _tc.get_control("stick") as VirtualStick
	var fire := _btn("fire")
	var ads := _btn("ads")
	var jump := _btn("jump")
	_ck(stick != null and fire != null and ads != null and jump != null,
		"scene exposes stick + fire + ads + jump by hud_id")

	# --- structure ---
	_ck(_tc.mouse_filter == Control.MOUSE_FILTER_IGNORE, "root never blocks the HUD (filter IGNORE)")
	var blockers := 0
	var movables := 0
	for n in _tc.find_children("*", "Control", true, false):
		var c := n as Control
		if c.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			blockers += 1
	_ck(blockers == 0, "every child Control is MOUSE_FILTER_IGNORE")
	for n in get_tree().get_nodes_in_group("hud_movable"):
		movables += 1
		var c := n as Control
		var ok := c.has_meta("hud_id") and String(c.get_meta("hud_id")) != "" \
			and c.has_meta("hud_default_pos") and c.has_meta("hud_default_size") \
			and c.has_meta("hud_anchor")
		if not ok:
			_ck(false, "movable %s carries hud_id/default metadata" % c.name)
	_ck(movables == 13, "13 controls in group hud_movable (got %d)" % movables)

	# --- stick ---
	var srect := Rect2(stick.get_global_transform_with_canvas() * Vector2.ZERO, stick.size)
	var sp := srect.position + Vector2(srect.size.x * 0.35, srect.size.y * 0.60)
	var r := stick.radius_px()
	_ck(is_equal_approx(r, 120.0 * Settings.hud_scale), "stick radius is 120 * hud_scale (%.1f)" % r)
	_touch(0, sp, true)
	_ck(_near(InputHub.move, Vector2.ZERO), "touch-down alone does not move")
	_drag(0, sp, sp + Vector2(r, 0.0))
	_ck(_near(InputHub.move, Vector2(1.0, 0.0)), "full-right drag -> move (1,0), got %v" % InputHub.move)
	_drag(0, sp + Vector2(r, 0.0), sp + Vector2(0.0, -r))
	_ck(_near(InputHub.move, Vector2(0.0, 1.0)), "full-up drag -> move (0,1) forward, got %v" % InputHub.move)
	_drag(0, sp + Vector2(0.0, -r), sp + Vector2(0.0, -r * 3.0))
	_ck(_near(InputHub.move, Vector2(0.0, 1.0)), "past the ring stays clamped to length 1")
	_drag(0, sp + Vector2(0.0, -r * 3.0), sp + Vector2(r * 0.05, 0.0))
	_ck(_near(InputHub.move, Vector2.ZERO), "inside the deadzone -> zero")
	_drag(0, sp + Vector2(r * 0.05, 0.0), sp + Vector2(0.0, -r))
	_ck(_near(InputHub.move, Vector2(0.0, 1.0)), "re-drag after deadzone works")

	# --- look surface, independent of the stick ---
	var look_pt := Vector2(vp.x * 0.62, vp.y * 0.34)
	var free := true
	for n in get_tree().get_nodes_in_group("hud_movable"):
		var c := n as Control
		if c.is_visible_in_tree() and Rect2(c.get_global_transform_with_canvas() * Vector2.ZERO,
				c.size).grow(8.0).has_point(look_pt):
			free = false
	_ck(free, "chosen look point is not over any control")
	InputHub.consume_look()
	_touch(1, look_pt, true)
	_ck(InputHub.look_delta == Vector2.ZERO, "look touch-down alone does not turn")
	_drag(1, look_pt, look_pt + Vector2(100.0, 40.0))
	var want := Vector2(100.0, 40.0) * Settings.look_sensitivity
	_ck(_near(InputHub.look_delta, want, 0.001), "look drag -> px * look_sensitivity %v" % InputHub.look_delta)
	_ck(_near(InputHub.move, Vector2(0.0, 1.0)), "look finger did not disturb the stick")

	# --- fire, while both other fingers stay down ---
	_touch(2, _centre(fire), true)
	_ck(InputHub.fire_held, "fire button -> fire_held")
	_ck(_near(InputHub.move, Vector2(0.0, 1.0)), "fire press did not disturb the stick")
	InputHub.consume_look()
	_drag(2, _centre(fire), _centre(fire) + Vector2(20.0, 0.0))
	_ck(_near(InputHub.look_delta, Vector2(20.0 * Settings.look_sensitivity, 0.0), 0.001),
		"dragging the fire thumb steers the camera (look_passthrough)")
	_ck(InputHub.fire_held, "fire stays held while dragging")
	InputHub.consume_look()
	_drag(1, look_pt + Vector2(100.0, 40.0), look_pt + Vector2(100.0, 90.0))
	_ck(_near(InputHub.look_delta, Vector2(0.0, 50.0 * Settings.look_sensitivity), 0.001),
		"look finger still steers after the other fingers moved")
	_ck(InputHub.fire_held and _near(InputHub.move, Vector2(0.0, 1.0)),
		"three fingers coexist: stick + look + fire")

	# --- lifting one finger leaves the others alone ---
	_touch(0, sp + Vector2(0.0, -r), false)
	_ck(_near(InputHub.move, Vector2.ZERO), "releasing the stick zeroes move")
	_ck(InputHub.fire_held, "releasing the stick did not release fire")
	InputHub.consume_look()
	_drag(1, look_pt + Vector2(100.0, 90.0), look_pt + Vector2(120.0, 90.0))
	_ck(_near(InputHub.look_delta, Vector2(20.0 * Settings.look_sensitivity, 0.0), 0.001),
		"look survives the stick release")
	_touch(2, _centre(fire), false)
	_ck(not InputHub.fire_held, "releasing fire clears fire_held")
	_touch(1, look_pt + Vector2(120.0, 90.0), false)

	# --- a second finger in the stick zone must not steal the stick ---
	_touch(0, sp, true)
	_drag(0, sp, sp + Vector2(r, 0.0))
	_ck(_near(InputHub.move, Vector2(1.0, 0.0)), "stick owned by finger 0")
	var sp2 := srect.position + Vector2(srect.size.x * 0.75, srect.size.y * 0.20)
	InputHub.consume_look()
	_touch(3, sp2, true)
	_drag(3, sp2, sp2 + Vector2(60.0, 0.0))
	_ck(_near(InputHub.look_delta, Vector2(60.0 * Settings.look_sensitivity, 0.0), 0.001),
		"a second finger in the stick zone becomes a look drag")
	_ck(_near(InputHub.move, Vector2(1.0, 0.0)), "the stick keeps its own finger")
	_touch(3, sp2 + Vector2(60.0, 0.0), false)
	_touch(0, sp + Vector2(r, 0.0), false)

	# --- one-shots and toggles ---
	_tap("jump")
	_ck(InputHub.jump_pressed and InputHub.consume_jump() and not InputHub.jump_pressed,
		"jump -> one-shot jump_pressed")
	_untap()
	_tap("reload")
	_ck(InputHub.reload_pressed and InputHub.consume_reload(), "reload -> one-shot reload_pressed")
	_untap()
	_tap("grenade_cycle")
	_ck(InputHub.grenade_cycle_pressed, "grenade cycle -> grenade_cycle_pressed")
	InputHub.consume_grenade_cycle()
	_untap()

	_ck(not InputHub.ads_held, "ads starts off")
	_tap("ads")
	_ck(InputHub.ads_held and ads.active, "ads tap toggles ads_held on and lights the button")
	_untap()
	_tap("ads")
	_ck(not InputHub.ads_held and not ads.active, "ads tap again toggles off")
	_untap()

	var crouch := _btn("crouch")
	Settings.crouch_is_toggle = true
	InputHub.crouch_held = false
	_tap("crouch")
	_ck(InputHub.crouch_held, "crouch (toggle mode) latches crouch_held")
	_untap()
	_ck(InputHub.crouch_held, "crouch stays latched after the finger lifts")
	_tap("crouch")
	_ck(not InputHub.crouch_held, "second crouch tap unlatches")
	_untap()
	Settings.crouch_is_toggle = false
	_tap("crouch")
	_ck(InputHub.crouch_held and crouch.active, "crouch (hold mode) holds while down")
	_untap()
	_ck(not InputHub.crouch_held, "crouch (hold mode) releases on lift")
	Settings.crouch_is_toggle = true

	var interact := _btn("interact")
	_tap("interact")
	_ck(InputHub.interact_held and interact.active, "interact holds interact_held")
	_untap()
	_ck(not InputHub.interact_held, "interact clears on lift")

	for i in 4:
		var id: String = String(_tc.slot_ids[i])
		_tap(id)
		_ck(InputHub.switch_slot_request == i and InputHub.consume_switch() == i,
			"%s -> switch_slot_request %d" % [id, i])
		_ck(_btn(id).active, "%s lights as the current slot" % id)
		_untap()
	_ck(_btn("slot_primary").active == false, "only the newest slot stays lit")

	# --- buttons vs look must not fight ---
	InputHub.consume_look()
	_touch(4, look_pt, true)
	_drag(4, look_pt, _centre(fire))
	_ck(not InputHub.fire_held and not fire.is_held,
		"a look drag passing over fire never presses it")
	_touch(4, _centre(fire), false)
	_ck(not InputHub.fire_held, "release over fire still does not press it")
	InputHub.consume_look()
	_touch(4, _centre(ads), true)
	_drag(4, _centre(ads), _centre(ads) + Vector2(30.0, 30.0))
	_ck(InputHub.look_delta == Vector2.ZERO, "dragging a non-passthrough button never turns the camera")
	_touch(4, _centre(ads) + Vector2(30.0, 30.0), false)
	InputHub.ads_held = false
	ads.active = false

	# --- Settings.hud_layout override ---
	var def_pos := jump.position
	var def_size := jump.size
	Settings.hud_layout["jump"] = {"pos": Vector2(-520.0, -320.0), "scale": 1.4}
	jump.apply_hud_layout()
	_ck(_near(jump.size, (def_size * 1.4).round(), 1.5), "hud_layout scale resizes the button")
	_ck(not _near(jump.position, def_pos, 1.0), "hud_layout pos moves the button")
	_touch(5, _centre(jump), true)
	_ck(InputHub.jump_pressed, "the moved button is hit at its new position")
	InputHub.consume_jump()
	_touch(5, _centre(jump), false)
	_touch(5, def_pos + def_size * 0.5, true)
	_ck(not InputHub.jump_pressed, "the vacated default position no longer fires jump")
	_touch(5, def_pos + def_size * 0.5, false)
	Settings.hud_layout.erase("jump")
	jump.apply_hud_layout()
	_ck(_near(jump.position, def_pos, 1.0) and _near(jump.size, def_size, 1.0),
		"clearing the override restores the default placement")

	# --- a layout that survived the JSON save file (Vector2 -> "(x, y)") ---
	Settings.hud_layout["jump"] = {"pos": "(-480.0, -300.0)", "scale": 1.2}
	jump.apply_hud_layout()
	_ck(_near(jump.size, (def_size * 1.2).round(), 1.5) and not _near(jump.position, def_pos, 1.0),
		"a JSON-round-tripped pos string still positions the button")
	Settings.hud_layout.erase("jump")
	jump.apply_hud_layout()

	# --- fire_left mirror follows Settings ---
	var fl := _btn("fire_left")
	_ck(not fl.visible, "mirrored left fire hidden by default")
	Settings.fire_left_mirror = true
	Settings.changed.emit()
	_ck(fl.visible, "Settings.fire_left_mirror shows the mirrored fire")
	_touch(6, _centre(fl), true)
	_ck(InputHub.fire_held, "mirrored fire drives fire_held")
	_touch(6, _centre(fl), false)
	_ck(not InputHub.fire_held, "mirrored fire releases")
	Settings.fire_left_mirror = false
	Settings.changed.emit()

	# --- losing the layer must not leave anything stuck ---
	_touch(0, _centre(fire), true)
	_touch(1, sp, true)
	_drag(1, sp, sp + Vector2(0.0, -r))
	_ck(InputHub.fire_held and _near(InputHub.move, Vector2(0.0, 1.0)), "held state before hide")
	_tc.set_active(false)
	_ck(not InputHub.fire_held and _near(InputHub.move, Vector2.ZERO) and not fire.is_held,
		"hiding the layer releases every finger")
	_tc.set_active(true)

	# --- edit mode ---
	_layout_events.clear()
	_tc.set_editing(true)
	var before := jump.position
	_touch(0, _centre(jump), true)
	_drag(0, _centre(jump), _centre(jump) + Vector2(-40.0, -30.0))
	_touch(0, _centre(jump), false)
	_ck(_near(jump.position, before + Vector2(-40.0, -30.0), 1.5),
		"edit mode drags the button (%v -> %v)" % [before, jump.position])
	_ck(_layout_events.has("jump"), "edit drag emits layout_changed(hud_id)")
	_ck(Settings.hud_layout.has("jump"), "edit drag stores pos/scale in Settings.hud_layout")
	_ck(not InputHub.fire_held and InputHub.move == Vector2.ZERO and InputHub.look_delta == Vector2.ZERO,
		"edit mode writes nothing to InputHub")
	var h := jump.size
	_touch(0, jump.get_global_transform_with_canvas() * (jump.size - Vector2(6.0, 6.0)), true)
	_drag(0, jump.get_global_transform_with_canvas() * (jump.size - Vector2(6.0, 6.0)),
		jump.get_global_transform_with_canvas() * (jump.size + Vector2(40.0, 40.0)))
	_touch(0, Vector2.ZERO, false)
	_ck(jump.size.x > h.x, "the corner handle resizes the button (%v -> %v)" % [h, jump.size])
	_tc.reset_layout()
	_ck(not Settings.hud_layout.has("jump") and _near(jump.position, def_pos, 1.0),
		"reset_layout clears overrides and restores defaults")
	_tc.set_editing(false)

	# --- hud_scale ---
	var s0 := jump.size
	Settings.hud_scale = 1.25
	Settings.changed.emit()
	_ck(_near(jump.size, (s0 * 1.25).round(), 1.5), "hud_scale rescales buttons (%v)" % jump.size)
	_ck(is_equal_approx(stick.radius_px(), 150.0), "hud_scale rescales the stick radius (%.1f)"
		% stick.radius_px())
	Settings.hud_scale = 1.0
	Settings.changed.emit()
	_ck(_near(jump.size, s0, 1.5), "hud_scale restores")

	# --- a freshly instantiated copy applies hud_layout in _ready ---
	Settings.hud_layout["fire"] = {"pos": Vector2(-420.0, -260.0), "scale": 0.8}
	var packed: PackedScene = load(SCENE)
	var second := packed.instantiate() as TouchControls
	add_child(second)
	var f2 := second.get_control("fire") as TouchButton
	_ck(_near(f2.size, (fire.base_size * 0.8).round(), 1.5),
		"_ready applies Settings.hud_layout scale (%v)" % f2.size)
	_ck(not _near(f2.position, fire.position, 1.0), "_ready applies Settings.hud_layout pos")
	remove_child(second)
	second.free()
	Settings.hud_layout.erase("fire")
	InputHub.reset()

	# --- API used by the HUD ---
	_tc.show_interact(false)
	_ck(not interact.visible, "show_interact(false) hides the plant/defuse button")
	_tc.show_interact(true, "DEFUSE")
	_ck(interact.visible and interact.label_text == "DEFUSE", "show_interact relabels and shows")
	_tc.set_control_enabled("fire", false)
	_touch(0, _centre(fire), true)
	_ck(not InputHub.fire_held, "a disabled button ignores touches")
	_touch(0, _centre(fire), false)
	_tc.set_control_enabled("fire", true)
	InputHub.reset()


func _pose_for_shot() -> void:
	Settings.fire_left_mirror = false
	var stick := _tc.get_control("stick") as VirtualStick
	var fire := _btn("fire")
	var srect := Rect2(stick.get_global_transform_with_canvas() * Vector2.ZERO, stick.size)
	var sp := srect.position + Vector2(srect.size.x * 0.35, srect.size.y * 0.60)
	var r := stick.radius_px()
	_touch(0, sp, true)
	_drag(0, sp, sp + Vector2(r * 0.75, -r * 0.55))
	_touch(1, _centre(fire), true)
	_tc.show_interact(true, "DEFUSE")
	_tc.set_current_slot(0)
	InputHub.ads_held = true
