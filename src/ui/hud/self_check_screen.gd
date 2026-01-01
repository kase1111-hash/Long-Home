class_name SelfCheckScreen
extends Control
## Self-check screen showing player's physical condition
## Displays body status in immersive, diegetic style
##
## Design Philosophy:
## - Body is felt, not displayed numerically
## - Status messages come from the character's perspective
## - Visual cues show severity without exact numbers

# =============================================================================
# SIGNALS
# =============================================================================

signal check_completed()
signal close_requested()

# =============================================================================
# CONFIGURATION
# =============================================================================

## Time for self-check action (seconds)
const CHECK_DURATION := 3.0

## Colors for severity levels
const COLOR_GOOD := Color(0.6, 0.8, 0.6)
const COLOR_WARNING := Color(0.9, 0.8, 0.4)
const COLOR_DANGER := Color(0.9, 0.5, 0.3)
const COLOR_CRITICAL := Color(0.9, 0.3, 0.3)

## Body part positions on silhouette (normalized 0-1)
const BODY_PART_POSITIONS := {
	GameEnums.BodyPart.HEAD: Vector2(0.5, 0.08),
	GameEnums.BodyPart.TORSO: Vector2(0.5, 0.3),
	GameEnums.BodyPart.LEFT_ARM: Vector2(0.25, 0.28),
	GameEnums.BodyPart.RIGHT_ARM: Vector2(0.75, 0.28),
	GameEnums.BodyPart.LEFT_HAND: Vector2(0.18, 0.45),
	GameEnums.BodyPart.RIGHT_HAND: Vector2(0.82, 0.45),
	GameEnums.BodyPart.LEFT_LEG: Vector2(0.38, 0.65),
	GameEnums.BodyPart.RIGHT_LEG: Vector2(0.62, 0.65),
	GameEnums.BodyPart.LEFT_FOOT: Vector2(0.35, 0.92),
	GameEnums.BodyPart.RIGHT_FOOT: Vector2(0.65, 0.92),
}

# =============================================================================
# STATE
# =============================================================================

## Is check in progress
var is_checking: bool = false

## Check progress (0-1)
var check_progress: float = 0.0

## Body state reference
var body_state: BodyState

## Body condition service
var body_condition_service: Node

## Cached status messages
var status_messages: Array[String] = []

# =============================================================================
# NODES
# =============================================================================

var background: ColorRect
var main_container: VBoxContainer
var title_label: Label
var progress_bar: ProgressBar
var content_container: HBoxContainer
var body_panel: Panel
var body_silhouette: Control
var status_panel: VBoxContainer
var overall_label: Label
var messages_container: VBoxContainer
var effects_container: VBoxContainer
var close_button: Button

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS

	_build_ui()
	_connect_signals()


func _build_ui() -> void:
	# Semi-transparent background
	background = ColorRect.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.05, 0.05, 0.08, 0.85)
	add_child(background)

	# Main container
	main_container = VBoxContainer.new()
	main_container.set_anchors_preset(Control.PRESET_CENTER)
	main_container.custom_minimum_size = Vector2(700, 500)
	main_container.add_theme_constant_override("separation", 15)
	add_child(main_container)

	# Center the container
	main_container.anchor_left = 0.5
	main_container.anchor_right = 0.5
	main_container.anchor_top = 0.5
	main_container.anchor_bottom = 0.5
	main_container.offset_left = -350
	main_container.offset_right = 350
	main_container.offset_top = -250
	main_container.offset_bottom = 250

	# Title
	title_label = Label.new()
	title_label.text = "SELF CHECK"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 24)
	title_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.8))
	main_container.add_child(title_label)

	# Progress bar (shown during check)
	progress_bar = ProgressBar.new()
	progress_bar.custom_minimum_size = Vector2(0, 8)
	progress_bar.max_value = 1.0
	progress_bar.value = 0.0
	progress_bar.show_percentage = false
	main_container.add_child(progress_bar)

	# Content area
	content_container = HBoxContainer.new()
	content_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_container.add_theme_constant_override("separation", 20)
	main_container.add_child(content_container)

	# Left side - body silhouette
	_build_body_panel()

	# Right side - status messages
	_build_status_panel()

	# Close button
	close_button = Button.new()
	close_button.text = "Close [ESC]"
	close_button.custom_minimum_size = Vector2(150, 40)
	close_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close_button.pressed.connect(_on_close_pressed)
	main_container.add_child(close_button)


