class_name TutorialManager
extends Node
## Central controller for the first-time player experience
## Manages the knife edge opening, instructor, and organic teaching
##
## Design Philosophy:
## - No UI popups, button prompts, or text boxes
## - Teaching through environment and consequence
## - Instructor provides diegetic guidance
## - Hard mode variant: instructor falls, player must rescue

# =============================================================================
# SIGNALS
# =============================================================================

signal tutorial_started(is_hard_mode: bool)
signal tutorial_phase_changed(phase: TutorialPhase)
signal tutorial_completed(rescued_instructor: bool)
signal lesson_learned(lesson: String)
signal instructor_accident_occurred()

# =============================================================================
# ENUMS
# =============================================================================

enum TutorialPhase {
	NONE,
	SPAWN,                 # Initial spawn on knife edge
	ORIENTATION,           # "Take a breath. Look around."
	FIRST_STEPS,           # Learning to move safely
	TERRAIN_READING,       # Instructor points at terrain
	TIME_AWARENESS,        # "We've got light. Not a lot."
	SLIDE_DEMONSTRATION,   # Instructor demonstrates slide
	SLIDE_ATTEMPT,         # Player tries sliding
	ROPE_LESSON,           # Optional rope use
	DESCENT_BEGIN,         # Actual descent starts
	# Hard mode phases
	INSTRUCTOR_ACCIDENT,   # Instructor falls
	SOLO_DESCENT,          # Player alone
	CABIN_DISCOVERY,       # Find the cabin
	RESCUE_ATTEMPT,        # Rescue the instructor
	RESOLUTION             # Tutorial complete
}

enum TutorialDifficulty {
	NORMAL,    # Full instructor guidance
	HARD       # Instructor accident variant
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Timing")
## Delay before instructor speaks after spawn
@export var initial_speak_delay: float = 2.0
## Minimum time between instructor lines
@export var line_spacing: float = 1.5
## Time to wait for player action before hint
@export var hint_delay: float = 8.0

@export_group("Knife Edge")
## Width of the knife edge ridge (meters)
@export var knife_edge_width: float = 1.2
## Drop distance that triggers fall
@export var fatal_drop_distance: float = 3.0

@export_group("Hard Mode")
## Probability of instructor accident in hard mode
@export var accident_probability: float = 1.0
## Time into descent before accident can occur
@export var accident_delay_min: float = 30.0
@export var accident_delay_max: float = 60.0

# =============================================================================
# STATE
# =============================================================================

## Current tutorial phase
var current_phase: TutorialPhase = TutorialPhase.NONE

## Tutorial difficulty
var difficulty: TutorialDifficulty = TutorialDifficulty.NORMAL

## Is tutorial active
var is_active: bool = false

## Instructor reference
var instructor: Instructor

## Player reference
var player: PlayerController

## Lessons the player has learned
var lessons_learned: Array[String] = []

## Phase start time
var phase_start_time: float = 0.0

## Time in current phase
var phase_time: float = 0.0

## Has player backed up (triggers first slip)
var player_backed_up: bool = false

## Has player moved carelessly
var careless_movement_count: int = 0

## Accident scheduled time (hard mode)
var accident_time: float = -1.0

## Has instructor fallen
var instructor_fallen: bool = false

## Has player found cabin
var cabin_found: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("TutorialManager", self)
	_connect_signals()
	print("[TutorialManager] Initialized")


func _connect_signals() -> void:
	EventBus.descent_ready.connect(_on_descent_ready)
	EventBus.player_movement_changed.connect(_on_player_movement_changed)
	EventBus.player_position_updated.connect(_on_player_position_updated)
	EventBus.micro_slip_occurred.connect(_on_micro_slip)
	EventBus.slide_ended.connect(_on_slide_ended)


# =============================================================================
# TUTORIAL LIFECYCLE
# =============================================================================

## Start the tutorial
func start_tutorial(hard_mode: bool = false) -> void:
	is_active = true
	difficulty = TutorialDifficulty.HARD if hard_mode else TutorialDifficulty.NORMAL
	lessons_learned.clear()
	instructor_fallen = false
	cabin_found = false

	# Get player reference
	player = ServiceLocator.get_service("PlayerController") as PlayerController

	# Schedule accident if hard mode
	if difficulty == TutorialDifficulty.HARD:
		accident_time = randf_range(accident_delay_min, accident_delay_max)

	tutorial_started.emit(hard_mode)
	_transition_to_phase(TutorialPhase.SPAWN)

	print("[TutorialManager] Tutorial started (hard_mode=%s)" % hard_mode)


## End the tutorial
func end_tutorial(success: bool = true) -> void:
	is_active = false

	var rescued := instructor_fallen and instructor != null and instructor.is_rescued
	tutorial_completed.emit(rescued)

	print("[TutorialManager] Tutorial completed (rescued=%s)" % rescued)


## Skip tutorial (for returning players)
func skip_tutorial() -> void:
	is_active = false
	_transition_to_phase(TutorialPhase.NONE)
	print("[TutorialManager] Tutorial skipped")


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_active:
		return

	phase_time += delta

