extends Node
## Map review renders: a top-down orthographic plan, and eye-level shots from
## named positions. This is the tool the map phase gate in docs/MAP_DESIGN.md
## requires ("top-down orthographic render reviewed against the connectivity
## graph; eye-level screenshots from each spawn, each site, mid, long angle").
##
##   xvfb-run -a -s "-screen 0 1024x1024x24" godot --rendering-driver opengl3 \
##     --resolution 1024x1024 --path . tools/map_preview.tscn -- \
##     <res://scene_or_shell> <out_prefix> [mode]
##
## mode: "plan" (default, top-down ortho) or "eye" (a sweep of eye-level shots
## at 1.65 m from a ring of positions, plus one from each spawn if the scene
## exposes MapInfo).

const EYE_HEIGHT := 1.65

var _out_prefix := ""
var _mode := "plan"
var _subject: Node3D = null
var _cam: Camera3D = null
var _shots: Array = []
var _shot_index := -1
var _frames := 0
var _aabb := AABB()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("usage: -- <res://scene> <out_prefix> [plan|eye]")
		get_tree().quit(1)
		return
	var path: String = args[0]
	_out_prefix = args[1]
	_mode = args[2] if args.size() > 2 else "plan"

	if not ResourceLoader.exists(path):
		printerr("[map_preview] missing: ", path)
		get_tree().quit(1)
		return
	var packed: PackedScene = load(path)
	_subject = packed.instantiate() as Node3D
	if _subject == null:
		printerr("[map_preview] root is not a Node3D: ", path)
		get_tree().quit(1)
		return
	add_child(_subject)

	_setup_environment()
	await get_tree().process_frame
	await get_tree().process_frame
	_aabb = _merged_aabb(_subject)
	_setup_camera()
	_plan_shots()


func _setup_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.09, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.60, 0.70)
	env.ambient_light_energy = 0.75
	we.environment = env
	add_child(we)

	# Steep key light so a top-down plan still shows wall relief as shadow.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-58.0, -35.0, 0.0)
	key.light_energy = 1.5
	key.light_color = Color(1.0, 0.95, 0.88)
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 200.0
	add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25.0, 140.0, 0.0)
	fill.light_energy = 0.5
	fill.light_color = Color(0.65, 0.75, 0.95)
	add_child(fill)


func _setup_camera() -> void:
	_cam = Camera3D.new()
	_cam.near = 0.05
	_cam.far = 500.0
	add_child(_cam)
	_cam.make_current()


func _plan_shots() -> void:
	_shots.clear()
	var c := _aabb.get_center()
	if _mode == "plan":
		var span: float = maxf(_aabb.size.x, _aabb.size.z) * 1.06
		_shots.append({
			"name": "plan",
			"ortho": span,
			"pos": Vector3(c.x, _aabb.end.y + 60.0, c.z),
			# Look straight down with north (−Z) toward the top of the image.
			"look": Vector3(c.x, _aabb.position.y, c.z),
			"up": Vector3(0, 0, -1),
		})
		# A 45° isometric makes the relief and heights legible in a way a pure
		# plan cannot.
		var d: float = span * 0.85
		_shots.append({
			"name": "iso",
			"ortho": span * 1.15,
			"pos": Vector3(c.x + d * 0.7, _aabb.end.y + d * 0.8, c.z + d * 0.7),
			"look": c,
			"up": Vector3.UP,
		})
	else:
		_eye_shots_from_map_info(c)
	_shot_index = -1
	_next_shot()


func _eye_shots_from_map_info(center: Vector3) -> void:
	# Prefer authored positions when the scene exposes MapInfo; otherwise sweep.
	var spawns_atk = _subject.get("atk_spawns") if _subject.get("atk_spawns") != null else []
	var spawns_def = _subject.get("def_spawns") if _subject.get("def_spawns") != null else []
	var sites = _subject.get("bomb_sites") if _subject.get("bomb_sites") != null else {}

	if spawns_atk is Array and not (spawns_atk as Array).is_empty():
		var m := (spawns_atk as Array)[0] as Node3D
		if m:
			_shots.append(_eye(m.global_position, center, "spawn_atk"))
	if spawns_def is Array and not (spawns_def as Array).is_empty():
		var m2 := (spawns_def as Array)[0] as Node3D
		if m2:
			_shots.append(_eye(m2.global_position, center, "spawn_def"))
	if sites is Dictionary:
		for key in (sites as Dictionary):
			var a = (sites as Dictionary)[key]
			if a is Node3D:
				_shots.append(_eye((a as Node3D).global_position + Vector3(0, 0, 8.0),
					(a as Node3D).global_position, "site_%s" % key))
	_shots.append(_eye(center + Vector3(0, 0, 14.0), center, "mid"))

	if _shots.is_empty():
		# Bare shell: ring the perimeter looking inward.
		for i in 4:
			var ang := TAU * float(i) / 4.0
			var p := center + Vector3(sin(ang), 0, cos(ang)) * (_aabb.size.x * 0.35)
			_shots.append(_eye(p, center, "view_%d" % i))


func _eye(from: Vector3, toward: Vector3, name: String) -> Dictionary:
	return {
		"name": name,
		"ortho": 0.0,
		"pos": Vector3(from.x, _aabb.position.y + EYE_HEIGHT, from.z),
		"look": Vector3(toward.x, _aabb.position.y + EYE_HEIGHT, toward.z),
		"up": Vector3.UP,
	}


func _next_shot() -> void:
	_shot_index += 1
	if _shot_index >= _shots.size():
		print("[map_preview] done, %d images" % _shots.size())
		get_tree().quit(0)
		return
	var s: Dictionary = _shots[_shot_index]
	if float(s.ortho) > 0.0:
		_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		_cam.size = float(s.ortho)
	else:
		_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		_cam.fov = 75.0
	_cam.global_position = s.pos
	var look_target: Vector3 = s.look
	if _cam.global_position.distance_to(look_target) < 0.01:
		look_target += Vector3(0, 0, -1)
	_cam.look_at(look_target, s.up)
	_frames = 0


func _process(_delta: float) -> void:
	if _shot_index < 0 or _shot_index >= _shots.size():
		return
	_frames += 1
	if _frames < 12:
		return
	var s: Dictionary = _shots[_shot_index]
	var img := get_viewport().get_texture().get_image()
	var out := "%s_%s.png" % [_out_prefix, String(s.name)]
	img.save_png(out)
	print("[map_preview] ", out)
	_next_shot()


func _merged_aabb(n: Node, acc := AABB()) -> AABB:
	if n is VisualInstance3D:
		var vi := n as VisualInstance3D
		var a: AABB = vi.global_transform * vi.get_aabb()
		acc = a if acc.size == Vector3.ZERO else acc.merge(a)
	for c in n.get_children():
		acc = _merged_aabb(c, acc)
	return acc
