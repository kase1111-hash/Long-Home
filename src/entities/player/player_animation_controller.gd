class_name PlayerAnimationController
extends Node
## Controls player animations based on movement state and body condition
##
## Design Philosophy:
## - Animation reflects physical state, not just input
## - Fatigue and injury visibly affect movement
## - Smooth blending between states
## - Works with placeholder or full character model

# =============================================================================
# SIGNALS
# =============================================================================

signal animation_state_changed(old_state: StringName, new_state: StringName)
signal footstep_triggered(foot: StringName, surface: GameEnums.SurfaceType)

# =============================================================================
# CONFIGURATION
# =============================================================================

## Blend time between animation states
const STATE_BLEND_TIME := 0.25

## Speed at which lean blends
const LEAN_BLEND_SPEED := 5.0

## Speed at which posture blends
const POSTURE_BLEND_SPEED := 3.0

## Speed at which fatigue affects animations
const FATIGUE_BLEND_SPEED := 2.0

## Footstep distance threshold (meters)
const FOOTSTEP_DISTANCE := 0.8

## Animation speed ranges
const MIN_ANIM_SPEED := 0.3
const MAX_ANIM_SPEED := 1.5

# =============================================================================
# REFERENCES
# =============================================================================

## Player controller reference
var player: PlayerController

## Player mesh node
var player_mesh: Node3D

## Body mesh (for procedural animations)
var body_mesh: MeshInstance3D

# =============================================================================
# STATE
# =============================================================================

## Current animation state name
var current_anim_state: StringName = &"idle"

## Target animation state
var target_anim_state: StringName = &"idle"

## State transition progress (0-1)
var state_blend: float = 1.0

## Current animation speed multiplier
var anim_speed: float = 1.0

## Lean blend value (-1 to 1)
var lean_blend: float = 0.0

## Posture blend (0=stable, 1=falling)
var posture_blend: float = 0.0

## Fatigue blend (0=fresh, 1=exhausted)
var fatigue_blend: float = 0.0

## Distance traveled for footsteps
var footstep_accumulator: float = 0.0

## Which foot is next
var next_foot: StringName = &"left"

## Time in current state
var state_time: float = 0.0

## Breathing phase for procedural animation
var breathing_phase: float = 0.0

## Shake/stumble offset
var shake_offset: Vector3 = Vector3.ZERO

## Base color for state indication
var base_color: Color = Color(0.7, 0.7, 0.75)

# =============================================================================
# ANIMATION STATE DATA
# =============================================================================

## Animation data per state
var animation_data := {
	&"idle": {
		"base_speed": 1.0,
		"sway_amount": 0.02,
		"breathing_speed": 0.5,
		"color": Color(0.7, 0.7, 0.75),
	},
	&"walking": {
		"base_speed": 1.0,
		"sway_amount": 0.03,
		"breathing_speed": 0.8,
		"color": Color(0.65, 0.7, 0.75),
	},
	&"walking_uphill": {
		"base_speed": 0.8,
		"sway_amount": 0.04,
		"breathing_speed": 1.2,
		"color": Color(0.6, 0.65, 0.7),
	},
	&"walking_downhill": {
		"base_speed": 1.1,
		"sway_amount": 0.035,
		"breathing_speed": 0.9,
		"color": Color(0.65, 0.68, 0.72),
	},
	&"downclimbing": {
		"base_speed": 0.6,
		"sway_amount": 0.02,
		"breathing_speed": 1.0,
		"color": Color(0.6, 0.6, 0.65),
	},
	&"traversing": {
		"base_speed": 0.7,
		"sway_amount": 0.025,
		"breathing_speed": 0.9,
		"color": Color(0.62, 0.65, 0.7),
	},
	&"sliding": {
		"base_speed": 1.5,
		"sway_amount": 0.08,
		"breathing_speed": 1.5,
		"color": Color(0.8, 0.6, 0.5),
	},
	&"sliding_controlled": {
		"base_speed": 1.2,
		"sway_amount": 0.05,
		"breathing_speed": 1.3,
		"color": Color(0.75, 0.65, 0.55),
	},
	&"roping": {
		"base_speed": 0.8,
		"sway_amount": 0.015,
		"breathing_speed": 0.7,
		"color": Color(0.5, 0.6, 0.7),
	},
	&"falling": {
		"base_speed": 2.0,
		"sway_amount": 0.15,
		"breathing_speed": 2.0,
		"color": Color(0.9, 0.4, 0.3),
	},
	&"arrested": {
		"base_speed": 1.0,
		"sway_amount": 0.06,
		"breathing_speed": 1.8,
		"color": Color(0.85, 0.55, 0.4),
	},
	&"resting": {
		"base_speed": 0.3,
		"sway_amount": 0.01,
		"breathing_speed": 0.4,
		"color": Color(0.5, 0.55, 0.6),
	},
	&"incapacitated": {
		"base_speed": 0.1,
		"sway_amount": 0.005,
		"breathing_speed": 0.2,
		"color": Color(0.4, 0.35, 0.35),
	},
}

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	# Get player reference from parent
	player = get_parent() as PlayerController
	if player == null:
		push_error("[AnimationController] Must be child of PlayerController")
		return

	# Find mesh nodes
	player_mesh = player.get_node_or_null("PlayerMesh")
	if player_mesh:
		body_mesh = player_mesh.get_node_or_null("Body") as MeshInstance3D

	_connect_signals()
	print("[AnimationController] Initialized")


