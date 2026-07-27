class_name Radar
extends Control
## Minimap: map outline, teammate positions and facing, bomb state, and the local
## player at the centre.
##
## Fairness rule, matching the bot perception contract in docs/BOT_AI.md: enemies
## are NEVER shown from position alone. An enemy blip appears only if a living
## teammate can currently see them, and it fades out on a short timer — the radar
## is a communication tool, not wallhacks.

const ENEMY_MEMORY := 3.0        ## s an enemy blip lingers after last being seen
const BLIP_TEAMMATE := 4.0
const BLIP_SELF := 5.0

@export var radar_radius: float = 96.0     ## px, drawing radius
@export var world_span: float = 90.0       ## metres across the full radar
@export var rotate_with_player: bool = true

var map_info: Node = null
var local_player: CharacterBase = null

## enemy id -> {pos: Vector3, time: float}. Preallocated dictionary, entries
## reused; never rebuilt per frame.
var _enemy_seen := {}
var _time := 0.0
var _outline: PackedVector2Array = PackedVector2Array()
var _combatants: Array[Node] = []


func _ready() -> void:
	custom_minimum_size = Vector2(radar_radius * 2.0, radar_radius * 2.0)
	set_process(true)


func bind(p_map: Node, p_player: CharacterBase) -> void:
	map_info = p_map
	local_player = p_player
	_build_outline()


## The outline is baked once from the map's declared playable bounds rather than
## traced from geometry every frame.
func _build_outline() -> void:
	_outline.clear()
	if map_info == null:
		return
	if map_info.has_method("get_radar_outline"):
		var pts = map_info.get_radar_outline()
		if pts is PackedVector2Array:
			_outline = pts
			return
	# Fall back to the playable AABB corners...
	if map_info.has_method("get_playable_bounds"):
		var b = map_info.get_playable_bounds()
		if b is AABB:
			_outline_from_aabb(b as AABB)
			return
	# ...and failing that, derive bounds from the map's own visual extent, so the
	# radar still shows the playable area on a map that predates MapInfo.
	var derived := _visual_aabb(map_info)
	if derived.size.length() > 1.0:
		_outline_from_aabb(derived)
		world_span = maxf(derived.size.x, derived.size.z) * 0.55


func _outline_from_aabb(aabb: AABB) -> void:
	_outline.append(Vector2(aabb.position.x, aabb.position.z))
	_outline.append(Vector2(aabb.end.x, aabb.position.z))
	_outline.append(Vector2(aabb.end.x, aabb.end.z))
	_outline.append(Vector2(aabb.position.x, aabb.end.z))


func _visual_aabb(n: Node, acc := AABB()) -> AABB:
	if n is VisualInstance3D:
		var vi := n as VisualInstance3D
		var a: AABB = vi.global_transform * vi.get_aabb()
		acc = a if acc.size == Vector3.ZERO else acc.merge(a)
	for c in n.get_children():
		acc = _visual_aabb(c, acc)
	return acc


func _process(delta: float) -> void:
	_time += delta
	_refresh_enemy_knowledge()
	queue_redraw()


## Build the enemy blip set from what OUR TEAM can actually see this frame.
func _refresh_enemy_knowledge() -> void:
	if local_player == null:
		return
	_combatants = get_tree().get_nodes_in_group("combatant")

	for n in _combatants:
		var c := n as CharacterBase
		if c == null or not c.alive or c.team == local_player.team:
			continue
		if _team_can_see(c):
			var e: Dictionary = _enemy_seen.get(c.player_id, {})
			if e.is_empty():
				_enemy_seen[c.player_id] = {"pos": c.global_position, "time": _time}
			else:
				e.pos = c.global_position
				e.time = _time

	# Expire stale sightings.
	for id in _enemy_seen.keys():
		if _time - float(_enemy_seen[id].time) > ENEMY_MEMORY:
			_enemy_seen.erase(id)


