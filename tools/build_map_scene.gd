extends Node
## Turns assets/maps/layouts.json + the Blender-built shell GLB into playable
## map scenes.
##
##   godot --headless --path . tools/build_map_scene.tscn [-- saltline transit]
##
## Produces scenes/maps/<id>.tscn containing everything the game needs:
##   Shell            the merged atlas-textured architecture (one draw call)
##   Collision        one StaticBody3D with a BoxShape3D per layout box (layer 1)
##   ATKSpawns/…      Marker3D spawn points, facing into the map
##   DEFSpawns/…
##   BombSites/A|B    Area3D over each plantable region
##   BuyZones/ATK|DEF Area3D over each spawn
##   BotPoints/…      authored hold/plant/retake/rotate markers (see docs/BOT_AI.md)
##   NavRegion        NavigationRegion3D with a baked mesh
##   WorldEnvironment sky, fog and ambient per the layout's mood
##   Sun              DirectionalLight3D
##
## Collision comes from the layout boxes rather than a trimesh of the shell: the
## shell has relief (plinths, caps, pilasters) that would trap players and cost a
## lot to collide against, whereas the layout boxes are the designed volumes.

const LAYOUTS_PATH := "res://assets/maps/layouts.json"
const OUT_DIR := "res://scenes/maps"
const MAP_INFO_SCRIPT := "res://src/game/map_info.gd"

const LAYER_WORLD := 1
## Nodes in this group are the navmesh baker's geometry source.
const NAV_SOURCE_GROUP := "navmesh_source"

## Navmesh agent metrics; must match CharacterBase's capsule.
const AGENT_RADIUS := 0.4
const AGENT_HEIGHT := 1.8
const AGENT_MAX_CLIMB := 0.45
const AGENT_MAX_SLOPE := 46.0


func _ready() -> void:
	var only := OS.get_cmdline_user_args()
	var f := FileAccess.open(LAYOUTS_PATH, FileAccess.READ)
	if f == null:
		printerr("[build_map] cannot open ", LAYOUTS_PATH,
			" — run: python3 tools/assets/map_layouts.py > assets/maps/layouts.json")
		get_tree().quit(1)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		printerr("[build_map] layouts.json is not an object")
		get_tree().quit(1)
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var built := 0
	for map_id in (parsed as Dictionary):
		if not only.is_empty() and not only.has(String(map_id)):
			continue
		if await _build(String(map_id), (parsed as Dictionary)[map_id]):
			built += 1
	print("[build_map] built %d map scene(s)" % built)
	get_tree().quit(0 if built > 0 else 1)


func _build(map_id: String, layout: Dictionary) -> bool:
	var root := Node3D.new()
	root.name = map_id.capitalize()
	if ResourceLoader.exists(MAP_INFO_SCRIPT):
		root.set_script(load(MAP_INFO_SCRIPT))
	else:
		push_warning("[build_map] %s missing; scene will need it attached later"
			% MAP_INFO_SCRIPT)

	_add_shell(root, map_id)
	_add_environment(root, layout)
	_add_collision(root, layout)
	_add_spawns(root, layout)
	_add_areas(root, layout)
	_add_bot_points(root, layout)
	var nav := _add_navigation(root, layout)

	# The navmesh baker walks the live SceneTree, so the map has to be in it
	# before baking (and physics needs a tick to register the static bodies).
	add_child(root)
	await get_tree().physics_frame
	await get_tree().physics_frame

	# Radar metadata the HUD reads.
	var radar: Dictionary = layout.get("radar", {})
	if radar.has("origin"):
		var o: Array = radar["origin"]
		root.set("radar_origin", Vector2(float(o[0]), float(o[1])))
	if radar.has("span"):
		root.set("radar_scale", float(radar["span"]))

	# Bake AFTER everything is parented, so the baker sees the collision bodies.
	_bake_nav(nav)

	var packed := PackedScene.new()
	# Own every descendant so they are all serialized into the .tscn.
	_set_owner_recursive(root, root)
	var err := packed.pack(root)
	if err != OK:
		printerr("[build_map] pack failed for ", map_id, ": ", err)
		return false
	var out := "%s/%s.tscn" % [OUT_DIR, map_id]
	err = ResourceSaver.save(packed, out)
	if err != OK:
		printerr("[build_map] save failed for ", out, ": ", err)
		return false
	print("[build_map] %s -> %s (%d walls, %d floors, %d markers)" % [
		map_id, out, (layout.get("walls", []) as Array).size(),
		(layout.get("floors", []) as Array).size(),
		(layout.get("markers", []) as Array).size()])
	remove_child(root)
	root.free()
	return true


# ---------------------------------------------------------------------------

