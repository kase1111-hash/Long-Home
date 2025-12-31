class_name Instructor
extends CharacterBody3D
## Tutorial instructor NPC
## Provides diegetic guidance through voice and action
##
## Design Philosophy:
## - Voice is the only teaching tool - no UI
## - Models good behavior through movement
## - Can fall in hard mode, requiring rescue

# =============================================================================
# SIGNALS
# =============================================================================

signal line_spoken(line_id: String, text: String)
signal gesture_made(gesture_type: String, target: Vector3)
signal demonstration_started(action: String)
signal demonstration_completed(action: String)
signal accident_triggered()
signal rescued()

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Voice")
## Audio stream for instructor voice lines
@export var voice_lines: Dictionary = {}  # line_id -> AudioStream

@export_group("Movement")
## Walk speed
@export var walk_speed: float = 1.8
## Careful movement speed
@export var careful_speed: float = 0.8

@export_group("Animation")
## Time to complete a gesture
@export var gesture_duration: float = 2.0
## Time to complete slide demonstration
@export var slide_demo_duration: float = 4.0

# =============================================================================
# STATE
# =============================================================================

## Lines that have been spoken
var spoken_lines: Array[String] = []

## Is currently speaking
var is_speaking: bool = false

## Current spoken line
var current_line: String = ""

## Is performing demonstration
var is_demonstrating: bool = false

## Current demonstration
var current_demo: String = ""

## Has fallen (hard mode)
var has_fallen: bool = false

## Is rescued
var is_rescued: bool = false

## Is visible to player
var is_visible: bool = true

## Target position for movement
var move_target: Vector3 = Vector3.ZERO

## Is moving
var is_moving: bool = false

## Rope attached to player
var rope_attached: bool = true

## Audio player for voice
var voice_player: AudioStreamPlayer3D


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_setup_audio()
	_setup_visuals()


func _setup_audio() -> void:
	voice_player = AudioStreamPlayer3D.new()
	voice_player.bus = "Player"  # Instructor voice on player bus
	voice_player.max_distance = 30.0
	voice_player.unit_size = 5.0
	add_child(voice_player)


func _setup_visuals() -> void:
	# In a full implementation, this would load the instructor mesh
	# For now, create a simple capsule representation
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	mesh.mesh = capsule
	mesh.position.y = 0.9
	add_child(mesh)

	# Collision shape
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 1.8
	collision.shape = shape
	collision.position.y = 0.9
	add_child(collision)


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if has_fallen and not is_rescued:
		# Fallen instructor doesn't move
		return

	if is_moving:
		_update_movement(delta)


func _update_movement(delta: float) -> void:
	var direction := (move_target - global_position).normalized()
	direction.y = 0  # Keep horizontal

	if global_position.distance_to(move_target) > 0.5:
		velocity = direction * (careful_speed if is_demonstrating else walk_speed)
		move_and_slide()
	else:
		is_moving = false
		velocity = Vector3.ZERO


# =============================================================================
# VOICE
# =============================================================================

## Speak a line of dialogue
func speak(line_id: String, text: String) -> void:
	if is_speaking:
		# Queue this line? For now, skip
		return

	is_speaking = true
	current_line = line_id
	spoken_lines.append(line_id)

	line_spoken.emit(line_id, text)

	# Play voice audio if available
	if voice_lines.has(line_id):
		voice_player.stream = voice_lines[line_id]
		voice_player.play()
		voice_player.finished.connect(_on_voice_finished, CONNECT_ONE_SHOT)
	else:
		# Simulate speaking time based on text length
		var speak_time := text.length() * 0.05  # ~50ms per character
		await get_tree().create_timer(speak_time).timeout
		_on_voice_finished()


func _on_voice_finished() -> void:
	is_speaking = false
	current_line = ""


## Give a subtle hint (shorter than full line)
func give_hint(hint_id: String) -> void:
	match hint_id:
		"careful_movement":
			speak(hint_id, "Careful now.")
		"watch_footing":
			speak(hint_id, "Watch your footing.")
		"slow_down":
			speak(hint_id, "Easy.")


