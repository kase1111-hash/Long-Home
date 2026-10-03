class_name SlideSystem
extends Node
## Core sliding physics: deliberate glissades, and the slides that follow a
## slip, a crash on skis or a tumble after a fall
##
## The slide lives in the player's velocity on the slope plane. Each tick
## (driven by PlayerMovement, so it always runs before move_and_slide) it adds
## gravity along the plane, kinetic friction against the motion, drag, the
## player's lean, and either the brake (heels and axe spike) or a self-arrest.
## move_and_slide then collides, so a boulder really stops you and a lip
## really launches you. Coefficients come from TractionModel: a soft-snow
## glissade is controllable, hard snow runs away, nothing brakes on ice, and
## an axe arrest bites in snow but skates on ice.
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
signal self_arrest_started()
signal self_arrest_engaged()
signal self_arrest_failed(reason: String)

# =============================================================================
# CONSTANTS
# =============================================================================

## Seconds a fall into a slide spends tumbling before the body can be steered
const TUMBLE_DURATION := 0.8
## Slides that start from rest get a push down the fall line (scooting off)
const GLISSADE_PUSH_SPEED := 1.5
## Arrest input is ignored this long after the slide starts (the same press)
const ARREST_INPUT_GRACE := 0.3
## Below this speed for this long the slide is over
const STOP_SPEED := 0.3
const STOP_HOLD_TIME := 0.3
## Faces steeper than this turn a slide into a fall
const FALL_FACE_SLOPE := 60.0

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Physics")
## Gravity constant
@export var gravity: float = 9.8
## Air and snow drag on the body (1/m)
@export var air_resistance: float = TractionModel.BODY_DRAG
## Hard cap on slide speed (m/s)
@export var terminal_speed: float = 25.0
## Speed at which control is nearly lost
@export var critical_speed: float = 15.0

@export_group("Control")
## Control lost per m/s above 5 m/s
@export var speed_control_decay: float = 0.035
## Minimum control at high speed
@export var min_control: float = 0.1

@export_group("Terrain")
## Slope angle below which a slide is a runout (kept for tuning tools)
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

## Fell into this slide rather than sat down into it
var is_uncontrolled: bool = false

## Seconds tumbling since the slide (or the last upset) began
var tumble_time: float = 0.0

## What started this slide ("glissade", "slip", "ski_crash", ...)
var slide_cause: String = ""

## Self-arrest: rolling onto the axe, then the pick biting
var is_arresting: bool = false
var arrest_engaged: bool = false
var arrest_timer: float = 0.0
var arrest_delay: float = 0.5
var arrest_cooldown: float = 0.0

## Slide controller for input handling
var controller: SlideController

## Exit zone detector
var exit_detector: ExitZoneDetector

## State manager for control spectrum
var state_manager: SlideStateManager

## Feedback system for audio/visual
var feedback: SlideFeedback

var _pending_uncontrolled: bool = false
var _pending_cause: String = "glissade"
var _stopped_by_arrest: bool = false
var _still_time: float = 0.0
var _warned_crampons: bool = false


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
	## Current surface friction (effective, including brake or arrest)
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
	## Direction to the nearest cliff
	var cliff_direction: Vector3 = Vector3.ZERO
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

	# Start/stop sliding physics when the player state machine enters/leaves SLIDING
	EventBus.player_movement_changed.connect(_on_player_movement_changed)

	# Register service
	ServiceLocator.register_service("SlideSystem", self)

	print("[SlideSystem] Initialized")


func _on_player_ready(service: Object) -> void:
	player = service as PlayerController
	print("[SlideSystem] Connected to PlayerController")


func _on_terrain_ready(service: Object) -> void:
	terrain_service = service as TerrainService
	print("[SlideSystem] Connected to TerrainService")


