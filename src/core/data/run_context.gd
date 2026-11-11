class_name RunContext
extends Resource
## Contains all state for a single descent run
## This is the central data object passed between systems

# =============================================================================
# IDENTIFICATION
# =============================================================================

## Unique ID for this run
@export var run_id: String = ""

## Mountain being descended
@export var mountain_id: String = ""

## Timestamp when run started (real time)
@export var start_timestamp: int = 0

# =============================================================================
# START CONDITIONS (Immutable after run begins)
# =============================================================================

## The conditions at the start of the run
@export var start_conditions: StartConditions

# =============================================================================
# CURRENT STATE (Mutable during run)
# =============================================================================

## Current player position in world space
@export var position: Vector3 = Vector3.ZERO

## Current player velocity
@export var velocity: Vector3 = Vector3.ZERO

## Current player movement state
@export var movement_state: GameEnums.PlayerMovementState = GameEnums.PlayerMovementState.STANDING

## Current body state
@export var body_state: BodyState

## Current gear state
@export var gear_state: GearState

## Current game time (hours, 0-24)
@export var current_time: float = 0.0

## Current weather state
@export var current_weather: GameEnums.WeatherState = GameEnums.WeatherState.CLEAR

## Current wind strength
@export var current_wind: GameEnums.WindStrength = GameEnums.WindStrength.CALM

## Current temperature
@export var current_temperature: float = 0.0

## Total real time elapsed in seconds
@export var real_time_elapsed: float = 0.0

## Total game time elapsed in hours
@export var game_time_elapsed: float = 0.0

## Total distance traveled in meters
@export var distance_traveled: float = 0.0

## Current elevation in meters
@export var current_elevation: float = 0.0

## Starting elevation (for progress tracking)
@export var start_elevation: float = 0.0

## Target elevation (base camp / safety)
@export var target_elevation: float = 0.0

# =============================================================================
# HISTORY (For replay and analysis)
# =============================================================================

## Path taken as list of positions (sampled)
@export var path_history: PackedVector3Array = PackedVector3Array()

## Significant decisions made during the run
@export var decisions: Array[Dictionary] = []

## Incidents that occurred (slips, falls, injuries, etc.)
@export var incidents: Array[Dictionary] = []

## Timestamps for path history (parallel array)
@export var path_timestamps: PackedFloat64Array = PackedFloat64Array()

## How each path sample was travelled (RouteMetrics.MODE_*: on foot, climbing,
## on the rope, gliding, out of control), parallel to path_history. Scoring
## grades only the ground covered under control.
@export var path_modes: PackedByteArray = PackedByteArray()

## Current travel mode (GameStateManager sets it from the player's state)
var travel_mode: int = 0

# =============================================================================
# ROUTE MODE (full route: up, then down)
# =============================================================================

## Descent only, or the full route from base camp to the summit and back
@export var route_mode: GameEnums.RouteMode = GameEnums.RouteMode.DESCENT

## Which way the climber is heading
@export var phase: GameEnums.RunPhase = GameEnums.RunPhase.DESCENT

## Full route: the summit has been reached
@export var summit_reached: bool = false

## Game hours elapsed when the summit was reached (-1 = not yet)
@export var summit_time: float = -1.0

## path_history index at the summit (-1 = not yet)
@export var summit_path_index: int = -1

## The scored result (RouteScorer.RouteScore), filled when the run ends
var route_score: RefCounted = null

## Marks a decision/incident entry already in this run's history, so the
## EventBus echo of record_decision/record_incident is not logged twice
const LOGGED_KEY := "logged"

## A single position sample further than this is a teleport (spawn, debug
## warp, test harness), not travel - it resets tracking instead of adding
## a bogus distance
const MAX_SAMPLE_STEP := 50.0

## True once update_position() has received its first real sample
var _has_position_sample: bool = false

# =============================================================================
# RUN OUTCOME
# =============================================================================