func _team_can_see(enemy: CharacterBase) -> bool:
	for n in _combatants:
		var mate := n as CharacterBase
		if mate == null or not mate.alive or mate.team != local_player.team:
			continue
		# Bots publish their own vision; reuse it rather than re-raycasting.
		if mate is BotBrain:
			var b := mate as BotBrain
			if b.target == enemy and b.target_visible:
				return true
			continue
		if mate == local_player and _player_sees(enemy):
			return true
	return false


func _player_sees(enemy: CharacterBase) -> bool:
	if local_player == null:
		return false
	var eye := local_player.eye_position()
	var to := enemy.global_position + Vector3.UP * 1.0 - eye
	var dist := to.length()
	if dist > 60.0:
		return false
	var facing: Vector3 = -local_player.global_transform.basis.z
	if local_player.has_method("look_direction"):
		facing = local_player.look_direction()
	if rad_to_deg(facing.angle_to(to / maxf(dist, 0.001))) > 55.0:
		return false
	var q := PhysicsRayQueryParameters3D.create(eye, eye + to,
		CharacterBase.LAYER_WORLD | CharacterBase.LAYER_CLIP)
	q.exclude = [local_player.get_rid()]
	# A Control has no 3D world of its own; borrow the player's.
	return local_player.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


# ---------------------------------------------------------------------------

func _draw() -> void:
	var c := size * 0.5
	var r := radar_radius

	# Dish
	draw_circle(c, r, Color(0.031, 0.039, 0.047, 0.86))
	draw_arc(c, r, 0.0, TAU, 48, UITheme.EDGE, 1.0, true)

	if local_player == null:
		return

	var yaw := 0.0
	if rotate_with_player:
		# Rotate the world so the player always faces up — the orientation a
		# player can read without thinking.
		yaw = local_player.global_rotation.y

	var scale_px := (r * 2.0) / maxf(world_span, 1.0)
	var origin := Vector2(local_player.global_position.x, local_player.global_position.z)

	_draw_outline(c, origin, yaw, scale_px, r)
	_draw_sites(c, origin, yaw, scale_px, r)
	_draw_bomb(c, origin, yaw, scale_px, r)
	_draw_teammates(c, origin, yaw, scale_px, r)
	_draw_enemies(c, origin, yaw, scale_px, r)
	_draw_self(c)

	# North indicator so absolute orientation is still recoverable.
	var n := _rot(Vector2(0.0, -1.0), -yaw) * (r - 8.0)
	draw_circle(c + n, 2.0, UITheme.TEXT_FAINT)


func _draw_outline(c: Vector2, origin: Vector2, yaw: float, s: float, r: float) -> void:
	if _outline.size() < 2:
		return
	for i in _outline.size():
		var a := _to_radar(_outline[i], c, origin, yaw, s)
		var b := _to_radar(_outline[(i + 1) % _outline.size()], c, origin, yaw, s)
		# Only draw the portion inside the dish; a full clip isn't worth the cost
		# at this scale, so skip segments fully outside.
		if a.distance_to(c) > r * 1.6 and b.distance_to(c) > r * 1.6:
			continue
		draw_line(a, b, Color(1, 1, 1, 0.13), 1.0)


func _draw_sites(c: Vector2, origin: Vector2, yaw: float, s: float, r: float) -> void:
	if map_info == null:
		return
	var sites = map_info.get("bomb_sites")
	if not (sites is Dictionary):
		return
	for key in (sites as Dictionary):
		var area = (sites as Dictionary)[key]
		if not (area is Node3D):
			continue
		var p := _to_radar(Vector2((area as Node3D).global_position.x,
			(area as Node3D).global_position.z), c, origin, yaw, s)
		if p.distance_to(c) > r:
			continue
		var col := UITheme.ACCENT_DIM
		draw_arc(p, 11.0, 0.0, TAU, 16, col, 1.5)
		var f := get_theme_default_font()
		if f:
			draw_string(f, p + Vector2(-4, 5), String(key),
				HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_SMALL, col)


