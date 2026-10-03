class_name PlayerController
extends CharacterBody3D
## Main player controller handling movement, states, and interaction with terrain
## Central hub for player-related systems
##
## Physics ownership per movement state:
##   STANDING / WALKING / RESTING   PlayerMovement steers, gravity and ground
##                                  friction act here, move_and_slide collides
##   DOWNCLIMBING / ARRESTED        clinging to the face: no gravity, the
##                                  movement follows the terrain surface
##   SLIDING                        SlideSystem integrates on the slope plane
##   SKIING                         SkiPhysics integrates on the slope plane
##   ROPING                         the rope system places the climber on the
##                                  face each tick (kinematic, no collision)
##   FALLING                        ballistic; landing impact decides the injury
##
## What is on the feet (boots, crampons, skis, splitboard) is a timed choice:
## F straps crampons on or off, T steps into or out of skis.

# =============================================================================
# SIGNALS
# =============================================================================

signal state_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState)
signal position_updated(position: Vector3, velocity: Vector3)
signal stability_changed(stability: float, posture: GameEnums.PostureState)
signal micro_slip_occurred(severity: float)
signal footwear_changed(old_footwear: GameEnums.Footwear, new_footwear: GameEnums.Footwear)
## Touched down after being airborne; impact is the cushioned impact speed (m/s)
signal landed(impact: float)

# =============================================================================
# CONSTANTS
# =============================================================================

## Slope (degrees) above which the climber turns to face the slope and downclimbs
const DOWNCLIMB_ENTER_SLOPE := 35.0
## Slope below which downclimbing relaxes back into walking (hysteresis)
const DOWNCLIMB_EXIT_SLOPE := 31.0
## Range of slopes a deliberate glissade can be started on
const GLISSADE_MIN_SLOPE := 20.0
const GLISSADE_MAX_SLOPE := 42.0
## Steepest slope you can step into skis on
const SKI_TRANSITION_MAX_SLOPE := 38.0

## Gear change times (real seconds; game time runs 10x)
const CRAMPONS_ON_TIME := 7.0
const CRAMPONS_OFF_TIME := 4.0
const SKIS_ON_TIME := 9.0
const SKIS_OFF_TIME := 6.0
const BOARD_EXTRA_TIME := 1.5
## Taking crampons off is part of stepping into skis
const CRAMPONS_OFF_FOR_SKIS := 3.0
## Fiddling with gear on a steep slope takes longer
const STEEP_GEAR_FACTOR := 1.5

## Steepest slope that still counts as floor for the character body
const FLOOR_MAX_SLOPE := 60.0

## Floor snap while walking, and while a slide or skis own the motion
const WALK_SNAP_LENGTH := 0.3
const MOTOR_SNAP_LENGTH := 0.6

## Airborne time and sink rate that turn a hop into a fall
const FALL_START_TIME := 0.35
const FALL_START_SINK := -4.5

## Cushioned impact speeds (m/s) for landing outcomes: ~1 m, ~2.5 m, ~6 m drops
const LANDING_HARD := 4.5
const LANDING_INJURY := 7.0
const LANDING_SEVERE := 11.0

## Meeting a tree or a boulder (m/s into it): harmless at walking pace, a
## knock above OBSTACLE_HARMLESS, an injury above OBSTACLE_INJURY, serious
## above OBSTACLE_SEVERE
const OBSTACLE_HARMLESS := 3.0
const OBSTACLE_INJURY := 6.0
const OBSTACLE_SEVERE := 11.0

## Seconds incapacitated before rescuers carry the climber down
const RESCUE_DELAY := 5.0

## Same diegetic message is not repeated within this many seconds
const MESSAGE_REPEAT_GAP := 4.0

# =============================================================================
# EXPORTS
# =============================================================================

@export_group("Movement")
@export var base_walk_speed: float = 2.4
@export var base_run_speed: float = 4.0
@export var downclimb_speed: float = 1.0
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
var ski: SkiPhysics

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

## Current gear state; assigning it resets what is on the feet
var gear_state: GearState:
	set = _set_gear_state

## What is on the climber's feet
var footwear: GameEnums.Footwear = GameEnums.Footwear.BOOTS

## Timed gear change in progress (&"" when none): &"crampons" or &"skis"
var gear_action: StringName = &""
var gear_action_elapsed: float = 0.0
var gear_action_duration: float = 0.0
var _gear_action_target: GameEnums.Footwear = GameEnums.Footwear.BOOTS

