class_name DroneEntity
extends CharacterBody3D
## Physical drone entity with environmental constraints
## The spectator eye that documents the descent
##
## Design Philosophy:
## - Drone is non-diegetic in spectator mode (player doesn't see it)
## - Has real physics constraints: wind, battery, signal range
## - Cannot go everywhere - terrain and weather limit it
## - Imperfect by design - misses shots, loses subject

# =============================================================================
# SIGNALS
# =============================================================================

signal position_updated(position: Vector3, velocity: Vector3)
signal altitude_changed(altitude: float)
signal constraint_hit(constraint_type: String)
signal drone_grounded(reason: String)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Movement")
## Maximum flight speed (m/s)
@export var max_speed: float = 15.0
## Acceleration (m/s²)
@export var acceleration: float = 8.0
## Deceleration when stopping
@export var deceleration: float = 12.0
## Vertical climb rate (m/s)
@export var climb_rate: float = 5.0
## Rotation speed (rad/s)
@export var rotation_speed: float = 3.0

@export_group("Constraints")
## Minimum altitude above terrain (m)
@export var min_altitude: float = 2.0
## Maximum altitude above terrain (m)
@export var max_altitude: float = 100.0
## Maximum distance from subject (m)
@export var max_subject_distance: float = 150.0
## Minimum distance from subject (m)
@export var min_subject_distance: float = 3.0

@export_group("Environmental")
## Wind resistance factor (0 = no effect, 1 = full effect)
@export var wind_resistance: float = 0.8
## Cold sensitivity (affects battery at low temps)
@export var cold_sensitivity: float = 0.5
## Maximum safe wind speed (m/s)
@export var max_safe_wind: float = 20.0

# =============================================================================
# COMPONENTS
# =============================================================================

var drone_camera: DroneCamera
var battery: DroneBattery
var controller: DroneController

# =============================================================================
# STATE
# =============================================================================

## Current drone mode
var mode: GameEnums.DroneMode = GameEnums.DroneMode.SPECTATOR

## Subject being tracked (usually player)
var subject: Node3D

## Is drone active/flying
var is_active: bool = false

## Is drone grounded (not flying)
var is_grounded: bool = true

## Current altitude above terrain
var altitude_above_terrain: float = 0.0

## Distance to subject
var subject_distance: float = 0.0

## Current wind effect on drone
var wind_effect: Vector3 = Vector3.ZERO

## Is drone fighting constraints
var is_constrained: bool = false

## Current target position
var target_position: Vector3 = Vector3.ZERO

## Current target velocity
var target_velocity: Vector3 = Vector3.ZERO

## Terrain service reference
var terrain_service: TerrainService

## Weather service reference
var weather_service: WeatherService


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_setup_components()
	_connect_services()

	ServiceLocator.register_service("DroneEntity", self)
	print("[DroneEntity] Initialized")


func _setup_components() -> void:
	# Create battery system
	battery = DroneBattery.new()
	add_child(battery)

	# Create controller
	controller = DroneController.new()
	controller.drone = self
	add_child(controller)

	# Camera is added as child node in scene


func _connect_services() -> void:
	ServiceLocator.get_service_async("TerrainService", func(s): terrain_service = s)
	ServiceLocator.get_service_async("WeatherService", func(s): weather_service = s)
	ServiceLocator.get_service_async("PlayerController", func(s):
		subject = s
		print("[DroneEntity] Tracking player")
	)


# =============================================================================
# ACTIVATION
# =============================================================================

## Activate the drone
func activate(start_mode: GameEnums.DroneMode = GameEnums.DroneMode.SPECTATOR) -> void:
	mode = start_mode
	is_active = true
	is_grounded = false

	# Position near subject if available
	if subject:
		global_position = subject.global_position + Vector3(5, 8, 10)
		look_at(subject.global_position, Vector3.UP)

	# Start battery drain
	battery.start_drain()

	EventBus.drone_mode_changed.emit(GameEnums.DroneMode.DISABLED, mode)
	print("[DroneEntity] Activated in %s mode" % GameEnums.DroneMode.keys()[mode])


## Deactivate/ground the drone
func deactivate(reason: String = "manual") -> void:
	is_active = false
	is_grounded = true
	velocity = Vector3.ZERO

	battery.stop_drain()

	drone_grounded.emit(reason)
	print("[DroneEntity] Grounded: %s" % reason)


## Switch drone mode
func set_mode(new_mode: GameEnums.DroneMode) -> void:
	var old_mode := mode
	mode = new_mode

	EventBus.drone_mode_changed.emit(old_mode, new_mode)

	# Adjust behavior based on mode
	match new_mode:
		GameEnums.DroneMode.SPECTATOR:
			# Full freedom, non-diegetic
			max_subject_distance = 150.0
		GameEnums.DroneMode.SCOUT:
			# Limited, player-controlled, costs battery
			max_subject_distance = 80.0
			battery.set_drain_multiplier(2.0)  # Scout mode drains faster
		GameEnums.DroneMode.DISABLED:
			deactivate("mode_disabled")


# =============================================================================
# PHYSICS
# =============================================================================

