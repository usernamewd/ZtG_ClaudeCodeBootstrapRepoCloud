extends SceneTree
## Verifies scenes load and instantiate without errors.
##   godot --headless --path . --script tools/check_scene.gd -- res://a.tscn [res://b.tscn ...]
## Exits non-zero if any scene fails to load or instantiate.

func _init() -> void:
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


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