func _build_body_panel() -> void:
	body_panel = Panel.new()
	body_panel.custom_minimum_size = Vector2(200, 0)
	body_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.1, 0.1, 0.12, 0.8)
	panel_style.border_width_left = 1
	panel_style.border_width_right = 1
	panel_style.border_width_top = 1
	panel_style.border_width_bottom = 1
	panel_style.border_color = Color(0.3, 0.3, 0.35)
	panel_style.corner_radius_top_left = 4
	panel_style.corner_radius_top_right = 4
	panel_style.corner_radius_bottom_left = 4
	panel_style.corner_radius_bottom_right = 4
	body_panel.add_theme_stylebox_override("panel", panel_style)

	content_container.add_child(body_panel)

	# Body silhouette drawing area
	body_silhouette = Control.new()
	body_silhouette.set_anchors_preset(Control.PRESET_FULL_RECT)
	body_silhouette.draw.connect(_on_body_silhouette_draw)
	body_panel.add_child(body_silhouette)


func _build_status_panel() -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_container.add_child(scroll)

	status_panel = VBoxContainer.new()
	status_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_panel.add_theme_constant_override("separation", 12)
	scroll.add_child(status_panel)

	# Overall condition
	overall_label = Label.new()
	overall_label.add_theme_font_size_override("font_size", 18)
	status_panel.add_child(overall_label)

	# Separator
	var sep := HSeparator.new()
	status_panel.add_child(sep)

	# Status messages container
	var messages_header := Label.new()
	messages_header.text = "How I'm Feeling"
	messages_header.add_theme_font_size_override("font_size", 14)
	messages_header.add_theme_color_override("font_color", Color(0.7, 0.65, 0.6))
	status_panel.add_child(messages_header)

	messages_container = VBoxContainer.new()
	messages_container.add_theme_constant_override("separation", 6)
	status_panel.add_child(messages_container)

	# Effects separator
	var sep2 := HSeparator.new()
	status_panel.add_child(sep2)

	# Effects container
	var effects_header := Label.new()
	effects_header.text = "Movement Impact"
	effects_header.add_theme_font_size_override("font_size", 14)
	effects_header.add_theme_color_override("font_color", Color(0.7, 0.65, 0.6))
	status_panel.add_child(effects_header)

	effects_container = VBoxContainer.new()
	effects_container.add_theme_constant_override("separation", 4)
	status_panel.add_child(effects_container)


func _connect_signals() -> void:
	ServiceLocator.get_service_async("BodyConditionService", func(service):
		body_condition_service = service
		if body_condition_service.has_signal("self_check_completed"):
			body_condition_service.self_check_completed.connect(_on_self_check_completed)
	)

	EventBus.body_state_updated.connect(_on_body_state_updated)


func _process(delta: float) -> void:
	if not visible:
		return

	if is_checking:
		check_progress += delta / CHECK_DURATION
		progress_bar.value = check_progress

		if check_progress >= 1.0:
			_complete_check()


# =============================================================================
# CHECK FLOW
# =============================================================================

func show_check() -> void:
	visible = true

	# Get current body state
	var run := GameStateManager.get_current_run()
	if run:
		body_state = run.body_state

	# Start the check process
	is_checking = true
	check_progress = 0.0
	progress_bar.value = 0.0
	progress_bar.visible = true
	title_label.text = "CHECKING CONDITION..."

	# Clear previous content
	_clear_messages()

	# Emit signal if service available
	if body_condition_service and body_condition_service.has_method("start_self_check"):
		body_condition_service.start_self_check()

	print("[SelfCheck] Starting self-check...")


func _complete_check() -> void:
	is_checking = false
	progress_bar.visible = false
	title_label.text = "SELF CHECK"

	# Populate the UI with results
	_update_display()

	check_completed.emit()
	print("[SelfCheck] Check complete")


