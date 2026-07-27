extends Node
## Runs a live match and reports renderer statistics + frame timing.

var _t := 0.0
var _frames := 0
var _samples: Array[float] = []
var _match: Node = null

func _ready() -> void:
	_match = (load("res://scenes/game/match.tscn") as PackedScene).instantiate()
	add_child(_match)

func _process(delta: float) -> void:
	_t += delta
	_frames += 1
	if _t > 3.0:
		_samples.append(delta * 1000.0)
	if _t < 18.0:
		return
	_samples.sort()
	var n := _samples.size()
	var med := _samples[n / 2] if n > 0 else 0.0
	var p95 := _samples[int(n * 0.95)] if n > 0 else 0.0
	print("=== PERF ===")
	print("frames=%d elapsed=%.1fs avg_fps=%.1f" % [_frames, _t, _frames / _t])
	print("frame_ms median=%.2f p95=%.2f min=%.2f max=%.2f" % [
		med, p95, _samples[0], _samples[n - 1]])
	print("objects_in_frame=%d" % RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
	print("primitives_in_frame=%d" % RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	print("draw_calls_in_frame=%d" % RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	print("texture_mem=%.1f MB" % (RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0))
	print("buffer_mem=%.1f MB" % (RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_BUFFER_MEM_USED) / 1048576.0))
	print("video_mem=%.1f MB" % (RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0))
	print("static_mem=%.1f MB" % (OS.get_static_memory_usage() / 1048576.0))
	print("nodes=%d" % get_tree().get_node_count())
	get_tree().quit(0)
