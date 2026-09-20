class_name EnvironmentVisuals
extends Node3D
## Procedural visual layer for the environment: sky, clouds, distant ranges,
## sun, fog, post-processing and precipitation (snow, rain, spindrift).
## Created and owned by EnvironmentService; reads TimeService, WeatherService
## and TemperatureSystem and never drives simulation state itself.
##
## Everything here is built from engine primitives (no imported assets). The
## base look (procedural sky, one shadow-casting DirectionalLight3D, depth
## fog, CPUParticles3D, the cloud sheet and the horizon ranges) renders on
## every backend, Compatibility (OpenGL3) included. Features that backend
## lacks in 4.2 (glow, colour adjustments, SSAO, cascaded shadow maps,
## volumetric fog) are enabled only on Forward+ / Mobile, decided once at
## start by detect_rendering_method().
##
## Design Philosophy:
## - The player reads time and weather from the world, not from a HUD:
##   sun height, shadow length, sky colour, cloud cover and haze are the
##   clock and the forecast
## - Weather is felt: a storm darkens the sky, spindrift races across the
##   snow, a whiteout swallows the horizon, and rain instead of snow tells
##   the climber how warm the day has turned

# =============================================================================
# CONSTANTS
# =============================================================================

## Seconds between lighting/sky refreshes (sun moves slowly; no need per frame)
const REFRESH_INTERVAL := 0.25

## Peak sun energy at high noon (tuned against Filmic tonemapping so snow
## does not blow out to pure white)
const SUN_ENERGY_MAX := 0.8

## Ambient colour = horizon colour pulled this far toward the zenith colour
const AMBIENT_ZENITH_MIX := 0.35
## Ambient energy in full daylight / deep night (night is relatively higher
## so moonlit snow still reads as a shape instead of a void)
const AMBIENT_ENERGY_DAY := 0.45
const AMBIENT_ENERGY_NIGHT := 0.8

## Tonemap exposure. Calibrated so near-white snow (albedo ~0.95) in full
## sun lands around 80% brightness with shading detail intact, instead of
## clipping to a flat white sheet
const TONEMAP_EXPOSURE := 0.75

## Faint blue fill once the sun is down so night is readable, not black
const MOON_ENERGY := 0.10
const MOON_COLOR := Color(0.50, 0.60, 0.92)

## Fog density at full visibility (faint alpine haze: the distant ranges
## recede into blue while the far end of the playable terrain stays crisp)
const FOG_DENSITY_CLEAR := 0.0005
## Fog density in a whiteout (a few tens of metres of near-white murk)
const FOG_DENSITY_WHITEOUT := 0.06

## Valley haze: a thin layer pooling below the lowest playable terrain, so
## the valley floor and the feet of the distant ranges sit in mist while the
## upper mountain stays crisp. Height fog only ever adds fog below this line
const VALLEY_HAZE_ABOVE_FLOOR := 50.0
const VALLEY_HAZE_DENSITY := 0.006

## Volumetric fog (Forward+ only) fades in once visibility drops below this
const VOLUMETRIC_FROM_VISIBILITY := 0.7
const VOLUMETRIC_DENSITY_MAX := 0.045

## Height of the snowfall emitter above the follow target
const SNOW_EMITTER_HEIGHT := 13.0
## Half-extents of the snowfall emission box (about 24 m across: the chase
## camera sits a few metres behind the climber, so density near it is what
## sells a storm)
const SNOW_BOX_EXTENTS := Vector3(12.0, 1.5, 12.0)

## Rain falls from lower and faster; the box is tighter so streaks stay dense
const RAIN_EMITTER_HEIGHT := 11.0
const RAIN_BOX_EXTENTS := Vector3(12.0, 0.5, 12.0)
const RAIN_FALL_SPEED := 16.0

## Spindrift (wind-blown snow) skims the ground around the climber
const SPINDRIFT_HEIGHT := 0.8
const SPINDRIFT_BOX_EXTENTS := Vector3(11.0, 0.7, 11.0)

## Particle buffer sizes; changing CPUParticles3D.amount wipes every live
## particle, so they are allocated once and intensity is expressed through
## size/alpha (rain is the exception: it has two tiers, see _drive_rainfall)
const SNOW_MAX_AMOUNT := 3200
const RAIN_LIGHT_AMOUNT := 700
const RAIN_HEAVY_AMOUNT := 1500
const SPINDRIFT_MAX_AMOUNT := 900

## Air temperature at the climber (Celsius) above which precipitation falls
## as rain, and below which it is all snow; in between it is sleet (both)
const RAIN_TEMPERATURE := 1.5
const SNOW_TEMPERATURE := -0.5

## Wind speed (m/s) from which loose snow starts blowing along the ground,
## and where spindrift reaches full strength
const SPINDRIFT_WIND_MIN := 9.0
const SPINDRIFT_WIND_FULL := 24.0

## Cloud sheet altitude above the highest terrain
const CLOUD_ALTITUDE_ABOVE_SUMMIT := 420.0

## Colours when the sun is well below the horizon
const NIGHT_TOP := Color(0.010, 0.016, 0.045)
const NIGHT_HORIZON := Color(0.035, 0.050, 0.095)
## Colours in civil twilight (sun a few degrees below the horizon)
const TWILIGHT_TOP := Color(0.05, 0.09, 0.26)
const TWILIGHT_HORIZON := Color(0.42, 0.30, 0.34)
## Colours with the sun low (golden hour)
const GOLDEN_TOP := Color(0.14, 0.30, 0.62)
const GOLDEN_HORIZON := Color(0.86, 0.58, 0.36)

## Sun disc size and halo when the disc is shown (degrees)
const SUN_DISC_SIZE := 0.6
const SUN_HALO_ANGLE := 6.0
## Alpine daytime: deep saturated zenith, pale horizon
const DAY_TOP := Color(0.09, 0.28, 0.70)
const DAY_HORIZON := Color(0.72, 0.81, 0.92)

## Overcast, storm and whiteout targets (scaled by daylight brightness)
const OVERCAST_TOP := Color(0.50, 0.54, 0.60)
const OVERCAST_HORIZON := Color(0.74, 0.76, 0.80)
const STORM_TINT := Color(0.28, 0.30, 0.34)
const WHITEOUT_TINT := Color(0.86, 0.87, 0.89)
const FOG_WHITE := Color(0.90, 0.91, 0.93)

