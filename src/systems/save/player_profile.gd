class_name PlayerProfile
extends RefCounted
## Persistent player profile data
## Tracks lifetime stats, achievements, and preferences
##
## Design Philosophy:
## - Stats tell a story of learning
## - Every run contributes to growth
## - Failure teaches as much as success

# =============================================================================
# IDENTITY
# =============================================================================

## Profile creation timestamp
var created_at: float = 0.0

## Last played timestamp
var last_played: float = 0.0

## Player display name (optional)
var display_name: String = "Mountaineer"

# =============================================================================
# LIFETIME STATISTICS
# =============================================================================

## Total number of runs
var total_runs: int = 0

## Successful runs (clean or injured return)
var successful_runs: int = 0

## Clean returns only
var clean_returns: int = 0

## Fatalities
var fatalities: int = 0

## Total meters descended
var total_descent_meters: float = 0.0

## Total play time (seconds)
var total_play_time: float = 0.0

## Best descent time per mountain (id -> time in minutes)
var best_times: Dictionary = {}

## Mountains completed (at least once)
var mountains_completed: Array[String] = []

## Mountains mastered (5+ clean returns)
var mountains_mastered: Array[String] = []

# =============================================================================
# STREAKS AND RECORDS
# =============================================================================

## Current clean return streak
var current_streak: int = 0

## Best clean return streak ever
var best_streak: int = 0

## Longest single descent (meters)
var longest_descent: float = 0.0

## Most technical sections in one run
var most_technical_sections: int = 0

## Survived worst weather
var worst_weather_survived: GameEnums.WeatherState = GameEnums.WeatherState.CLEAR

# =============================================================================
# LEARNING MILESTONES
# =============================================================================

## First successful self-arrest
var first_self_arrest: bool = false

## First rope deployment
var first_rope_use: bool = false

## First storm survival
var first_storm_survival: bool = false

## First bivy
var first_bivy: bool = false

## First clean run without rope
var first_no_rope_clean: bool = false

# =============================================================================
# PREFERENCES
# =============================================================================

## Preferred loadout preset
var preferred_loadout: String = "Standard"

## Last selected mountain
var last_mountain: String = ""

## Tutorial completed
var tutorial_completed: bool = false

## Intro cinematics seen
var intro_seen: bool = false

# =============================================================================
# SESSION TRACKING
# =============================================================================

## Current session start time
var session_start: float = 0.0

## Current session runs
var session_runs: int = 0

## Current session successful runs
var session_successful: int = 0

# =============================================================================
# UPDATE METHODS
# =============================================================================

