class_name DroneService
extends Node
## Central coordinator for the drone camera system
## Interface for Camera Director AI to control drone
##
## Design Philosophy:
## - Provides high-level commands for camera work
## - Manages drone lifecycle and mode switching
## - Bridges between game events and camera behavior
## - Foundation for Camera Director AI integration

# =============================================================================
# SIGNALS
# =============================================================================

signal drone_ready()
signal drone_mode_changed(mode: GameEnums.DroneMode)
signal shot_executed(shot_type: String)
signal subject_lost()
signal subject_acquired()

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Spawning")
## Initial spawn offset from subject
@export var spawn_offset: Vector3 = Vector3(5, 8, 10)
## Auto-activate on descent start
@export var auto_activate: bool = true

@export_group("Modes")
## Default mode
@export var default_mode: GameEnums.DroneMode = GameEnums.DroneMode.SPECTATOR
## Enable scout mode (easy mode only)
@export var scout_mode_available: bool = true

# =============================================================================
# COMPONENTS
# =============================================================================

## Main drone entity
var drone: DroneEntity

## Drone camera
var drone_camera: DroneCamera

## Is drone system initialized
var is_initialized: bool = false


# =============================================================================
# STATE
# =============================================================================

## Current shot intent
var current_intent: GameEnums.ShotIntent = GameEnums.ShotIntent.CONTEXT

## Is tracking subject
var is_tracking: bool = false

## Subject being filmed
var filming_subject: Node3D

## Time in current shot
var shot_time: float = 0.0

## Last subject position (for lost detection)
var last_subject_position: Vector3 = Vector3.ZERO


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("DroneService", self)
	_connect_events()
	print("[DroneService] Initialized")


func _connect_events() -> void:
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.descent_ready.connect(_on_descent_ready)
	EventBus.run_ended.connect(_on_run_ended)

	# Camera signals for shot changes
	EventBus.slide_started.connect(_on_slide_started)
	EventBus.slide_ended.connect(_on_slide_ended)
	EventBus.fatal_event_started.connect(_on_fatal_event_started)
	EventBus.fatal_phase_changed.connect(_on_fatal_phase_changed)


## Initialize the drone system
func initialize() -> void:
	if is_initialized:
		return

	_spawn_drone()
	is_initialized = true
	drone_ready.emit()

	print("[DroneService] Drone system ready")


func _spawn_drone() -> void:
	# Create drone entity
	drone = DroneEntity.new()
	drone.name = "DroneEntity"
	add_child(drone)

	# Create drone camera
	drone_camera = DroneCamera.new()
	drone_camera.name = "DroneCamera"
	drone.add_child(drone_camera)
	drone.drone_camera = drone_camera

	# Get subject (player)
	ServiceLocator.get_service_async("PlayerController", func(player):
		filming_subject = player
		drone.set_subject(player)
		drone_camera.set_target(player)
		is_tracking = true
		subject_acquired.emit()
	)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_initialized or drone == null:
		return

	shot_time += delta
	_update_tracking()
	_update_camera_from_weather()


func _update_tracking() -> void:
	if filming_subject == null:
		return

	var current_pos := filming_subject.global_position

	# Check if subject moved significantly
	if current_pos.distance_to(last_subject_position) > 1.0:
		last_subject_position = current_pos


func _update_camera_from_weather() -> void:
	var weather := ServiceLocator.get_service("WeatherService") as WeatherService
	if weather and drone_camera:
		var wind_strength := weather.wind_speed / weather.max_wind_speed
		drone_camera.set_wind_strength(wind_strength)

	# Update signal strength
	if drone and drone_camera:
		drone_camera.set_signal_strength(drone.get_signal_strength())


# =============================================================================
# DRONE CONTROL
# =============================================================================

## Activate the drone
func activate(mode: GameEnums.DroneMode = GameEnums.DroneMode.SPECTATOR) -> void:
	if drone == null:
		initialize()

	drone.activate(mode)
	drone_mode_changed.emit(mode)


## Deactivate the drone
func deactivate() -> void:
	if drone:
		drone.deactivate("service_request")


## Switch drone mode
func set_mode(mode: GameEnums.DroneMode) -> void:
	if drone:
		drone.set_mode(mode)
		drone_mode_changed.emit(mode)


## Get current mode
func get_mode() -> GameEnums.DroneMode:
	if drone:
		return drone.get_mode()
	return GameEnums.DroneMode.DISABLED


# =============================================================================
# SHOT CONTROL
# =============================================================================

## Set the current shot intent
func set_shot_intent(intent: GameEnums.ShotIntent) -> void:
	current_intent = intent
	shot_time = 0.0

	if drone_camera:
		drone_camera.set_shot_intent(intent)

	if drone and drone.controller:
		drone.controller.position_for_intent(intent)

	shot_executed.emit(GameEnums.ShotIntent.keys()[intent])


## Execute a context shot (wide, establishing)
func execute_context_shot() -> void:
	set_shot_intent(GameEnums.ShotIntent.CONTEXT)


## Execute a tension shot
func execute_tension_shot() -> void:
	set_shot_intent(GameEnums.ShotIntent.TENSION)


## Execute a commitment shot
func execute_commitment_shot() -> void:
	set_shot_intent(GameEnums.ShotIntent.COMMITMENT)


## Execute a consequence shot
func execute_consequence_shot() -> void:
	set_shot_intent(GameEnums.ShotIntent.CONSEQUENCE)


## Execute a release shot
func execute_release_shot() -> void:
	set_shot_intent(GameEnums.ShotIntent.RELEASE)