func _on_player_movement_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	if new_state == GameEnums.PlayerMovementState.SLIDING:
		begin_slide()
	elif old_state == GameEnums.PlayerMovementState.SLIDING and is_sliding:
		# Something else took over (a fall off an edge, the run ending)
		var outcome := GameEnums.SlideOutcome.CLEAN_STOP
		if new_state == GameEnums.PlayerMovementState.FALLING:
			outcome = GameEnums.SlideOutcome.COMPOUND_SLIDE
		end_slide(outcome, false)


# =============================================================================
# SLIDE LIFECYCLE
# =============================================================================

## Describe the next slide before the player enters SLIDING
func prepare_entry(uncontrolled: bool, cause: String) -> void:
	_pending_uncontrolled = uncontrolled
	_pending_cause = cause


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
	is_uncontrolled = _pending_uncontrolled
	slide_cause = _pending_cause
	_pending_uncontrolled = false
	_pending_cause = "glissade"
	tumble_time = 0.0
	is_arresting = false
	arrest_engaged = false
	arrest_timer = 0.0
	arrest_cooldown = 0.0
	_stopped_by_arrest = false
	_still_time = 0.0

	# Initialize state from current conditions
	_initialize_slide_state()

	if not is_uncontrolled and player.footwear == GameEnums.Footwear.CRAMPONS and not _warned_crampons:
		_warned_crampons = true
		player.say("Crampons still on. Keep your heels up.", 2.5)

	# Record decision
	EventBus.record_decision("slide_initiated", {
		"position": start_position,
		"slope": current_state.slope_angle,
		"entry_speed": current_state.speed,
		"surface": GameEnums.SurfaceType.keys()[current_state.surface_type],
		"cause": slide_cause,
		"uncontrolled": is_uncontrolled
	})

	slide_started.emit(current_state.speed, current_state.slope_angle)
	EventBus.slide_started.emit(current_state.speed, current_state.slope_angle)

	print("[SlideSystem] Slide started (%s) at %.1f°, speed %.1f" % [
		slide_cause, current_state.slope_angle, current_state.speed
	])


## End the slide. change_player_state: pick the player's next state from the
## outcome (false when another system already moved the player on)
func end_slide(outcome: GameEnums.SlideOutcome, change_player_state: bool = true) -> void:
	if not is_sliding:
		return

	is_sliding = false
	is_arresting = false
	arrest_engaged = false

	# Record outcome
	EventBus.record_incident("slide_ended", {
		"outcome": GameEnums.SlideOutcome.keys()[outcome],
		"final_speed": current_state.speed,
		"distance": slide_distance,
		"duration": slide_time,
		"end_position": player.global_position,
		"arrested": _stopped_by_arrest
	})

	slide_ended.emit(outcome, current_state.speed)
	EventBus.slide_ended.emit(outcome, current_state.speed)

	print("[SlideSystem] Slide ended: %s, distance=%.1fm, time=%.1fs" % [
		GameEnums.SlideOutcome.keys()[outcome],
		slide_distance,
		slide_time
	])

	if change_player_state:
		_handle_slide_outcome(outcome)


## Abort slide (emergency)
func abort_slide() -> void:
	end_slide(GameEnums.SlideOutcome.TUMBLE_STOP)


# =============================================================================
# PHYSICS UPDATE
# =============================================================================

## One tick of slide physics; called by PlayerMovement before move_and_slide
func physics_step(delta: float) -> void:
	if not is_sliding or player == null or terrain_service == null:
		return

	slide_time += delta
	tumble_time += delta
	arrest_cooldown = maxf(0.0, arrest_cooldown - delta)

	# Update terrain data
	_update_terrain_data()

	# Arrest progress (rolling over, the pick biting)
	_update_arrest(delta)

	var velocity := player.velocity
	if player.is_on_floor():
		var normal := player.get_floor_normal()
		velocity = TractionModel.onto_slope_plane(velocity, normal)
		velocity = _integrate_on_slope(velocity, normal, delta)
	else:
		# Airborne over a lip: PlayerController adds gravity, the air drags
		var speed := velocity.length()
		if speed > 0.01:
			velocity -= velocity / speed * minf(air_resistance * speed * speed * delta, speed)

	player.velocity = velocity
	current_state.velocity = velocity
	current_state.speed = velocity.length()
	current_state.position = player.global_position
	_face_travel(delta)

	# Hazards of the ride itself
	_check_crampon_catch(delta)
	_check_rock_impacts(delta)

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
	_check_automatic_outcomes(delta)