## Whether the run has ended
@export var is_complete: bool = false

## Final outcome of the run
@export var outcome: GameEnums.ResolutionType = GameEnums.ResolutionType.CLEAN_RETURN

## Position where run ended
@export var end_position: Vector3 = Vector3.ZERO

## Cause of end (if not clean return)
@export var end_cause: String = ""

# =============================================================================
# INITIALIZATION
# =============================================================================

func _init() -> void:
	run_id = _generate_run_id()
	start_timestamp = Time.get_unix_time_from_system()


static func _generate_run_id() -> String:
	return "%d_%s" % [Time.get_unix_time_from_system(), str(randi() % 10000).pad_zeros(4)]


## Initialize a new run with the given conditions
static func create_new_run(mountain: String, conditions: StartConditions) -> RunContext:
	var context := RunContext.new()
	context.mountain_id = mountain
	context.start_conditions = conditions.duplicate_conditions()

	# Copy mutable state from start conditions
	context.body_state = conditions.body_state.duplicate_state()
	context.gear_state = conditions.gear_state.duplicate_state()
	context.current_time = conditions.time_of_day
	context.current_weather = conditions.weather
	context.current_wind = conditions.wind_strength
	context.current_temperature = conditions.temperature
	context.route_mode = conditions.route_mode
	if conditions.route_mode == GameEnums.RouteMode.FULL_ROUTE:
		context.phase = GameEnums.RunPhase.ASCENT

	return context


# =============================================================================
# STATE UPDATES
# =============================================================================

## Update position and record to history.
## The first sample (and any teleport-sized jump) only anchors tracking;
## distance is accumulated between consecutive real samples.
func update_position(new_position: Vector3, new_velocity: Vector3) -> void:
	var old_position := position
	position = new_position
	velocity = new_velocity

	# Track distance
	if _has_position_sample:
		var step := old_position.distance_to(new_position)
		if step <= MAX_SAMPLE_STEP:
			distance_traveled += step
	_has_position_sample = true

	# Update elevation
	current_elevation = position.y

	# Sample path history (every ~1 meter or time threshold)
	if path_history.is_empty() or path_history[-1].distance_to(position) >= 1.0:
		path_history.append(position)
		path_timestamps.append(game_time_elapsed)
		path_modes.append(travel_mode)


## Full route: the climber stands on the summit; the way home starts now
func reach_summit() -> void:
	if summit_reached:
		return
	summit_reached = true
	phase = GameEnums.RunPhase.DESCENT
	summit_time = game_time_elapsed
	# Descent progress now runs from the top
	start_elevation = maxf(start_elevation, position.y)
	summit_path_index = maxi(0, path_history.size() - 1)
	record_decision("summit_reached", {
		"elevation": position.y,
		"game_time": game_time_elapsed,
		"time_of_day": current_time
	})


## True for a full-route run
func is_full_route() -> bool:
	return route_mode == GameEnums.RouteMode.FULL_ROUTE


## Forget the last position sample so the next update_position() call
## anchors tracking again (used when the player is placed, not moved)
func reset_position_tracking() -> void:
	_has_position_sample = false


## Update time
func update_time(delta_real: float) -> void:
	real_time_elapsed += delta_real
	var delta_game := delta_real * GameEnums.TIME_SCALE / 3600.0  # Convert to hours
	game_time_elapsed += delta_game
	var start_time := start_conditions.time_of_day if start_conditions else 6.0
	current_time = fmod(start_time + game_time_elapsed, 24.0)


## Record a decision
func record_decision(decision_type: String, details: Dictionary = {}) -> void:
	var decision := log_decision(decision_type, details)
	EventBus.decision_recorded.emit(decision_type, decision)


## Record an incident
func record_incident(incident_type: String, details: Dictionary = {}) -> void:
	var incident := log_incident(incident_type, details)
	EventBus.incident_recorded.emit(incident_type, incident)