## Cloud colours: sunlit tops by time of day, and the shaded undersides
const CLOUD_LIT_DAY := Color(0.99, 0.99, 1.0)
const CLOUD_LIT_GOLDEN := Color(1.0, 0.80, 0.58)
const CLOUD_LIT_TWILIGHT := Color(0.46, 0.40, 0.50)
const CLOUD_SHADE_DAY := Color(0.64, 0.68, 0.76)
const CLOUD_SHADE_OVERCAST := Color(0.52, 0.55, 0.60)
const CLOUD_SHADE_STORM := Color(0.30, 0.32, 0.36)

## What is falling right now (decided from precipitation and temperature)
enum PrecipitationForm { NONE, SNOW, SLEET, RAIN }

# =============================================================================
# NODES
# =============================================================================

## World environment holding the sky, fog and tonemap settings
var world_environment: WorldEnvironment

## Environment resource driven every refresh
var environment: Environment

## Procedural sky material (alpine palette)
var sky_material: ProceduralSkyMaterial

## The sun (or moon, at night). Named "SunLight" so other systems can find it
var sun_light: DirectionalLight3D

## Falling snow that follows the player
var snowfall: CPUParticles3D

## Rain streaks that follow the player (warm precipitation)
var rainfall: CPUParticles3D

## Wind-blown snow skimming the ground around the player
var spindrift: CPUParticles3D

## Cloud sheet above the summit
var clouds: CloudLayer

## Distant ranges and the hazy valley floor beyond the playable terrain
var horizon: HorizonRange

## Materials shared by every particle of each emitter
var _snow_material: StandardMaterial3D
var _rain_material: StandardMaterial3D
var _spindrift_material: StandardMaterial3D

# =============================================================================
# SERVICES
# =============================================================================

var time_service: TimeService = null
var weather_service: WeatherService = null
var temperature_system: TemperatureSystem = null
var terrain_service: TerrainService = null

# =============================================================================
# STATE
# =============================================================================

## Rendering method reported by the engine at start
## ("forward_plus", "mobile" or "gl_compatibility")
var _rendering_method: String = "forward_plus"
var _is_compatibility: bool = false
var _is_forward_plus: bool = true

## Accumulated time since the last lighting refresh
var _refresh_accumulator: float = REFRESH_INTERVAL

## Smoothed fog density (weather changes are gradual, so is the haze)
var _fog_density: float = FOG_DENSITY_CLEAR

## True until the first refresh has run (first refresh snaps instead of lerping)
var _first_refresh: bool = true

## Cached weather state used by the last refresh
var _last_weather: GameEnums.WeatherState = GameEnums.WeatherState.CLEAR

## Snow emitter amount currently applied (intensity tier, see _drive_snowfall)
var _snow_amount: int = 0

## Rain buffer size currently applied (0 = not raining)
var _rain_amount: int = 0

## What is falling right now
var _precipitation_form: PrecipitationForm = PrecipitationForm.NONE

## Precipitation intensity 0..1 from the weather state
var _precipitation_intensity: float = 0.0

## Cloud sheet altitude (metres) and current coverage (for debug)
var _cloud_altitude: float = 3600.0
var _cloud_coverage: float = 0.0

## Horizontal wind direction used to lead the snow emitter
var _wind_dir: Vector3 = Vector3(1, 0, 0)

## Wind speed (m/s) used for snow drift
var _wind_speed: float = 3.0


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_detect_renderer()
	_build_environment()
	_build_sun()
	_build_snowfall()
	_build_rainfall()
	_build_spindrift()
	_build_clouds()
	_build_horizon()

	# Services may arrive later than this node (or never, in isolated tests)
	ServiceLocator.get_service_async("TimeService", _on_time_service_ready)
	ServiceLocator.get_service_async("WeatherService", _on_weather_service_ready)
	ServiceLocator.get_service_async("TemperatureSystem", _on_temperature_system_ready)
	ServiceLocator.get_service_async("TerrainService", _on_terrain_service_ready)

	# Weather events are broadcast globally; refresh immediately on change
	EventBus.weather_changed.connect(_on_weather_changed)
	EventBus.wind_changed.connect(_on_wind_changed)

	print("[EnvironmentVisuals] Sky, clouds, ranges, sun, fog and precipitation ready (%s)" % _rendering_method)


func _process(delta: float) -> void:
	_refresh_accumulator += delta
	if _refresh_accumulator >= REFRESH_INTERVAL:
		_refresh(_refresh_accumulator)
		_refresh_accumulator = 0.0

	_follow_emitters()
	_follow_clouds()


# =============================================================================
# CONSTRUCTION
# =============================================================================

func _detect_renderer() -> void:
	_rendering_method = detect_rendering_method()
	_is_compatibility = _rendering_method == "gl_compatibility"
	_is_forward_plus = _rendering_method == "forward_plus"


## The rendering method in use: "forward_plus", "mobile" or "gl_compatibility".
## Godot 4.2 has no runtime query for this, so read the project setting and
## treat the absence of a RenderingDevice (Compatibility, or headless) as
## "gl_compatibility", which is also the safe answer for feature gating.
static func detect_rendering_method() -> String:
	if RenderingServer.get_rendering_device() == null:
		return "gl_compatibility"
	var method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus"))
	if method == "mobile" or method == "gl_compatibility":
		return method
	return "forward_plus"