func _connect_signals() -> void:
	if player == null:
		return

	player.state_changed.connect(_on_player_state_changed)
	player.stability_changed.connect(_on_stability_changed)
	player.position_updated.connect(_on_position_updated)

	# Connect to EventBus for additional signals
	EventBus.micro_slip_occurred.connect(_on_micro_slip)
	EventBus.fatigue_threshold_crossed.connect(_on_fatigue_threshold)
	EventBus.slide_started.connect(_on_slide_started)
	EventBus.slide_ended.connect(_on_slide_ended)


func _physics_process(delta: float) -> void:
	if player == null:
		return

	state_time += delta

	# Update blends
	_update_state_blend(delta)
	_update_lean_blend(delta)
	_update_posture_blend(delta)
	_update_fatigue_blend(delta)
	_update_breathing(delta)

	# Update animation speed based on velocity
	_update_animation_speed()

	# Apply procedural animations
	_apply_procedural_animation(delta)

	# Check footsteps
	_update_footsteps(delta)


# =============================================================================
# STATE MANAGEMENT
# =============================================================================

func _on_player_state_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	var new_anim := _movement_state_to_animation(new_state)

	if new_anim != target_anim_state:
		var old_anim := current_anim_state
		target_anim_state = new_anim
		state_blend = 0.0
		state_time = 0.0

		animation_state_changed.emit(old_anim, new_anim)
		print("[AnimationController] State: %s -> %s" % [old_anim, new_anim])


func _movement_state_to_animation(state: GameEnums.PlayerMovementState) -> StringName:
	match state:
		GameEnums.PlayerMovementState.STANDING:
			return &"idle"
		GameEnums.PlayerMovementState.WALKING:
			return _get_walking_variant()
		GameEnums.PlayerMovementState.DOWNCLIMBING:
			return &"downclimbing"
		GameEnums.PlayerMovementState.TRAVERSING:
			return &"traversing"
		GameEnums.PlayerMovementState.SLIDING:
			return _get_sliding_variant()
		GameEnums.PlayerMovementState.ROPING:
			return &"roping"
		GameEnums.PlayerMovementState.FALLING:
			return &"falling"
		GameEnums.PlayerMovementState.ARRESTED:
			return &"arrested"
		GameEnums.PlayerMovementState.RESTING:
			return &"resting"
		GameEnums.PlayerMovementState.INCAPACITATED:
			return &"incapacitated"
		_:
			return &"idle"


func _get_walking_variant() -> StringName:
	if player.current_cell == null:
		return &"walking"

	var slope := player.current_cell.slope_angle
	var velocity := player.velocity

	# Check if moving uphill or downhill
	if slope > 15.0:
		var slope_dir := player.get_downhill_direction()
		var move_dir := velocity.normalized()
		var dot := move_dir.dot(slope_dir)

		if dot < -0.3:  # Moving uphill
			return &"walking_uphill"
		elif dot > 0.3:  # Moving downhill
			return &"walking_downhill"

	return &"walking"