func _add_shell(root: Node3D, map_id: String) -> void:
	var shell_path := "res://assets/maps/%s_shell.glb" % map_id
	if not ResourceLoader.exists(shell_path):
		push_warning("[build_map] missing shell %s" % shell_path)
		return
	var packed: PackedScene = load(shell_path)
	var inst := packed.instantiate()
	inst.name = "Shell"
	root.add_child(inst)
	# Shadows off on the shell: lighting is baked/ambient on mobile presets and
	# the shell is the largest shadow caster by far.
	for n in _descendants(inst):
		if n is GeometryInstance3D:
			(n as GeometryInstance3D).cast_shadow = \
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _add_environment(root: Node3D, layout: Dictionary) -> void:
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()

	var sky_name := String(layout.get("sky", "day"))
	var sky_tex := "res://assets/env/sky_%s.png" % sky_name
	if ResourceLoader.exists(sky_tex):
		var sky := Sky.new()
		var mat := PanoramaSkyMaterial.new()
		mat.panorama = load(sky_tex)
		sky.sky_material = mat
		env.background_mode = Environment.BG_SKY
		env.sky = sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	else:
		# Procedural fallback so a map is never lit by a flat void.
		var sky2 := Sky.new()
		var pmat := ProceduralSkyMaterial.new()
		if sky_name == "dusk":
			pmat.sky_top_color = Color(0.09, 0.12, 0.20)
			pmat.sky_horizon_color = Color(0.35, 0.30, 0.32)
			pmat.ground_bottom_color = Color(0.06, 0.07, 0.08)
			pmat.ground_horizon_color = Color(0.22, 0.20, 0.20)
		else:
			pmat.sky_top_color = Color(0.29, 0.45, 0.68)
			pmat.sky_horizon_color = Color(0.72, 0.70, 0.62)
			pmat.ground_bottom_color = Color(0.18, 0.16, 0.14)
			pmat.ground_horizon_color = Color(0.52, 0.47, 0.40)
		sky2.sky_material = pmat
		env.background_mode = Environment.BG_SKY
		env.sky = sky2
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY

	var amb: Dictionary = layout.get("ambient", {})
	if amb.has("color"):
		var c: Array = amb["color"]
		env.ambient_light_color = Color(float(c[0]), float(c[1]), float(c[2]))
	env.ambient_light_energy = float(amb.get("energy", 0.4))
	env.ambient_light_sky_contribution = 0.35

	var fog: Dictionary = layout.get("fog", {})
	if bool(fog.get("enabled", false)):
		env.fog_enabled = true
		var fc: Array = fog.get("color", [0.5, 0.5, 0.5])
		env.fog_light_color = Color(float(fc[0]), float(fc[1]), float(fc[2]))
		env.fog_density = float(fog.get("density", 0.006))
		# Aerial perspective reads as depth without costing anything.
		env.fog_sky_affect = 0.4

	# Tonemap so the palette atlas doesn't clip to white in sunlight.
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 1.1
	we.environment = env
	root.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	var s: Dictionary = layout.get("sun", {})
	sun.rotation_degrees = Vector3(float(s.get("pitch", -45.0)),
		float(s.get("yaw", -30.0)), 0.0)
	var sc: Array = s.get("color", [1.0, 1.0, 1.0])
	sun.light_color = Color(float(sc[0]), float(sc[1]), float(sc[2]))
	sun.light_energy = float(s.get("energy", 1.0))
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 60.0
	# A large ortho shadow across a flat floor shows acne as concentric arcs
	# without a generous normal bias.
	sun.shadow_bias = 0.09
	sun.shadow_normal_bias = 2.5
	sun.add_to_group("sun_light", true)
	root.add_child(sun)


func _add_collision(root: Node3D, layout: Dictionary) -> void:
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	body.add_to_group(NAV_SOURCE_GROUP, true)
	root.add_child(body)

	for w in layout.get("walls", []):
		var wall: Dictionary = w
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var h := float(wall.get("h", 3.2))
		box.size = Vector3(float(wall.sx), h, float(wall.sz))
		shape.shape = box
		shape.position = Vector3(float(wall.cx), h * 0.5, float(wall.cz))
		shape.name = "W_%s_%d" % [String(wall.get("tag", "wall")), body.get_child_count()]
		body.add_child(shape)

	for fl in layout.get("floors", []):
		var f: Dictionary = fl
		var shape2 := CollisionShape3D.new()
		var box2 := BoxShape3D.new()
		# Floors are thin slabs; give them real thickness so a fast fall can't
		# tunnel through.
		box2.size = Vector3(float(f.sx), 0.5, float(f.sz))
		shape2.shape = box2
		shape2.position = Vector3(float(f.cx), float(f.get("y", 0.0)) - 0.25,
			float(f.cz))
		shape2.name = "F_%s_%d" % [String(f.get("tag", "floor")), body.get_child_count()]
		body.add_child(shape2)