func _physics_process(delta: float) -> void:
	if not is_active or is_grounded:
		return

	# Update environmental effects
	_update_wind_effect(delta)

	# Update altitude
	_update_altitude()

	# Update distance to subject
	_update_subject_distance()

	# Check constraints
	_check_constraints()

	# Apply movement
	_apply_movement(delta)

	# Emit updates
	if Engine.get_physics_frames() % 3 == 0:
		position_updated.emit(global_position, velocity)


func _update_wind_effect(delta: float) -> void:
	if weather_service == null:
		wind_effect = Vector3.ZERO
		return

	var wind := weather_service.get_wind_vector()
	var wind_strength := wind.length()

	# Wind effect increases with altitude
	var altitude_factor := clampf(altitude_above_terrain / 50.0, 0.5, 2.0)

	# Calculate wind force on drone
	wind_effect = wind * wind_resistance * altitude_factor

	# Check if wind is too strong
	if wind_strength > max_safe_wind:
		# Drone struggles in high wind
		is_constrained = true
		constraint_hit.emit("high_wind")

		# Battery drains faster fighting wind
		battery.set_drain_multiplier(1.5)


func _update_altitude() -> void:
	if terrain_service == null:
		altitude_above_terrain = global_position.y
		return

	var terrain_height := terrain_service.get_height_at(global_position)
	altitude_above_terrain = global_position.y - terrain_height

	altitude_changed.emit(altitude_above_terrain)


func _update_subject_distance() -> void:
	if subject == null:
		subject_distance = 0.0
		return

	subject_distance = global_position.distance_to(subject.global_position)


func _check_constraints() -> void:
	is_constrained = false

	# Altitude constraints
	if altitude_above_terrain < min_altitude:
		_apply_altitude_correction(min_altitude - altitude_above_terrain)
		is_constrained = true
		constraint_hit.emit("min_altitude")

	elif altitude_above_terrain > max_altitude:
		_apply_altitude_correction(max_altitude - altitude_above_terrain)
		is_constrained = true
		constraint_hit.emit("max_altitude")

	# Subject distance constraints
	if subject:
		if subject_distance > max_subject_distance:
			_apply_distance_correction(true)
			is_constrained = true
			constraint_hit.emit("max_distance")

		elif subject_distance < min_subject_distance:
			_apply_distance_correction(false)
			is_constrained = true
			constraint_hit.emit("min_distance")

	# Battery constraint
	if battery.is_critical():
		constraint_hit.emit("low_battery")
		EventBus.drone_battery_low.emit(battery.get_level())

	if battery.is_dead():
		deactivate("battery_dead")


func _apply_altitude_correction(correction: float) -> void:
	velocity.y += correction * 2.0


func _apply_distance_correction(too_far: bool) -> void:
	if subject == null:
		return

	var direction := (subject.global_position - global_position).normalized()
	if not too_far:
		direction = -direction

	velocity += direction * acceleration * 0.5


func _apply_movement(delta: float) -> void:
	# Get input from controller
	var input_velocity := controller.get_movement_input()

	# Apply acceleration toward target
	var target_vel := input_velocity * max_speed

	# Add wind effect
	target_vel += wind_effect

	# Accelerate/decelerate
	if target_vel.length() > 0.1:
		velocity = velocity.move_toward(target_vel, acceleration * delta)
	else:
		velocity = velocity.move_toward(Vector3.ZERO, deceleration * delta)

	# Clamp speed
	var horizontal_vel := Vector3(velocity.x, 0, velocity.z)
	if horizontal_vel.length() > max_speed:
		horizontal_vel = horizontal_vel.normalized() * max_speed
		velocity.x = horizontal_vel.x
		velocity.z = horizontal_vel.z

	velocity.y = clampf(velocity.y, -climb_rate, climb_rate)

	# Move
	move_and_slide()


# =============================================================================
# TARGETING
# =============================================================================

## Set the subject to track
func set_subject(new_subject: Node3D) -> void:
	subject = new_subject


## Move toward a target position
func move_to(position: Vector3, speed_factor: float = 1.0) -> void:
	target_position = position
	controller.set_target_position(position, speed_factor)


## Look at a position
func look_at_target(target: Vector3) -> void:
	if drone_camera:
		drone_camera.look_at_position(target)
	else:
		look_at(target, Vector3.UP)


## Get current look direction
func get_look_direction() -> Vector3:
	return -global_transform.basis.z


# =============================================================================
# QUERIES
# =============================================================================

func is_flying() -> bool:
	return is_active and not is_grounded


func get_battery_level() -> float:
	return battery.get_level()


func get_signal_strength() -> float:
	return battery.get_signal_strength(subject_distance)


func is_in_constraints() -> bool:
	return is_constrained


func get_mode() -> GameEnums.DroneMode:
	return mode


func get_subject() -> Node3D:
	return subject


func get_summary() -> Dictionary:
	return {
		"mode": GameEnums.DroneMode.keys()[mode],
		"active": is_active,
		"grounded": is_grounded,
		"altitude": altitude_above_terrain,
		"subject_distance": subject_distance,
		"battery": battery.get_level(),
		"signal": get_signal_strength(),
		"constrained": is_constrained,
		"wind_effect": wind_effect.length()
	}