## Is the player grounded (on the floor, or clinging to the face)
var is_grounded: bool = true

## Seconds since the climber last had ground under them
var air_time: float = 0.0

## Current stability value (0-1)
var stability: float = 1.0

## Grip left over what the slope demands (PostureSystem keeps it current)
var grip_margin: float = 1.0

## Current posture state
var posture_state: GameEnums.PostureState = GameEnums.PostureState.STABLE

## Latest air temperature (C), for crampon balling
var air_temperature: float = -8.0

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

var _slide_system: SlideSystem
var _incapacitated_time: float = 0.0
var _fall_still_time: float = 0.0

## Seconds before another tree or boulder can hurt (one impact per collision)
var _obstacle_cooldown: float = 0.0
var _rescue_called: bool = false
var _last_message: String = ""
var _last_message_time: float = -100.0

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
	floor_snap_length = WALK_SNAP_LENGTH
	# Slopes up to 60 degrees are ground a body rests, slides or tumbles on;
	# only faces steeper than that are walls to fall down
	floor_max_angle = deg_to_rad(FLOOR_MAX_SLOPE)

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
	ski = SkiPhysics.new(self)

	add_child(movement)
	add_child(ski)
	add_child(posture)
	add_child(input_handler)
	add_child(state_machine)


func _connect_signals() -> void:
	state_changed.connect(_on_state_changed)
	micro_slip_occurred.connect(_on_micro_slip)
	EventBus.temperature_changed.connect(_on_temperature_changed)


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

	# Crampons and skis
	_handle_gear_input()
	_update_gear_action(delta)

	# Update posture and stability
	posture.update(delta)

	# Update state machine
	state_machine.update(delta)

	# Apply movement based on state
	movement.update(delta)

	# Apply gravity and move
	_apply_physics(delta)

	# Rescue after a disabling injury
	_update_incapacitation(delta)

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

	# Hands are busy with straps and bindings
	if is_busy_with_gear():
		input_handler.move_input = Vector2.ZERO
		input_handler.raw_move_input = Vector2.ZERO
		for action in input_handler.actions_just_pressed:
			if action != "crampons_toggle" and action != "skis_toggle":
				input_handler.actions_just_pressed[action] = false


func _apply_physics(delta: float) -> void:
	if current_state == GameEnums.PlayerMovementState.ROPING:
		# The rope system places the climber on the face each tick
		is_grounded = true
		air_time = 0.0
		return

	var clinging := is_clinging()
	var motor := is_motor_driven()
	var on_floor_before := is_on_floor()

	if not on_floor_before and not clinging:
		velocity.y -= gravity * delta
		if not motor:
			velocity.x *= 1.0 - (air_friction * delta)
			velocity.z *= 1.0 - (air_friction * delta)
	elif on_floor_before and not motor and not clinging:
		# Ground friction when not moving
		if input_handler.move_input.length() < 0.1:
			var friction_force := ground_friction * delta
			velocity.x *= max(0, 1.0 - friction_force)
			velocity.z *= max(0, 1.0 - friction_force)

	floor_snap_length = MOTOR_SNAP_LENGTH if motor else WALK_SNAP_LENGTH

	var pre_velocity := velocity
	move_and_slide()
	_recover_from_ground_underside(pre_velocity)
	_obstacle_cooldown = maxf(0.0, _obstacle_cooldown - delta)
	_check_obstacle_impacts(pre_velocity)

	var grounded := is_on_floor()
	if not grounded and (clinging or motor):
		grounded = get_height_above_terrain() < (0.6 if clinging else 0.3)

	if grounded:
		# A fall that started on the ground (an anchor ripping at a ledge) still
		# has to be resolved once the body has settled
		var touched_down := not is_grounded and air_time > 0.12
		var settled_fall := current_state == GameEnums.PlayerMovementState.FALLING and state_time > 0.25
		if touched_down or settled_fall:
			_on_landed(pre_velocity)
		air_time = 0.0
	else:
		air_time += delta
		_check_fall_start()
	is_grounded = grounded

	# A falling body wedged where nothing counts as floor (a narrow gully) but
	# no longer moving has landed all the same
	if current_state == GameEnums.PlayerMovementState.FALLING and velocity.length() < 0.3:
		_fall_still_time += delta
		if _fall_still_time > 1.0:
			_fall_still_time = 0.0
			_on_landed(pre_velocity)
	else:
		_fall_still_time = 0.0


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