func _initialize_slide_state() -> void:
	current_state.position = player.global_position
	var velocity := player.velocity

	var cell: TerrainCell = null
	if terrain_service != null:
		cell = terrain_service.get_cell_at(player.global_position)
	if cell != null:
		velocity -= cell.normal * velocity.dot(cell.normal)
		# Scoot off down the fall line when sitting down from a standstill
		if velocity.length() < GLISSADE_PUSH_SPEED and cell.slope_direction.length_squared() > 0.01:
			var fall_line := cell.slope_direction - cell.normal * cell.slope_direction.dot(cell.normal)
			velocity = fall_line.normalized() * GLISSADE_PUSH_SPEED

	player.velocity = velocity
	current_state.velocity = velocity
	current_state.speed = velocity.length()
	current_state.control = 0.3 if is_uncontrolled else 1.0
	current_state.risk = 0.0

	_update_terrain_data()


func _update_terrain_data() -> void:
	var cell := terrain_service.get_cell_at(player.global_position)
	if cell == null:
		return

	current_state.slope_angle = cell.slope_angle
	current_state.slope_direction = cell.slope_direction
	current_state.surface_type = cell.surface_type
	current_state.cliff_distance = cell.distance_to_cliff
	current_state.cliff_direction = cell.cliff_direction

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


## Gravity along the slope plane, friction against the motion, drag, lean
func _integrate_on_slope(velocity: Vector3, normal: Vector3, delta: float) -> Vector3:
	var gravity_vec := Vector3.DOWN * gravity
	var along_plane := gravity_vec - normal * gravity_vec.dot(normal)
	var normal_accel := gravity * maxf(normal.y, 0.05)
	var mu := _current_friction()
	current_state.friction = mu

	var speed := velocity.length()
	if speed < 0.05:
		# At rest, static friction holds unless the slope beats it
		if along_plane.length() <= (mu + TractionModel.BODY_STATIC_EXTRA) * normal_accel:
			return Vector3.ZERO
		var start_dir := along_plane.normalized()
		return start_dir * maxf(along_plane.length() - mu * normal_accel, 0.0) * delta

	var lateral := controller.get_influence_force(delta)
	lateral -= normal * lateral.dot(normal)

	velocity += (along_plane + lateral) * delta

	# Friction and drag oppose the motion and can stop it, never reverse it
	var drag := air_resistance * (0.8 if controller.is_tucked() else 1.0)
	var new_speed := velocity.length()
	var loss := (mu * normal_accel + drag * new_speed * new_speed) * delta
	if loss >= new_speed:
		return Vector3.ZERO
	velocity -= velocity / new_speed * loss

	if velocity.length() > terminal_speed:
		velocity = velocity.normalized() * terminal_speed
	return velocity


## Kinetic friction now: the glide, plus the brake, or the arrest once it bites
func _current_friction() -> float:
	var surface := current_state.surface_type
	var glide := TractionModel.glide_friction(surface)
	if controller.is_tucked() and not is_uncontrolled:
		glide = maxf(glide - 0.03, 0.02)

	var has_axe := player.has_ice_axe()
	if arrest_engaged:
		var arrest := TractionModel.arrest_friction(surface, has_axe)
		var technique := 1.0
		if player.body_state:
			technique = lerpf(0.6, 1.0, player.body_state.get_slide_control_modifier())
		return maxf(glide, arrest * technique)

	if is_uncontrolled and tumble_time < TUMBLE_DURATION:
		return glide + 0.08  # A tumbling body grinds

	var brake := controller.get_brake_level() * TractionModel.brake_friction(surface, has_axe)
	if player.footwear == GameEnums.Footwear.CRAMPONS:
		brake *= 1.15  # The points bite (and catch: see _check_crampon_catch)
	brake *= lerpf(0.5, 1.0, current_state.control)
	return glide + brake


