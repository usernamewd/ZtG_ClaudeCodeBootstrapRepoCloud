class_name UITheme
extends RefCounted
## The game's original visual identity, built in code so every screen shares one
## source of truth and nothing depends on a binary .theme file.
##
## The look: near-black slate panels with a 1 px light edge, a single warm orange
## accent, thin geometric shapes, generous touch targets. Deliberately austere —
## a tactical readout rather than a console UI.

# Palette
const BG            := Color(0.047, 0.055, 0.066)      # page background
const PANEL         := Color(0.078, 0.090, 0.105, 0.94)
const PANEL_SOLID   := Color(0.086, 0.098, 0.113)
const PANEL_RAISED  := Color(0.117, 0.133, 0.152)
const EDGE          := Color(1, 1, 1, 0.10)
const EDGE_STRONG   := Color(1, 1, 1, 0.20)

const ACCENT        := Color(1.0, 0.478, 0.102)        # #FF7A1A
const ACCENT_DIM    := Color(1.0, 0.478, 0.102, 0.35)
const ACCENT_COOL   := Color(0.325, 0.643, 1.0)        # defenders / info

const TEXT          := Color(0.902, 0.925, 0.945)
const TEXT_DIM      := Color(0.588, 0.627, 0.667)
const TEXT_FAINT    := Color(0.392, 0.427, 0.463)

const OK            := Color(0.353, 0.855, 0.478)
const WARN          := Color(1.0, 0.769, 0.220)
const BAD           := Color(0.949, 0.318, 0.310)

# Team identity — also used by nametags, radar blips and the scoreboard.
const TEAM_ATK      := Color(1.0, 0.545, 0.208)        # Havoc, warm
const TEAM_DEF      := Color(0.361, 0.686, 1.0)        # Aegis, cool

# Metrics. Touch targets are sized for a thumb, not a mouse.
const TOUCH_MIN     := 56.0
const RADIUS        := 6.0
const PAD           := 14.0
const GAP           := 10.0

const FS_HUGE       := 42
const FS_TITLE      := 28
const FS_HEAD       := 20
const FS_BODY       := 16
const FS_SMALL      := 13
const FS_TINY       := 11


static func panel_box(bg := PANEL, edge := EDGE, radius := RADIUS) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(radius))
	s.set_border_width_all(1)
	s.border_color = edge
	s.set_content_margin_all(PAD)
	return s


static func flat_box(bg: Color, radius := RADIUS) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(radius))
	return s


## Accent bar on the left edge — the recurring motif that marks a live/selected
## row without needing an icon.
static func marked_box(bg: Color, mark := ACCENT, radius := RADIUS) -> StyleBoxFlat:
	var s := flat_box(bg, radius)
	s.set_content_margin_all(PAD)
	s.border_width_left = 3
	s.border_color = mark
	return s


static func button_box(bg: Color, edge: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(RADIUS))
	s.set_border_width_all(1)
	s.border_color = edge
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s