func _build_environment() -> void:
	sky_material = ProceduralSkyMaterial.new()
	sky_material.sky_top_color = DAY_TOP
	sky_material.sky_horizon_color = DAY_HORIZON
	sky_material.sky_curve = 0.12
	sky_material.sky_energy_multiplier = 1.0
	# The ground half of the sky reads as distant haze below the horizon,
	# not a dark sea: keep it close to the horizon colour
	sky_material.ground_horizon_color = DAY_HORIZON
	sky_material.ground_bottom_color = DAY_HORIZON * Color(0.72, 0.75, 0.80)
	sky_material.ground_curve = 0.12
	# Tight sun disc with a short halo; the default 30 degree glow whites out
	# the whole horizon when a low sun is in frame
	sky_material.sun_angle_max = SUN_HALO_ANGLE
	sky_material.sun_curve = 0.08
	sky_material.use_debanding = true

	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_128

	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky

	# Ambient is a flat colour derived from the sky palette every refresh, so
	# shaded snow stays a cool blue-grey rather than black. Deliberately NOT
	# sourced from the sky: on the Compatibility (OpenGL3) backend in 4.2 the
	# sky-sourced ambient ignores ambient_light_energy and returns an
	# unfiltered zenith sample, which is far too blue and blows out snow
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_sky_contribution = 0.0
	environment.ambient_light_color = DAY_HORIZON.lerp(DAY_TOP, AMBIENT_ZENITH_MIX)
	environment.ambient_light_energy = AMBIENT_ENERGY_DAY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# Filmic keeps sunlit snow from clipping while preserving shadow detail.
	# Godot's filmic curve carries a 2x exposure bias, so the exposure sits
	# a little under 1.0 to leave headroom for near-white snow at noon
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = TONEMAP_EXPOSURE
	environment.tonemap_white = 6.0

	# Plain depth fog (works on every renderer); density follows visibility.
	# Height fog is set per refresh once the terrain's floor is known
	environment.fog_enabled = true
	environment.volumetric_fog_enabled = false
	environment.fog_light_color = DAY_HORIZON
	environment.fog_light_energy = 1.0
	environment.fog_sun_scatter = 0.08
	environment.fog_density = FOG_DENSITY_CLEAR
	environment.fog_aerial_perspective = 0.35
	environment.fog_sky_affect = 0.2
	environment.fog_height_density = 0.0

	# --- Post-processing: Forward+ / Mobile only ---------------------------
	# The Compatibility renderer in 4.2 has none of these; setting them there
	# is harmless but pointless, so keep its Environment plain
	if not _is_compatibility:
		# A soft bloom on sunlit snow, the sun disc and the base camp beacon
		environment.glow_enabled = true
		environment.glow_normalized = false
		environment.glow_intensity = 0.35
		environment.glow_strength = 0.9
		environment.glow_bloom = 0.04
		environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
		environment.glow_hdr_threshold = 0.9
		environment.glow_hdr_scale = 2.0
		environment.glow_hdr_luminance_cap = 8.0

		# A touch more contrast and colour than the flat filmic output
		environment.adjustment_enabled = true
		environment.adjustment_brightness = 1.0
		environment.adjustment_contrast = 1.06
		environment.adjustment_saturation = 1.08

	if _is_forward_plus:
		# Contact shadows in gullies, under the climber and around camp
		environment.ssao_enabled = true
		environment.ssao_radius = 2.0
		environment.ssao_intensity = 1.6
		environment.ssao_power = 1.5
		environment.ssao_detail = 0.5
		environment.ssao_horizon = 0.06
		environment.ssao_sharpness = 0.98
		environment.ssao_light_affect = 0.0
		environment.ssao_ao_channel_affect = 0.0

		# Volumetric fog is switched on per refresh when the weather closes
		# in (light shafts and drifting murk near the climber); the depth fog
		# above still carries the distance
		environment.volumetric_fog_density = 0.0
		environment.volumetric_fog_length = 96.0
		environment.volumetric_fog_detail_spread = 2.0
		environment.volumetric_fog_ambient_inject = 0.5
		environment.volumetric_fog_anisotropy = 0.35
		environment.volumetric_fog_sky_affect = 0.6

	world_environment = WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	add_child(world_environment)


func _build_sun() -> void:
	sun_light = DirectionalLight3D.new()
	sun_light.name = "SunLight"
	sun_light.light_color = Color(1.0, 0.98, 0.95)
	sun_light.light_energy = SUN_ENERGY_MAX
	sun_light.light_indirect_energy = 1.0
	sun_light.light_angular_distance = SUN_DISC_SIZE
	sun_light.shadow_enabled = true

	if _is_compatibility:
		# A single orthogonal map over ~180 m is acne-free on the OpenGL3
		# backend (PSSM split boundaries speckle there) and, with the default
		# 4096 map, still resolves to a few centimetres per texel around the
		# climber
		sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun_light.directional_shadow_max_distance = 180.0
		sun_light.directional_shadow_fade_start = 0.8
		sun_light.shadow_bias = 0.05
		sun_light.shadow_normal_bias = 2.0
		sun_light.shadow_blur = 1.5
	else:
		# Four blended cascades: crisp shadows at the boots, and the ridges
		# and gullies a few hundred metres down the face still cast
		sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		sun_light.directional_shadow_split_1 = 0.08
		sun_light.directional_shadow_split_2 = 0.2
		sun_light.directional_shadow_split_3 = 0.45
		sun_light.directional_shadow_blend_splits = true
		sun_light.directional_shadow_max_distance = 420.0
		sun_light.directional_shadow_fade_start = 0.85
		sun_light.shadow_bias = 0.03
		sun_light.shadow_normal_bias = 1.6
		sun_light.shadow_blur = 1.2

	# Default: mid-morning sun from the south-east until TimeService arrives
	_aim_light(Vector3(0.45, 0.65, 0.6).normalized())
	add_child(sun_light)


func _build_snowfall() -> void:
	_snow_material = _make_sprite_material(Color(0.95, 0.96, 1.0))

	# Soft round sprites read as flakes at every distance, where the old
	# five-segment spheres turned into hard dots
	var flake := QuadMesh.new()
	flake.size = Vector2(0.12, 0.12)
	flake.material = _snow_material

	snowfall = CPUParticles3D.new()
	snowfall.name = "Snowfall"
	snowfall.emitting = false
	snowfall.amount = SNOW_MAX_AMOUNT
	snowfall.lifetime = 8.0
	snowfall.preprocess = 2.0
	snowfall.randomness = 0.4
	snowfall.local_coords = false
	snowfall.mesh = flake
	snowfall.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	snowfall.emission_box_extents = SNOW_BOX_EXTENTS
	snowfall.direction = Vector3.DOWN
	snowfall.spread = 25.0
	snowfall.gravity = Vector3(0, -0.4, 0)
	snowfall.initial_velocity_min = 1.2
	snowfall.initial_velocity_max = 2.0
	# A little sideways acceleration makes flakes flutter instead of falling
	# in straight lines
	snowfall.tangential_accel_min = -0.6
	snowfall.tangential_accel_max = 0.6
	snowfall.scale_amount_min = 0.5
	snowfall.scale_amount_max = 1.2
	snowfall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Particles live in world space around a moving emitter: keep a generous
	# bounds box so they are never frustum-culled while the emitter walks off
	snowfall.custom_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 120))
	add_child(snowfall)


