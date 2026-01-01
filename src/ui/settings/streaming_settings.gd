class_name StreamingSettings
extends Control
## Streaming settings panel for OBS integration and streamer tools
##
## Design Philosophy:
## - Simple toggles for common options
## - Advanced settings hidden but accessible
## - Real-time connection status

# =============================================================================
# SIGNALS
# =============================================================================

signal settings_changed()
signal close_requested()

# =============================================================================
# REFERENCES
# =============================================================================

var obs_integration: OBSIntegration
var streamer_tools: StreamerTools

# =============================================================================
# UI REFERENCES
# =============================================================================

var connection_status: Label
var connect_button: Button
var host_input: LineEdit
var port_input: SpinBox

var streamer_mode_toggle: CheckButton
var content_warning_toggle: CheckButton
var predictive_fades_toggle: CheckButton
var wind_only_toggle: CheckButton
var delay_fatal_toggle: CheckButton
var exclude_fatal_toggle: CheckButton

var shot_bias_option: OptionButton
var human_error_slider: HSlider

var marker_slides_toggle: CheckButton
var marker_rope_toggle: CheckButton
var marker_injuries_toggle: CheckButton
var marker_weather_toggle: CheckButton
var marker_decisions_toggle: CheckButton

var scene_hints_toggle: CheckButton
var scene_gameplay_input: LineEdit
var scene_ending_input: LineEdit
var scene_menu_input: LineEdit
var scene_stats_input: LineEdit

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	_build_ui()
	_connect_services()


func _build_ui() -> void:
	# Main container
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(600, 500)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(scroll)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	scroll.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	margin.add_child(vbox)

	# Header
	var header := _create_header(vbox)

	# OBS Connection
	_create_connection_section(vbox)

	# Streamer Mode Settings
	_create_streamer_section(vbox)

	# Camera Settings
	_create_camera_section(vbox)

	# Marker Settings
	_create_marker_section(vbox)

	# Scene Settings
	_create_scene_section(vbox)

	# Close button
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func(): close_requested.emit())
	vbox.add_child(close_btn)


func _create_header(parent: Control) -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	parent.add_child(hbox)

	var title := Label.new()
	title.text = "Streaming Settings"
	title.add_theme_font_size_override("font_size", 24)
	hbox.add_child(title)

	hbox.add_child(Control.new())  # Spacer

	connection_status = Label.new()
	connection_status.text = "OBS: Disconnected"
	hbox.add_child(connection_status)

	return hbox


func _create_connection_section(parent: Control) -> void:
	var section := _create_section("OBS Connection", parent)

	# Host/Port row
	var conn_row := HBoxContainer.new()
	conn_row.add_theme_constant_override("separation", 8)
	section.add_child(conn_row)

	var host_label := Label.new()
	host_label.text = "Host:"
	conn_row.add_child(host_label)

	host_input = LineEdit.new()
	host_input.text = "127.0.0.1"
	host_input.custom_minimum_size.x = 120
	host_input.text_changed.connect(func(_t): _save_settings())
	conn_row.add_child(host_input)

	var port_label := Label.new()
	port_label.text = "Port:"
	conn_row.add_child(port_label)

	port_input = SpinBox.new()
	port_input.min_value = 1
	port_input.max_value = 65535
	port_input.value = 4455
	port_input.value_changed.connect(func(_v): _save_settings())
	conn_row.add_child(port_input)

	conn_row.add_child(Control.new())  # Spacer

	connect_button = Button.new()
	connect_button.text = "Connect"
	connect_button.pressed.connect(_on_connect_pressed)
	conn_row.add_child(connect_button)


func _create_streamer_section(parent: Control) -> void:
	var section := _create_section("Streamer Mode", parent)

	streamer_mode_toggle = _create_toggle("Enable Streamer Mode", section)
	streamer_mode_toggle.tooltip_text = "Enables all streamer-friendly features"
	streamer_mode_toggle.toggled.connect(_on_streamer_mode_toggled)

	content_warning_toggle = _create_toggle("Show Content Warning", section)
	content_warning_toggle.tooltip_text = "Display content warning at stream start"
	content_warning_toggle.toggled.connect(func(_v): _save_settings())

	predictive_fades_toggle = _create_toggle("Predictive Fades", section)
	predictive_fades_toggle.tooltip_text = "Fade stream feed before intense moments"
	predictive_fades_toggle.toggled.connect(func(_v): _save_settings())

	wind_only_toggle = _create_toggle("Wind-Only Fatal Audio", section)
	wind_only_toggle.tooltip_text = "Replace fatal audio with wind during death"
	wind_only_toggle.toggled.connect(func(_v): _save_settings())

	delay_fatal_toggle = _create_toggle("Delay Fatal Replay", section)
	delay_fatal_toggle.tooltip_text = "Don't show fatal replays until stream ends"
	delay_fatal_toggle.toggled.connect(func(_v): _save_settings())

	exclude_fatal_toggle = _create_toggle("Exclude Fatal Highlights", section)
	exclude_fatal_toggle.tooltip_text = "Exclude death from auto-generated highlights"
	exclude_fatal_toggle.toggled.connect(func(_v): _save_settings())


