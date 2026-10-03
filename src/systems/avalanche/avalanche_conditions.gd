class_name AvalancheConditions
extends RefCounted
## The day's snowpack on one mountain, and the avalanche bulletin written
## from it.
##
## A day is drawn from the mountain's climate (how stormy, how windy, how
## cold): the snow of the last three days, the wind that moved it, whether a
## persistent weak layer lies buried, and how warm the afternoon will be.
## From that come the avalanche problems a forecaster would name (storm slab,
## wind slab, persistent slab, loose dry, wet loose, wet slab), each with the
## aspects and elevations it lives on, how likely a release is and how big it
## would be, and the danger rating for each elevation band on the five-level
## scale used by European and North American services:
##
##   1 Low  2 Moderate  3 Considerable  4 High  5 Very High
##
## The danger follows the EAWS matrix idea: a likelier release, or a bigger
## one, raises the level. Persistent slabs are rated up half a step because a
## low chance of a big, deep slab is what kills experienced parties.
##
## AvalancheField turns this into instability on the terrain; AvalancheSystem
## releases what the snowpack cannot hold. Nothing is labelled on the
## mountain: the bulletin is read at the hut.

# =============================================================================
# DEFINITIONS
# =============================================================================

enum ProblemType { STORM_SLAB, WIND_SLAB, PERSISTENT_SLAB, LOOSE_DRY, WET_LOOSE, WET_SLAB }

const PROBLEM_NAMES := {
	ProblemType.STORM_SLAB: "Storm slab",
	ProblemType.WIND_SLAB: "Wind slab",
	ProblemType.PERSISTENT_SLAB: "Persistent slab",
	ProblemType.LOOSE_DRY: "Loose dry",
	ProblemType.WET_LOOSE: "Wet loose",
	ProblemType.WET_SLAB: "Wet slab",
}

const LEVEL_NAMES: Array[String] = ["", "Low", "Moderate", "Considerable", "High", "Very High"]

## Danger level colours, as the bulletins print them
const LEVEL_COLORS: Array[Color] = [
	Color(0.5, 0.5, 0.5),
	Color(0.8, 1.0, 0.4),     # Low: green
	Color(1.0, 1.0, 0.0),     # Moderate: yellow
	Color(1.0, 0.6, 0.0),     # Considerable: orange
	Color(1.0, 0.0, 0.0),     # High: red
	Color(0.12, 0.08, 0.08),  # Very High: black (red/black chequer in print)
]

## Compass sectors, clockwise from north; a problem's aspects are a bit mask
const ASPECT_NAMES: Array[String] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
const ALL_ASPECTS := 0xFF
## Shady half (NW, N, NE, E): where cold snow and buried weak layers last
const SHADED_ASPECTS := 0b10000111
## Sunny aspects (E, SE, S, SW, W): where the afternoon sun wets the snow
const SUNNY_ASPECTS := 0b01111100

## Elevation bands, low to high; a problem's bands are a bit mask
enum Band { LOWER, MIDDLE, UPPER }
const BAND_NAMES: Array[String] = ["Lower mountain", "Middle mountain", "Upper mountain"]
const ALL_BANDS := 0b111

## Afternoon air temperature model, the same numbers as TemperatureSystem
## (sea-level base + afternoon swing, lapse rate per km), so the forecast
## freezing level is the one the climber meets
const SEA_LEVEL_TEMPERATURE := 15.0
const AFTERNOON_SWING := 8.0
const LAPSE_RATE := 6.5

## Travel advice by danger level
const ADVICE: Array[String] = [
	"",
	"Generally safe conditions. Watch for isolated unstable snow on extremely steep slopes and in terrain traps.",
	"Heightened conditions on specific terrain. Identify the features of concern and evaluate the snow and terrain carefully.",
	"Dangerous conditions. Careful snowpack evaluation, cautious route-finding and conservative decisions are essential.",
	"Very dangerous conditions. Travel in avalanche terrain is not recommended.",
	"Extraordinary conditions. Avoid all avalanche terrain, including runout zones.",
]


