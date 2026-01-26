class_name SlideSystem
extends Node
## Core sliding physics system
## Handles the terrifying, high-skill descent mechanic
##
## Design Philosophy:
## - Sliding is never fully safe
## - Control is indirect (influence, not command)
## - Speed amplifies both success and failure
## - Veterans learn when it won't kill them

# =============================================================================
# SIGNALS
# =============================================================================

signal slide_started(entry_speed: float, slope_angle: float)
signal slide_updated(state: SlideState)
signal slide_control_changed(old_level: GameEnums.SlideControlLevel, new_level: GameEnums.SlideControlLevel)
signal slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float)
signal exit_zone_approached(distance: float, quality: float)
signal terminal_velocity_warning()
signal point_of_no_return()

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Physics")
## Gravity constant
@export var gravity: float = 9.8
## Base friction on snow
@export var base_friction: float = 0.15
## Air resistance coefficient
@export var air_resistance: float = 0.02
## Maximum slide speed before terminal
@export var terminal_speed: float = 25.0
## Speed at which control is nearly lost
@export var critical_speed: float = 18.0

@export_group("Control")
## How much lean affects trajectory (0-1)
@export var lean_influence: float = 0.3
## How much edge engagement affects friction
@export var edge_friction_bonus: float = 0.15
## Control degradation rate with speed
@export var speed_control_decay: float = 0.04
## Minimum control at high speed
@export var min_control: float = 0.1

@export_group("Terrain")
## Slope angle for minimum slide speed
@export var min_slide_slope: float = 25.0
## Slope angle for maximum acceleration
@export var max_slide_slope: float = 45.0
## Transition zone danger threshold (degrees change)
@export var transition_danger_threshold: float = 10.0

# =============================================================================
# STATE
# =============================================================================

## Current slide state data
var current_state: SlideState

## Reference to player controller
var player: PlayerController

## Reference to terrain service
var terrain_service: TerrainService

## Is currently sliding
var is_sliding: bool = false

## Time in slide
var slide_time: float = 0.0

## Distance slid
var slide_distance: float = 0.0

## Starting position
var start_position: Vector3 = Vector3.ZERO

## Last control level (for change detection)
var last_control_level: GameEnums.SlideControlLevel = GameEnums.SlideControlLevel.CONTROLLED

## Has emitted terminal warning
var terminal_warning_emitted: bool = false

## Has emitted point of no return
var point_of_no_return_emitted: bool = false

## Slide controller for input handling
var controller: SlideController

## Exit zone detector
var exit_detector: ExitZoneDetector

## State manager for control spectrum
var state_manager: SlideStateManager

## Feedback system for audio/visual
var feedback: SlideFeedback


# =============================================================================
# SLIDE STATE DATA CLASS
# =============================================================================

class SlideState:
	## Current position
	var position: Vector3 = Vector3.ZERO
	## Current velocity
	var velocity: Vector3 = Vector3.ZERO
	## Current speed (magnitude)
	var speed: float = 0.0
	## Current slope angle
	var slope_angle: float = 0.0
	## Current slope direction
	var slope_direction: Vector3 = Vector3.ZERO
	## Current surface type
	var surface_type: GameEnums.SurfaceType = GameEnums.SurfaceType.SNOW_FIRM
	## Current surface friction
	var friction: float = 0.3
	## Control level (0-1)
	var control: float = 1.0
	## Control level enum
	var control_level: GameEnums.SlideControlLevel = GameEnums.SlideControlLevel.CONTROLLED
	## Distance to nearest exit zone
	var exit_zone_distance: float = 100.0
	## Exit zone quality
	var exit_zone_quality: float = 0.0
	## Distance to cliff
	var cliff_distance: float = 100.0
	## Current risk level (0-1)
	var risk: float = 0.0
	## Is in transition zone (slope changing)
	var in_transition: bool = false
	## Transition danger level
	var transition_danger: float = 0.0
	## Time in slide
	var time: float = 0.0
	## Distance traveled
	var distance: float = 0.0

	func get_control_level() -> GameEnums.SlideControlLevel:
		# Validate control value to handle potential NaN or infinite values from physics
		var safe_control := control
		if not is_finite(safe_control):
			safe_control = 0.0
		safe_control = clampf(safe_control, 0.0, 1.0)
		return GameEnums.get_slide_control_level(safe_control)


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	current_state = SlideState.new()
	controller = SlideController.new(self)
	exit_detector = ExitZoneDetector.new(self)
	state_manager = SlideStateManager.new(self)
	feedback = SlideFeedback.new(self, state_manager)

	add_child(controller)
	add_child(exit_detector)
	add_child(state_manager)
	add_child(feedback)

	# Get services
	ServiceLocator.get_service_async("PlayerController", _on_player_ready)
	ServiceLocator.get_service_async("TerrainService", _on_terrain_ready)

	# Register service
	ServiceLocator.register_service("SlideSystem", self)

	print("[SlideSystem] Initialized")