## Trees and boulders (TerrainScatter) are walked round at walking pace, but
## meeting one at speed (sliding, skiing, falling) is a collision with
## something that does not give
func _check_obstacle_impacts(pre_velocity: Vector3) -> void:
	if _obstacle_cooldown > 0.0:
		return
	for i in range(get_slide_collision_count()):
		var collision := get_slide_collision(i)
		var shape := collision.get_collider_shape() as Node
		if shape == null or not shape.has_meta("scatter_kind"):
			continue
		var normal := collision.get_normal()
		normal.y = 0.0
		if normal.length_squared() < 0.0001:
			continue
		var impact := maxf(0.0, -pre_velocity.dot(normal.normalized()))
		if impact >= OBSTACLE_HARMLESS:
			hit_obstacle(str(shape.get_meta("scatter_kind")), impact)
		return


## The climber hits a tree or a boulder at impact m/s
func hit_obstacle(kind: String, impact: float) -> void:
	_obstacle_cooldown = 1.0
	var is_rock := kind == "boulder" or kind == "rock"
	EventBus.record_incident("obstacle_impact", {
		"object": kind,
		"speed": impact,
		"state": GameEnums.PlayerMovementState.keys()[current_state]
	})
	# It stops you
	velocity.x *= 0.15
	velocity.z *= 0.15

	var disabling := false
	if impact >= OBSTACLE_SEVERE:
		var severity := clampf(0.6 + (impact - OBSTACLE_SEVERE) / 15.0, 0.6, 1.0)
		_apply_impact_injury(severity, impact, kind, true)
		set_stability(0.1)
		disabling = severity >= 0.85
	elif impact >= OBSTACLE_INJURY:
		_apply_impact_injury(clampf(0.2 + (impact - OBSTACLE_INJURY) / 12.0, 0.2, 0.6), impact, kind, false)
		set_stability(stability - 0.5)
	else:
		set_stability(stability - 0.3)

	match current_state:
		GameEnums.PlayerMovementState.SKIING:
			if ski != null:
				ski._crash("obstacle")
		GameEnums.PlayerMovementState.SLIDING:
			var slides := get_slide_system()
			if slides != null:
				slides._upset("obstacle")
	if disabling and body_state != null:
		change_state(GameEnums.PlayerMovementState.INCAPACITATED)
	say("You slam into a boulder." if is_rock else "You hit a tree.", 2.5)


## Blunt injury from a collision: arms and legs at moderate speed, the body
## (and an unhelmeted head) at high speed
func _apply_impact_injury(severity: float, impact: float, kind: String, serious: bool) -> void:
	if body_state == null:
		return
	var locations: Array = [
		GameEnums.BodyPart.LEFT_ARM, GameEnums.BodyPart.RIGHT_ARM,
		GameEnums.BodyPart.LEFT_LEG, GameEnums.BodyPart.RIGHT_LEG,
	]
	if serious:
		locations = [GameEnums.BodyPart.TORSO, GameEnums.BodyPart.LEFT_LEG, GameEnums.BodyPart.RIGHT_LEG]
		if gear_state == null or not gear_state.has_item(GameEnums.GearType.HELMET):
			locations.append(GameEnums.BodyPart.HEAD)
	var location: GameEnums.BodyPart = locations[randi() % locations.size()]
	var injury_type := GameEnums.InjuryType.FRACTURE if severity > 0.45 else GameEnums.InjuryType.SPRAIN
	if location == GameEnums.BodyPart.HEAD or location == GameEnums.BodyPart.TORSO:
		injury_type = GameEnums.InjuryType.FRACTURE if severity > 0.6 else GameEnums.InjuryType.LACERATION
	var injury := Injury.new(injury_type, severity, location, 0.0)
	body_state.add_injury(injury)
	EventBus.injury_occurred.emit(injury)
	EventBus.body_state_updated.emit(body_state)
	EventBus.record_incident("injury", {
		"cause": kind,
		"severity": severity,
		"impact_speed": impact,
		"type": GameEnums.InjuryType.keys()[injury_type],
		"location": GameEnums.BodyPart.keys()[location]
	})


