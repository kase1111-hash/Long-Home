class_name SpeedrunTimer
extends Node
## Speedrun timing and split tracking
## For competitive play and personal bests
##
## The time is the run's own clock (RunContext.real_time_elapsed: the seconds
## actually played, not counting pauses), so a run set aside and picked up
## again is timed in one piece. A personal best is kept only for a route
## brought home, per mountain and per way round it (descent or full route).
## The HUD and the resolution screen show it when the "show_timer" setting is
## on (SPEC-SHEET 17, "Speedrun Timer": an optional display, personal
## tracking only):
##   var timer := ServiceLocator.get_service("SpeedrunTimer") as SpeedrunTimer
##   timer.get_elapsed_time()                       # seconds, this run
##   timer.get_personal_best(mountain_id, full)     # seconds, -1 when none
##   SpeedrunTimer.format_clock(754.0)              # "12:34"
##
## Splits are noted at fixed shares of the height between the summit and base
## camp (SPLIT_MARKS), so they mean the same on whatever line is taken; on a
## full route the summit is one. Each is compared with the same split of the
## best run on that mountain. They are kept on the run (its "timer_splits"
## meta), so they survive Save and Quit.
##   timer.get_current_splits()                     # Array[Split], in order
##   timer.split_recorded                           # (name, time, comparison)
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

const DATA_PATH := "user://speedrun_data.json"

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

## Where the time is noted on the way. share: how much of the leg's height is
## behind the climber (0-1); phase: the leg it belongs to. The summit of a
## full route is noted when it is reached (EventBus.summit_reached).
## short: the label for the HUD.
const SPLIT_MARKS := {
	GameEnums.RouteMode.DESCENT: [
		{"id": "down_25", "label": "Quarter way down", "short": "25%", "phase": GameEnums.RunPhase.DESCENT, "share": 0.25},
		{"id": "down_50", "label": "Halfway down", "short": "50%", "phase": GameEnums.RunPhase.DESCENT, "share": 0.5},
		{"id": "down_75", "label": "Three quarters down", "short": "75%", "phase": GameEnums.RunPhase.DESCENT, "share": 0.75},
	],
	GameEnums.RouteMode.FULL_ROUTE: [
		{"id": "up_50", "label": "Halfway up", "short": "Up 50%", "phase": GameEnums.RunPhase.ASCENT, "share": 0.5},
		{"id": "summit", "label": "Summit", "short": "Summit", "phase": GameEnums.RunPhase.ASCENT, "share": 2.0},
		{"id": "down_50", "label": "Halfway down", "short": "Down 50%", "phase": GameEnums.RunPhase.DESCENT, "share": 0.5},
	],
}

## Key of the splits kept on a run (plain data: [{"id", "time"}])
const SPLITS_META := "timer_splits"

# =============================================================================
# SPLIT DATA
# =============================================================================

