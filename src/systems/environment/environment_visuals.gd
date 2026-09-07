class_name EnvironmentVisuals
extends Node3D
## Procedural visual layer for the environment: sky, sun, fog and snowfall.
## Created and owned by EnvironmentService; reads TimeService and
## WeatherService and never drives simulation state itself.
##
## Everything here is built from engine primitives (no imported assets) and
## avoids renderer features that the Compatibility (OpenGL3) backend lacks:
## no volumetric fog, no SDFGI/SSR/SSAO/glow. Depth fog, a procedural sky,
## one shadow-casting DirectionalLight3D and CPUParticles3D are used instead.
##
## Design Philosophy:
## - The player reads time and weather from the world, not from a HUD:
##   sun height, shadow length, sky colour and haze are the clock and forecast
## - Weather is felt: a storm darkens the sky, a whiteout swallows the horizon

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

## Fog density at full visibility (faint alpine haze: distant ridges recede)
const FOG_DENSITY_CLEAR := 0.0006
## Fog density in a whiteout (a few tens of metres of near-white murk)
const FOG_DENSITY_WHITEOUT := 0.06

## Height of the snowfall emitter above the follow target
const SNOW_EMITTER_HEIGHT := 14.0
## Half-extents of the snowfall emission box (about 30 m across)
const SNOW_BOX_EXTENTS := Vector3(16.0, 1.5, 16.0)

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

## Material shared by every snowflake
var _snow_material: StandardMaterial3D

# =============================================================================
# SERVICES
# =============================================================================

var time_service: TimeService = null
var weather_service: WeatherService = null

# =============================================================================
# STATE
# =============================================================================

## Accumulated time since the last lighting refresh
var _refresh_accumulator: float = REFRESH_INTERVAL

## Smoothed fog density (weather changes are gradual, so is the haze)
var _fog_density: float = FOG_DENSITY_CLEAR

## True until the first refresh has run (first refresh snaps instead of lerping)
var _first_refresh: bool = true

## Cached weather state used by the last refresh
var _last_weather: GameEnums.WeatherState = GameEnums.WeatherState.CLEAR

## Snow emitter amount currently applied (changing amount restarts the emitter)
var _snow_amount: int = 0

## Horizontal wind direction used to lead the snow emitter
var _wind_dir: Vector3 = Vector3(1, 0, 0)

## Wind speed (m/s) used for snow drift
var _wind_speed: float = 3.0


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_build_environment()
	_build_sun()
	_build_snowfall()

	# Services may arrive later than this node (or never, in isolated tests)
	ServiceLocator.get_service_async("TimeService", _on_time_service_ready)
	ServiceLocator.get_service_async("WeatherService", _on_weather_service_ready)

	# Weather events are broadcast globally; refresh immediately on change
	EventBus.weather_changed.connect(_on_weather_changed)
	EventBus.wind_changed.connect(_on_wind_changed)

	print("[EnvironmentVisuals] Sky, sun, fog and snowfall ready")


func _process(delta: float) -> void:
	_refresh_accumulator += delta
	if _refresh_accumulator >= REFRESH_INTERVAL:
		_refresh(_refresh_accumulator)
		_refresh_accumulator = 0.0

	_follow_snowfall()


# =============================================================================
# CONSTRUCTION
# =============================================================================

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

	# Plain depth fog (works on every renderer); density follows visibility
	environment.fog_enabled = true
	environment.volumetric_fog_enabled = false
	environment.fog_light_color = DAY_HORIZON
	environment.fog_light_energy = 1.0
	environment.fog_sun_scatter = 0.08
	environment.fog_density = FOG_DENSITY_CLEAR
	environment.fog_aerial_perspective = 0.35
	environment.fog_sky_affect = 0.2
	environment.fog_height_density = 0.0

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

	# Shadow settings that hold up on Compatibility as well as Forward+.
	# A single orthogonal map over ~180 m is acne-free on the OpenGL3 backend
	# (PSSM split boundaries speckle there) and, with the default 4096 map,
	# still resolves to a few centimetres per texel around the climber
	sun_light.shadow_enabled = true
	sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun_light.directional_shadow_max_distance = 180.0
	sun_light.directional_shadow_fade_start = 0.8
	sun_light.shadow_bias = 0.05
	sun_light.shadow_normal_bias = 2.0
	sun_light.shadow_blur = 1.5

	# Default: mid-morning sun from the south-east until TimeService arrives
	_aim_light(Vector3(0.45, 0.65, 0.6).normalized())
	add_child(sun_light)