	# Phase-specific updates
	match current_phase:
		TutorialPhase.SPAWN:
			_update_spawn_phase(delta)
		TutorialPhase.ORIENTATION:
			_update_orientation_phase(delta)
		TutorialPhase.FIRST_STEPS:
			_update_first_steps_phase(delta)
		TutorialPhase.TERRAIN_READING:
			_update_terrain_reading_phase(delta)
		TutorialPhase.SLIDE_DEMONSTRATION:
			_update_slide_demo_phase(delta)
		TutorialPhase.DESCENT_BEGIN:
			_update_descent_phase(delta)


func _update_spawn_phase(delta: float) -> void:
	# Wait for initial delay then transition
	if phase_time >= initial_speak_delay:
		_transition_to_phase(TutorialPhase.ORIENTATION)


func _update_orientation_phase(delta: float) -> void:
	# Check if player has looked around
	if instructor and instructor.has_given_line("orientation"):
		if phase_time > 5.0:  # Give player time to look
			_transition_to_phase(TutorialPhase.FIRST_STEPS)


func _update_first_steps_phase(delta: float) -> void:
	# Check if player has moved safely
	if lessons_learned.has("safe_movement"):
		_transition_to_phase(TutorialPhase.TERRAIN_READING)
	elif phase_time > hint_delay and not lessons_learned.has("back_up_danger"):
		# Player hasn't moved - instructor gives subtle hint
		if instructor:
			instructor.give_hint("careful_movement")


func _update_terrain_reading_phase(delta: float) -> void:
	if phase_time > 6.0:
		_transition_to_phase(TutorialPhase.TIME_AWARENESS)


func _update_slide_demo_phase(delta: float) -> void:
	if instructor and instructor.has_completed_demonstration():
		_transition_to_phase(TutorialPhase.SLIDE_ATTEMPT)


func _update_descent_phase(delta: float) -> void:
	# Check for accident trigger in hard mode
	if difficulty == TutorialDifficulty.HARD and not instructor_fallen:
		if phase_time >= accident_time:
			_trigger_instructor_accident()


# =============================================================================
# PHASE TRANSITIONS
# =============================================================================

func _transition_to_phase(new_phase: TutorialPhase) -> void:
	var old_phase := current_phase
	current_phase = new_phase
	phase_time = 0.0
	phase_start_time = Time.get_ticks_msec() / 1000.0

	tutorial_phase_changed.emit(new_phase)

	# Trigger phase entry actions
	match new_phase:
		TutorialPhase.ORIENTATION:
			_enter_orientation()
		TutorialPhase.FIRST_STEPS:
			_enter_first_steps()
		TutorialPhase.TERRAIN_READING:
			_enter_terrain_reading()
		TutorialPhase.TIME_AWARENESS:
			_enter_time_awareness()
		TutorialPhase.SLIDE_DEMONSTRATION:
			_enter_slide_demonstration()
		TutorialPhase.SLIDE_ATTEMPT:
			_enter_slide_attempt()
		TutorialPhase.DESCENT_BEGIN:
			_enter_descent_begin()
		TutorialPhase.INSTRUCTOR_ACCIDENT:
			_enter_instructor_accident()

	print("[TutorialManager] Phase: %s -> %s" % [
		TutorialPhase.keys()[old_phase],
		TutorialPhase.keys()[new_phase]
	])


func _enter_orientation() -> void:
	if instructor:
		instructor.speak("orientation", "Alright. Take a breath. You're standing where people usually stop thinking.")
		await get_tree().create_timer(line_spacing + 2.0).timeout
		instructor.speak("look_around", "Look around—slowly. And don't back up.")


func _enter_first_steps() -> void:
	# Player can now move - instructor watches
	pass


func _enter_terrain_reading() -> void:
	if instructor:
		instructor.speak("terrain_intro", "The way down isn't where you think it is.")
		await get_tree().create_timer(line_spacing).timeout
		instructor.gesture_at_terrain()


func _enter_time_awareness() -> void:
	if instructor:
		instructor.speak("time_warning", "We've got light. Not a lot.")
		await get_tree().create_timer(3.0).timeout
		_transition_to_phase(TutorialPhase.SLIDE_DEMONSTRATION)


func _enter_slide_demonstration() -> void:
	if instructor:
		instructor.speak("slide_intro", "This saves time if you respect it.")
		await get_tree().create_timer(line_spacing).timeout
		instructor.demonstrate_slide()


func _enter_slide_attempt() -> void:
	if instructor:
		instructor.speak("slide_invitation", "Your call.")


func _enter_descent_begin() -> void:
	# Tutorial is effectively complete for normal mode
	if difficulty == TutorialDifficulty.NORMAL:
		# Continue with instructor as guide
		pass


func _enter_instructor_accident() -> void:
	instructor_accident_occurred.emit()
	# Instructor entity handles the fall animation/audio


# =============================================================================
# ORGANIC TEACHING
# =============================================================================

## Record that a lesson was learned
func record_lesson(lesson: String) -> void:
	if not lessons_learned.has(lesson):
		lessons_learned.append(lesson)
		lesson_learned.emit(lesson)
		print("[TutorialManager] Lesson learned: %s" % lesson)


## Check if player is on the knife edge
func _is_on_knife_edge() -> bool:
	if player == null:
		return false
	# Check if player is within knife edge bounds
	# This would use actual terrain data in practice
	return current_phase in [TutorialPhase.SPAWN, TutorialPhase.ORIENTATION, TutorialPhase.FIRST_STEPS]


## Trigger a teaching slip (player backed up or moved carelessly)
func _trigger_teaching_slip(fatal: bool = false) -> void:
	if fatal:
		# Immediate fall - reload with no commentary
		print("[TutorialManager] Fatal teaching slip - reloading")
		# The game would reload here
	else:
		# Non-fatal slip - lesson learned
		if player:
			player.trigger_micro_slip(0.6)
		record_lesson("movement_danger")


# =============================================================================
# HARD MODE: INSTRUCTOR ACCIDENT
# =============================================================================

func _trigger_instructor_accident() -> void:
	if instructor == null or instructor_fallen:
		return

