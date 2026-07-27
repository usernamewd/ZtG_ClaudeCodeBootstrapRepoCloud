extends SceneTree
## Generates scenes/maps/graybox.tscn — the Phase 1 test range.
##
##   godot --headless --path . --script tools/build_graybox.gd
##
## Graybox is the one map in this project allowed to be untextured blocks: it
## exists to make weapon, movement and penetration behaviour measurable, not to
## be played competitively. Layout (X east, Z south, origin at map centre):
##
##   z 20..28   RANGE LANE     90 m of open ground, floor stripes every 10 m,
##              three dummies at 10 / 30 / 60 m from the firing line
##   z 10..18   ATK spawn + buy zone (centre), MOVEMENT GYM (west)
##   z -8..8    open middle with pillar/half-height cover, bomb site B (east)
##   z -26..-8  PENETRATION GALLERY (west), DEF spawn + buy zone (centre),
##              bomb site A (east)
##
## Targets: the three range dummies are instanced into the scene so the map is
## a working shooting range on its own. The penetration gallery instead exposes
## DummySpawns/PenA..PenD markers, so whoever drives the test decides whether to
## put bodies behind the walls (MapInfo.dummy_spawns lists them).
##
## The navmesh is deliberately NOT baked here: Phase 3 owns baking. NavRegion
## ships with a NavigationMesh whose geometry source is the "navmesh_source"
## group, so `region.bake_navigation_mesh(false)` is all it needs later.

const OUT_PATH := "res://scenes/maps/graybox.tscn"
const OUT_DIR := "res://scenes/maps"
const MAP_INFO_SCRIPT := "res://src/game/map_info.gd"
const DUMMY_SCENE := "res://scenes/characters/dummy.tscn"

const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_BOT := 4
## Nodes in this group are the navmesh baker's geometry source (matches
## tools/build_map_scene.gd so both map pipelines bake the same way).
const NAV_SOURCE_GROUP := "navmesh_source"

## Navmesh agent metrics; must match CharacterBase's capsule.
const AGENT_RADIUS := 0.4
const AGENT_HEIGHT := 1.8
const AGENT_MAX_CLIMB := 0.45
const AGENT_MAX_SLOPE := 46.0

# Playable rectangle.
const HALF_X := 50.0
const HALF_Z := 30.0
const WALL_H := 6.0

# Range lane.
const LANE_Z := 24.0
const FIRING_X := -46.0
const LANE_HALF_W := 4.0

# Weapon.gd punches a wall at most 0.35 m * penetration thick, so these three
# thicknesses bracket the whole weapon roster.
const THIN_T := 0.15
const MED_T := 0.30
const THICK_T := 0.80

# CharacterBase: JUMP_VELOCITY 5.4 with gravity 16 -> apex 0.911 m.
const JUMP_APEX := 0.911
const CROUCH_GAP := 1.30    # < STAND_HEIGHT 1.8, > CROUCH_HEIGHT 1.25
const STAND_GAP := 2.00

# Sign facings: the compass direction the READABLE face of a sign points at.
# Label3D draws on its local +Z (not the Node3D -Z "forward"), so these yaws are
# the opposite of what a Marker3D would need.
const FACE_N := 180.0
const FACE_S := 0.0
const FACE_E := 90.0
const FACE_W := -90.0

var _root: Node3D
var _geo: Node3D
var _body: StaticBody3D
var _signs: Node3D
var _mats: Dictionary = {}
var _mesh_cache: Dictionary = {}
var _shape_cache: Dictionary = {}
var _box_count := 0


