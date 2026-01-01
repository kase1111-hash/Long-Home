class_name PauseMenu
extends Control
## In-game pause menu
## Provides options to resume, check map, adjust settings, or abandon
##
## Design Philosophy:
## - Pause provides respite, not escape
## - Map check is a tool, not a cheat
## - Abandoning has consequences

# =============================================================================
# SIGNALS
# =============================================================================

signal resume_pressed()
signal map_check_pressed()
signal self_check_pressed()
signal settings_pressed()
signal streaming_settings_pressed()
signal abandon_pressed()

# =============================================================================
# CONFIGURATION
# =============================================================================

const FADE_DURATION := 0.2
const BLUR_AMOUNT := 0.5

# =============================================================================
# STATE
# =============================================================================

## Is menu visible
var is_showing: bool = false

## Current run context
var run_context: RunContext

## Time spent paused (for stats)
var pause_start_time: float = 0.0

## Total time paused this run
var total_pause_time: float = 0.0

# =============================================================================
# NODES
# =============================================================================

var background: ColorRect
var menu_container: VBoxContainer
var title_label: Label
var status_panel: PanelContainer
var button_container: VBoxContainer
var resume_button: Button
var map_button: Button
var self_check_button: Button
var settings_button: Button
var streaming_button: Button
var abandon_button: Button
var confirm_dialog: Control

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_build_ui()
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS  # Process even when paused


func _build_ui() -> void:
	# Background overlay
	background = ColorRect.new()
	background.name = "Background"
	background.color = Color(0.0, 0.0, 0.0, 0.7)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(background)

	# Center container
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	# Menu panel
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(400, 0)
	center.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.95)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.3, 0.3, 0.35, 0.8)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	panel.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 30)
	margin.add_theme_constant_override("margin_right", 30)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	panel.add_child(margin)

	menu_container = VBoxContainer.new()
	menu_container.add_theme_constant_override("separation", 20)
	margin.add_child(menu_container)

	# Title
	title_label = Label.new()
	title_label.name = "Title"
	title_label.text = "PAUSED"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 32)
	title_label.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88))
	menu_container.add_child(title_label)

	# Status panel
	_create_status_panel()

	# Separator
	var sep := HSeparator.new()
	menu_container.add_child(sep)

	# Buttons
	button_container = VBoxContainer.new()
	button_container.add_theme_constant_override("separation", 12)
	menu_container.add_child(button_container)

	resume_button = _create_button("Resume", "Continue the descent")
	resume_button.pressed.connect(_on_resume_pressed)
	button_container.add_child(resume_button)

	map_button = _create_button("Check Map", "View your position and planned route")
	map_button.pressed.connect(_on_map_pressed)
	button_container.add_child(map_button)

	self_check_button = _create_button("Check Body", "Assess your physical condition")
	self_check_button.pressed.connect(_on_self_check_pressed)
	button_container.add_child(self_check_button)

	settings_button = _create_button("Settings", "Adjust game settings")
	settings_button.pressed.connect(_on_settings_pressed)
	button_container.add_child(settings_button)

	streaming_button = _create_button("Streaming", "OBS integration and streamer mode")
	streaming_button.pressed.connect(_on_streaming_pressed)
	button_container.add_child(streaming_button)
	_update_streaming_button()

	# Spacer before abandon
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	button_container.add_child(spacer)

	abandon_button = _create_button("Abandon Run", "Give up and return to menu", true)
	abandon_button.pressed.connect(_on_abandon_pressed)
	button_container.add_child(abandon_button)

	# Confirm dialog (hidden by default)
	_create_confirm_dialog()


func _create_status_panel() -> void:
	status_panel = PanelContainer.new()
	menu_container.add_child(status_panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.8)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	status_panel.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_right", 15)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	status_panel.add_child(margin)

	var grid := GridContainer.new()
	grid.name = "StatusGrid"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 6)
	margin.add_child(grid)


func _create_button(text: String, tooltip: String, danger: bool = false) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.tooltip_text = tooltip
	btn.custom_minimum_size = Vector2(0, 45)

	if danger:
		btn.add_theme_color_override("font_color", Color(0.9, 0.5, 0.4))
		btn.add_theme_color_override("font_hover_color", Color(1.0, 0.6, 0.5))

	return btn


func _create_confirm_dialog() -> void:
	confirm_dialog = Control.new()
	confirm_dialog.name = "ConfirmDialog"
	confirm_dialog.visible = false
	confirm_dialog.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(confirm_dialog)

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.5)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	confirm_dialog.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	confirm_dialog.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(350, 0)
	center.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.1, 0.1, 0.98)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.6, 0.3, 0.3, 0.8)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 25)
	margin.add_theme_constant_override("margin_right", 25)
	margin.add_theme_constant_override("margin_top", 25)
	margin.add_theme_constant_override("margin_bottom", 25)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 15)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Abandon Run?"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.9, 0.5, 0.4))
	vbox.add_child(title)

	var warning := Label.new()
	warning.text = "This run will be recorded as a fatality.\nYour progress on this descent will be lost."
	warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warning.add_theme_font_size_override("font_size", 14)
	warning.add_theme_color_override("font_color", Color(0.7, 0.65, 0.6))
	vbox.add_child(warning)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 20)
	vbox.add_child(buttons)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(100, 40)
	cancel.pressed.connect(_on_confirm_cancel)
	buttons.add_child(cancel)

	var confirm := Button.new()
	confirm.text = "Abandon"
	confirm.custom_minimum_size = Vector2(100, 40)
	confirm.add_theme_color_override("font_color", Color(0.9, 0.4, 0.3))
	confirm.pressed.connect(_on_confirm_abandon)
	buttons.add_child(confirm)


