class_name TutorialTriggers
extends Node
## Organic teaching trigger system
## Monitors player behavior and triggers learning moments
##
## Design Philosophy:
## - No explicit tutorials or prompts
## - Player learns through consequence
## - Mistakes have immediate, proportional feedback
## - Recovery teaches more than failure

# =============================================================================
# SIGNALS
# =============================================================================

signal trigger_activated(trigger_type: String, severity: float)
signal lesson_triggered(lesson: String, context: Dictionary)
signal warning_issued(warning_type: String)

# =============================================================================
# ENUMS
# =============================================================================

enum TriggerType {
	BACKWARD_MOVEMENT,      # Moving backward on knife edge
	RAPID_CAMERA,           # Moving camera too fast
	CARELESS_STEP,          # Not watching footing
	SPEED_EXCESS,           # Moving too fast for terrain
	SLOPE_MISJUDGMENT,      # Entering dangerous slope carelessly
	ROPE_SKIP,              # Not using rope when needed
	FATIGUE_IGNORE,         # Pushing through exhaustion
	WEATHER_IGNORE,         # Ignoring weather signs
	EXIT_MISS               # Missing slide exit zone
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Thresholds")
## Camera rotation speed that triggers instability (deg/s)
@export var camera_speed_threshold: float = 120.0
## Movement speed that's "careless" for current terrain
@export var careless_speed_multiplier: float = 1.5
## How long player can ignore rope requirement (seconds)
@export var rope_grace_period: float = 5.0

@export_group("Cooldowns")
## Minimum time between same trigger type (seconds)
@export var trigger_cooldown: float = 3.0

# =============================================================================
# STATE
# =============================================================================

## Player reference
var player: PlayerController

## Tutorial manager reference
var tutorial_manager: TutorialManager

## Terrain service reference
var terrain_service: TerrainService

## Last trigger times (for cooldowns)
var last_trigger_times: Dictionary = {}

## Active warnings
var active_warnings: Array[String] = []

## Rope requirement timer
var rope_required_time: float = 0.0

## Is monitoring active
var is_active: bool = false

## Previous camera rotation for speed calculation
var prev_camera_rotation: Vector3 = Vector3.ZERO

## Previous player position for direction calculation
var prev_player_position: Vector3 = Vector3.ZERO


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("TutorialTriggers", self)
	_get_references()


func _get_references() -> void:
	ServiceLocator.get_service_async("PlayerController", func(s): player = s)
	ServiceLocator.get_service_async("TutorialManager", func(s): tutorial_manager = s)
	ServiceLocator.get_service_async("TerrainService", func(s): terrain_service = s)


## Enable trigger monitoring
func enable() -> void:
	is_active = true
	print("[TutorialTriggers] Enabled")


## Disable trigger monitoring
func disable() -> void:
	is_active = false
	print("[TutorialTriggers] Disabled")


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if not is_active or player == null:
		return

	_check_camera_speed(delta)
	_check_movement_direction(delta)
	_check_movement_speed(delta)
	_check_rope_requirement(delta)
	_check_terrain_danger(delta)

	# Store for next frame
	prev_player_position = player.global_position
	if player.camera_pivot:
		prev_camera_rotation = player.camera_pivot.rotation


# =============================================================================
# TRIGGER CHECKS
# =============================================================================

## Check if camera is moving too fast (causes instability)
func _check_camera_speed(delta: float) -> void:
	if player.camera_pivot == null:
		return

	var current_rot := player.camera_pivot.rotation
	var rot_delta := (current_rot - prev_camera_rotation) / delta
	var rot_speed := rad_to_deg(rot_delta.length())

	if rot_speed > camera_speed_threshold:
		_trigger(TriggerType.RAPID_CAMERA, rot_speed / camera_speed_threshold)


## Check for backward movement on dangerous terrain
func _check_movement_direction(delta: float) -> void:
	if player.current_cell == null:
		return

	# Only check on steep/dangerous terrain
	if player.current_cell.slope_angle < 25.0:
		return

	var move_dir := (player.global_position - prev_player_position).normalized()
	var facing := player.get_facing_direction()

	# Moving backward
	if move_dir.length() > 0.1 and facing.dot(move_dir) < -0.3:
		var danger := player.current_cell.slope_angle / 45.0
		_trigger(TriggerType.BACKWARD_MOVEMENT, danger)


## Check if moving too fast for terrain
func _check_movement_speed(delta: float) -> void:
	if player.current_cell == null:
		return

	var current_speed := player.smooth_velocity.length()
	var safe_speed := _get_safe_speed_for_terrain()

	if current_speed > safe_speed * careless_speed_multiplier:
		var excess := (current_speed - safe_speed) / safe_speed
		_trigger(TriggerType.SPEED_EXCESS, excess)


## Check if rope is required but not being used
func _check_rope_requirement(delta: float) -> void:
	if player.current_cell == null:
		return

	if player.current_cell.requires_rope:
		if player.current_state != GameEnums.PlayerMovementState.ROPING:
			rope_required_time += delta
			if rope_required_time > rope_grace_period:
				_trigger(TriggerType.ROPE_SKIP, 1.0)
				_issue_warning("rope_required")
		else:
			rope_required_time = 0.0
	else:
		rope_required_time = 0.0


## Check for entering dangerous terrain carelessly
func _check_terrain_danger(delta: float) -> void:
	if player.current_cell == null:
		return

