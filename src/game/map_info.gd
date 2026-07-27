class_name MapInfo
extends Node3D
## The interface every map root implements (docs/ARCHITECTURE.md "Match flow",
## docs/MAP_DESIGN.md "Required per-map data").
##
## A map is authored as a plain node tree; this script turns that tree into the
## typed handles the match controller, bot AI and radar consume:
##
##   ATKSpawns/*      Marker3D  -> atk_spawns
##   DEFSpawns/*      Marker3D  -> def_spawns
##   BombSites/A|B    Area3D    -> bomb_sites
##   BuyZones/ATK|DEF Area3D    -> buy_zones   (keyed by team int)
##   NavRegion        NavigationRegion3D -> nav_region
##   BotPoints/*      Marker3D  (meta kind/site) -> bot_points
##   DummySpawns/*    Marker3D  -> dummy_spawns (Phase 1 test ranges only)
##
## Everything is resolved once in _ready. Point-in-volume queries run against
## precomputed inverse transforms and half-extents, so site_containing() and
## in_buy_zone() allocate nothing and can be called every tick.

## Mirrors GameState.Team; duplicated as plain ints so a map can be inspected by
## tooling that runs without the autoloads.
const TEAM_ATK := 0
const TEAM_DEF := 1

## The radar texture the HUD maps into, in pixels.
const RADAR_PX := 256.0
## radar_scale is metres per radar pixel. Some map builders store the full span
## in metres instead; anything at or above this is treated as a span, because a
## 256 px radar at >= 1 m/px would cover 256 m — larger than any map in this
## project.
const RADAR_SPAN_CUTOFF := 1.0

## Lateral/backward offset applied to each extra wrap of get_spawn(), so a team
## larger than the spawn count does not stack bodies inside each other.
const SPAWN_NUDGE := 1.2

const NODE_ATK_SPAWNS := "ATKSpawns"
const NODE_DEF_SPAWNS := "DEFSpawns"
const NODE_BOMB_SITES := "BombSites"
const NODE_BUY_ZONES := "BuyZones"
const NODE_NAV_REGION := "NavRegion"
const NODE_BOT_POINTS := "BotPoints"
const NODE_DUMMY_SPAWNS := "DummySpawns"

## World XZ of the radar's top-left corner.
@export var radar_origin: Vector2 = Vector2(-32.0, -32.0)
## Metres per radar pixel across a 256 px radar (see RADAR_SPAN_CUTOFF).
@export var radar_scale: float = 0.25
## World size (X, Z) of the playable rectangle. Zero falls back to the square
## implied by the radar metadata.
@export var playable_extent: Vector2 = Vector2.ZERO
@export var playable_floor_y: float = -2.0
@export var playable_ceiling_y: float = 18.0

var atk_spawns: Array[Marker3D] = []
var def_spawns: Array[Marker3D] = []
## "A"/"B" -> Area3D
var bomb_sites: Dictionary = {}
## team int -> Area3D
var buy_zones: Dictionary = {}
var nav_region: NavigationRegion3D = null
## Authored bot positions; each carries meta "kind" (hold/peek/plant/retake/
## rotate) and meta "site" ("A"/"B"/"mid"/"").
var bot_points: Array[Marker3D] = []
## Optional target positions for the Phase 1 shooting range.
var dummy_spawns: Array[Marker3D] = []

# Flattened, preallocated volume tests. One entry per CollisionShape3D.
var _site_keys: PackedStringArray = PackedStringArray()
var _site_inv: Array[Transform3D] = []
var _site_half: Array[Vector3] = []
var _buy_team: PackedInt32Array = PackedInt32Array()
var _buy_inv: Array[Transform3D] = []
var _buy_half: Array[Vector3] = []

var _radar_m_per_px: float = 0.25
var _bounds: AABB = AABB()
var _outline: PackedVector2Array = PackedVector2Array()


func _ready() -> void:
	_resolve_spawns()
	_resolve_bomb_sites()
	_resolve_buy_zones()
	_resolve_nav_region()
	_resolve_bot_points()
	_resolve_dummy_spawns()
	_build_radar_cache()


# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

func _resolve_spawns() -> void:
	atk_spawns.clear()
	def_spawns.clear()
	_gather_markers(get_node_or_null(NODE_ATK_SPAWNS), atk_spawns)
	_gather_markers(get_node_or_null(NODE_DEF_SPAWNS), def_spawns)
	if atk_spawns.is_empty():
		push_error("MapInfo '%s': no Marker3D under %s/ — attackers will spawn at the origin"
			% [name, NODE_ATK_SPAWNS])
	if def_spawns.is_empty():
		push_error("MapInfo '%s': no Marker3D under %s/ — defenders will spawn at the origin"
			% [name, NODE_DEF_SPAWNS])


