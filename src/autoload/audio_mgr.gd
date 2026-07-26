extends Node
## Central SFX playback with pooled 3D/2D players. Streams are registered by id.

const POOL_3D_SIZE := 24
const POOL_2D_SIZE := 8

var _streams: Dictionary = {}
var _pool_3d: Array[AudioStreamPlayer3D] = []
var _pool_2d: Array[AudioStreamPlayer]= []
var _idx_3d := 0
var _idx_2d := 0


func _ready() -> void:
	for i in POOL_3D_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.max_polyphony = 1
		p.bus = "SFX"
		add_child(p)
		_pool_3d.append(p)
	for i in POOL_2D_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_pool_2d.append(p)


func register(id: String, stream: AudioStream) -> void:
	_streams[id] = stream


func has_sound(id: String) -> bool:
	return _streams.has(id)


func play_3d(id: String, global_pos: Vector3, volume_db := 0.0, pitch := 1.0) -> void:
	var s: AudioStream = _streams.get(id)
	if s == null:
		return
	var p := _pool_3d[_idx_3d]
	_idx_3d = (_idx_3d + 1) % POOL_3D_SIZE
	p.stream = s
	p.global_position = global_pos
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


func play_ui(id: String, volume_db := 0.0, pitch := 1.0) -> void:
	var s: AudioStream = _streams.get(id)
	if s == null:
		return
	var p := _pool_2d[_idx_2d]
	_idx_2d = (_idx_2d + 1) % POOL_2D_SIZE
	p.stream = s
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()