# =============================================================================
# CAMERA MOVEMENTS
# =============================================================================

## Orbit around subject
func start_orbit(radius: float = 10.0, speed: float = 0.3) -> void:
	if drone and drone.controller:
		drone.controller.start_orbit(radius, speed)


## Stop orbiting
func stop_orbit() -> void:
	if drone and drone.controller:
		drone.controller.stop_orbit()


## Hold current position
func hold_position() -> void:
	if drone and drone.controller:
		drone.controller.hold_position()


## Move to specific position
func move_to(position: Vector3, speed: float = 1.0) -> void:
	if drone:
		drone.move_to(position, speed)


## Track with offset
func track_with_offset(offset: Vector3) -> void:
	if drone and drone.controller:
		drone.controller.track_subject(offset)


## Dolly in toward subject
func dolly_in(distance: float, duration: float) -> void:
	if drone and drone.controller:
		drone.controller.dolly_in(distance, duration)


## Dolly out from subject
func dolly_out(distance: float, duration: float) -> void:
	if drone and drone.controller:
		drone.controller.dolly_out(distance, duration)


## Crane up
func crane_up(height: float, duration: float) -> void:
	if drone and drone.controller:
		drone.controller.crane_up(height, duration)


## Crane down
func crane_down(height: float, duration: float) -> void:
	if drone and drone.controller:
		drone.controller.crane_down(height, duration)


# =============================================================================
# CAMERA IMPERFECTIONS
# =============================================================================

## Make the camera miss a shot
func miss_shot(duration: float = 0.5) -> void:
	if drone_camera:
		drone_camera.miss_shot(duration)


## Make the camera arrive late
func arrive_late(delay: float = 0.3) -> void:
	if drone_camera and filming_subject:
		drone_camera.arrive_late(filming_subject.global_position, delay)


## Make the camera hesitate
func hesitate(duration: float = 0.2) -> void:
	if drone_camera:
		drone_camera.hesitate(duration)


# =============================================================================
# SPECIAL SEQUENCES
# =============================================================================

## Execute slide entry sequence
func execute_slide_sequence() -> void:
	# Pull back for slide
	execute_commitment_shot()

	# After slide starts, track from side
	await get_tree().create_timer(0.5).timeout
	if drone and drone.controller:
		drone.controller.move_to_subject_offset(Vector3(8, 3, 5), 0.8)


## Execute fatal event sequence
func execute_fatal_sequence() -> void:
	# Phase 1: Hesitate
	hesitate(0.3)

	await get_tree().create_timer(0.3).timeout

	# Phase 2: Pull back
	execute_consequence_shot()
	dolly_out(10.0, 2.0)


## Execute aftermath sequence
func execute_aftermath_sequence() -> void:
	# Hold position, look at last known subject position
	hold_position()

	await get_tree().create_timer(5.0).timeout

	# Slowly crane up
	crane_up(20.0, 5.0)


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_game_state_changed(old_state: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	match new_state:
		GameEnums.GameState.DESCENT:
			if auto_activate:
				activate(default_mode)
		GameEnums.GameState.MAIN_MENU:
			deactivate()
		GameEnums.GameState.RESOLUTION:
			# Keep drone for resolution replay
			pass


func _on_descent_ready() -> void:
	if not is_initialized:
		initialize()

	# Start with context shot
	execute_context_shot()


func _on_run_ended(_run_context: RunContext, _outcome: GameEnums.ResolutionType) -> void:
	# Drone behavior handled by fatal event system for fatalities
	pass


func _on_slide_started(entry_speed: float, slope_angle: float) -> void:
	execute_slide_sequence()


func _on_slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	match outcome:
		GameEnums.SlideOutcome.CLEAN_STOP:
			execute_release_shot()
		GameEnums.SlideOutcome.TUMBLE_STOP:
			execute_consequence_shot()
		GameEnums.SlideOutcome.TERMINAL_RUNOUT:
			execute_fatal_sequence()


func _on_fatal_event_started(phase: GameEnums.FatalPhase) -> void:
	execute_fatal_sequence()


func _on_fatal_phase_changed(old_phase: GameEnums.FatalPhase, new_phase: GameEnums.FatalPhase) -> void:
	match new_phase:
		GameEnums.FatalPhase.LOSS_OF_CONTROL:
			# Pull back as control is lost
			dolly_out(15.0, 2.0)

		GameEnums.FatalPhase.AFTERMATH:
			execute_aftermath_sequence()

		GameEnums.FatalPhase.ACKNOWLEDGMENT:
			# Final crane up and fade
			crane_up(30.0, 3.0)


# =============================================================================
# QUERIES
# =============================================================================

func is_drone_active() -> bool:
	return drone != null and drone.is_flying()


func get_drone_position() -> Vector3:
	if drone:
		return drone.global_position
	return Vector3.ZERO


func get_battery_level() -> float:
	if drone:
		return drone.get_battery_level()
	return 0.0


func get_signal_strength() -> float:
	if drone:
		return drone.get_signal_strength()
	return 0.0


func get_current_intent() -> GameEnums.ShotIntent:
	return current_intent


func get_summary() -> Dictionary:
	var summary := {
		"initialized": is_initialized,
		"active": is_drone_active(),
		"mode": GameEnums.DroneMode.keys()[get_mode()],
		"intent": GameEnums.ShotIntent.keys()[current_intent],
		"battery": get_battery_level(),
		"signal": get_signal_strength(),
		"tracking": is_tracking
	}

	if drone:
		summary.merge(drone.get_summary())

	return summary