class AvalancheProblem:
	var type: int = ProblemType.STORM_SLAB
	## Aspects affected (bit i = ASPECT_NAMES[i])
	var aspects: int = ALL_ASPECTS
	## Elevation bands affected (bit i = Band i)
	var bands: int = ALL_BANDS
	## Chance a slope of this kind releases under a person (0-1)
	var likelihood: float = 0.3
	## Destructive size 1 (harmless) to 4 (destroys a building)
	var size: int = 2
	## Thickness of the slab, or of the loose snow that runs (metres)
	var depth: float = 0.4
	## Hours of the day the problem is active (wet snow: afternoons)
	var active_hours: Vector2 = Vector2(0.0, 24.0)
	## Remote triggering possible (a collapse can release a slope nearby)
	var remote: bool = false

	func covers(aspect: int, band: int) -> bool:
		return (aspects >> aspect) & 1 == 1 and (bands >> band) & 1 == 1

	func is_slab() -> bool:
		return type == ProblemType.STORM_SLAB or type == ProblemType.WIND_SLAB \
			or type == ProblemType.PERSISTENT_SLAB or type == ProblemType.WET_SLAB

	func is_wet() -> bool:
		return type == ProblemType.WET_LOOSE or type == ProblemType.WET_SLAB

	func get_name() -> String:
		return AvalancheConditions.PROBLEM_NAMES.get(type, "Avalanche")

	func likelihood_word() -> String:
		return AvalancheConditions.likelihood_name(likelihood)

	func size_word() -> String:
		return AvalancheConditions.size_name(size)

	func aspect_text() -> String:
		return AvalancheConditions.aspect_list(aspects)


# =============================================================================
# STATE
# =============================================================================

var seed: int = 0
var mountain_id: String = ""

## Snow of the last 72 hours (cm)
var new_snow_cm: float = 0.0
## Wind during the loading (km/h) and the bearing it blew from (degrees)
var wind_kmh: float = 10.0
var wind_from: float = 270.0
## A buried persistent weak layer
var weak_layer: bool = false
var weak_layer_depth: float = 0.0
var weak_layer_kind: String = ""
## Forecast afternoon freezing level (metres); the day runs this much
## warmer or colder than a clear standard day (degrees, TemperatureSystem
## takes it for the run)
var freezing_level: float = 3500.0
var temperature_offset: float = 0.0
## Elevation band boundaries (lower/middle, middle/upper) and the mountain's range
var band_edges: Vector2 = Vector2.ZERO
var elevation_range: Vector2 = Vector2.ZERO

## Danger per band (index Band), 1-5
var danger: PackedInt32Array = PackedInt32Array([1, 1, 1])
var problems: Array[AvalancheProblem] = []
var headline: String = ""


# =============================================================================
# GENERATION
# =============================================================================

## Draw a day on a mountain. low/high: the elevation range of its terrain.
## The same seed gives the same day.
static func generate(mountain: MountainDatabase.MountainData, id: String, day_seed: int, low: float, high: float) -> AvalancheConditions:
	var c := AvalancheConditions.new()
	c.seed = day_seed
	c.mountain_id = id
	c.elevation_range = Vector2(low, high)
	var third := (high - low) / 3.0
	c.band_edges = Vector2(low + third, low + 2.0 * third)

	var volatility := 0.4
	var wind_exposure := 0.5
	var typical_temperature := -10.0
	if mountain != null:
		volatility = mountain.weather_volatility
		wind_exposure = mountain.wind_exposure
		typical_temperature = mountain.typical_temperature

	var rng := RandomNumberGenerator.new()
	rng.seed = day_seed

	# The last three days: a storm cycle (mostly modest, now and then big),
	# or a few centimetres here and there
	if rng.randf() < 0.2 + 0.3 * volatility:
		c.new_snow_cm = 15.0 + (15.0 + 55.0 * volatility) * pow(rng.randf(), 1.6)
	else:
		c.new_snow_cm = rng.randf_range(0.0, 12.0) * (0.4 if rng.randf() < 0.5 else 1.0)

	# Wind: stronger on exposed peaks; mostly from the west
	c.wind_kmh = rng.randf_range(8.0, 25.0 + 50.0 * wind_exposure)
	c.wind_from = fposmod(270.0 + rng.randf_range(-100.0, 100.0), 360.0)

	# Cold, thin continental snowpacks grow facets and keep them
	var cold := clampf((-typical_temperature - 5.0) / 20.0, 0.0, 1.0)
	c.weak_layer = rng.randf() < 0.18 + 0.45 * cold
	if c.weak_layer:
		var kinds := ["buried surface hoar", "facets above a crust", "depth hoar near the ground"]
		c.weak_layer_kind = kinds[rng.randi() % kinds.size()]
		c.weak_layer_depth = rng.randf_range(0.4, 1.1)
		if c.weak_layer_kind.begins_with("depth hoar"):
			c.weak_layer_depth = rng.randf_range(1.0, 1.6)

	# Most days are cooler than a clear standard day (cloud, a cold air mass)
	c.temperature_offset = rng.randf_range(-7.0, 2.0)
	c.freezing_level = (SEA_LEVEL_TEMPERATURE + AFTERNOON_SWING + c.temperature_offset) / LAPSE_RATE * 1000.0
	c._build_problems(rng)
	c._rate_danger()
	c._write_headline()
	return c