func _init() -> void:
	_build_materials()

	_root = Node3D.new()
	_root.name = "Graybox"
	if not ResourceLoader.exists(MAP_INFO_SCRIPT):
		printerr("[build_graybox] missing ", MAP_INFO_SCRIPT)
		quit(1)
		return
	_root.set_script(load(MAP_INFO_SCRIPT))
	_root.set("radar_origin", Vector2(-HALF_X, -HALF_Z))
	_root.set("radar_scale", (HALF_X * 2.0) / 256.0)
	_root.set("playable_extent", Vector2(HALF_X * 2.0, HALF_Z * 2.0))
	_root.set("playable_floor_y", -2.0)
	_root.set("playable_ceiling_y", 12.0)

	_add_environment()

	_geo = Node3D.new()
	_geo.name = "Geo"
	_root.add_child(_geo)

	_body = StaticBody3D.new()
	_body.name = "Collision"
	_body.collision_layer = LAYER_WORLD
	_body.collision_mask = 0
	_body.add_to_group(NAV_SOURCE_GROUP, true)
	_root.add_child(_body)

	_signs = Node3D.new()
	_signs.name = "Signs"
	_root.add_child(_signs)

	_add_shell()
	_add_range_lane()
	_add_movement_gym()
	_add_penetration_gallery()
	_add_middle_cover()
	_add_sites_and_zones()
	_add_spawns()
	_add_bot_points()
	_add_dummies()
	_add_navigation()

	_save()


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

func _build_materials() -> void:
	_mats["floor"] = _mat(Color(0.30, 0.32, 0.35), 0.95)
	_mats["wall"] = _mat(Color(0.45, 0.49, 0.55), 0.90)
	_mats["block"] = _mat(Color(0.80, 0.56, 0.26), 0.80)
	_mats["pen"] = _mat(Color(0.26, 0.68, 0.46), 0.70)
	_mats["nopen"] = _mat(Color(0.74, 0.24, 0.22), 0.70)
	_mats["mark"] = _mat(Color(0.88, 0.89, 0.92), 1.0)


