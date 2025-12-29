class_name TimeService
extends Node
## Manages game time simulation
## Handles time scaling, sun position, and time-based events
##
## Design Philosophy:
## - Time is a resource to be managed
## - Players read time from environment (shadows, sun position)
## - No persistent clock UI - checking watch costs time

# =============================================================================
# SIGNALS
# =============================================================================

signal time_updated(game_time: float)
signal hour_changed(hour: int)
signal time_of_day_changed(period: TimePeriod)
signal sunrise()
signal sunset()
signal golden_hour_started()
signal blue_hour_started()
signal night_fallen()
signal dawn_approaching()

# =============================================================================
# ENUMS
# =============================================================================

enum TimePeriod {
	NIGHT,          # 0:00 - 5:00
	DAWN,           # 5:00 - 6:30
	MORNING,        # 6:30 - 10:00
	MIDDAY,         # 10:00 - 14:00
	AFTERNOON,      # 14:00 - 17:00
	GOLDEN_HOUR,    # 17:00 - 18:30
	DUSK,           # 18:30 - 20:00
	EVENING         # 20:00 - 24:00
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Time Scaling")
## Game minutes per real second
@export var time_scale: float = 10.0 / 60.0  # 10 game min = 1 real min
## Minimum time scale (for dramatic moments)
@export var min_time_scale: float = 1.0 / 60.0
## Maximum time scale (for time skips)
@export var max_time_scale: float = 60.0 / 60.0

@export_group("Location")
## Latitude for sun calculations (45° = Alps)
@export var latitude: float = 45.0
## Day of year (affects sunrise/sunset times)
@export var day_of_year: int = 180  # Summer solstice default
## Timezone offset
@export var timezone_offset: float = 0.0

@export_group("Time Events")
## Hours for time period transitions
@export var dawn_start: float = 5.0
@export var sunrise_time: float = 6.0
@export var morning_start: float = 6.5
@export var midday_start: float = 10.0
@export var afternoon_start: float = 14.0
@export var golden_hour_start: float = 17.0
@export var sunset_time: float = 18.5
@export var dusk_end: float = 20.0

# =============================================================================
# STATE
# =============================================================================

## Current game time in hours (0-24)
var current_time: float = 8.0

## Starting time for this run
var start_time: float = 8.0

## Real time elapsed since run start
var real_time_elapsed: float = 0.0

## Is time paused
var is_paused: bool = false

## Current time period
var current_period: TimePeriod = TimePeriod.MORNING

## Previous hour (for hour change detection)
var previous_hour: int = 8

## Current time scale multiplier
var current_scale_multiplier: float = 1.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_update_period()
	ServiceLocator.register_service("TimeService", self)
	print("[TimeService] Initialized at %.1f:00" % current_time)


## Initialize time for a new run
func initialize_run(start_hour: float, day: int = 180) -> void:
	start_time = start_hour
	current_time = start_hour
	day_of_year = day
	real_time_elapsed = 0.0
	previous_hour = int(start_hour)
	_update_period()

	# Calculate actual sunrise/sunset based on latitude and day
	_calculate_sun_times()


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if is_paused:
		return

	# Update real time
	real_time_elapsed += delta

	# Calculate game time
	var time_delta := delta * time_scale * current_scale_multiplier * 60.0  # Convert to hours
	current_time += time_delta

	# Wrap around midnight
	if current_time >= 24.0:
		current_time -= 24.0
		day_of_year += 1
		_calculate_sun_times()

	# Emit updates
	time_updated.emit(current_time)

	# Check hour change
	var current_hour := int(current_time)
	if current_hour != previous_hour:
		previous_hour = current_hour
		hour_changed.emit(current_hour)

	# Check period change
	_check_period_change()


func _check_period_change() -> void:
	var new_period := _calculate_period()
	if new_period != current_period:
		var old_period := current_period
		current_period = new_period
		time_of_day_changed.emit(new_period)

		# Emit specific events
		match new_period:
			TimePeriod.DAWN:
				dawn_approaching.emit()
			TimePeriod.MORNING:
				sunrise.emit()
				EventBus.time_milestone.emit(current_time, "sunrise")
			TimePeriod.GOLDEN_HOUR:
				golden_hour_started.emit()
				EventBus.time_milestone.emit(current_time, "golden_hour")
			TimePeriod.DUSK:
				sunset.emit()
				blue_hour_started.emit()
				EventBus.time_milestone.emit(current_time, "sunset")
			TimePeriod.NIGHT:
				night_fallen.emit()
				EventBus.time_milestone.emit(current_time, "night")


func _calculate_period() -> TimePeriod:
	if current_time < dawn_start:
		return TimePeriod.NIGHT
	elif current_time < morning_start:
		return TimePeriod.DAWN
	elif current_time < midday_start:
		return TimePeriod.MORNING
	elif current_time < afternoon_start:
		return TimePeriod.MIDDAY
	elif current_time < golden_hour_start:
		return TimePeriod.AFTERNOON
	elif current_time < sunset_time:
		return TimePeriod.GOLDEN_HOUR
	elif current_time < dusk_end:
		return TimePeriod.DUSK
	else:
		return TimePeriod.EVENING


func _update_period() -> void:
	current_period = _calculate_period()


func _calculate_sun_times() -> void:
	# Simplified sun time calculation based on latitude and day of year
	# More accurate would use actual astronomical formulas

	# Day length variation (hours from 12)
	var day_angle := (day_of_year - 172.0) / 365.0 * TAU  # 172 = summer solstice
	var day_length_variation := 4.0 * sin(day_angle) * (latitude / 45.0)

	# Base 12 hour day, adjusted
	var half_day := 6.0 + day_length_variation / 2.0