func _create_camera_section(parent: Control) -> void:
	var section := _create_section("Camera Preferences", parent)

	# Shot bias
	var bias_row := HBoxContainer.new()
	bias_row.add_theme_constant_override("separation", 8)
	section.add_child(bias_row)

	var bias_label := Label.new()
	bias_label.text = "Shot Preference:"
	bias_row.add_child(bias_label)

	shot_bias_option = OptionButton.new()
	shot_bias_option.add_item("Context-Heavy", 0)
	shot_bias_option.add_item("Balanced", 1)
	shot_bias_option.add_item("Action-Heavy", 2)
	shot_bias_option.select(1)
	shot_bias_option.item_selected.connect(func(_i): _save_settings())
	bias_row.add_child(shot_bias_option)

	# Human error slider
	var error_row := HBoxContainer.new()
	error_row.add_theme_constant_override("separation", 8)
	section.add_child(error_row)

	var error_label := Label.new()
	error_label.text = "Camera \"Human Error\":"
	error_row.add_child(error_label)

	human_error_slider = HSlider.new()
	human_error_slider.min_value = 0.0
	human_error_slider.max_value = 1.0
	human_error_slider.step = 0.1
	human_error_slider.value = 0.5
	human_error_slider.custom_minimum_size.x = 150
	human_error_slider.value_changed.connect(func(_v): _save_settings())
	error_row.add_child(human_error_slider)

	var error_hint := Label.new()
	error_hint.text = "(More = missed shots, late arrivals)"
	error_hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	section.add_child(error_hint)


func _create_marker_section(parent: Control) -> void:
	var section := _create_section("Automatic Markers", parent)

	var hint := Label.new()
	hint.text = "Create recording markers for:"
	section.add_child(hint)

	marker_slides_toggle = _create_toggle("Slides", section)
	marker_slides_toggle.toggled.connect(func(_v): _save_settings())

	marker_rope_toggle = _create_toggle("Rope Deployments", section)
	marker_rope_toggle.toggled.connect(func(_v): _save_settings())

	marker_injuries_toggle = _create_toggle("Injuries", section)
	marker_injuries_toggle.toggled.connect(func(_v): _save_settings())

	marker_weather_toggle = _create_toggle("Weather Changes", section)
	marker_weather_toggle.toggled.connect(func(_v): _save_settings())

	marker_decisions_toggle = _create_toggle("Key Decisions", section)
	marker_decisions_toggle.toggled.connect(func(_v): _save_settings())


func _create_scene_section(parent: Control) -> void:
	var section := _create_section("Scene Suggestions", parent)

	scene_hints_toggle = _create_toggle("Suggest Scene Changes", section)
	scene_hints_toggle.tooltip_text = "Game suggests OBS scene changes"
	scene_hints_toggle.toggled.connect(func(_v): _save_settings())

	scene_gameplay_input = _create_scene_input("Gameplay Scene:", section)
	scene_ending_input = _create_scene_input("Ending Scene:", section)
	scene_menu_input = _create_scene_input("Menu Scene:", section)
	scene_stats_input = _create_scene_input("Stats Scene:", section)


func _create_section(title: String, parent: Control) -> VBoxContainer:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 8)
	parent.add_child(container)

	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 18)
	container.add_child(label)

	var sep := HSeparator.new()
	container.add_child(sep)

	return container


func _create_toggle(text: String, parent: Control) -> CheckButton:
	var toggle := CheckButton.new()
	toggle.text = text
	parent.add_child(toggle)
	return toggle


func _create_scene_input(label_text: String, parent: Control) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 120
	row.add_child(label)

	var input := LineEdit.new()
	input.custom_minimum_size.x = 200
	input.text_changed.connect(func(_t): _save_settings())
	row.add_child(input)

	return input


# =============================================================================
# SERVICE CONNECTION
# =============================================================================

func _connect_services() -> void:
	ServiceLocator.get_service_async("OBSIntegration", func(service):
		obs_integration = service
		_connect_obs_signals()
		_load_settings()
	)

	ServiceLocator.get_service_async("StreamerTools", func(service):
		streamer_tools = service
		_load_settings()
	)


func _connect_obs_signals() -> void:
	if obs_integration == null:
		return

	obs_integration.connected.connect(_update_connection_status)
	obs_integration.disconnected.connect(_update_connection_status)
	obs_integration.stream_started.connect(_update_connection_status)
	obs_integration.stream_stopped.connect(_update_connection_status)


