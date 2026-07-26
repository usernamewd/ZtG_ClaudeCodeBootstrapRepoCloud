extends Control
## HUD layout editor: drag and resize every on-screen control, then save.
##
## Rather than reimplement the HUD, this instantiates the real HUD and touch
## controls and puts them into editing mode. Anything in group `hud_movable` with
## a `hud_id` meta becomes draggable, so a control added later is editable with no
## changes here. Layout is stored in Settings.hud_layout as
## hud_id -> {"pos": Vector2, "scale": float}.

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const SETTINGS_SCENE := "res://scenes/ui/settings.tscn"
const HUD_SCENE := "res://scenes/ui/hud.tscn"
const TOUCH_SCENE := "res://scenes/ui/touch_controls.tscn"

var _hud: Node = null
var _selected: Control = null
var _dragging := false
var _drag_offset := Vector2.ZERO
var _drag_touch := -1
var _selected_label: Label = null
var _scale_slider: HSlider = null
var _overlay: EditOverlay = null


func _ready() -> void:
	theme = UITheme.build()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_backdrop()
	_load_hud()
	_build_chrome()


func _build_backdrop() -> void:
	# A mock scene behind the HUD so contrast is realistic while editing.
	var bg := ColorRect.new()
	bg.color = Color(0.20, 0.22, 0.24)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var band := ColorRect.new()
	band.color = Color(0.13, 0.14, 0.15)
	band.set_anchors_preset(Control.PRESET_FULL_RECT)
	band.anchor_top = 0.55
	add_child(band)


func _load_hud() -> void:
	# The HUD normally carries the touch controls; if it isn't present yet, fall
	# back to the touch controls alone so the editor is still usable.
	var path := HUD_SCENE if ResourceLoader.exists(HUD_SCENE) else TOUCH_SCENE
	if not ResourceLoader.exists(path):
		return
	var packed: PackedScene = load(path)
	if packed == null:
		return
	_hud = packed.instantiate()
	add_child(_hud)
	# Put every movable control into editing mode.
	for n in get_tree().get_nodes_in_group("hud_movable"):
		if n.has_method("set_editing"):
			n.set_editing(true)
	for n in _all_children(_hud):
		if n.has_method("set_editing"):
			n.set_editing(true)


func _build_chrome() -> void:
	_overlay = EditOverlay.new()
	_overlay.editor = self
	add_child(_overlay)

	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = 74
	add_child(bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	bar.add_child(row)

	var title := Label.new()
	title.text = "HUD LAYOUT"
	title.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	row.add_child(title)

	_selected_label = Label.new()
	_selected_label.text = "Drag any control to move it."
	_selected_label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	_selected_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_selected_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_selected_label)

	var scale_label := Label.new()
	scale_label.text = "SIZE"
	scale_label.add_theme_font_size_override("font_size", UITheme.FS_TINY)
	scale_label.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	scale_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(scale_label)

	_scale_slider = HSlider.new()
	_scale_slider.min_value = 0.6
	_scale_slider.max_value = 1.8
	_scale_slider.step = 0.05
	_scale_slider.value = 1.0
	_scale_slider.custom_minimum_size = Vector2(200, 44)
	_scale_slider.value_changed.connect(_on_scale_changed)
	row.add_child(_scale_slider)

	var reset := Button.new()
	reset.text = "RESET ALL"
	reset.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
	reset.pressed.connect(_on_reset)
	row.add_child(reset)

	var save := Button.new()
	save.text = "SAVE"
	save.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
	var sb := UITheme.button_box(Color(0.196, 0.110, 0.031), UITheme.ACCENT)
	save.add_theme_stylebox_override("normal", sb)
	save.add_theme_color_override("font_color", UITheme.ACCENT)
	save.pressed.connect(_on_save)
	row.add_child(save)