func _on_player_ready(service: Object) -> void:
	player = service as PlayerController
	print("[SlideSystem] Connected to PlayerController")


func _on_terrain_ready(service: Object) -> void:
	terrain_service = service as TerrainService
	print("[SlideSystem] Connected to TerrainService")


# =============================================================================
# SLIDE LIFECYCLE
# =============================================================================

## Begin a slide
func begin_slide() -> void:
	if is_sliding or player == null:
		return

	is_sliding = true
	slide_time = 0.0
	slide_distance = 0.0
	start_position = player.global_position
	terminal_warning_emitted = false
	point_of_no_return_emitted = false
	last_control_level = GameEnums.SlideControlLevel.CONTROLLED

	# Initialize state from current conditions
	_initialize_slide_state()

	# Record decision
	EventBus.record_decision("slide_initiated", {
		"position": start_position,
		"slope": current_state.slope_angle,
		"entry_speed": current_state.speed,
		"surface": GameEnums.SurfaceType.keys()[current_state.surface_type]
	})

	slide_started.emit(current_state.speed, current_state.slope_angle)
	EventBus.slide_started.emit(current_state.speed, current_state.slope_angle)

	print("[SlideSystem] Slide started at %.1f°, speed %.1f" % [
		current_state.slope_angle, current_state.speed
	])


## End the slide
func end_slide(outcome: GameEnums.SlideOutcome) -> void:
	if not is_sliding:
		return

	is_sliding = false

	# Record outcome
	EventBus.record_incident("slide_ended", {
		"outcome": GameEnums.SlideOutcome.keys()[outcome],
		"final_speed": current_state.speed,
		"distance": slide_distance,
		"duration": slide_time,
		"end_position": player.global_position
	})

	slide_ended.emit(outcome, current_state.speed)
	EventBus.slide_ended.emit(outcome, current_state.speed)

	print("[SlideSystem] Slide ended: %s, distance=%.1fm, time=%.1fs" % [
		GameEnums.SlideOutcome.keys()[outcome],
		slide_distance,
		slide_time
	])

	# Transition player state based on outcome
	_handle_slide_outcome(outcome)


## Abort slide (emergency)
func abort_slide() -> void:
	end_slide(GameEnums.SlideOutcome.TUMBLE_STOP)


# =============================================================================
# PHYSICS UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if not is_sliding or player == null or terrain_service == null:
		return

	slide_time += delta

	# Update terrain data
	_update_terrain_data()

	# Calculate forces
	var forces := _calculate_forces(delta)

	# Apply player influence
	forces += controller.get_influence_force(delta)

	# Update velocity
	current_state.velocity += forces * delta

	# Apply friction and drag
	_apply_friction_and_drag(delta)

	# Update position via player
	player.velocity = current_state.velocity
	current_state.position = player.global_position

	# Update state calculations
	_update_state_calculations()

	# Track distance
	slide_distance += current_state.speed * delta
	current_state.distance = slide_distance
	current_state.time = slide_time

	# Check for exit zones
	exit_detector.update(delta)

	# Update state manager
	state_manager.update(delta)

	# Check for dangerous conditions
	_check_danger_conditions()

	# Emit state update
	slide_updated.emit(current_state)
	EventBus.slide_state_updated.emit(current_state.control, current_state.speed, current_state.velocity)

	# Check control level changes
	_check_control_level_change()

	# Check for automatic outcomes
	_check_automatic_outcomes()