## Check if a line has been spoken
func has_given_line(line_id: String) -> bool:
	return spoken_lines.has(line_id)


# =============================================================================
# GESTURES & DEMONSTRATIONS
# =============================================================================

## Gesture at terrain to teach reading
func gesture_at_terrain() -> void:
	gesture_made.emit("point_terrain", global_position + Vector3(5, -3, 10))

	# Animate pointing (would use animation in full implementation)
	# For now, just rotate toward target
	var look_target := global_position + Vector3(5, -3, 10)
	look_at(look_target, Vector3.UP)


## Demonstrate a controlled slide
func demonstrate_slide() -> void:
	is_demonstrating = true
	current_demo = "slide"
	demonstration_started.emit("slide")

	# Move to slide position
	var slide_start := global_position + Vector3(2, 0, 3)
	move_to(slide_start)

	await get_tree().create_timer(2.0).timeout

	# Perform slide (simplified)
	var slide_end := slide_start + Vector3(0, -5, 15)

	# Animate slide movement
	var tween := create_tween()
	tween.tween_property(self, "global_position", slide_end, slide_demo_duration)
	tween.tween_callback(_complete_demonstration)


func _complete_demonstration() -> void:
	is_demonstrating = false
	demonstration_completed.emit(current_demo)
	current_demo = ""


## Check if demonstration is complete
func has_completed_demonstration() -> bool:
	return not is_demonstrating and current_demo == ""


# =============================================================================
# MOVEMENT
# =============================================================================

## Move to a target position
func move_to(target: Vector3) -> void:
	move_target = target
	is_moving = true


## Model good posture by shifting weight
func model_posture() -> void:
	# Would animate subtle weight shifts
	# Shows player what stable movement looks like
	pass


## Wait for player at current position
func wait_for_player() -> void:
	is_moving = false
	velocity = Vector3.ZERO


# =============================================================================
# HARD MODE: ACCIDENT
# =============================================================================

## Trigger the instructor falling accident
func trigger_accident() -> void:
	if has_fallen:
		return

	has_fallen = true
	rope_attached = false  # Rope snaps
	accident_triggered.emit()

	# Play scream audio
	speak("accident_scream", "")  # Just audio, no text

	# Animate fall (simplified)
	var fall_direction := Vector3(randf_range(-1, 1), -1, randf_range(-1, 1)).normalized()
	var fall_distance := 50.0

	var fall_tween := create_tween()
	fall_tween.tween_property(
		self,
		"global_position",
		global_position + fall_direction * fall_distance,
		2.0
	).set_ease(Tween.EASE_IN)

	# Become invisible as they fall away
	fall_tween.parallel().tween_property(self, "is_visible", false, 1.5)

	# After fall, position at rescue location
	fall_tween.tween_callback(_position_for_rescue)


func _position_for_rescue() -> void:
	# Move to a position where player can find them
	# This would be near the cabin
	is_visible = false


## Set rescued state
func set_rescued(value: bool) -> void:
	is_rescued = value
	if value:
		rescued.emit()
		is_visible = true
		has_fallen = false  # No longer in fallen state


## Check if instructor can be rescued at position
func can_rescue_at(position: Vector3) -> bool:
	if not has_fallen or is_rescued:
		return false

	return global_position.distance_to(position) < 3.0


# =============================================================================
# ROPE
# =============================================================================

## Check if rope is attached
func is_rope_attached() -> bool:
	return rope_attached


## Attach rope to instructor (for rescue)
func attach_rope() -> void:
	rope_attached = true


## Detach rope
func detach_rope() -> void:
	rope_attached = false


# =============================================================================
# QUERIES
# =============================================================================

func is_fallen() -> bool:
	return has_fallen


func get_state() -> Dictionary:
	return {
		"is_speaking": is_speaking,
		"is_demonstrating": is_demonstrating,
		"has_fallen": has_fallen,
		"is_rescued": is_rescued,
		"rope_attached": rope_attached,
		"spoken_lines": spoken_lines.size()
	}
