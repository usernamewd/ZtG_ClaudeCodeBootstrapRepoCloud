extends SceneTree
## Captures a scene that does NOT touch autoload singletons.
##   xvfb-run -a godot --rendering-driver opengl3 --path . \
##     --script tools/screenshot.gd -- <scene.tscn> <out.png> [wait_frames]
##
## LIMITATION: `--script` runs never register autoloads, so any scene whose
## scripts reference Settings / GameState / Economy / AudioMgr / Pools / InputHub
## fails to compile here with "Identifier not found". For those (the HUD, menus,
## the match scene — i.e. most gameplay scenes) use the scene-based runner:
##
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
##     --resolution 1280x720 --path . tools/capture.tscn -- \
##     <res://scene.tscn> <out.png> [wait_frames] [autopilot_seconds]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <scene.tscn> <out.png> [wait_frames]")
		quit(1)
		return
	var scene_path: String = args[0]
	var out_path: String = args[1]
	var wait_frames: int = int(args[2]) if args.size() > 2 else 30
	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("cannot load scene (if it uses autoloads, use tools/capture.tscn): "
			+ scene_path)
		quit(1)
		return
	var inst := packed.instantiate()
	root.add_child(inst)
	_capture(out_path, wait_frames)


func _capture(out_path: String, wait_frames: int) -> void:
	for i in wait_frames:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(out_path)
	print("screenshot saved: ", out_path, " ", img.get_width(), "x", img.get_height())
	quit(0)