	sunrise_time = 12.0 - half_day
	sunset_time = 12.0 + half_day

	# Adjust other times relative to sunrise/sunset
	dawn_start = sunrise_time - 1.0
	morning_start = sunrise_time + 0.5
	golden_hour_start = sunset_time - 1.5
	dusk_end = sunset_time + 1.5


# =============================================================================
# SUN CALCULATIONS
# =============================================================================

## Get sun position as angles (azimuth, elevation)
func get_sun_position() -> Vector2:
	# Calculate hour angle
	var hour_angle := (current_time - 12.0) * 15.0  # 15 degrees per hour

	# Declination angle (seasonal variation)
	var day_angle := (day_of_year - 172.0) / 365.0 * TAU
	var declination := 23.45 * sin(day_angle)

	# Convert to radians
	var lat_rad := deg_to_rad(latitude)
	var dec_rad := deg_to_rad(declination)
	var hour_rad := deg_to_rad(hour_angle)

	# Calculate elevation angle
	var sin_elevation := sin(lat_rad) * sin(dec_rad) + cos(lat_rad) * cos(dec_rad) * cos(hour_rad)
	var elevation := rad_to_deg(asin(clampf(sin_elevation, -1.0, 1.0)))

	# Calculate azimuth
	var cos_azimuth := (sin(dec_rad) - sin(lat_rad) * sin_elevation) / (cos(lat_rad) * cos(deg_to_rad(elevation)))
	var azimuth := rad_to_deg(acos(clampf(cos_azimuth, -1.0, 1.0)))
	if hour_angle > 0:
		azimuth = 360.0 - azimuth

	return Vector2(azimuth, elevation)


## Get sun direction vector (for lighting)
func get_sun_direction() -> Vector3:
	var sun_pos := get_sun_position()
	var azimuth_rad := deg_to_rad(sun_pos.x)
	var elevation_rad := deg_to_rad(sun_pos.y)

	return Vector3(
		cos(elevation_rad) * sin(azimuth_rad),
		sin(elevation_rad),
		cos(elevation_rad) * cos(azimuth_rad)
	).normalized()


## Get light intensity (0-1)
func get_light_intensity() -> float:
	var sun_pos := get_sun_position()
	var elevation := sun_pos.y

	if elevation < -6.0:
		# Civil twilight ended
		return 0.05
	elif elevation < 0.0:
		# Twilight
		return 0.05 + (elevation + 6.0) / 6.0 * 0.2
	elif elevation < 10.0:
		# Low sun
		return 0.25 + elevation / 10.0 * 0.25
	else:
		# Full daylight
		return 0.5 + minf(elevation - 10.0, 40.0) / 40.0 * 0.5


## Get shadow length multiplier (1 = same as object height)
func get_shadow_length() -> float:
	var sun_pos := get_sun_position()
	var elevation := sun_pos.y

	if elevation <= 0:
		return 100.0  # Extremely long (essentially infinite)

	return 1.0 / tan(deg_to_rad(elevation))


## Get light color temperature for time of day
func get_light_color() -> Color:
	var sun_pos := get_sun_position()
	var elevation := sun_pos.y

	if elevation < -6.0:
		# Night
		return Color(0.1, 0.1, 0.2)
	elif elevation < 0.0:
		# Blue hour
		return Color(0.3, 0.4, 0.7)
	elif elevation < 10.0:
		# Golden hour
		var t := elevation / 10.0
		return Color(1.0, 0.8 + t * 0.15, 0.5 + t * 0.4)
	else:
		# Daylight
		return Color(1.0, 0.98, 0.95)


# =============================================================================
# TIME CONTROL
# =============================================================================

## Pause time
func pause() -> void:
	is_paused = true


## Resume time
func resume() -> void:
	is_paused = false


## Set time scale multiplier (for dramatic slow-mo or fast forward)
func set_scale_multiplier(multiplier: float) -> void:
	current_scale_multiplier = clampf(multiplier, 0.1, 10.0)


## Reset to normal time scale
func reset_scale() -> void:
	current_scale_multiplier = 1.0


## Add time (for activities that take time)
func add_time(minutes: float) -> void:
	current_time += minutes / 60.0
	if current_time >= 24.0:
		current_time -= 24.0
		day_of_year += 1


# =============================================================================
# QUERIES
# =============================================================================

## Get current time as formatted string
func get_time_string() -> String:
	var hours := int(current_time)
	var minutes := int((current_time - hours) * 60)
	return "%02d:%02d" % [hours, minutes]


## Get time until sunset (hours)
func get_time_until_sunset() -> float:
	if current_time > sunset_time:
		return 24.0 - current_time + sunset_time
	return sunset_time - current_time


## Get time until night (hours)
func get_time_until_night() -> float:
	if current_time > dusk_end:
		return 24.0 - current_time + dawn_start
	return dusk_end - current_time


## Check if it's dark
func is_dark() -> bool:
	return current_period == TimePeriod.NIGHT or current_period == TimePeriod.EVENING


## Check if visibility is reduced
func is_low_visibility() -> bool:
	return get_light_intensity() < 0.3


## Get current period name
func get_period_name() -> String:
	return TimePeriod.keys()[current_period]


## Get elapsed real time (seconds)
func get_real_time_elapsed() -> float:
	return real_time_elapsed


## Get elapsed game time (hours)
func get_game_time_elapsed() -> float:
	var elapsed := current_time - start_time
	if elapsed < 0:
		elapsed += 24.0
	return elapsed


## Get visibility range based on light
func get_visibility_range() -> float:
	var base := 1000.0  # Full daylight visibility
	return base * get_light_intensity()