## The terrain is a heightfield: it has no overhangs, so touching a "ceiling"
## means a fast body slipped under the paper-thin collider for a tick. Put it
## back on top and give back the motion the false contact took.
func _recover_from_ground_underside(pre_velocity: Vector3) -> void:
	if not is_on_ceiling() or terrain_service == null or not terrain_service.has_terrain_at(global_position):
		return
	var ground := terrain_service.get_height_at(global_position)
	if global_position.y > ground + 0.5:
		return
	global_position.y = maxf(global_position.y, ground + 0.05)
	var normal := current_cell.normal if current_cell else Vector3.UP
	velocity = pre_velocity - normal * minf(pre_velocity.dot(normal), 0.0)


# =============================================================================
# AIRBORNE AND LANDING
# =============================================================================

func _check_fall_start() -> void:
	if current_state in [
		GameEnums.PlayerMovementState.FALLING,
		GameEnums.PlayerMovementState.ROPING,
		GameEnums.PlayerMovementState.INCAPACITATED,
	]:
		return
	if is_clinging():
		return

	var min_time := FALL_START_TIME
	var min_sink := FALL_START_SINK
	match current_state:
		GameEnums.PlayerMovementState.SKIING:
			# Air is part of skiing; only a real drop is a fall
			min_time = 1.0
			min_sink = -9.0
		GameEnums.PlayerMovementState.SLIDING:
			min_time = 0.5
			min_sink = -6.0

	if air_time > min_time and velocity.y < min_sink:
		change_state(GameEnums.PlayerMovementState.FALLING)


func _on_landed(pre_velocity: Vector3) -> void:
	var normal := get_floor_normal() if is_on_floor() else Vector3.UP
	var impact := maxf(0.0, -pre_velocity.dot(normal))
	var surface := current_cell.surface_type if current_cell else GameEnums.SurfaceType.ROCK_DRY
	var cushioned := impact / TractionModel.landing_softness(surface)
	landed.emit(cushioned)

	match current_state:
		GameEnums.PlayerMovementState.SKIING:
			if ski != null:
				ski.on_landed(cushioned)
		GameEnums.PlayerMovementState.SLIDING:
			var slides := get_slide_system()
			if slides != null:
				slides.on_landed(cushioned)
		GameEnums.PlayerMovementState.FALLING:
			_resolve_fall_landing(cushioned, pre_velocity, normal)
		_:
			# A hop off a step; only a real drop hurts
			if cushioned >= LANDING_HARD:
				_resolve_fall_landing(cushioned, pre_velocity, normal)


func _resolve_fall_landing(cushioned: float, pre_velocity: Vector3, normal: Vector3) -> void:
	var tangential := pre_velocity - normal * pre_velocity.dot(normal)

	if cushioned >= LANDING_SEVERE:
		var severity := clampf(0.75 + (cushioned - LANDING_SEVERE) / 12.0, 0.75, 1.0)
		_apply_landing_injury(severity, cushioned)
		set_stability(0.1)
		if severity >= 0.85:
			change_state(GameEnums.PlayerMovementState.INCAPACITATED)
			return
	elif cushioned >= LANDING_INJURY:
		_apply_landing_injury(0.25 + (cushioned - LANDING_INJURY) / 8.0, cushioned)
		set_stability(stability - 0.5)
	elif cushioned >= LANDING_HARD:
		set_stability(stability - 0.35)
		EventBus.record_incident("hard_landing", {"impact_speed": cushioned})
		if randf() < 0.25:
			_apply_landing_injury(randf_range(0.15, 0.3), cushioned)

	_settle_after_landing(tangential.length())


## Where a tumbling body ends up: still sliding if the slope will not hold it,
## clinging if it is steep, otherwise back on its feet
func _settle_after_landing(tangential_speed: float) -> void:
	_update_terrain_cell()
	var slope := current_cell.slope_angle if current_cell else 0.0
	var surface := current_cell.surface_type if current_cell else GameEnums.SurfaceType.ROCK_DRY
	var body_hold := TractionModel.max_holding_slope(TractionModel.body_static_friction(surface))

	if is_on_skis() and slope < body_hold:
		change_state(GameEnums.PlayerMovementState.SKIING)
	elif slope > body_hold and (tangential_speed > 1.5 or slope > body_hold + 5.0):
		start_slide(true, "tumble_after_fall")
	elif slope > DOWNCLIMB_ENTER_SLOPE:
		change_state(GameEnums.PlayerMovementState.DOWNCLIMBING)
	else:
		change_state(GameEnums.PlayerMovementState.STANDING)


