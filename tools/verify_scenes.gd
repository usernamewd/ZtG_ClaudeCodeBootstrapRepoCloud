extends Node
## Loads and instantiates scenes WITH autoloads registered, reporting failures.
##
##   godot --headless --path . tools/verify_scenes.tscn -- [res://a.tscn ...]
##
## With no arguments it walks scenes/ and checks everything. Runs as a scene
## rather than via `--script` because `--script` never registers the autoload
## singletons, so any gameplay scene fails to compile there (see
## tools/check_scene.gd, which is kept for autoload-free scenes).

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var paths: Array[String] = []
	if args.is_empty():
		_collect("res://scenes", paths)
		paths.sort()
	else:
		for a in args:
			paths.append(String(a))

	var failures: Array[String] = []
	for p in paths:
		if not ResourceLoader.exists(p):
			printerr("MISSING: ", p)
			failures.append(p)
			continue
		var packed: PackedScene = ResourceLoader.load(p, "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE)
		if packed == null:
			printerr("LOAD FAILED: ", p)
			failures.append(p)
			continue
		var inst := packed.instantiate()
		if inst == null:
			printerr("INSTANTIATE FAILED: ", p)
			failures.append(p)
			continue
		print("OK  %-46s %4d nodes  root=%s" % [p, _count(inst), inst.get_class()])
		inst.free()

	print("[verify_scenes] %d scenes, %d failed" % [paths.size(), failures.size()])
	if not failures.is_empty():
		for f in failures:
			printerr("  FAILED: ", f)
	get_tree().quit(0 if failures.is_empty() else 1)


func _collect(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not name.begins_with("."):
			var full := dir_path.path_join(name)
			if d.current_is_dir():
				_collect(full, out)
			elif name.ends_with(".tscn"):
				out.append(full)
		name = d.get_next()
	d.list_dir_end()


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
