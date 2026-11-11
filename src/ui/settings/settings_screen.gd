class_name SettingsScreen
extends Control
## The settings screen: how loud each kind of sound is, how the game is
## displayed, and how the camera handles.
##
## Opened from the main menu and from the pause menu (it works while the game
## is paused). Every control writes straight to GameSettings, which applies
## the change at once and saves it; there is nothing to confirm.

signal close_requested()

# =============================================================================
# WHAT IS ON EACH PAGE
# =============================================================================

## Sound: setting, name, what it covers, and a sound to play when the slider is
## let go ([id, bus, volume_db]) so the new level can be judged
const SOUND_ROWS := [
	["volume_master", "Everything", "", ["ui_confirm", "UI", -6.0]],
	["volume_ambient", "Wind and weather", "Wind, gusts, rain, the glacier", ["wind_gust", "Ambient", -6.0]],
	["volume_climber", "The climber", "Breath, heartbeat, footsteps", ["footstep_snow_firm", "Player", -8.0]],
	["volume_effects", "Movement and gear", "Slides, skis, rope, hardware, avalanches", ["carabiner_clip", "Effects", -6.0]],
	["volume_interface", "Menus and map", "", ["ui_select", "UI", -6.0]],
]

const ANTIALIASING_CHOICES: Array[String] = ["Off", "2x", "4x", "8x"]

## The keys, in the order a player meets them
const KEY_ROWS := [
	["move_forward", "Move forward"],
	["move_back", "Move back; brake a glissade"],
	["move_left", "Move left"],
	["move_right", "Move right"],
	["lean_left", "Lean left in a glissade"],
	["lean_right", "Lean right in a glissade"],
	["slide_initiate", "Glissade; self-arrest; airbag; dig"],
	["rope_deploy", "Rope: anchor, rappel, unclip"],
	["crampons_toggle", "Crampons on or off"],
	["skis_toggle", "Skis or splitboard on or off"],
	["probe", "Probe the snow ahead"],
	["snow_pit", "Dig a snow pit"],
	["check_self", "Check yourself"],
	["open_map", "Map"],
	["drone_view", "Watch through the film crew's drone"],
]

## Keys that are not actions in the input map
const FIXED_KEY_ROWS := [
	["Mouse", "Look around"],
	["Esc", "Pause"],
	["H", "Show or hide the control hints"],
]

const PANEL_SIZE := Vector2(900, 740)
const LABEL_COLOR := Color(0.9, 0.88, 0.85)
const NOTE_COLOR := Color(0.6, 0.6, 0.65)

# =============================================================================
# STATE
# =============================================================================

var settings: GameSettings
var tabs: TabContainer
var back_button: Button
var reset_button: Button

## key -> the control that shows it (HSlider, CheckButton or OptionButton)
var _controls: Dictionary = {}
## key -> the label that shows a slider's value
var _value_labels: Dictionary = {}
## key -> Callable(value) -> String for that label
var _formats: Dictionary = {}
## tab index -> the settings on that page
var _page_keys: Dictionary = {}
var _keys_grid: GridContainer

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Anchors and offsets: in the tree, set_anchors_preset() alone would keep
	# the current (empty) rectangle
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	settings = ServiceLocator.get_service("GameSettings") as GameSettings
	_build_ui()
	if settings != null:
		settings.changed.connect(_on_setting_changed)


func _input(event: InputEvent) -> void:
	# Before the pause menu and the game see it: Esc leaves this screen only
	if visible and event.is_action_pressed("ui_cancel"):
		close_requested.emit()
		get_viewport().set_input_as_handled()


func show_settings() -> void:
	_refresh()
	visible = true
	if back_button != null:
		back_button.grab_focus()


func hide_settings() -> void:
	visible = false


# =============================================================================
# BUILDING
# =============================================================================

func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color(0.05, 0.06, 0.08, 0.96)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = PANEL_SIZE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.11, 0.14)
	style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)

	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88))
	column.add_child(title)

	tabs = TabContainer.new()
	tabs.name = "Tabs"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.tab_changed.connect(func(_tab: int) -> void: _update_reset_button())
	column.add_child(tabs)

	_build_sound_page(_add_page("Sound"))
	_build_display_page(_add_page("Display"))
	_build_controls_page(_add_page("Controls"))

	var buttons := HBoxContainer.new()
	column.add_child(buttons)

	reset_button = Button.new()
	reset_button.name = "ResetButton"
	reset_button.custom_minimum_size = Vector2(0, 40)
	reset_button.pressed.connect(_on_reset_pressed)
	buttons.add_child(reset_button)

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(gap)

	back_button = Button.new()
	back_button.name = "BackButton"
	back_button.text = "Back"
	back_button.custom_minimum_size = Vector2(160, 40)
	back_button.pressed.connect(func() -> void: close_requested.emit())
	buttons.add_child(back_button)

	_update_reset_button()