func _draw_bomb(c: Vector2, origin: Vector2, yaw: float, s: float, r: float) -> void:
	var bomb := get_tree().get_first_node_in_group("planted_bomb")
	if bomb == null:
		bomb = get_tree().get_first_node_in_group("dropped_bomb")
	if bomb == null or not (bomb is Node3D):
		return
	var bp := (bomb as Node3D).global_position
	var p := _to_radar(Vector2(bp.x, bp.z), c, origin, yaw, s)
	p = _clamp_to_dish(p, c, r)
	# Pulse so a planted bomb is impossible to miss.
	var pulse := 3.5 + sin(_time * 9.0) * 1.8
	draw_circle(p, pulse, UITheme.BAD)
	draw_arc(p, 8.0, 0.0, TAU, 12, UITheme.BAD, 1.0)


func _draw_teammates(c: Vector2, origin: Vector2, yaw: float, s: float, r: float) -> void:
	var col := UITheme.team_color(local_player.team)
	for n in _combatants:
		var mate := n as CharacterBase
		if mate == null or mate == local_player or mate.team != local_player.team:
			continue
		var p := _to_radar(Vector2(mate.global_position.x, mate.global_position.z),
			c, origin, yaw, s)
		if p.distance_to(c) > r:
			continue
		if not mate.alive:
			# Dead teammates leave a faint cross so you know where you lost them.
			draw_line(p + Vector2(-3, -3), p + Vector2(3, 3), Color(col, 0.3), 1.0)
			draw_line(p + Vector2(-3, 3), p + Vector2(3, -3), Color(col, 0.3), 1.0)
			continue
		_draw_facing_blip(p, mate.global_rotation.y - yaw, col, BLIP_TEAMMATE)


func _draw_enemies(c: Vector2, origin: Vector2, yaw: float, s: float, r: float) -> void:
	for id in _enemy_seen:
		var e: Dictionary = _enemy_seen[id]
		var age: float = _time - float(e.time)
		var alpha: float = clampf(1.0 - age / ENEMY_MEMORY, 0.0, 1.0)
		var wp: Vector3 = e.pos
		var p := _to_radar(Vector2(wp.x, wp.z), c, origin, yaw, s)
		if p.distance_to(c) > r:
			continue
		var col := Color(UITheme.BAD, alpha)
		# Enemies are a hollow diamond — a different shape, not just a different
		# colour, so it reads for colour-blind players too.
		var d := 4.5
		draw_polyline(PackedVector2Array([
			p + Vector2(0, -d), p + Vector2(d, 0), p + Vector2(0, d),
			p + Vector2(-d, 0), p + Vector2(0, -d)]), col, 1.5)


func _draw_self(c: Vector2) -> void:
	# The local player is a filled arrow pointing up (radar is player-relative).
	var pts := PackedVector2Array([
		c + Vector2(0, -BLIP_SELF - 1.0),
		c + Vector2(BLIP_SELF * 0.8, BLIP_SELF),
		c + Vector2(0, BLIP_SELF * 0.45),
		c + Vector2(-BLIP_SELF * 0.8, BLIP_SELF)])
	draw_colored_polygon(pts, Color.WHITE)


func _draw_facing_blip(p: Vector2, facing: float, col: Color, radius: float) -> void:
	draw_circle(p, radius, col)
	# Short whisker showing which way they're looking — turns the radar into
	# useful information instead of dots.
	var dir := _rot(Vector2(0.0, -1.0), facing)
	draw_line(p, p + dir * (radius + 4.0), col, 1.5)


func _to_radar(world_xz: Vector2, c: Vector2, origin: Vector2, yaw: float,
		s: float) -> Vector2:
	return c + _rot((world_xz - origin) * s, -yaw)


func _rot(v: Vector2, a: float) -> Vector2:
	var ca := cos(a)
	var sa := sin(a)
	return Vector2(v.x * ca - v.y * sa, v.x * sa + v.y * ca)


## Keep an off-radar marker on the rim rather than dropping it, so the bomb is
## always locatable.
func _clamp_to_dish(p: Vector2, c: Vector2, r: float) -> Vector2:
	var d := p - c
	if d.length() <= r - 4.0:
		return p
	return c + d.normalized() * (r - 4.0)
