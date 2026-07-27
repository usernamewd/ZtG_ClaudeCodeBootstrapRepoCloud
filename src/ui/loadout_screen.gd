class_name LoadoutScreen
extends Control
## Loadout and Crates.
##
## Cosmetics only, earned purely by playing — there is no real-money anything and
## no way to buy a crate or a key. Rounds played grant XP; XP grants crates; a
## crate opens into one weapon finish. A "finish" is a recoloured palette atlas
## over identical geometry (see docs/ASSET_PIPELINE.md), so a skin costs one
## texture and zero extra draw calls.

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"

const XP_PER_CRATE := 1000

## Original finish definitions: id -> {name, rarity, tint overrides by material
## family}. The pipeline applies these to a weapon's atlas at load time.
const FINISHES := [
	{"id": "factory", "name": "Factory", "rarity": 0,
		"tints": {}},
	{"id": "graphite", "name": "Graphite", "rarity": 0,
		"tints": {"metal": Color(0.16, 0.17, 0.19), "wood": Color(0.13, 0.13, 0.14)}},
	{"id": "desert", "name": "Dust Line", "rarity": 1,
		"tints": {"metal": Color(0.62, 0.53, 0.36), "wood": Color(0.44, 0.34, 0.20)}},
	{"id": "forest", "name": "Treeline", "rarity": 1,
		"tints": {"metal": Color(0.24, 0.31, 0.20), "wood": Color(0.21, 0.24, 0.15)}},
	{"id": "oxide", "name": "Red Oxide", "rarity": 2,
		"tints": {"metal": Color(0.45, 0.16, 0.11), "wood": Color(0.25, 0.12, 0.09)}},
	{"id": "cobalt", "name": "Cobalt Wash", "rarity": 2,
		"tints": {"metal": Color(0.16, 0.31, 0.52), "wood": Color(0.14, 0.20, 0.30)}},
	{"id": "ember", "name": "Ember Etch", "rarity": 3,
		"tints": {"metal": Color(0.72, 0.30, 0.06), "wood": Color(0.30, 0.14, 0.05)}},
	{"id": "frost", "name": "Hoarfrost", "rarity": 3,
		"tints": {"metal": Color(0.74, 0.82, 0.88), "wood": Color(0.44, 0.51, 0.56)}},
	{"id": "brass", "name": "Brasswork", "rarity": 4,
		"tints": {"metal": Color(0.72, 0.55, 0.20), "wood": Color(0.32, 0.20, 0.09)}},
]

const RARITY_NAMES := ["Standard", "Field", "Marked", "Refined", "Exceptional"]
const RARITY_COLORS := [
	Color(0.55, 0.58, 0.62), Color(0.36, 0.66, 0.96), Color(0.55, 0.44, 0.95),
	Color(0.91, 0.40, 0.86), Color(1.0, 0.66, 0.18),
]
## Draw weights per rarity — rarer finishes really are rarer.
const RARITY_WEIGHTS := [50.0, 26.0, 14.0, 7.0, 3.0]

var _profile := {}
var _tabs: TabContainer = null
var _crate_count_label: Label = null
var _xp_bar: ProgressBar = null
var _owned_grid: GridContainer = null
var _reveal: CrateReveal = null
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	theme = UITheme.build()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_rng.randomize()
	_load_profile()
	_build()
	var tab := int(Persistence.get_value("loadout_open_tab", 0))
	Persistence.put("loadout_open_tab", 0)
	if _tabs and tab < _tabs.get_tab_count():
		_tabs.current_tab = tab


func _load_profile() -> void:
	_profile = Persistence.get_value("profile", {})
	if not _profile.has("xp"):
		_profile["xp"] = 0
	if not _profile.has("crates"):
		_profile["crates"] = 0
	if not _profile.has("owned"):
		# Everyone starts with the plain finish on every weapon.
		_profile["owned"] = {}
	if not _profile.has("equipped"):
		_profile["equipped"] = {}


func _save_profile() -> void:
	Persistence.put("profile", _profile)
	Persistence.save_now()


# ---------------------------------------------------------------------------

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = UITheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 30)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	margin.add_child(col)

	col.add_child(_build_header())

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_tabs)
	_tabs.add_child(_build_loadout_tab())
	_tabs.add_child(_build_crates_tab())

	_reveal = CrateReveal.new()
	_reveal.visible = false
	add_child(_reveal)