## Add a decision to the history without announcing it (GameStateManager
## logs the decisions systems announce through EventBus.record_decision)
func log_decision(decision_type: String, details: Dictionary = {}) -> Dictionary:
	var decision := {
		"type": decision_type,
		"game_time": game_time_elapsed,
		"real_time": real_time_elapsed,
		"position": position,
		"details": details,
		LOGGED_KEY: true
	}
	decisions.append(decision)
	return decision


## Add an incident to the history without announcing it (GameStateManager
## logs the incidents systems announce through EventBus.record_incident)
func log_incident(incident_type: String, details: Dictionary = {}) -> Dictionary:
	var incident := {
		"type": incident_type,
		"game_time": game_time_elapsed,
		"real_time": real_time_elapsed,
		"position": position,
		"velocity": velocity,
		"body_state": body_state.duplicate_state() if body_state else null,
		"details": details,
		LOGGED_KEY: true
	}
	incidents.append(incident)
	return incident


# =============================================================================
# PROGRESS & METRICS
# =============================================================================

## Get descent progress (0 = at summit, 1 = at safety)
func get_descent_progress() -> float:
	if start_elevation <= target_elevation:
		return 1.0

	var total_descent := start_elevation - target_elevation
	var current_descent := start_elevation - current_elevation

	return clampf(current_descent / total_descent, 0.0, 1.0)


## Get estimated time remaining based on current pace
func get_estimated_time_remaining() -> float:
	var progress := get_descent_progress()
	if progress <= 0.0 or game_time_elapsed <= 0.0:
		return -1.0  # Unknown

	var time_per_progress := game_time_elapsed / progress
	var remaining_progress := 1.0 - progress

	return time_per_progress * remaining_progress


## Get daylight remaining at current game time
func get_daylight_remaining() -> float:
	var sunset := get_sunset_time()
	if current_time >= sunset:
		return 0.0
	return sunset - current_time


## Get sunrise time based on latitude and day of year
func get_sunrise_time() -> float:
	if start_conditions:
		return start_conditions.calculate_sunrise()
	return 6.0  # Default fallback


## Get sunset time based on latitude and day of year
func get_sunset_time() -> float:
	if start_conditions:
		return start_conditions.calculate_sunset()
	return 18.0  # Default fallback


## Check if it's getting dark (less than 1 hour of daylight)
func is_getting_dark() -> bool:
	return get_daylight_remaining() < 1.0


## Check if it's fully dark (past sunset)
func is_dark() -> bool:
	return get_daylight_remaining() <= 0.0


## Check if it's currently daytime
func is_daytime() -> bool:
	var sunrise := get_sunrise_time()
	var sunset := get_sunset_time()
	return current_time >= sunrise and current_time < sunset


## Get the current sun elevation angle (for lighting)
## Returns degrees above horizon (negative = below horizon)
func get_sun_elevation() -> float:
	var sunrise := get_sunrise_time()
	var sunset := get_sunset_time()

	if current_time < sunrise or current_time > sunset:
		return -10.0  # Below horizon

	# Normalize time to 0-1 between sunrise and sunset
	var day_progress := (current_time - sunrise) / (sunset - sunrise)

	# Peak elevation at solar noon (midpoint)
	# Use sine curve: 0 at sunrise, peak at noon, 0 at sunset
	var elevation := sin(day_progress * PI) * 60.0  # Max ~60° at noon

	# Adjust for latitude (higher latitudes = lower maximum sun angle)
	if start_conditions:
		var latitude_factor := 1.0 - absf(start_conditions.latitude) / 90.0
		elevation *= latitude_factor + 0.4  # Keep minimum of 40% of angle

	return elevation


# =============================================================================
# RUN COMPLETION
# =============================================================================

## End the run with given outcome
func complete_run(result: GameEnums.ResolutionType, cause: String = "") -> void:
	is_complete = true
	outcome = result
	end_position = position
	end_cause = cause

	# Record final incident
	record_incident("run_complete", {
		"outcome": result,
		"cause": cause
	})


