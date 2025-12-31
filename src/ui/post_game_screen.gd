class_name PostGameScreen
extends Control
## Post-game analysis screen
## Shows topo replay with path and key moments highlighted
## No scores, no medals - just clarity about what happened

# =============================================================================
# SIGNALS
# =============================================================================

signal return_to_menu_pressed()
signal retry_pressed()

# =============================================================================
# REFERENCES
# =============================================================================

@onready var topo_view: Control = $HSplitContainer/TopoContainer/TopoView
@onready var path_line: Line2D = $HSplitContainer/TopoContainer/TopoView/PathLine
@onready var moments_container: VBoxContainer = $HSplitContainer/MomentsPanel/MomentsContainer
@onready var insight_label: Label = $HSplitContainer/MomentsPanel/InsightLabel
@onready var return_button: Button = $HSplitContainer/MomentsPanel/ButtonContainer/ReturnButton
@onready var retry_button: Button = $HSplitContainer/MomentsPanel/ButtonContainer/RetryButton

# =============================================================================
# CONFIGURATION
# =============================================================================

## Time to draw the full path (seconds)
@export var path_draw_duration: float = 5.0

## Pause at key moments (seconds)
@export var moment_pause_duration: float = 0.5

# =============================================================================
# STATE
# =============================================================================

var run_context: RunContext
var is_drawing_path: bool = false
var path_progress: float = 0.0
var path_points: PackedVector2Array = PackedVector2Array()
var key_moments: Array[Dictionary] = []
var current_moment_index: int = -1

# Topo view scaling
var topo_scale: float = 1.0
var topo_offset: Vector2 = Vector2.ZERO

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	return_button.pressed.connect(_on_return_pressed)
	retry_button.pressed.connect(_on_retry_pressed)
	_apply_theme()
	visible = false


func _process(delta: float) -> void:
	if is_drawing_path:
		_update_path_drawing(delta)


func _apply_theme() -> void:
	var dim_color := Color(0.6, 0.6, 0.65, 0.8)
	insight_label.add_theme_font_size_override("font_size", 14)
	insight_label.add_theme_color_override("font_color", dim_color)


# =============================================================================
# PUBLIC API
# =============================================================================

## Show the post-game analysis
func show_analysis(context: RunContext) -> void:
	run_context = context

	# Extract path and moments
	_extract_path_data()
	_extract_key_moments()

	# Build moments list
	_build_moments_list()

	# Generate insight
	insight_label.text = _generate_insight()

	# Show retry only for non-fatality
	retry_button.visible = context.outcome != GameEnums.ResolutionType.FATALITY

	# Show and start path animation
	visible = true
	modulate.a = 0.0

	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.5)
	tween.tween_callback(_start_path_drawing)


## Hide the analysis screen
func hide_analysis() -> void:
	is_drawing_path = false
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.3)
	tween.tween_callback(func(): visible = false)


# =============================================================================
# PATH EXTRACTION
# =============================================================================

func _extract_path_data() -> void:
	path_points.clear()

	if run_context == null or run_context.path_history.is_empty():
		return

	# Calculate bounds for scaling
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)

	for pos in run_context.path_history:
		min_pos.x = minf(min_pos.x, pos.x)
		min_pos.y = minf(min_pos.y, pos.z)  # Use Z as Y for top-down view
		max_pos.x = maxf(max_pos.x, pos.x)
		max_pos.y = maxf(max_pos.y, pos.z)

	# Add margin
	var margin := 20.0
	min_pos -= Vector2(margin, margin)
	max_pos += Vector2(margin, margin)

	# Calculate scale to fit topo view
	var view_size := topo_view.size if topo_view else Vector2(400, 400)
	var world_size := max_pos - min_pos

	if world_size.x > 0 and world_size.y > 0:
		topo_scale = minf(view_size.x / world_size.x, view_size.y / world_size.y)
		topo_offset = -min_pos * topo_scale + (view_size - world_size * topo_scale) * 0.5

	# Convert 3D path to 2D screen coordinates
	for pos in run_context.path_history:
		var screen_pos := Vector2(pos.x, pos.z) * topo_scale + topo_offset
		path_points.append(screen_pos)