func _initialize_slide_state() -> void:
	current_state.position = player.global_position
	current_state.velocity = player.velocity

	# Add initial push in slope direction if starting slow
	if current_state.velocity.length() < 2.0:
		var cell := terrain_service.get_cell_at(player.global_position)
		if cell:
			current_state.velocity = cell.slope_direction * 2.0
			current_state.velocity.y = -1.0

	current_state.speed = current_state.velocity.length()
	current_state.control = 1.0
	current_state.risk = 0.0

	_update_terrain_data()


func _update_terrain_data() -> void:
	var cell := terrain_service.get_cell_at(player.global_position)
	if cell == null:
		return

	current_state.slope_angle = cell.slope_angle
	current_state.slope_direction = cell.slope_direction
	current_state.surface_type = cell.surface_type
	current_state.friction = cell.friction
	current_state.cliff_distance = cell.distance_to_cliff

	# Check for exit zone
	if cell.is_exit_zone:
		current_state.exit_zone_distance = 0.0
		current_state.exit_zone_quality = cell.exit_zone_quality
	else:
		var exit := terrain_service.find_nearest_exit_zone(player.global_position, 50.0)
		if exit:
			current_state.exit_zone_distance = player.global_position.distance_to(exit.position)
			current_state.exit_zone_quality = exit.exit_zone_quality
		else:
			current_state.exit_zone_distance = 100.0
			current_state.exit_zone_quality = 0.0


func _calculate_forces(delta: float) -> Vector3:
	var forces := Vector3.ZERO

	# Gravity component along slope
	var slope_rad := deg_to_rad(current_state.slope_angle)
	var gravity_force := gravity * sin(slope_rad)

	# Apply in slope direction
	forces += current_state.slope_direction * gravity_force

	# Downward gravity component (into slope)
	forces.y -= gravity * cos(slope_rad) * 0.1

	return forces


func _apply_friction_and_drag(delta: float) -> void:
	var speed := current_state.velocity.length()
	if speed < 0.01:
		return

	# Surface friction
	var friction_force := current_state.friction * gravity * cos(deg_to_rad(current_state.slope_angle))

	# Edge engagement bonus from player
	friction_force += controller.get_edge_friction_bonus()

	# Apply friction (opposes motion)
	var friction_decel := friction_force * delta
	var velocity_dir := current_state.velocity.normalized()

	if friction_decel > speed:
		current_state.velocity = Vector3.ZERO
	else:
		current_state.velocity -= velocity_dir * friction_decel

	# Air resistance (quadratic with speed)
	var drag := air_resistance * speed * speed * delta
	if drag > current_state.velocity.length():
		current_state.velocity *= 0.5
	else:
		current_state.velocity -= velocity_dir * drag

	# Terminal speed clamp
	speed = current_state.velocity.length()
	if speed > terminal_speed:
		current_state.velocity = current_state.velocity.normalized() * terminal_speed

	current_state.speed = current_state.velocity.length()


func _update_state_calculations() -> void:
	# Calculate control level
	var control := 1.0

	# Speed reduces control
	if current_state.speed > 5.0:
		control -= (current_state.speed - 5.0) * speed_control_decay
		control = maxf(control, min_control)

	# Surface affects control
	match current_state.surface_type:
		GameEnums.SurfaceType.ICE:
			control *= 0.4
		GameEnums.SurfaceType.SNOW_POWDER:
			control *= 0.7
		GameEnums.SurfaceType.SCREE:
			control *= 0.6

	# Body state affects control
	if player.body_state:
		control *= player.body_state.get_slide_control_modifier()

	# Stability affects control
	control *= player.stability

	# Edge engagement improves control
	control += controller.get_control_bonus()

	current_state.control = clampf(control, 0.0, 1.0)
	current_state.control_level = current_state.get_control_level()

	# Calculate risk
	var risk := 0.0

	# Speed risk
	risk += current_state.speed / terminal_speed * 0.4

	# Cliff proximity risk
	if current_state.cliff_distance < 30.0:
		risk += (1.0 - current_state.cliff_distance / 30.0) * 0.4

	# Low control risk
	risk += (1.0 - current_state.control) * 0.3

	# No exit zone risk
	if current_state.exit_zone_distance > 50.0:
		risk += 0.2

	current_state.risk = clampf(risk, 0.0, 1.0)