func _build_rainfall() -> void:
	_rain_material = StandardMaterial3D.new()
	_rain_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rain_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_rain_material.albedo_color = Color(0.80, 0.86, 0.95, 0.45)
	_rain_material.disable_receive_shadows = true

	# A thin streak aligned with its own velocity (particle_flag_align_y)
	var streak := BoxMesh.new()
	streak.size = Vector3(0.014, 0.42, 0.014)
	streak.material = _rain_material

	rainfall = CPUParticles3D.new()
	rainfall.name = "Rainfall"
	rainfall.emitting = false
	rainfall.amount = RAIN_HEAVY_AMOUNT
	rainfall.lifetime = 1.1
	rainfall.preprocess = 1.0
	rainfall.randomness = 0.3
	rainfall.local_coords = false
	rainfall.mesh = streak
	rainfall.particle_flag_align_y = true
	rainfall.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	rainfall.emission_box_extents = RAIN_BOX_EXTENTS
	rainfall.direction = Vector3.DOWN
	rainfall.spread = 3.0
	rainfall.gravity = Vector3.ZERO
	rainfall.initial_velocity_min = RAIN_FALL_SPEED * 0.85
	rainfall.initial_velocity_max = RAIN_FALL_SPEED * 1.1
	rainfall.scale_amount_min = 0.7
	rainfall.scale_amount_max = 1.2
	rainfall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rainfall.custom_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 120))
	add_child(rainfall)


func _build_spindrift() -> void:
	_spindrift_material = StandardMaterial3D.new()
	_spindrift_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_spindrift_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_spindrift_material.albedo_color = Color(0.93, 0.95, 1.0, 0.4)
	_spindrift_material.disable_receive_shadows = true

	# Wisps stretched along their own velocity (particle_flag_align_y), so
	# they streak across the snow the way blown snow does
	var grain := BoxMesh.new()
	grain.size = Vector3(0.025, 0.4, 0.025)
	grain.material = _spindrift_material

	spindrift = CPUParticles3D.new()
	spindrift.name = "Spindrift"
	spindrift.emitting = false
	spindrift.amount = SPINDRIFT_MAX_AMOUNT
	spindrift.lifetime = 1.6
	spindrift.preprocess = 1.0
	spindrift.randomness = 0.5
	spindrift.local_coords = false
	spindrift.mesh = grain
	spindrift.particle_flag_align_y = true
	spindrift.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	spindrift.emission_box_extents = SPINDRIFT_BOX_EXTENTS
	spindrift.direction = Vector3.RIGHT
	spindrift.spread = 12.0
	spindrift.gravity = Vector3(0, -2.5, 0)
	spindrift.initial_velocity_min = 8.0
	spindrift.initial_velocity_max = 12.0
	spindrift.tangential_accel_min = -2.0
	spindrift.tangential_accel_max = 2.0
	spindrift.scale_amount_min = 0.5
	spindrift.scale_amount_max = 1.1
	spindrift.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	spindrift.custom_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 120))
	add_child(spindrift)


func _build_clouds() -> void:
	clouds = CloudLayer.new()
	add_child(clouds)


func _build_horizon() -> void:
	horizon = HorizonRange.new()
	add_child(horizon)


## Unshaded, alpha-blended billboard with a soft radial sprite
func _make_sprite_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.billboard_keep_scale = true
	material.albedo_color = color
	material.albedo_texture = _make_soft_dot_texture()
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.disable_receive_shadows = true
	return material


## Radial gradient: solid centre fading to nothing at the edge
func _make_soft_dot_texture() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	gradient.add_point(0.4, Color(1.0, 1.0, 1.0, 0.8))

	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 32
	texture.height = 32
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	return texture


# =============================================================================
# SERVICE HOOKS
# =============================================================================

func _on_time_service_ready(service: Object) -> void:
	time_service = service as TimeService
	_request_refresh()


func _on_weather_service_ready(service: Object) -> void:
	weather_service = service as WeatherService
	if weather_service != null:
		weather_service.weather_changed.connect(_on_weather_changed)
		weather_service.wind_changed.connect(_on_service_wind_changed)
		weather_service.wind_direction_changed.connect(_on_wind_direction_changed)
	_request_refresh()


func _on_temperature_system_ready(service: Object) -> void:
	temperature_system = service as TemperatureSystem
	_request_refresh()


func _on_terrain_service_ready(service: Object) -> void:
	terrain_service = service as TerrainService
	if terrain_service == null:
		return
	if not terrain_service.terrain_loaded.is_connected(_on_terrain_loaded):
		terrain_service.terrain_loaded.connect(_on_terrain_loaded)
	# The mountain is usually loaded before this node exists
	if not terrain_service.is_loading and not terrain_service.chunks.is_empty():
		_on_terrain_loaded(terrain_service.current_mountain)


func _on_terrain_loaded(mountain_id: String) -> void:
	if terrain_service == null or horizon == null:
		return
	var bounds_min := terrain_service.terrain_bounds_min
	var bounds_max := terrain_service.terrain_bounds_max
	if not is_finite(bounds_min.y) or not is_finite(bounds_max.y):
		return
	var center := (bounds_min + bounds_max) * 0.5
	horizon.build(center, bounds_min.y, bounds_max.y, mountain_id.hash())
	_cloud_altitude = bounds_max.y + CLOUD_ALTITUDE_ABOVE_SUMMIT
	_request_refresh()


func _on_weather_changed(_old: GameEnums.WeatherState, _new: GameEnums.WeatherState) -> void:
	_request_refresh()


## EventBus.wind_changed(strength, direction)
func _on_wind_changed(_strength: GameEnums.WindStrength, _direction: Vector3) -> void:
	_request_refresh()


## WeatherService.wind_changed(old_strength, new_strength)
func _on_service_wind_changed(_old: GameEnums.WindStrength, _new: GameEnums.WindStrength) -> void:
	_request_refresh()


## WeatherService.wind_direction_changed(direction)
func _on_wind_direction_changed(_direction: Vector3) -> void:
	_request_refresh()


## Force a refresh on the next frame
func _request_refresh() -> void:
	_refresh_accumulator = REFRESH_INTERVAL


# =============================================================================
# REFRESH
# =============================================================================

## Start a run from its configured weather: the next refresh snaps fog, cloud
## cover and precipitation instead of easing in from whatever the sky looked
## like before
func reset_for_run() -> void:
	_first_refresh = true
	for emitter in [snowfall, rainfall, spindrift]:
		var particles := emitter as CPUParticles3D
		if particles != null:
			# restart() clears the live particles but also switches emission
			# back on, so stop it again afterwards or the preprocess spawns
			# a burst of flakes into a clear sky before the first refresh
			particles.restart()
			particles.emitting = false
	if clouds != null:
		clouds.snap_next()
	_request_refresh()