## Feet first, facing down the line of travel
func _face_travel(delta: float) -> void:
	var horizontal := Vector3(current_state.velocity.x, 0.0, current_state.velocity.z)
	if horizontal.length() < 0.5:
		return
	var target := PlayerMovement.yaw_facing(horizontal)
	var diff := wrapf(target - player.rotation.y, -PI, PI)
	player.rotation.y += signf(diff) * minf(absf(diff), 4.0 * delta)


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
			control *= 0.8
		GameEnums.SurfaceType.SCREE:
			control *= 0.6
		GameEnums.SurfaceType.MIXED:
			control *= 0.5
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET:
			control *= 0.3

	# Body state affects control
	if player.body_state:
		control *= player.body_state.get_slide_control_modifier()

	# A fall into a slide starts out of control
	if is_uncontrolled and tumble_time < TUMBLE_DURATION * 2.0:
		control *= lerpf(0.35, 1.0, clampf(tumble_time / (TUMBLE_DURATION * 2.0), 0.0, 1.0))

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


func _check_automatic_outcomes(delta: float) -> void:
	# Over the edge of a cliff band at speed: there is no coming back
	if current_state.cliff_distance < 2.0 and current_state.speed > 8.0:
		var toward := current_state.velocity.normalized().dot(current_state.cliff_direction)
		if toward > 0.3:
			_trigger_terminal_outcome()
			return

	# Onto a face too steep to slide on: it becomes a fall
	if current_state.slope_angle >= FALL_FACE_SLOPE and not TractionModel.is_snow(current_state.surface_type):
		_launch_into_fall()
		return

	# Came to rest
	if current_state.speed < STOP_SPEED:
		_still_time += delta
	else:
		_still_time = 0.0
	if _still_time >= STOP_HOLD_TIME:
		var outcome := GameEnums.SlideOutcome.CLEAN_STOP
		if is_uncontrolled and not _stopped_by_arrest and slide_distance > 8.0:
			outcome = GameEnums.SlideOutcome.TUMBLE_STOP
		end_slide(outcome)
		return

	# Rolled out onto a flat at walking pace
	if current_state.exit_zone_distance < 3.0 and current_state.speed < 1.5 and current_state.slope_angle < 15.0:
		end_slide(GameEnums.SlideOutcome.CLEAN_STOP)


func _trigger_terminal_outcome() -> void:
	EventBus.record_incident("terminal_slide", {
		"position": player.global_position,
		"speed": current_state.speed,
		"cliff_distance": current_state.cliff_distance
	})

	end_slide(GameEnums.SlideOutcome.TERMINAL_RUNOUT)


## The slope fell away: let gravity have the climber
func _launch_into_fall() -> void:
	end_slide(GameEnums.SlideOutcome.COMPOUND_SLIDE, false)
	player.change_state(GameEnums.PlayerMovementState.FALLING)


func _handle_slide_outcome(outcome: GameEnums.SlideOutcome) -> void:
	match outcome:
		GameEnums.SlideOutcome.TUMBLE_STOP:
			_apply_tumble_effects()
		GameEnums.SlideOutcome.TERRAIN_CATCH:
			_apply_terrain_catch_effects()
		GameEnums.SlideOutcome.COMPOUND_SLIDE:
			# Stay in slide but reset some state
			terminal_warning_emitted = false
			return
		GameEnums.SlideOutcome.TERMINAL_RUNOUT:
			_apply_terminal_effects()
			player.change_state(GameEnums.PlayerMovementState.FALLING)
			return

	if _stopped_by_arrest:
		player.change_state(GameEnums.PlayerMovementState.ARRESTED)
	elif player.is_on_skis():
		player.change_state(GameEnums.PlayerMovementState.SKIING)
	elif current_state.slope_angle > PlayerController.DOWNCLIMB_ENTER_SLOPE:
		player.change_state(GameEnums.PlayerMovementState.DOWNCLIMBING)
	else:
		player.change_state(GameEnums.PlayerMovementState.STANDING)


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