func _apply_landing_injury(severity: float, impact: float) -> void:
	if body_state == null:
		return
	severity = clampf(severity, 0.05, 1.0)

	var injury_type := GameEnums.InjuryType.SPRAIN
	if severity > 0.45:
		injury_type = GameEnums.InjuryType.FRACTURE

	var locations := [
		GameEnums.BodyPart.LEFT_LEG, GameEnums.BodyPart.RIGHT_LEG,
		GameEnums.BodyPart.LEFT_FOOT, GameEnums.BodyPart.RIGHT_FOOT,
	]
	var location: GameEnums.BodyPart = locations[randi() % locations.size()]

	var injury := Injury.new(injury_type, severity, location, 0.0)
	body_state.add_injury(injury)

	EventBus.injury_occurred.emit(injury)
	EventBus.body_state_updated.emit(body_state)
	EventBus.record_incident("fall_injury", {
		"severity": severity,
		"impact_speed": impact,
		"type": GameEnums.InjuryType.keys()[injury_type],
		"location": GameEnums.BodyPart.keys()[location]
	})


func _update_incapacitation(delta: float) -> void:
	if current_state != GameEnums.PlayerMovementState.INCAPACITATED:
		_incapacitated_time = 0.0
		return
	_incapacitated_time += delta
	if _rescue_called or _incapacitated_time < RESCUE_DELAY:
		return

	var fatal := ServiceLocator.get_service("FatalEventManager") as FatalEventManager
	if fatal != null and fatal.is_in_fatal_sequence():
		return
	if not GameStateManager.is_run_active():
		return
	_rescue_called = true
	GameStateManager.complete_run(GameEnums.ResolutionType.RESCUE, "Injured in a fall; carried down by rescuers")


## Knock the climber off their stance (anchor failure, a hold breaking)
func trigger_fall() -> void:
	var push := Vector3.ZERO
	if current_cell != null:
		push = current_cell.slope_direction * 1.5
	velocity = push + Vector3(0.0, -1.0, 0.0)
	air_time = FALL_START_TIME
	is_grounded = false
	change_state(GameEnums.PlayerMovementState.FALLING)

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

## Put the climber back into a fresh standing state for another descent.
## The same player node is reused across runs so every system that cached
## it or connected to its signals keeps working; call this after placing it.
func reset_for_new_run() -> void:
	velocity = Vector3.ZERO
	smooth_velocity = Vector3.ZERO
	last_position = global_position
	_last_position_initialized = false
	state_time = 0.0
	stability = 1.0
	grip_margin = 1.0
	posture_state = GameEnums.PostureState.STABLE
	is_grounded = true
	air_time = 0.0
	current_cell = null
	input_delay_buffer = 0.0
	gear_action = &""
	gear_action_elapsed = 0.0
	_incapacitated_time = 0.0
	_rescue_called = false
	_last_message = ""

	if input_handler != null:
		input_handler.input_buffer.clear()
		input_handler.move_input = Vector2.ZERO
		input_handler.raw_move_input = Vector2.ZERO
		input_handler.hesitation_time = 0.0
		input_handler.actions_just_pressed.clear()
		input_handler.actions_held.clear()
		input_handler.lean_input = 0.0
		input_handler.is_map_open = false
		input_handler.is_self_checking = false
	if posture != null:
		posture.micro_slip_timer = 0.0
		posture.stability_modifiers.clear()
		posture.recent_slips.clear()
		posture.is_precarious = false
	if movement != null:
		movement.reset()

	if current_state != GameEnums.PlayerMovementState.STANDING:
		change_state(GameEnums.PlayerMovementState.STANDING)
	elif state_machine != null:
		state_machine.transition_to(GameEnums.PlayerMovementState.STANDING)

	var pivot := camera_pivot as PlayerCamera
	if pivot != null:
		pivot.snap_behind_player()

	print("[PlayerController] Reset for new run")


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


## Start a slide. uncontrolled: the climber fell into it (a slip, a crash on
## skis, a tumble after a fall) rather than sitting down on purpose
func start_slide(uncontrolled: bool, cause: String) -> void:
	var slides := get_slide_system()
	if slides != null:
		slides.prepare_entry(uncontrolled, cause)
	change_state(GameEnums.PlayerMovementState.SLIDING)


