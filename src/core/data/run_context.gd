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

	return context


# =============================================================================
# STATE UPDATES
# =============================================================================

## Update position and record to history
func update_position(new_position: Vector3, new_velocity: Vector3) -> void:
	var old_position := position
	position = new_position
	velocity = new_velocity

	# Track distance
	if old_position != Vector3.ZERO:
		distance_traveled += old_position.distance_to(new_position)

	# Update elevation
	current_elevation = position.y

	# Sample path history (every ~1 meter or time threshold)
	if path_history.is_empty() or path_history[-1].distance_to(position) >= 1.0:
		path_history.append(position)
		path_timestamps.append(game_time_elapsed)


## Update time
func update_time(delta_real: float) -> void:
	real_time_elapsed += delta_real
	var delta_game := delta_real * GameEnums.TIME_SCALE / 3600.0  # Convert to hours
	game_time_elapsed += delta_game
	var start_time := start_conditions.time_of_day if start_conditions else 6.0
	current_time = fmod(start_time + game_time_elapsed, 24.0)


## Record a decision
func record_decision(decision_type: String, details: Dictionary = {}) -> void:
	var decision := {
		"type": decision_type,
		"game_time": game_time_elapsed,
		"real_time": real_time_elapsed,
		"position": position,
		"details": details
	}
	decisions.append(decision)
	EventBus.decision_recorded.emit(decision_type, decision)


## Record an incident
func record_incident(incident_type: String, details: Dictionary = {}) -> void:
	var incident := {
		"type": incident_type,
		"game_time": game_time_elapsed,
		"real_time": real_time_elapsed,
		"position": position,
		"velocity": velocity,
		"body_state": body_state.duplicate_state() if body_state else null,
		"details": details
	}
	incidents.append(incident)
	EventBus.incident_recorded.emit(incident_type, incident)


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
		"difficulty": start_conditions.get_difficulty_score() if start_conditions else 0.0
	}


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