## Afternoon air temperature at an elevation (clear sky), as forecast
func afternoon_temperature(elevation: float) -> float:
	return SEA_LEVEL_TEMPERATURE + AFTERNOON_SWING + temperature_offset - elevation / 1000.0 * LAPSE_RATE


func _build_problems(rng: RandomNumberGenerator) -> void:
	problems.clear()
	var lower_mid := (elevation_range.x + band_edges.x) * 0.5
	var middle_mid := (band_edges.x + band_edges.y) * 0.5
	var upper_mid := (band_edges.y + elevation_range.y) * 0.5

	# Storm slab: the new snow itself, before it bonds
	if new_snow_cm >= 20.0:
		var p := AvalancheProblem.new()
		p.type = ProblemType.STORM_SLAB
		p.likelihood = clampf((new_snow_cm - 15.0) / 60.0, 0.2, 0.95)
		p.depth = new_snow_cm / 100.0 * 0.85
		p.size = 1 if new_snow_cm < 25.0 else (2 if new_snow_cm < 45.0 else (3 if new_snow_cm < 80.0 else 4))
		p.remote = new_snow_cm >= 50.0
		problems.append(p)

	# Wind slab: snow moved by the wind onto the lee side of ridges
	# (old loose snow at the surface can be moved too)
	var transportable := new_snow_cm + (5.0 if rng.randf() < 0.5 else 0.0)
	if wind_kmh >= 25.0 and transportable >= 5.0:
		var p := AvalancheProblem.new()
		p.type = ProblemType.WIND_SLAB
		var lee := fposmod(wind_from + 180.0, 360.0)
		p.aspects = aspect_mask_around(lee, 67.5)
		p.bands = (1 << Band.MIDDLE) | (1 << Band.UPPER)
		p.likelihood = clampf(0.08 + transportable / 100.0 + (wind_kmh - 25.0) / 120.0, 0.08, 0.75)
		p.depth = clampf(0.2 + transportable / 150.0 + (wind_kmh - 25.0) / 200.0, 0.2, 0.9)
		p.size = 1 if transportable < 8.0 else 2
		if transportable >= 50.0 and wind_kmh >= 50.0:
			p.size = 3
		problems.append(p)

	# Persistent slab: a weak layer under a slab, waiting
	if weak_layer:
		var p := AvalancheProblem.new()
		p.type = ProblemType.PERSISTENT_SLAB
		var deep := weak_layer_kind.begins_with("depth hoar")
		p.aspects = ALL_ASPECTS if deep else SHADED_ASPECTS
		p.bands = ALL_BANDS if deep else ((1 << Band.MIDDLE) | (1 << Band.UPPER))
		p.likelihood = clampf(0.15 + new_snow_cm / 200.0, 0.15, 0.5)
		p.depth = weak_layer_depth + new_snow_cm / 100.0 * 0.5
		p.size = 2 if p.depth < 0.7 else 3
		p.remote = true
		problems.append(p)

	# Loose dry: cold new snow sloughing off steep shady slopes
	if new_snow_cm >= 10.0 and afternoon_temperature(middle_mid) < -4.0:
		var p := AvalancheProblem.new()
		p.type = ProblemType.LOOSE_DRY
		p.aspects = SHADED_ASPECTS
		p.likelihood = clampf(0.25 + new_snow_cm / 100.0, 0.25, 0.65)
		p.depth = minf(new_snow_cm / 100.0, 0.5)
		p.size = 1
		problems.append(p)

	# Wet loose: the afternoon sun on sunny slopes, worst on new snow
	var warm_bands := 0
	if afternoon_temperature(lower_mid) > -1.0:
		warm_bands |= 1 << Band.LOWER
	if afternoon_temperature(middle_mid) > -1.0:
		warm_bands |= 1 << Band.MIDDLE
	if afternoon_temperature(upper_mid) > -0.5:
		warm_bands |= 1 << Band.UPPER
	if warm_bands != 0:
		var warmest := afternoon_temperature(lower_mid)
		var p := AvalancheProblem.new()
		p.type = ProblemType.WET_LOOSE
		p.aspects = SUNNY_ASPECTS
		p.bands = warm_bands
		p.likelihood = clampf(0.1 + warmest / 12.0 + new_snow_cm / 80.0, 0.1, 0.8)
		p.depth = clampf(0.15 + new_snow_cm / 150.0, 0.15, 0.5)
		p.size = 2 if new_snow_cm >= 20.0 else 1
		p.active_hours = Vector2(11.0, 18.0)
		problems.append(p)

		# Wet slab: melt water reaching a buried weak layer on a warm day
		if weak_layer and warmest > 3.0:
			var w := AvalancheProblem.new()
			w.type = ProblemType.WET_SLAB
			w.aspects = SUNNY_ASPECTS
			w.bands = warm_bands & ((1 << Band.LOWER) | (1 << Band.MIDDLE))
			if w.bands == 0:
				w.bands = warm_bands
			w.likelihood = clampf(0.15 + (warmest - 2.0) / 10.0, 0.15, 0.4)
			w.depth = weak_layer_depth
			w.size = 3
			w.active_hours = Vector2(12.0, 19.0)
			problems.append(w)


