extends Node
## User-facing settings: input, graphics, HUD layout, crosshair.
## Persisted through Persistence autoload. All gameplay/UI code reads from here.

signal changed

const PRESET_LOW := 0
const PRESET_MEDIUM := 1
const PRESET_HIGH := 2

var look_sensitivity: float = 0.35      # touch-look degrees per pixel factor
var ads_sensitivity_mult: float = 0.6
var gyro_enabled: bool = false
var gyro_sensitivity: float = 1.0
var invert_y: bool = false
var crouch_is_toggle: bool = true
var fire_left_mirror: bool = false      # extra fire button on the left side

var graphics_preset: int = PRESET_MEDIUM
var show_fps: bool = false

# Crosshair
var crosshair_color: Color = Color(0.2, 1.0, 0.4, 0.9)
var crosshair_size: float = 12.0
var crosshair_gap: float = 4.0
var crosshair_thickness: float = 2.0
var crosshair_dot: bool = false
var crosshair_dynamic: bool = true      # expands with spread

# HUD layout: control name -> {pos: Vector2 (anchor-relative offset), scale: float}
var hud_layout: Dictionary = {}
var hud_scale: float = 1.0

var player_name: String = "Operator"


func _ready() -> void:
	load_from_disk()


func apply_graphics_preset() -> void:
	var vp := get_viewport()
	match graphics_preset:
		PRESET_LOW:
			vp.scaling_3d_scale = 0.7
			vp.msaa_3d = Viewport.MSAA_DISABLED
		PRESET_MEDIUM:
			vp.scaling_3d_scale = 0.85
			vp.msaa_3d = Viewport.MSAA_2X
		PRESET_HIGH:
			vp.scaling_3d_scale = 1.0
			vp.msaa_3d = Viewport.MSAA_4X
	apply_shadow_preset()
	changed.emit()


## Realtime shadows are the single largest GPU cost on a mid-range phone, so
## Low and Medium run without them and rely on the baked/ambient lighting.
## Maps add their sun to the "sun_light" group for this.
func apply_shadow_preset() -> void:
	var want_shadows := graphics_preset == PRESET_HIGH
	for n in get_tree().get_nodes_in_group("sun_light"):
		if n is DirectionalLight3D:
			(n as DirectionalLight3D).shadow_enabled = want_shadows


func to_dict() -> Dictionary:
	return {
		"look_sensitivity": look_sensitivity,
		"ads_sensitivity_mult": ads_sensitivity_mult,
		"gyro_enabled": gyro_enabled,
		"gyro_sensitivity": gyro_sensitivity,
		"invert_y": invert_y,
		"crouch_is_toggle": crouch_is_toggle,
		"fire_left_mirror": fire_left_mirror,
		"graphics_preset": graphics_preset,
		"show_fps": show_fps,
		"crosshair_color": crosshair_color.to_html(),
		"crosshair_size": crosshair_size,
		"crosshair_gap": crosshair_gap,
		"crosshair_thickness": crosshair_thickness,
		"crosshair_dot": crosshair_dot,
		"crosshair_dynamic": crosshair_dynamic,
		"hud_layout": hud_layout,
		"hud_scale": hud_scale,
		"player_name": player_name,
	}


func from_dict(d: Dictionary) -> void:
	look_sensitivity = d.get("look_sensitivity", look_sensitivity)
	ads_sensitivity_mult = d.get("ads_sensitivity_mult", ads_sensitivity_mult)
	gyro_enabled = d.get("gyro_enabled", gyro_enabled)
	gyro_sensitivity = d.get("gyro_sensitivity", gyro_sensitivity)
	invert_y = d.get("invert_y", invert_y)
	crouch_is_toggle = d.get("crouch_is_toggle", crouch_is_toggle)
	fire_left_mirror = d.get("fire_left_mirror", fire_left_mirror)
	graphics_preset = int(d.get("graphics_preset", graphics_preset))
	show_fps = d.get("show_fps", show_fps)
	crosshair_color = Color.html(d.get("crosshair_color", crosshair_color.to_html()))
	crosshair_size = d.get("crosshair_size", crosshair_size)
	crosshair_gap = d.get("crosshair_gap", crosshair_gap)
	crosshair_thickness = d.get("crosshair_thickness", crosshair_thickness)
	crosshair_dot = d.get("crosshair_dot", crosshair_dot)
	crosshair_dynamic = d.get("crosshair_dynamic", crosshair_dynamic)
	hud_layout = d.get("hud_layout", hud_layout)
	hud_scale = d.get("hud_scale", hud_scale)
	player_name = d.get("player_name", player_name)
	changed.emit()


func save_to_disk() -> void:
	Persistence.put("settings", to_dict())
	Persistence.save_now()


func load_from_disk() -> void:
	var d: Dictionary = Persistence.get_value("settings", {})
	if not d.is_empty():
		from_dict(d)
