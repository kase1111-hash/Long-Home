class_name PlayerController
extends CharacterBody3D
## Main player controller handling movement, states, and interaction with terrain
## Central hub for player-related systems

# =============================================================================
# SIGNALS
# =============================================================================

signal state_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState)
signal position_updated(position: Vector3, velocity: Vector3)
signal stability_changed(stability: float, posture: GameEnums.PostureState)
signal micro_slip_occurred(severity: float)

# =============================================================================
# EXPORTS
# =============================================================================

@export_group("Movement")
@export var base_walk_speed: float = 2.0
@export var base_run_speed: float = 4.0
@export var downclimb_speed: float = 0.8
@export var traverse_speed: float = 1.2

@export_group("Physics")
@export var gravity: float = 9.8
@export var fall_acceleration: float = 20.0
@export var ground_friction: float = 8.0
@export var air_friction: float = 0.5

@export_group("Stability")
@export var base_stability: float = 1.0
@export var micro_slip_threshold: float = 0.4
@export var fall_threshold: float = 0.15

# =============================================================================
# COMPONENTS
# =============================================================================

var movement: PlayerMovement
var posture: PostureSystem
var input_handler: PlayerInput
var state_machine: PlayerStateMachine

# =============================================================================
# STATE
# =============================================================================

## Current movement state
var current_state: GameEnums.PlayerMovementState = GameEnums.PlayerMovementState.STANDING

## Reference to terrain service
var terrain_service: TerrainService

## Current terrain cell under player
var current_cell: TerrainCell

## Current body state (from RunContext)
var body_state: BodyState

## Current gear state
var gear_state: GearState

## Is the player grounded
var is_grounded: bool = true

## Current stability value (0-1)
var stability: float = 1.0

## Current posture state
var posture_state: GameEnums.PostureState = GameEnums.PostureState.STABLE

## Accumulated input delay from fatigue
var input_delay_buffer: float = 0.0

## Time in current state
var state_time: float = 0.0

## Last position for velocity calculation
var last_position: Vector3 = Vector3.ZERO
## Whether last_position has been initialized with actual player position
var _last_position_initialized: bool = false

## Calculated velocity (smoother than CharacterBody3D.velocity for some uses)
var smooth_velocity: Vector3 = Vector3.ZERO

# =============================================================================
# CACHED REFERENCES
# =============================================================================

@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var camera_pivot: Node3D = $CameraPivot
@onready var player_mesh: Node3D = $PlayerMesh


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	# Initialize components
	_setup_components()

	# Get services
	ServiceLocator.get_service_async("TerrainService", _on_terrain_service_ready)

	# Register as service
	ServiceLocator.register_service("PlayerController", self)

	# Connect to EventBus
	_connect_signals()

	print("[PlayerController] Initialized")


func _setup_components() -> void:
	movement = PlayerMovement.new(self)
	posture = PostureSystem.new(self)
	input_handler = PlayerInput.new(self)
	state_machine = PlayerStateMachine.new(self)

	add_child(movement)
	add_child(posture)
	add_child(input_handler)
	add_child(state_machine)


func _connect_signals() -> void:
	state_changed.connect(_on_state_changed)
	micro_slip_occurred.connect(_on_micro_slip)


func _on_terrain_service_ready(service: Object) -> void:
	terrain_service = service as TerrainService
	print("[PlayerController] Connected to TerrainService")


# =============================================================================
# PHYSICS PROCESS
# =============================================================================

func _physics_process(delta: float) -> void:
	if terrain_service == null:
		return

	# Update terrain cell
	_update_terrain_cell()

	# Process input with delay
	_process_input(delta)

	# Update posture and stability
	posture.update(delta)

	# Update state machine
	state_machine.update(delta)

	# Apply movement based on state
	movement.update(delta)

	# Apply gravity and move
	_apply_physics(delta)

	# Update tracking
	_update_tracking(delta)