func _build_header() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 20)

	var title := Label.new()
	title.text = "ARMOURY"
	title.add_theme_font_size_override("font_size", UITheme.FS_TITLE)
	h.add_child(title)

	var xp_box := VBoxContainer.new()
	xp_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	xp_box.add_theme_constant_override("separation", 2)
	var xp_row := HBoxContainer.new()
	var xp_label := Label.new()
	var xp := int(_profile.xp)
	xp_label.text = "PROGRESS TO NEXT CRATE"
	xp_label.add_theme_font_size_override("font_size", UITheme.FS_TINY)
	xp_label.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	xp_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	xp_row.add_child(xp_label)
	var xp_val := Label.new()
	xp_val.text = "%d / %d XP" % [xp % XP_PER_CRATE, XP_PER_CRATE]
	xp_val.add_theme_font_size_override("font_size", UITheme.FS_TINY)
	xp_val.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	xp_row.add_child(xp_val)
	xp_box.add_child(xp_row)
	_xp_bar = ProgressBar.new()
	_xp_bar.max_value = XP_PER_CRATE
	_xp_bar.value = xp % XP_PER_CRATE
	_xp_bar.show_percentage = false
	_xp_bar.custom_minimum_size = Vector2(0, 8)
	_xp_bar.add_theme_stylebox_override("background", UITheme.flat_box(Color(1, 1, 1, 0.07), 3))
	_xp_bar.add_theme_stylebox_override("fill", UITheme.flat_box(UITheme.ACCENT, 3))
	xp_box.add_child(_xp_bar)
	h.add_child(xp_box)

	var back := Button.new()
	back.text = "BACK"
	back.custom_minimum_size = Vector2(140, UITheme.TOUCH_MIN)
	back.pressed.connect(_on_back)
	h.add_child(back)
	return h


func _build_loadout_tab() -> Control:
	var page := ScrollContainer.new()
	page.name = "FINISHES"
	page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	page.add_child(v)

	var hint := Label.new()
	hint.text = "Equip a finish for each weapon. Finishes are cosmetic only — they never change how a weapon performs."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	v.add_child(hint)

	# One row per gun, showing the finishes owned for it.
	for cat in [0, 1, 2, 3]:
		for id in WeaponDB.ids_in_category(cat):
			v.add_child(_build_weapon_row(String(id)))
	return page


func _build_weapon_row(weapon_id: String) -> Control:
	var def := WeaponDB.get_def(weapon_id)
	var pc := PanelContainer.new()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	pc.add_child(v)

	var name_label := Label.new()
	name_label.text = String(def.get("display_name", weapon_id)).to_upper()
	name_label.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	v.add_child(name_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var owned: Array = _owned_for(weapon_id)
	var equipped: String = String(_profile.equipped.get(weapon_id, "factory"))
	for finish_id in owned:
		var finish := _finish(String(finish_id))
		if finish.is_empty():
			continue
		var b := Button.new()
		b.text = String(finish.name)
		b.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN)
		var rarity := int(finish.rarity)
		var sb := UITheme.button_box(UITheme.PANEL_RAISED, RARITY_COLORS[rarity])
		if String(finish_id) == equipped:
			sb.bg_color = Color(0.196, 0.110, 0.031)
			sb.border_width_left = 4
			sb.border_color = UITheme.ACCENT
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_color_override("font_color", RARITY_COLORS[rarity])
		var fid := String(finish_id)
		b.pressed.connect(func():
			_profile.equipped[weapon_id] = fid
			_save_profile()
			AudioMgr.play_ui("ui_click")
			_rebuild_loadout_tab())
		row.add_child(b)
	v.add_child(row)
	return pc


func _rebuild_loadout_tab() -> void:
	if _tabs == null:
		return
	var current := _tabs.current_tab
	var old := _tabs.get_child(0)
	_tabs.remove_child(old)
	old.queue_free()
	var fresh := _build_loadout_tab()
	_tabs.add_child(fresh)
	_tabs.move_child(fresh, 0)
	_tabs.current_tab = current


