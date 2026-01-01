class_name SpeedrunTimer
extends Node
## Speedrun timing and split tracking
## For competitive play and personal bests
##
## Categories:
## - Any%: Reach base by any means
## - Clean Return: No injuries, good margin
## - No Rope: Complete without rope deployment
## - Deathless: No fatalities (for multi-attempt sessions)

# =============================================================================
# SIGNALS
# =============================================================================

signal timer_started(category: String)
signal timer_stopped(final_time: float)
signal timer_paused()
signal timer_resumed()
signal split_recorded(split_name: String, time: float, delta: float)
signal personal_best(category: String, time: float)
signal gold_split(split_name: String, time: float)

# =============================================================================
# ENUMS
# =============================================================================

enum Category {
	ANY_PERCENT,
	CLEAN_RETURN,
	NO_ROPE,
	DEATHLESS,
	CUSTOM
}

enum TimerState {
	STOPPED,
	RUNNING,
	PAUSED,
	FINISHED
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Display")
## Show timer during run
@export var show_timer: bool = true
## Show splits
@export var show_splits: bool = true
## Show comparison to PB
@export var show_comparison: bool = true
## Decimal precision for display
@export var decimal_places: int = 2

@export_group("Auto-Split")
## Auto-split on altitude milestones
@export var auto_split_altitude: bool = true
## Altitude interval for auto-splits (meters)
@export var altitude_split_interval: float = 500.0

# =============================================================================
# SPLIT DATA
# =============================================================================

class Split:
	var name: String
	var time: float           # Time at this split
	var segment_time: float   # Time since last split
	var comparison: float     # Difference from PB
	var is_gold: bool         # Best segment ever

	func to_dict() -> Dictionary:
		return {
			"name": name,
			"time": time,
			"segment": segment_time,
			"comparison": comparison,
			"gold": is_gold
		}


class RunData:
	var category: Category
	var mountain_id: String
	var start_time: float
	var end_time: float
	var final_time: float
	var splits: Array[Split] = []
	var is_pb: bool = false
	var is_valid: bool = true  # Invalid if category rules broken
	var invalidation_reason: String = ""

	func to_dict() -> Dictionary:
		var split_dicts: Array[Dictionary] = []
		for split in splits:
			split_dicts.append(split.to_dict())

		return {
			"category": Category.keys()[category],
			"mountain": mountain_id,
			"final_time": final_time,
			"splits": split_dicts,
			"is_pb": is_pb,
			"is_valid": is_valid,
			"reason": invalidation_reason
		}

# =============================================================================
# STATE
# =============================================================================

## Current timer state
var state: TimerState = TimerState.STOPPED

## Current category
var category: Category = Category.ANY_PERCENT

## Current mountain
var mountain_id: String = ""

## Timer start time
var start_time: float = 0.0

## Current elapsed time
var elapsed_time: float = 0.0

## Pause time accumulator
var pause_accumulator: float = 0.0

## Last pause start
var pause_start: float = 0.0

## Current splits
var current_splits: Array[Split] = []

## Last split time
var last_split_time: float = 0.0

## Personal bests by category and mountain
var personal_bests: Dictionary = {}  # "mountain:category" -> RunData

## Gold splits (best segments ever)
var gold_splits: Dictionary = {}  # "mountain:split_name" -> float

## Starting altitude (for split calculation)
var start_altitude: float = 0.0

## Last split altitude
var last_split_altitude: float = 0.0

## Has used rope this run (for No Rope category)
var rope_used: bool = false

## Has died this session (for Deathless category)
var session_death: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("SpeedrunTimer", self)
	_load_data()
	_connect_events()
	print("[SpeedrunTimer] Initialized")


func _connect_events() -> void:
	EventBus.run_started.connect(_on_run_started)
	EventBus.run_ended.connect(_on_run_ended)
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.player_position_updated.connect(_on_player_position)
	EventBus.rope_deployment_started.connect(_on_rope_deployed)
	EventBus.fatal_event_started.connect(_on_fatal_event)
	EventBus.injury_occurred.connect(_on_injury)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if state != TimerState.RUNNING:
		return

	elapsed_time = Time.get_ticks_msec() / 1000.0 - start_time - pause_accumulator


# =============================================================================
# TIMER CONTROL
# =============================================================================

func start_timer(run_category: Category = Category.ANY_PERCENT, mountain: String = "") -> void:
	if state == TimerState.RUNNING:
		return