func update_from_run(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	total_runs += 1
	session_runs += 1
	last_played = Time.get_unix_time_from_system()

	# Track descent
	var descent := run_context.start_elevation - run_context.current_elevation
	total_descent_meters += descent
	if descent > longest_descent:
		longest_descent = descent

	# Track play time
	var run_duration := run_context.elapsed_time
	total_play_time += run_duration

	# Track outcome
	match outcome:
		GameEnums.ResolutionType.CLEAN_RETURN:
			successful_runs += 1
			clean_returns += 1
			session_successful += 1
			current_streak += 1
			if current_streak > best_streak:
				best_streak = current_streak
			_record_best_time(run_context.mountain_id, run_context.elapsed_time / 60.0)
			_check_mountain_completion(run_context.mountain_id)

		GameEnums.ResolutionType.INJURED_RETURN:
			successful_runs += 1
			session_successful += 1
			current_streak = 0  # Injured breaks streak
			_check_mountain_completion(run_context.mountain_id)

		GameEnums.ResolutionType.FORCED_BIVY:
			current_streak = 0
			if not first_bivy:
				first_bivy = true

		GameEnums.ResolutionType.RESCUE:
			current_streak = 0

		GameEnums.ResolutionType.FATALITY:
			fatalities += 1
			current_streak = 0

	# Track weather survival
	var weather: GameEnums.WeatherState = run_context.current_weather
	if outcome <= GameEnums.ResolutionType.INJURED_RETURN:
		if weather > worst_weather_survived:
			worst_weather_survived = weather
		if weather >= GameEnums.WeatherState.STORM and not first_storm_survival:
			first_storm_survival = true

	# Track gear usage
	var gear: GearState = run_context.gear_state
	if gear and not gear.has_item(GameEnums.GearType.ROPE):
		if outcome == GameEnums.ResolutionType.CLEAN_RETURN and not first_no_rope_clean:
			first_no_rope_clean = true

	# Update last mountain
	last_mountain = run_context.mountain_id


func _record_best_time(mountain_id: String, time_minutes: float) -> void:
	if not best_times.has(mountain_id) or time_minutes < best_times[mountain_id]:
		best_times[mountain_id] = time_minutes


func _check_mountain_completion(mountain_id: String) -> void:
	if mountain_id not in mountains_completed:
		mountains_completed.append(mountain_id)


func mark_mountain_mastered(mountain_id: String) -> void:
	if mountain_id not in mountains_mastered:
		mountains_mastered.append(mountain_id)


func start_session() -> void:
	session_start = Time.get_unix_time_from_system()
	session_runs = 0
	session_successful = 0


func get_session_duration() -> float:
	if session_start == 0.0:
		return 0.0
	return Time.get_unix_time_from_system() - session_start


# =============================================================================
# DERIVED STATS
# =============================================================================

func get_success_rate() -> float:
	if total_runs == 0:
		return 0.0
	return float(successful_runs) / float(total_runs)


func get_clean_rate() -> float:
	if total_runs == 0:
		return 0.0
	return float(clean_returns) / float(total_runs)


func get_fatality_rate() -> float:
	if total_runs == 0:
		return 0.0
	return float(fatalities) / float(total_runs)


func get_average_descent() -> float:
	if total_runs == 0:
		return 0.0
	return total_descent_meters / float(total_runs)


func get_formatted_play_time() -> String:
	var hours := int(total_play_time / 3600)
	var minutes := int(fmod(total_play_time, 3600) / 60)

	if hours > 0:
		return "%dh %dm" % [hours, minutes]
	else:
		return "%dm" % minutes


func get_experience_level() -> String:
	if total_runs < 5:
		return "Novice"
	elif total_runs < 20:
		return "Beginner"
	elif total_runs < 50:
		return "Intermediate"
	elif total_runs < 100:
		return "Experienced"
	elif total_runs < 200:
		return "Veteran"
	else:
		return "Master"


# =============================================================================
# SERIALIZATION
# =============================================================================

func to_dict() -> Dictionary:
	return {
		"created_at": created_at,
		"last_played": last_played,
		"display_name": display_name,

		"total_runs": total_runs,
		"successful_runs": successful_runs,
		"clean_returns": clean_returns,
		"fatalities": fatalities,
		"total_descent_meters": total_descent_meters,
		"total_play_time": total_play_time,
		"best_times": best_times,
		"mountains_completed": mountains_completed,
		"mountains_mastered": mountains_mastered,

		"current_streak": current_streak,
		"best_streak": best_streak,
		"longest_descent": longest_descent,
		"most_technical_sections": most_technical_sections,
		"worst_weather_survived": worst_weather_survived,

		"first_self_arrest": first_self_arrest,
		"first_rope_use": first_rope_use,
		"first_storm_survival": first_storm_survival,
		"first_bivy": first_bivy,
		"first_no_rope_clean": first_no_rope_clean,

		"preferred_loadout": preferred_loadout,
		"last_mountain": last_mountain,
		"tutorial_completed": tutorial_completed,
		"intro_seen": intro_seen
	}


static func from_dict(data: Dictionary) -> PlayerProfile:
	var profile := PlayerProfile.new()

	profile.created_at = data.get("created_at", 0.0)
	profile.last_played = data.get("last_played", 0.0)
	profile.display_name = data.get("display_name", "Mountaineer")

	profile.total_runs = data.get("total_runs", 0)
	profile.successful_runs = data.get("successful_runs", 0)
	profile.clean_returns = data.get("clean_returns", 0)
	profile.fatalities = data.get("fatalities", 0)
	profile.total_descent_meters = data.get("total_descent_meters", 0.0)
	profile.total_play_time = data.get("total_play_time", 0.0)
	profile.best_times = data.get("best_times", {})
	profile.mountains_completed.assign(data.get("mountains_completed", []))
	profile.mountains_mastered.assign(data.get("mountains_mastered", []))

	profile.current_streak = data.get("current_streak", 0)
	profile.best_streak = data.get("best_streak", 0)
	profile.longest_descent = data.get("longest_descent", 0.0)
	profile.most_technical_sections = data.get("most_technical_sections", 0)
	profile.worst_weather_survived = data.get("worst_weather_survived", GameEnums.WeatherState.CLEAR)

	profile.first_self_arrest = data.get("first_self_arrest", false)
	profile.first_rope_use = data.get("first_rope_use", false)
	profile.first_storm_survival = data.get("first_storm_survival", false)
	profile.first_bivy = data.get("first_bivy", false)
	profile.first_no_rope_clean = data.get("first_no_rope_clean", false)

	profile.preferred_loadout = data.get("preferred_loadout", "Standard")
	profile.last_mountain = data.get("last_mountain", "")
	profile.tutorial_completed = data.get("tutorial_completed", false)
	profile.intro_seen = data.get("intro_seen", false)

	return profile