	# Check if entering cliff proximity
	if player.current_cell.distance_to_cliff < 5.0:
		if player.smooth_velocity.length() > 1.0:
			_trigger(TriggerType.SLOPE_MISJUDGMENT, 1.0 - player.current_cell.distance_to_cliff / 5.0)


# =============================================================================
# TRIGGER HANDLING
# =============================================================================

func _trigger(type: TriggerType, severity: float) -> void:
	var type_name := TriggerType.keys()[type]

	# Check cooldown
	var current_time := Time.get_ticks_msec() / 1000.0
	if last_trigger_times.has(type_name):
		if current_time - last_trigger_times[type_name] < trigger_cooldown:
			return

	last_trigger_times[type_name] = current_time

	trigger_activated.emit(type_name, severity)

	# Apply consequences based on trigger type
	match type:
		TriggerType.BACKWARD_MOVEMENT:
			_apply_backward_consequence(severity)
		TriggerType.RAPID_CAMERA:
			_apply_camera_consequence(severity)
		TriggerType.CARELESS_STEP:
			_apply_careless_consequence(severity)
		TriggerType.SPEED_EXCESS:
			_apply_speed_consequence(severity)
		TriggerType.SLOPE_MISJUDGMENT:
			_apply_slope_consequence(severity)
		TriggerType.ROPE_SKIP:
			_apply_rope_consequence(severity)


## Backward movement on dangerous terrain
func _apply_backward_consequence(severity: float) -> void:
	if severity > 0.8:
		# Fatal slip in tutorial
		if tutorial_manager and tutorial_manager.is_tutorial_active():
			# Reload with no commentary
			lesson_triggered.emit("back_up_fatal", {"severity": severity})
		else:
			# Regular slip
			player.trigger_micro_slip(severity)
	else:
		player.trigger_micro_slip(severity * 0.5)
		lesson_triggered.emit("back_up_danger", {"severity": severity})


## Fast camera movement causes instability
func _apply_camera_consequence(severity: float) -> void:
	# Reduce stability
	var stability_loss := severity * 0.1
	player.set_stability(player.stability - stability_loss)

	# Camera shake (handled by camera system)
	EventBus.emit_camera_signal(GameEnums.CameraSignal.MICRO_SLIP, severity * 0.3)

	lesson_triggered.emit("camera_stability", {"severity": severity})


## Careless stepping
func _apply_careless_consequence(severity: float) -> void:
	player.trigger_micro_slip(severity * 0.4)
	lesson_triggered.emit("careful_footing", {"severity": severity})


## Moving too fast
func _apply_speed_consequence(severity: float) -> void:
	# Increased fatigue
	if player.body_state:
		player.body_state.add_fatigue(severity * 0.05)

	# Small slip chance
	if randf() < severity * 0.3:
		player.trigger_micro_slip(severity * 0.3)

	lesson_triggered.emit("speed_danger", {"severity": severity})


## Misjudging slope danger
func _apply_slope_consequence(severity: float) -> void:
	if severity > 0.7:
		# Major slip
		player.trigger_micro_slip(severity)
		lesson_triggered.emit("slope_reading", {"severity": severity})
	else:
		# Warning only
		_issue_warning("slope_danger")


## Skipping required rope
func _apply_rope_consequence(severity: float) -> void:
	# High probability of fall without rope
	if randf() < 0.5:
		player.trigger_micro_slip(0.8)
		lesson_triggered.emit("rope_necessity", {"severity": 1.0})


# =============================================================================
# WARNINGS
# =============================================================================

func _issue_warning(warning_type: String) -> void:
	if active_warnings.has(warning_type):
		return

	active_warnings.append(warning_type)
	warning_issued.emit(warning_type)

	# Clear warning after a time
	get_tree().create_timer(10.0).timeout.connect(func():
		active_warnings.erase(warning_type)
	)


# =============================================================================
# HELPERS
# =============================================================================

func _get_safe_speed_for_terrain() -> float:
	if player.current_cell == null:
		return 2.0

	var base_speed := 2.0

	# Reduce for slope
	var slope := player.current_cell.slope_angle
	if slope > 20:
		base_speed *= 1.0 - ((slope - 20) / 50.0) * 0.6

	# Reduce for surface
	match player.current_cell.surface_type:
		GameEnums.SurfaceType.ICE:
			base_speed *= 0.4
		GameEnums.SurfaceType.ROCK_WET:
			base_speed *= 0.6
		GameEnums.SurfaceType.SCREE:
			base_speed *= 0.7

	return base_speed


func _can_trigger(type: TriggerType) -> bool:
	var type_name := TriggerType.keys()[type]
	var current_time := Time.get_ticks_msec() / 1000.0

	if last_trigger_times.has(type_name):
		return current_time - last_trigger_times[type_name] >= trigger_cooldown

	return true


# =============================================================================
# QUERIES
# =============================================================================

func get_active_warnings() -> Array[String]:
	return active_warnings


func get_summary() -> Dictionary:
	return {
		"active": is_active,
		"active_warnings": active_warnings,
		"trigger_count": last_trigger_times.size()
	}