	state = TimerState.RUNNING
	category = run_category
	mountain_id = mountain
	start_time = Time.get_ticks_msec() / 1000.0
	elapsed_time = 0.0
	pause_accumulator = 0.0
	last_split_time = 0.0

	current_splits.clear()
	rope_used = false

	timer_started.emit(Category.keys()[category])


func stop_timer() -> void:
	if state == TimerState.STOPPED:
		return

	state = TimerState.FINISHED
	var final_time := elapsed_time

	timer_stopped.emit(final_time)

	# Check for PB
	_check_personal_best(final_time)


func pause_timer() -> void:
	if state != TimerState.RUNNING:
		return

	state = TimerState.PAUSED
	pause_start = Time.get_ticks_msec() / 1000.0
	timer_paused.emit()


func resume_timer() -> void:
	if state != TimerState.PAUSED:
		return

	state = TimerState.RUNNING
	pause_accumulator += Time.get_ticks_msec() / 1000.0 - pause_start
	timer_resumed.emit()


func reset_timer() -> void:
	state = TimerState.STOPPED
	elapsed_time = 0.0
	current_splits.clear()
	rope_used = false


# =============================================================================
# SPLITS
# =============================================================================

func record_split(split_name: String) -> void:
	if state != TimerState.RUNNING:
		return

	var split := Split.new()
	split.name = split_name
	split.time = elapsed_time
	split.segment_time = elapsed_time - last_split_time

	# Compare to PB split
	var pb := _get_pb_split(split_name)
	if pb > 0:
		split.comparison = split.time - pb

	# Check for gold split
	var gold := _get_gold_split(split_name)
	if gold <= 0 or split.segment_time < gold:
		split.is_gold = true
		_save_gold_split(split_name, split.segment_time)
		gold_split.emit(split_name, split.segment_time)

	current_splits.append(split)
	last_split_time = elapsed_time

	split_recorded.emit(split_name, split.time, split.comparison)


func _check_altitude_split(altitude: float) -> void:
	if not auto_split_altitude:
		return

	var altitude_dropped := start_altitude - altitude
	var splits_expected := int(altitude_dropped / altitude_split_interval)
	var current_split_count := current_splits.size()

	if splits_expected > current_split_count:
		var split_altitude := start_altitude - (splits_expected * altitude_split_interval)
		record_split("Alt_%dm" % int(split_altitude))


# =============================================================================
# CATEGORY VALIDATION
# =============================================================================

func _validate_category() -> void:
	match category:
		Category.NO_ROPE:
			if rope_used:
				_invalidate_run("Rope was deployed")

		Category.DEATHLESS:
			if session_death:
				_invalidate_run("Death occurred in session")

		Category.CLEAN_RETURN:
			# Checked at end of run
			pass


func _invalidate_run(reason: String) -> void:
	# Run is no longer valid for this category
	# Could still count for Any%

	var run := _get_current_run_data()
	run.is_valid = false
	run.invalidation_reason = reason


func _get_current_run_data() -> RunData:
	var run := RunData.new()
	run.category = category
	run.mountain_id = mountain_id
	run.start_time = start_time
	run.end_time = Time.get_ticks_msec() / 1000.0
	run.final_time = elapsed_time
	run.splits = current_splits.duplicate()
	return run


# =============================================================================
# PERSONAL BESTS
# =============================================================================

func _check_personal_best(time: float) -> void:
	var key := "%s:%s" % [mountain_id, Category.keys()[category]]
	var current_pb: float = personal_bests.get(key, {}).get("final_time", INF)

	if time < current_pb:
		var run := _get_current_run_data()
		run.is_pb = true
		personal_bests[key] = run.to_dict()

		personal_best.emit(Category.keys()[category], time)
		_save_data()


func get_personal_best(mount_id: String = "", cat: Category = Category.ANY_PERCENT) -> float:
	if mount_id.is_empty():
		mount_id = mountain_id

	var key := "%s:%s" % [mount_id, Category.keys()[cat]]
	return personal_bests.get(key, {}).get("final_time", -1.0)


func get_pb_splits(mount_id: String = "", cat: Category = Category.ANY_PERCENT) -> Array[Dictionary]:
	if mount_id.is_empty():
		mount_id = mountain_id

