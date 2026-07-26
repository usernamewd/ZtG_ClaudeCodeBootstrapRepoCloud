extends SceneTree
## Renders a model/scene on a neutral studio set for asset review.
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
##     --resolution 1280x720 --path . --script tools/preview_model.gd -- \
##     <res://model.glb> <out.png> [yaw_deg] [anim_name] [anim_time]
## Frames the subject automatically from its AABB.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <res://model> <out.png> [yaw_deg] [anim] [anim_time]")
		quit(1)
		return
	var model_path: String = args[0]
	var out_path: String = args[1]
	var yaw: float = float(args[2]) if args.size() > 2 else 35.0
	var anim_name: String = args[3] if args.size() > 3 else ""
	var anim_time: float = float(args[4]) if args.size() > 4 else 0.0

	var world := Node3D.new()
	root.add_child(world)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.13, 0.145, 0.16)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.45, 0.5, 0.6)
	e.ambient_light_energy = 0.55
	env.environment = e
	world.add_child(env)

	# Three-point lighting so silhouette and form both read.
	_add_light(world, Vector3(-40, -35, 0), Color(1.0, 0.96, 0.9), 2.2)
	_add_light(world, Vector3(-20, 140, 0), Color(0.6, 0.72, 1.0), 0.9)
	_add_light(world, Vector3(-65, -160, 0), Color(1.0, 0.85, 0.7), 0.7)

	var packed: Resource = load(model_path)
	if packed == null:
		push_error("cannot load: " + model_path)
		quit(1)
		return
	var subject: Node3D = packed.instantiate()
	world.add_child(subject)

	if anim_name != "":
		var ap := _find_anim_player(subject)
		if ap and ap.has_animation(anim_name):
			ap.play(anim_name)
			ap.seek(anim_time, true)
			ap.pause()
		else:
			printerr("animation not found: ", anim_name)

	# Ground plane for scale reference.
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	ground.mesh = pm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.18, 0.19, 0.21)
	ground.material_override = gmat
	world.add_child(ground)

	await process_frame
	await process_frame

	var aabb := _merged_aabb(subject)
	if aabb.size.length() < 0.001:
		aabb = AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 1, 1))
	ground.position.y = aabb.position.y

	var cam := Camera3D.new()
	cam.fov = 40.0
	cam.near = 0.01
	world.add_child(cam)
	var center := aabb.get_center()
	var radius: float = maxf(aabb.size.length() * 0.5, 0.05)
	var dist: float = radius / tan(deg_to_rad(cam.fov * 0.5)) * 1.35
	var rad := deg_to_rad(yaw)
	cam.position = center + Vector3(sin(rad) * dist, radius * 0.55, cos(rad) * dist)
	cam.look_at(center, Vector3.UP)

	for i in 8:
		await process_frame

	var img := root.get_viewport().get_texture().get_image()
	img.save_png(out_path)
	print("preview: ", out_path, "  aabb_size=", aabb.size, "  tris=", _tri_count(subject))
	quit(0)


func _add_light(parent: Node3D, rot_deg: Vector3, color: Color, energy: float) -> void:
	var l := DirectionalLight3D.new()
	l.rotation_degrees = rot_deg
	l.light_color = color
	l.light_energy = energy
	l.shadow_enabled = energy > 1.5
	parent.add_child(l)


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r:
			return r
	return null


func _merged_aabb(n: Node, acc := AABB()) -> AABB:
	if n is VisualInstance3D:
		var a: AABB = (n as VisualInstance3D).global_transform * (n as VisualInstance3D).get_aabb()
		acc = a if acc.size == Vector3.ZERO else acc.merge(a)
	for c in n.get_children():
		acc = _merged_aabb(c, acc)
	return acc


func _tri_count(n: Node) -> int:
	var t := 0
	if n is MeshInstance3D and n.mesh:
		for s in n.mesh.get_surface_count():
			t += n.mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX].size() / 3 if n.mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX] else 0
	for c in n.get_children():
		t += _tri_count(c)
	return t