## Get a summary of the run
func get_run_summary() -> Dictionary:
	return {
		"run_id": run_id,
		"mountain_id": mountain_id,
		"outcome": outcome,
		"real_time": real_time_elapsed,
		"game_time": game_time_elapsed,
		"distance": distance_traveled,
		"start_elevation": start_elevation,
		"end_elevation": current_elevation,
		"decisions_count": decisions.size(),
		"incidents_count": incidents.size(),
		"final_fatigue": body_state.fatigue if body_state else 0.0,
		"injuries": body_state.injuries.size() if body_state else 0,
		"difficulty": start_conditions.get_difficulty_score() if start_conditions else 0.0,
		"route_mode": route_mode,
		"summit_reached": summit_reached
	}


# =============================================================================
# SUSPENDING (a run saved part-way, to be picked up again)
# =============================================================================

## This run as plain data (numbers, strings, vectors, arrays, dictionaries):
## everything needed to carry on with it later. SaveManager writes it; the
## world around the run (clock, weather, where the climber stands) is saved
## alongside by Main.
func to_save() -> Dictionary:
	var metas := {}
	for key in get_meta_list():
		var value: Variant = _plain(get_meta(key))
		if value != null:
			metas[str(key)] = value
	return {
		"run_id": run_id,
		"mountain_id": mountain_id,
		"start_timestamp": start_timestamp,
		"start_conditions": start_conditions.to_save() if start_conditions != null else {},
		"position": position,
		"movement_state": int(movement_state),
		"body_state": body_state.to_save() if body_state != null else {},
		"gear_state": gear_state.to_save() if gear_state != null else {},
		"current_time": current_time,
		"current_weather": int(current_weather),
		"current_wind": int(current_wind),
		"current_temperature": current_temperature,
		"real_time_elapsed": real_time_elapsed,
		"game_time_elapsed": game_time_elapsed,
		"distance_traveled": distance_traveled,
		"current_elevation": current_elevation,
		"start_elevation": start_elevation,
		"target_elevation": target_elevation,
		"path_history": path_history,
		"path_timestamps": path_timestamps,
		"path_modes": path_modes,
		"decisions": _plain(decisions),
		"incidents": _plain(incidents),
		"route_mode": int(route_mode),
		"phase": int(phase),
		"summit_reached": summit_reached,
		"summit_time": summit_time,
		"summit_path_index": summit_path_index,
		"metas": metas,
	}


