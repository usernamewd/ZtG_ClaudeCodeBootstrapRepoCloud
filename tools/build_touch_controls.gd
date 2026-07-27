extends SceneTree
## Builds scenes/ui/touch_controls.tscn from code so the default landscape layout
## stays reproducible and every node keeps its hud_id / anchor metadata.
##   godot --headless --path . --script tools/build_touch_controls.gd
##
## Layout is authored as (anchor, offset) pairs against the safe-area rect, not
## as absolute pixels: TouchControls resizes the "Safe" child to the display safe
## area and each control re-derives its position from its own anchor, so the same
## defaults work on any phone aspect. Offsets are unscaled — Settings.hud_scale
## and the per-control layout scale multiply them at runtime.

const OUT_PATH := "res://scenes/ui/touch_controls.tscn"
const TC_SCRIPT := "res://src/ui/touch_controls.gd"
const STICK_SCRIPT := "res://src/ui/virtual_stick.gd"
const BTN_SCRIPT := "res://src/ui/touch_button.gd"

# Must match TouchButton.Icon.
const ICON_NONE := 0
const ICON_FIRE := 1
const ICON_ADS := 2
const ICON_JUMP := 3
const ICON_CROUCH := 4
const ICON_RELOAD := 5
const ICON_INTERACT := 6
const ICON_RIFLE := 7
const ICON_PISTOL := 8
const ICON_KNIFE := 9
const ICON_GRENADE := 10
const ICON_GRENADE_CYCLE := 11

const BR := Vector2(1.0, 1.0)
const BL := Vector2(0.0, 1.0)
const TR := Vector2(1.0, 0.0)
const BC := Vector2(0.5, 1.0)

var _root: Control
var _safe: Control
var _btn_script: Script
var _done := false


## Autoloads only exist on the SceneTree after _init() returns, and these scripts
## reference Settings/InputHub, so build on the first frame instead.
func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_build()
	return true


func _build() -> void:
	var tc_script := load(TC_SCRIPT) as Script
	var stick_script := load(STICK_SCRIPT) as Script
	_btn_script = load(BTN_SCRIPT) as Script
	if tc_script == null or stick_script == null or _btn_script == null:
		printerr("missing one of the touch control scripts — refusing to write a scriptless scene")
		quit(1)
		return

	_root = Control.new()
	_root.name = "TouchControls"
	_root.set_script(tc_script)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.set("safe_area_path", NodePath("Safe"))

	_safe = Control.new()
	_safe.name = "Safe"
	_safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_safe)
	_safe.owner = _root

	# Left hand: movement zone (left 40%, lower 78% of the safe area).
	var stick := Control.new()
	stick.name = "Stick"
	stick.set_script(stick_script)
	stick.set("hud_id", "stick")
	stick.set("radius", 120.0)
	stick.set("deadzone", 0.14)
	stick.set("dynamic_origin", true)
	stick.set("zone_ratio", Vector2(0.40, 0.78))
	stick.set("hud_anchor", BL)
	stick.set("hud_offset", Vector2(0.0, 0.0))
	_safe.add_child(stick)
	stick.owner = _root

	# Right hand: fire cluster. Fire is the largest target and sits under the
	# resting thumb; everything else rings it without overlapping.
	_button("Fire", "fire", ICON_FIRE, Vector2(168.0, 168.0), BR, Vector2(-28.0, -28.0),
		true, "", true)
	_button("Ads", "ads", ICON_ADS, Vector2(96.0, 96.0), BR, Vector2(-212.0, -96.0),
		true, "ADS")
	_button("Crouch", "crouch", ICON_CROUCH, Vector2(96.0, 96.0), BR, Vector2(-212.0, -204.0))
	_button("Jump", "jump", ICON_JUMP, Vector2(96.0, 96.0), BR, Vector2(-56.0, -220.0))
	_button("Reload", "reload", ICON_RELOAD, Vector2(88.0, 88.0), BR, Vector2(-336.0, -40.0))

	# Plant/defuse: centre-bottom, reachable with either thumb, labelled because
	# the action changes with the round state.
	_button("Interact", "interact", ICON_INTERACT, Vector2(136.0, 96.0), BC, Vector2(0.0, -22.0),
		false, "USE")

	# Mirrored fire for left-handed players (Settings.fire_left_mirror). Sits
	# above the stick's resting ring so it does not steal its travel.
	var fl := _button("FireLeft", "fire_left", ICON_FIRE, Vector2(132.0, 132.0), BL,
		Vector2(20.0, -292.0), true, "", true)
	fl.visible = false

	# Weapon strip, top-right, in slot order primary/secondary/knife/grenade.
	_button("SlotPrimary", "slot_primary", ICON_RIFLE, Vector2(78.0, 62.0), TR,
		Vector2(-282.0, 22.0), false)
	_button("SlotSecondary", "slot_secondary", ICON_PISTOL, Vector2(78.0, 62.0), TR,
		Vector2(-196.0, 22.0), false)
	_button("SlotKnife", "slot_knife", ICON_KNIFE, Vector2(78.0, 62.0), TR,
		Vector2(-110.0, 22.0), false)
	_button("SlotGrenade", "slot_grenade", ICON_GRENADE, Vector2(78.0, 62.0), TR,
		Vector2(-24.0, 22.0), false)
	_button("GrenadeCycle", "grenade_cycle", ICON_GRENADE_CYCLE, Vector2(78.0, 56.0), TR,
		Vector2(-24.0, 92.0), false)

	var packed := PackedScene.new()
	var err := packed.pack(_root)
	if err != OK:
		printerr("pack failed: ", err)
		quit(1)
		return
	err = ResourceSaver.save(packed, OUT_PATH)
	if err != OK:
		printerr("save failed: ", err)
		quit(1)
		return
	print("wrote ", OUT_PATH, " (", _count(_root), " nodes)")
	_root.free()
	quit(0)


func _button(node_name: String, hud_id: String, icon: int, base_size: Vector2,
		anchor: Vector2, offset: Vector2, round_shape: bool = true, label: String = "",
		look_passthrough: bool = false) -> Control:
	var b := Control.new()
	b.name = node_name
	b.set_script(_btn_script)
	b.set("hud_id", hud_id)
	b.set("icon", icon)
	b.set("base_size", base_size)
	b.set("hud_anchor", anchor)
	b.set("hud_offset", offset)
	b.set("round_shape", round_shape)
	b.set("label_text", label)
	b.set("look_passthrough", look_passthrough)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.size = base_size
	_safe.add_child(b)
	b.owner = _root
	return b


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