## A page of the tab container; returns the box its rows go in
func _add_page(page_name: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = page_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 18)
	scroll.add_child(margin)

	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.add_theme_constant_override("separation", 14)
	margin.add_child(rows)
	_page_keys[tabs.get_tab_count() - 1] = []
	return rows


func _build_sound_page(rows: VBoxContainer) -> void:
	for row in SOUND_ROWS:
		var slider := _add_slider(rows, row[0], row[1], row[2], 0.0, 1.0, 0.01, _percent)
		slider.drag_ended.connect(_on_volume_let_go.bind(row[3]))
	_add_note(rows, "There is no music in the game. Wind, breath and footsteps are how it tells you things.")


func _build_display_page(rows: VBoxContainer) -> void:
	_add_toggle(rows, "fullscreen", "Fullscreen", "")
	_add_toggle(rows, "vsync", "V-Sync", "Matches frames to the screen. Off can feel quicker and can tear.")
	_add_choice(rows, "antialiasing", "Anti-aliasing", "Smooths edges. Lower is faster.", ANTIALIASING_CHOICES)
	# Measured: on the Forward+ renderer half resolution is plainly softer (and
	# cheaper); the Compatibility renderer of Godot 4.2 ignores the setting
	var scalable := EnvironmentVisuals.detect_rendering_method() != "gl_compatibility"
	var scale := _add_slider(rows, "render_scale", "3D resolution",
		"Draws the mountain at a lower resolution to run faster. Menus stay sharp." if scalable
		else "Not available with the compatibility renderer this computer is using.",
		0.5, 1.0, 0.05, _percent)
	scale.editable = scalable
	_add_toggle(rows, "show_timer", "Run timer",
		"Shows the time you have been on the mountain, and your fastest return on it, on the HUD and at the end of a run.")


func _build_controls_page(rows: VBoxContainer) -> void:
	_add_slider(rows, "mouse_sensitivity", "Mouse speed", "", 0.25, 3.0, 0.05, _percent)
	_add_toggle(rows, "invert_y", "Invert vertical look", "")
	_add_slider(rows, "camera_sway", "Camera sway and shake",
		"The camera sways when you are tired or unsteady and shakes on impacts. Turn it down if the motion is uncomfortable.",
		0.0, 1.0, 0.05, _percent)

	rows.add_child(HSeparator.new())
	var heading := Label.new()
	heading.text = "Keys"
	heading.add_theme_font_size_override("font_size", 17)
	heading.add_theme_color_override("font_color", LABEL_COLOR)
	rows.add_child(heading)

	_keys_grid = GridContainer.new()
	_keys_grid.name = "Keys"
	_keys_grid.columns = 4
	_keys_grid.add_theme_constant_override("h_separation", 18)
	_keys_grid.add_theme_constant_override("v_separation", 6)
	rows.add_child(_keys_grid)
	_fill_keys()
	_add_note(rows, "The keys are fixed in this version.")


## Two columns of "key, what it does"
func _fill_keys() -> void:
	for child in _keys_grid.get_children():
		_keys_grid.remove_child(child)
		child.queue_free()
	var entries: Array = []
	for row in KEY_ROWS:
		var key := GameSettings.key_name(row[0])
		entries.append([key if not key.is_empty() else "-", row[1]])
	entries.append_array(FIXED_KEY_ROWS)
	for entry in entries:
		var key_label := Label.new()
		key_label.text = entry[0]
		key_label.custom_minimum_size = Vector2(64, 0)
		key_label.add_theme_font_size_override("font_size", 14)
		key_label.add_theme_color_override("font_color", Color(0.95, 0.88, 0.6))
		_keys_grid.add_child(key_label)
		var what := Label.new()
		what.text = entry[1]
		what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		what.add_theme_font_size_override("font_size", 14)
		what.add_theme_color_override("font_color", LABEL_COLOR)
		_keys_grid.add_child(what)


# =============================================================================
# ROWS
# =============================================================================