func _build_crates_tab() -> Control:
	var page := ScrollContainer.new()
	page.name = "CRATES"
	page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 14)
	page.add_child(v)

	var pc := PanelContainer.new()
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 10)
	pc.add_child(inner)

	_crate_count_label = Label.new()
	_crate_count_label.add_theme_font_size_override("font_size", UITheme.FS_TITLE)
	inner.add_child(_crate_count_label)

	var blurb := Label.new()
	blurb.text = "Crates are earned by playing matches — %d XP each. There is nothing to buy, and no keys.\nEach crate contains one weapon finish." % XP_PER_CRATE
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	inner.add_child(blurb)

	var open := Button.new()
	open.text = "OPEN CRATE"
	open.custom_minimum_size = Vector2(0, UITheme.TOUCH_MIN + 8)
	open.pressed.connect(_on_open_crate)
	inner.add_child(open)
	v.add_child(pc)

	var collection := Label.new()
	collection.text = "COLLECTION"
	collection.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	collection.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	v.add_child(collection)

	_owned_grid = GridContainer.new()
	_owned_grid.columns = 3
	_owned_grid.add_theme_constant_override("h_separation", int(UITheme.GAP))
	_owned_grid.add_theme_constant_override("v_separation", int(UITheme.GAP))
	v.add_child(_owned_grid)

	_refresh_crates()
	return page


func _refresh_crates() -> void:
	if _crate_count_label:
		var n := int(_profile.crates)
		_crate_count_label.text = "%d CRATE%s AVAILABLE" % [n, "" if n == 1 else "S"]
		_crate_count_label.add_theme_color_override("font_color",
			UITheme.ACCENT if n > 0 else UITheme.TEXT_FAINT)
	if _owned_grid == null:
		return
	for c in _owned_grid.get_children():
		c.queue_free()
	# Flatten the collection: one card per (weapon, finish) actually owned.
	for weapon_id in _profile.owned:
		for finish_id in _profile.owned[weapon_id]:
			_owned_grid.add_child(_collection_card(String(weapon_id), String(finish_id)))


func _collection_card(weapon_id: String, finish_id: String) -> Control:
	var finish := _finish(finish_id)
	var wdef := WeaponDB.get_def(weapon_id)
	var pc := PanelContainer.new()
	var rarity := int(finish.get("rarity", 0))
	var sb := UITheme.flat_box(UITheme.PANEL_RAISED, 5)
	sb.set_content_margin_all(10)
	sb.border_width_left = 3
	sb.border_color = RARITY_COLORS[rarity]
	pc.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	pc.add_child(v)
	var n := Label.new()
	n.text = String(finish.get("name", finish_id))
	n.add_theme_color_override("font_color", RARITY_COLORS[rarity])
	v.add_child(n)
	var w := Label.new()
	w.text = String(wdef.get("display_name", weapon_id)).to_upper()
	w.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	w.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	v.add_child(w)
	var r := Label.new()
	r.text = RARITY_NAMES[rarity]
	r.add_theme_font_size_override("font_size", UITheme.FS_TINY)
	r.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
	v.add_child(r)
	return pc


# ---------------------------------------------------------------------------

func _on_open_crate() -> void:
	if int(_profile.crates) <= 0:
		AudioMgr.play_ui("buy_denied")
		return
	_profile.crates = int(_profile.crates) - 1

	var finish := _roll_finish()
	var weapon_id := _roll_weapon()
	var owned: Array = _owned_for(weapon_id)
	var duplicate: bool = owned.has(String(finish.id))
	if duplicate:
		# Duplicates convert to XP rather than being dead weight.
		_profile.xp = int(_profile.xp) + 250
	else:
		owned.append(String(finish.id))
		_set_owned(weapon_id, owned)
	_save_profile()

	_reveal.play(weapon_id, finish, duplicate)
	_refresh_crates()
	_rebuild_loadout_tab()
	if _xp_bar:
		_xp_bar.value = int(_profile.xp) % XP_PER_CRATE


func _roll_finish() -> Dictionary:
	var total := 0.0
	for f in FINISHES:
		total += RARITY_WEIGHTS[int(f.rarity)]
	var pick := _rng.randf() * total
	for f in FINISHES:
		pick -= RARITY_WEIGHTS[int(f.rarity)]
		if pick <= 0.0:
			return f
	return FINISHES[0]


func _roll_weapon() -> String:
	var pool: Array[String] = []
	for cat in [0, 1, 2, 3]:
		for id in WeaponDB.ids_in_category(cat):
			pool.append(String(id))
	if pool.is_empty():
		return "ar77"
	return pool[_rng.randi() % pool.size()]


func _finish(id: String) -> Dictionary:
	for f in FINISHES:
		if String(f.id) == id:
			return f
	return {}