# =============================================================================
# STATUS UPDATE
# =============================================================================

func _update_status() -> void:
	var grid := status_panel.get_node("MarginContainer/StatusGrid")
	if not grid:
		return

	# Clear existing
	for child in grid.get_children():
		child.queue_free()

	if run_context == null:
		run_context = GameStateManager.get_current_run()

	if run_context == null:
		return

	# Elapsed time
	_add_status_row(grid, "Elapsed", _format_time(run_context.elapsed_time))

	# Current elevation
	_add_status_row(grid, "Elevation", "%.0fm" % run_context.current_elevation)

	# Descent progress
	var descent := run_context.start_elevation - run_context.current_elevation
	var total := run_context.start_elevation - run_context.target_elevation
	var percent := (descent / maxf(1.0, total)) * 100.0
	_add_status_row(grid, "Progress", "%.0f%%" % percent)

	# Weather
	var weather_name := GameEnums.WeatherState.keys()[run_context.current_weather]
	_add_status_row(grid, "Weather", weather_name.capitalize())

	# Body state
	if run_context.body_state:
		var fatigue := run_context.body_state.fatigue * 100
		_add_status_row(grid, "Fatigue", "%.0f%%" % fatigue)


func _add_status_row(grid: GridContainer, label_text: String, value_text: String) -> void:
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	grid.add_child(label)

	var value := Label.new()
	value.text = value_text
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.add_theme_font_size_override("font_size", 13)
	value.add_theme_color_override("font_color", Color(0.9, 0.88, 0.85))
	grid.add_child(value)


func _format_time(seconds: float) -> String:
	var hours := int(seconds / 3600)
	var minutes := int(fmod(seconds, 3600) / 60)
	var secs := int(fmod(seconds, 60))

	if hours > 0:
		return "%d:%02d:%02d" % [hours, minutes, secs]
	else:
		return "%d:%02d" % [minutes, secs]


# =============================================================================
# SHOW/HIDE
# =============================================================================

func show_menu() -> void:
	if is_showing:
		return

	is_showing = true
	visible = true
	pause_start_time = Time.get_ticks_msec() / 1000.0

	run_context = GameStateManager.get_current_run()
	_update_status()

	# Fade in
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, FADE_DURATION)

	# Focus resume button
	resume_button.grab_focus()


func hide_menu() -> void:
	if not is_showing:
		return

	is_showing = false
	total_pause_time += (Time.get_ticks_msec() / 1000.0) - pause_start_time

	# Fade out
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, FADE_DURATION)
	tween.tween_callback(func(): visible = false)


func _show_confirm_dialog() -> void:
	confirm_dialog.visible = true
	confirm_dialog.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(confirm_dialog, "modulate:a", 1.0, 0.15)


func _hide_confirm_dialog() -> void:
	var tween := create_tween()
	tween.tween_property(confirm_dialog, "modulate:a", 0.0, 0.15)
	tween.tween_callback(func(): confirm_dialog.visible = false)


# =============================================================================
# BUTTON HANDLERS
# =============================================================================

func _on_resume_pressed() -> void:
	resume_pressed.emit()
	hide_menu()
	GameStateManager.toggle_pause()


func _on_map_pressed() -> void:
	map_check_pressed.emit()
	# Transition to map check state (pause remains)
	GameStateManager.enter_map_check()


func _on_self_check_pressed() -> void:
	self_check_pressed.emit()


func _on_settings_pressed() -> void:
	settings_pressed.emit()
	# Would show settings overlay


func _on_streaming_pressed() -> void:
	streaming_settings_pressed.emit()


func _update_streaming_button() -> void:
	# Show streaming status on button
	var streamer_tools := ServiceLocator.get_service("StreamerTools") as StreamerTools
	if streamer_tools == null:
		return

	var summary := streamer_tools.get_summary()
	var label := "Streaming"

	if summary.obs_streaming:
		label = "Streaming [LIVE]"
		streaming_button.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	elif summary.obs_connected:
		label = "Streaming [OBS]"
		streaming_button.add_theme_color_override("font_color", Color(0.5, 0.8, 0.5))
	elif summary.is_active:
		label = "Streaming [ON]"
		streaming_button.remove_theme_color_override("font_color")
	else:
		streaming_button.remove_theme_color_override("font_color")

	streaming_button.text = label


func _on_abandon_pressed() -> void:
	_show_confirm_dialog()


func _on_confirm_cancel() -> void:
	_hide_confirm_dialog()


func _on_confirm_abandon() -> void:
	_hide_confirm_dialog()
	abandon_pressed.emit()

	# Record as fatality
	if run_context:
		run_context.set_meta("death_cause", "Abandoned")

	GameStateManager.complete_run(GameEnums.ResolutionType.FATALITY, "Run abandoned")


# =============================================================================
# INPUT
# =============================================================================

func _input(event: InputEvent) -> void:
	if not visible:
		return

	if event.is_action_pressed("ui_cancel"):
		if confirm_dialog.visible:
			_hide_confirm_dialog()
		else:
			_on_resume_pressed()
		get_viewport().set_input_as_handled()


# =============================================================================
# PUBLIC API
# =============================================================================

func get_total_pause_time() -> float:
	if is_showing:
		return total_pause_time + ((Time.get_ticks_msec() / 1000.0) - pause_start_time)
	return total_pause_time


func reset_pause_time() -> void:
	total_pause_time = 0.0
	pause_start_time = 0.0