func _check_danger_conditions() -> void:
	# Terminal velocity warning
	if current_state.speed > critical_speed and not terminal_warning_emitted:
		terminal_warning_emitted = true
		terminal_velocity_warning.emit()
		EventBus.emit_camera_signal(GameEnums.CameraSignal.SPEED_CHANGE, 1.0)

	# Point of no return (no exit zone visible, high speed)
	if not point_of_no_return_emitted:
		if current_state.exit_zone_distance > 50.0 and current_state.speed > 12.0:
			point_of_no_return_emitted = true
			point_of_no_return.emit()
			EventBus.point_of_no_return_detected.emit()


func _check_control_level_change() -> void:
	if current_state.control_level != last_control_level:
		slide_control_changed.emit(last_control_level, current_state.control_level)
		EventBus.slide_control_changed.emit(last_control_level, current_state.control_level)
		last_control_level = current_state.control_level


func _check_automatic_outcomes() -> void:
	# Cliff collision
	if current_state.cliff_distance < 2.0:
		_trigger_terminal_outcome()
		return

	# Stopped naturally
	if current_state.speed < 0.5 and current_state.slope_angle < 20.0:
		end_slide(GameEnums.SlideOutcome.CLEAN_STOP)
		return

	# In exit zone at low speed
	if current_state.exit_zone_distance < 3.0 and current_state.speed < 3.0:
		end_slide(GameEnums.SlideOutcome.CLEAN_STOP)
		return

	# Terrain too flat to continue
	if current_state.slope_angle < min_slide_slope and current_state.speed < 5.0:
		end_slide(GameEnums.SlideOutcome.CLEAN_STOP)
		return


func _trigger_terminal_outcome() -> void:
	EventBus.record_incident("terminal_slide", {
		"position": player.global_position,
		"speed": current_state.speed,
		"cliff_distance": current_state.cliff_distance
	})

	end_slide(GameEnums.SlideOutcome.TERMINAL_RUNOUT)


func _handle_slide_outcome(outcome: GameEnums.SlideOutcome) -> void:
	match outcome:
		GameEnums.SlideOutcome.CLEAN_STOP:
			player.change_state(GameEnums.PlayerMovementState.STANDING)

		GameEnums.SlideOutcome.TUMBLE_STOP:
			_apply_tumble_effects()
			player.change_state(GameEnums.PlayerMovementState.STANDING)

		GameEnums.SlideOutcome.TERRAIN_CATCH:
			_apply_terrain_catch_effects()
			player.change_state(GameEnums.PlayerMovementState.STANDING)

		GameEnums.SlideOutcome.COMPOUND_SLIDE:
			# Stay in slide but reset some state
			terminal_warning_emitted = false

		GameEnums.SlideOutcome.TERMINAL_RUNOUT:
			_apply_terminal_effects()
			player.change_state(GameEnums.PlayerMovementState.FALLING)


func _apply_tumble_effects() -> void:
	# Fatigue from tumble
	player.add_fatigue(0.1)

	# Stability loss
	player.set_stability(player.stability - 0.3)

	# Possible minor injury
	if randf() < 0.3:
		_apply_slide_injury(0.2)


func _apply_terrain_catch_effects() -> void:
	# Gear damage possible
	if player.gear_state and randf() < 0.2:
		var gear_types := [
			GameEnums.GearType.CRAMPONS,
			GameEnums.GearType.ICE_AXE,
			GameEnums.GearType.LAYERS
		]
		var random_gear: GameEnums.GearType = gear_types[randi() % gear_types.size()]
		player.gear_state.damage_item(random_gear, 0.1)

	# Fatigue
	player.add_fatigue(0.05)


func _apply_terminal_effects() -> void:
	# This is likely fatal or severely injuring
	_apply_slide_injury(0.8 + randf() * 0.2)