func _apply_slide_injury(severity: float, location_pool: Array = []) -> void:
	if player.body_state == null:
		return

	var injury_type := GameEnums.InjuryType.SPRAIN
	if severity > 0.5:
		injury_type = GameEnums.InjuryType.STRAIN
	if severity > 0.7:
		injury_type = GameEnums.InjuryType.LACERATION
	if severity > 0.9:
		injury_type = GameEnums.InjuryType.FRACTURE

	var locations := location_pool
	if locations.is_empty():
		locations = [
			GameEnums.BodyPart.LEFT_LEG,
			GameEnums.BodyPart.RIGHT_LEG,
			GameEnums.BodyPart.LEFT_ARM,
			GameEnums.BodyPart.RIGHT_ARM
		]
	var location: GameEnums.BodyPart = locations[randi() % locations.size()]

	var injury := Injury.new(injury_type, severity, location, slide_time)
	player.body_state.add_injury(injury)

	EventBus.injury_occurred.emit(injury)
	EventBus.body_state_updated.emit(player.body_state)

# =============================================================================
# HAZARDS OF THE RIDE
# =============================================================================

## Digging heels in with crampons on: a point catches and flips you
func _check_crampon_catch(delta: float) -> void:
	if player.footwear != GameEnums.Footwear.CRAMPONS or arrest_engaged:
		return
	var brake := controller.get_brake_level()
	if brake < 0.3 or current_state.speed < 3.0:
		return
	if not TractionModel.is_snow(current_state.surface_type):
		return
	var rate := 0.35 * brake * (current_state.speed / 8.0)
	if randf() >= rate * delta:
		return

	_upset("crampon_catch")
	player.say("A crampon point catches and flips you.", 2.5)
	if randf() < 0.5:
		_apply_slide_injury(randf_range(0.2, 0.45), [GameEnums.BodyPart.LEFT_FOOT, GameEnums.BodyPart.RIGHT_FOOT])


## Tumbling over rock and scree: every few metres something hits back
func _check_rock_impacts(delta: float) -> void:
	var surface := current_state.surface_type
	if not (TractionModel.is_rock(surface) or surface == GameEnums.SurfaceType.SCREE or surface == GameEnums.SurfaceType.MIXED):
		return
	var speed := current_state.speed
	if speed < 3.0 or not player.is_on_floor():
		return
	var rate := 0.4 * pow(speed / 6.0, 2.0)
	if randf() >= rate * delta:
		return

	# Each blow scrubs speed and leaves a mark
	player.velocity *= 0.7
	current_state.velocity = player.velocity
	var parts: Array = [
		GameEnums.BodyPart.LEFT_LEG, GameEnums.BodyPart.RIGHT_LEG,
		GameEnums.BodyPart.LEFT_ARM, GameEnums.BodyPart.RIGHT_ARM,
		GameEnums.BodyPart.TORSO,
	]
	var helmet := player.gear_state != null and player.gear_state.has_item(GameEnums.GearType.HELMET)
	if not helmet:
		parts.append(GameEnums.BodyPart.HEAD)
	_apply_slide_injury(clampf(0.1 + speed / 25.0, 0.1, 0.95), parts)
	EventBus.record_incident("slide_impact", {"speed": speed, "surface": GameEnums.SurfaceType.keys()[surface]})


## Landing after a lip while sliding
func on_landed(impact: float) -> void:
	if not is_sliding or impact < 6.0:
		return
	_upset("hard_landing")
	if randf() < clampf((impact - 6.0) / 6.0, 0.0, 1.0):
		_apply_slide_injury(clampf(0.15 + (impact - 6.0) / 10.0, 0.15, 0.8))


## Knocked out of control mid-slide: tumbling again, any arrest undone
func _upset(cause: String) -> void:
	is_uncontrolled = true
	tumble_time = 0.0
	is_arresting = false
	arrest_engaged = false
	arrest_cooldown = 0.6
	current_state.control *= 0.4
	EventBus.record_incident("slide_upset", {"cause": cause, "speed": current_state.speed})