## The left part of a row: its name and, under it, what it covers
func _add_row(rows: VBoxContainer, key: String, label_text: String, note: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = key
	row.add_theme_constant_override("separation", 16)
	rows.add_child(row)

	var text := VBoxContainer.new()
	text.custom_minimum_size = Vector2(380, 0)
	text.add_theme_constant_override("separation", 2)
	row.add_child(text)

	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", LABEL_COLOR)
	text.add_child(label)

	if not note.is_empty():
		var small := Label.new()
		small.text = note
		small.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		small.add_theme_font_size_override("font_size", 12)
		small.add_theme_color_override("font_color", NOTE_COLOR)
		text.add_child(small)

	(_page_keys[tabs.get_tab_count() - 1] as Array).append(key)
	return row


func _add_slider(rows: VBoxContainer, key: String, label_text: String, note: String,
		from: float, to: float, step: float, format: Callable) -> HSlider:
	var row := _add_row(rows, key, label_text, note)

	var slider := HSlider.new()
	slider.min_value = from
	slider.max_value = to
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(240, 0)
	# The default track is as dark as the panel: show the whole run of it
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.24, 0.25, 0.3)
	track.set_corner_radius_all(2)
	track.content_margin_top = 2.0
	track.content_margin_bottom = 2.0
	slider.add_theme_stylebox_override("slider", track)
	var filled := track.duplicate() as StyleBoxFlat
	filled.bg_color = Color(0.8, 0.76, 0.62)
	slider.add_theme_stylebox_override("grabber_area", filled)
	slider.add_theme_stylebox_override("grabber_area_highlight", filled)
	slider.value_changed.connect(func(value: float) -> void: _write(key, value))
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(56, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", 14)
	value_label.add_theme_color_override("font_color", LABEL_COLOR)
	row.add_child(value_label)

	_controls[key] = slider
	_value_labels[key] = value_label
	_formats[key] = format
	return slider


func _add_toggle(rows: VBoxContainer, key: String, label_text: String, note: String) -> CheckButton:
	var row := _add_row(rows, key, label_text, note)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)

	# The default switch is hard to read when it is off: say which it is
	var state := Label.new()
	state.add_theme_font_size_override("font_size", 14)
	state.add_theme_color_override("font_color", NOTE_COLOR)
	row.add_child(state)

	var toggle := CheckButton.new()
	toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	toggle.toggled.connect(func(on: bool) -> void: _write(key, on))
	row.add_child(toggle)
	_controls[key] = toggle
	_value_labels[key] = state
	_formats[key] = func(value: Variant) -> String: return "On" if bool(value) else "Off"
	return toggle


func _add_choice(rows: VBoxContainer, key: String, label_text: String, note: String, choices: Array[String]) -> OptionButton:
	var row := _add_row(rows, key, label_text, note)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)

	var choice := OptionButton.new()
	choice.custom_minimum_size = Vector2(120, 0)
	choice.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for i in choices.size():
		choice.add_item(choices[i], i)
	choice.item_selected.connect(func(index: int) -> void: _write(key, index))
	row.add_child(choice)
	_controls[key] = choice
	return choice


func _add_note(rows: VBoxContainer, text: String) -> void:
	var note := Label.new()
	note.text = text
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", NOTE_COLOR)
	rows.add_child(note)


func _percent(value: Variant) -> String:
	return "%d%%" % roundi(float(value) * 100.0)


# =============================================================================
# READING AND WRITING SETTINGS
# =============================================================================

func _write(key: String, value: Variant) -> void:
	if settings != null:
		settings.set_value(key, value)
	_show_value(key, value)
	_update_reset_button()


## Put every control where its setting is, without that counting as a change
func _refresh() -> void:
	if settings == null:
		return
	for key in _controls.keys():
		_show_control(key, settings.get_value(key))
	_fill_keys()
	_update_reset_button()


func _on_setting_changed(key: String, value: Variant) -> void:
	if _controls.has(key):
		_show_control(key, value)
	_update_reset_button()


func _show_control(key: String, value: Variant) -> void:
	var control: Control = _controls[key]
	if control is HSlider:
		(control as HSlider).set_value_no_signal(float(value))
	elif control is CheckButton:
		(control as CheckButton).set_pressed_no_signal(bool(value))
	elif control is OptionButton:
		(control as OptionButton).select(int(value))
	_show_value(key, value)


func _show_value(key: String, value: Variant) -> void:
	if _value_labels.has(key):
		(_value_labels[key] as Label).text = (_formats[key] as Callable).call(value)


## "Reset" is for the page in view, and says so
func _update_reset_button() -> void:
	if reset_button == null or tabs == null:
		return
	var page := tabs.current_tab
	reset_button.text = "Reset %s to defaults" % tabs.get_tab_title(page).to_lower()
	var changed_here := false
	if settings != null:
		for key in _page_keys.get(page, []):
			changed_here = changed_here or not settings.is_default(key)
	reset_button.disabled = not changed_here


func _on_reset_pressed() -> void:
	if settings != null:
		settings.reset(_page_keys.get(tabs.current_tab, []))
	_refresh()


## A volume slider was let go: play something through what it controls
func _on_volume_let_go(value_changed: bool, sample: Array) -> void:
	if not value_changed:
		return
	var audio := ServiceLocator.get_service("AudioService") as AudioService
	if audio != null:
		audio.play(str(sample[0]), float(sample[2]), 1.0, str(sample[1]))
