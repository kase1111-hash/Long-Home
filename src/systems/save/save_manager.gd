class_name SaveManager
extends Node
## Central save/load system for all persistent game data
## Manages player profile, run history, and progression
##
## Design Philosophy:
## - Every run teaches something worth remembering
## - Progress is knowledge, not power
## - Failure is data, not punishment

# =============================================================================
# SIGNALS
# =============================================================================

signal save_started()
signal save_completed(success: bool)
signal load_started()
signal load_completed(success: bool)
signal profile_loaded(profile: PlayerProfile)
signal autosave_triggered()

# =============================================================================
# CONFIGURATION
# =============================================================================

## Save file paths
const PROFILE_PATH := "user://player_profile.json"
const HISTORY_PATH := "user://run_history.json"
const ROUTES_PATH := "user://familiar_routes.json"
const SETTINGS_PATH := "user://settings.json"
const BACKUP_SUFFIX := ".backup"

## Autosave interval (seconds)
const AUTOSAVE_INTERVAL := 300.0  # 5 minutes

## Maximum run history entries
const MAX_HISTORY_ENTRIES := 100

## Maximum familiar routes per mountain
const MAX_ROUTES_PER_MOUNTAIN := 10

# =============================================================================
# STATE
# =============================================================================

## Player profile
var player_profile: PlayerProfile

## Run history
var run_history: RunHistory

## Route memory
var route_memory: RouteMemory

## Progression tracker
var progression: ProgressionTracker

## Is save system initialized
var is_initialized: bool = false

## Autosave timer
var autosave_timer: float = 0.0

## Pending save flag
var save_pending: bool = false

# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("SaveManager", self)

	# Initialize subsystems
	player_profile = PlayerProfile.new()
	run_history = RunHistory.new()
	route_memory = RouteMemory.new()
	progression = ProgressionTracker.new()

	# Connect to game events
	_connect_signals()

	# Load existing data
	load_all()

	print("[SaveManager] Initialized")


func _connect_signals() -> void:
	EventBus.run_ended.connect(_on_run_ended)
	EventBus.game_state_changed.connect(_on_game_state_changed)


func _process(delta: float) -> void:
	if not is_initialized:
		return

	# Autosave check
	autosave_timer += delta
	if autosave_timer >= AUTOSAVE_INTERVAL:
		autosave_timer = 0.0
		if save_pending:
			_perform_autosave()


# =============================================================================
# SAVE OPERATIONS
# =============================================================================

## Save all data
func save_all() -> bool:
	save_started.emit()

	var success := true

	# Save each component
	success = _save_profile() and success
	success = _save_history() and success
	success = _save_routes() and success

	save_pending = false
	save_completed.emit(success)

	if success:
		print("[SaveManager] All data saved successfully")
	else:
		push_warning("[SaveManager] Some data failed to save")

	return success


func _save_profile() -> bool:
	return _save_json(PROFILE_PATH, player_profile.to_dict())


func _save_history() -> bool:
	return _save_json(HISTORY_PATH, run_history.to_dict())


func _save_routes() -> bool:
	return _save_json(ROUTES_PATH, route_memory.to_dict())