func _add_spawns(root: Node3D, layout: Dictionary) -> void:
	var atk := Node3D.new()
	atk.name = "ATKSpawns"
	root.add_child(atk)
	var def := Node3D.new()
	def.name = "DEFSpawns"
	root.add_child(def)

	for m in layout.get("markers", []):
		var mk: Dictionary = m
		var tag := String(mk.get("tag", ""))
		if tag != "atk_spawn" and tag != "def_spawn":
			continue
		var parent: Node3D = atk if tag == "atk_spawn" else def
		var marker := Marker3D.new()
		marker.name = "Spawn%d" % parent.get_child_count()
		marker.position = Vector3(float(mk.x), float(mk.get("y", 0.0)) + 0.1,
			float(mk.z))
		marker.rotation_degrees = Vector3(0.0, float(mk.get("yaw", 0.0)), 0.0)
		parent.add_child(marker)


func _add_areas(root: Node3D, layout: Dictionary) -> void:
	var sites := Node3D.new()
	sites.name = "BombSites"
	root.add_child(sites)
	for key in layout.get("sites", {}):
		var s: Dictionary = (layout["sites"] as Dictionary)[key]
		sites.add_child(_make_area(String(key), s, 4.0))

	var zones := Node3D.new()
	zones.name = "BuyZones"
	root.add_child(zones)
	for key in layout.get("buy_zones", {}):
		var z: Dictionary = (layout["buy_zones"] as Dictionary)[key]
		zones.add_child(_make_area(String(key), z, 6.0))


func _make_area(name: String, rect: Dictionary, height: float) -> Area3D:
	var area := Area3D.new()
	area.name = name
	area.monitoring = true
	area.monitorable = true
	# Areas detect character bodies (player layer 2, bot layer 4).
	area.collision_layer = 0
	area.collision_mask = 2 | 4
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(float(rect.sx), height, float(rect.sz))
	shape.shape = box
	area.add_child(shape)
	area.position = Vector3(float(rect.cx), height * 0.5, float(rect.cz))
	return area


func _add_bot_points(root: Node3D, layout: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "BotPoints"
	root.add_child(holder)
	for m in layout.get("markers", []):
		var mk: Dictionary = m
		var tag := String(mk.get("tag", ""))
		if tag == "" or tag == "atk_spawn" or tag == "def_spawn":
			continue
		var marker := Marker3D.new()
		marker.name = "%s_%d" % [tag, holder.get_child_count()]
		marker.position = Vector3(float(mk.x), float(mk.get("y", 0.0)) + 0.1,
			float(mk.z))
		marker.rotation_degrees = Vector3(0.0, float(mk.get("yaw", 0.0)), 0.0)
		# The bot AI selects by tag; store the bare tag plus its site suffix.
		marker.set_meta("tag", tag)
		var parts := tag.split("_")
		marker.set_meta("kind", parts[0])
		marker.set_meta("site", parts[1] if parts.size() > 1 else "")
		holder.add_child(marker)


func _add_navigation(root: Node3D, layout: Dictionary) -> NavigationRegion3D:
	var region := NavigationRegion3D.new()
	region.name = "NavRegion"
	var nav := NavigationMesh.new()
	nav.agent_radius = AGENT_RADIUS
	nav.agent_height = AGENT_HEIGHT
	nav.agent_max_climb = AGENT_MAX_CLIMB
	nav.agent_max_slope = AGENT_MAX_SLOPE
	nav.cell_size = 0.25
	nav.cell_height = 0.2
	# Bake from the physics bodies, which are the designed volumes — baking from
	# the shell's relief geometry produces spurious ledges on every plinth.
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.geometry_collision_mask = LAYER_WORLD
	# ROOT_NODE_CHILDREN would parse the region's OWN children, which are none —
	# the collision body is a sibling. Parse it by group instead.
	nav.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav.geometry_source_group_name = NAV_SOURCE_GROUP

	var b: Dictionary = layout.get("bounds", {})
	if not b.is_empty():
		var w := absf(float(b.x1) - float(b.x0)) + 8.0
		var d := absf(float(b.z1) - float(b.z0)) + 8.0
		nav.filter_baking_aabb = AABB(
			Vector3(minf(float(b.x0), float(b.x1)) - 4.0, -2.0,
				minf(float(b.z0), float(b.z1)) - 4.0),
			Vector3(w, 20.0, d))
	region.navigation_mesh = nav
	root.add_child(region)
	return region


func _bake_nav(region: NavigationRegion3D) -> void:
	if region == null:
		return
	# Synchronous bake so the mesh is populated before the scene is packed.
	region.bake_navigation_mesh(false)
	var poly_count := region.navigation_mesh.get_polygon_count() if region.navigation_mesh else 0
	if poly_count == 0:
		push_warning("[build_map] navmesh baked with 0 polygons — bots will not move")
	else:
		print("[build_map]   navmesh: %d polygons" % poly_count)


# ---------------------------------------------------------------------------

func _set_owner_recursive(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		# Instanced sub-scenes (the shell GLB) keep their own internal ownership;
		# only the instance root needs an owner.
		c.owner = owner_node
		if c.scene_file_path == "":
			_set_owner_recursive(c, owner_node)


func _descendants(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			out.append(c)
			stack.append(c)
	return out
