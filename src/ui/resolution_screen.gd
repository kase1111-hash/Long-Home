class_name ResolutionScreen
extends Control
## Resolution screen shown at the end of a run
## Displays outcome in a minimal, atmospheric way
## No scores, no medals - just clarity

# =============================================================================
# SIGNALS
# =============================================================================

signal continue_pressed()

# =============================================================================
# REFERENCES
# =============================================================================

@onready var outcome_label: Label = $VBoxContainer/OutcomeLabel
@onready var outcome_subtitle: Label = $VBoxContainer/OutcomeSubtitle
@onready var stats_container: VBoxContainer = $VBoxContainer/StatsContainer
@onready var message_label: Label = $VBoxContainer/MessageLabel
@onready var continue_button: Button = $VBoxContainer/ContinueButton

# =============================================================================
# OUTCOME MESSAGES
# =============================================================================

const OUTCOME_TITLES := {
	GameEnums.ResolutionType.CLEAN_RETURN: "You Made It",
	GameEnums.ResolutionType.INJURED_RETURN: "You Made It",
	GameEnums.ResolutionType.FORCED_BIVY: "You Survived",
	GameEnums.ResolutionType.RESCUE: "You Were Found",
	GameEnums.ResolutionType.FATALITY: "You Did Not Return"
}

const OUTCOME_SUBTITLES := {
	GameEnums.ResolutionType.CLEAN_RETURN: "The mountain let you go",
	GameEnums.ResolutionType.INJURED_RETURN: "But not without cost",
	GameEnums.ResolutionType.FORCED_BIVY: "The night was long",
	GameEnums.ResolutionType.RESCUE: "They came for you",
	GameEnums.ResolutionType.FATALITY: ""
}

# =============================================================================
# STATE
# =============================================================================

var run_context: RunContext
var outcome: GameEnums.ResolutionType

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	continue_button.pressed.connect(_on_continue_pressed)
	_apply_theme()
	visible = false


func _apply_theme() -> void:
	# Atmospheric, muted styling
	var text_color := Color(0.9, 0.9, 0.92, 1.0)
	var dim_color := Color(0.6, 0.6, 0.65, 0.8)

	outcome_label.add_theme_font_size_override("font_size", 48)
	outcome_label.add_theme_color_override("font_color", text_color)

	outcome_subtitle.add_theme_font_size_override("font_size", 20)
	outcome_subtitle.add_theme_color_override("font_color", dim_color)

	message_label.add_theme_font_size_override("font_size", 16)
	message_label.add_theme_color_override("font_color", dim_color)


# =============================================================================
# PUBLIC API
# =============================================================================

## Show the resolution screen with run results
func show_resolution(context: RunContext, result: GameEnums.ResolutionType) -> void:
	run_context = context
	outcome = result

	# Set outcome text
	outcome_label.text = OUTCOME_TITLES.get(outcome, "The End")
	outcome_subtitle.text = OUTCOME_SUBTITLES.get(outcome, "")

	# Build stats display
	_build_stats()

	# Generate contextual message
	message_label.text = _generate_message()

	# Show with fade
	visible = true
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 1.5).set_ease(Tween.EASE_OUT)


## Hide the resolution screen
func hide_resolution() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.5)
	tween.tween_callback(func(): visible = false)


# =============================================================================
# STATS DISPLAY
# =============================================================================

func _build_stats() -> void:
	# Clear existing stats
	for child in stats_container.get_children():
		child.queue_free()

	if run_context == null:
		return

	# Time elapsed
	_add_stat("Time", _format_time(run_context.game_time_elapsed))

	# Distance traveled
	_add_stat("Distance", "%.0f m" % run_context.distance_traveled)

	# Elevation descended
	var elevation_change := run_context.start_elevation - run_context.current_elevation
	_add_stat("Descent", "%.0f m" % elevation_change)

	# Injuries (if any)
	var injury_count := run_context.body_state.injuries.size() if run_context.body_state else 0
	if injury_count > 0:
		_add_stat("Injuries", str(injury_count))


func _add_stat(label_text: String, value_text: String) -> void:
	var container := HBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var label := Label.new()
	label.text = label_text + ":"
	label.custom_minimum_size = Vector2(100, 0)
	label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55, 0.8))

	var value := Label.new()
	value.text = value_text
	value.add_theme_color_override("font_color", Color(0.8, 0.8, 0.82, 1.0))

	container.add_child(label)
	container.add_child(value)
	stats_container.add_child(container)


func _format_time(hours: float) -> String:
	var total_minutes := int(hours * 60)
	var h := total_minutes / 60
	var m := total_minutes % 60
	return "%d:%02d" % [h, m]


# =============================================================================
# MESSAGE GENERATION
# =============================================================================

func _generate_message() -> String:
	if run_context == null:
		return ""

	match outcome:
		GameEnums.ResolutionType.CLEAN_RETURN:
			return _generate_clean_message()
		GameEnums.ResolutionType.INJURED_RETURN:
			return _generate_injured_message()
		GameEnums.ResolutionType.FORCED_BIVY:
			return _generate_bivy_message()
		GameEnums.ResolutionType.RESCUE:
			return _generate_rescue_message()
		GameEnums.ResolutionType.FATALITY:
			return _generate_fatality_message()

	return ""


func _generate_clean_message() -> String:
	var messages := [
		"Good decisions compound.",
		"You read the mountain well.",
		"Patience is its own reward.",
		"The margin was earned."
	]
	return messages[randi() % messages.size()]


func _generate_injured_message() -> String:
	var fatigue := run_context.body_state.fatigue if run_context.body_state else 0.0

	if fatigue > 0.8:
		return "You pushed too hard."
	elif run_context.incidents.size() > 3:
		return "Small mistakes add up."
	else:
		return "You made it. That's what matters."


func _generate_bivy_message() -> String:
	return "Sometimes survival is the victory."


func _generate_rescue_message() -> String:
	return "They found you in time."


func _generate_fatality_message() -> String:
	# Check what caused the fatality
	var fatal_incident := run_context.get_fatal_incident()
	if fatal_incident.is_empty():
		return ""

	match fatal_incident.get("type", ""):
		"terminal_slide":
			return "The slope did not forgive."
		"fatal_fall":
			return "Gravity is patient."
		"exposure_death":
			return "The cold takes its time."
		_:
			return "The mountain keeps its own."


# =============================================================================
# INPUT HANDLERS
# =============================================================================

func _on_continue_pressed() -> void:
	continue_pressed.emit()
	# Transition to post-game analysis
	GameStateManager.transition_to(GameEnums.GameState.POST_GAME)
