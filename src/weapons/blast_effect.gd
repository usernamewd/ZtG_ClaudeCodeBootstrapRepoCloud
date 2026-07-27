class_name BlastEffect
extends Node3D
## Pooled one-shot explosion: a particle burst plus a brief light flash.
##
## Pooled means it must never queue_free itself — it returns to Pools when the
## burst finishes, and resets fully on acquire so a recycled instance never shows
## the tail of its previous life.

const FLASH_TIME := 0.09

var _particles: GPUParticles3D = null
var _light: OmniLight3D = null
var _age := 0.0
var _duration := 1.0
var _active := false


func _ready() -> void:
	_particles = get_node_or_null("Particles")
	_light = get_node_or_null("Flash")
	if _particles:
		_duration = _particles.lifetime + 0.15
	set_process(false)
	visible = false


func on_pool_acquire() -> void:
	_age = 0.0
	_active = true
	visible = true
	if _particles:
		_particles.restart()
		_particles.emitting = true
	if _light:
		_light.visible = true
	set_process(true)


func _process(delta: float) -> void:
	if not _active:
		return
	_age += delta
	# The light is a punch, not a lamp: kill it well before the particles fade.
	if _light and _light.visible and _age > FLASH_TIME:
		_light.visible = false
	if _age >= _duration:
		_active = false
		visible = false
		if _particles:
			_particles.emitting = false
		set_process(false)
		Pools.release(self)