class Split:
	var id: String            # Which mark (SPLIT_MARKS)
	var name: String          # Its label ("Halfway down")
	var short_name: String    # Its label on the HUD ("50%")
	var time: float           # Time at this split
	var segment_time: float   # Time since last split
	var comparison: float     # Difference from the best run's same split
	var has_comparison: bool  # There is a best run with this split to compare with
	var is_gold: bool         # Best segment ever

	func to_dict() -> Dictionary:
		return {
			"id": id,
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

## The run being timed is a full route (base camp, summit, base camp)
var full_route: bool = false

## The run still counts for its category (see _invalidate_run)
var is_valid: bool = true
var invalidation_reason: String = ""

## The last finished run: its time, and whether it is the best on its mountain
var last_time: float = 0.0
var last_was_best: bool = false

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

## Has used rope this run (for No Rope category)
var rope_used: bool = false

## Has died this session (for Deathless category)
var session_death: bool = false

## Where bests are kept (tests point this at a file of their own)
var data_path: String = DATA_PATH


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
	EventBus.run_suspended.connect(_on_run_suspended)
	EventBus.summit_reached.connect(_on_summit_reached)
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.player_position_updated.connect(_on_player_position)
	EventBus.rope_deployment_started.connect(_on_rope_deployed)
	EventBus.fatal_event_started.connect(_on_fatal_event)
	EventBus.injury_occurred.connect(_on_injury)


# =============================================================================
# UPDATE
# =============================================================================

func _process(_delta: float) -> void:
	if state != TimerState.RUNNING:
		return

	# The run's own clock: seconds played, pauses not counted, and carried
	# through a save
	var run := GameStateManager.current_run
	if run != null:
		elapsed_time = run.real_time_elapsed


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
	is_valid = true
	invalidation_reason = ""
	last_was_best = false

	current_splits.clear()
	rope_used = false

	timer_started.emit(Category.keys()[category])


## Stop the clock. home: the route was brought home (only then can the time
## be a personal best: a run that ended on the mountain has no time to beat).
func stop_timer(home: bool = false) -> void:
	if state == TimerState.STOPPED:
		return

	state = TimerState.FINISHED
	var final_time := elapsed_time
	last_time = final_time
	last_was_best = false

	timer_stopped.emit(final_time)

	if home and is_valid:
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

## Note the time at a mark of this run's SPLIT_MARKS (once: a mark already
## passed is not noted again)
func record_split(split_id: String) -> void:
	if state != TimerState.RUNNING or _has_split(split_id):
		return
	var run := GameStateManager.current_run
	if run != null:
		elapsed_time = run.real_time_elapsed

	var split := _make_split(split_id, elapsed_time, last_split_time)

	# Check for gold split
	var gold := _get_gold_split(split_id)
	if gold <= 0 or split.segment_time < gold:
		split.is_gold = true
		_save_gold_split(split_id, split.segment_time)
		gold_split.emit(split.name, split.segment_time)

	current_splits.append(split)
	last_split_time = elapsed_time
	_keep_splits_on(run)

	split_recorded.emit(split.name, split.time, split.comparison)


## A split of the run being timed, compared with the best run's
func _make_split(split_id: String, time: float, previous_time: float) -> Split:
	var split := Split.new()
	split.id = split_id
	split.name = split_id
	split.short_name = split_id
	for mark in SPLIT_MARKS.get(GameEnums.RouteMode.FULL_ROUTE if full_route else GameEnums.RouteMode.DESCENT, []):
		if mark["id"] == split_id:
			split.name = mark["label"]
			split.short_name = mark["short"]
	split.time = time
	split.segment_time = time - previous_time
	var best := _get_pb_split(split_id)
	if best > 0.0:
		split.comparison = time - best
		split.has_comparison = true
	return split


func _has_split(split_id: String) -> bool:
	for split in current_splits:
		if split.id == split_id:
			return true
	return false


## The splits so far go with the run, as plain data, so that a run set aside
## and picked up again still has them
func _keep_splits_on(run: RunContext) -> void:
	if run == null:
		return
	var kept: Array = []
	for split in current_splits:
		kept.append({"id": split.id, "time": split.time})
	run.set_meta(SPLITS_META, kept)


## Take up the splits a run already has (it was set aside and picked up again)
func _take_splits_from(run: RunContext) -> void:
	current_splits.clear()
	last_split_time = 0.0
	if run == null:
		return
	var kept: Variant = run.get_meta(SPLITS_META, [])
	if not (kept is Array):
		return
	for entry in kept:
		if not (entry is Dictionary) or str(entry.get("id", "")).is_empty() or _has_split(str(entry["id"])):
			continue
		var time := float(entry.get("time", 0.0))
		current_splits.append(_make_split(str(entry["id"]), time, last_split_time))
		last_split_time = time


## Note the marks the climber has passed: a share of the height between the
## summit and base camp, on the leg they are on
func _check_marks(position: Vector3) -> void:
	var run := GameStateManager.current_run
	var terrain := ServiceLocator.get_service("TerrainService") as TerrainService
	if run == null or terrain == null or terrain.current_mountain != run.mountain_id:
		return
	var top := terrain.start_position.y
	var bottom := terrain.goal_position.y
	if top - bottom < 1.0:
		return
	var up_share := clampf((position.y - bottom) / (top - bottom), 0.0, 1.0)
	for mark in SPLIT_MARKS.get(run.route_mode, []):
		if int(mark["phase"]) != int(run.phase) or _has_split(mark["id"]):
			continue
		var share := up_share if int(mark["phase"]) == GameEnums.RunPhase.ASCENT else 1.0 - up_share
		if share >= float(mark["share"]):
			record_split(mark["id"])


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


## The run no longer counts for its category (it is still timed)
func _invalidate_run(reason: String) -> void:
	is_valid = false
	invalidation_reason = reason


func _get_current_run_data() -> RunData:
	var run := RunData.new()
	run.category = category
	run.mountain_id = mountain_id
	run.start_time = start_time
	run.end_time = Time.get_ticks_msec() / 1000.0
	run.final_time = elapsed_time
	run.splits = current_splits.duplicate()
	run.is_valid = is_valid
	run.invalidation_reason = invalidation_reason
	return run


# =============================================================================
# PERSONAL BESTS
# =============================================================================

func _check_personal_best(time: float) -> void:
	var key := _best_key(mountain_id, full_route, category)
	var current_pb: float = personal_bests.get(key, {}).get("final_time", INF)

	if time > 0.0 and time < current_pb:
		var run := _get_current_run_data()
		run.is_pb = true
		personal_bests[key] = run.to_dict()
		last_was_best = true

		personal_best.emit(Category.keys()[category], time)
		_save_data()


## Fastest return on a mountain, in seconds (-1 when there is none yet).
## full: the full route rather than the descent. No mountain: the current one.
func get_personal_best(mount_id: String = "", full: bool = false, cat: Category = Category.ANY_PERCENT) -> float:
	if mount_id.is_empty():
		mount_id = mountain_id
		full = full_route

	return float(personal_bests.get(_best_key(mount_id, full, cat), {}).get("final_time", -1.0))


## Where a best is filed. (Bests filed before this layout, under
## "mountain:CATEGORY", counted any ended run, deaths included; they are not
## read.)
static func _best_key(mount_id: String, full: bool, cat: Category) -> String:
	return "%s|%s|%s" % [mount_id, "full" if full else "descent", Category.keys()[cat]]


## The splits of the best run on a mountain ([{"id", "name", "time", ...}];
## empty when there is none). No mountain: the current one.
func get_pb_splits(mount_id: String = "", full: bool = false, cat: Category = Category.ANY_PERCENT) -> Array[Dictionary]:
	if mount_id.is_empty():
		mount_id = mountain_id
		full = full_route

	var splits: Array[Dictionary] = []
	var kept: Variant = personal_bests.get(_best_key(mount_id, full, cat), {}).get("splits", [])
	if kept is Array:
		for entry in kept:
			if entry is Dictionary:
				splits.append(entry)
	return splits


func _get_pb_split(split_id: String) -> float:
	for split in get_pb_splits():
		if str(split.get("id", "")) == split_id:
			return float(split.get("time", 0.0))
	return 0.0


# =============================================================================
# GOLD SPLITS
# =============================================================================

func _get_gold_split(split_id: String) -> float:
	return float(gold_splits.get(_gold_key(split_id), 0.0))


func _save_gold_split(split_id: String, time: float) -> void:
	gold_splits[_gold_key(split_id)] = time
	_save_data()


func _gold_key(split_id: String) -> String:
	return "%s|%s|%s" % [mountain_id, "full" if full_route else "descent", split_id]


# =============================================================================
# DATA PERSISTENCE
# =============================================================================

func _save_data() -> void:
	var data := {
		"personal_bests": personal_bests,
		"gold_splits": gold_splits
	}

	var file := FileAccess.open(data_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()


func _load_data() -> void:
	if not FileAccess.file_exists(data_path):
		return
	var file := FileAccess.open(data_path, FileAccess.READ)
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

	# Auto-start timer on run start. A run picked up again carries its own
	# clock, so it goes on from where it was (its splits start again)
	reset_timer()
	full_route = run_context != null and run_context.is_full_route()
	start_timer(category, mountain_id)
	if run_context != null:
		elapsed_time = run_context.real_time_elapsed
		_take_splits_from(run_context)


func _on_run_suspended(_run_context: RunContext) -> void:
	reset_timer()


func _on_run_ended(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	if state != TimerState.RUNNING:
		return

	# Validate clean return category
	if category == Category.CLEAN_RETURN:
		if outcome != GameEnums.ResolutionType.CLEAN_RETURN:
			_invalidate_run("Did not achieve clean return")

	if run_context != null:
		elapsed_time = run_context.real_time_elapsed
	stop_timer(outcome == GameEnums.ResolutionType.CLEAN_RETURN or outcome == GameEnums.ResolutionType.INJURED_RETURN)


func _on_game_state_changed(_old_state: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	# (Pauses need no handling: the run's clock does not run in them)
	if new_state == GameEnums.GameState.MAIN_MENU:
		reset_timer()


func _on_player_position(position: Vector3, _velocity: Vector3) -> void:
	if state != TimerState.RUNNING:
		return
	_check_marks(position)


## Full route: the summit is a split of its own
func _on_summit_reached(_run_context: RunContext) -> void:
	record_split("summit")


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

## A time in seconds as a clock: "12:34", or "1:02:03" from an hour up
static func format_clock(seconds: float) -> String:
	var whole := maxi(int(seconds), 0)
	if whole >= 3600:
		return "%d:%02d:%02d" % [whole / 3600, (whole / 60) % 60, whole % 60]
	return "%d:%02d" % [whole / 60, whole % 60]


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
	var prefix := "+" if delta > 0 else "-"
	return prefix + format_time(absf(delta))


## A difference in seconds as a signed clock: "+0:05", "-0:14"
static func format_delta(seconds: float) -> String:
	return ("+" if seconds >= 0.0 else "-") + format_clock(absf(seconds))


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
