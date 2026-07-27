class_name HUD
extends CanvasLayer
## The in-match combat HUD.
##
## Layout (scenes/ui/hud.tscn, built by tools/build_hud_scene.gd):
##   HUD                  CanvasLayer, this script
##     Root               full-rect Control, carries the shared HUD theme
##       TouchControls    scenes/ui/touch_controls.tscn — FIRST child, so every
##                        informational widget above it draws on top while the
##                        controls keep the input (all widgets are
##                        MOUSE_FILTER_IGNORE and never eat a touch)
##       Reticle          DamageIndicator / Crosshair / HitMarker, screen centre
##       Widgets          vitals, ammo and the FPS readout (built in code)
##       Phase4           empty, named slots the Phase 4 widgets attach into
##
## Everything reacts to signals; nothing polls the player. `_process` is off on
## this node, the crosshair only repaints when its gap actually moves, and the
## panels only repaint when a displayed number changes, so a quiet HUD costs a
## handful of draw calls and zero allocations per frame.
##
## Entry point: `bind_player(p)` — MatchController calls it right after
## instantiating this scene.

const ROOT_PATH := ^"Root"
const TOUCH_PATH := ^"Root/TouchControls"
const RETICLE_PATH := ^"Root/Reticle"
const CROSSHAIR_PATH := ^"Root/Reticle/Crosshair"
const HITMARKER_PATH := ^"Root/Reticle/HitMarker"
const DAMAGE_PATH := ^"Root/Reticle/DamageIndicator"
const WIDGETS_PATH := ^"Root/Widgets"
const PHASE4_PATH := ^"Root/Phase4"

# --- shared HUD skin ----------------------------------------------------------
# Phase 4 widgets (radar, round bar, kill feed, money, alerts) should paint with
# these plus UITheme so the whole readout stays one system. Deliberately darker
# and more translucent than UITheme.PANEL: a menu panel sits on a flat
# background, a HUD panel sits on the game.
#
# The values and the painters live on HudWidget because a GDScript inner class
# cannot see its outer class's scope; these aliases are the public spelling.

const PANEL_BG := HudWidget.PANEL_BG
const PANEL_EDGE := HudWidget.PANEL_EDGE
const MARK_WIDTH := HudWidget.MARK_WIDTH

# --- player / weapon interface (all optional, probed with has_method) ---------

const M_HEALTH := &"get_health"
const M_MAX_HEALTH := &"get_max_health"
const M_ARMOR := &"get_armor"
const M_HELMET := &"get_helmet"
const M_WEAPON_NAME := &"get_weapon_display_name"
const M_WEAPON_NODE := &"get_weapon_node"
const M_MAG := &"get_mag_ammo"
const M_RESERVE := &"get_reserve_ammo"
const M_GRENADES := &"get_grenade_count"
const M_RELOADING := &"is_reloading"
const M_WEAPON_DEF := &"current_weapon_def"
const M_CAMERA := &"get_camera"

const S_HUD_STATE := &"hud_state_changed"
const S_WEAPON_EQUIPPED := &"weapon_equipped"
const S_HIT_MARKER := &"hit_marker"
const S_DAMAGED := &"damaged"
const S_DIED := &"died"
const S_RESPAWNED := &"respawned"

const S_AMMO_CHANGED := &"ammo_changed"
const S_RELOAD_STARTED := &"reload_started"
const S_RELOAD_FINISHED := &"reload_finished"
const S_HIT_CONFIRMED := &"hit_confirmed"

static var _theme: Theme = null

var _root: Control = null
var _touch: Control = null
var _crosshair: Crosshair = null
var _hit_marker: HitMarker = null
var _damage: DamageIndicator = null
var _widgets: Control = null
var _phase4: Control = null

var _vitals: VitalsPanel = null
var _ammo: AmmoPanel = null
var _fps: FpsReadout = null

var _player: Node = null
var _weapon: Node = null
var _use_player_hit_relay: bool = false