func _extract_key_moments() -> void:
	key_moments.clear()

	if run_context == null:
		return

	# Extract from decisions
	for decision in run_context.decisions:
		var moment := {
			"type": decision.get("type", "decision"),
			"time": decision.get("game_time", 0.0),
			"position": decision.get("position", Vector3.ZERO),
			"details": decision.get("details", {})
		}
		key_moments.append(moment)

	# Extract from incidents
	for incident in run_context.incidents:
		var moment := {
			"type": incident.get("type", "incident"),
			"time": incident.get("game_time", 0.0),
			"position": incident.get("position", Vector3.ZERO),
			"details": incident.get("details", {}),
			"is_incident": true
		}
		key_moments.append(moment)

	# Sort by time
	key_moments.sort_custom(func(a, b): return a.time < b.time)


# =============================================================================
# PATH DRAWING
# =============================================================================

func _start_path_drawing() -> void:
	path_progress = 0.0
	is_drawing_path = true
	current_moment_index = -1

	if path_line:
		path_line.clear_points()
		path_line.default_color = Color(0.9, 0.7, 0.3, 0.8)
		path_line.width = 2.0


func _update_path_drawing(delta: float) -> void:
	if path_points.is_empty():
		is_drawing_path = false
		return

	# Advance progress
	path_progress += delta / path_draw_duration
	path_progress = minf(path_progress, 1.0)

	# Calculate how many points to show
	var target_point := int(path_progress * (path_points.size() - 1))

	# Add points up to target
	while path_line.get_point_count() <= target_point:
		var idx := path_line.get_point_count()
		if idx < path_points.size():
			path_line.add_point(path_points[idx])

			# Check for key moments at this position
			_check_moment_at_index(idx)

	# Done drawing
	if path_progress >= 1.0:
		is_drawing_path = false


func _check_moment_at_index(path_idx: int) -> void:
	if run_context == null or run_context.path_history.is_empty():
		return

	# Get world position at this path index
	if path_idx >= run_context.path_history.size():
		return

	var world_pos := run_context.path_history[path_idx]

	# Check if any moments are near this position
	for i in range(current_moment_index + 1, key_moments.size()):
		var moment: Dictionary = key_moments[i]
		var moment_pos: Vector3 = moment.get("position", Vector3.ZERO)

		if moment_pos.distance_to(world_pos) < 5.0:
			current_moment_index = i
			_highlight_moment(moment)
			break


func _highlight_moment(moment: Dictionary) -> void:
	# Flash the moment in the list
	var moment_type: String = moment.get("type", "")

	# Could add visual marker on topo here
	# For now, just update the insight text briefly
	pass


# =============================================================================
# MOMENTS LIST
# =============================================================================

func _build_moments_list() -> void:
	# Clear existing
	for child in moments_container.get_children():
		child.queue_free()

	# Add header
	var header := Label.new()
	header.text = "Key Moments"
	header.add_theme_font_size_override("font_size", 18)
	header.add_theme_color_override("font_color", Color(0.8, 0.8, 0.82))
	moments_container.add_child(header)

	# Add spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	moments_container.add_child(spacer)

	# Add moments
	var displayed_count := 0
	for moment in key_moments:
		if displayed_count >= 8:  # Limit displayed moments
			break

		var moment_text := _get_moment_text(moment)
		if moment_text.is_empty():
			continue

		var label := Label.new()
		label.text = moment_text
		label.add_theme_font_size_override("font_size", 13)

		# Color based on type
		var is_incident: bool = moment.get("is_incident", false)
		if is_incident:
			label.add_theme_color_override("font_color", Color(0.9, 0.6, 0.5, 0.9))
		else:
			label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8, 0.9))

		moments_container.add_child(label)
		displayed_count += 1