## Recompute sun, sky, clouds, fog and precipitation from the current time and
## weather. [param elapsed] is the real time since the previous refresh.
func _refresh(elapsed: float) -> void:
	var sun_dir := _get_sun_direction()
	var sun_elevation := rad_to_deg(asin(clampf(sun_dir.y, -1.0, 1.0)))
	var weather := _get_weather()
	var cloud := _get_cloud_cover(weather)
	var visibility := _get_visibility(weather)

	_wind_dir = _get_wind_direction()
	_wind_speed = _get_wind_speed()

	_update_sun(sun_dir, sun_elevation, cloud, weather)
	var palette := _update_sky_and_fog(sun_elevation, cloud, visibility, weather, elapsed)
	_update_clouds(sun_elevation, cloud, visibility, weather, palette)
	_update_precipitation(weather, visibility)

	_last_weather = weather
	_first_refresh = false


func _update_sun(sun_dir: Vector3, elevation: float, cloud: float, weather: GameEnums.WeatherState) -> void:
	var weather_factor := 1.0 - cloud * 0.55
	match weather:
		GameEnums.WeatherState.STORM:
			weather_factor *= 0.5
		GameEnums.WeatherState.WHITEOUT:
			weather_factor *= 0.35

	if elevation > 0.0:
		# Daylight: shine from the sun toward the world
		_aim_light(sun_dir)
		var intensity := 1.0
		var color := Color(1.0, 0.98, 0.95)
		if time_service != null:
			intensity = clampf(time_service.get_light_intensity(), 0.0, 1.0)
			color = time_service.get_light_color()
		# Ease in over the first degrees so sunrise is not a hard switch.
		# Keep a floor under the low sun: long warm shadows are how the
		# player reads the hour, so golden hour must still cast them
		var horizon_fade := clampf(elevation / 3.0, 0.0, 1.0)
		var scaled := lerpf(0.65, 1.0, intensity)
		sun_light.light_color = color
		sun_light.light_energy = maxf(SUN_ENERGY_MAX * scaled * horizon_fade, 0.02) * weather_factor
	else:
		# Night: a faint blue moon high in the opposite half of the sky.
		# Everything is continuous with the day branch at elevation 0: the
		# light starts where the sun set (energy floor, golden colour) and
		# swings up to the moon over the first six degrees of twilight
		var flat := Vector3(-sun_dir.x, 0.0, -sun_dir.z)
		if flat.length_squared() < 0.0001:
			flat = Vector3(0, 0, -1)
		var moon_dir := (flat.normalized() * 0.7 + Vector3.UP * 0.714).normalized()
		var horizon_dir := Vector3(sun_dir.x, 0.0, sun_dir.z)
		if horizon_dir.length_squared() < 0.0001:
			horizon_dir = -flat
		horizon_dir = (horizon_dir.normalized() + Vector3.UP * 0.02).normalized()
		var twilight := clampf(-elevation / 6.0, 0.0, 1.0)
		_aim_light(horizon_dir.slerp(moon_dir, twilight))
		var sunset_color := Color(1.0, 0.8, 0.5)  # TimeService's colour at the horizon
		sun_light.light_color = sunset_color.lerp(MOON_COLOR, twilight)
		sun_light.light_energy = lerpf(0.02, MOON_ENERGY, twilight) * weather_factor


## Returns the palette the cloud sheet needs: {"top", "horizon", "fog", "brightness"}
func _update_sky_and_fog(elevation: float, cloud: float, visibility: float, weather: GameEnums.WeatherState, elapsed: float) -> Dictionary:
	# --- Time of day palette -------------------------------------------------
	var top: Color
	var horizon_color: Color
	if elevation <= -10.0:
		top = NIGHT_TOP
		horizon_color = NIGHT_HORIZON
	elif elevation <= -3.0:
		var t := smoothstep(-10.0, -3.0, elevation)
		top = NIGHT_TOP.lerp(TWILIGHT_TOP, t)
		horizon_color = NIGHT_HORIZON.lerp(TWILIGHT_HORIZON, t)
	elif elevation <= 6.0:
		var t := smoothstep(-3.0, 6.0, elevation)
		top = TWILIGHT_TOP.lerp(GOLDEN_TOP, t)
		horizon_color = TWILIGHT_HORIZON.lerp(GOLDEN_HORIZON, t)
	else:
		var t := smoothstep(6.0, 25.0, elevation)
		top = GOLDEN_TOP.lerp(DAY_TOP, t)
		horizon_color = GOLDEN_HORIZON.lerp(DAY_HORIZON, t)

	# Overall brightness of the sky (keeps overcast/whiteout dark at night)
	var brightness := clampf((elevation + 6.0) / 20.0, 0.06, 1.0)

	# --- Weather overlay -----------------------------------------------------
	top = top.lerp(OVERCAST_TOP * brightness, cloud * 0.85)
	horizon_color = horizon_color.lerp(OVERCAST_HORIZON * brightness, cloud * 0.7)

	match weather:
		GameEnums.WeatherState.STORM:
			# Storms darken the sky
			top = top.lerp(STORM_TINT * brightness, 0.75)
			horizon_color = horizon_color.lerp(STORM_TINT * brightness * 1.35, 0.6)
		GameEnums.WeatherState.WHITEOUT:
			top = top.lerp(WHITEOUT_TINT * brightness, 0.9)
			horizon_color = horizon_color.lerp(WHITEOUT_TINT * brightness, 0.9)

	# Fog takes the horizon colour and whitens as visibility drops
	var fog_color := horizon_color.lerp(FOG_WHITE * brightness, 1.0 - visibility)

	# The sky shader paints the sun disc as light colour x energy. When that
	# is dimmer than the surrounding sky (low sun, storm) it would read as a
	# dark hole, so let the sun sink into the haze instead
	# Show the disc in clear-ish skies once the sun is properly up; a
	# luminance comparison here flapped several times a day
	var clear_sky := weather == GameEnums.WeatherState.CLEAR \
		or weather == GameEnums.WeatherState.PARTLY_CLOUDY \
		or weather == GameEnums.WeatherState.CLEARING
	var show_disc := elevation > 1.0 and visibility > 0.5 and clear_sky and cloud < 0.6
	# Hide the disc in the sky only: light_angular_distance also sets the
	# soft-shadow penumbra on Forward+, so it must not change
	sun_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY if show_disc \
		else DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	sky_material.sun_angle_max = SUN_HALO_ANGLE if show_disc else 0.0

	# --- Apply sky ----------------------------------------------------------
	sky_material.sky_top_color = top
	sky_material.sky_horizon_color = horizon_color
	sky_material.ground_horizon_color = horizon_color
	sky_material.ground_bottom_color = horizon_color * Color(0.72, 0.75, 0.80)

	# Ambient: a flat colour between horizon and zenith (see _build_environment).
	# Flatter and a touch brighter under cloud; storm skies are dark, so lift
	# the energy or the ground turns to pitch
	var ambient := lerpf(AMBIENT_ENERGY_NIGHT, AMBIENT_ENERGY_DAY, brightness) + cloud * 0.15
	match weather:
		GameEnums.WeatherState.STORM:
			ambient *= 1.6
		GameEnums.WeatherState.WHITEOUT:
			ambient *= 1.2
	environment.ambient_light_color = horizon_color.lerp(top, AMBIENT_ZENITH_MIX)
	environment.ambient_light_energy = ambient

	# --- Fog ---------------------------------------------------------------
	# Exponential mapping: 1.0 -> faint haze, 0.05 -> whiteout
	var t_vis := clampf(1.0 - visibility, 0.0, 1.0)
	var target_density := FOG_DENSITY_CLEAR * pow(FOG_DENSITY_WHITEOUT / FOG_DENSITY_CLEAR, t_vis)
	if _first_refresh:
		_fog_density = target_density
	else:
		# ~3 s time constant: weather rolls in, it does not snap
		_fog_density = lerpf(_fog_density, target_density, 1.0 - exp(-elapsed / 3.0))

	environment.fog_density = _fog_density
	environment.fog_light_color = fog_color
	environment.fog_sun_scatter = 0.08 * visibility
	environment.fog_aerial_perspective = 0.35 * visibility
	environment.fog_sky_affect = lerpf(0.2, 1.0, t_vis * t_vis)

	# Valley haze below the playable terrain (see VALLEY_HAZE_*). The depth
	# fog takes over as visibility drops, so the haze thins with it
	var floor_y := _get_terrain_floor()
	if is_finite(floor_y):
		environment.fog_height = floor_y + VALLEY_HAZE_ABOVE_FLOOR
		environment.fog_height_density = VALLEY_HAZE_DENSITY * visibility
	else:
		environment.fog_height_density = 0.0

	# Volumetric murk near the climber once the weather closes in (Forward+)
	if _is_forward_plus:
		var murk := clampf((VOLUMETRIC_FROM_VISIBILITY - visibility) / VOLUMETRIC_FROM_VISIBILITY, 0.0, 1.0)
		environment.volumetric_fog_enabled = murk > 0.0
		environment.volumetric_fog_density = VOLUMETRIC_DENSITY_MAX * murk * murk
		environment.volumetric_fog_albedo = Color(fog_color.r, fog_color.g, fog_color.b, 1.0)
		# Self-lit to match the depth fog's colour, so near and far murk agree
		environment.volumetric_fog_emission = Color(fog_color.r, fog_color.g, fog_color.b, 1.0)
		environment.volumetric_fog_emission_energy = 0.4 * brightness * murk

	if horizon != null:
		horizon.set_haze_color(fog_color)
		# Fade the ranges with the fog's transmittance out to the near ring:
		# a faint haze leaves them crisp, a storm dissolves them, a whiteout
		# hides them completely
		var transmittance := exp(-_fog_density * HorizonRange.NEAR_RADIUS)
		horizon.set_fade(clampf(transmittance / 0.08, 0.0, 1.0))

	return {
		"top": top,
		"horizon": horizon_color,
		"fog": fog_color,
		"brightness": brightness,
	}