func _mat(albedo: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	m.metallic = 0.0
	# GL Compatibility: keep everything opaque and unshaded-free so the pass
	# count stays at one per material.
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	return m


# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

func _box(nm: String, center: Vector3, size: Vector3, mat_key: String,
		collide: bool = true, basis: Basis = Basis()) -> void:
	var xf := Transform3D(basis, center)

	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = _box_mesh(size)
	mi.transform = xf
	mi.set_surface_override_material(0, _mats[mat_key])
	_geo.add_child(mi)

	if collide:
		var cs := CollisionShape3D.new()
		cs.name = nm
		cs.shape = _box_shape(size)
		cs.transform = xf
		_body.add_child(cs)
	_box_count += 1


## A ramp whose TOP surface runs from `from` (low) to `to` (high).
func _ramp(nm: String, from: Vector3, to: Vector3, width: float,
		thickness: float, mat_key: String) -> void:
	var d := to - from
	var length := d.length()
	if length < 0.01:
		return
	var x_axis := d.normalized()
	var horiz := Vector3(d.x, 0.0, d.z)
	if horiz.length_squared() < 0.0001:
		horiz = Vector3.RIGHT
	horiz = horiz.normalized()
	var z_axis := horiz.cross(Vector3.UP).normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	var basis := Basis(x_axis, y_axis, z_axis)
	var center := (from + to) * 0.5 - y_axis * (thickness * 0.5)
	_box(nm, center, Vector3(length, thickness, width), mat_key, true, basis)


func _box_mesh(size: Vector3) -> BoxMesh:
	if _mesh_cache.has(size):
		return _mesh_cache[size]
	var m := BoxMesh.new()
	m.size = size
	_mesh_cache[size] = m
	return m


func _box_shape(size: Vector3) -> BoxShape3D:
	if _shape_cache.has(size):
		return _shape_cache[size]
	var s := BoxShape3D.new()
	s.size = size
	_shape_cache[size] = s
	return s


## Signs are fixed-orientation, not billboards: a billboarded Label3D reports an
## AABB big enough to cover every rotation, which for a 20 m wide caption drags
## the map's merged AABB metres below the floor and puts tools/map_preview.gd's
## eye-level camera underground. Pass `yaw_deg` as one of the FACE_* constants.
func _sign(nm: String, text: String, pos: Vector3, yaw_deg: float,
		font_size: int = 64, pixel_size: float = 0.016,
		col: Color = Color(1, 1, 1)) -> void:
	var l := Label3D.new()
	l.name = nm
	l.text = text
	l.position = pos
	l.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	l.font_size = font_size
	l.outline_size = maxf(float(font_size) * 0.18, 8.0)
	l.pixel_size = pixel_size
	l.modulate = col
	l.outline_modulate = Color(0.05, 0.06, 0.07, 1.0)
	l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	# Depth-writing cutout instead of blended transparency, so signs sort
	# correctly against the blocks they label.
	l.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	l.double_sided = true
	l.shaded = false
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_signs.add_child(l)


func _marker(parent: Node, nm: String, pos: Vector3, yaw_deg: float) -> Marker3D:
	var m := Marker3D.new()
	m.name = nm
	m.position = pos
	m.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	parent.add_child(m)
	return m


func _holder(nm: String) -> Node3D:
	var n := Node3D.new()
	n.name = nm
	_root.add_child(n)
	return n


func _area(parent: Node, nm: String, center: Vector3, size: Vector3) -> Area3D:
	var a := Area3D.new()
	a.name = nm
	a.monitoring = true
	a.monitorable = true
	# Zones detect character bodies only; they are not part of the world.
	a.collision_layer = 0
	a.collision_mask = LAYER_PLAYER | LAYER_BOT
	a.position = center
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = _box_shape(size)
	a.add_child(cs)
	parent.add_child(a)
	return a


# ---------------------------------------------------------------------------
# Content
# ---------------------------------------------------------------------------

func _add_environment() -> void:
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	var sky := Sky.new()
	var psm := ProceduralSkyMaterial.new()
	psm.sky_top_color = Color(0.24, 0.40, 0.62)
	psm.sky_horizon_color = Color(0.66, 0.70, 0.74)
	psm.ground_bottom_color = Color(0.16, 0.17, 0.19)
	psm.ground_horizon_color = Color(0.44, 0.45, 0.46)
	sky.sky_material = psm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 0.6
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 1.1
	# No fog: the 90 m range lane has to stay readable end to end.
	env.fog_enabled = false
	we.environment = env
	_root.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.light_color = Color(1.0, 0.97, 0.92)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 70.0
	sun.shadow_bias = 0.04
	_root.add_child(sun)


func _add_shell() -> void:
	_box("Floor", Vector3(0.0, -0.25, 0.0),
		Vector3(HALF_X * 2.0, 0.5, HALF_Z * 2.0), "floor")

	var t := 1.0
	var h := WALL_H
	_box("BoundaryNorth", Vector3(0.0, h * 0.5, -HALF_Z - t * 0.5),
		Vector3(HALF_X * 2.0 + t * 2.0, h, t), "wall")
	_box("BoundarySouth", Vector3(0.0, h * 0.5, HALF_Z + t * 0.5),
		Vector3(HALF_X * 2.0 + t * 2.0, h, t), "wall")
	_box("BoundaryWest", Vector3(-HALF_X - t * 0.5, h * 0.5, 0.0),
		Vector3(t, h, HALF_Z * 2.0), "wall")
	_box("BoundaryEast", Vector3(HALF_X + t * 0.5, h * 0.5, 0.0),
		Vector3(t, h, HALF_Z * 2.0), "wall")


## 90 m of open ground with distance stripes, a half-height cover rail along its
## inner edge, and the three range dummies.
func _add_range_lane() -> void:
	_box("LaneFiringPad", Vector3(FIRING_X, 0.02, LANE_Z),
		Vector3(2.0, 0.04, LANE_HALF_W * 2.0), "mark", false)
	_sign("SignFiringLine", "FIRING LINE",
		Vector3(FIRING_X, 2.6, LANE_Z), FACE_E, 72, 0.020, Color(1.0, 0.86, 0.35))
	_sign("SignRangeLane", "RANGE LANE — DAMAGE FALLOFF",
		Vector3(FIRING_X + 24.0, 4.6, LANE_Z), FACE_E, 72, 0.024,
		Color(1.0, 0.86, 0.35))

	for i in range(1, 10):
		var metres := float(i) * 10.0
		var x := FIRING_X + metres
		_box("LaneStripe%d" % int(metres), Vector3(x, 0.02, LANE_Z),
			Vector3(0.25, 0.04, LANE_HALF_W * 2.0), "mark", false)
		# A short post makes the stripe readable from eye level as well as
		# from a top-down capture.
		_box("LanePost%d" % int(metres), Vector3(x, 0.9, LANE_Z + LANE_HALF_W),
			Vector3(0.3, 1.8, 0.3), "block")
		_sign("SignRange%d" % int(metres), "%d m" % int(metres),
			Vector3(x, 2.3, LANE_Z + LANE_HALF_W), FACE_W, 64, 0.018)

	# Inner rail: crouch-safe cover (MAP_DESIGN half-height is 1.1 m) that also
	# stops strays from wandering out of the lane. Split at the centre so the
	# ATK spawn has a straight walk-in instead of a detour to the map edge.
	var rail_z := LANE_Z - LANE_HALF_W - 0.25
	_box("LaneRailWest", Vector3(-26.0, 0.55, rail_z), Vector3(40.0, 1.1, 0.5),
		"block")
	_box("LaneRailEast", Vector3(26.0, 0.55, rail_z), Vector3(40.0, 1.1, 0.5),
		"block")
	_sign("SignLaneRail", "HALF COVER 1.10 m", Vector3(-26.0, 1.9, rail_z),
		FACE_N, 56, 0.014)


## Jump steps, two headroom gates and a ramp-fed platform.
func _add_movement_gym() -> void:
	_sign("SignGym", "MOVEMENT GYM", Vector3(-32.0, 5.0, 16.0), FACE_E, 80,
		0.026, Color(0.55, 0.85, 1.0))

	# Jump steps: 0.90 clears the 0.911 m apex, 1.20 does not.
	var heights := PackedFloat32Array([0.30, 0.60, 0.90, 1.20])
	for i in heights.size():
		var h := heights[i]
		var x := -45.0 + float(i) * 3.5
		_box("JumpStep%d" % i, Vector3(x, h * 0.5, 16.0),
			Vector3(2.6, h, 2.6), "block")
		_sign("SignJumpStep%d" % i, "%.2f m" % h, Vector3(x, h + 0.9, 16.0),
			FACE_S, 48, 0.013)
	_sign("SignJumpApex", "JUMP APEX %.2f m" % JUMP_APEX,
		Vector3(-40.0, 3.4, 16.0), FACE_S, 56, 0.014)

	_headroom_gate("CrouchGate", Vector3(-44.0, 0.0, 9.0), CROUCH_GAP,
		"CROUCH ONLY — %.2f m" % CROUCH_GAP)
	_headroom_gate("StandGate", Vector3(-36.0, 0.0, 9.0), STAND_GAP,
		"STAND OK — %.2f m" % STAND_GAP)

	# Ramp-fed platform: 2.5 m high, reached by a 22.6 deg ramp (well under the
	# navmesh's 46 deg limit) and droppable off any edge.
	_box("GymPlatform", Vector3(-27.0, 1.25, 2.0), Vector3(10.0, 2.5, 10.0),
		"block")
	_ramp("GymRamp", Vector3(-16.0, 0.0, 2.0), Vector3(-22.0, 2.5, 2.0),
		4.0, 0.6, "wall")
	_sign("SignGymPlatform", "PLATFORM 2.50 m / RAMP 22.6°",
		Vector3(-27.0, 4.0, 2.0), FACE_E, 56, 0.016)

	# A tall pillar and a crouch-safe block beside the platform so cover work can
	# be tested at two heights side by side.
	_box("GymPillar", Vector3(-34.0, 1.6, 2.0), Vector3(1.4, 3.2, 1.4), "wall")
	_box("GymHalfCover", Vector3(-34.0, 0.55, -3.0), Vector3(3.0, 1.1, 0.8),
		"block")


func _headroom_gate(nm: String, base: Vector3, gap: float, label: String) -> void:
	var opening := 3.0
	var depth := 4.0
	var top := 3.2
	_box(nm + "Left", base + Vector3(-(opening * 0.5 + 0.4), top * 0.5, 0.0),
		Vector3(0.8, top, depth), "wall")
	_box(nm + "Right", base + Vector3(opening * 0.5 + 0.4, top * 0.5, 0.0),
		Vector3(0.8, top, depth), "wall")
	_box(nm + "Lintel", base + Vector3(0.0, (gap + top) * 0.5, 0.0),
		Vector3(opening, top - gap, depth), "wall")
	_sign("Sign" + nm, label, base + Vector3(0.0, top + 0.8, 0.0), FACE_S, 56,
		0.014)


## Four labelled walls of increasing thickness with a firing mark in front of
## each and a witness backstop behind, so a penetrating round is visible.
func _add_penetration_gallery() -> void:
	_sign("SignPenGallery", "PENETRATION GALLERY",
		Vector3(-30.0, 5.0, -8.0), FACE_S, 80, 0.026, Color(0.55, 0.85, 1.0))

	var wall_z := -16.0
	var fire_z := -10.0
	var specs := [
		{"x": -42.0, "t": THIN_T, "mat": "pen", "nm": "PenA",
			"label": "THIN %.2f m\npen >= 0.43" % THIN_T},
		{"x": -34.0, "t": THIN_T, "mat": "pen", "nm": "PenB",
			"label": "THIN %.2f m\npen >= 0.43" % THIN_T},
		{"x": -26.0, "t": MED_T, "mat": "block", "nm": "PenC",
			"label": "MEDIUM %.2f m\npen >= 0.86" % MED_T},
		{"x": -18.0, "t": THICK_T, "mat": "nopen", "nm": "PenD",
			"label": "THICK %.2f m\nNO PENETRATION" % THICK_T},
	]

	var targets := _holder("DummySpawns")
	for s in specs:
		var x := float(s["x"])
		var t := float(s["t"])
		var nm := String(s["nm"])
		_box("Wall" + nm, Vector3(x, 1.6, wall_z), Vector3(5.0, 3.2, t),
			String(s["mat"]))
		_sign("Sign" + nm, String(s["label"]), Vector3(x, 4.4, wall_z), FACE_S,
			52, 0.014)
		_box("FireMark" + nm, Vector3(x, 0.02, fire_z),
			Vector3(1.2, 0.04, 1.2), "mark", false)
		# Marker for an optional target behind the wall; MapInfo.dummy_spawns.
		_marker(targets, nm, Vector3(x, 0.1, wall_z - 3.0), 180.0)

	_sign("SignPenFire", "FIRE FROM HERE", Vector3(-30.0, 2.4, fire_z), FACE_S,
		56, 0.016, Color(1.0, 0.86, 0.35))
	# Witness backstop: impacts on it prove the round came through.
	_box("PenBackstop", Vector3(-30.0, 1.6, -22.0), Vector3(34.0, 3.2, 1.0),
		"wall")


func _add_middle_cover() -> void:
	_box("MidPillarW", Vector3(-9.0, 1.6, 0.0), Vector3(1.4, 3.2, 1.4), "wall")
	_box("MidPillarE", Vector3(9.0, 1.6, 0.0), Vector3(1.4, 3.2, 1.4), "wall")
	_box("MidPillarN", Vector3(0.0, 1.6, -7.0), Vector3(1.4, 3.2, 1.4), "wall")
	_box("MidPillarS", Vector3(0.0, 1.6, 7.0), Vector3(1.4, 3.2, 1.4), "wall")
	_box("MidCoverW", Vector3(-5.0, 0.55, 4.0), Vector3(3.5, 1.1, 0.8), "block")
	_box("MidCoverE", Vector3(5.0, 0.55, -4.0), Vector3(3.5, 1.1, 0.8), "block")
	# Two crates at jump height so the player can mantle onto the half cover.
	_box("MidCrateW", Vector3(-13.0, 0.45, -2.0), Vector3(1.8, 0.9, 1.8), "block")
	_box("MidCrateE", Vector3(13.0, 0.45, 2.0), Vector3(1.8, 0.9, 1.8), "block")


func _add_sites_and_zones() -> void:
	# Zone boxes reach a little below the floor: a character's position is its
	# feet, so a box sitting exactly on y = 0 would be an exact-boundary test.
	var sites := _holder("BombSites")
	_area(sites, "A", Vector3(30.0, 1.8, -18.0), Vector3(18.0, 4.4, 12.0))
	_area(sites, "B", Vector3(30.0, 1.8, 8.0), Vector3(18.0, 4.4, 12.0))
	_sign("SignSiteA", "SITE A", Vector3(30.0, 4.6, -18.0), FACE_W, 88, 0.030,
		Color(1.0, 0.55, 0.35))
	_sign("SignSiteB", "SITE B", Vector3(30.0, 4.6, 8.0), FACE_W, 88, 0.030,
		Color(1.0, 0.55, 0.35))

	# Site A: crates plus a ramp-fed post-plant platform.
	_box("SiteACrate0", Vector3(24.0, 0.75, -14.0), Vector3(2.0, 1.5, 2.0), "block")
	_box("SiteACrate1", Vector3(33.0, 0.55, -22.0), Vector3(3.0, 1.1, 1.0), "block")
	_box("SiteAPlatform", Vector3(37.0, 0.75, -18.0), Vector3(6.0, 1.5, 8.0), "block")
	_ramp("SiteARamp", Vector3(29.0, 0.0, -18.0), Vector3(34.0, 1.5, -18.0),
		3.0, 0.5, "wall")

	# Site B: crates and a half-height plant shoulder.
	_box("SiteBCrate0", Vector3(24.0, 0.75, 11.0), Vector3(2.0, 1.5, 2.0), "block")
	_box("SiteBCrate1", Vector3(34.0, 0.55, 4.0), Vector3(3.0, 1.1, 1.0), "block")
	_box("SiteBShoulder", Vector3(30.0, 0.55, 12.5), Vector3(8.0, 1.1, 0.8), "block")

	var zones := _holder("BuyZones")
	_area(zones, "ATK", Vector3(0.0, 2.5, 15.0), Vector3(26.0, 7.0, 10.0))
	_area(zones, "DEF", Vector3(0.0, 2.5, -15.0), Vector3(26.0, 7.0, 10.0))
	# Placed on the far edge of each zone, facing the spawn, so a player standing
	# on their spawn markers reads it head-on rather than edge-on.
	_sign("SignBuyATK", "ATK BUY ZONE", Vector3(0.0, 3.4, 10.5), FACE_S, 56,
		0.013, Color(0.95, 0.62, 0.30))
	_sign("SignBuyDEF", "DEF BUY ZONE", Vector3(0.0, 3.4, -10.5), FACE_N, 56,
		0.013, Color(0.45, 0.72, 1.0))


func _add_spawns() -> void:
	# Attackers south facing north (Marker3D forward is -Z, so yaw 0 = north).
	var atk := _holder("ATKSpawns")
	for i in 5:
		_marker(atk, "Spawn%d" % i,
			Vector3(-8.0 + float(i) * 4.0, 0.1, 15.0), 0.0)
	var def := _holder("DEFSpawns")
	for i in 5:
		_marker(def, "Spawn%d" % i,
			Vector3(-8.0 + float(i) * 4.0, 0.1, -15.0), 180.0)


## Authored positions so the bot AI has somewhere to go if graybox is loaded
## with a full roster (docs/BOT_AI.md).
func _add_bot_points() -> void:
	var pts := _holder("BotPoints")
	var specs := [
		["hold_A", Vector3(34.0, 0.1, -13.0), 200.0],
		["hold_A", Vector3(24.0, 0.1, -22.0), 20.0],
		["hold_B", Vector3(34.0, 0.1, 3.0), 160.0],
		["hold_B", Vector3(24.0, 0.1, 12.0), 340.0],
		["hold_mid", Vector3(9.0, 0.1, -3.0), 180.0],
		["hold_mid", Vector3(-9.0, 0.1, 3.0), 0.0],
		["plant_A", Vector3(30.0, 0.1, -18.0), 180.0],
		["plant_B", Vector3(30.0, 0.1, 8.0), 0.0],
		["retake_A", Vector3(20.0, 0.1, -24.0), 45.0],
		["retake_B", Vector3(20.0, 0.1, 14.0), 315.0],
		["rotate_A", Vector3(16.0, 0.1, -10.0), 200.0],
		["rotate_B", Vector3(16.0, 0.1, 4.0), 160.0],
		["rotate_mid", Vector3(0.0, 0.1, 0.0), 180.0],
	]
	for i in specs.size():
		var s: Array = specs[i]
		var tag := String(s[0])
		var m := _marker(pts, "%s_%d" % [tag, i], s[1], float(s[2]))
		var parts := tag.split("_")
		m.set_meta("tag", tag)
		m.set_meta("kind", parts[0])
		m.set_meta("site", parts[1] if parts.size() > 1 else "")


## Three range targets at 10 / 30 / 60 m, facing the firing line.
func _add_dummies() -> void:
	var holder := _holder("Dummies")
	if not ResourceLoader.exists(DUMMY_SCENE):
		push_warning("[build_graybox] %s missing; placing markers only" % DUMMY_SCENE)
	var packed: PackedScene = load(DUMMY_SCENE) if ResourceLoader.exists(DUMMY_SCENE) else null
	var ranges := PackedFloat32Array([10.0, 30.0, 60.0])
	for i in ranges.size():
		var metres := ranges[i]
		var pos := Vector3(FIRING_X + metres, 0.0, LANE_Z)
		if packed == null:
			_marker(holder, "Dummy%dm" % int(metres), pos, 90.0)
			continue
		var inst := packed.instantiate()
		inst.name = "Dummy%dm" % int(metres)
		var n3 := inst as Node3D
		n3.position = pos
		# yaw +90 points a Node3D's -Z forward at -X, i.e. back down the lane.
		n3.rotation_degrees = Vector3(0.0, 90.0, 0.0)
		# Enemy team relative to the default player team (DEF), and ids well
		# clear of the match roster's 0..9.
		inst.set("team", 0)
		inst.set("player_id", 900 + i)
		holder.add_child(inst)


func _add_navigation() -> void:
	var region := NavigationRegion3D.new()
	region.name = "NavRegion"
	var nav := NavigationMesh.new()
	nav.agent_radius = AGENT_RADIUS
	nav.agent_height = AGENT_HEIGHT
	nav.agent_max_climb = AGENT_MAX_CLIMB
	nav.agent_max_slope = AGENT_MAX_SLOPE
	nav.cell_size = 0.25
	nav.cell_height = 0.2
	# Bake from the physics bodies: they are the designed volumes, and the
	# visual meshes duplicate them exactly.
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.geometry_collision_mask = LAYER_WORLD
	# ROOT_NODE_CHILDREN would parse the region's own children (none); the
	# collision body is a sibling, so parse it by group instead.
	nav.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav.geometry_source_group_name = NAV_SOURCE_GROUP
	nav.filter_baking_aabb = AABB(
		Vector3(-HALF_X - 2.0, -2.0, -HALF_Z - 2.0),
		Vector3(HALF_X * 2.0 + 4.0, 20.0, HALF_Z * 2.0 + 4.0))
	region.navigation_mesh = nav
	_root.add_child(region)


# ---------------------------------------------------------------------------

func _save() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_set_owner_recursive(_root, _root)
	var packed := PackedScene.new()
	var err := packed.pack(_root)
	if err != OK:
		printerr("[build_graybox] pack failed: ", err)
		quit(1)
		return
	err = ResourceSaver.save(packed, OUT_PATH)
	if err != OK:
		printerr("[build_graybox] save failed: ", err)
		quit(1)
		return
	print("[build_graybox] %s -> %d boxes, %d signs, navmesh UNBAKED (Phase 3)"
		% [OUT_PATH, _box_count, _signs.get_child_count()])
	# The tree was never added to the SceneTree, so nothing else will release it.
	_root.free()
	_root = null
	_geo = null
	_body = null
	_signs = null
	_mesh_cache.clear()
	_shape_cache.clear()
	_mats.clear()
	quit(0)


func _set_owner_recursive(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		# Instanced sub-scenes (the dummies) keep their own internal ownership.
		if c.scene_file_path == "":
			_set_owner_recursive(c, owner_node)