func _ready() -> void:
	layer = 1
	_root = get_node_or_null(ROOT_PATH) as Control
	if _root == null:
		# Tolerate being instantiated bare (tests, the layout editor's fallback).
		_root = Control.new()
		_root.name = "Root"
		_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_root)
	_root.theme = hud_theme()

	_touch = get_node_or_null(TOUCH_PATH) as Control
	_crosshair = get_node_or_null(CROSSHAIR_PATH) as Crosshair
	_hit_marker = get_node_or_null(HITMARKER_PATH) as HitMarker
	_damage = get_node_or_null(DAMAGE_PATH) as DamageIndicator
	_widgets = get_node_or_null(WIDGETS_PATH) as Control
	_phase4 = get_node_or_null(PHASE4_PATH) as Control
	if _widgets == null:
		_widgets = _make_layer("Widgets")
	if _phase4 == null:
		_phase4 = _make_layer("Phase4")

	_build_widgets()

	if not Settings.changed.is_connected(_on_settings_changed):
		Settings.changed.connect(_on_settings_changed)
	_root.resized.connect(_relayout)
	_relayout()
	set_process(false)


func _exit_tree() -> void:
	unbind_player()
	if Settings.changed.is_connected(_on_settings_changed):
		Settings.changed.disconnect(_on_settings_changed)


func _make_layer(layer_name: String) -> Control:
	var c := Control.new()
	c.name = layer_name
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(c)
	return c


func _build_widgets() -> void:
	_vitals = VitalsPanel.new()
	_vitals.name = "Vitals"
	_vitals.setup("vitals", Vector2(0.0, 1.0), Vector2(20.0, -20.0),
		Vector2(272.0, 96.0))
	_widgets.add_child(_vitals)

	# The ammo block is right-hand side, but lifted clear of the touch fire
	# cluster (fire/ADS/jump/crouch/reload reach up to 316 px off the bottom-right
	# corner in scenes/ui/touch_controls.tscn). Sitting directly above the fire
	# button keeps it out from under the thumb and short on eye travel.
	_ammo = AmmoPanel.new()
	_ammo.name = "Ammo"
	_ammo.setup("ammo", Vector2(1.0, 1.0), Vector2(-20.0, -326.0),
		Vector2(272.0, 96.0))
	_widgets.add_child(_ammo)

	_fps = FpsReadout.new()
	_fps.name = "Fps"
	_fps.setup("fps", Vector2(0.5, 0.0), Vector2(0.0, 84.0), Vector2(146.0, 44.0))
	_widgets.add_child(_fps)
	_fps.set_enabled(Settings.show_fps)


# --- shared skin --------------------------------------------------------------

## One Theme instance shared by every HUD in the process; Phase 4 widgets added
## under `Phase4` inherit it automatically.
static func hud_theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font_size = UITheme.FS_BODY
	t.set_color("font_color", "Label", UITheme.TEXT)
	t.set_font_size("font_size", "Label", UITheme.FS_SMALL)
	t.set_stylebox("panel", "Panel", panel_box())
	t.set_stylebox("panel", "PanelContainer", panel_box())
	_theme = t
	return _theme


static func panel_box() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PANEL_BG
	s.set_corner_radius_all(2)
	s.set_border_width_all(1)
	s.border_color = PANEL_EDGE
	s.set_content_margin_all(10.0)
	return s


## The HUD's panel motif: translucent slate, hairline edge, one accent rule down
## the side that faces the screen edge. Cheap enough for a `_draw` pass.
static func draw_panel(ci: CanvasItem, rect: Rect2, mark_right: bool = false,
		mark: Color = UITheme.ACCENT, mark_width: float = MARK_WIDTH) -> void:
	HudWidget.paint_panel(ci, rect, mark_right, mark, mark_width)


## Right-aligned text helper; `at` is the baseline's right end. Returns the width
## drawn so callers can stack numbers leftwards.
static func draw_text_right(ci: CanvasItem, f: Font, at: Vector2, text: String,
		font_size: int, col: Color) -> float:
	return HudWidget.paint_text_right(ci, f, at, text, font_size, col)