func _update_clouds(elevation: float, cloud: float, visibility: float, weather: GameEnums.WeatherState, palette: Dictionary) -> void:
	if clouds == null:
		return

	# Coverage and softness by weather; the service's smoothed cloud cover
	# can only add to the table so transitions roll in
	var coverage := 0.0
	var softness := 0.3
	match weather:
		GameEnums.WeatherState.CLEAR:
			coverage = 0.12
			softness = 0.22
		GameEnums.WeatherState.PARTLY_CLOUDY:
			coverage = 0.45
			softness = 0.3
		GameEnums.WeatherState.CLOUDY:
			coverage = 0.66
			softness = 0.4
		GameEnums.WeatherState.CLEARING:
			coverage = 0.5
			softness = 0.35
		GameEnums.WeatherState.OVERCAST:
			coverage = 0.92
			softness = 0.6
		GameEnums.WeatherState.DETERIORATING:
			coverage = 0.88
			softness = 0.5
		GameEnums.WeatherState.SNOW:
			coverage = 0.95
			softness = 0.65
		GameEnums.WeatherState.STORM, GameEnums.WeatherState.WHITEOUT:
			coverage = 1.0
			softness = 0.7
	coverage = maxf(coverage, cloud * 0.9)

	# Sunlit tops follow the hour; undersides follow the weather
	var brightness: float = palette["brightness"]
	var lit: Color
	if elevation <= -6.0:
		lit = NIGHT_HORIZON * 2.2
	elif elevation <= 2.0:
		lit = CLOUD_LIT_TWILIGHT.lerp(CLOUD_LIT_GOLDEN, smoothstep(-6.0, 2.0, elevation))
	else:
		lit = CLOUD_LIT_GOLDEN.lerp(CLOUD_LIT_DAY, smoothstep(2.0, 20.0, elevation))
	var shade := CLOUD_SHADE_DAY.lerp(CLOUD_SHADE_OVERCAST, cloud)
	if weather == GameEnums.WeatherState.STORM:
		shade = CLOUD_SHADE_STORM
		lit = lit.lerp(CLOUD_SHADE_OVERCAST, 0.5)
	lit = lit * lerpf(0.35, 1.0, brightness)
	shade = shade * lerpf(0.25, 1.0, brightness)

	# The fog hides the sheet anyway in a whiteout; thinning it a little
	# earlier keeps the two from fighting
	var t_vis := clampf(1.0 - visibility, 0.0, 1.0)
	var opacity := 1.0 - t_vis * t_vis * 0.5

	clouds.set_conditions(coverage, softness, opacity, lit, shade, _first_refresh)
	clouds.set_wind(Vector2(_wind_dir.x, _wind_dir.z) * _wind_speed)
	_cloud_coverage = coverage


# =============================================================================
# PRECIPITATION
# =============================================================================

func _update_precipitation(weather: GameEnums.WeatherState, visibility: float) -> void:
	var intensity := _precipitation_intensity_for(weather)
	_precipitation_intensity = intensity
	_precipitation_form = _precipitation_form_for(intensity)

	var snow_share := 0.0
	var rain_share := 0.0
	match _precipitation_form:
		PrecipitationForm.SNOW:
			snow_share = 1.0
		PrecipitationForm.RAIN:
			rain_share = 1.0
		PrecipitationForm.SLEET:
			snow_share = 0.55
			rain_share = 0.6

	_drive_snowfall(intensity * snow_share, visibility)
	_drive_rainfall(intensity * rain_share, visibility)
	_drive_spindrift(visibility)