func hide_check() -> void:
	visible = false
	is_checking = false


func _clear_messages() -> void:
	for child in messages_container.get_children():
		child.queue_free()
	for child in effects_container.get_children():
		child.queue_free()


# =============================================================================
# DISPLAY UPDATE
# =============================================================================

func _update_display() -> void:
	if body_state == null:
		overall_label.text = "Unable to assess condition"
		return

	# Update overall condition
	_update_overall_condition()

	# Update status messages
	_update_status_messages()

	# Update movement effects
	_update_effects()

	# Redraw body silhouette
	body_silhouette.queue_redraw()


func _update_overall_condition() -> void:
	var condition := 1.0 - body_state.fatigue
	var color := _get_severity_color(1.0 - condition)

	var condition_text := ""
	if condition > 0.8:
		condition_text = "Feeling strong"
	elif condition > 0.6:
		condition_text = "Managing okay"
	elif condition > 0.4:
		condition_text = "Getting tired"
	elif condition > 0.2:
		condition_text = "Struggling"
	else:
		condition_text = "At my limit"

	overall_label.text = condition_text
	overall_label.add_theme_color_override("font_color", color)


func _update_status_messages() -> void:
	_clear_messages()

	# Get diegetic messages from body state
	var messages := body_state.get_status_messages()

	if messages.is_empty():
		var good_msg := Label.new()
		good_msg.text = "• No major concerns right now"
		good_msg.add_theme_color_override("font_color", COLOR_GOOD)
		good_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		messages_container.add_child(good_msg)
	else:
		for msg in messages:
			var label := Label.new()
			label.text = "• " + msg
			label.add_theme_color_override("font_color", _get_message_color(msg))
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			messages_container.add_child(label)

	# Add injury-specific messages
	for injury in body_state.injuries:
		var injury_msg := _get_injury_message(injury)
		var label := Label.new()
		label.text = "• " + injury_msg
		label.add_theme_color_override("font_color", _get_severity_color(injury.severity))
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		messages_container.add_child(label)

	# Add extremity cold warnings
	for part in body_state.extremity_cold:
		var cold_level: float = body_state.extremity_cold[part]
		if cold_level > 0.5:
			var part_name := _get_body_part_name(part)
			var cold_msg := "%s feeling numb" % part_name if cold_level > 0.7 else "%s getting cold" % part_name
			var label := Label.new()
			label.text = "• " + cold_msg
			label.add_theme_color_override("font_color", _get_severity_color(cold_level))
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			messages_container.add_child(label)


func _update_effects() -> void:
	for child in effects_container.get_children():
		child.queue_free()

	# Movement modifier
	var move_mod := body_state.get_movement_modifier()
	if move_mod < 0.95:
		_add_effect("Speed: %d%%" % int(move_mod * 100), move_mod)

	# Stability modifier
	var stab_mod := body_state.get_stability_modifier()
	if stab_mod < 0.95:
		_add_effect("Balance: %d%%" % int(stab_mod * 100), stab_mod)

	# Rope handling
	var rope_mod := body_state.get_rope_handling_modifier()
	if rope_mod < 0.95:
		_add_effect("Rope handling: %d%%" % int(rope_mod * 100), rope_mod)

	# Input delay
	var delay := body_state.get_input_delay()
	if delay > 0.05:
		_add_effect("Reaction slowed: +%.1fs" % delay, 1.0 - delay)

	# If no effects, show positive message
	if effects_container.get_child_count() == 0:
		var label := Label.new()
		label.text = "Moving at full capacity"
		label.add_theme_color_override("font_color", COLOR_GOOD)
		effects_container.add_child(label)


func _add_effect(text: String, modifier: float) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", _get_severity_color(1.0 - modifier))
	effects_container.add_child(label)


# =============================================================================
# BODY SILHOUETTE
# =============================================================================

func _on_body_silhouette_draw() -> void:
	var size := body_silhouette.size
	var center := size / 2

	# Draw simple body outline
	_draw_body_outline(size)

	# Draw injury indicators
	if body_state:
		_draw_injury_markers(size)
		_draw_cold_indicators(size)


