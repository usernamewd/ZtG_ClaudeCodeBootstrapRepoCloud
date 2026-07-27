extends SceneTree
## Verifies scenes load and instantiate without errors.
##   godot --headless --path . --script tools/check_scene.gd -- res://a.tscn [res://b.tscn ...]
## Exits non-zero if any scene fails to load, instantiate, or attach its scripts.
##
## The work runs on the first idle frame, NOT in _init: autoload singletons are
## registered after _init returns, so loading a scene there makes every script
## that touches an autoload fail to compile. Godot then attaches no script and
## the scene still "instantiates", which used to be reported as OK.

var _done := false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <scene.tscn> [more...]")
		quit(1)
		return
	var failures := 0
	for path in args:
		if not ResourceLoader.exists(path):
			printerr("MISSING: ", path)
			failures += 1
			continue
		var packed: PackedScene = load(path)
		if packed == null:
			printerr("LOAD FAILED: ", path)
			failures += 1
			continue
		var missing := _missing_scripts(packed)
		if not missing.is_empty():
			printerr("SCRIPT FAILED TO ATTACH: ", path, " -> ", ", ".join(missing))
			failures += 1
			continue
		var inst := packed.instantiate()
		if inst == null:
			printerr("INSTANTIATE FAILED: ", path)
			failures += 1
			continue
		print("OK: ", path, "  (", _count(inst), " nodes, root ", inst.get_class(), ")")
		inst.free()
	if failures > 0:
		printerr("FAILURES: ", failures)
		quit(1)
	else:
		print("ALL SCENES OK")
		quit(0)


## Node names whose .tscn declares a script that resolved to null — i.e. the
## script failed to compile, so the instantiated node silently loses its
## behaviour. Without this the check passes on a broken scene.
func _missing_scripts(packed: PackedScene) -> Array[String]:
	var bad: Array[String] = []
	var st := packed.get_state()
	for n in st.get_node_count():
		for p in st.get_node_property_count(n):
			if st.get_node_property_name(n, p) != &"script":
				continue
			if st.get_node_property_value(n, p) == null:
				bad.append(String(st.get_node_name(n)))
	return bad


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
