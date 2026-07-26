extends Control
## Settings: Controls, Crosshair, Graphics, HUD layout.
##
## Every control writes straight into the Settings autoload and saves on exit, so
## a change is live immediately (the crosshair preview updates as you drag).
## Built in code against UITheme.

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const HUD_EDITOR_SCENE := "res://scenes/ui/hud_editor.tscn"

var _tabs: TabContainer = null
var _crosshair_preview: CrosshairPreview = null


func _ready() -> void:
	theme = UITheme.build()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = UITheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 30)
	margin.add_theme_constant_override("margin_right", 30)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	margin.add_child(col)

	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", UITheme.FS_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var back := Button.new()
	back.text = "BACK"
	back.custom_minimum_size = Vector2(140, UITheme.TOUCH_MIN)
	back.pressed.connect(_on_back)
	head.add_child(back)
	col.add_child(head)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_tabs)

	_tabs.add_child(_build_controls_tab())
	_tabs.add_child(_build_crosshair_tab())
	_tabs.add_child(_build_graphics_tab())
	_tabs.add_child(_build_hud_tab())


# ---------------------------------------------------------------------------

func _build_controls_tab() -> Control:
	var page := _page("CONTROLS")
	var v := page.get_meta("body") as VBoxContainer

	_slider(v, "Look sensitivity", 0.05, 1.2, 0.01, Settings.look_sensitivity,
		func(val): Settings.look_sensitivity = val, "%.2f")
	_slider(v, "Aiming sensitivity multiplier", 0.2, 1.0, 0.05,
		Settings.ads_sensitivity_mult,
		func(val): Settings.ads_sensitivity_mult = val, "%.2f")
	_toggle(v, "Invert vertical look", Settings.invert_y,
		func(on): Settings.invert_y = on)
	_toggle(v, "Crouch is a toggle", Settings.crouch_is_toggle,
		func(on): Settings.crouch_is_toggle = on,
		"Off: hold the crouch button to stay crouched.")
	_toggle(v, "Mirror fire button to the left", Settings.fire_left_mirror,
		func(on): Settings.fire_left_mirror = on,
		"Adds a second fire button so you can shoot with either thumb.")

	v.add_child(HSeparator.new())
	_toggle(v, "Gyro aiming", Settings.gyro_enabled,
		func(on): Settings.gyro_enabled = on,
		"Tilt the device to fine-tune your aim. Requires a gyroscope.")
	_slider(v, "Gyro strength", 0.2, 3.0, 0.1, Settings.gyro_sensitivity,
		func(val): Settings.gyro_sensitivity = val, "%.1f")
	return page