## Danger per band from the problems that live in it (EAWS matrix idea)
func _rate_danger() -> void:
	danger = PackedInt32Array([1, 1, 1])
	for band in range(3):
		var best := 0.0
		for p in problems:
			if (p.bands >> band) & 1 == 0:
				continue
			var score: float = float(likelihood_class(p.likelihood)) + float(SIZE_STEP[clampi(p.size, 1, 4)])
			if p.type == ProblemType.PERSISTENT_SLAB:
				score += 0.5
			# A problem on one or two aspects worries a forecaster less
			if bit_count(p.aspects) <= 2:
				score -= 0.5
			best = maxf(best, score)
		danger[band] = clampi(1 + floori(best), 1, 5)


const SIZE_STEP := [0.0, -1.0, 0.0, 0.5, 1.0]


func _write_headline() -> void:
	var top := get_max_danger()
	var problem := get_main_problem()
	if problem == null:
		headline = "Low avalanche danger. A well-bonded, settled snowpack."
		return
	var where := ""
	if danger[Band.LOWER] == top and danger[Band.MIDDLE] == top:
		where = "at all elevations"
	elif danger[Band.MIDDLE] == top:
		where = "above %s m" % _thousands(band_edges.x)
	else:
		where = "above %s m" % _thousands(band_edges.y)
	headline = "%s avalanche danger %s. %s on %s aspects." % [
		LEVEL_NAMES[top], where, problem.get_name() + "s", aspect_list(problem.aspects)
	]


# =============================================================================
# QUERIES
# =============================================================================

func get_max_danger() -> int:
	return maxi(danger[0], maxi(danger[1], danger[2]))