# --- binding ------------------------------------------------------------------

## MatchController calls this once the local player exists. Safe to call again
## with a different character (spectate, kill cam) or with null.
func bind_player(p: Node) -> void:
	if p == _player:
		return
	unbind_player()
	_player = p
	if _player == null:
		return
	_use_player_hit_relay = _player.has_signal(S_HIT_MARKER)
	_connect_to(_player, S_HUD_STATE, _refresh)
	_connect_to(_player, S_WEAPON_EQUIPPED, _on_weapon_equipped)
	_connect_to(_player, S_DAMAGED, _on_player_damaged)
	_connect_to(_player, S_DIED, _on_player_died)
	_connect_to(_player, S_RESPAWNED, _on_player_respawned)
	if _use_player_hit_relay:
		_connect_to(_player, S_HIT_MARKER, _on_hit)
	if _crosshair:
		_crosshair.set_player(_player)
		if _player.has_method(M_CAMERA):
			_crosshair.set_camera(_player.call(M_CAMERA) as Camera3D)
	var w: Node = null
	if _player.has_method(M_WEAPON_NODE):
		w = _player.call(M_WEAPON_NODE) as Node
	_bind_weapon(w)
	_set_alive(true)
	_refresh()


func unbind_player() -> void:
	_bind_weapon(null)
	if _player != null and is_instance_valid(_player):
		_disconnect_from(_player, S_HUD_STATE, _refresh)
		_disconnect_from(_player, S_WEAPON_EQUIPPED, _on_weapon_equipped)
		_disconnect_from(_player, S_DAMAGED, _on_player_damaged)
		_disconnect_from(_player, S_DIED, _on_player_died)
		_disconnect_from(_player, S_RESPAWNED, _on_player_respawned)
		_disconnect_from(_player, S_HIT_MARKER, _on_hit)
	_player = null
	if _crosshair:
		_crosshair.set_player(null)
	if _damage:
		_damage.clear()


func get_player() -> Node:
	return _player


func touch_controls() -> Control:
	return _touch


func crosshair() -> Crosshair:
	return _crosshair


## Phase 4 attaches here: `hud.phase4_slot("Radar").add_child(radar)` and so on.
## The slots are empty full-rect Controls so a widget can anchor itself freely.
func phase4_slot(slot_name: String) -> Control:
	if _phase4 == null:
		return null
	return _phase4.get_node_or_null(NodePath(slot_name)) as Control


## Hide the whole readout (buy menu, scoreboard, end-of-match). The touch layer
## has its own `set_active` so input state is released properly.
func set_hud_visible(on: bool) -> void:
	if _widgets:
		_widgets.visible = on
	var reticle := get_node_or_null(RETICLE_PATH) as Control
	if reticle:
		reticle.visible = on
	if _touch and _touch.has_method(&"set_active"):
		_touch.call(&"set_active", on)


func _connect_to(o: Object, sig: StringName, cb: Callable) -> void:
	if o.has_signal(sig) and not o.is_connected(sig, cb):
		o.connect(sig, cb)


func _disconnect_from(o: Object, sig: StringName, cb: Callable) -> void:
	if o.has_signal(sig) and o.is_connected(sig, cb):
		o.disconnect(sig, cb)


# --- weapon -------------------------------------------------------------------

func _on_weapon_equipped(w: Node3D, _weapon_id: String) -> void:
	_bind_weapon(w)
	_refresh()


func _bind_weapon(w: Node) -> void:
	if w == _weapon:
		return
	if _weapon != null and is_instance_valid(_weapon):
		_disconnect_from(_weapon, S_AMMO_CHANGED, _on_ammo_changed)
		_disconnect_from(_weapon, S_RELOAD_STARTED, _on_reload_started)
		_disconnect_from(_weapon, S_RELOAD_FINISHED, _on_reload_finished)
		_disconnect_from(_weapon, S_HIT_CONFIRMED, _on_hit)
	_weapon = w
	if _weapon != null:
		_connect_to(_weapon, S_AMMO_CHANGED, _on_ammo_changed)
		_connect_to(_weapon, S_RELOAD_STARTED, _on_reload_started)
		_connect_to(_weapon, S_RELOAD_FINISHED, _on_reload_finished)
		# The player relays hit_confirmed as `hit_marker`; only subscribe to the
		# weapon directly when there is no relay, or every hit would flash twice.
		if not _use_player_hit_relay:
			_connect_to(_weapon, S_HIT_CONFIRMED, _on_hit)
	if _crosshair:
		_crosshair.set_weapon(_weapon)
	if _ammo:
		_ammo.end_reload()


