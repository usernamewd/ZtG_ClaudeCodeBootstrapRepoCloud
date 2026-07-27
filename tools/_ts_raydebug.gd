extends Node

func _ready() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 8
	body.collision_mask = 0
	body.position = Vector3(0, 1.25, -10)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.5, 0.5, 0.32)
	cs.shape = box
	body.add_child(cs)
	add_child(body)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := get_viewport().world_3d.direct_space_state
	print("space=", space)
	var q := PhysicsRayQueryParameters3D.new()
	q.from = Vector3(0, 1.25, 0)
	q.to = Vector3(0, 1.25, -300)
	q.collision_mask = 9
	q.collide_with_bodies = true
	q.collide_with_areas = false
	q.hit_from_inside = false
	print("no-exclude hit: ", space.intersect_ray(q))
	var ex: Array[RID] = []
	q.exclude = ex
	print("empty-exclude hit: ", space.intersect_ray(q))
	q.collision_mask = 9
	q.hit_back_faces = false
	print("no-backface hit: ", space.intersect_ray(q))
	get_tree().quit(0)