# ---------------------------------------------------------------------------
# Dragging
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_begin_drag(t.position, t.index)
		elif t.index == _drag_touch:
			_end_drag()
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == _drag_touch:
			_move_drag(d.position)
	elif event is InputEventMouseButton:
		var m := event as InputEventMouseButton
		if m.button_index == MOUSE_BUTTON_LEFT:
			if m.pressed:
				_begin_drag(m.position, -2)
			else:
				_end_drag()
	elif event is InputEventMouseMotion and _dragging:
		_move_drag((event as InputEventMouseMotion).position)


func _begin_drag(at: Vector2, touch_index: int) -> void:
	if at.y < 80.0:
		return       # the toolbar owns the top strip
	var hit := _pick(at)
	if hit == null:
		return
	_selected = hit
	_dragging = true
	_drag_touch = touch_index
	_drag_offset = hit.global_position - at
	if _selected_label:
		_selected_label.text = "Editing: %s" % _hud_id(hit)
	if _scale_slider:
		var entry: Dictionary = Settings.hud_layout.get(_hud_id(hit), {})
		_scale_slider.set_value_no_signal(float(entry.get("scale", 1.0)))
	if _overlay:
		_overlay.queue_redraw()


func _move_drag(at: Vector2) -> void:
	if not _dragging or _selected == null:
		return
	var target := at + _drag_offset
	# Keep controls fully on screen — an off-screen button is unrecoverable
	# without the reset.
	target.x = clampf(target.x, 0.0, size.x - _selected.size.x * _selected.scale.x)
	target.y = clampf(target.y, 80.0, size.y - _selected.size.y * _selected.scale.y)
	_selected.global_position = target
	_store(_selected)
	if _overlay:
		_overlay.queue_redraw()


func _end_drag() -> void:
	_dragging = false
	_drag_touch = -1


## Topmost movable control under the point.
func _pick(at: Vector2) -> Control:
	var best: Control = null
	for n in get_tree().get_nodes_in_group("hud_movable"):
		var c := n as Control
		if c == null or not c.visible:
			continue
		var r := Rect2(c.global_position, c.size * c.scale)
		if r.has_point(at):
			best = c      # later nodes draw on top, so the last hit wins
	return best


func _on_scale_changed(value: float) -> void:
	if _selected == null:
		return
	_selected.scale = Vector2.ONE * value
	_store(_selected)
	if _overlay:
		_overlay.queue_redraw()


func _store(c: Control) -> void:
	Settings.hud_layout[_hud_id(c)] = {
		"pos": c.global_position,
		"scale": c.scale.x,
	}


func _hud_id(c: Control) -> String:
	return String(c.get_meta("hud_id", c.name))


func _on_reset() -> void:
	Settings.hud_layout.clear()
	Settings.save_to_disk()
	_selected = null
	if _selected_label:
		_selected_label.text = "Layout reset. Reopen to see defaults."
	AudioMgr.play_ui("ui_click")
	# Rebuild the HUD so the defaults are visible immediately.
	if _hud and is_instance_valid(_hud):
		_hud.queue_free()
	_hud = null
	_load_hud()
	if _overlay:
		_overlay.queue_redraw()


func _on_save() -> void:
	Settings.save_to_disk()
	AudioMgr.play_ui("ui_click")
	if ResourceLoader.exists(SETTINGS_SCENE):
		get_tree().change_scene_to_file(SETTINGS_SCENE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_save()


func _all_children(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			out.append(c)
			stack.append(c)
	return out


## Draws the selection brackets and a hint outline around every editable control,
## so the player can see what is movable.
class EditOverlay extends Control:
	var editor = null

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if editor == null:
			return
		for n in get_tree().get_nodes_in_group("hud_movable"):
			var c := n as Control
			if c == null or not c.visible:
				continue
			var r := Rect2(c.global_position, c.size * c.scale)
			var selected: bool = c == editor._selected
			draw_rect(r, Color(UITheme.ACCENT if selected else UITheme.TEXT_FAINT,
				0.07 if selected else 0.03))
			if selected:
				UITheme.draw_brackets(self, r, UITheme.ACCENT, 14.0, 2.0)
			else:
				draw_rect(r, Color(1, 1, 1, 0.12), false, 1.0)
