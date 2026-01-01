class_name RunHistory
extends RefCounted
## Records and tracks past runs for analysis and comparison
## Enables learning from previous attempts
##
## Design Philosophy:
## - History informs future decisions
## - Patterns emerge from data
## - Every run is a lesson

# =============================================================================
# CONFIGURATION
# =============================================================================

const MAX_ENTRIES := 100
const MAX_ENTRIES_PER_MOUNTAIN := 20

# =============================================================================
# DATA STRUCTURES
# =============================================================================

class HistoryEntry:
	## Unique run ID
	var run_id: String

	## Mountain ID
	var mountain_id: String

	## Timestamp
	var timestamp: float

	## Outcome
	var outcome: GameEnums.ResolutionType

	## Duration in seconds
	var duration: float

	## Total descent in meters
	var descent_meters: float

	## Starting conditions summary
	var start_weather: GameEnums.WeatherState
	var start_time_of_day: float

	## Gear weight at start
	var gear_weight: float

	## Key events during run
	var key_events: Array[Dictionary] = []

	## Death cause (if applicable)
	var death_cause: String = ""

	## Injuries sustained
	var injuries: Array[String] = []

	## Rope sections used
	var rope_sections_used: int = 0

	## Self-arrest attempts
	var self_arrest_attempts: int = 0

	## Self-arrest successes
	var self_arrest_successes: int = 0

	func to_dict() -> Dictionary:
		return {
			"run_id": run_id,
			"mountain_id": mountain_id,
			"timestamp": timestamp,
			"outcome": outcome,
			"duration": duration,
			"descent_meters": descent_meters,
			"start_weather": start_weather,
			"start_time_of_day": start_time_of_day,
			"gear_weight": gear_weight,
			"key_events": key_events,
			"death_cause": death_cause,
			"injuries": injuries,
			"rope_sections_used": rope_sections_used,
			"self_arrest_attempts": self_arrest_attempts,
			"self_arrest_successes": self_arrest_successes
		}

	static func from_dict(data: Dictionary) -> HistoryEntry:
		var entry := HistoryEntry.new()
		entry.run_id = data.get("run_id", "")
		entry.mountain_id = data.get("mountain_id", "")
		entry.timestamp = data.get("timestamp", 0.0)
		entry.outcome = data.get("outcome", GameEnums.ResolutionType.FATALITY)
		entry.duration = data.get("duration", 0.0)
		entry.descent_meters = data.get("descent_meters", 0.0)
		entry.start_weather = data.get("start_weather", GameEnums.WeatherState.CLEAR)
		entry.start_time_of_day = data.get("start_time_of_day", 0.0)
		entry.gear_weight = data.get("gear_weight", 0.0)
		entry.key_events.assign(data.get("key_events", []))
		entry.death_cause = data.get("death_cause", "")
		entry.injuries.assign(data.get("injuries", []))
		entry.rope_sections_used = data.get("rope_sections_used", 0)
		entry.self_arrest_attempts = data.get("self_arrest_attempts", 0)
		entry.self_arrest_successes = data.get("self_arrest_successes", 0)
		return entry


# =============================================================================
# STATE
# =============================================================================

## All history entries (newest first)
var entries: Array[HistoryEntry] = []

## Entries indexed by mountain
var by_mountain: Dictionary = {}  # mountain_id -> Array[HistoryEntry]

# =============================================================================
# RECORDING
# =============================================================================

func record_run(run_context: RunContext, outcome: GameEnums.ResolutionType) -> HistoryEntry:
	var entry := HistoryEntry.new()

	entry.run_id = run_context.run_id
	entry.mountain_id = run_context.mountain_id
	entry.timestamp = Time.get_unix_time_from_system()
	entry.outcome = outcome
	entry.duration = run_context.elapsed_time
	entry.descent_meters = run_context.start_elevation - run_context.current_elevation

	# Start conditions
	if run_context.start_conditions:
		entry.start_weather = run_context.start_conditions.weather
		entry.start_time_of_day = run_context.start_conditions.time_of_day
		if run_context.start_conditions.gear_state:
			entry.gear_weight = run_context.start_conditions.gear_state.total_weight

	# Extract key events from run
	entry.key_events = _extract_key_events(run_context)

	# Death cause
	if outcome == GameEnums.ResolutionType.FATALITY:
		entry.death_cause = run_context.get_meta("death_cause", "Unknown")

	# Injuries
	if run_context.body_state:
		for injury in run_context.body_state.injuries:
			entry.injuries.append(str(injury))

	# Add to history
	entries.insert(0, entry)

	# Index by mountain
	if not by_mountain.has(entry.mountain_id):
		by_mountain[entry.mountain_id] = []
	by_mountain[entry.mountain_id].insert(0, entry)

	# Trim to max size
	_trim_history()

	return entry


func _extract_key_events(run_context: RunContext) -> Array[Dictionary]:
	var key_events: Array[Dictionary] = []

	# Would extract from run context's event log
	# For now, return empty array
	return key_events


func _trim_history() -> void:
	# Trim global entries
	while entries.size() > MAX_ENTRIES:
		var removed := entries.pop_back()
		# Also remove from mountain index
		if by_mountain.has(removed.mountain_id):
			var mountain_entries: Array = by_mountain[removed.mountain_id]
			mountain_entries.erase(removed)

	# Trim per-mountain entries
	for mountain_id in by_mountain:
		var mountain_entries: Array = by_mountain[mountain_id]
		while mountain_entries.size() > MAX_ENTRIES_PER_MOUNTAIN:
			mountain_entries.pop_back()


# =============================================================================
# QUERIES
# =============================================================================

