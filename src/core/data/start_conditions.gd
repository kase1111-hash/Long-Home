class_name StartConditions
extends Resource
## Represents all pre-determined conditions at the start of a descent
## These are the player's choices that determine difficulty
##
## The player makes two of them at the hut (planning screen): how the climb
## went (CLIMBS) and which weather window to go in (WEATHER_WINDOWS). Neither
## is a difficulty setting: a climb trades daylight against tired legs, and a
## harder weather window counts for more in the logbook (RouteScorer).
##   var conditions := StartConditions.create_for_day("fast", "front")

# =============================================================================
# THE DAY
# =============================================================================

## How the climb went: when you stand on top, and in what shape. Every hour
## saved on the way up is paid for in the legs.
##   time_of_day: hour on the summit; fatigue, hydration: 0-1 (BodyState)
const CLIMBS: Array[Dictionary] = [
	{
		"id": "fast",
		"name": "Pushed hard",
		"summary": "Legs heavy and water low, with the whole day ahead.",
		"time_of_day": 10.0,
		"fatigue": 0.45,
		"hydration": 0.55,
	},
	{
		"id": "steady",
		"name": "Steady",
		"summary": "Some of the climb in your legs, half the day left.",
		"time_of_day": 12.0,
		"fatigue": 0.3,
		"hydration": 0.7,
	},
	{
		"id": "slow",
		"name": "Slow, with rests",
		"summary": "Fresh and watered, and the afternoon already going.",
		"time_of_day": 14.5,
		"fatigue": 0.15,
		"hydration": 0.85,
	},
]

## The weather window to go in: what the sky is doing on the summit and how
## likely it is to hold (WeatherService plays the rest of the day out from it).
##   stability: 0-1, the chance each stretch of weather holds
##   score: what a route finished in this window counts for (RouteScorer)
const WEATHER_WINDOWS: Array[Dictionary] = [
	{
		"id": "settled",
		"name": "Settled",
		"summary": "Clear, light wind. Likely to hold all day.",
		"weather": GameEnums.WeatherState.CLEAR,
		"wind": GameEnums.WindStrength.LIGHT,
		"stability": 0.9,
		"score": 1.0,
	},
	{
		"id": "changeable",
		"name": "Changeable",
		"summary": "Broken cloud, a moderate wind. It may thicken through the afternoon.",
		"weather": GameEnums.WeatherState.PARTLY_CLOUDY,
		"wind": GameEnums.WindStrength.MODERATE,
		"stability": 0.6,
		"score": 1.05,
	},
	{
		"id": "front",
		"name": "Front coming in",
		"summary": "Cloud building, the wind rising. Snow and poor visibility are hours away, not days.",
		"weather": GameEnums.WeatherState.CLOUDY,
		"wind": GameEnums.WindStrength.MODERATE,
		"stability": 0.3,
		"score": 1.15,
	},
	{
		"id": "storm",
		"name": "Storm day",
		"summary": "Snowing already, in a strong wind. It may close in to a whiteout.",
		"weather": GameEnums.WeatherState.DETERIORATING,
		"wind": GameEnums.WindStrength.STRONG,
		"stability": 0.12,
		"score": 1.3,
	},
]

const DEFAULT_CLIMB := "steady"
const DEFAULT_WEATHER := "changeable"

## The climb and weather window chosen for this day ("": conditions built by
## hand, as tests and tools do)
@export var climb_id: String = ""
@export var weather_id: String = ""

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

## Descent only, or the full route (base camp to summit and back)
@export var route_mode: GameEnums.RouteMode = GameEnums.RouteMode.DESCENT

## Known routes from previous descents
@export var known_routes: Array[PackedVector3Array] = []

## Known hazard locations
@export var known_hazards: Array[Vector3] = []

## The day's snowpack and avalanche bulletin (AvalancheService). null runs
## without avalanches (tests and tools that build their own conditions)
var avalanche: AvalancheConditions = null

# =============================================================================
# INITIALIZATION
# =============================================================================

func _init() -> void:
	if body_state == null:
		body_state = BodyState.new()
	if gear_state == null:
		gear_state = GearState.create_standard_loadout()


## The day a player chose at the hut: a climb (CLIMBS) and a weather window
## (WEATHER_WINDOWS), by id. Unknown ids give the defaults.
static func create_for_day(climb: String = DEFAULT_CLIMB, window: String = DEFAULT_WEATHER) -> StartConditions:
	var conditions := StartConditions.new()
	conditions.apply_climb(climb)
	conditions.apply_weather_window(window)
	return conditions


## A climb by id (the default climb for an unknown id)
static func climb_option(id: String) -> Dictionary:
	return _option(CLIMBS, id, DEFAULT_CLIMB)


## A weather window by id (the default window for an unknown id)
static func weather_option(id: String) -> Dictionary:
	return _option(WEATHER_WINDOWS, id, DEFAULT_WEATHER)


static func _option(options: Array[Dictionary], id: String, fallback: String) -> Dictionary:
	var chosen: Dictionary = {}
	for option in options:
		if option["id"] == id:
			return option
		if option["id"] == fallback:
			chosen = option
	return chosen


## Arrive on the summit the way this climb went: the hour, the daylight left
## and the state of the body
func apply_climb(id: String) -> void:
	var option := climb_option(id)
	climb_id = option["id"]
	time_of_day = option["time_of_day"]
	daylight_remaining = maxf(0.0, calculate_sunset() - time_of_day)
	if body_state != null:
		body_state.fatigue = option["fatigue"]
		body_state.hydration = option["hydration"]


