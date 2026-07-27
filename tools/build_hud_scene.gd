extends SceneTree
## Builds scenes/ui/hud.tscn from code so the in-match HUD stays reproducible.
##   godot --headless --path . --script tools/build_hud_scene.gd
##
## Node order inside Root matters and is the reason this file exists:
##   1. TouchControls  — instanced first so it draws UNDER everything and its
##                       buttons are never covered by a readout;
##   2. Reticle        — crosshair stack, screen centre;
##   3. Widgets        — health / ammo / FPS, populated by src/ui/hud.gd at run
##                       time because those widgets paint themselves;
##   4. Phase4         — empty named slots the Phase 4 widgets attach into.
## Every node here is MOUSE_FILTER_IGNORE: the HUD shows, the touch layer feels.
##
## Like tools/build_touch_controls.gd this builds on the first frame rather than
## in _init(), because autoload singletons (Settings, AudioMgr) only exist on the
## SceneTree once _init() has returned and the HUD scripts reference them.

const OUT_PATH := "res://scenes/ui/hud.tscn"
const HUD_SCRIPT := "res://src/ui/hud.gd"
const CROSSHAIR_SCRIPT := "res://src/ui/crosshair.gd"
const HITMARKER_SCRIPT := "res://src/ui/hit_marker.gd"
const DAMAGE_SCRIPT := "res://src/ui/damage_indicator.gd"
const TOUCH_SCENE := "res://scenes/ui/touch_controls.tscn"

## Phase 4 attachment points. Empty full-rect Controls, so each widget can anchor
## itself however it likes: hud.phase4_slot("Radar").add_child(radar).
const PHASE4_SLOTS := ["Radar", "RoundBar", "KillFeed", "Money", "Alerts",
	"Objective"]

var _root: CanvasLayer = null
var _done := false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_build()
	return true


func _build() -> void:
	var hud_script := load(HUD_SCRIPT) as Script
	var crosshair_script := load(CROSSHAIR_SCRIPT) as Script
	var hitmarker_script := load(HITMARKER_SCRIPT) as Script
	var damage_script := load(DAMAGE_SCRIPT) as Script
	if hud_script == null or crosshair_script == null \
			or hitmarker_script == null or damage_script == null:
		printerr("missing a HUD script — refusing to write a scriptless scene")
		quit(1)
		return

	_root = CanvasLayer.new()
	_root.name = "HUD"
	_root.layer = 1
	_root.set_script(hud_script)

	var root_control := Control.new()
	root_control.name = "Root"
	_add(root_control, _root)

	# 1. Touch layer, underneath everything else.
	if ResourceLoader.exists(TOUCH_SCENE):
		var packed_touch: PackedScene = load(TOUCH_SCENE)
		if packed_touch != null:
			var touch := packed_touch.instantiate()
			touch.name = "TouchControls"
			root_control.add_child(touch)
			touch.owner = _root
	else:
		printerr("note: %s not on disk yet; hud.tscn will be built without it"
			% TOUCH_SCENE)

	# 2. Reticle stack. Damage arcs sit behind the crosshair, the hit marker in
	#    front of it, so a kill flash is never hidden by the reticle lines.
	var reticle := Control.new()
	reticle.name = "Reticle"
	_add(reticle, root_control)
	_add(_scripted("DamageIndicator", damage_script), reticle)
	_add(_scripted("Crosshair", crosshair_script), reticle)
	_add(_scripted("HitMarker", hitmarker_script), reticle)

	# 3. Readouts (filled in by HUD._ready).
	_add(_plain("Widgets"), root_control)

	# 4. Phase 4 slots.
	var phase4 := _plain("Phase4")
	_add(phase4, root_control)
	for slot_name in PHASE4_SLOTS:
		_add(_plain(String(slot_name)), phase4)

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
	print("wrote ", OUT_PATH, "  (", _count(_root), " nodes)")
	_root.free()
	quit(0)


func _plain(node_name: String) -> Control:
	var c := Control.new()
	c.name = node_name
	return c


func _scripted(node_name: String, script: Script) -> Control:
	var c := Control.new()
	c.name = node_name
	c.set_script(script)
	return c


## Full-rect, input-transparent, owned by the scene root so pack() keeps it.
func _add(c: Control, parent: Node) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(c)
	c.owner = _root


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