func _draw_body_outline(size: Vector2) -> void:
	var color := Color(0.5, 0.5, 0.55, 0.6)
	var cx := size.x / 2
	var margin := 30.0

	# Head
	var head_y := margin + 20
	body_silhouette.draw_arc(Vector2(cx, head_y), 18, 0, TAU, 24, color, 2.0)

	# Neck
	body_silhouette.draw_line(Vector2(cx, head_y + 18), Vector2(cx, head_y + 30), color, 2.0)

	# Shoulders
	var shoulder_y := head_y + 35
	body_silhouette.draw_line(Vector2(cx - 40, shoulder_y), Vector2(cx + 40, shoulder_y), color, 2.0)

	# Torso
	var torso_bottom := shoulder_y + 80
	body_silhouette.draw_line(Vector2(cx - 30, shoulder_y), Vector2(cx - 25, torso_bottom), color, 2.0)
	body_silhouette.draw_line(Vector2(cx + 30, shoulder_y), Vector2(cx + 25, torso_bottom), color, 2.0)
	body_silhouette.draw_line(Vector2(cx - 25, torso_bottom), Vector2(cx + 25, torso_bottom), color, 2.0)

	# Arms
	var arm_length := 60.0
	body_silhouette.draw_line(Vector2(cx - 40, shoulder_y), Vector2(cx - 55, shoulder_y + arm_length), color, 2.0)
	body_silhouette.draw_line(Vector2(cx + 40, shoulder_y), Vector2(cx + 55, shoulder_y + arm_length), color, 2.0)

	# Hands
	body_silhouette.draw_arc(Vector2(cx - 55, shoulder_y + arm_length + 8), 8, 0, TAU, 12, color, 1.5)
	body_silhouette.draw_arc(Vector2(cx + 55, shoulder_y + arm_length + 8), 8, 0, TAU, 12, color, 1.5)

	# Legs
	var leg_top := torso_bottom
	var leg_bottom := size.y - margin - 30
	body_silhouette.draw_line(Vector2(cx - 15, leg_top), Vector2(cx - 25, leg_bottom), color, 2.0)
	body_silhouette.draw_line(Vector2(cx + 15, leg_top), Vector2(cx + 25, leg_bottom), color, 2.0)

	# Feet
	body_silhouette.draw_line(Vector2(cx - 25, leg_bottom), Vector2(cx - 35, leg_bottom + 15), color, 2.0)
	body_silhouette.draw_line(Vector2(cx + 25, leg_bottom), Vector2(cx + 35, leg_bottom + 15), color, 2.0)


func _draw_injury_markers(size: Vector2) -> void:
	for injury in body_state.injuries:
		var pos := _get_body_part_screen_position(injury.location, size)
		var color := _get_severity_color(injury.severity)
		var radius := 8.0 + injury.severity * 8.0

		# Pulsing glow for severe injuries
		if injury.severity > 0.6:
			var pulse := (sin(Time.get_ticks_msec() * 0.005) + 1.0) / 2.0
			var glow_color := color
			glow_color.a = 0.3 + pulse * 0.2
			body_silhouette.draw_circle(pos, radius + 5, glow_color)

		# Main marker
		body_silhouette.draw_circle(pos, radius, color)

		# Injury type icon (simple)
		var icon_color := Color.WHITE
		icon_color.a = 0.9
		match injury.type:
			GameEnums.InjuryType.FRACTURE:
				# X mark
				body_silhouette.draw_line(pos - Vector2(4, 4), pos + Vector2(4, 4), icon_color, 2.0)
				body_silhouette.draw_line(pos - Vector2(-4, 4), pos + Vector2(-4, 4), icon_color, 2.0)
			GameEnums.InjuryType.SPRAIN, GameEnums.InjuryType.STRAIN:
				# Wavy line
				body_silhouette.draw_arc(pos, 4, 0, PI, 8, icon_color, 1.5)
			GameEnums.InjuryType.LACERATION:
				# Slash
				body_silhouette.draw_line(pos - Vector2(4, 4), pos + Vector2(4, 4), icon_color, 2.0)
			GameEnums.InjuryType.FROSTBITE:
				# Snowflake-ish
				body_silhouette.draw_circle(pos, 2, icon_color)