## 0 = dry, 1 = whiteout-strength precipitation
func _precipitation_intensity_for(weather: GameEnums.WeatherState) -> float:
	match weather:
		GameEnums.WeatherState.SNOW:
			return 0.41
		GameEnums.WeatherState.STORM:
			return 0.73
		GameEnums.WeatherState.WHITEOUT:
			return 1.0
		_:
			# Light precipitation during a deteriorating window (reported by the service)
			if weather_service != null and weather_service.is_precipitating():
				return 0.2
	return 0.0


## Snow, sleet or rain, from the air temperature at the climber
func _precipitation_form_for(intensity: float) -> PrecipitationForm:
	if intensity <= 0.0:
		return PrecipitationForm.NONE
	var temperature := _get_air_temperature()
	if temperature >= RAIN_TEMPERATURE:
		return PrecipitationForm.RAIN
	if temperature <= SNOW_TEMPERATURE:
		return PrecipitationForm.SNOW
	return PrecipitationForm.SLEET


func _drive_snowfall(intensity: float, visibility: float) -> void:
	if intensity <= 0.0:
		_snow_amount = 0
		if snowfall.emitting:
			snowfall.emitting = false
		return

	# Intensity tiers change flake size and opacity, never the buffer size
	_snow_amount = int(round(intensity * SNOW_MAX_AMOUNT))
	snowfall.scale_amount_min = lerpf(0.3, 0.55, intensity)
	snowfall.scale_amount_max = lerpf(0.6, 1.5, intensity)

	# Drift with the wind: stronger wind, flatter and faster flakes
	var drift := _wind_dir * (_wind_speed * 0.25)
	var fall := Vector3.DOWN * 1.5
	var velocity := drift + fall
	snowfall.direction = velocity.normalized()
	snowfall.initial_velocity_min = velocity.length() * 0.7
	snowfall.initial_velocity_max = velocity.length() * 1.2
	snowfall.spread = clampf(30.0 - _wind_speed, 8.0, 30.0)

	# Flakes dull slightly in murk so they do not sparkle against grey
	var flake_color := Color(0.95, 0.96, 1.0).lerp(Color(0.84, 0.86, 0.90), 1.0 - visibility)
	flake_color.a = lerpf(0.45, 1.0, intensity)
	_snow_material.albedo_color = flake_color

	if not snowfall.emitting:
		snowfall.emitting = true


func _drive_rainfall(intensity: float, visibility: float) -> void:
	if intensity <= 0.0:
		_rain_amount = 0
		if rainfall.emitting:
			rainfall.emitting = false
		return

	# Two buffer tiers: a drizzle at a third of the streaks, a downpour at
	# full. Changing amount restarts the emitter, so only do it on a change
	var amount := RAIN_HEAVY_AMOUNT if intensity >= 0.5 else RAIN_LIGHT_AMOUNT
	if amount != _rain_amount:
		_rain_amount = amount
		rainfall.amount = amount

	# Rain slants with the wind and hits the ground fast
	var velocity := Vector3.DOWN * RAIN_FALL_SPEED + _wind_dir * (_wind_speed * 0.6)
	rainfall.direction = velocity.normalized()
	rainfall.initial_velocity_min = velocity.length() * 0.85
	rainfall.initial_velocity_max = velocity.length() * 1.1
	rainfall.scale_amount_min = lerpf(0.6, 0.9, intensity)
	rainfall.scale_amount_max = lerpf(0.9, 1.4, intensity)

	var streak_color := Color(0.82, 0.88, 0.96).lerp(Color(0.74, 0.77, 0.82), 1.0 - visibility)
	streak_color.a = lerpf(0.35, 0.6, intensity)
	_rain_material.albedo_color = streak_color

	if not rainfall.emitting:
		rainfall.emitting = true


## Loose snow races along the ground in strong wind, when there is snow to
## lift: falling snow, or a snow or ice surface under the climber (never
## while it rains, and not over bare scree)
func _drive_spindrift(visibility: float) -> void:
	var strength := clampf((_wind_speed - SPINDRIFT_WIND_MIN) / (SPINDRIFT_WIND_FULL - SPINDRIFT_WIND_MIN), 0.0, 1.0)
	if strength <= 0.0 or _precipitation_form == PrecipitationForm.RAIN or not _has_loose_snow():
		if spindrift.emitting:
			spindrift.emitting = false
		return

	var velocity := _wind_dir * (_wind_speed * 0.85) + Vector3.DOWN * 0.4
	spindrift.direction = velocity.normalized()
	spindrift.initial_velocity_min = velocity.length() * 0.7
	spindrift.initial_velocity_max = velocity.length() * 1.15
	spindrift.spread = lerpf(14.0, 8.0, strength)
	spindrift.scale_amount_min = lerpf(0.5, 0.7, strength)
	spindrift.scale_amount_max = lerpf(0.9, 1.4, strength)

	var grain_color := Color(0.93, 0.95, 1.0).lerp(Color(0.86, 0.88, 0.92), 1.0 - visibility)
	grain_color.a = lerpf(0.18, 0.42, strength)
	_spindrift_material.albedo_color = grain_color

	if not spindrift.emitting:
		spindrift.emitting = true


## Keep the precipitation emitters above (and slightly upwind of) the player
## or camera, and the spindrift box on the ground around them
func _follow_emitters() -> void:
	if not snowfall.emitting and not rainfall.emitting and not spindrift.emitting:
		return

	var target := _get_follow_target()
	if target == null:
		return
	var anchor := target.global_position

	if snowfall.emitting:
		var lead := _wind_dir * minf(_wind_speed * 0.25 * 3.0, 12.0)
		snowfall.global_position = anchor + Vector3(0, SNOW_EMITTER_HEIGHT, 0) - lead

	if rainfall.emitting:
		# Streaks fall for ~0.7 s before reaching the ground: lead by that drift
		var lead := _wind_dir * minf(_wind_speed * 0.6 * 0.7, 10.0)
		rainfall.global_position = anchor + Vector3(0, RAIN_EMITTER_HEIGHT, 0) - lead

	if spindrift.emitting:
		# Emit upwind so the grains stream past and through the climber
		var lead := _wind_dir * minf(_wind_speed * 0.85 * 0.8, 14.0)
		spindrift.global_position = anchor + Vector3(0, SPINDRIFT_HEIGHT, 0) - lead