## A run from to_save() data, ready to carry on (never a finished one).
## null when the data is not a run.
static func from_save(data: Dictionary) -> RunContext:
	if str(data.get("mountain_id", "")).is_empty() or not (data.get("start_conditions") is Dictionary):
		return null
	var run := RunContext.new()
	run.run_id = str(data.get("run_id", run.run_id))
	run.mountain_id = str(data["mountain_id"])
	run.start_timestamp = int(data.get("start_timestamp", run.start_timestamp))
	run.start_conditions = StartConditions.from_save(data["start_conditions"])
	if data.get("position") is Vector3:
		run.position = data["position"]
	run.body_state = BodyState.from_save(data["body_state"]) if data.get("body_state") is Dictionary \
		else run.start_conditions.body_state.duplicate_state()
	run.gear_state = GearState.from_save(data["gear_state"]) if data.get("gear_state") is Dictionary \
		else run.start_conditions.gear_state.duplicate_state()
	run.current_time = fposmod(float(data.get("current_time", run.start_conditions.time_of_day)), 24.0)
	run.current_weather = StartConditions._enum_value(data.get("current_weather"), GameEnums.WeatherState.size(), run.start_conditions.weather) as GameEnums.WeatherState
	run.current_wind = StartConditions._enum_value(data.get("current_wind"), GameEnums.WindStrength.size(), run.start_conditions.wind_strength) as GameEnums.WindStrength
	run.current_temperature = float(data.get("current_temperature", run.start_conditions.temperature))
	run.real_time_elapsed = maxf(float(data.get("real_time_elapsed", 0.0)), 0.0)
	run.game_time_elapsed = maxf(float(data.get("game_time_elapsed", 0.0)), 0.0)
	run.distance_traveled = maxf(float(data.get("distance_traveled", 0.0)), 0.0)
	run.current_elevation = float(data.get("current_elevation", run.position.y))
	run.start_elevation = float(data.get("start_elevation", run.position.y))
	run.target_elevation = float(data.get("target_elevation", 0.0))
	if data.get("path_history") is PackedVector3Array:
		run.path_history = data["path_history"]
	if data.get("path_timestamps") is PackedFloat64Array:
		run.path_timestamps = data["path_timestamps"]
	if data.get("path_modes") is PackedByteArray:
		run.path_modes = data["path_modes"]
	# The three run in parallel: a file where they do not match keeps the
	# part they share
	var samples := mini(run.path_history.size(), run.path_timestamps.size())
	run.path_history = run.path_history.slice(0, samples)
	run.path_timestamps = run.path_timestamps.slice(0, samples)
	if run.path_modes.size() != samples:
		run.path_modes.resize(samples)
	for entry in _dictionaries(data.get("decisions")):
		run.decisions.append(entry)
	for entry in _dictionaries(data.get("incidents")):
		run.incidents.append(entry)
	run.route_mode = run.start_conditions.route_mode
	run.phase = StartConditions._enum_value(data.get("phase"), GameEnums.RunPhase.size(), run.phase) as GameEnums.RunPhase
	run.summit_reached = bool(data.get("summit_reached", false))
	run.summit_time = float(data.get("summit_time", -1.0))
	run.summit_path_index = clampi(int(data.get("summit_path_index", -1)), -1, maxi(samples - 1, -1))
	var metas: Variant = data.get("metas")
	if metas is Dictionary:
		for key in metas:
			run.set_meta(str(key), metas[key])
	return run


## A copy of a value with nothing but plain data in it: objects become their
## own to_save() data when they have one and are left out otherwise
static func _plain(value: Variant) -> Variant:
	match typeof(value):
		TYPE_OBJECT:
			if value != null and is_instance_valid(value) and (value as Object).has_method("to_save"):
				return (value as Object).call("to_save")
			return null
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return null
		TYPE_DICTIONARY:
			var copy := {}
			for key in value:
				var plain_key: Variant = _plain(key)
				if plain_key != null:
					copy[plain_key] = _plain(value[key])
			return copy
		TYPE_ARRAY:
			var list: Array = []
			for item in value:
				list.append(_plain(item))
			return list
	return value


## The dictionaries in a saved list (anything else in it is dropped)
static func _dictionaries(value: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if value is Array:
		for entry in value:
			if entry is Dictionary:
				out.append(entry)
	return out


# =============================================================================
# ANALYSIS
# =============================================================================

## Get decisions of a specific type
func get_decisions_by_type(decision_type: String) -> Array[Dictionary]:
	var filtered: Array[Dictionary] = []
	for decision in decisions:
		if decision.type == decision_type:
			filtered.append(decision)
	return filtered


## Get incidents of a specific type
func get_incidents_by_type(incident_type: String) -> Array[Dictionary]:
	var filtered: Array[Dictionary] = []
	for incident in incidents:
		if incident.type == incident_type:
			filtered.append(incident)
	return filtered


## Get the incident that caused failure (if any)
func get_fatal_incident() -> Dictionary:
	if outcome != GameEnums.ResolutionType.FATALITY:
		return {}

	# Return the last critical incident
	for i in range(incidents.size() - 1, -1, -1):
		var incident: Dictionary = incidents[i]
		if incident.type in ["terminal_slide", "fatal_fall", "exposure_death"]:
			return incident

	return {}