func _draw_cold_indicators(size: Vector2) -> void:
	for part in body_state.extremity_cold:
		var cold_level: float = body_state.extremity_cold[part]
		if cold_level > 0.3:
			var pos := _get_body_part_screen_position(part, size)
			var color := Color(0.4, 0.6, 0.9, cold_level * 0.6)

			# Cold ring
			body_silhouette.draw_arc(pos, 12, 0, TAU, 16, color, 2.0)


func _get_body_part_screen_position(part: GameEnums.BodyPart, size: Vector2) -> Vector2:
	if BODY_PART_POSITIONS.has(part):
		return BODY_PART_POSITIONS[part] * size
	return size / 2


# =============================================================================
# HELPERS
# =============================================================================

func _get_severity_color(severity: float) -> Color:
	if severity < 0.3:
		return COLOR_GOOD
	elif severity < 0.5:
		return COLOR_WARNING
	elif severity < 0.7:
		return COLOR_DANGER
	else:
		return COLOR_CRITICAL


func _get_message_color(msg: String) -> Color:
	# Determine color based on message content
	var lower := msg.to_lower()
	if "critical" in lower or "can't" in lower or "numb" in lower or "collapsed" in lower:
		return COLOR_CRITICAL
	elif "screaming" in lower or "desperate" in lower or "severe" in lower:
		return COLOR_DANGER
	elif "burning" in lower or "hard" in lower or "tired" in lower:
		return COLOR_WARNING
	else:
		return Color(0.8, 0.8, 0.75)


func _get_injury_message(injury: Injury) -> String:
	var location := _get_body_part_name(injury.location)
	var severity_text := ""

	if injury.severity < 0.3:
		severity_text = "Minor"
	elif injury.severity < 0.6:
		severity_text = "Painful"
	elif injury.severity < 0.9:
		severity_text = "Serious"
	else:
		severity_text = "Critical"

	match injury.type:
		GameEnums.InjuryType.SPRAIN:
			return "%s sprain in %s" % [severity_text, location.to_lower()]
		GameEnums.InjuryType.STRAIN:
			return "%s muscle strain" % severity_text
		GameEnums.InjuryType.LACERATION:
			return "%s cut on %s" % [severity_text, location.to_lower()]
		GameEnums.InjuryType.FRACTURE:
			return "%s fracture - %s" % [severity_text, location.to_lower()]
		GameEnums.InjuryType.FROSTBITE:
			return "Frostbite on %s" % location.to_lower()
		GameEnums.InjuryType.HYPOTHERMIA:
			return "Hypothermia setting in"
		GameEnums.InjuryType.EXHAUSTION:
			return "Severe exhaustion"
		_:
			return "%s injury to %s" % [severity_text, location.to_lower()]


func _get_body_part_name(part: GameEnums.BodyPart) -> String:
	match part:
		GameEnums.BodyPart.HEAD:
			return "Head"
		GameEnums.BodyPart.TORSO:
			return "Torso"
		GameEnums.BodyPart.LEFT_ARM, GameEnums.BodyPart.RIGHT_ARM:
			return "Arm"
		GameEnums.BodyPart.LEFT_HAND, GameEnums.BodyPart.RIGHT_HAND:
			return "Hand"
		GameEnums.BodyPart.LEFT_LEG, GameEnums.BodyPart.RIGHT_LEG:
			return "Leg"
		GameEnums.BodyPart.LEFT_FOOT, GameEnums.BodyPart.RIGHT_FOOT:
			return "Foot"
		_:
			return "Body"


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_self_check_completed(messages: Array) -> void:
	status_messages.clear()
	for msg in messages:
		if msg is String:
			status_messages.append(msg)


func _on_body_state_updated(new_state: BodyState) -> void:
	body_state = new_state
	if visible and not is_checking:
		_update_display()


func _on_close_pressed() -> void:
	close_requested.emit()


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return

	if event.is_action_pressed("ui_cancel"):
		close_requested.emit()
		get_viewport().set_input_as_handled()