func _update_terrain_cell() -> void:
	if terrain_service:
		current_cell = terrain_service.get_cell_at(global_position)


func _process_input(delta: float) -> void:
	# Get input delay from body state
	var delay := 0.0
	if body_state:
		delay = body_state.get_input_delay()

	input_handler.update(delta, delay)


func _apply_physics(delta: float) -> void:
	# Check if grounded
	is_grounded = is_on_floor()

	if not is_grounded:
		# Apply gravity
		velocity.y -= gravity * delta

		# Air friction
		velocity.x *= 1.0 - (air_friction * delta)
		velocity.z *= 1.0 - (air_friction * delta)
	else:
		# Ground friction when not moving
		if input_handler.move_input.length() < 0.1:
			var friction_force := ground_friction * delta
			velocity.x *= max(0, 1.0 - friction_force)
			velocity.z *= max(0, 1.0 - friction_force)

	# Move and slide
	move_and_slide()

	# Check for falling
	if not is_grounded and velocity.y < -10.0:
		if current_state != GameEnums.PlayerMovementState.FALLING:
			change_state(GameEnums.PlayerMovementState.FALLING)


func _update_tracking(delta: float) -> void:
	# Calculate smooth velocity (skip first frame to avoid spawn-position spike)
	if _last_position_initialized:
		smooth_velocity = (global_position - last_position) / delta
	else:
		_last_position_initialized = true
	last_position = global_position

	# Update state time
	state_time += delta

	# Emit position update (throttled)
	if Engine.get_physics_frames() % 3 == 0:
		position_updated.emit(global_position, smooth_velocity)
		EventBus.player_position_updated.emit(global_position, smooth_velocity)


# =============================================================================
# STATE MANAGEMENT
# =============================================================================

## Change to a new movement state
func change_state(new_state: GameEnums.PlayerMovementState) -> void:
	if new_state == current_state:
		return

	var old_state := current_state
	current_state = new_state
	state_time = 0.0

	state_machine.transition_to(new_state)

	state_changed.emit(old_state, new_state)
	EventBus.player_movement_changed.emit(old_state, new_state)


## Check if a state transition is valid
func can_transition_to(new_state: GameEnums.PlayerMovementState) -> bool:
	return state_machine.can_transition_to(current_state, new_state)


# =============================================================================
# MOVEMENT QUERIES
# =============================================================================

## Get current movement speed based on state and conditions
func get_current_speed() -> float:
	var base_speed := base_walk_speed

	match current_state:
		GameEnums.PlayerMovementState.WALKING:
			base_speed = base_walk_speed
		GameEnums.PlayerMovementState.DOWNCLIMBING:
			base_speed = downclimb_speed
		GameEnums.PlayerMovementState.TRAVERSING:
			base_speed = traverse_speed
		GameEnums.PlayerMovementState.RESTING:
			base_speed = 0.0
		GameEnums.PlayerMovementState.INCAPACITATED:
			base_speed = 0.0

	# Apply modifiers
	var speed := base_speed

	# Terrain modifier
	if current_cell:
		speed *= _get_terrain_speed_modifier()

	# Body state modifier
	if body_state:
		speed *= body_state.get_movement_modifier()

	# Gear weight modifier
	if gear_state:
		speed *= gear_state.get_weight_modifier()

	# Stability modifier
	speed *= stability

	return speed


func _get_terrain_speed_modifier() -> float:
	if current_cell == null:
		return 1.0

	var modifier := 1.0

	# Slope affects speed
	var slope := current_cell.slope_angle
	if slope > 20:
		modifier *= 1.0 - ((slope - 20) / 70.0) * 0.5

	# Surface affects speed
	match current_cell.surface_type:
		GameEnums.SurfaceType.ICE:
			modifier *= 0.6
		GameEnums.SurfaceType.SNOW_POWDER:
			modifier *= 0.7
		GameEnums.SurfaceType.SCREE:
			modifier *= 0.75
		GameEnums.SurfaceType.ROCK_WET:
			modifier *= 0.85

	return modifier