func _get_sliding_variant() -> StringName:
	if player.stability > 0.5:
		return &"sliding_controlled"
	return &"sliding"


# =============================================================================
# BLEND UPDATES
# =============================================================================

func _update_state_blend(delta: float) -> void:
	if state_blend < 1.0:
		state_blend = minf(state_blend + delta / STATE_BLEND_TIME, 1.0)

		if state_blend >= 1.0:
			current_anim_state = target_anim_state


func _update_lean_blend(delta: float) -> void:
	var target_lean := 0.0

	if player.input_handler:
		target_lean = player.input_handler.lean_input

	lean_blend = move_toward(lean_blend, target_lean, LEAN_BLEND_SPEED * delta)


func _update_posture_blend(delta: float) -> void:
	var target_posture := 0.0

	match player.posture_state:
		GameEnums.PostureState.STABLE:
			target_posture = 0.0
		GameEnums.PostureState.MARGINAL:
			target_posture = 0.33
		GameEnums.PostureState.UNSTABLE:
			target_posture = 0.66
		GameEnums.PostureState.FALLING:
			target_posture = 1.0

	posture_blend = move_toward(posture_blend, target_posture, POSTURE_BLEND_SPEED * delta)


func _update_fatigue_blend(delta: float) -> void:
	var target_fatigue := 0.0

	var run := GameStateManager.get_current_run()
	if run and run.body_state:
		target_fatigue = run.body_state.fatigue

	fatigue_blend = move_toward(fatigue_blend, target_fatigue, FATIGUE_BLEND_SPEED * delta)


func _update_breathing(delta: float) -> void:
	var data := _get_current_anim_data()
	var breathing_speed: float = data.get("breathing_speed", 1.0)

	# Fatigue increases breathing speed
	breathing_speed *= (1.0 + fatigue_blend * 0.5)

	breathing_phase = fmod(breathing_phase + delta * breathing_speed, TAU)


func _update_animation_speed() -> void:
	var data := _get_current_anim_data()
	var base_speed: float = data.get("base_speed", 1.0)

	# Scale by velocity
	var speed_factor := player.velocity.length() / 5.0  # Normalize to ~5 m/s max
	speed_factor = clampf(speed_factor, 0.3, 1.5)

	# Apply fatigue slowdown
	var fatigue_factor := 1.0 - (fatigue_blend * 0.3)

	anim_speed = base_speed * speed_factor * fatigue_factor
	anim_speed = clampf(anim_speed, MIN_ANIM_SPEED, MAX_ANIM_SPEED)


# =============================================================================
# PROCEDURAL ANIMATION
# =============================================================================

func _apply_procedural_animation(delta: float) -> void:
	if player_mesh == null:
		return

	var data := _get_current_anim_data()
	var sway_amount: float = data.get("sway_amount", 0.02)

	# Increase sway with posture instability
	sway_amount *= (1.0 + posture_blend * 2.0)

	# Breathing sway
	var breath_offset := Vector3(
		sin(breathing_phase) * sway_amount * 0.3,
		sin(breathing_phase * 2.0) * sway_amount,
		cos(breathing_phase * 0.7) * sway_amount * 0.2
	)

	# Lean offset
	var lean_offset := Vector3(lean_blend * 0.1, 0, 0)

	# Posture offset (crouch when unstable)
	var posture_offset := Vector3(0, -posture_blend * 0.15, 0)

	# Shake decay
	shake_offset = shake_offset.move_toward(Vector3.ZERO, delta * 5.0)

	# Apply combined offset
	var total_offset := breath_offset + lean_offset + posture_offset + shake_offset
	player_mesh.position = Vector3(0, 0.9, 0) + total_offset

	# Rotation based on movement and lean
	var target_rotation := Vector3.ZERO

	# Lean rotation
	target_rotation.z = -lean_blend * 0.15

	# Stability wobble
	if posture_blend > 0.3:
		target_rotation.x = sin(state_time * 3.0) * posture_blend * 0.1
		target_rotation.z += cos(state_time * 2.5) * posture_blend * 0.08

	player_mesh.rotation = player_mesh.rotation.lerp(target_rotation, delta * 8.0)

	# Update body mesh color (if placeholder)
	_update_placeholder_color(data)