func _build_snowfall() -> void:
	_snow_material = StandardMaterial3D.new()
	_snow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_snow_material.albedo_color = Color(0.95, 0.96, 1.0)
	_snow_material.disable_receive_shadows = true

	var flake := SphereMesh.new()
	flake.radius = 0.028
	flake.height = 0.056
	flake.radial_segments = 5
	flake.rings = 3
	flake.material = _snow_material

	snowfall = CPUParticles3D.new()
	snowfall.name = "Snowfall"
	snowfall.emitting = false
	snowfall.amount = 800
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
	snowfall.scale_amount_min = 0.5
	snowfall.scale_amount_max = 1.2
	snowfall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Particles live in world space around a moving emitter: keep a generous
	# bounds box so they are never frustum-culled while the emitter walks off
	snowfall.custom_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 120))
	add_child(snowfall)


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

## Recompute sun, sky, fog and snowfall from the current time and weather.
## [param elapsed] is the real time since the previous refresh (for smoothing).
func _refresh(elapsed: float) -> void:
	var sun_dir := _get_sun_direction()
	var sun_elevation := rad_to_deg(asin(clampf(sun_dir.y, -1.0, 1.0)))
	var weather := _get_weather()
	var cloud := _get_cloud_cover(weather)
	var visibility := _get_visibility(weather)

	_wind_dir = _get_wind_direction()
	_wind_speed = _get_wind_speed()

	_update_sun(sun_dir, sun_elevation, cloud, weather)
	_update_sky_and_fog(sun_elevation, cloud, visibility, weather, elapsed)
	_update_snowfall(weather, visibility)

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
		# Night: a faint blue moon high in the opposite half of the sky
		var flat := Vector3(-sun_dir.x, 0.0, -sun_dir.z)
		if flat.length_squared() < 0.0001:
			flat = Vector3(0, 0, -1)
		var moon_dir := (flat.normalized() * 0.7 + Vector3.UP * 0.714).normalized()
		_aim_light(moon_dir)
		# Blend from dusk light to moonlight through the first degrees of twilight
		var twilight := clampf(-elevation / 6.0, 0.0, 1.0)
		var dusk_color := Color(0.85, 0.55, 0.45)
		sun_light.light_color = dusk_color.lerp(MOON_COLOR, twilight)
		sun_light.light_energy = lerpf(0.12, MOON_ENERGY, twilight) * weather_factor


