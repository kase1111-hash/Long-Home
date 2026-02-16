class_name StartConditions
extends Resource
## Represents all pre-determined conditions at the start of a descent
## These are the player's choices that determine difficulty

# =============================================================================
# TIME CONDITIONS
# =============================================================================

## Time of day at summit (0-24 hours)
@export_range(0.0, 24.0) var time_of_day: float = 10.0

## Estimated daylight remaining in hours
@export var daylight_remaining: float = 8.0

## Latitude for sun calculations (degrees, 45 = Alps, 28 = Himalayas)
@export_range(-90.0, 90.0) var latitude: float = 45.0

## Day of year (1-365, affects sunrise/sunset times)
@export_range(1, 365) var day_of_year: int = 180

# =============================================================================
# WEATHER CONDITIONS
# =============================================================================

## Current weather state
@export var weather: GameEnums.WeatherState = GameEnums.WeatherState.CLEAR

## Weather stability (how likely it is to deteriorate)
@export_range(0.0, 1.0) var weather_stability: float = 0.8

## Current wind strength
@export var wind_strength: GameEnums.WindStrength = GameEnums.WindStrength.LIGHT

## Wind direction (degrees, 0 = north)
@export_range(0.0, 360.0) var wind_direction: float = 270.0

## Current temperature at summit (Celsius)
@export var temperature: float = -10.0

# =============================================================================
# PHYSICAL CONDITIONS
# =============================================================================

## Starting body state
@export var body_state: BodyState

## Starting gear loadout
@export var gear_state: GearState

# =============================================================================
# KNOWLEDGE CONDITIONS
# =============================================================================

## Mountain ID
@export var mountain_id: String = ""

## Player's familiarity with this mountain
@export var knowledge_level: GameEnums.KnowledgeLevel = GameEnums.KnowledgeLevel.UNKNOWN

## Known routes from previous descents
@export var known_routes: Array[PackedVector3Array] = []

## Known hazard locations
@export var known_hazards: Array[Vector3] = []

# =============================================================================
# INITIALIZATION
# =============================================================================

func _init() -> void:
	if body_state == null:
		body_state = BodyState.new()
	if gear_state == null:
		gear_state = GearState.create_standard_loadout()


## Create default/easy conditions
static func create_easy() -> StartConditions:
	var conditions := StartConditions.new()

	# Favorable time
	conditions.time_of_day = 9.0
	conditions.daylight_remaining = 10.0

	# Good weather
	conditions.weather = GameEnums.WeatherState.CLEAR
	conditions.weather_stability = 0.9
	conditions.wind_strength = GameEnums.WindStrength.LIGHT
	conditions.temperature = -5.0

	# Fresh body
	conditions.body_state = BodyState.new()
	conditions.body_state.fatigue = 0.1
	conditions.body_state.hydration = 0.9

	# Full gear
	conditions.gear_state = GearState.create_standard_loadout()

	return conditions


## Create moderate conditions
static func create_moderate() -> StartConditions:
	var conditions := StartConditions.new()

	# Midday start
	conditions.time_of_day = 12.0
	conditions.daylight_remaining = 6.0

	# Variable weather
	conditions.weather = GameEnums.WeatherState.PARTLY_CLOUDY
	conditions.weather_stability = 0.6
	conditions.wind_strength = GameEnums.WindStrength.MODERATE
	conditions.temperature = -12.0

	# Some fatigue from climb
	conditions.body_state = BodyState.new()
	conditions.body_state.fatigue = 0.3
	conditions.body_state.hydration = 0.7

	# Standard gear
	conditions.gear_state = GearState.create_standard_loadout()

	return conditions


## Create hard conditions
static func create_hard() -> StartConditions:
	var conditions := StartConditions.new()

	# Late start
	conditions.time_of_day = 14.0
	conditions.daylight_remaining = 4.0

	# Deteriorating weather
	conditions.weather = GameEnums.WeatherState.DETERIORATING
	conditions.weather_stability = 0.3
	conditions.wind_strength = GameEnums.WindStrength.STRONG
	conditions.temperature = -18.0

	# Fatigued from hard climb
	conditions.body_state = BodyState.new()
	conditions.body_state.fatigue = 0.5
	conditions.body_state.hydration = 0.5
	conditions.body_state.cold_exposure = 0.2

	# Standard gear, some wear
	conditions.gear_state = GearState.create_standard_loadout()
	conditions.gear_state.damage_item(GameEnums.GearType.ROPE, 0.1)

	return conditions


## Create extreme conditions (deceptively lethal)
static func create_extreme() -> StartConditions:
	var conditions := StartConditions.new()

	# Very late, minimal light
	conditions.time_of_day = 16.0
	conditions.daylight_remaining = 2.0

	# Storm incoming
	conditions.weather = GameEnums.WeatherState.STORM
	conditions.weather_stability = 0.1
	conditions.wind_strength = GameEnums.WindStrength.SEVERE
	conditions.temperature = -25.0

	# Exhausted
	conditions.body_state = BodyState.new()
	conditions.body_state.fatigue = 0.6
	conditions.body_state.hydration = 0.4
	conditions.body_state.cold_exposure = 0.4

	# Light gear (faster but less margin)
	conditions.gear_state = GearState.create_light_loadout()

	return conditions


# =============================================================================
# DIFFICULTY ASSESSMENT
# =============================================================================