## Danger at an elevation (its band's rating)
func danger_at(elevation: float) -> int:
	return danger[band_of(elevation)]


func band_of(elevation: float) -> int:
	if elevation < band_edges.x:
		return Band.LOWER
	if elevation < band_edges.y:
		return Band.MIDDLE
	return Band.UPPER


## The problem that drives the danger (most likely, then biggest)
func get_main_problem() -> AvalancheProblem:
	var best: AvalancheProblem = null
	var best_score := -INF
	for p in problems:
		var score: float = float(likelihood_class(p.likelihood)) + float(SIZE_STEP[clampi(p.size, 1, 4)]) + p.likelihood * 0.1
		if p.type == ProblemType.PERSISTENT_SLAB:
			score += 0.5
		if score > best_score:
			best_score = score
			best = p
	return best


func get_advice() -> String:
	return ADVICE[get_max_danger()]


## Snowpack summary lines for the bulletin
func get_snowpack_lines() -> Array[String]:
	var lines: Array[String] = []
	if new_snow_cm >= 1.0:
		lines.append("%d cm of new snow in the last three days." % roundi(new_snow_cm))
	else:
		lines.append("No new snow in the last three days.")
	lines.append("%s winds from the %s (%d km/h)." % [wind_word(wind_kmh), compass_word(wind_from), roundi(wind_kmh)])
	if weak_layer:
		lines.append("A persistent weak layer (%s) lies about %d cm down." % [weak_layer_kind, roundi(weak_layer_depth * 100.0)])
	else:
		lines.append("The old snowpack is well bonded.")
	lines.append("Freezing level near %s m in the afternoon." % _thousands(freezing_level))
	return lines


static func likelihood_class(likelihood: float) -> int:
	if likelihood < 0.2:
		return 0
	if likelihood < 0.45:
		return 1
	if likelihood < 0.7:
		return 2
	return 3


static func likelihood_name(likelihood: float) -> String:
	return ["Unlikely", "Possible", "Likely", "Very likely"][likelihood_class(likelihood)]


static func size_name(size: int) -> String:
	match size:
		1:
			return "Small (size 1: harmless to people, except in a trap)"
		2:
			return "Large (size 2: can bury a person)"
		3:
			return "Very large (size 3: can bury a car)"
	return "Extremely large (size 4: can destroy a building)"


## Compass sector (0 = N ... 7 = NW) of a downhill direction in world xz
## (north is -z, east is +x, as on the maps)
static func aspect_of(downhill: Vector2) -> int:
	var bearing := fposmod(rad_to_deg(atan2(downhill.x, -downhill.y)), 360.0)
	return int(round(bearing / 45.0)) % 8


## Mask of the sectors whose centre lies within half_width degrees of a bearing
static func aspect_mask_around(bearing: float, half_width: float) -> int:
	var mask := 0
	for i in range(8):
		var diff := absf(fposmod(float(i) * 45.0 - bearing + 180.0, 360.0) - 180.0)
		if diff <= half_width + 0.01:
			mask |= 1 << i
	if mask == 0:
		mask = 1 << (int(round(bearing / 45.0)) % 8)
	return mask


static func aspect_list(mask: int) -> String:
	if mask & 0xFF == 0xFF:
		return "all"
	var names: Array[String] = []
	for i in range(8):
		if (mask >> i) & 1 == 1:
			names.append(ASPECT_NAMES[i])
	return ", ".join(names)


static func bit_count(mask: int) -> int:
	var n := 0
	for i in range(8):
		n += (mask >> i) & 1
	return n


static func compass_word(bearing: float) -> String:
	var words := ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
	return words[int(round(fposmod(bearing, 360.0) / 45.0)) % 8]


static func wind_word(kmh: float) -> String:
	if kmh < 15.0:
		return "Light"
	if kmh < 30.0:
		return "Moderate"
	if kmh < 50.0:
		return "Strong"
	return "Very strong"


static func _thousands(metres: float) -> String:
	var value := roundi(metres / 50.0) * 50
	if value >= 1000:
		return "%d,%03d" % [value / 1000, value % 1000]
	return str(value)
