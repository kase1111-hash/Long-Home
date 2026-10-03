class_name RappelController
extends Node
## Lowers the climber down a face on a doubled rope
##
## The climber hangs on the rope with their feet on the face; this places
## them on the surface each tick (the player is kinematic while ROPING).
## Pushing down the face (camera-relative, like walking) lets rope run
## through the device up to a safe pace; holding Space as well lets it run
## fast, which loads the anchor, snags more and wears the rope. Letting go
## brakes to a stop, quicker with warm hands than numb ones. Pushing up the
## face prusiks back up slowly; sideways walks across the face within the
## swing of the rope. The rappel ends when the feet find ground a climber can
## stand on. At the knots at the rope's end the only ways on are another
## anchor (R) or back up the rope.
##
## Design Philosophy:
## - Rappel is safe but slow
## - Speed regulation is manual (faster = more risk)
## - Rope jams are possible based on terrain
## - Players control descent rate with friction

# =============================================================================
# SIGNALS
# =============================================================================

signal rappel_started(rope: Rope, anchor: AnchorPoint)
signal rappel_ended(outcome: RappelOutcome)
signal speed_changed(speed: float)
signal rope_jam_occurred()
signal rope_jam_cleared()
signal rope_running_low(remaining: float)
signal rope_end_reached()
signal anchor_stress_warning(stress: float)
signal terrain_contact(position: Vector3)

# =============================================================================
# ENUMS
# =============================================================================

enum RappelOutcome {
	COMPLETE,        # Reached ground you can stand on
	ROPE_END,        # Ran out of rope (need to re-anchor)
	ROPE_JAM,        # Rope stuck, need to clear
	ANCHOR_FAILURE,  # Anchor gave way
	ABORTED          # Unclipped (or re-anchoring) before the bottom
}


# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Speed")
## Comfortable descent speed with the brake hand easing off (m/s)
@export var safe_speed: float = 1.0
## Letting it run (m/s): fast and dangerous
@export var max_speed: float = 3.0
## Acceleration when the brake hand eases off
@export var descent_acceleration: float = 2.0
## Deceleration when the brake hand locks off (warm hands)
@export var brake_deceleration: float = 5.0
## Prusiking back up the rope (m/s)
@export var ascent_speed: float = 0.2
## Walking across the face on the rope (m/s)
@export var lateral_speed: float = 0.4

@export_group("Rope")
## Warning threshold for remaining rope (meters)
@export var rope_warning_threshold: float = 5.0
## Snags per metre of rope run over snow and ice
@export var jam_per_metre: float = 0.0015
## Snags per metre over rock edges and flakes
@export var jam_per_metre_rock: float = 0.0045

@export_group("Risk")
## Speed threshold for increased risk
@export var risky_speed: float = 2.0
## Anchor failures per second at quality 0 and normal load
@export var anchor_failure_scale: float = 0.008

@export_group("Ground")
## Ground gentler than this is somewhere to stand (degrees)
@export var touchdown_slope: float = 40.0
## Seconds on standable ground before you are off the rope
@export var touchdown_time: float = 0.5
## How far the body hangs off the face (metres along the normal)
@export var standoff: float = 0.35


# =============================================================================
# STATE
# =============================================================================

## Is currently rappelling
var is_rappelling: bool = false

## Active rope
var active_rope: Rope = null

## Active anchor
var active_anchor: AnchorPoint = null

## Rope remaining below the climber (meters)
var rope_remaining: float = 0.0

## Current speed down the face (m/s, negative when climbing back up)
var current_speed: float = 0.0

## Target speed (from input)
var target_speed: float = 0.0

## Rope paid out below the anchor (meters)
var distance_descended: float = 0.0

## Is rope jammed
var is_jammed: bool = false

## Jam clear progress (0-1)
var jam_clear_progress: float = 0.0

## Hanging at the knots at the end of the rope
var at_rope_end: bool = false

## No harness: a body rappel with the rope round the hips and shoulder
var is_body_rappel: bool = false

## Player reference
var player: PlayerController

## Terrain service reference
var terrain_service: TerrainService

## Accumulated anchor stress (for warnings)
var anchor_stress: float = 0.0

## Where the climber is on the face (feet on the surface, xz matter)
var face_position: Vector3 = Vector3.ZERO

var _fall_line: Vector3 = Vector3.FORWARD
var _start_position: Vector3 = Vector3.ZERO
var _jam_clear_time: float = 4.0
var _touchdown_timer: float = 0.0
## Has the climber been out on the steep face yet (the ledge at the top is not the bottom)
var _been_on_face: bool = false
var _low_rope_warned: bool = false
var _last_speed: float = 0.0
var _progress_timer: float = 0.0
var _max_speed_reached: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("PlayerController", _on_player_ready)
	ServiceLocator.get_service_async("TerrainService", _on_terrain_ready)
	ServiceLocator.register_service("RappelController", self)