## Go in this weather window: the sky and wind at the start, and how settled
func apply_weather_window(id: String) -> void:
	var option := weather_option(id)
	weather_id = option["id"]
	weather = option["weather"]
	wind_strength = option["wind"]
	weather_stability = option["stability"]


## What a route finished on this day counts for in the logbook (1 = a
## settled day; conditions built by hand count as that)
func get_weather_score_factor() -> float:
	if weather_id.is_empty():
		return 1.0
	return float(weather_option(weather_id)["score"])


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


## Shape the day for a route mode: a full route leaves base camp fresh at an
## alpine start (05:00); a descent starts on the summit after the climb
func apply_route_mode(mode: GameEnums.RouteMode) -> void:
	route_mode = mode
	if mode == GameEnums.RouteMode.FULL_ROUTE:
		# The climb is still to do: how it goes is up to the player now
		climb_id = ""
		time_of_day = 5.0
		daylight_remaining = 13.0
		if body_state != null:
			body_state.fatigue = 0.05
			body_state.hydration = 1.0


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
	copy.route_mode = route_mode
	copy.climb_id = climb_id
	copy.weather_id = weather_id
	copy.known_routes = known_routes.duplicate()
	copy.known_hazards = known_hazards.duplicate()
	copy.body_state = body_state.duplicate_state()
	copy.gear_state = gear_state.duplicate_state()
	copy.avalanche = avalanche  # The day itself is shared, not copied
	return copy


## These conditions as plain data, for a suspended run's save file. The
## day's snowpack is kept as the seed and elevation range it was drawn from
## (AvalancheConditions.generate gives the same day back).
func to_save() -> Dictionary:
	var data := {
		"time_of_day": time_of_day,
		"daylight_remaining": daylight_remaining,
		"latitude": latitude,
		"day_of_year": day_of_year,
		"weather": int(weather),
		"weather_stability": weather_stability,
		"wind_strength": int(wind_strength),
		"wind_direction": wind_direction,
		"temperature": temperature,
		"mountain_id": mountain_id,
		"knowledge_level": int(knowledge_level),
		"route_mode": int(route_mode),
		"climb_id": climb_id,
		"weather_id": weather_id,
		"known_routes": known_routes.duplicate(),
		"known_hazards": known_hazards.duplicate(),
		"body_state": body_state.to_save(),
		"gear_state": gear_state.to_save(),
	}
	if avalanche != null:
		data["avalanche"] = {"seed": avalanche.seed, "elevation_range": avalanche.elevation_range}
	return data


## Conditions from to_save() data. The snowpack is not rebuilt here (it
## needs the mountain): see avalanche_from_save().
static func from_save(data: Dictionary) -> StartConditions:
	var conditions := StartConditions.new()
	conditions.time_of_day = clampf(float(data.get("time_of_day", conditions.time_of_day)), 0.0, 24.0)
	conditions.daylight_remaining = maxf(float(data.get("daylight_remaining", conditions.daylight_remaining)), 0.0)
	conditions.latitude = clampf(float(data.get("latitude", conditions.latitude)), -90.0, 90.0)
	conditions.day_of_year = clampi(int(data.get("day_of_year", conditions.day_of_year)), 1, 365)
	conditions.weather = _enum_value(data.get("weather"), GameEnums.WeatherState.size(), conditions.weather) as GameEnums.WeatherState
	conditions.weather_stability = clampf(float(data.get("weather_stability", conditions.weather_stability)), 0.0, 1.0)
	conditions.wind_strength = _enum_value(data.get("wind_strength"), GameEnums.WindStrength.size(), conditions.wind_strength) as GameEnums.WindStrength
	conditions.wind_direction = fposmod(float(data.get("wind_direction", conditions.wind_direction)), 360.0)
	conditions.temperature = float(data.get("temperature", conditions.temperature))
	conditions.mountain_id = str(data.get("mountain_id", ""))
	conditions.knowledge_level = _enum_value(data.get("knowledge_level"), GameEnums.KnowledgeLevel.size(), conditions.knowledge_level) as GameEnums.KnowledgeLevel
	conditions.route_mode = _enum_value(data.get("route_mode"), GameEnums.RouteMode.size(), conditions.route_mode) as GameEnums.RouteMode
	conditions.climb_id = str(data.get("climb_id", ""))
	conditions.weather_id = str(data.get("weather_id", ""))
	var routes: Variant = data.get("known_routes")
	if routes is Array:
		for route in routes:
			if route is PackedVector3Array:
				conditions.known_routes.append(route)
	var hazards: Variant = data.get("known_hazards")
	if hazards is Array:
		for hazard in hazards:
			if hazard is Vector3:
				conditions.known_hazards.append(hazard)
	if data.get("body_state") is Dictionary:
		conditions.body_state = BodyState.from_save(data["body_state"])
	if data.get("gear_state") is Dictionary:
		conditions.gear_state = GearState.from_save(data["gear_state"])
	return conditions


## The day's snowpack named in to_save() data, drawn again for a mountain
## (null when the run had none)
static func avalanche_from_save(data: Dictionary, mountain: MountainDatabase.MountainData) -> AvalancheConditions:
	var saved: Variant = data.get("avalanche")
	if not (saved is Dictionary) or not (saved.get("elevation_range") is Vector2):
		return null
	var range: Vector2 = saved["elevation_range"]
	return AvalancheConditions.generate(mountain, str(data.get("mountain_id", "")), int(saved.get("seed", 0)), range.x, range.y)


## A saved enum value, or the fallback when it is not one
static func _enum_value(value: Variant, count: int, fallback: int) -> int:
	if not (value is int or value is float):
		return fallback
	var number := int(value)
	return number if number >= 0 and number < count else fallback


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
