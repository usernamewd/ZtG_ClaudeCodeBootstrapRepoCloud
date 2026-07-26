extends Node
## Compiles every GDScript in the project WITH autoloads registered.
##
##   godot --headless --path . tools/script_check.tscn
##
## Running as a scene (rather than `--script`) is what makes autoload singletons
## and class_name globals resolve; `--check-only --script` reports false
## "Identifier not found: GameState" errors because it never registers them.
##
## Optional: pass directories after `--` to narrow the scan.

const DEFAULT_ROOTS := ["res://src", "res://tools"]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var roots: Array = args if not args.is_empty() else DEFAULT_ROOTS

	var files: Array[String] = []
	for r in roots:
		if String(r).ends_with(".gd"):
			files.append(String(r))
		else:
			_collect(String(r), files)
	files.sort()

	var failed: Array[String] = []
	for f in files:
		if f.ends_with("script_check.gd"):
			continue
		var res := ResourceLoader.load(f, "Script", ResourceLoader.CACHE_MODE_IGNORE)
		if res == null:
			failed.append(f)
	print("[script_check] checked %d scripts, %d failed" % [files.size(), failed.size()])
	for f in failed:
		printerr("[script_check] FAIL: ", f)
	if failed.is_empty():
		print("[script_check] ALL SCRIPTS OK")
	get_tree().quit(0 if failed.is_empty() else 1)


func _collect(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full := dir_path.path_join(name)
		if d.current_is_dir():
			_collect(full, out)
		elif name.ends_with(".gd"):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()