# =============================================================================
# SELF-ARREST
# =============================================================================

## Attempt self-arrest: roll onto the axe (or dig in hands and toes). The pick
## bites after a moment that grows with speed, tumbling, tiredness and skis
## on your feet; once it bites, the arrest friction does the stopping. At too
## high a speed the pick is torn out of your hands.
func attempt_self_arrest() -> bool:
	if not is_sliding or is_arresting or arrest_cooldown > 0.0:
		return false
	if slide_time < ARREST_INPUT_GRACE:
		return false

	is_arresting = true
	arrest_engaged = false
	arrest_timer = 0.0

	var fatigue := player.get_fatigue()
	arrest_delay = 0.45 + 0.35 * (1.0 - current_state.control) + 0.25 * fatigue
	if is_uncontrolled and tumble_time < TUMBLE_DURATION:
		arrest_delay += 0.4  # Get the feet downhill first
	if player.is_on_skis():
		arrest_delay += 0.3  # Skis in the way
	if not player.has_ice_axe():
		arrest_delay *= 0.8  # Nothing to roll onto: just dig in

	EventBus.record_decision("self_arrest_attempt", {
		"speed": current_state.speed,
		"surface": GameEnums.SurfaceType.keys()[current_state.surface_type],
		"has_axe": player.has_ice_axe(),
		"slope": current_state.slope_angle
	})
	self_arrest_started.emit()
	return true


func _update_arrest(delta: float) -> void:
	if not is_arresting:
		return
	arrest_timer += delta

	if not arrest_engaged and arrest_timer >= arrest_delay:
		var has_axe := player.has_ice_axe()
		if has_axe:
			var hold := TractionModel.arrest_hold_speed(current_state.surface_type)
			hold *= lerpf(0.75, 1.0, player.get_ice_axe_effectiveness())
			if current_state.speed > hold:
				var rip := clampf((current_state.speed - hold) / 6.0, 0.0, 0.9)
				if randf() < rip:
					_axe_torn_out()
					return
		arrest_engaged = true
		self_arrest_engaged.emit()
		if has_axe:
			player.say("You roll onto the axe and drive the pick in.", 2.0)
		else:
			player.say("No axe. Hands and toes into the snow.", 2.0)

	if arrest_engaged and current_state.speed < STOP_SPEED:
		_stopped_by_arrest = true
		EventBus.record_incident("self_arrest_success", {
			"position": player.global_position,
			"distance": slide_distance,
			"surface": GameEnums.SurfaceType.keys()[current_state.surface_type]
		})
		end_slide(GameEnums.SlideOutcome.CLEAN_STOP)


func _axe_torn_out() -> void:
	is_arresting = false
	arrest_engaged = false
	arrest_cooldown = 1.2
	_upset("axe_torn_out")

	var lost := randf() < 0.25
	if player.gear_state != null:
		if lost:
			player.gear_state.remove_item(GameEnums.GearType.ICE_AXE)
		else:
			player.gear_state.damage_item(GameEnums.GearType.ICE_AXE, 0.3)
	player.say("The axe is torn out of your hands." if not lost else "The axe is gone.", 2.5)

	EventBus.record_incident("self_arrest_failed", {
		"speed": current_state.speed,
		"position": player.global_position,
		"axe_lost": lost
	})
	self_arrest_failed.emit("axe_torn_out")


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
		"cause": slide_cause,
		"uncontrolled": is_uncontrolled,
		"speed": current_state.speed,
		"control": current_state.control,
		"control_level": GameEnums.SlideControlLevel.keys()[current_state.control_level],
		"slope": current_state.slope_angle,
		"surface": GameEnums.SurfaceType.keys()[current_state.surface_type],
		"friction": current_state.friction,
		"brake": controller.get_brake_level(),
		"arresting": is_arresting,
		"arrest_engaged": arrest_engaged,
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