func _update_connection_status() -> void:
	if obs_integration == null:
		connection_status.text = "OBS: Not Available"
		return

	var status := obs_integration.get_status()
	if not status.connected:
		connection_status.text = "OBS: Disconnected"
		connection_status.add_theme_color_override("font_color", Color(0.8, 0.3, 0.3))
		connect_button.text = "Connect"
	else:
		var status_parts: Array[String] = ["OBS: Connected"]
		if status.streaming:
			status_parts.append("LIVE")
		if status.recording:
			status_parts.append("REC")
		connection_status.text = " | ".join(status_parts)
		connection_status.add_theme_color_override("font_color", Color(0.3, 0.8, 0.3))
		connect_button.text = "Disconnect"


# =============================================================================
# SETTINGS
# =============================================================================

func _load_settings() -> void:
	# Load OBS settings
	if obs_integration:
		var obs_settings := obs_integration.get_settings()
		host_input.text = obs_settings.get("host", "127.0.0.1")
		port_input.value = obs_settings.get("port", 4455)
		marker_slides_toggle.button_pressed = obs_settings.get("marker_slides", true)
		marker_rope_toggle.button_pressed = obs_settings.get("marker_rope", true)
		marker_injuries_toggle.button_pressed = obs_settings.get("marker_injuries", true)
		marker_weather_toggle.button_pressed = obs_settings.get("marker_weather", true)
		marker_decisions_toggle.button_pressed = obs_settings.get("marker_decisions", false)
		scene_hints_toggle.button_pressed = obs_settings.get("enable_scene_hints", true)
		scene_gameplay_input.text = obs_settings.get("scene_gameplay", "Gameplay")
		scene_ending_input.text = obs_settings.get("scene_ending", "Ending")
		scene_menu_input.text = obs_settings.get("scene_menu", "Menu")
		scene_stats_input.text = obs_settings.get("scene_stats", "Stats")
		_update_connection_status()

	# Load streamer tools settings
	if streamer_tools:
		var st_settings := streamer_tools.get_settings()
		streamer_mode_toggle.button_pressed = streamer_tools.is_active
		content_warning_toggle.button_pressed = st_settings.get("show_start_warning", true)
		predictive_fades_toggle.button_pressed = st_settings.get("predictive_fades_enabled", true)
		wind_only_toggle.button_pressed = st_settings.get("wind_only_fatal", false)
		delay_fatal_toggle.button_pressed = st_settings.get("delay_fatal_replay", false)
		exclude_fatal_toggle.button_pressed = st_settings.get("exclude_fatal_highlights", true)

		var bias: String = st_settings.get("shot_bias", "balanced")
		match bias:
			"context": shot_bias_option.select(0)
			"balanced": shot_bias_option.select(1)
			"action": shot_bias_option.select(2)

		human_error_slider.value = st_settings.get("human_error_amount", 0.5)


func _save_settings() -> void:
	# Save OBS settings
	if obs_integration:
		obs_integration.apply_settings({
			"host": host_input.text,
			"port": int(port_input.value),
			"marker_slides": marker_slides_toggle.button_pressed,
			"marker_rope": marker_rope_toggle.button_pressed,
			"marker_injuries": marker_injuries_toggle.button_pressed,
			"marker_weather": marker_weather_toggle.button_pressed,
			"marker_decisions": marker_decisions_toggle.button_pressed,
			"enable_scene_hints": scene_hints_toggle.button_pressed,
			"scene_gameplay": scene_gameplay_input.text,
			"scene_ending": scene_ending_input.text,
			"scene_menu": scene_menu_input.text,
			"scene_stats": scene_stats_input.text
		})

	# Save streamer tools settings
	if streamer_tools:
		var bias := "balanced"
		match shot_bias_option.selected:
			0: bias = "context"
			1: bias = "balanced"
			2: bias = "action"

		streamer_tools.apply_settings({
			"show_start_warning": content_warning_toggle.button_pressed,
			"predictive_fades_enabled": predictive_fades_toggle.button_pressed,
			"wind_only_fatal": wind_only_toggle.button_pressed,
			"delay_fatal_replay": delay_fatal_toggle.button_pressed,
			"exclude_fatal_highlights": exclude_fatal_toggle.button_pressed,
			"shot_bias": bias,
			"human_error_amount": human_error_slider.value
		})

	settings_changed.emit()


# =============================================================================
# HANDLERS
# =============================================================================

func _on_connect_pressed() -> void:
	if obs_integration == null:
		return

	if obs_integration.is_connected:
		obs_integration.disconnect_from_obs()
	else:
		obs_integration.host = host_input.text
		obs_integration.port = int(port_input.value)
		obs_integration.connect_to_obs()


func _on_streamer_mode_toggled(enabled: bool) -> void:
	if streamer_tools == null:
		return

	if enabled:
		streamer_tools.enable_streamer_mode()
	else:
		streamer_tools.disable_streamer_mode()

	_save_settings()


# =============================================================================
# PUBLIC API
# =============================================================================

func show_settings() -> void:
	visible = true
	_load_settings()


func hide_settings() -> void:
	visible = false