## Ask the rope system to set up a rappel here (it explains if it cannot)
func request_rope() -> void:
	var rope := ServiceLocator.get_service("RopeService") as RopeService
	if rope == null:
		say("You have no rope.")
		return
	if current_state == GameEnums.PlayerMovementState.ROPING:
		rope.on_rope_key()
	else:
		rope.request_rappel(self)


## Holding onto the face: no gravity, movement follows the surface
func is_clinging() -> bool:
	return current_state == GameEnums.PlayerMovementState.DOWNCLIMBING \
		or current_state == GameEnums.PlayerMovementState.ARRESTED


## A slide or skis integrate the motion themselves
func is_motor_driven() -> bool:
	return current_state == GameEnums.PlayerMovementState.SLIDING \
		or current_state == GameEnums.PlayerMovementState.SKIING


func get_slide_system() -> SlideSystem:
	if not is_instance_valid(_slide_system):
		_slide_system = ServiceLocator.get_service("SlideSystem") as SlideSystem
	return _slide_system


## Height of the feet above the terrain directly below
func get_height_above_terrain() -> float:
	if terrain_service == null or not terrain_service.has_terrain_at(global_position):
		return 0.0
	return global_position.y - terrain_service.get_height_at(global_position)


## Say something in the diegetic message slot (not repeated back to back)
func say(message: String, duration: float = 2.5) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if message == _last_message and now - _last_message_time < MESSAGE_REPEAT_GAP:
		return
	_last_message = message
	_last_message_time = now
	EventBus.diegetic_message.emit(message, duration)


# =============================================================================
# FOOTWEAR AND GEAR CHANGES
# =============================================================================

func _set_gear_state(state: GearState) -> void:
	gear_state = state
	gear_action = &""
	# A climber tops out with crampons on; skis ride on the pack
	var start := GameEnums.Footwear.BOOTS
	if state != null and state.has_crampons():
		start = GameEnums.Footwear.CRAMPONS
	if start != footwear:
		_set_footwear(start)


func is_on_skis() -> bool:
	return footwear == GameEnums.Footwear.SKIS or footwear == GameEnums.Footwear.SNOWBOARD


## The footwear that decides foot traction (skis count as boots for a stance)
func get_traction_footwear() -> GameEnums.Footwear:
	if is_on_skis():
		return GameEnums.Footwear.BOOTS
	return footwear


## Skis or splitboard carried, as the footwear they become (BOOTS if none)
func get_ski_footwear() -> GameEnums.Footwear:
	if gear_state == null:
		return GameEnums.Footwear.BOOTS
	if gear_state.has_item(GameEnums.GearType.SKIS):
		return GameEnums.Footwear.SKIS
	if gear_state.has_item(GameEnums.GearType.SNOWBOARD):
		return GameEnums.Footwear.SNOWBOARD
	return GameEnums.Footwear.BOOTS


func is_busy_with_gear() -> bool:
	return gear_action != &""


func get_gear_action_progress() -> float:
	if gear_action == &"" or gear_action_duration <= 0.0:
		return 0.0
	return clampf(gear_action_elapsed / gear_action_duration, 0.0, 1.0)


func _handle_gear_input() -> void:
	if input_handler.is_action_just_pressed("crampons_toggle"):
		toggle_crampons()
	if input_handler.is_action_just_pressed("skis_toggle"):
		toggle_skis()


func _can_change_gear() -> bool:
	match current_state:
		GameEnums.PlayerMovementState.STANDING, \
		GameEnums.PlayerMovementState.WALKING, \
		GameEnums.PlayerMovementState.DOWNCLIMBING, \
		GameEnums.PlayerMovementState.RESTING:
			return true
		GameEnums.PlayerMovementState.SKIING:
			return smooth_velocity.length() < 1.0
	return false


## Strap crampons on or take them off. Returns true if a change started
func toggle_crampons() -> bool:
	if gear_action == &"crampons":
		_cancel_gear_action()
		return false
	if gear_action != &"":
		return false
	if gear_state == null or not gear_state.has_crampons():
		say("You have no crampons.")
		return false
	if is_on_skis():
		say("Take your skis off first.")
		return false
	if not _can_change_gear():
		say("Not now.")
		return false

	if footwear == GameEnums.Footwear.CRAMPONS:
		_begin_gear_action(&"crampons", GameEnums.Footwear.BOOTS, CRAMPONS_OFF_TIME, "Taking your crampons off...")
	else:
		_begin_gear_action(&"crampons", GameEnums.Footwear.CRAMPONS, CRAMPONS_ON_TIME, "Strapping on your crampons...")
	return true


