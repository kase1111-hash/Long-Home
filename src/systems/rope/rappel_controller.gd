class_name RappelController
extends Node
## Controls player descent while on rope
## Handles rappel physics, speed regulation, and risk
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
signal anchor_stress_warning(stress: float)
signal terrain_contact(position: Vector3)

# =============================================================================
# ENUMS
# =============================================================================

enum RappelOutcome {
	COMPLETE,        # Reached bottom safely
	ROPE_END,        # Ran out of rope (need to re-anchor)
	ROPE_JAM,        # Rope stuck, need to clear
	ANCHOR_FAILURE,  # Anchor gave way
	ABORTED          # Player cancelled
}


# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Speed")
## Maximum safe descent speed (m/s)
@export var safe_speed: float = 1.0
## Maximum possible speed (dangerous)
@export var max_speed: float = 3.0
## Acceleration when releasing brake
@export var descent_acceleration: float = 2.0
## Deceleration when applying brake
@export var brake_deceleration: float = 5.0

@export_group("Rope")
## Warning threshold for remaining rope (meters)
@export var rope_warning_threshold: float = 5.0
## Base jam probability per meter descended
@export var base_jam_chance: float = 0.002

@export_group("Risk")
## Speed threshold for increased risk
@export var risky_speed: float = 2.0
## Anchor stress per unit speed over safe
@export var speed_stress_factor: float = 0.1


# =============================================================================
# STATE
# =============================================================================

## Is currently rappelling
var is_rappelling: bool = false

## Active rope
var active_rope: Rope = null

## Active anchor
var active_anchor: AnchorPoint = null

## Rope remaining (meters)
var rope_remaining: float = 0.0

## Current descent speed
var current_speed: float = 0.0

## Target speed (from input)
var target_speed: float = 0.0

## Total distance descended
var distance_descended: float = 0.0

## Is rope jammed
var is_jammed: bool = false

## Jam clear progress (0-1)
var jam_clear_progress: float = 0.0

## Player reference
var player: Node

## Terrain service reference
var terrain_service: TerrainService

## Accumulated anchor stress
var anchor_stress: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("PlayerController", _on_player_ready)
	ServiceLocator.get_service_async("TerrainService", _on_terrain_ready)
	ServiceLocator.register_service("RappelController", self)


func _on_player_ready(service: Object) -> void:
	player = service


func _on_terrain_ready(service: Object) -> void:
	terrain_service = service as TerrainService


# =============================================================================
# RAPPEL LIFECYCLE
# =============================================================================

## Begin rappelling
func begin_rappel(rope: Rope, anchor: AnchorPoint) -> bool:
	if is_rappelling:
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
	anchor_stress = 0.0
	is_rappelling = true

	rappel_started.emit(rope, anchor)
	EventBus.rappel_started.emit()

	return true


## End rappelling
func end_rappel(outcome: RappelOutcome) -> void:
	if not is_rappelling:
		return

	is_rappelling = false

	# Handle outcomes
	match outcome:
		RappelOutcome.COMPLETE:
			_complete_rappel()
		RappelOutcome.ROPE_END:
			_handle_rope_end()
		RappelOutcome.ROPE_JAM:
			_handle_jam_abort()
		RappelOutcome.ANCHOR_FAILURE:
			_handle_anchor_failure()
		RappelOutcome.ABORTED:
			_handle_abort()

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
	if not is_rappelling:
		return

	if is_jammed:
		_process_jam(delta)
		return

	# Update speed
	_update_speed(delta)

	# Apply descent
	if current_speed > 0.01:
		_apply_descent(delta)

	# Check for jams
	_check_for_jam(delta)

	# Check anchor stress
	_update_anchor_stress(delta)

	# Check rope remaining
	_check_rope_remaining()


func _update_speed(delta: float) -> void:
	if target_speed > current_speed:
		# Accelerating (releasing brake)
		current_speed = minf(target_speed, current_speed + descent_acceleration * delta)
	else:
		# Decelerating (applying brake)
		current_speed = maxf(target_speed, current_speed - brake_deceleration * delta)

	current_speed = clampf(current_speed, 0.0, max_speed)
	speed_changed.emit(current_speed)


func _apply_descent(delta: float) -> void:
	var descent := current_speed * delta

	rope_remaining -= descent
	distance_descended += descent

	# Move player down along rope
	if player and player.has_method("apply_rappel_movement"):
		player.apply_rappel_movement(Vector3.DOWN * descent)

	# Check for terrain contact
	_check_terrain_contact()

	# Apply rope wear
	if active_rope:
		var wear := descent * 0.0001  # Very small wear per meter
		if current_speed > risky_speed:
			wear *= 2.0  # Fast descent wears rope more
		active_rope.apply_damage(wear)