func _apply_slide_injury(severity: float) -> void:
	if player.body_state == null:
		return

	var injury_type := GameEnums.InjuryType.SPRAIN
	if severity > 0.5:
		injury_type = GameEnums.InjuryType.STRAIN
	if severity > 0.7:
		injury_type = GameEnums.InjuryType.LACERATION
	if severity > 0.9:
		injury_type = GameEnums.InjuryType.FRACTURE

	var locations := [
		GameEnums.BodyPart.LEFT_LEG,
		GameEnums.BodyPart.RIGHT_LEG,
		GameEnums.BodyPart.LEFT_ARM,
		GameEnums.BodyPart.RIGHT_ARM
	]
	var location: GameEnums.BodyPart = locations[randi() % locations.size()]

	var injury := Injury.new(injury_type, severity, location, slide_time)
	player.body_state.add_injury(injury)

	EventBus.injury_occurred.emit(injury)


# =============================================================================
# SELF-ARREST
# =============================================================================

## Attempt self-arrest
func attempt_self_arrest() -> bool:
	if not is_sliding:
		return false

	# Check if player has ice axe
	var has_axe := player.gear_state and player.gear_state.has_ice_axe()
	var axe_effectiveness := 0.0
	if has_axe:
		axe_effectiveness = player.gear_state.get_ice_axe_effectiveness()

	# Calculate arrest success probability
	var success_chance := _calculate_arrest_chance(axe_effectiveness)

	if randf() < success_chance:
		# Successful arrest
		_execute_arrest()
		return true
	else:
		# Failed arrest
		_fail_arrest()
		return false


func _calculate_arrest_chance(axe_effectiveness: float) -> float:
	var chance := 0.5

	# Axe helps significantly
	chance += axe_effectiveness * 0.4

	# Speed reduces chance
	chance -= (current_state.speed / terminal_speed) * 0.5

	# Surface affects arrest
	var surface_bonus := 0.0
	match current_state.surface_type:
		GameEnums.SurfaceType.SNOW_FIRM:
			surface_bonus = 0.3
		GameEnums.SurfaceType.SNOW_SOFT:
			surface_bonus = 0.2
		GameEnums.SurfaceType.ICE:
			surface_bonus = -0.2
		GameEnums.SurfaceType.SCREE:
			surface_bonus = -0.3

	chance += surface_bonus

	# Control level affects chance
	chance += (current_state.control - 0.5) * 0.3

	return clampf(chance, 0.05, 0.95)


func _execute_arrest() -> void:
	# Gradual slowdown
	current_state.velocity *= 0.3

	EventBus.record_incident("self_arrest_success", {
		"speed_before": current_state.speed,
		"position": player.global_position
	})

	end_slide(GameEnums.SlideOutcome.CLEAN_STOP)
	player.change_state(GameEnums.PlayerMovementState.ARRESTED)


func _fail_arrest() -> void:
	# Arrest failure - tumble
	current_state.control *= 0.5
	player.set_stability(player.stability - 0.2)

	EventBus.record_incident("self_arrest_failed", {
		"speed": current_state.speed,
		"position": player.global_position
	})

	# May trigger tumble
	if randf() < 0.5:
		end_slide(GameEnums.SlideOutcome.TUMBLE_STOP)


# =============================================================================
# QUERIES
# =============================================================================

## Get current slide state
func get_state() -> SlideState:
	return current_state


## Check if currently sliding
func is_active() -> bool:
	return is_sliding


## Get slide duration
func get_duration() -> float:
	return slide_time


## Get slide distance
func get_distance() -> float:
	return slide_distance


## Get control as percentage
func get_control_percent() -> float:
	return current_state.control * 100.0


## Check if slide is dangerous
func is_dangerous() -> bool:
	return current_state.risk > 0.6 or current_state.control_level == GameEnums.SlideControlLevel.LOST


# =============================================================================
# DEBUG
# =============================================================================

func get_debug_info() -> Dictionary:
	return {
		"is_sliding": is_sliding,
		"speed": current_state.speed,
		"control": current_state.control,
		"control_level": GameEnums.SlideControlLevel.keys()[current_state.control_level],
		"slope": current_state.slope_angle,
		"surface": GameEnums.SurfaceType.keys()[current_state.surface_type],
		"risk": current_state.risk,
		"cliff_distance": current_state.cliff_distance,
		"exit_distance": current_state.exit_zone_distance,
		"distance_traveled": slide_distance,
		"duration": slide_time,
		"smooth_control": state_manager.smooth_control,
		"is_warning": state_manager.is_warning_active,
		"is_panic": state_manager.is_panicking,
		"feedback_intensity": feedback.get_feedback_intensity()
	}