func _resolve_bomb_sites() -> void:
	bomb_sites.clear()
	_site_keys.clear()
	_site_inv.clear()
	_site_half.clear()
	var holder := get_node_or_null(NODE_BOMB_SITES)
	if holder == null:
		push_error("MapInfo '%s': missing %s node — the bomb cannot be planted"
			% [name, NODE_BOMB_SITES])
		return
	for child in holder.get_children():
		var area := child as Area3D
		if area == null:
			continue
		var key := String(area.name).to_upper()
		bomb_sites[key] = area
		_collect_volumes(area, key, TEAM_ATK, true)
	for required in ["A", "B"]:
		if not bomb_sites.has(required):
			push_error("MapInfo '%s': missing %s/%s (Area3D)"
				% [name, NODE_BOMB_SITES, required])


func _resolve_buy_zones() -> void:
	buy_zones.clear()
	_buy_team.clear()
	_buy_inv.clear()
	_buy_half.clear()
	var holder := get_node_or_null(NODE_BUY_ZONES)
	if holder == null:
		push_error("MapInfo '%s': missing %s node — buying will be allowed anywhere"
			% [name, NODE_BUY_ZONES])
		return
	for child in holder.get_children():
		var area := child as Area3D
		if area == null:
			continue
		var team := _team_from_name(String(area.name))
		if team < 0:
			push_error("MapInfo '%s': %s/%s is not named ATK or DEF; ignored"
				% [name, NODE_BUY_ZONES, area.name])
			continue
		buy_zones[team] = area
		_collect_volumes(area, "", team, false)
	if not buy_zones.has(TEAM_ATK):
		push_error("MapInfo '%s': missing %s/ATK (Area3D)" % [name, NODE_BUY_ZONES])
	if not buy_zones.has(TEAM_DEF):
		push_error("MapInfo '%s': missing %s/DEF (Area3D)" % [name, NODE_BUY_ZONES])


func _resolve_nav_region() -> void:
	nav_region = get_node_or_null(NODE_NAV_REGION) as NavigationRegion3D
	if nav_region == null:
		push_error("MapInfo '%s': missing %s (NavigationRegion3D) — bots cannot path"
			% [name, NODE_NAV_REGION])
		return
	if nav_region.navigation_mesh == null:
		push_error("MapInfo '%s': %s has no NavigationMesh resource"
			% [name, NODE_NAV_REGION])


func _resolve_bot_points() -> void:
	bot_points.clear()
	_gather_markers(get_node_or_null(NODE_BOT_POINTS), bot_points)


func _resolve_dummy_spawns() -> void:
	dummy_spawns.clear()
	_gather_markers(get_node_or_null(NODE_DUMMY_SPAWNS), dummy_spawns)


func _gather_markers(holder: Node, out: Array[Marker3D]) -> void:
	if holder == null:
		return
	for child in holder.get_children():
		var m := child as Marker3D
		if m != null:
			out.append(m)


func _team_from_name(n: String) -> int:
	var u := n.to_upper()
	if u.begins_with("ATK") or u == "0" or u == "HAVOC":
		return TEAM_ATK
	if u.begins_with("DEF") or u == "1" or u == "AEGIS":
		return TEAM_DEF
	return -1


## Flattens every CollisionShape3D under `area` into the point-test arrays.
func _collect_volumes(area: Area3D, site_key: String, team: int, is_site: bool) -> void:
	var found := 0
	for node in _descendants(area):
		var cs := node as CollisionShape3D
		if cs == null or cs.disabled or cs.shape == null:
			continue
		found += 1
		var inv := cs.global_transform.affine_inverse()
		var half := _shape_half_extents(cs.shape)
		if is_site:
			_site_keys.append(site_key)
			_site_inv.append(inv)
			_site_half.append(half)
		else:
			_buy_team.append(team)
			_buy_inv.append(inv)
			_buy_half.append(half)
	if found == 0:
		push_error("MapInfo '%s': Area3D '%s' has no enabled CollisionShape3D"
			% [name, area.name])


## Non-box shapes are tested as their bounding box: these volumes are trigger
## regions, and a few centimetres at the corners never decides a round.
func _shape_half_extents(shape: Shape3D) -> Vector3:
	if shape is BoxShape3D:
		return (shape as BoxShape3D).size * 0.5
	if shape is SphereShape3D:
		var r := (shape as SphereShape3D).radius
		return Vector3(r, r, r)
	if shape is CylinderShape3D:
		var cyl := shape as CylinderShape3D
		return Vector3(cyl.radius, cyl.height * 0.5, cyl.radius)
	if shape is CapsuleShape3D:
		var cap := shape as CapsuleShape3D
		return Vector3(cap.radius, cap.height * 0.5, cap.radius)
	push_warning("MapInfo '%s': unsupported zone shape %s; using a 1 m cube"
		% [name, shape.get_class()])
	return Vector3(0.5, 0.5, 0.5)