## Build the project-wide Theme. Applied once to each screen's root Control.
static func build() -> Theme:
	var t := Theme.new()
	t.default_font_size = FS_BODY

	# Buttons
	t.set_stylebox("normal", "Button", button_box(PANEL_RAISED, EDGE))
	t.set_stylebox("hover", "Button", button_box(Color(0.145, 0.164, 0.188), EDGE_STRONG))
	t.set_stylebox("pressed", "Button", button_box(Color(0.196, 0.129, 0.055), ACCENT))
	t.set_stylebox("disabled", "Button", button_box(Color(0.086, 0.094, 0.105), Color(1, 1, 1, 0.05)))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", ACCENT)
	t.set_color("font_disabled_color", "Button", TEXT_FAINT)
	t.set_font_size("font_size", "Button", FS_BODY)

	# Panels
	t.set_stylebox("panel", "PanelContainer", panel_box())
	t.set_stylebox("panel", "Panel", panel_box())

	# Labels
	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", FS_BODY)

	# Sliders — chunky enough to drag with a thumb
	var slider_bg := flat_box(Color(0.145, 0.160, 0.180), 3)
	slider_bg.content_margin_top = 5
	slider_bg.content_margin_bottom = 5
	t.set_stylebox("slider", "HSlider", slider_bg)
	t.set_stylebox("grabber_area", "HSlider", flat_box(ACCENT, 3))
	t.set_stylebox("grabber_area_highlight", "HSlider", flat_box(ACCENT, 3))

	# Tabs
	t.set_stylebox("tab_selected", "TabContainer", marked_box(PANEL_RAISED))
	t.set_stylebox("tab_unselected", "TabContainer", flat_box(Color(0.070, 0.078, 0.090)))
	t.set_stylebox("panel", "TabContainer", panel_box())
	t.set_color("font_selected_color", "TabContainer", ACCENT)
	t.set_color("font_unselected_color", "TabContainer", TEXT_DIM)

	# Scroll
	t.set_stylebox("scroll", "VScrollBar", flat_box(Color(1, 1, 1, 0.04), 3))
	t.set_stylebox("grabber", "VScrollBar", flat_box(Color(1, 1, 1, 0.16), 3))
	t.set_stylebox("grabber_highlight", "VScrollBar", flat_box(ACCENT_DIM, 3))

	# Checkboxes read as a switch in this UI; styled by the settings screen.
	t.set_color("font_color", "CheckButton", TEXT)
	t.set_color("font_color", "CheckBox", TEXT)

	t.set_color("font_color", "LineEdit", TEXT)
	t.set_stylebox("normal", "LineEdit", panel_box(Color(0.043, 0.050, 0.058), EDGE, 4))
	t.set_stylebox("focus", "LineEdit", panel_box(Color(0.043, 0.050, 0.058), ACCENT, 4))

	return t


static func team_color(team: int) -> Color:
	return TEAM_ATK if team == GameState.Team.ATK else TEAM_DEF


## Health colour ramp: green -> amber -> red, so a glance at the number is enough.
static func health_color(fraction: float) -> Color:
	if fraction > 0.55:
		return OK
	if fraction > 0.25:
		return WARN
	return BAD


## Money is shown green when a full buy is affordable, dim otherwise, so the buy
## menu communicates affordability without reading prices.
static func money_color(amount: int) -> Color:
	if amount >= 4000:
		return OK
	if amount >= 2000:
		return WARN
	return TEXT_DIM


# --- Shared drawing primitives ------------------------------------------------

## Corner-bracket frame — used for the buy menu selection, crate reveals and the
## scoreboard header. Cheap and distinctive.
static func draw_brackets(ci: CanvasItem, rect: Rect2, color: Color,
		length := 14.0, thickness := 2.0) -> void:
	var l := minf(length, minf(rect.size.x, rect.size.y) * 0.45)
	var corners := [
		[rect.position, Vector2(1, 0), Vector2(0, 1)],
		[Vector2(rect.end.x, rect.position.y), Vector2(-1, 0), Vector2(0, 1)],
		[Vector2(rect.position.x, rect.end.y), Vector2(1, 0), Vector2(0, -1)],
		[rect.end, Vector2(-1, 0), Vector2(0, -1)],
	]
	for c in corners:
		var p: Vector2 = c[0]
		ci.draw_line(p, p + (c[1] as Vector2) * l, color, thickness)
		ci.draw_line(p, p + (c[2] as Vector2) * l, color, thickness)


## Segmented bar (health, armour, round score). Segments read faster than a
## smooth bar at a glance.
static func draw_segmented_bar(ci: CanvasItem, rect: Rect2, fraction: float,
		color: Color, segments := 10, gap := 2.0) -> void:
	var seg_w := (rect.size.x - gap * (segments - 1)) / float(segments)
	var filled := fraction * segments
	for i in segments:
		var x := rect.position.x + i * (seg_w + gap)
		var r := Rect2(Vector2(x, rect.position.y), Vector2(seg_w, rect.size.y))
		if i + 1 <= filled:
			ci.draw_rect(r, color)
		elif i < filled:
			# Partial segment: fill proportionally so the bar is readable at low
			# health instead of snapping between whole segments.
			var f := filled - i
			ci.draw_rect(Rect2(r.position, Vector2(r.size.x * f, r.size.y)), color)
			ci.draw_rect(Rect2(r.position + Vector2(r.size.x * f, 0),
				Vector2(r.size.x * (1.0 - f), r.size.y)), Color(1, 1, 1, 0.07))
		else:
			ci.draw_rect(r, Color(1, 1, 1, 0.07))