## Calculate overall difficulty score (0-1, higher = harder)
func get_difficulty_score() -> float:
	var score := 0.0

	# Time pressure (less daylight = harder)
	score += (1.0 - clampf(daylight_remaining / 10.0, 0.0, 1.0)) * 0.2

	# Weather difficulty
	score += _get_weather_difficulty() * 0.25

	# Physical condition
	score += body_state.fatigue * 0.15
	score += (1.0 - body_state.hydration) * 0.1
	score += body_state.cold_exposure * 0.1

	# Gear limitations
	if not gear_state.has_item(GameEnums.GearType.ROPE):
		score += 0.15
	if not gear_state.has_crampons():
		score += 0.1

	# Knowledge bonus (knowing the mountain helps)
	match knowledge_level:
		GameEnums.KnowledgeLevel.MASTERED:
			score -= 0.1
		GameEnums.KnowledgeLevel.EXPERIENCED:
			score -= 0.05
		GameEnums.KnowledgeLevel.UNKNOWN:
			score += 0.05

	return clampf(score, 0.0, 1.0)


func _get_weather_difficulty() -> float:
	var difficulty := 0.0

	match weather:
		GameEnums.WeatherState.CLEAR:
			difficulty = 0.0
		GameEnums.WeatherState.PARTLY_CLOUDY:
			difficulty = 0.1
		GameEnums.WeatherState.OVERCAST:
			difficulty = 0.15
		GameEnums.WeatherState.CLOUDY:
			difficulty = 0.2
		GameEnums.WeatherState.SNOW:
			difficulty = 0.4
		GameEnums.WeatherState.DETERIORATING:
			difficulty = 0.5
		GameEnums.WeatherState.STORM:
			difficulty = 0.8
		GameEnums.WeatherState.WHITEOUT:
			difficulty = 1.0
		GameEnums.WeatherState.CLEARING:
			difficulty = 0.15

	# Wind adds difficulty
	match wind_strength:
		GameEnums.WindStrength.MODERATE:
			difficulty += 0.1
		GameEnums.WindStrength.STRONG:
			difficulty += 0.25
		GameEnums.WindStrength.GALE:
			difficulty += 0.35
		GameEnums.WindStrength.SEVERE:
			difficulty += 0.4

	# Instability adds risk
	difficulty += (1.0 - weather_stability) * 0.2

	return clampf(difficulty, 0.0, 1.0)


## Get a text description of conditions
func get_conditions_summary() -> String:
	var lines: Array[String] = []

	# Time
	var hour := int(time_of_day)
	var minute := int((time_of_day - hour) * 60)
	lines.append("Time: %02d:%02d, ~%.1f hours of light remaining" % [hour, minute, daylight_remaining])

	# Weather
	var weather_text := ""
	match weather:
		GameEnums.WeatherState.CLEAR:
			weather_text = "Clear skies"
		GameEnums.WeatherState.PARTLY_CLOUDY:
			weather_text = "Partly cloudy"
		GameEnums.WeatherState.CLOUDY:
			weather_text = "Overcast"
		GameEnums.WeatherState.DETERIORATING:
			weather_text = "Weather deteriorating"
		GameEnums.WeatherState.STORM:
			weather_text = "Storm conditions"
		GameEnums.WeatherState.WHITEOUT:
			weather_text = "Whiteout"
	lines.append("Weather: %s, %.0f°C" % [weather_text, temperature])

	# Physical
	if body_state.fatigue > 0.5:
		lines.append("Physical: Fatigued from the climb")
	elif body_state.fatigue > 0.2:
		lines.append("Physical: Somewhat tired")
	else:
		lines.append("Physical: Fresh")

	# Gear
	lines.append("Gear: %.1f kg total" % gear_state.total_weight)

	return "\n".join(lines)


## Create a copy of these conditions
func duplicate_conditions() -> StartConditions:
	var copy := StartConditions.new()
	copy.time_of_day = time_of_day
	copy.daylight_remaining = daylight_remaining
	copy.latitude = latitude
	copy.day_of_year = day_of_year
	copy.weather = weather
	copy.weather_stability = weather_stability
	copy.wind_strength = wind_strength
	copy.wind_direction = wind_direction
	copy.temperature = temperature
	copy.mountain_id = mountain_id
	copy.knowledge_level = knowledge_level
	copy.known_routes = known_routes.duplicate()
	copy.known_hazards = known_hazards.duplicate()
	copy.body_state = body_state.duplicate_state()
	copy.gear_state = gear_state.duplicate_state()
	return copy


# =============================================================================
# SUN CALCULATIONS
# =============================================================================

## Calculate sunrise time based on latitude and day of year
func calculate_sunrise() -> float:
	var sun_times := _calculate_sun_times()
	return sun_times.x


## Calculate sunset time based on latitude and day of year
func calculate_sunset() -> float:
	var sun_times := _calculate_sun_times()
	return sun_times.y


## Calculate both sunrise and sunset times
## Returns Vector2(sunrise, sunset) in hours
func _calculate_sun_times() -> Vector2:
	# Day length variation based on day of year and latitude
	# Day 172 is approximately summer solstice in northern hemisphere
	var day_angle := (day_of_year - 172.0) / 365.0 * TAU

	# Day length variation in hours (±4 hours at 45° latitude)
	# Scale by latitude (higher latitudes = more variation)
	var day_length_variation := 4.0 * sin(day_angle) * (latitude / 45.0)

	# Base 12-hour day, adjusted by variation
	var half_day := 6.0 + day_length_variation / 2.0

	var sunrise := 12.0 - half_day
	var sunset := 12.0 + half_day

	# Clamp to valid range
	sunrise = clampf(sunrise, 0.0, 12.0)
	sunset = clampf(sunset, 12.0, 24.0)

	return Vector2(sunrise, sunset)
