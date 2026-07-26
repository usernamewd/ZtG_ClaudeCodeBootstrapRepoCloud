class_name KillFeed
extends VBoxContainer
## Rolling kill notifications in the top-right.
##
## Entries are drawn as `killer  [weapon]  victim`, tinted by team so you can
## read a trade at a glance, with the local player's own kills and deaths
## highlighted. Rows are pooled: a fixed set of entries is reused forever, so a
## busy round allocates nothing.

const MAX_ROWS := 5
const ROW_LIFE := 5.5
const FADE_TIME := 0.6

var local_player_id: int = -1

var _rows: Array[Entry] = []


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_BEGIN
	add_theme_constant_override("separation", 4)
	for i in MAX_ROWS:
		var e := Entry.new()
		e.visible = false
		add_child(e)
		_rows.append(e)
	if not GameState.kill_feed.is_connected(_on_kill):
		GameState.kill_feed.connect(_on_kill)
	set_process(true)


func _on_kill(killer_id: int, victim_id: int, weapon_id: String, headshot: bool) -> void:
	push_entry(killer_id, victim_id, weapon_id, headshot)


func push_entry(killer_id: int, victim_id: int, weapon_id: String,
		headshot: bool) -> void:
	# Scroll: reuse the oldest row by moving it to the bottom of the list.
	var row: Entry = _rows.pop_front()
	_rows.append(row)
	move_child(row, get_child_count() - 1)
	row.setup(killer_id, victim_id, weapon_id, headshot, local_player_id)


func _process(delta: float) -> void:
	for e in _rows:
		e.tick(delta)


func clear_all() -> void:
	for e in _rows:
		e.visible = false


## One notification row. Draws itself so there is no per-entry node churn.
class Entry extends Control:
	var age: float = 0.0
	var life: float = 0.0
	var text_killer: String = ""
	var text_victim: String = ""
	var weapon_label: String = ""
	var color_killer: Color = UITheme.TEXT
	var color_victim: Color = UITheme.TEXT
	var highlight: bool = false
	var is_headshot: bool = false

	func _init() -> void:
		custom_minimum_size = Vector2(0, 26)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func setup(killer_id: int, victim_id: int, weapon_id: String,
			headshot: bool, local_id: int) -> void:
		var killer: Dictionary = GameState.players.get(killer_id, {})
		var victim: Dictionary = GameState.players.get(victim_id, {})
		text_killer = String(killer.get("name", "")) if not killer.is_empty() else ""
		text_victim = String(victim.get("name", "?"))
		color_killer = UITheme.team_color(int(killer.get("team", 0))) if not killer.is_empty() else UITheme.TEXT_DIM
		color_victim = UITheme.team_color(int(victim.get("team", 0))) if not victim.is_empty() else UITheme.TEXT_DIM

		var def := WeaponDB.get_def(weapon_id)
		weapon_label = String(def.get("display_name", weapon_id)).to_upper()
		if weapon_id == "bomb":
			weapon_label = "DETONATION"
		elif weapon_id == "":
			weapon_label = "—"

		is_headshot = headshot
		highlight = killer_id == local_id or victim_id == local_id
		age = 0.0
		life = ROW_LIFE
		visible = true
		queue_redraw()

	func tick(delta: float) -> void:
		if not visible:
			return
		age += delta
		if age >= life:
			visible = false
		queue_redraw()

	func _draw() -> void:
		var f := get_theme_default_font()
		if f == null:
			return
		var alpha := 1.0
		if age > life - FADE_TIME:
			alpha = clampf((life - age) / FADE_TIME, 0.0, 1.0)

		# Right-aligned: measure back from the right edge so entries line up on
		# the side they're anchored to.
		var fs := UITheme.FS_SMALL
		var pad := 8.0
		var x := size.x - pad
		var y := size.y * 0.5 + fs * 0.35

		var victim_w := f.get_string_size(text_victim, HORIZONTAL_ALIGNMENT_LEFT,
			-1, fs).x
		x -= victim_w
		draw_string(f, Vector2(x, y), text_victim, HORIZONTAL_ALIGNMENT_LEFT, -1,
			fs, Color(color_victim, alpha))

		var mid := " %s " % weapon_label
		if is_headshot:
			mid = " %s ⌖ " % weapon_label
		var mid_w := f.get_string_size(mid, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		x -= mid_w
		draw_string(f, Vector2(x, y), mid, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			Color(UITheme.ACCENT if is_headshot else UITheme.TEXT_DIM, alpha))

		if text_killer != "":
			var killer_w := f.get_string_size(text_killer,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			x -= killer_w
			draw_string(f, Vector2(x, y), text_killer, HORIZONTAL_ALIGNMENT_LEFT,
				-1, fs, Color(color_killer, alpha))

		# The local player's own kills/deaths get a backing plate so they stand
		# out from teammate chatter.
		if highlight:
			var r := Rect2(Vector2(x - 6.0, 1.0),
				Vector2(size.x - x + 4.0, size.y - 2.0))
			draw_rect(r, Color(UITheme.ACCENT.r, UITheme.ACCENT.g,
				UITheme.ACCENT.b, 0.10 * alpha))
			draw_rect(r, Color(UITheme.ACCENT, 0.30 * alpha), false, 1.0)
