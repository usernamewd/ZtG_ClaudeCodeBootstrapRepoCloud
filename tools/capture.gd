extends Node
## Loads a scene, waits, and saves a PNG — the phase-gate screenshot tool.
##
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
##     --resolution 1280x720 --path . tools/capture.tscn -- \
##     <res://scene.tscn> <out.png> [wait_frames] [autopilot_seconds]
##
## Runs as a SCENE, not via `--script`, because autoloads (Settings, GameState,
## ...) are only registered for a normal scene run — a `--script` run fails to
## compile anything that references them.
##
## `autopilot_seconds` waits that long in real time before capturing, which lets
## a match scene reach a live gameplay frame (bots moving, weapon drawn) instead
## of capturing the spawn instant.

var _out_path := ""
var _wait_frames := 30
var _autopilot := 0.0
var _elapsed := 0.0
var _frames := 0
var _target: Node = null
var _captured := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("usage: -- <res://scene.tscn> <out.png> [wait_frames] [autopilot_seconds]")
		get_tree().quit(1)
		return
	var scene_path: String = args[0]
	_out_path = args[1]
	_wait_frames = int(args[2]) if args.size() > 2 else 30
	_autopilot = float(args[3]) if args.size() > 3 else 0.0

	if not ResourceLoader.exists(scene_path):
		printerr("[capture] missing scene: ", scene_path)
		get_tree().quit(1)
		return
	var packed: PackedScene = load(scene_path)
	if packed == null:
		printerr("[capture] failed to load: ", scene_path)
		get_tree().quit(1)
		return
	_target = packed.instantiate()
	if _target == null:
		printerr("[capture] failed to instantiate: ", scene_path)
		get_tree().quit(1)
		return
	get_tree().root.add_child.call_deferred(_target)


func _process(delta: float) -> void:
	if _captured:
		return
	_frames += 1
	_elapsed += delta
	if _frames < _wait_frames or _elapsed < _autopilot:
		return
	_captured = true
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_out_path)
	if err != OK:
		printerr("[capture] save failed (", err, "): ", _out_path)
		get_tree().quit(1)
		return
	print("[capture] %s  %dx%d  after %d frames / %.1fs" % [
		_out_path, img.get_width(), img.get_height(), _frames, _elapsed])
	get_tree().quit(0)