func _check_for_jam(delta: float) -> void:
	if active_rope == null:
		return

	# Calculate jam probability
	var jam_chance := base_jam_chance * delta

	# Rope condition affects jam chance
	jam_chance += (1.0 - active_rope.condition) * 0.005

	# Speed affects jam chance
	if current_speed > risky_speed:
		jam_chance += (current_speed - risky_speed) * 0.002

	# Terrain affects jam chance (would query terrain service)
	if terrain_service:
		var cell := terrain_service.get_cell_at(player.global_position if player else Vector3.ZERO)
		if cell and cell.surface_type == GameEnums.SurfaceType.ROCK:
			# Rocky terrain has more edges to catch rope
			jam_chance += 0.003

	# Wet rope more likely to jam
	if active_rope.is_wet:
		jam_chance *= 1.5

	if randf() < jam_chance:
		_trigger_jam()


func _trigger_jam() -> void:
	is_jammed = true
	jam_clear_progress = 0.0
	current_speed = 0.0

	rope_jam_occurred.emit()
	EventBus.record_incident("rope_jam", {
		"position": player.global_position if player else Vector3.ZERO,
		"rope_remaining": rope_remaining
	})


func _process_jam(delta: float) -> void:
	# Player must work to clear jam (would be input-driven)
	# For now, auto-clear slowly
	jam_clear_progress += delta * 0.2

	if jam_clear_progress >= 1.0:
		is_jammed = false
		rope_jam_cleared.emit()


func _update_anchor_stress(delta: float) -> void:
	# Base stress from body weight
	var stress := 0.01 * delta

	# Speed adds stress
	if current_speed > safe_speed:
		stress += (current_speed - safe_speed) * speed_stress_factor * delta

	# Jerky movements add stress (speed changes)
	# Would track acceleration

	anchor_stress += stress

	if anchor_stress > 0.5:
		anchor_stress_warning.emit(anchor_stress)

	# Check for anchor failure
	if active_anchor:
		var failure_chance := anchor_stress * (1.0 - active_anchor.get_effective_quality()) * 0.01
		if randf() < failure_chance:
			end_rappel(RappelOutcome.ANCHOR_FAILURE)


func _check_rope_remaining() -> void:
	if rope_remaining <= 0.0:
		end_rappel(RappelOutcome.ROPE_END)
		return

	if rope_remaining <= rope_warning_threshold:
		rope_running_low.emit(rope_remaining)


func _check_terrain_contact() -> void:
	if player == null or terrain_service == null:
		return

	# Check if reached stable ground
	var cell := terrain_service.get_cell_at(player.global_position)
	if cell == null:
		return

	# If terrain is flat enough to stand, can end rappel
	if cell.slope_angle < 40.0:
		terrain_contact.emit(player.global_position)
		end_rappel(RappelOutcome.COMPLETE)


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


## Attempt to clear rope jam
func clear_jam(effort: float) -> void:
	if not is_jammed:
		return

	jam_clear_progress += effort * 0.1
	if jam_clear_progress >= 1.0:
		is_jammed = false
		rope_jam_cleared.emit()


# =============================================================================
# OUTCOME HANDLERS
# =============================================================================

func _complete_rappel() -> void:
	# Successfully reached bottom
	if active_anchor:
		active_anchor.deactivate()

	# Rope needs recovery
	EventBus.record_decision("rappel_complete", {
		"distance": distance_descended,
		"max_speed": current_speed
	})


func _handle_rope_end() -> void:
	# Ran out of rope but not at bottom
	# Player must find new anchor or climb back up
	EventBus.record_incident("rope_end_reached", {
		"distance": distance_descended,
		"position": player.global_position if player else Vector3.ZERO
	})


func _handle_jam_abort() -> void:
	# Couldn't clear jam, need to cut rope or climb
	EventBus.record_incident("rope_jam_abort", {
		"position": player.global_position if player else Vector3.ZERO
	})


func _handle_anchor_failure() -> void:
	# Anchor gave way - this is very bad
	EventBus.record_incident("anchor_failure", {
		"position": player.global_position if player else Vector3.ZERO,
		"anchor_stress": anchor_stress
	})

	# Player falls
	if player and player.has_method("trigger_fall"):
		player.trigger_fall()


func _handle_abort() -> void:
	# Player chose to abort
	EventBus.record_decision("rappel_abort", {
		"distance": distance_descended
	})


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