func _save_json(path: String, data: Dictionary) -> bool:
	# Create backup of existing file
	if FileAccess.file_exists(path):
		var backup_path := path + BACKUP_SUFFIX
		DirAccess.copy_absolute(path, backup_path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[SaveManager] Failed to open %s for writing" % path)
		return false

	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


func _perform_autosave() -> void:
	autosave_triggered.emit()
	save_all()


# =============================================================================
# LOAD OPERATIONS
# =============================================================================

## Load all data
func load_all() -> bool:
	load_started.emit()

	var success := true

	# Load each component
	success = _load_profile() and success
	success = _load_history() and success
	success = _load_routes() and success

	is_initialized = true
	load_completed.emit(success)

	if success:
		print("[SaveManager] All data loaded successfully")
	else:
		print("[SaveManager] Some data failed to load (may be first run)")

	profile_loaded.emit(player_profile)
	return success


func _load_profile() -> bool:
	var data := _load_json(PROFILE_PATH)
	if data.is_empty():
		# First run - create new profile
		player_profile = PlayerProfile.new()
		player_profile.created_at = Time.get_unix_time_from_system()
		return true

	player_profile = PlayerProfile.from_dict(data)
	return player_profile != null


func _load_history() -> bool:
	var data := _load_json(HISTORY_PATH)
	if data.is_empty():
		run_history = RunHistory.new()
		return true

	run_history = RunHistory.from_dict(data)
	return run_history != null


func _load_routes() -> bool:
	var data := _load_json(ROUTES_PATH)
	if data.is_empty():
		route_memory = RouteMemory.new()
		return true

	route_memory = RouteMemory.from_dict(data)
	return route_memory != null


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		# Try backup
		var backup_path := path + BACKUP_SUFFIX
		if FileAccess.file_exists(backup_path):
			file = FileAccess.open(backup_path, FileAccess.READ)

		if file == null:
			push_error("[SaveManager] Failed to open %s for reading" % path)
			return {}

	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()

	if error != OK:
		push_error("[SaveManager] Failed to parse %s: %s" % [path, json.get_error_message()])
		return {}

	return json.data


# =============================================================================
# RUN RECORDING
# =============================================================================

func _on_run_ended(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	# Record the run
	var entry := run_history.record_run(run_context, outcome)

	# Update player profile stats
	player_profile.update_from_run(run_context, outcome)

	# Store familiar route if successful
	if outcome <= GameEnums.ResolutionType.INJURED_RETURN:
		var planned_route = run_context.get_meta("planned_route", PackedVector3Array())
		if planned_route.size() > 0:
			route_memory.store_route(run_context.mountain_id, planned_route, outcome)

	# Update progression
	progression.update_from_run(run_context, outcome)

	# Mark save pending
	save_pending = true


func _on_game_state_changed(old_state: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	# Save when returning to main menu
	if new_state == GameEnums.GameState.MAIN_MENU:
		if save_pending:
			save_all()


# =============================================================================
# PUBLIC API
# =============================================================================

func get_profile() -> PlayerProfile:
	return player_profile


func get_history() -> RunHistory:
	return run_history


func get_route_memory() -> RouteMemory:
	return route_memory


func get_progression() -> ProgressionTracker:
	return progression


## Get stats summary for display
func get_stats_summary() -> Dictionary:
	return {
		"total_runs": player_profile.total_runs,
		"successful_runs": player_profile.successful_runs,
		"total_descent": player_profile.total_descent_meters,
		"play_time": player_profile.total_play_time,
		"mountains_completed": player_profile.mountains_completed.size(),
		"best_streak": player_profile.best_streak
	}


## Check if this is a first-time player
func is_new_player() -> bool:
	return player_profile.total_runs == 0


## Reset all progress (with confirmation)
func reset_progress() -> void:
	player_profile = PlayerProfile.new()
	player_profile.created_at = Time.get_unix_time_from_system()
	run_history = RunHistory.new()
	route_memory = RouteMemory.new()
	progression = ProgressionTracker.new()

	save_all()
	print("[SaveManager] All progress reset")


## Export save data for backup
func export_save_data() -> Dictionary:
	return {
		"version": "1.0",
		"exported_at": Time.get_unix_time_from_system(),
		"profile": player_profile.to_dict(),
		"history": run_history.to_dict(),
		"routes": route_memory.to_dict(),
		"progression": progression.to_dict()
	}


## Import save data from backup
func import_save_data(data: Dictionary) -> bool:
	if not data.has("version"):
		push_error("[SaveManager] Invalid save data format")
		return false

	if data.has("profile"):
		player_profile = PlayerProfile.from_dict(data["profile"])
	if data.has("history"):
		run_history = RunHistory.from_dict(data["history"])
	if data.has("routes"):
		route_memory = RouteMemory.from_dict(data["routes"])
	if data.has("progression"):
		progression = ProgressionTracker.from_dict(data["progression"])

	save_all()
	return true
