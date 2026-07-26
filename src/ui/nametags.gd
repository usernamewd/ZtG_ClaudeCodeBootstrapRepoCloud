class_name Nametags
extends Control
## Floating name + health labels above teammates.
##
## Enemy names are NEVER shown — not through walls, not in line of sight. Showing
## them would hand the player information the genre deliberately withholds, and
## it is the mirror of the bot fairness rule in docs/BOT_AI.md.
##
## A teammate's tag appears when they are close, or when the crosshair is on
## them at any range, and fades with distance. All drawing happens in one _draw
## over a preallocated list, so N teammates cost no allocations.

const NEAR_DISTANCE := 14.0        ## m: always show within this range
const MAX_DISTANCE := 55.0         ## m: never show beyond this
const CROSSHAIR_ANGLE_DEG := 4.0   ## how close to centre counts as "hovered"
const FADE_IN := 6.0               ## px/s-ish smoothing for alpha changes

var camera: Camera3D = null
var local_player: CharacterBase = null

## Preallocated per-teammate render state, reused every frame.
var _entries: Array[Dictionary] = []
var _combatants: Array[Node] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_process(true)


func bind(p_camera: Camera3D, p_player: CharacterBase) -> void:
	camera = p_camera
	local_player = p_player


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if camera == null or local_player == null:
		return
	var f := get_theme_default_font()
	if f == null:
		return

	_combatants = get_tree().get_nodes_in_group("combatant")
	var cam_pos := camera.global_position
	var cam_fwd := -camera.global_transform.basis.z

	for n in _combatants:
		var mate := n as CharacterBase
		if mate == null or mate == local_player:
			continue
		# The whole point: teammates only.
		if mate.team != local_player.team or not mate.alive:
			continue

		var head := mate.global_position + Vector3.UP * (
			mate.EYE_CROUCH if mate.is_crouching else mate.EYE_STAND) + Vector3.UP * 0.28
		if camera.is_position_behind(head):
			continue
		var to := head - cam_pos
		var dist := to.length()
		if dist > MAX_DISTANCE:
			continue

		var hovered := rad_to_deg(cam_fwd.angle_to(to / maxf(dist, 0.001))) <= CROSSHAIR_ANGLE_DEG
		if dist > NEAR_DISTANCE and not hovered:
			continue

		# Fade out toward the far limit so distant tags don't clutter the screen.
		var alpha := 1.0
		if dist > NEAR_DISTANCE:
			alpha = clampf(1.0 - (dist - NEAR_DISTANCE) / (MAX_DISTANCE - NEAR_DISTANCE), 0.15, 1.0)

		var screen := camera.unproject_position(head)
		# Shrink with distance, but stay legible on a phone.
		var scale := clampf(1.25 - dist / MAX_DISTANCE, 0.62, 1.0) * Settings.hud_scale
		_draw_tag(f, screen, mate, alpha, scale)


func _draw_tag(f: Font, at: Vector2, mate: CharacterBase, alpha: float,
		scale: float) -> void:
	var display_name := String(GameState.players.get(mate.player_id, {}).get("name", ""))
	if display_name == "":
		return
	var fs := int(UITheme.FS_SMALL * scale)
	var team_col := Color(UITheme.team_color(mate.team), alpha)

	var text_size := f.get_string_size(display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var bar_w := maxf(text_size.x, 46.0 * scale)
	var bar_h := 3.0 * scale
	var pad := 5.0 * scale

	var box := Rect2(
		at - Vector2(bar_w * 0.5 + pad, text_size.y + bar_h + pad * 2.0 + 2.0),
		Vector2(bar_w + pad * 2.0, text_size.y + bar_h + pad * 2.0))

	draw_rect(box, Color(0.03, 0.04, 0.05, 0.55 * alpha))
	draw_rect(box, Color(1, 1, 1, 0.08 * alpha), false, 1.0)

	draw_string(f, Vector2(at.x - text_size.x * 0.5, box.position.y + pad + text_size.y * 0.8),
		display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, team_col)

	# Health bar under the name, coloured by the shared ramp so it matches the HUD.
	var frac := clampf(mate.health / maxf(mate.max_health, 1.0), 0.0, 1.0)
	var bar := Rect2(Vector2(at.x - bar_w * 0.5, box.end.y - pad - bar_h),
		Vector2(bar_w, bar_h))
	draw_rect(bar, Color(1, 1, 1, 0.12 * alpha))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * frac, bar.size.y)),
		Color(UITheme.health_color(frac), alpha))

	# Mark a teammate who is planting or defusing — the information that actually
	# changes your decisions.
	var busy := ""
	if mate.has_method("action_progress") and mate.action_progress() > 0.01:
		busy = "PLANTING" if mate.team == GameState.Team.ATK else "DEFUSING"
	if busy != "":
		var bfs := int(UITheme.FS_TINY * scale)
		var bw := f.get_string_size(busy, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs).x
		draw_string(f, Vector2(at.x - bw * 0.5, box.position.y - 4.0), busy,
			HORIZONTAL_ALIGNMENT_LEFT, -1, bfs, Color(UITheme.ACCENT, alpha))