func _update_sky_and_fog(elevation: float, cloud: float, visibility: float, weather: GameEnums.WeatherState, elapsed: float) -> void:
	# --- Time of day palette -------------------------------------------------
	var top: Color
	var horizon: Color
	if elevation <= -10.0:
		top = NIGHT_TOP
		horizon = NIGHT_HORIZON
	elif elevation <= -3.0:
		var t := smoothstep(-10.0, -3.0, elevation)
		top = NIGHT_TOP.lerp(TWILIGHT_TOP, t)
		horizon = NIGHT_HORIZON.lerp(TWILIGHT_HORIZON, t)
	elif elevation <= 6.0:
		var t := smoothstep(-3.0, 6.0, elevation)
		top = TWILIGHT_TOP.lerp(GOLDEN_TOP, t)
		horizon = TWILIGHT_HORIZON.lerp(GOLDEN_HORIZON, t)
	else:
		var t := smoothstep(6.0, 25.0, elevation)
		top = GOLDEN_TOP.lerp(DAY_TOP, t)
		horizon = GOLDEN_HORIZON.lerp(DAY_HORIZON, t)

	# Overall brightness of the sky (keeps overcast/whiteout dark at night)
	var brightness := clampf((elevation + 6.0) / 20.0, 0.06, 1.0)

	# --- Weather overlay -----------------------------------------------------
	top = top.lerp(OVERCAST_TOP * brightness, cloud * 0.85)
	horizon = horizon.lerp(OVERCAST_HORIZON * brightness, cloud * 0.7)

	match weather:
		GameEnums.WeatherState.STORM:
			# Storms darken the sky
			top = top.lerp(STORM_TINT * brightness, 0.75)
			horizon = horizon.lerp(STORM_TINT * brightness * 1.35, 0.6)
		GameEnums.WeatherState.WHITEOUT:
			top = top.lerp(WHITEOUT_TINT * brightness, 0.9)
			horizon = horizon.lerp(WHITEOUT_TINT * brightness, 0.9)

	# Fog takes the horizon colour and whitens as visibility drops
	var fog_color := horizon.lerp(FOG_WHITE * brightness, 1.0 - visibility)

	# The sky shader paints the sun disc as light colour x energy. When that
	# is dimmer than the surrounding sky (low sun, storm) it would read as a
	# dark hole, so let the sun sink into the haze instead
	var disc_luma := sun_light.light_color.get_luminance() * sun_light.light_energy
	var show_disc := disc_luma >= horizon.get_luminance() * 0.9 and visibility > 0.5
	sun_light.light_angular_distance = SUN_DISC_SIZE if show_disc else 0.0
	sky_material.sun_angle_max = SUN_HALO_ANGLE if show_disc else 0.0

	# --- Apply sky ----------------------------------------------------------
	sky_material.sky_top_color = top
	sky_material.sky_horizon_color = horizon
	sky_material.ground_horizon_color = horizon
	sky_material.ground_bottom_color = horizon * Color(0.72, 0.75, 0.80)

	# Ambient: a flat colour between horizon and zenith (see _build_environment).
	# Flatter and a touch brighter under cloud; storm skies are dark, so lift
	# the energy or the ground turns to pitch
	var ambient := lerpf(AMBIENT_ENERGY_NIGHT, AMBIENT_ENERGY_DAY, brightness) + cloud * 0.15
	match weather:
		GameEnums.WeatherState.STORM:
			ambient *= 1.6
		GameEnums.WeatherState.WHITEOUT:
			ambient *= 1.2
	environment.ambient_light_color = horizon.lerp(top, AMBIENT_ZENITH_MIX)
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


func _update_snowfall(weather: GameEnums.WeatherState, visibility: float) -> void:
	var target_amount := 0
	match weather:
		GameEnums.WeatherState.SNOW:
			target_amount = 900
		GameEnums.WeatherState.STORM:
			target_amount = 1600
		GameEnums.WeatherState.WHITEOUT:
			target_amount = 2200
		_:
			# Light snow during a deteriorating window (reported by the service)
			if weather_service != null and weather_service.is_precipitating():
				target_amount = 450

	if target_amount == 0:
		if snowfall.emitting:
			snowfall.emitting = false
		return

	if target_amount != _snow_amount:
		_snow_amount = target_amount
		snowfall.amount = target_amount

	# Drift with the wind: stronger wind, flatter and faster flakes
	var drift := _wind_dir * (_wind_speed * 0.25)
	var fall := Vector3.DOWN * 1.5
	var velocity := drift + fall
	snowfall.direction = velocity.normalized()
	snowfall.initial_velocity_min = velocity.length() * 0.7
	snowfall.initial_velocity_max = velocity.length() * 1.2
	snowfall.spread = clampf(30.0 - _wind_speed, 8.0, 30.0)

	# Flakes dull slightly in murk so they do not sparkle against grey
	_snow_material.albedo_color = Color(0.95, 0.96, 1.0).lerp(Color(0.82, 0.84, 0.88), 1.0 - visibility)

	if not snowfall.emitting:
		snowfall.emitting = true


## Keep the emitter above (and slightly upwind of) the player or camera
func _follow_snowfall() -> void:
	if not snowfall.emitting:
		return

	var target := _get_follow_target()
	if target == null:
		return

	var lead := _wind_dir * minf(_wind_speed * 0.25 * 3.0, 12.0)
	snowfall.global_position = target.global_position + Vector3(0, SNOW_EMITTER_HEIGHT, 0) - lead


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


## The node the snow should follow: the player, else the active camera
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
		"sun_energy": sun_light.light_energy,
		"sun_color": sun_light.light_color,
		"fog_density": _fog_density,
		"weather": GameEnums.WeatherState.keys()[_last_weather],
		"snow_emitting": snowfall.emitting,
		"snow_amount": _snow_amount,
	}