func _on_ammo_changed(_mag: int, _reserve: int) -> void:
	_refresh()


func _on_reload_started(duration: float) -> void:
	if _ammo:
		_ammo.begin_reload(duration)


func _on_reload_finished() -> void:
	if _ammo:
		_ammo.end_reload()
	_refresh()


func _on_hit(zone: int, died: bool) -> void:
	if _hit_marker:
		_hit_marker.flash(zone, died)


# --- damage -------------------------------------------------------------------

## `CharacterBase.damaged` carries no direction, so the world direction of the
## shot is read back from `last_damage_dir` (set immediately before the signal).
## It is converted into a screen-relative bearing with the body's yaw basis —
## the body carries yaw only, so looking up or down cannot skew the arc.
func _on_player_damaged(amount: float, _zone: int, _attacker_id: int) -> void:
	if _damage == null or _player == null:
		return
	var raw: Variant = _player.get(&"last_damage_dir")
	var travel: Vector3 = raw if raw is Vector3 else Vector3.ZERO
	travel.y = 0.0
	if travel.length_squared() < 0.000001:
		_damage.add_hit(0.0, amount)      # unknown source reads as "in front"
		return
	var from := -travel.normalized()       # where the shot came FROM
	var b := Basis.IDENTITY
	if _player is Node3D:
		b = (_player as Node3D).global_transform.basis
	var fwd := -b.z
	var right := b.x
	fwd.y = 0.0
	right.y = 0.0
	if fwd.length_squared() < 0.000001:
		_damage.add_hit(0.0, amount)
		return
	fwd = fwd.normalized()
	right = right.normalized()
	_damage.add_hit(atan2(from.dot(right), from.dot(fwd)), amount)


func _on_player_died(_attacker_id: int, _weapon_id: String, _headshot: bool) -> void:
	_set_alive(false)


func _on_player_respawned() -> void:
	_set_alive(true)
	var w: Node = null
	if _player != null and _player.has_method(M_WEAPON_NODE):
		w = _player.call(M_WEAPON_NODE) as Node
	_bind_weapon(w)
	_refresh()


func _set_alive(alive: bool) -> void:
	if _crosshair:
		_crosshair.visible = alive
	if _damage and not alive:
		_damage.clear()
	if _hit_marker and not alive:
		_hit_marker.clear()


# --- state pump ---------------------------------------------------------------

## Called on every `hud_state_changed`. Both panels compare against what they
## are already showing and only repaint on a real change, so calling this too
## often is free.
func _refresh() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	if _vitals:
		var hp := float(_player.call(M_HEALTH)) if _player.has_method(M_HEALTH) \
			else 0.0
		var hp_max := float(_player.call(M_MAX_HEALTH)) \
			if _player.has_method(M_MAX_HEALTH) else 100.0
		var ap := float(_player.call(M_ARMOR)) if _player.has_method(M_ARMOR) \
			else 0.0
		var helmet := bool(_player.call(M_HELMET)) \
			if _player.has_method(M_HELMET) else false
		_vitals.set_vitals(hp, hp_max, ap, helmet)
	if _ammo:
		_refresh_ammo()