func _on_player_ready(service: Object) -> void:
	player = service as PlayerController


func _on_terrain_ready(service: Object) -> void:
	terrain_service = service as TerrainService


# =============================================================================
# RAPPEL LIFECYCLE
# =============================================================================

## Begin rappelling from where the climber stands
func begin_rappel(rope: Rope, anchor: AnchorPoint) -> bool:
	if is_rappelling or player == null or terrain_service == null:
		return false

	if rope == null or anchor == null:
		return false

	if not rope.is_deployed:
		return false

	active_rope = rope
	active_anchor = anchor
	rope_remaining = rope.deployed_length
	current_speed = 0.0
	target_speed = 0.0
	distance_descended = 0.0
	is_jammed = false
	at_rope_end = false
	anchor_stress = 0.0
	_touchdown_timer = 0.0
	_been_on_face = false
	_low_rope_warned = false
	_last_speed = 0.0
	_max_speed_reached = 0.0
	is_body_rappel = player.gear_state == null or not player.gear_state.has_item(GameEnums.GearType.HARNESS)

	face_position = player.global_position
	_start_position = face_position
	var cell := terrain_service.get_cell_at(face_position)
	_fall_line = _flat_or(cell.slope_direction if cell else Vector3.ZERO, -player.get_facing_direction())
	is_rappelling = true
	_place_player(0.0)

	rappel_started.emit(rope, anchor)
	EventBus.rappel_started.emit()

	return true


## End rappelling
func end_rappel(outcome: RappelOutcome) -> void:
	if not is_rappelling:
		return

	is_rappelling = false
	is_jammed = false

	match outcome:
		RappelOutcome.COMPLETE:
			if active_anchor:
				active_anchor.deactivate()
			EventBus.record_decision("rappel_complete", {
				"distance": distance_descended,
				"max_speed": _max_speed_reached
			})
		RappelOutcome.ANCHOR_FAILURE:
			EventBus.record_incident("anchor_failure", {
				"position": player.global_position if player else Vector3.ZERO,
				"anchor_type": AnchorPoint.AnchorType.keys()[active_anchor.anchor_type] if active_anchor else "unknown",
				"speed": current_speed,
				"distance": distance_descended
			})
		RappelOutcome.ABORTED:
			EventBus.record_decision("rappel_abort", {
				"distance": distance_descended,
				"at_rope_end": at_rope_end
			})

	current_speed = 0.0
	rappel_ended.emit(outcome)
	EventBus.rappel_ended.emit(outcome)

	active_rope = null
	active_anchor = null


## Abort rappel
func abort() -> void:
	if is_rappelling:
		end_rappel(RappelOutcome.ABORTED)


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if not is_rappelling or player == null or terrain_service == null:
		return
	if player.current_state != GameEnums.PlayerMovementState.ROPING:
		return

	if is_jammed:
		_process_jam(delta)
		_place_player(delta)
		return

	var input := _read_input()
	_update_speed(input.x, input.y, delta)
	var descended := _move(input.x, input.y, delta)
	_place_player(delta)

	_check_for_jam(descended)
	_update_anchor_stress(delta)
	if not is_rappelling:
		return

	_check_rope_remaining()
	_check_touchdown(delta)
	_apply_effort(delta)

	_progress_timer += delta
	if _progress_timer >= 0.25:
		_progress_timer = 0.0
		EventBus.rappel_progress.emit(rope_remaining, current_speed)


## (down the face, across the face) from camera-relative input, each -1..1
func _read_input() -> Vector2:
	var direction := player.movement.get_input_direction_world()
	if direction == Vector3.ZERO:
		return Vector2.ZERO
	var down := _down_direction()
	var side := down.cross(Vector3.UP).normalized()
	return Vector2(direction.dot(down), direction.dot(side))


func _update_speed(along: float, across_input: float, delta: float) -> void:
	var fast := player.input_handler.is_action_held("slide_initiate")
	var safe := safe_speed * (0.5 if is_body_rappel else 1.0)
	var top := minf(max_speed, 1.0) if is_body_rappel else max_speed

	if along > 0.3 and along >= absf(across_input):
		target_speed = top if fast else safe
	elif along < -0.3 and -along >= absf(across_input):
		target_speed = -ascent_speed
	else:
		target_speed = 0.0
	if at_rope_end and target_speed > 0.0:
		target_speed = 0.0

	var hands := 1.0
	if player.body_state:
		hands = player.body_state.get_rope_handling_modifier()

	_last_speed = current_speed
	if target_speed > current_speed:
		current_speed = minf(target_speed, current_speed + descent_acceleration * delta)
	else:
		# Numb hands lock the rope off slowly
		current_speed = maxf(target_speed, current_speed - brake_deceleration * lerpf(0.4, 1.0, hands) * delta)

	current_speed = clampf(current_speed, -ascent_speed, max_speed)
	_max_speed_reached = maxf(_max_speed_reached, current_speed)
	speed_changed.emit(current_speed)