## Get the direction the player is facing
func get_facing_direction() -> Vector3:
	return -global_transform.basis.z


## Get the downhill direction at current position
func get_downhill_direction() -> Vector3:
	if current_cell:
		return current_cell.slope_direction
	return Vector3.ZERO


## Check if player can slide from current position
func can_initiate_slide() -> bool:
	if current_cell == null:
		return false

	return (
		current_cell.is_slideable and
		current_state in [
			GameEnums.PlayerMovementState.STANDING,
			GameEnums.PlayerMovementState.WALKING
		] and
		stability > 0.3
	)


## Check if rope is required at current position
func needs_rope() -> bool:
	if current_cell == null:
		return false
	return current_cell.requires_rope


# =============================================================================
# STABILITY
# =============================================================================

## Update stability value
func set_stability(value: float) -> void:
	var old_stability := stability
	stability = clampf(value, 0.0, 1.0)

	# Update posture state
	var new_posture := GameEnums.PostureState.STABLE
	if stability < fall_threshold:
		new_posture = GameEnums.PostureState.FALLING
	elif stability < micro_slip_threshold:
		new_posture = GameEnums.PostureState.UNSTABLE
	elif stability < 0.7:
		new_posture = GameEnums.PostureState.MARGINAL

	if new_posture != posture_state:
		posture_state = new_posture
		stability_changed.emit(stability, posture_state)
		EventBus.player_stability_changed.emit(stability, posture_state)


## Trigger a micro-slip
func trigger_micro_slip(severity: float) -> void:
	micro_slip_occurred.emit(severity)
	EventBus.micro_slip_occurred.emit(severity, global_position)

	# Camera shake would be triggered here
	# Audio cue would be triggered here


# =============================================================================
# BODY & GEAR STATE
# =============================================================================

## Set body state reference (from RunContext)
func set_body_state(state: BodyState) -> void:
	body_state = state


## Set gear state reference
func set_gear_state(state: GearState) -> void:
	gear_state = state


## Add fatigue from exertion
func add_fatigue(amount: float) -> void:
	if body_state:
		body_state.add_fatigue(amount)
		EventBus.body_state_updated.emit(body_state)


## Check if player is exhausted
func is_exhausted() -> bool:
	if body_state:
		return body_state.fatigue >= GameEnums.FATIGUE_THRESHOLDS.critical
	return false


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_state_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	print("[PlayerController] State: %s -> %s" % [
		GameEnums.PlayerMovementState.keys()[old_state],
		GameEnums.PlayerMovementState.keys()[new_state]
	])

	# Emit camera signal for state changes
	match new_state:
		GameEnums.PlayerMovementState.SLIDING:
			EventBus.emit_camera_signal(GameEnums.CameraSignal.SLIDE_ENTRY, 1.0)
		GameEnums.PlayerMovementState.FALLING:
			EventBus.emit_camera_signal(GameEnums.CameraSignal.MICRO_SLIP, 1.0)


func _on_micro_slip(severity: float) -> void:
	# Record incident
	EventBus.record_incident("micro_slip", {
		"severity": severity,
		"stability": stability,
		"slope": current_cell.slope_angle if current_cell else 0.0
	})


# =============================================================================
# DEBUG
# =============================================================================

func get_debug_info() -> Dictionary:
	return {
		"state": GameEnums.PlayerMovementState.keys()[current_state],
		"position": global_position,
		"velocity": velocity,
		"smooth_velocity": smooth_velocity,
		"speed": smooth_velocity.length(),
		"is_grounded": is_grounded,
		"stability": stability,
		"posture": GameEnums.PostureState.keys()[posture_state],
		"terrain_zone": GameEnums.TerrainZone.keys()[current_cell.terrain_zone] if current_cell else "unknown",
		"slope_angle": current_cell.slope_angle if current_cell else 0.0,
		"fatigue": body_state.fatigue if body_state else 0.0
	}