## The cloud sheet stays centred over whatever camera is rendering
func _follow_clouds() -> void:
	if clouds == null or not is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	# Never let the sheet come down onto the camera if the altitude is stale
	var altitude := maxf(_cloud_altitude, camera.global_position.y + 250.0)
	clouds.follow(camera.global_position, altitude)


# =============================================================================
# QUERIES (null-safe wrappers around the services)
# =============================================================================

func _get_sun_direction() -> Vector3:
	if time_service != null:
		var dir := time_service.get_sun_direction()
		if dir.length_squared() > 0.0001:
			return dir.normalized()
	return Vector3(0.45, 0.65, 0.6).normalized()


func _get_weather() -> GameEnums.WeatherState:
	if weather_service != null:
		return weather_service.current_weather
	return GameEnums.WeatherState.CLEAR


## Cloud cover 0-1. WeatherService only interpolates cloud_cover during
## transitions, so a directly-set weather state falls back to a table.
func _get_cloud_cover(weather: GameEnums.WeatherState) -> float:
	var from_state := 0.0
	match weather:
		GameEnums.WeatherState.CLEAR:
			from_state = 0.05
		GameEnums.WeatherState.PARTLY_CLOUDY:
			from_state = 0.3
		GameEnums.WeatherState.CLOUDY:
			from_state = 0.5
		GameEnums.WeatherState.CLEARING:
			from_state = 0.4
		GameEnums.WeatherState.OVERCAST:
			from_state = 0.8
		GameEnums.WeatherState.DETERIORATING:
			from_state = 0.8
		GameEnums.WeatherState.SNOW:
			from_state = 0.9
		GameEnums.WeatherState.STORM, GameEnums.WeatherState.WHITEOUT:
			from_state = 1.0

	if weather_service != null:
		return clampf(maxf(from_state, weather_service.cloud_cover), 0.0, 1.0)
	return from_state


## Visibility 0-1 (1 = crystal clear). Combines the service's smoothed value
## with a per-state floor for states the service never transitioned through.
func _get_visibility(weather: GameEnums.WeatherState) -> float:
	var from_state := 1.0
	match weather:
		GameEnums.WeatherState.PARTLY_CLOUDY:
			from_state = 0.95
		GameEnums.WeatherState.CLOUDY:
			from_state = 0.9
		GameEnums.WeatherState.CLEARING:
			from_state = 0.85
		GameEnums.WeatherState.OVERCAST:
			from_state = 0.8
		GameEnums.WeatherState.DETERIORATING:
			from_state = 0.65
		GameEnums.WeatherState.SNOW:
			from_state = 0.6
		GameEnums.WeatherState.STORM:
			from_state = 0.3
		GameEnums.WeatherState.WHITEOUT:
			from_state = 0.06

	if weather_service != null:
		return clampf(minf(from_state, weather_service.visibility), 0.03, 1.0)
	return from_state


func _get_wind_direction() -> Vector3:
	if weather_service != null:
		var dir := Vector3(weather_service.wind_direction.x, 0.0, weather_service.wind_direction.z)
		if dir.length_squared() > 0.0001:
			return dir.normalized()
	return Vector3(1, 0, 0)


func _get_wind_speed() -> float:
	if weather_service != null:
		return maxf(weather_service.wind_speed, 0.0)
	return 3.0


## True when there is snow about to blow: snow is falling, or the ground
## under the follow target is snow or ice (true when the terrain is unknown)
func _has_loose_snow() -> bool:
	if _precipitation_form == PrecipitationForm.SNOW or _precipitation_form == PrecipitationForm.SLEET:
		return true
	if terrain_service == null or terrain_service.chunks.is_empty():
		return true
	var target := _get_follow_target()
	if target == null or not terrain_service.has_terrain_at(target.global_position):
		return true
	match terrain_service.get_surface_at(target.global_position):
		GameEnums.SurfaceType.SNOW_FIRM, GameEnums.SurfaceType.SNOW_SOFT, \
		GameEnums.SurfaceType.SNOW_PACKED, GameEnums.SurfaceType.SNOW_POWDER, \
		GameEnums.SurfaceType.ICE, GameEnums.SurfaceType.MIXED:
			return true
	return false


## Air temperature at the climber (Celsius); well below freezing when unknown
func _get_air_temperature() -> float:
	if temperature_system != null:
		return temperature_system.get_air_temperature()
	return -8.0


## Elevation of the lowest playable terrain, or INF when no terrain is loaded
func _get_terrain_floor() -> float:
	if terrain_service != null and not terrain_service.chunks.is_empty():
		var floor_y := terrain_service.terrain_bounds_min.y
		if is_finite(floor_y):
			return floor_y
	return INF


## The node the precipitation should follow: the player, else the active camera
func _get_follow_target() -> Node3D:
	var player_obj: Object = ServiceLocator.get_service("PlayerController")
	if is_instance_valid(player_obj) and player_obj is Node3D:
		var player_node := player_obj as Node3D
		if player_node.is_inside_tree():
			return player_node

	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera != null and is_instance_valid(camera):
		return camera

	return null


# =============================================================================
# PUBLIC QUERIES
# =============================================================================

## What is falling right now (snow, sleet, rain or nothing)
func get_precipitation_form() -> PrecipitationForm:
	return _precipitation_form


## Rendering method the visuals were built for
func get_rendering_method() -> String:
	return _rendering_method


# =============================================================================
# HELPERS
# =============================================================================

## Point the directional light so it shines FROM [param toward_light_dir]
## (a unit vector toward the sun/moon) onto the world.
func _aim_light(toward_light_dir: Vector3) -> void:
	var shine_dir := -toward_light_dir.normalized()
	var up := Vector3.UP
	if absf(shine_dir.dot(up)) > 0.995:
		up = Vector3.BACK
	sun_light.transform.basis = Basis.looking_at(shine_dir, up)


# =============================================================================
# DEBUG
# =============================================================================

func get_debug_info() -> Dictionary:
	return {
		"renderer": _rendering_method,
		"sun_energy": sun_light.light_energy,
		"sun_color": sun_light.light_color,
		"fog_density": _fog_density,
		"weather": GameEnums.WeatherState.keys()[_last_weather],
		"precipitation": PrecipitationForm.keys()[_precipitation_form],
		"precipitation_intensity": _precipitation_intensity,
		"snow_emitting": snowfall.emitting,
		"snow_amount": _snow_amount,
		"rain_emitting": rainfall.emitting,
		"rain_amount": _rain_amount,
		"spindrift_emitting": spindrift.emitting,
		"cloud_coverage": _cloud_coverage,
		"cloud_altitude": _cloud_altitude,
		"volumetric_fog": environment.volumetric_fog_enabled,
	}