func _get_moment_text(moment: Dictionary) -> String:
	var moment_type: String = moment.get("type", "")
	var time: float = moment.get("time", 0.0)
	var time_str := "%d:%02d" % [int(time), int(fmod(time * 60, 60))]

	match moment_type:
		"start_slide":
			return "[%s] Started sliding" % time_str
		"start_downclimb":
			var slope: float = moment.get("details", {}).get("slope", 0.0)
			return "[%s] Began downclimbing (%.0f°)" % [time_str, slope]
		"deploy_rope":
			return "[%s] Deployed rope" % time_str
		"self_arrest":
			return "[%s] Self-arrested" % time_str
		"hard_landing":
			return "[%s] Hard landing" % time_str
		"fall_injury":
			var injury_type: String = moment.get("details", {}).get("type", "injury")
			return "[%s] %s from fall" % [time_str, injury_type.capitalize()]
		"collapse":
			return "[%s] Collapsed from exhaustion" % time_str
		"incapacitated":
			return "[%s] Became incapacitated" % time_str
		"terminal_slide", "fatal_fall", "exposure_death":
			return "[%s] Fatal incident" % time_str
		"run_complete":
			return ""  # Don't show this one
		_:
			if moment.get("is_incident", false):
				return "[%s] %s" % [time_str, moment_type.replace("_", " ").capitalize()]

	return ""


# =============================================================================
# INSIGHT GENERATION
# =============================================================================

func _generate_insight() -> String:
	if run_context == null:
		return ""

	var insights: Array[String] = []

	# Analyze the run
	var fatigue := run_context.body_state.fatigue if run_context.body_state else 0.0
	var incident_count := run_context.incidents.size()
	var slide_count := run_context.get_decisions_by_type("start_slide").size()
	var rope_count := run_context.get_decisions_by_type("deploy_rope").size()

	# Generate contextual insights
	if fatigue > 0.8 and run_context.outcome != GameEnums.ResolutionType.CLEAN_RETURN:
		insights.append("You were moving fast when you needed margin.")

	if incident_count > 5:
		insights.append("Small mistakes compounded into larger problems.")

	if slide_count > 3 and run_context.outcome == GameEnums.ResolutionType.FATALITY:
		insights.append("Each slide added risk. The last one was too much.")

	if rope_count == 0 and run_context.outcome != GameEnums.ResolutionType.CLEAN_RETURN:
		insights.append("The rope stayed in the pack.")

	# Positive insights for success
	if run_context.outcome == GameEnums.ResolutionType.CLEAN_RETURN:
		if fatigue < 0.3:
			insights.append("You read the mountain well and kept reserves.")
		elif incident_count == 0:
			insights.append("A clean line. No wasted movement.")
		else:
			insights.append("Good decisions outweighed the mistakes.")

	# Return one insight or default
	if insights.is_empty():
		match run_context.outcome:
			GameEnums.ResolutionType.CLEAN_RETURN:
				return "The mountain let you pass."
			GameEnums.ResolutionType.INJURED_RETURN:
				return "You made it, but not without cost."
			GameEnums.ResolutionType.FORCED_BIVY:
				return "Sometimes stopping is the right choice."
			GameEnums.ResolutionType.RESCUE:
				return "Help arrived in time."
			GameEnums.ResolutionType.FATALITY:
				return "The mountain keeps its own."

	return insights[randi() % insights.size()]


# =============================================================================
# BUTTON HANDLERS
# =============================================================================

func _on_return_pressed() -> void:
	return_to_menu_pressed.emit()
	GameStateManager.transition_to(GameEnums.GameState.MAIN_MENU)


func _on_retry_pressed() -> void:
	retry_pressed.emit()
	# Return to planning with same mountain
	GameStateManager.transition_to(GameEnums.GameState.PLANNING)