func _descendants(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			out.append(c)
			stack.append(c)
	return out


func _build_radar_cache() -> void:
	_radar_m_per_px = radar_scale
	if _radar_m_per_px >= RADAR_SPAN_CUTOFF:
		_radar_m_per_px = radar_scale / RADAR_PX
	if _radar_m_per_px <= 0.0:
		push_error("MapInfo '%s': radar_scale must be > 0" % name)
		_radar_m_per_px = 0.25

	var span := _radar_m_per_px * RADAR_PX
	var ext := playable_extent
	if ext.x <= 0.0 or ext.y <= 0.0:
		ext = Vector2(span, span)
	_bounds = AABB(
		Vector3(radar_origin.x, playable_floor_y, radar_origin.y),
		Vector3(ext.x, maxf(playable_ceiling_y - playable_floor_y, 1.0), ext.y))

	_outline.clear()
	_outline.append(Vector2(_bounds.position.x, _bounds.position.z))
	_outline.append(Vector2(_bounds.end.x, _bounds.position.z))
	_outline.append(Vector2(_bounds.end.x, _bounds.end.z))
	_outline.append(Vector2(_bounds.position.x, _bounds.end.z))


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## World transform for the `index`-th member of `team`. Wraps around when a team
## is bigger than its spawn list, offsetting each extra wrap sideways and behind
## the marker so bodies never spawn inside one another.
func get_spawn(team: int, index: int) -> Transform3D:
	var list: Array[Marker3D] = def_spawns if team == TEAM_DEF else atk_spawns
	if list.is_empty():
		return _fallback_spawn(team, index)
	var n := list.size()
	var i := posmod(index, n)
	var lap := int(floor(float(index) / float(n)))
	var marker := list[i]
	var xf := marker.global_transform
	xf.basis = xf.basis.orthonormalized()
	if lap > 0:
		var side := 1.0 if (lap % 2) == 1 else -1.0
		var step := float((lap + 1) / 2)
		# basis.x is the marker's right, basis.z its back (forward is -Z).
		xf.origin += xf.basis.x * (side * step * SPAWN_NUDGE)
		xf.origin += xf.basis.z * (float(lap) * SPAWN_NUDGE * 0.6)
	return xf


func _fallback_spawn(team: int, index: int) -> Transform3D:
	var side := -18.0 if team == TEAM_DEF else 18.0
	var xf := Transform3D.IDENTITY
	xf.origin = Vector3(float(index - 2) * 2.0, 1.0, side)
	# Face the middle of the map so a spawn without markers is still playable.
	xf.basis = Basis(Vector3.UP, PI if team == TEAM_DEF else 0.0)
	return xf


## "A", "B" or "" — which bomb site contains `pos`.
func site_containing(pos: Vector3) -> String:
	for i in _site_keys.size():
		if _inside(_site_inv[i], _site_half[i], pos):
			return _site_keys[i]
	return ""


func in_buy_zone(team: int, pos: Vector3) -> bool:
	for i in _buy_team.size():
		if _buy_team[i] != team:
			continue
		if _inside(_buy_inv[i], _buy_half[i], pos):
			return true
	return false


func _inside(inv: Transform3D, half: Vector3, pos: Vector3) -> bool:
	var l := inv * pos
	return absf(l.x) <= half.x and absf(l.y) <= half.y and absf(l.z) <= half.z


## World position -> radar pixel, with (0, 0) at radar_origin.
func world_to_radar(pos: Vector3) -> Vector2:
	return Vector2(pos.x - radar_origin.x, pos.z - radar_origin.y) / _radar_m_per_px


## Radar pixel -> world XZ (y is left at 0).
func radar_to_world(px: Vector2) -> Vector3:
	return Vector3(radar_origin.x + px.x * _radar_m_per_px, 0.0,
		radar_origin.y + px.y * _radar_m_per_px)


func radar_meters_per_pixel() -> float:
	return _radar_m_per_px


func get_playable_bounds() -> AABB:
	return _bounds


## World-space XZ outline the radar traces. The rectangle of the playable area
## by default; a map with a distinctive footprint can override this.
func get_radar_outline() -> PackedVector2Array:
	return _outline


## Authored bot position, or null when the map has none matching.
## `kind` is hold/peek/plant/retake/rotate; `site` is "A"/"B"/"mid" or "" for any.
func pick_bot_point(kind: String, _team: int, site: String, player_id: int) -> Variant:
	if bot_points.is_empty():
		return null
	var want := site.to_upper()
	var count := _count_bot_points(kind, want)
	if count == 0 and want != "":
		want = ""
		count = _count_bot_points(kind, want)
	if count == 0:
		return null
	# Deterministic per player so a squad spreads over the available posts
	# instead of piling onto the first one.
	var pick := posmod(player_id, count)
	var seen := 0
	for m in bot_points:
		if not _bot_point_matches(m, kind, want):
			continue
		if seen == pick:
			return m.global_position
		seen += 1
	return null


func _count_bot_points(kind: String, site: String) -> int:
	var n := 0
	for m in bot_points:
		if _bot_point_matches(m, kind, site):
			n += 1
	return n


func _bot_point_matches(m: Marker3D, kind: String, site: String) -> bool:
	if String(m.get_meta("kind", "")).to_lower() != kind.to_lower():
		return false
	if site == "":
		return true
	return String(m.get_meta("site", "")).to_upper() == site
