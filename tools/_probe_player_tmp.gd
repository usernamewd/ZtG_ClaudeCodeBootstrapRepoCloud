extends SceneTree

var _n := 0

func _init() -> void:
	print("init: has InputHub: ", root.has_node("InputHub"))

func _process(_d: float) -> bool:
	_n += 1
	print("frame ", _n, " has InputHub: ", root.has_node("InputHub"))
	if _n >= 2:
		var s := load("res://src/characters/player.gd")
		print("player.gd can_instantiate: ", (s as GDScript).can_instantiate())
		return true
	return false