func _refresh_ammo() -> void:
	var display := ""
	if _player.has_method(M_WEAPON_NAME):
		display = String(_player.call(M_WEAPON_NAME))
	var mag := 0
	var reserve := 0
	var mag_size := 0
	var mode := AmmoPanel.MODE_GUN

	var def: Dictionary = {}
	if _player.has_method(M_WEAPON_DEF):
		var d: Variant = _player.call(M_WEAPON_DEF)
		if d is Dictionary:
			def = d
	var slot_v: Variant = _player.get(&"current_slot")
	var slot := int(slot_v) if slot_v != null else -1
	if slot == CharacterBase.Slot.GRENADE:
		mode = AmmoPanel.MODE_GRENADE
		if _player.has_method(M_GRENADES):
			mag = int(_player.call(M_GRENADES))
	elif not def.has("mag") or int(def.get("mag", 0)) <= 0:
		mode = AmmoPanel.MODE_MELEE
	else:
		mag_size = int(def.get("mag", 0))
		if _player.has_method(M_MAG):
			mag = int(_player.call(M_MAG))
		if _player.has_method(M_RESERVE):
			reserve = int(_player.call(M_RESERVE))

	_ammo.set_ammo(display, mode, mag, reserve, mag_size)
	if _player.has_method(M_RELOADING) and not bool(_player.call(M_RELOADING)):
		_ammo.end_reload()


# --- settings / layout --------------------------------------------------------

func _on_settings_changed() -> void:
	if _fps:
		_fps.set_enabled(Settings.show_fps)
	_relayout()


func _relayout() -> void:
	if _vitals:
		_vitals.apply_hud_layout()
	if _ammo:
		_ammo.apply_hud_layout()
	if _fps:
		_fps.apply_hud_layout()


# ==============================================================================
# Widgets
#
# These are built in code rather than authored into hud.tscn because they draw
# themselves; a scene node would only carry a transform. Each one is a
# `hud_movable` with a `hud_id`, so src/ui/hud_editor.gd can drag and scale it
# and the arrangement survives in Settings.hud_layout.
# ==============================================================================