func _build_crosshair_tab() -> Control:
	var page := _page("CROSSHAIR")
	var v := page.get_meta("body") as VBoxContainer

	var preview_panel := PanelContainer.new()
	preview_panel.custom_minimum_size = Vector2(0, 150)
	_crosshair_preview = CrosshairPreview.new()
	preview_panel.add_child(_crosshair_preview)
	v.add_child(preview_panel)

	_slider(v, "Size", 4.0, 30.0, 1.0, Settings.crosshair_size,
		func(val):
			Settings.crosshair_size = val
			_redraw_preview(), "%.0f")
	_slider(v, "Centre gap", 0.0, 20.0, 1.0, Settings.crosshair_gap,
		func(val):
			Settings.crosshair_gap = val
			_redraw_preview(), "%.0f")
	_slider(v, "Thickness", 1.0, 6.0, 1.0, Settings.crosshair_thickness,
		func(val):
			Settings.crosshair_thickness = val
			_redraw_preview(), "%.0f")
	_toggle(v, "Centre dot", Settings.crosshair_dot,
		func(on):
			Settings.crosshair_dot = on
			_redraw_preview())
	_toggle(v, "Expand with weapon spread", Settings.crosshair_dynamic,
		func(on):
			Settings.crosshair_dynamic = on
			_redraw_preview(),
		"The crosshair opens up while you move or spray, showing your real accuracy.")

	# A short palette is far more usable on a touch screen than an RGB picker.
	var colours_label := Label.new()
	colours_label.text = "Colour"
	colours_label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	v.add_child(colours_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for c in [Color(0.2, 1.0, 0.4), Color(0.2, 0.9, 1.0), Color(1.0, 0.9, 0.2),
			Color(1.0, 0.35, 0.3), Color(1.0, 0.478, 0.102), Color(1, 1, 1),
			Color(1.0, 0.4, 0.85)]:
		var b := Button.new()
		b.custom_minimum_size = Vector2(UITheme.TOUCH_MIN, UITheme.TOUCH_MIN)
		var sb := UITheme.flat_box(c, 4)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		var col: Color = c
		b.pressed.connect(func():
			Settings.crosshair_color = Color(col, 0.9)
			_redraw_preview()
			AudioMgr.play_ui("ui_click"))
		row.add_child(b)
	v.add_child(row)
	return page


func _build_graphics_tab() -> Control:
	var page := _page("GRAPHICS")
	var v := page.get_meta("body") as VBoxContainer

	var label := Label.new()
	label.text = "Quality preset"
	label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	v.add_child(label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var names := ["LOW", "MEDIUM", "HIGH"]
	var blurbs := [
		"70% render scale, no anti-aliasing, no dynamic shadows. Targets 60 fps on older phones.",
		"85% render scale, 2x anti-aliasing. The default balance.",
		"Full render scale, 4x anti-aliasing. For flagship devices.",
	]
	var blurb := Label.new()
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	blurb.add_theme_font_size_override("font_size", UITheme.FS_SMALL)

	for i in names.size():
		var b := Button.new()
		b.text = names[i]
		b.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var idx := i
		b.pressed.connect(func():
			Settings.graphics_preset = idx
			Settings.apply_graphics_preset()
			blurb.text = blurbs[idx]
			AudioMgr.play_ui("ui_click")
			_mark_preset(row, idx))
		row.add_child(b)
	v.add_child(row)
	v.add_child(blurb)
	blurb.text = blurbs[Settings.graphics_preset]
	_mark_preset(row, Settings.graphics_preset)

	v.add_child(HSeparator.new())
	_toggle(v, "Show frame rate", Settings.show_fps,
		func(on): Settings.show_fps = on)
	return page


func _mark_preset(row: HBoxContainer, active: int) -> void:
	for i in row.get_child_count():
		var b := row.get_child(i) as Button
		if b:
			b.add_theme_color_override("font_color",
				UITheme.ACCENT if i == active else UITheme.TEXT_DIM)


func _build_hud_tab() -> Control:
	var page := _page("HUD")
	var v := page.get_meta("body") as VBoxContainer

	_slider(v, "HUD scale", 0.7, 1.6, 0.05, Settings.hud_scale,
		func(val): Settings.hud_scale = val, "%.2f")

	var info := Label.new()
	info.text = "Open the layout editor to drag and resize the on-screen controls. Every button and readout can be moved, and your layout is saved."
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	v.add_child(info)

	var edit := Button.new()
	edit.text = "OPEN HUD LAYOUT EDITOR"
	edit.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN + 6)
	edit.pressed.connect(func():
		Settings.save_to_disk()
		if ResourceLoader.exists(HUD_EDITOR_SCENE):
			get_tree().change_scene_to_file(HUD_EDITOR_SCENE))
	v.add_child(edit)

	var reset := Button.new()
	reset.text = "RESET HUD TO DEFAULTS"
	reset.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
	reset.pressed.connect(func():
		Settings.hud_layout.clear()
		Settings.hud_scale = 1.0
		Settings.save_to_disk()
		AudioMgr.play_ui("ui_click"))
	v.add_child(reset)
	return page


# ---------------------------------------------------------------------------
# Small builders
# ---------------------------------------------------------------------------

func _page(title: String) -> Control:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_theme_constant_override("margin_left", 8)
	m.add_theme_constant_override("margin_right", 8)
	m.add_theme_constant_override("margin_top", 8)
	sc.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_child(v)
	sc.set_meta("body", v)
	return sc


func _slider(parent: Control, label: String, lo: float, hi: float, step: float,
		value: float, on_change: Callable, fmt := "%.2f") -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var val := Label.new()
	val.text = fmt % value
	val.add_theme_color_override("font_color", UITheme.ACCENT)
	row.add_child(val)
	v.add_child(row)

	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	# Tall enough to grab with a thumb; the default slider is a mouse target.
	s.custom_minimum_size = Vector2(0, 40)
	s.value_changed.connect(func(nv: float):
		val.text = fmt % nv
		on_change.call(nv))
	v.add_child(s)
	parent.add_child(v)


func _toggle(parent: Control, label: String, value: bool, on_change: Callable,
		hint := "") -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	var cb := CheckButton.new()
	cb.text = label
	cb.button_pressed = value
	cb.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
	cb.toggled.connect(func(on: bool):
		on_change.call(on)
		AudioMgr.play_ui("ui_click"))
	v.add_child(cb)
	if hint != "":
		var h := Label.new()
		h.text = hint
		h.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		h.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
		h.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
		v.add_child(h)
	parent.add_child(v)


func _redraw_preview() -> void:
	if _crosshair_preview:
		_crosshair_preview.queue_redraw()


func _on_back() -> void:
	Settings.save_to_disk()
	if ResourceLoader.exists(MENU_SCENE):
		get_tree().change_scene_to_file(MENU_SCENE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back()


## Live crosshair preview over a mock scene backdrop, drawn with the same
## geometry the HUD crosshair uses so what you tune is what you get.
class CrosshairPreview extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		# Backdrop with light and dark halves: a crosshair must be legible on both.
		draw_rect(r, Color(0.24, 0.25, 0.27))
		draw_rect(Rect2(r.position, Vector2(r.size.x * 0.5, r.size.y)),
			Color(0.09, 0.10, 0.11))
		var c := size * 0.5
		var col: Color = Settings.crosshair_color
		var gap: float = Settings.crosshair_gap
		var len_px: float = Settings.crosshair_size
		var th: float = Settings.crosshair_thickness
		if Settings.crosshair_dynamic:
			gap += 6.0     # show the expanded state so the effect is visible
		for d in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
			draw_line(c + d * gap, c + d * (gap + len_px), col, th)
		if Settings.crosshair_dot:
			draw_rect(Rect2(c - Vector2(th, th) * 0.5, Vector2(th, th)), col)
