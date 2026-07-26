extends Node
## Tiny key/value save system backed by user://save.json.
## Sections: "settings", "profile" (xp, crates, finishes, stats).

const SAVE_PATH := "user://save.json"

var _data: Dictionary = {}
var _loaded := false


func _ready() -> void:
	_load()


func get_value(key: String, default_val = null):
	if not _loaded:
		_load()
	return _data.get(key, default_val)


func put(key: String, value) -> void:
	_data[key] = value


func save_now() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_data))
		f.close()


func _load() -> void:
	_loaded = true
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_data = parsed