func get_all_entries() -> Array[HistoryEntry]:
	return entries


func get_entries_for_mountain(mountain_id: String) -> Array[HistoryEntry]:
	if not by_mountain.has(mountain_id):
		return []
	var result: Array[HistoryEntry] = []
	result.assign(by_mountain[mountain_id])
	return result


func get_recent_entries(count: int = 10) -> Array[HistoryEntry]:
	var result: Array[HistoryEntry] = []
	for i in range(mini(count, entries.size())):
		result.append(entries[i])
	return result


func get_best_time(mountain_id: String) -> float:
	if not by_mountain.has(mountain_id):
		return -1.0

	var best := -1.0
	for entry in by_mountain[mountain_id]:
		if entry.outcome == GameEnums.ResolutionType.CLEAN_RETURN:
			if best < 0 or entry.duration < best:
				best = entry.duration

	return best


func get_success_rate(mountain_id: String) -> float:
	if not by_mountain.has(mountain_id):
		return 0.0

	var total := 0
	var successful := 0

	for entry in by_mountain[mountain_id]:
		total += 1
		if entry.outcome <= GameEnums.ResolutionType.INJURED_RETURN:
			successful += 1

	if total == 0:
		return 0.0
	return float(successful) / float(total)


func get_attempt_count(mountain_id: String) -> int:
	if not by_mountain.has(mountain_id):
		return 0
	return by_mountain[mountain_id].size()


func get_outcome_breakdown(mountain_id: String = "") -> Dictionary:
	var breakdown := {
		"clean_return": 0,
		"injured_return": 0,
		"forced_bivy": 0,
		"rescue": 0,
		"fatality": 0
	}

	var source := entries
	if mountain_id != "" and by_mountain.has(mountain_id):
		source = by_mountain[mountain_id]

	for entry in source:
		match entry.outcome:
			GameEnums.ResolutionType.CLEAN_RETURN:
				breakdown["clean_return"] += 1
			GameEnums.ResolutionType.INJURED_RETURN:
				breakdown["injured_return"] += 1
			GameEnums.ResolutionType.FORCED_BIVY:
				breakdown["forced_bivy"] += 1
			GameEnums.ResolutionType.RESCUE:
				breakdown["rescue"] += 1
			GameEnums.ResolutionType.FATALITY:
				breakdown["fatality"] += 1

	return breakdown


func get_common_death_causes(mountain_id: String = "", limit: int = 5) -> Array[Dictionary]:
	var causes: Dictionary = {}

	var source := entries
	if mountain_id != "" and by_mountain.has(mountain_id):
		source = by_mountain[mountain_id]

	for entry in source:
		if entry.outcome == GameEnums.ResolutionType.FATALITY and entry.death_cause != "":
			causes[entry.death_cause] = causes.get(entry.death_cause, 0) + 1

	# Sort by count
	var sorted: Array[Dictionary] = []
	for cause in causes:
		sorted.append({"cause": cause, "count": causes[cause]})
	sorted.sort_custom(func(a, b): return a["count"] > b["count"])

	# Limit results
	var result: Array[Dictionary] = []
	for i in range(mini(limit, sorted.size())):
		result.append(sorted[i])
	return result


func get_average_duration(mountain_id: String, outcome_filter: GameEnums.ResolutionType = -1) -> float:
	if not by_mountain.has(mountain_id):
		return 0.0

	var total := 0.0
	var count := 0

	for entry in by_mountain[mountain_id]:
		if outcome_filter == -1 or entry.outcome == outcome_filter:
			total += entry.duration
			count += 1

	if count == 0:
		return 0.0
	return total / float(count)


# =============================================================================
# ANALYSIS
# =============================================================================

func get_improvement_trend(mountain_id: String, window: int = 5) -> float:
	## Returns a trend value: positive = improving, negative = worsening
	if not by_mountain.has(mountain_id):
		return 0.0

	var mountain_entries: Array = by_mountain[mountain_id]
	if mountain_entries.size() < window * 2:
		return 0.0  # Not enough data

	# Compare recent runs to older runs
	var recent_success := 0.0
	var older_success := 0.0

	for i in range(window):
		if mountain_entries[i].outcome <= GameEnums.ResolutionType.INJURED_RETURN:
			recent_success += 1.0

	for i in range(window, window * 2):
		if mountain_entries[i].outcome <= GameEnums.ResolutionType.INJURED_RETURN:
			older_success += 1.0

	return (recent_success - older_success) / float(window)


func get_peak_performance(mountain_id: String) -> HistoryEntry:
	## Returns the best run for a mountain
	if not by_mountain.has(mountain_id):
		return null

	var best: HistoryEntry = null

	for entry in by_mountain[mountain_id]:
		if entry.outcome != GameEnums.ResolutionType.CLEAN_RETURN:
			continue

		if best == null or entry.duration < best.duration:
			best = entry

	return best


# =============================================================================
# SERIALIZATION
# =============================================================================

func to_dict() -> Dictionary:
	var entries_data: Array[Dictionary] = []
	for entry in entries:
		entries_data.append(entry.to_dict())

	return {
		"entries": entries_data
	}


static func from_dict(data: Dictionary) -> RunHistory:
	var history := RunHistory.new()

	var entries_data: Array = data.get("entries", [])
	for entry_data in entries_data:
		var entry := HistoryEntry.from_dict(entry_data)
		history.entries.append(entry)

		# Build mountain index
		if not history.by_mountain.has(entry.mountain_id):
			history.by_mountain[entry.mountain_id] = []
		history.by_mountain[entry.mountain_id].append(entry)

	return history