## Move along the face; returns the metres of rope that ran out this tick
func _move(along: float, across: float, delta: float) -> float:
	var step := current_speed * delta
	if step > 0.0:
		step = minf(step, rope_remaining)
	else:
		step = maxf(step, -distance_descended)

	if absf(step) > 0.00001:
		var down := _down_direction()
		face_position = _walk_along_face(face_position, down * signf(step), absf(step))
		rope_remaining -= step
		distance_descended += step

	# Across the face, within the swing of the rope. Sideways is across this
	# face (not the slope at the anchor), and takes a deliberate push: leaning
	# on the down input must never walk the climber back up a steep face
	if absf(across) > 0.5 and absf(across) > absf(along):
		var side := _down_direction().cross(Vector3.UP).normalized()
		var swing := _fall_line.cross(Vector3.UP).normalized()
		var offset := (face_position - _start_position).dot(swing)
		var reach := 1.0 + 0.35 * distance_descended
		var move := side * lateral_speed * signf(across) * delta
		if absf(offset + move.dot(swing)) <= reach:
			face_position += move

	# Rope wear: a little per metre, more when it runs hot
	if step > 0.0 and active_rope:
		var wear := step * 0.0001
		if current_speed > risky_speed:
			wear *= 2.0
		active_rope.apply_damage(wear)

	return maxf(step, 0.0)


## A step of surface distance along a horizontal direction on the face
func _walk_along_face(from: Vector3, direction: Vector3, surface_distance: float) -> Vector3:
	var cell := terrain_service.get_cell_at(from)
	var slope := cell.slope_angle if cell else 45.0
	var horizontal := maxf(surface_distance * cos(deg_to_rad(slope)), surface_distance * 0.02)
	var height := terrain_service.get_height_at(from)
	var drop := terrain_service.get_height_at(from + direction * horizontal) - height
	var travelled := sqrt(horizontal * horizontal + drop * drop)
	if travelled > 0.00001:
		horizontal *= surface_distance / travelled
	return from + direction * horizontal


## Hang the climber on the face at face_position, facing the rock
func _place_player(delta: float) -> void:
	var cell := terrain_service.get_cell_at(face_position)
	var normal := cell.normal if cell else Vector3.UP
	var ground := Vector3(face_position.x, terrain_service.get_height_at(face_position), face_position.z)
	var target := ground + normal * standoff
	if delta > 0.0:
		# Ease onto the spot: the face normal jumps from cell to cell
		target = player.global_position.lerp(target, clampf(15.0 * delta, 0.0, 1.0))
		player.velocity = (target - player.global_position) / delta
	player.global_position = target

	var face_in := -_down_direction()
	var yaw := PlayerMovement.yaw_facing(face_in)
	player.rotation.y = lerp_angle(player.rotation.y, yaw, clampf(6.0 * delta, 0.0, 1.0)) if delta > 0.0 else yaw


func _down_direction() -> Vector3:
	var cell: TerrainCell = null
	if terrain_service != null:
		cell = terrain_service.get_cell_at(face_position)
	if cell == null or cell.slope_direction.length_squared() < 0.01:
		return _fall_line
	# Lean on the fall line from the anchor so noisy cells do not twist the path
	return (cell.slope_direction * 0.7 + _fall_line * 0.3).normalized()


func _flat_or(direction: Vector3, fallback: Vector3) -> Vector3:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() > 0.01:
		return flat.normalized()
	var other := Vector3(fallback.x, 0.0, fallback.z)
	return other.normalized() if other.length_squared() > 0.01 else Vector3.FORWARD


# =============================================================================
# HAZARDS
# =============================================================================

func _check_for_jam(descended: float) -> void:
	if descended <= 0.0 or active_rope == null:
		return
	var per_metre := jam_per_metre
	var cell := terrain_service.get_cell_at(face_position)
	if cell != null and (TractionModel.is_rock(cell.surface_type) or cell.surface_type == GameEnums.SurfaceType.MIXED):
		per_metre = jam_per_metre_rock
	per_metre += (1.0 - active_rope.condition) * 0.006
	if active_rope.is_wet:
		per_metre *= 1.5
	if current_speed > risky_speed:
		per_metre *= 2.0
	if randf() < per_metre * descended:
		_trigger_jam()