## Common anchoring, hud_scale handling and layout persistence.
class HudWidget extends Control:
	const SCALE_MIN := 0.6
	const SCALE_MAX := 1.8

	# The shared HUD skin. Declared here (and re-exported as HUD.PANEL_BG etc.)
	# because inner classes cannot reach the outer class's constants.
	const PANEL_BG := Color(0.031, 0.039, 0.047, 0.62)
	const PANEL_EDGE := Color(1.0, 1.0, 1.0, 0.10)
	const MARK_WIDTH := 3.0

	var hud_id: String = ""
	var hud_anchor: Vector2 = Vector2.ZERO      # 0..1 within the parent rect
	var hud_offset: Vector2 = Vector2.ZERO      # unscaled px from that anchor
	var base_size: Vector2 = Vector2(240.0, 88.0)
	var layout_scale: float = 1.0
	## hud_scale * layout_scale. Every drawn coordinate is authored at 1.0 and
	## multiplied by this, so one number scales the whole widget.
	var ui_scale: float = 1.0


	static func paint_panel(ci: CanvasItem, rect: Rect2, mark_right: bool = false,
			mark: Color = UITheme.ACCENT, mark_width: float = MARK_WIDTH) -> void:
		ci.draw_rect(rect, PANEL_BG)
		ci.draw_rect(rect, PANEL_EDGE, false, 1.0)
		if mark_width > 0.0:
			var x := (rect.end.x - mark_width) if mark_right else rect.position.x
			ci.draw_rect(Rect2(x, rect.position.y, mark_width, rect.size.y), mark)


	static func paint_text_right(ci: CanvasItem, f: Font, at: Vector2,
			text: String, font_size: int, col: Color) -> float:
		var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			font_size).x
		ci.draw_string(f, Vector2(at.x - w, at.y), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
		return w


	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		focus_mode = Control.FOCUS_NONE
		clip_contents = false


	func setup(p_id: String, p_anchor: Vector2, p_offset: Vector2,
			p_size: Vector2) -> void:
		hud_id = p_id
		hud_anchor = p_anchor
		hud_offset = p_offset
		base_size = p_size
		add_to_group("hud_movable")
		set_meta("hud_id", hud_id)
		set_meta("hud_anchor", hud_anchor)
		set_meta("hud_default_pos", hud_offset)
		set_meta("hud_default_size", base_size)
		set_meta("hud_default_scale", 1.0)


	func _ready() -> void:
		apply_hud_layout()


	## Honours both stored layout formats, exactly like src/ui/touch_button.gd:
	## "off" is an anchor-relative unscaled offset (resolution independent) and
	## "pos" is the absolute position src/ui/hud_editor.gd writes. "off" wins.
	func apply_hud_layout() -> void:
		var off := hud_offset
		var abs_pos := Vector2.INF
		var mult := 1.0
		if hud_id != "":
			var ov: Variant = Settings.hud_layout.get(hud_id)
			if ov is Dictionary:
				var d: Dictionary = ov
				if d.has("scale"):
					mult = float(d["scale"])
				if d.has("off"):
					off = to_vec2(d["off"], off)
				elif d.has("pos"):
					abs_pos = to_vec2(d["pos"], abs_pos)
		layout_scale = clampf(mult, SCALE_MIN, SCALE_MAX)
		ui_scale = clampf(Settings.hud_scale, 0.5, 2.0) * layout_scale
		scale = Vector2.ONE
		size = (base_size * ui_scale).round()
		var area := get_parent_area_size()
		if abs_pos.is_finite():
			global_position = abs_pos
		else:
			var anchor_pt := Vector2(area.x * hud_anchor.x, area.y * hud_anchor.y)
			position = anchor_pt + off * ui_scale \
				- Vector2(size.x * hud_anchor.x, size.y * hud_anchor.y)
		clamp_into_parent()
		queue_redraw()


	func clamp_into_parent() -> void:
		var area := get_parent_area_size()
		position = Vector2(
			clampf(position.x, 0.0, maxf(0.0, area.x - size.x)),
			clampf(position.y, 0.0, maxf(0.0, area.y - size.y))).round()


	## Settings persist through JSON, which turns a Vector2 into the string
	## "(x, y)", so a stored layout has to be parsed tolerantly or every saved
	## arrangement is silently dropped. Same rule as touch_button.gd; duplicated
	## on purpose so the HUD does not depend on the touch layer.
	static func to_vec2(v: Variant, fallback: Vector2) -> Vector2:
		match typeof(v):
			TYPE_VECTOR2:
				return v
			TYPE_VECTOR2I:
				return Vector2(v)
			TYPE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, \
			TYPE_PACKED_INT32_ARRAY:
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


## Bottom-left: health as a number plus a segmented bar, armour beside it with a
## helmet pip. The number is what you read mid-fight; the bar is what you read
## peripherally, which is why both are present.
class VitalsPanel extends HudWidget:
	var _hp: int = -1
	var _hp_max: int = 100
	var _ap: int = -1
	var _helmet: bool = false
	var _hp_text: String = "100"
	var _ap_text: String = "0"


	func set_vitals(hp: float, hp_max: float, ap: float, helmet: bool) -> void:
		var ihp := int(ceilf(maxf(hp, 0.0)))
		var iap := int(ceilf(maxf(ap, 0.0)))
		var imax := maxi(int(hp_max), 1)
		if ihp == _hp and iap == _ap and helmet == _helmet and imax == _hp_max:
			return
		if ihp != _hp:
			_hp_text = str(ihp)
		if iap != _ap:
			_ap_text = str(iap)
		_hp = ihp
		_ap = iap
		_hp_max = imax
		_helmet = helmet
		queue_redraw()


	func _draw() -> void:
		var f := get_theme_default_font()
		if f == null:
			return
		var s := ui_scale
		paint_panel(self, Rect2(Vector2.ZERO, size), false)

		var frac := clampf(float(_hp) / float(_hp_max), 0.0, 1.0)
		var hp_col := UITheme.health_color(frac)

		draw_string(f, Vector2(18.0, 26.0) * s, "HP", HORIZONTAL_ALIGNMENT_LEFT,
			-1, int(UITheme.FS_TINY * s), UITheme.TEXT_FAINT)
		draw_string(f, Vector2(16.0, 70.0) * s, _hp_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(UITheme.FS_HUGE * s), hp_col)
		UITheme.draw_segmented_bar(self,
			Rect2(Vector2(16.0, 78.0) * s, Vector2(168.0, 6.0) * s), frac,
			hp_col, 10, 2.0 * s)

		var ap_col := UITheme.ACCENT_COOL if _ap > 0 else UITheme.TEXT_FAINT
		draw_string(f, Vector2(192.0, 26.0) * s, "ARMOR",
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(UITheme.FS_TINY * s),
			UITheme.TEXT_FAINT)
		draw_string(f, Vector2(190.0, 62.0) * s, _ap_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(UITheme.FS_HEAD * s), ap_col)
		UITheme.draw_segmented_bar(self,
			Rect2(Vector2(190.0, 78.0) * s, Vector2(66.0, 6.0) * s),
			clampf(float(_ap) / 100.0, 0.0, 1.0), ap_col, 5, 2.0 * s)

		if _helmet:
			# Helmet reads as a dome; parked right of the armour figure so three
			# digits still clear it.
			var c := Vector2(246.0, 54.0) * s
			draw_arc(c, 10.0 * s, PI, TAU, 12, UITheme.ACCENT_COOL, 2.0 * s, true)
			draw_line(c - Vector2(10.0, 0.0) * s, c + Vector2(10.0, 0.0) * s,
				UITheme.ACCENT_COOL, 2.0 * s)


## Bottom-right: magazine large, reserve small, weapon name above, reload
## progress across the foot of the panel.
class AmmoPanel extends HudWidget:
	const MODE_GUN := 0
	const MODE_MELEE := 1
	const MODE_GRENADE := 2

	const LOW_FRACTION := 0.25

	var _mode: int = MODE_GUN
	var _mag: int = -1
	var _reserve: int = -1
	var _mag_size: int = 0
	var _name: String = ""
	var _mag_text: String = "0"
	var _reserve_text: String = "0"

	var _reload_total: float = 0.0
	var _reload_left: float = 0.0


	func set_ammo(display_name: String, mode: int, mag: int, reserve: int,
			mag_size: int) -> void:
		if mode == _mode and mag == _mag and reserve == _reserve \
				and mag_size == _mag_size and display_name == _name:
			return
		if mag != _mag:
			_mag_text = str(maxi(mag, 0))
		if reserve != _reserve:
			_reserve_text = str(maxi(reserve, 0))
		_mode = mode
		_mag = mag
		_reserve = reserve
		_mag_size = mag_size
		_name = display_name
		queue_redraw()


	func begin_reload(duration: float) -> void:
		if duration <= 0.0:
			return
		_reload_total = duration
		_reload_left = duration
		set_process(true)
		queue_redraw()


	func end_reload() -> void:
		if _reload_left <= 0.0:
			return
		_reload_left = 0.0
		set_process(false)
		queue_redraw()


	## Only runs while a reload is in flight; the bar is an animation, so a
	## repaint per frame is the point.
	func _process(delta: float) -> void:
		_reload_left -= delta
		if _reload_left <= 0.0:
			_reload_left = 0.0
			set_process(false)
		queue_redraw()


	func _draw() -> void:
		var f := get_theme_default_font()
		if f == null:
			return
		var s := ui_scale
		paint_panel(self, Rect2(Vector2.ZERO, size), true)

		var right := 254.0 * s
		if _name != "":
			paint_text_right(self, f, Vector2(right, 26.0 * s), _name,
				int(UITheme.FS_SMALL * s), UITheme.TEXT_DIM)

		match _mode:
			MODE_MELEE:
				paint_text_right(self, f, Vector2(right, 72.0 * s), "—",
					int(UITheme.FS_HUGE * s), UITheme.TEXT_FAINT)
			MODE_GRENADE:
				var gw := paint_text_right(self, f, Vector2(right, 72.0 * s),
					_mag_text, int(UITheme.FS_HUGE * s),
					UITheme.TEXT if _mag > 0 else UITheme.TEXT_FAINT)
				paint_text_right(self, f,
					Vector2(right - gw - 8.0 * s, 72.0 * s), "x",
					int(UITheme.FS_HEAD * s), UITheme.TEXT_DIM)
			_:
				var rw := paint_text_right(self, f, Vector2(right, 72.0 * s),
					_reserve_text, int(UITheme.FS_HEAD * s), UITheme.TEXT_DIM)
				var slash_x := right - rw - 8.0 * s
				var sw := paint_text_right(self, f,
					Vector2(slash_x, 72.0 * s), "/", int(UITheme.FS_HEAD * s),
					UITheme.TEXT_FAINT)
				paint_text_right(self, f,
					Vector2(slash_x - sw - 6.0 * s, 72.0 * s), _mag_text,
					int(UITheme.FS_HUGE * s), _mag_color())

		if _reload_left > 0.0 and _reload_total > 0.0:
			var t := clampf(1.0 - _reload_left / _reload_total, 0.0, 1.0)
			var bar := Rect2(Vector2(16.0, 84.0) * s, Vector2(238.0, 4.0) * s)
			draw_rect(bar, Color(1.0, 1.0, 1.0, 0.10))
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * t, bar.size.y)),
				UITheme.ACCENT)
			draw_string(f, Vector2(16.0, 78.0) * s, "RELOADING",
				HORIZONTAL_ALIGNMENT_LEFT, -1, int(UITheme.FS_TINY * s),
				UITheme.ACCENT)


	func _mag_color() -> Color:
		if _mag <= 0:
			return UITheme.BAD
		if _mag_size > 0 and float(_mag) / float(_mag_size) <= LOW_FRACTION:
			return UITheme.WARN
		return UITheme.TEXT