func _update_placeholder_color(data: Dictionary) -> void:
	if body_mesh == null:
		return

	var material := body_mesh.get_surface_override_material(0)
	if material == null:
		material = StandardMaterial3D.new()
		body_mesh.set_surface_override_material(0, material)

	if material is StandardMaterial3D:
		var target_color: Color = data.get("color", Color(0.7, 0.7, 0.75))

		# Fatigue desaturates and darkens
		target_color = target_color.lerp(Color(0.5, 0.5, 0.55), fatigue_blend * 0.3)

		# Danger states add red tint
		if current_anim_state in [&"falling", &"sliding", &"arrested"]:
			target_color = target_color.lerp(Color(0.9, 0.5, 0.4), 0.3)

		material.albedo_color = material.albedo_color.lerp(target_color, 0.1)


# =============================================================================
# FOOTSTEPS
# =============================================================================

func _update_footsteps(delta: float) -> void:
	# Only trigger footsteps when walking
	if current_anim_state not in [&"walking", &"walking_uphill", &"walking_downhill", &"traversing", &"downclimbing"]:
		return

	var speed := player.velocity.length()
	if speed < 0.5:
		return

	footstep_accumulator += speed * delta

	# Adjust distance for fatigue (tired = slower cadence)
	var step_distance := FOOTSTEP_DISTANCE * (1.0 + fatigue_blend * 0.3)

	if footstep_accumulator >= step_distance:
		footstep_accumulator = 0.0
		_trigger_footstep()


func _trigger_footstep() -> void:
	var surface := GameEnums.SurfaceType.ROCK_DRY
	if player.current_cell:
		surface = player.current_cell.surface_type

	footstep_triggered.emit(next_foot, surface)

	# Alternate feet
	next_foot = &"right" if next_foot == &"left" else &"left"


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_stability_changed(stability: float, posture: GameEnums.PostureState) -> void:
	# Stability changes are handled in _update_posture_blend
	pass


func _on_position_updated(_position: Vector3, _velocity: Vector3) -> void:
	# Position updates are used for footstep tracking
	pass


func _on_micro_slip(severity: float, _position: Vector3) -> void:
	# Apply shake based on slip severity
	shake_offset = Vector3(
		randf_range(-1, 1) * severity * 0.1,
		randf_range(-0.5, 0) * severity * 0.05,
		randf_range(-1, 1) * severity * 0.1
	)


func _on_fatigue_threshold(fatigue: float, threshold_name: String) -> void:
	print("[AnimationController] Fatigue threshold: %s (%.2f)" % [threshold_name, fatigue])


func _on_slide_started(_entry_speed: float, _slope_angle: float) -> void:
	# Could trigger slide start animation
	pass


func _on_slide_ended(_outcome: String, _final_speed: float) -> void:
	# Could trigger slide end animation
	pass


# =============================================================================
# HELPERS
# =============================================================================

func _get_current_anim_data() -> Dictionary:
	# Blend between current and target state data
	var current_data: Dictionary = animation_data.get(current_anim_state, animation_data[&"idle"])
	var target_data: Dictionary = animation_data.get(target_anim_state, animation_data[&"idle"])

	if state_blend >= 1.0:
		return target_data

	# Interpolate values
	var blended := {}
	for key in current_data:
		var current_val = current_data[key]
		var target_val = target_data.get(key, current_val)

		if current_val is float:
			blended[key] = lerpf(current_val, target_val, state_blend)
		elif current_val is Color:
			blended[key] = current_val.lerp(target_val, state_blend)
		else:
			blended[key] = target_val if state_blend > 0.5 else current_val

	return blended


## Get animation state info for debugging
func get_debug_info() -> Dictionary:
	return {
		"state": current_anim_state,
		"target": target_anim_state,
		"blend": state_blend,
		"speed": anim_speed,
		"lean": lean_blend,
		"posture": posture_blend,
		"fatigue": fatigue_blend,
	}