func _trigger_jam() -> void:
	is_jammed = true
	jam_clear_progress = 0.0
	current_speed = 0.0
	var hands := player.body_state.get_rope_handling_modifier() if player.body_state else 1.0
	_jam_clear_time = randf_range(3.0, 6.0) / maxf(hands, 0.3)

	rope_jam_occurred.emit()
	EventBus.rope_jammed.emit(player.global_position)
	EventBus.record_incident("rope_jam", {
		"position": player.global_position,
		"rope_remaining": rope_remaining
	})


func _process_jam(delta: float) -> void:
	# Working at it (any input) frees it faster than waiting for it to give
	var effort := 1.5 if player.input_handler.has_active_input() else 1.0
	jam_clear_progress += delta * effort / _jam_clear_time
	if jam_clear_progress >= 1.0:
		is_jammed = false
		rope_jam_cleared.emit()


## Attempt to clear rope jam
func clear_jam(effort: float) -> void:
	if not is_jammed:
		return

	jam_clear_progress += effort * 0.1
	if jam_clear_progress >= 1.0:
		is_jammed = false
		rope_jam_cleared.emit()


func _update_anchor_stress(delta: float) -> void:
	if active_anchor == null:
		return
	var safe := safe_speed * (0.5 if is_body_rappel else 1.0)
	var load := 1.0
	if current_speed > safe:
		load += 3.0 * (current_speed - safe) / safe
	# Locking off hard from speed shock-loads the anchor
	var decel := (_last_speed - current_speed) / maxf(delta, 0.001)
	if decel > 3.0:
		load += decel * 0.5

	anchor_stress += load * delta * 0.01
	if load > 2.5:
		anchor_stress_warning.emit(anchor_stress)

	var quality := active_anchor.get_effective_quality()
	var hazard := anchor_failure_scale * pow(1.0 - quality, 3.0) * load
	if randf() < hazard * delta:
		end_rappel(RappelOutcome.ANCHOR_FAILURE)


func _check_rope_remaining() -> void:
	if rope_remaining <= 0.01 and not at_rope_end:
		at_rope_end = true
		current_speed = minf(current_speed, 0.0)
		rope_end_reached.emit()
		EventBus.record_incident("rope_end_reached", {
			"distance": distance_descended,
			"position": player.global_position
		})
	elif rope_remaining > 0.5:
		at_rope_end = false

	if rope_remaining <= rope_warning_threshold and not _low_rope_warned:
		_low_rope_warned = true
		rope_running_low.emit(rope_remaining)


func _check_touchdown(delta: float) -> void:
	var cell := terrain_service.get_cell_at(face_position)
	if cell != null and cell.slope_angle >= touchdown_slope + 5.0:
		_been_on_face = true
	if distance_descended < 2.0 or not _been_on_face:
		_touchdown_timer = 0.0
		return
	if cell != null and cell.slope_angle < touchdown_slope:
		_touchdown_timer += delta
	else:
		_touchdown_timer = 0.0
	if _touchdown_timer >= touchdown_time:
		terrain_contact.emit(player.global_position)
		end_rappel(RappelOutcome.COMPLETE)


func _apply_effort(delta: float) -> void:
	var rate := 0.0004
	if current_speed < 0.0:
		rate = 0.004  # Prusiking up is hard work
	if is_body_rappel:
		rate *= 2.0
	player.add_fatigue(rate * delta)


# =============================================================================
# INPUT HANDLING
# =============================================================================

## Set target descent speed (from player input)
func set_target_speed(speed: float) -> void:
	target_speed = clampf(speed, 0.0, max_speed)


## Apply brake (stop)
func apply_brake() -> void:
	target_speed = 0.0


## Release brake (descend at safe speed)
func release_brake() -> void:
	target_speed = safe_speed


## Fast descent (risky)
func fast_descent() -> void:
	target_speed = max_speed


# =============================================================================
# QUERIES
# =============================================================================

## Get current rappel state
func get_state() -> Dictionary:
	return {
		"is_rappelling": is_rappelling,
		"speed": current_speed,
		"rope_remaining": rope_remaining,
		"distance_descended": distance_descended,
		"is_jammed": is_jammed,
		"jam_progress": jam_clear_progress if is_jammed else 0.0,
		"at_rope_end": at_rope_end,
		"body_rappel": is_body_rappel,
		"anchor_stress": anchor_stress
	}


## Check if speed is risky
func is_speed_risky() -> bool:
	return current_speed > risky_speed


## Get speed as percentage of max
func get_speed_percent() -> float:
	return current_speed / max_speed


## Get rope remaining as percentage
func get_rope_remaining_percent() -> float:
	if active_rope == null:
		return 0.0
	return rope_remaining / active_rope.deployed_length
