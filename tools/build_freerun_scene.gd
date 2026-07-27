extends Node
## Generates scenes/game/freerun.tscn — the Phase 1 FREE-RUN gameplay scene.
##
##   godot --headless --path . tools/build_freerun_scene.tscn
##
## Runs as a SCENE rather than via `--script` because instantiating the HUD
## compiles scripts that reference the autoloads (Settings, GameState, ...) and
## `--script` runs never register them.
##
## The built tree is deliberately tiny: the controller fills MapRoot at runtime
## from GameState.cfg_map, so map choice never touches the packed scene.

const OUT_PATH := "res://scenes/game/freerun.tscn"
const CONTROLLER_SCRIPT := "res://src/game/match.gd"
const HUD_SCENE := "res://scenes/ui/hud.tscn"


func _ready() -> void:
	var err := _build()
	get_tree().quit(0 if err == OK else 1)


func _build() -> int:
	var script := load(CONTROLLER_SCRIPT)
	if script == null:
		printerr("[build_freerun] cannot load ", CONTROLLER_SCRIPT)
		return ERR_FILE_NOT_FOUND

	var root := Node.new()
	root.name = "FreeRun"
	root.set_script(script)

	var map_root := Node3D.new()
	map_root.name = "MapRoot"
	root.add_child(map_root)
	map_root.owner = root

	if ResourceLoader.exists(HUD_SCENE):
		var hud: Node = (load(HUD_SCENE) as PackedScene).instantiate()
		hud.name = "HUD"
		root.add_child(hud)
		# owner + scene_file_path (set by instantiate) make pack() store this as a
		# scene instance instead of inlining every HUD node.
		hud.owner = root
	else:
		printerr("[build_freerun] missing ", HUD_SCENE, " — scene will have no HUD")

	var packed := PackedScene.new()
	var perr := packed.pack(root)
	if perr != OK:
		printerr("[build_freerun] pack failed: ", perr)
		root.free()
		return perr

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUT_PATH.get_base_dir()))
	var serr := ResourceSaver.save(packed, OUT_PATH)
	root.free()
	if serr != OK:
		printerr("[build_freerun] save failed: ", serr)
		return serr
	print("[build_freerun] wrote ", OUT_PATH)
	return OK