## Step into skis (or the splitboard) or out of them. Returns true if a change started
func toggle_skis() -> bool:
	if gear_action == &"skis":
		_cancel_gear_action()
		return false
	if gear_action != &"":
		return false
	var ski_kind := get_ski_footwear()
	if ski_kind == GameEnums.Footwear.BOOTS:
		say("You have no skis or board with you.")
		return false
	if not _can_change_gear():
		say("Stop first." if is_on_skis() else "Not now.")
		return false

	var board_extra := BOARD_EXTRA_TIME if ski_kind == GameEnums.Footwear.SNOWBOARD else 0.0
	if is_on_skis():
		_begin_gear_action(&"skis", GameEnums.Footwear.BOOTS, SKIS_OFF_TIME + board_extra,
			"Stepping out of your bindings...")
		return true

	var slope := current_cell.slope_angle if current_cell else 0.0
	if slope > SKI_TRANSITION_MAX_SLOPE:
		say("Too steep to step into your bindings here.")
		return false
	if current_cell != null and not TractionModel.is_snow(current_cell.surface_type):
		say("Nothing to ski on here.")
		return false
	var time := SKIS_ON_TIME + board_extra
	if footwear == GameEnums.Footwear.CRAMPONS:
		time += CRAMPONS_OFF_FOR_SKIS
	var what := "board" if ski_kind == GameEnums.Footwear.SNOWBOARD else "skis"
	_begin_gear_action(&"skis", ski_kind, time, "Clicking into your %s..." % what)
	return true


func _begin_gear_action(action: StringName, target: GameEnums.Footwear, duration: float, message: String) -> void:
	if current_cell != null and current_cell.slope_angle > DOWNCLIMB_ENTER_SLOPE:
		duration *= STEEP_GEAR_FACTOR
	if body_state != null:
		# Cold, clumsy hands fumble straps and bindings
		duration /= maxf(body_state.get_rope_handling_modifier(), 0.4)

	gear_action = action
	gear_action_elapsed = 0.0
	gear_action_duration = duration
	_gear_action_target = target
	if current_state == GameEnums.PlayerMovementState.WALKING:
		change_state(GameEnums.PlayerMovementState.STANDING)
	say(message, minf(duration, 4.0))


func _cancel_gear_action() -> void:
	if gear_action == &"":
		return
	gear_action = &""
	gear_action_elapsed = 0.0
	say("You leave it for now.", 1.5)


func _update_gear_action(delta: float) -> void:
	if gear_action == &"":
		return
	if not _can_change_gear():
		# Swept off your feet mid-change: it never happened
		gear_action = &""
		return
	gear_action_elapsed += delta
	if gear_action_elapsed < gear_action_duration:
		return

	gear_action = &""
	_set_footwear(_gear_action_target)
	match footwear:
		GameEnums.Footwear.CRAMPONS:
			say("Crampons on.", 1.5)
		GameEnums.Footwear.BOOTS:
			say("On your boots.", 1.5)
		GameEnums.Footwear.SKIS:
			say("Skis on. Heels down.", 1.8)
		GameEnums.Footwear.SNOWBOARD:
			say("Strapped in.", 1.8)


## Put something else on the feet right now (gear lost or broken)
func set_footwear(new_footwear: GameEnums.Footwear) -> void:
	gear_action = &""
	_set_footwear(new_footwear)