func _owned_for(weapon_id: String) -> Array:
	var owned: Dictionary = _profile.owned
	if not owned.has(weapon_id):
		owned[weapon_id] = ["factory"]
	return owned[weapon_id]


func _set_owned(weapon_id: String, list: Array) -> void:
	_profile.owned[weapon_id] = list


func _on_back() -> void:
	_save_profile()
	if ResourceLoader.exists(MENU_SCENE):
		get_tree().change_scene_to_file(MENU_SCENE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back()


## Award progress at the end of a match. Called by the match controller.
static func award_match(rounds_won: int, rounds_played: int, kills: int) -> void:
	var profile: Dictionary = Persistence.get_value("profile", {})
	var xp := int(profile.get("xp", 0))
	var crates := int(profile.get("crates", 0))
	var gained := rounds_played * 40 + rounds_won * 60 + kills * 15
	var before := xp / XP_PER_CRATE
	xp += gained
	crates += (xp / XP_PER_CRATE) - before
	profile["xp"] = xp
	profile["crates"] = crates
	if not profile.has("owned"):
		profile["owned"] = {}
	if not profile.has("equipped"):
		profile["equipped"] = {}
	Persistence.put("profile", profile)
	Persistence.save_now()


## Crate-opening animation: a corner-bracket frame closes in, the rarity colour
## floods, then the finish name resolves. Drawn entirely in code.
class CrateReveal extends Control:
	const DURATION := 2.2

	var t: float = 0.0
	var finish: Dictionary = {}
	var weapon_name: String = ""
	var duplicate: bool = false

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_STOP

	func play(weapon_id: String, p_finish: Dictionary, p_duplicate: bool) -> void:
		finish = p_finish
		duplicate = p_duplicate
		weapon_name = String(WeaponDB.get_def(weapon_id).get("display_name", weapon_id)).to_upper()
		t = 0.0
		visible = true
		set_process(true)
		AudioMgr.play_ui("ui_click")

	func _process(delta: float) -> void:
		t += delta
		queue_redraw()
		if t >= DURATION:
			visible = false
			set_process(false)

	func _gui_input(event: InputEvent) -> void:
		# Let an impatient player skip it.
		if (event is InputEventScreenTouch and event.pressed) or \
				(event is InputEventMouseButton and event.pressed):
			t = DURATION

	func _draw() -> void:
		if finish.is_empty():
			return
		var f := get_theme_default_font()
		var rarity := int(finish.get("rarity", 0))
		var col: Color = RARITY_COLORS[rarity]
		var p := clampf(t / DURATION, 0.0, 1.0)

		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.78 * minf(p * 6.0, 1.0)))

		# Brackets close in over the first third, then hold.
		var close_p := clampf(p / 0.33, 0.0, 1.0)
		var eased := 1.0 - pow(1.0 - close_p, 3.0)
		var target := Rect2(size * 0.5 - Vector2(230, 90), Vector2(460, 180))
		var start := target.grow(220.0)
		var rect := Rect2(
			start.position.lerp(target.position, eased),
			start.size.lerp(target.size, eased))
		UITheme.draw_brackets(self, rect, col, 30.0, 3.0)

		if p < 0.33 or f == null:
			return

		# Rarity flood, then text.
		var text_p := clampf((p - 0.33) / 0.25, 0.0, 1.0)
		draw_rect(rect, Color(col, 0.10 * text_p))

		var c := size * 0.5
		var rarity_text: String = String(RARITY_NAMES[rarity]).to_upper()
		var rw := f.get_string_size(rarity_text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FS_SMALL).x
		draw_string(f, Vector2(c.x - rw * 0.5, rect.position.y + 40.0), rarity_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_SMALL, Color(col, text_p))

		var name_text := String(finish.get("name", "")).to_upper()
		var nw := f.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FS_TITLE).x
		draw_string(f, Vector2(c.x - nw * 0.5, c.y + 8.0), name_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_TITLE, Color(1, 1, 1, text_p))

		var sub := weapon_name
		if duplicate:
			sub += "   ·   DUPLICATE, CONVERTED TO 250 XP"
		var sw := f.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.FS_SMALL).x
		draw_string(f, Vector2(c.x - sw * 0.5, rect.end.y - 34.0), sub,
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_SMALL,
			Color(UITheme.TEXT_DIM, text_p))