## Frame budget readout, shown only when Settings.show_fps. Rebuilt at 4 Hz and
## only when the displayed integers change, so it never formats a string in a
## frame where nothing moved.
class FpsReadout extends HudWidget:
	const REFRESH := 0.25
	const MS_SMOOTH := 0.12

	var _accum: float = 0.0
	var _ms: float = 16.6
	var _fps: int = -1
	var _ms_tenths: int = -1
	var _fps_text: String = "0"
	var _ms_text: String = "0.0 ms"


	func set_enabled(on: bool) -> void:
		visible = on
		set_process(on)
		if on:
			_accum = REFRESH


	func _process(delta: float) -> void:
		_ms = lerpf(_ms, delta * 1000.0, MS_SMOOTH)
		_accum += delta
		if _accum < REFRESH:
			return
		_accum = 0.0
		var fps := int(Engine.get_frames_per_second())
		var tenths := int(roundf(_ms * 10.0))
		if fps == _fps and tenths == _ms_tenths:
			return
		if fps != _fps:
			_fps = fps
			_fps_text = str(fps)
		if tenths != _ms_tenths:
			_ms_tenths = tenths
			_ms_text = "%.1f ms" % (float(tenths) * 0.1)
		queue_redraw()


	func _draw() -> void:
		var f := get_theme_default_font()
		if f == null:
			return
		var s := ui_scale
		paint_panel(self, Rect2(Vector2.ZERO, size), false, _fps_color(),
			2.0 * s)
		var w := f.get_string_size(_fps_text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			int(UITheme.FS_HEAD * s)).x
		draw_string(f, Vector2(14.0, 30.0) * s, _fps_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(UITheme.FS_HEAD * s), _fps_color())
		draw_string(f, Vector2(14.0 * s + w + 5.0 * s, 30.0 * s), "FPS",
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(UITheme.FS_TINY * s),
			UITheme.TEXT_FAINT)
		paint_text_right(self, f, Vector2(132.0 * s, 30.0 * s), _ms_text,
			int(UITheme.FS_TINY * s), UITheme.TEXT_DIM)


	func _fps_color() -> Color:
		if _fps >= 55:
			return UITheme.OK
		if _fps >= 40:
			return UITheme.WARN
		return UITheme.BAD
