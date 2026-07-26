extends Node
## Generic object pooling for gameplay VFX: bullet impacts, tracers, shells,
## muzzle flashes. Zero allocations during a round: everything preallocated.

var _pools: Dictionary = {}   # key -> {scene: PackedScene, free: Array[Node], all: Array[Node]}


func create_pool(key: String, scene: PackedScene, count: int) -> void:
	if _pools.has(key):
		return
	var pool := {"scene": scene, "free": [], "all": []}
	for i in count:
		var n: Node = scene.instantiate()
		n.set_meta("pool_key", key)
		pool.free.append(n)
		pool.all.append(n)
	_pools[key] = pool


func acquire(key: String, parent: Node) -> Node:
	var pool: Dictionary = _pools.get(key, {})
	if pool.is_empty():
		return null
	var n: Node
	if pool.free.is_empty():
		# Recycle the oldest live instance rather than allocating.
		n = pool.all[0]
		pool.all.remove_at(0)
		pool.all.append(n)
		if n.get_parent():
			n.get_parent().remove_child(n)
	else:
		n = pool.free.pop_back()
	parent.add_child(n)
	if n.has_method("on_pool_acquire"):
		n.on_pool_acquire()
	return n


func release(n: Node) -> void:
	var key: String = n.get_meta("pool_key", "")
	var pool: Dictionary = _pools.get(key, {})
	if pool.is_empty():
		n.queue_free()
		return
	if n.get_parent():
		n.get_parent().remove_child(n)
	if not pool.free.has(n):
		pool.free.append(n)


func clear_all() -> void:
	for pool in _pools.values():
		for n in pool.all:
			if is_instance_valid(n) and n.get_parent() == null:
				n.free()
	_pools.clear()