func _set_footwear(new_footwear: GameEnums.Footwear) -> void:
	var old := footwear
	if old == new_footwear:
		return
	footwear = new_footwear
	footwear_changed.emit(old, new_footwear)
	EventBus.footwear_changed.emit(old, new_footwear)
	if is_inside_tree():
		EventBus.record_decision("footwear_changed", {
			"from": GameEnums.Footwear.keys()[old],
			"to": GameEnums.Footwear.keys()[new_footwear],
			"position": global_position,
			"slope": current_cell.slope_angle if current_cell else 0.0
		})

	if state_machine == null:
		return
	var was_skiing := old == GameEnums.Footwear.SKIS or old == GameEnums.Footwear.SNOWBOARD
	if is_on_skis() and current_state != GameEnums.PlayerMovementState.SKIING:
		change_state(GameEnums.PlayerMovementState.SKIING)
	elif was_skiing and current_state == GameEnums.PlayerMovementState.SKIING:
		var steep := current_cell != null and current_cell.slope_angle > DOWNCLIMB_ENTER_SLOPE
		change_state(GameEnums.PlayerMovementState.DOWNCLIMBING if steep else GameEnums.PlayerMovementState.STANDING)

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

	# Surface underfoot: postholing, shuffling on ice, crampons on rock
	if current_cell:
		speed *= TractionModel.walk_surface_speed(current_cell.surface_type, get_traction_footwear())

	# Body state modifier
	if body_state:
		speed *= body_state.get_movement_modifier()

	# Gear weight modifier
	if gear_state:
		speed *= gear_state.get_weight_modifier()

	# Stability modifier: unsteady footing slows the climber but never
	# roots them to the spot
	speed *= lerpf(0.55, 1.0, clampf(stability, 0.0, 1.0))

	return speed


## Get the direction the player is facing
func get_facing_direction() -> Vector3:
	return -global_transform.basis.z


## Get the downhill direction at current position
func get_downhill_direction() -> Vector3:
	if current_cell:
		return current_cell.slope_direction
	return Vector3.ZERO


## Check if player can sit down into a glissade from current position
func can_initiate_slide() -> bool:
	if current_cell == null or is_on_skis():
		return false
	if not current_state in [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.WALKING,
		GameEnums.PlayerMovementState.DOWNCLIMBING,
	]:
		return false
	if not TractionModel.is_glissadable(current_cell.surface_type):
		return false
	return current_cell.slope_angle >= GLISSADE_MIN_SLOPE and current_cell.slope_angle <= GLISSADE_MAX_SLOPE


## Check if rope is required at current position
func needs_rope() -> bool:
	if current_cell == null:
		return false
	return current_cell.requires_rope


## Fatigue (0-1), for systems that scale with tiredness
func get_fatigue() -> float:
	return body_state.fatigue if body_state else 0.0


## How well the hands work (0-1): glove dexterity and cold fingers
func get_hand_dexterity() -> float:
	var dexterity := 0.95
	if gear_state != null and gear_state.has_item(GameEnums.GearType.GLOVES):
		var gloves := gear_state.get_item(GameEnums.GearType.GLOVES)
		dexterity = gloves.properties.get("dexterity", 0.8)
	if body_state != null:
		var hand_cold: float = maxf(
			body_state.extremity_cold.get(GameEnums.BodyPart.LEFT_HAND, 0.0),
			body_state.extremity_cold.get(GameEnums.BodyPart.RIGHT_HAND, 0.0))
		dexterity *= 1.0 - 0.6 * hand_cold
	return clampf(dexterity, 0.1, 1.0)


## How cold the feet are (0-1)
func get_foot_cold() -> float:
	if body_state == null:
		return 0.0
	return maxf(
		body_state.extremity_cold.get(GameEnums.BodyPart.LEFT_FOOT, 0.0),
		body_state.extremity_cold.get(GameEnums.BodyPart.RIGHT_FOOT, 0.0))


func has_ice_axe() -> bool:
	return gear_state != null and gear_state.has_ice_axe()


func get_ice_axe_effectiveness() -> float:
	return gear_state.get_ice_axe_effectiveness() if gear_state else 0.0


func get_crampon_effectiveness() -> float:
	return gear_state.get_crampon_effectiveness() if gear_state else 0.0


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
		"slope": current_cell.slope_angle if current_cell else 0.0,
		"surface": GameEnums.SurfaceType.keys()[current_cell.surface_type] if current_cell else "unknown",
		"footwear": GameEnums.Footwear.keys()[footwear]
	})


func _on_temperature_changed(temperature: float, _feels_like: float) -> void:
	air_temperature = temperature


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
		"grip_margin": grip_margin,
		"footwear": GameEnums.Footwear.keys()[footwear],
		"posture": GameEnums.PostureState.keys()[posture_state],
		"terrain_zone": GameEnums.TerrainZone.keys()[current_cell.terrain_zone] if current_cell else "unknown",
		"slope_angle": current_cell.slope_angle if current_cell else 0.0,
		"fatigue": body_state.fatigue if body_state else 0.0
	}