	instructor_fallen = true
	_transition_to_phase(TutorialPhase.INSTRUCTOR_ACCIDENT)

	# Instructor falls
	instructor.trigger_accident()

	# Player hears scream, then silence
	await get_tree().create_timer(2.0).timeout

	# Now player is alone
	_transition_to_phase(TutorialPhase.SOLO_DESCENT)


## Called when player finds the cabin
func on_cabin_found() -> void:
	if not cabin_found and instructor_fallen:
		cabin_found = true
		_transition_to_phase(TutorialPhase.CABIN_DISCOVERY)


## Called when player rescues instructor
func on_instructor_rescued() -> void:
	if instructor_fallen and instructor:
		instructor.set_rescued(true)
		_transition_to_phase(TutorialPhase.RESOLUTION)

		# Instructor's final line
		await get_tree().create_timer(1.0).timeout
		instructor.speak("rescued", "Most people don't learn this until it's too late.")


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_descent_ready() -> void:
	# Auto-start tutorial for new players
	# In practice, this would check player save data
	pass


func _on_player_movement_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	if not is_active:
		return

	# Check for first safe movement
	if current_phase == TutorialPhase.FIRST_STEPS:
		if new_state == GameEnums.PlayerMovementState.WALKING:
			record_lesson("safe_movement")


func _on_player_position_updated(position: Vector3, velocity: Vector3) -> void:
	if not is_active:
		return

	# Check if player backed up on knife edge
	if _is_on_knife_edge() and not player_backed_up:
		# Check for backward movement
		if velocity.length() > 0.5:
			var facing := player.get_facing_direction() if player else Vector3.FORWARD
			var move_dir := velocity.normalized()
			var dot := facing.dot(move_dir)

			if dot < -0.5:  # Moving backward
				player_backed_up = true
				record_lesson("back_up_danger")
				_trigger_teaching_slip(true)  # Fatal slip - reload


func _on_micro_slip(severity: float, _position: Vector3) -> void:
	if not is_active:
		return

	careless_movement_count += 1

	# Instructor comments on careless movement
	if instructor and careless_movement_count == 1:
		instructor.speak("slip_comment", "Easy. You feel that? That's the edge reminding you.")


func _on_slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	if not is_active:
		return

	if current_phase == TutorialPhase.SLIDE_ATTEMPT:
		match outcome:
			GameEnums.SlideOutcome.CLEAN_STOP:
				record_lesson("slide_success")
				_transition_to_phase(TutorialPhase.DESCENT_BEGIN)
			GameEnums.SlideOutcome.TUMBLE_STOP:
				record_lesson("slide_danger")
				# Instructor doesn't comment - let player feel it


# =============================================================================
# INSTRUCTOR MANAGEMENT
# =============================================================================

## Set instructor reference
func set_instructor(instr: Instructor) -> void:
	instructor = instr


## Create and spawn instructor at position
func spawn_instructor(position: Vector3, rotation: Vector3 = Vector3.ZERO) -> Instructor:
	# This would instantiate the Instructor scene
	# For now, create a basic instructor node
	instructor = Instructor.new()
	instructor.global_position = position
	instructor.rotation = rotation

	return instructor


# =============================================================================
# QUERIES
# =============================================================================

func is_tutorial_active() -> bool:
	return is_active


func get_current_phase() -> TutorialPhase:
	return current_phase


func has_learned(lesson: String) -> bool:
	return lessons_learned.has(lesson)


func is_hard_mode() -> bool:
	return difficulty == TutorialDifficulty.HARD


func get_progress() -> float:
	# Return 0-1 progress through tutorial
	var total_phases := TutorialPhase.RESOLUTION
	return float(current_phase) / float(total_phases)


func get_summary() -> Dictionary:
	return {
		"active": is_active,
		"phase": TutorialPhase.keys()[current_phase],
		"difficulty": TutorialDifficulty.keys()[difficulty],
		"lessons_learned": lessons_learned,
		"instructor_fallen": instructor_fallen,
		"cabin_found": cabin_found
	}