	var key := "%s:%s" % [mount_id, Category.keys()[cat]]
	var splits: Array[Dictionary] = []
	splits.assign(personal_bests.get(key, {}).get("splits", []))
	return splits


func _get_pb_split(split_name: String) -> float:
	var pb_splits := get_pb_splits()
	for split in pb_splits:
		if split.get("name") == split_name:
			return split.get("time", 0.0)
	return 0.0


# =============================================================================
# GOLD SPLITS
# =============================================================================

func _get_gold_split(split_name: String) -> float:
	var key := "%s:%s" % [mountain_id, split_name]
	return gold_splits.get(key, 0.0)


func _save_gold_split(split_name: String, time: float) -> void:
	var key := "%s:%s" % [mountain_id, split_name]
	gold_splits[key] = time
	_save_data()


# =============================================================================
# DATA PERSISTENCE
# =============================================================================

func _save_data() -> void:
	var data := {
		"personal_bests": personal_bests,
		"gold_splits": gold_splits
	}

	var file := FileAccess.open("user://speedrun_data.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()


func _load_data() -> void:
	var file := FileAccess.open("user://speedrun_data.json", FileAccess.READ)
	if file == null:
		return

	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()

	if error != OK:
		return

	personal_bests = json.data.get("personal_bests", {})
	gold_splits = json.data.get("gold_splits", {})


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_run_started(run_context: RunContext) -> void:
	if run_context:
		mountain_id = run_context.mountain_id

	# Auto-start timer on run start
	start_timer(category, mountain_id)


func _on_run_ended(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	if state != TimerState.RUNNING:
		return

	# Validate clean return category
	if category == Category.CLEAN_RETURN:
		if outcome != GameEnums.ResolutionType.CLEAN_RETURN:
			_invalidate_run("Did not achieve clean return")

	stop_timer()


func _on_game_state_changed(old_state: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	if new_state == GameEnums.GameState.PAUSED:
		pause_timer()
	elif old_state == GameEnums.GameState.PAUSED:
		resume_timer()
	elif new_state == GameEnums.GameState.MAIN_MENU:
		reset_timer()


func _on_player_position(position: Vector3, _velocity: Vector3) -> void:
	if state != TimerState.RUNNING:
		return

	# Initialize start altitude
	if start_altitude == 0.0:
		start_altitude = position.y
		last_split_altitude = position.y

	# Check for altitude splits
	_check_altitude_split(position.y)


func _on_rope_deployed(_quality: GameEnums.AnchorQuality) -> void:
	rope_used = true
	_validate_category()


func _on_fatal_event(_phase: GameEnums.FatalPhase) -> void:
	session_death = true
	_validate_category()


func _on_injury(_injury: Injury) -> void:
	if category == Category.CLEAN_RETURN:
		_invalidate_run("Injury occurred")


# =============================================================================
# DISPLAY FORMATTING
# =============================================================================

func format_time(time: float) -> String:
	var minutes := int(time) / 60
	var seconds := int(time) % 60
	var decimal := int((time - int(time)) * pow(10, decimal_places))

	if decimal_places == 0:
		return "%d:%02d" % [minutes, seconds]
	elif decimal_places == 1:
		return "%d:%02d.%d" % [minutes, seconds, decimal]
	elif decimal_places == 2:
		return "%d:%02d.%02d" % [minutes, seconds, decimal]
	else:
		return "%d:%02d.%03d" % [minutes, seconds, decimal]


func format_comparison(delta: float) -> String:
	var prefix := "+" if delta > 0 else ""
	return prefix + format_time(absf(delta))


# =============================================================================
# LEADERBOARD SUPPORT
# =============================================================================

## Get run data formatted for leaderboard submission
func get_leaderboard_data() -> Dictionary:
	return {
		"category": Category.keys()[category],
		"mountain": mountain_id,
		"time": elapsed_time,
		"splits": current_splits.size(),
		"is_valid": true,  # Would include validation hash
		"timestamp": Time.get_unix_time_from_system()
	}


# =============================================================================
# QUERIES
# =============================================================================

func get_elapsed_time() -> float:
	return elapsed_time


func get_current_splits() -> Array[Split]:
	return current_splits


func get_comparison_to_pb() -> float:
	var pb := get_personal_best()
	if pb < 0:
		return 0.0
	return elapsed_time - pb


func is_on_pb_pace() -> bool:
	return get_comparison_to_pb() < 0


func get_summary() -> Dictionary:
	return {
		"state": TimerState.keys()[state],
		"category": Category.keys()[category],
		"elapsed": elapsed_time,
		"formatted": format_time(elapsed_time),
		"splits": current_splits.size(),
		"pb": get_personal_best(),
		"comparison": get_comparison_to_pb(),
		"on_pace": is_on_pb_pace()
	}
