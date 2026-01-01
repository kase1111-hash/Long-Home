class_name LoadoutConfigScreen
extends Control
## Screen for configuring gear loadout before a descent
## Shows gear options, weight trade-offs, and mountain requirements
##
## Design Philosophy:
## - Every choice has consequences
## - No perfect loadout, only trade-offs
## - Make requirements clear, let player decide

# =============================================================================
# SIGNALS
# =============================================================================

signal back_pressed()
signal start_descent_pressed(loadout: GearState)

# =============================================================================
# CONFIGURATION
# =============================================================================

const ITEM_HEIGHT := 50
const SECTION_SPACING := 20

const COLOR_INCLUDED := Color(0.3, 0.6, 0.4, 1.0)
const COLOR_EXCLUDED := Color(0.5, 0.5, 0.55, 0.6)
const COLOR_REQUIRED := Color(0.8, 0.5, 0.3, 1.0)
const COLOR_ERROR := Color(0.8, 0.3, 0.3, 1.0)
const COLOR_WARNING := Color(0.8, 0.6, 0.2, 1.0)

# =============================================================================
# STATE
# =============================================================================

## References
var mountain_db: MountainDatabase
var gear_db: GearDatabase

## Selected mountain
var mountain: MountainDatabase.MountainData

## Current loadout being configured
var current_loadout: GearState

## Gear item toggles
var gear_toggles: Dictionary = {}  # GearType -> CheckButton

## UI built flag
var ui_built: bool = false

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("MountainDatabase", func(db):
		mountain_db = db
		_check_ready()
	)
	ServiceLocator.get_service_async("GearDatabase", func(db):
		gear_db = db
		_check_ready()
	)


func _check_ready() -> void:
	if mountain_db and gear_db:
		_initialize()


func _initialize() -> void:
	# Get selected mountain
	mountain = mountain_db.get_selected_mountain()
	if not mountain:
		# Fallback to first available
		var available := mountain_db.get_available_mountains()
		if available.size() > 0:
			mountain = available[0]

	# Start with standard loadout
	current_loadout = GearState.create_standard_loadout()

	_build_ui()


func _build_ui() -> void:
	if ui_built:
		return
	ui_built = true

	# Clear existing
	for child in get_children():
		child.queue_free()

	# Main container
	var main := VBoxContainer.new()
	main.name = "MainContainer"
	main.anchor_right = 1.0
	main.anchor_bottom = 1.0
	main.add_theme_constant_override("separation", 15)
	add_child(main)

	# Header
	_create_header(main)

	# Content - split view
	var content := HBoxContainer.new()
	content.name = "Content"
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 20)
	main.add_child(content)

	# Left: Mountain info and presets
	_create_left_panel(content)

	# Center: Gear list
	_create_gear_list(content)

	# Right: Summary and validation
	_create_summary_panel(content)

	# Bottom buttons
	_create_button_bar(main)

	# Initial update
	_update_summary()

	# Fade in
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.5)


# =============================================================================
# UI CREATION
# =============================================================================

func _create_header(parent: Control) -> void:
	var header := VBoxContainer.new()
	header.name = "Header"
	parent.add_child(header)

	var title := Label.new()
	title.name = "Title"
	title.text = "Configure Loadout"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 42)
	title.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88))
	header.add_child(title)


func _create_left_panel(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.name = "LeftPanel"
	panel.custom_minimum_size = Vector2(280, 0)
	parent.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.9)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)

	# Mountain section
	var mountain_label := Label.new()
	mountain_label.text = "Destination"
	mountain_label.add_theme_font_size_override("font_size", 16)
	mountain_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.72))
	content.add_child(mountain_label)

	if mountain:
		var name_label := Label.new()
		name_label.text = mountain.name
		name_label.add_theme_font_size_override("font_size", 22)
		name_label.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88))
		content.add_child(name_label)

		var stats := Label.new()
		stats.text = "%s | %dm descent | %s" % [
			mountain.region,
			int(mountain.total_descent),
			mountain.get_difficulty_name()
		]
		stats.add_theme_font_size_override("font_size", 12)
		stats.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		content.add_child(stats)

	# Requirements section
	var sep1 := HSeparator.new()
	content.add_child(sep1)

	var req_label := Label.new()
	req_label.text = "Requirements"
	req_label.add_theme_font_size_override("font_size", 16)
	req_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.72))
	content.add_child(req_label)

	if mountain:
		if mountain.rope_required:
			_add_requirement(content, "Rope required", true)
		elif mountain.rope_recommended:
			_add_requirement(content, "Rope recommended", false)

		if mountain.crampons_required:
			_add_requirement(content, "Crampons required", true)

		if mountain.bivy_possible:
			_add_requirement(content, "Bivy possible", false)

	# Presets section
	var sep2 := HSeparator.new()
	content.add_child(sep2)

	var preset_label := Label.new()
	preset_label.text = "Quick Loadouts"
	preset_label.add_theme_font_size_override("font_size", 16)
	preset_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.72))
	content.add_child(preset_label)

	for preset_name in gear_db.get_preset_names():
		if preset_name == "Custom":
			continue
		var btn := Button.new()
		btn.text = preset_name
		btn.pressed.connect(_on_preset_selected.bind(preset_name))
		content.add_child(btn)


func _add_requirement(parent: Control, text: String, required: bool) -> void:
	var label := Label.new()
	label.text = ("● " if required else "○ ") + text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", COLOR_REQUIRED if required else Color(0.5, 0.6, 0.5))
	parent.add_child(label)


func _create_gear_list(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.name = "GearPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.9)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", style)

	var scroll := ScrollContainer.new()
	scroll.name = "GearScroll"
	panel.add_child(scroll)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	scroll.add_child(margin)

	var gear_list := VBoxContainer.new()
	gear_list.name = "GearList"
	gear_list.add_theme_constant_override("separation", 8)
	margin.add_child(gear_list)

	# Add gear by category
	for category in gear_db.get_categories():
		_add_category_section(gear_list, category)


func _add_category_section(parent: Control, category: String) -> void:
	var section := VBoxContainer.new()
	section.name = "Section_" + category
	section.add_theme_constant_override("separation", 4)
	parent.add_child(section)

	# Category header
	var header := Label.new()
	header.text = category.to_upper()
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	section.add_child(header)

	# Items in category
	var items := gear_db.get_items_by_category(category)
	for item_info in items:
		_add_gear_item_row(section, item_info)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, SECTION_SPACING)
	section.add_child(spacer)


func _add_gear_item_row(parent: Control, item_info: GearDatabase.GearItemInfo) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ITEM_HEIGHT)
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)

	# Checkbox
	var check := CheckButton.new()
	check.name = "Check_" + str(item_info.type)
	check.button_pressed = current_loadout.has_item(item_info.type)
	check.disabled = item_info.is_essential
	check.toggled.connect(_on_gear_toggled.bind(item_info.type))
	row.add_child(check)
	gear_toggles[item_info.type] = check

	# Info container
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	# Name row
	var name_row := HBoxContainer.new()
	info.add_child(name_row)

	var name_label := Label.new()
	name_label.text = item_info.name
	name_label.add_theme_font_size_override("font_size", 16)
	if item_info.is_essential:
		name_label.add_theme_color_override("font_color", COLOR_REQUIRED)
	else:
		name_label.add_theme_color_override("font_color", Color(0.9, 0.88, 0.85))
	name_row.add_child(name_label)

	if item_info.is_essential:
		var essential := Label.new()
		essential.text = " (Essential)"
		essential.add_theme_font_size_override("font_size", 12)
		essential.add_theme_color_override("font_color", Color(0.6, 0.5, 0.4))
		name_row.add_child(essential)

	# Description
	var desc := Label.new()
	desc.text = item_info.description
	desc.add_theme_font_size_override("font_size", 11)
	desc.add_theme_color_override("font_color", Color(0.55, 0.55, 0.58))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(desc)

	# Weight
	var weight := Label.new()
	weight.text = "%.1f kg" % item_info.base_weight
	weight.custom_minimum_size = Vector2(60, 0)
	weight.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	weight.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	row.add_child(weight)


func _create_summary_panel(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.name = "SummaryPanel"
	panel.custom_minimum_size = Vector2(260, 0)
	parent.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.9)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.name = "SummaryContent"
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)

	# Weight section
	var weight_title := Label.new()
	weight_title.text = "Total Weight"
	weight_title.add_theme_font_size_override("font_size", 14)
	weight_title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.72))
	content.add_child(weight_title)

	var weight_value := Label.new()
	weight_value.name = "WeightValue"
	weight_value.text = "0.0 kg"
	weight_value.add_theme_font_size_override("font_size", 28)
	content.add_child(weight_value)

	var weight_rating := Label.new()
	weight_rating.name = "WeightRating"
	weight_rating.text = "Standard"
	weight_rating.add_theme_font_size_override("font_size", 14)
	content.add_child(weight_rating)

	# Separator
	var sep1 := HSeparator.new()
	content.add_child(sep1)

	# Validation section
	var valid_title := Label.new()
	valid_title.text = "Validation"
	valid_title.add_theme_font_size_override("font_size", 14)
	valid_title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.72))
	content.add_child(valid_title)

	var messages := VBoxContainer.new()
	messages.name = "ValidationMessages"
	messages.add_theme_constant_override("separation", 4)
	content.add_child(messages)

	# Separator
	var sep2 := HSeparator.new()
	content.add_child(sep2)

	# Stats section
	var stats_title := Label.new()
	stats_title.text = "Loadout Effects"
	stats_title.add_theme_font_size_override("font_size", 14)
	stats_title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.72))
	content.add_child(stats_title)

	var stats := VBoxContainer.new()
	stats.name = "LoadoutStats"
	stats.add_theme_constant_override("separation", 4)
	content.add_child(stats)


func _create_button_bar(parent: Control) -> void:
	var bar := HBoxContainer.new()
	bar.name = "ButtonBar"
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 20)
	parent.add_child(bar)

	var back := Button.new()
	back.name = "BackButton"
	back.text = "Back"
	back.custom_minimum_size = Vector2(120, 40)
	back.pressed.connect(_on_back_pressed)
	bar.add_child(back)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var start := Button.new()
	start.name = "StartButton"
	start.text = "Begin Descent"
	start.custom_minimum_size = Vector2(160, 40)
	start.pressed.connect(_on_start_pressed)
	bar.add_child(start)


# =============================================================================
# UPDATE LOGIC
# =============================================================================

func _update_summary() -> void:
	if not mountain:
		return

	# Update weight display
	var weight_value := get_node_or_null("MainContainer/Content/SummaryPanel/MarginContainer/SummaryContent/WeightValue")
	var weight_rating := get_node_or_null("MainContainer/Content/SummaryPanel/MarginContainer/SummaryContent/WeightRating")

	if weight_value:
		weight_value.text = "%.1f kg" % current_loadout.total_weight

	if weight_rating:
		var assessment := gear_db.get_weight_assessment(current_loadout.total_weight)
		weight_rating.text = assessment["rating"]
		weight_rating.add_theme_color_override("font_color", assessment["color"])

	# Update validation messages
	var messages := get_node_or_null("MainContainer/Content/SummaryPanel/MarginContainer/SummaryContent/ValidationMessages")
	if messages:
		for child in messages.get_children():
			child.queue_free()

		var check := gear_db.check_requirements(current_loadout, mountain)

		if check["errors"].size() == 0 and check["warnings"].size() == 0:
			var ok := Label.new()
			ok.text = "✓ All requirements met"
			ok.add_theme_font_size_override("font_size", 13)
			ok.add_theme_color_override("font_color", COLOR_INCLUDED)
			messages.add_child(ok)
		else:
			for error in check["errors"]:
				var label := Label.new()
				label.text = "✗ " + error
				label.add_theme_font_size_override("font_size", 12)
				label.add_theme_color_override("font_color", COLOR_ERROR)
				label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				messages.add_child(label)

			for warning in check["warnings"]:
				var label := Label.new()
				label.text = "! " + warning
				label.add_theme_font_size_override("font_size", 12)
				label.add_theme_color_override("font_color", COLOR_WARNING)
				label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				messages.add_child(label)

		# Update start button
		var start_btn := get_node_or_null("MainContainer/ButtonBar/StartButton")
		if start_btn:
			start_btn.disabled = not check["met"]

	# Update loadout stats
	var stats := get_node_or_null("MainContainer/Content/SummaryPanel/MarginContainer/SummaryContent/LoadoutStats")
	if stats:
		for child in stats.get_children():
			child.queue_free()

		_add_stat(stats, "Speed Modifier", "%.0f%%" % (current_loadout.get_weight_modifier() * 100))
		_add_stat(stats, "Warmth Rating", "%.0f%%" % (current_loadout.get_warmth_rating() * 100))

		if current_loadout.has_item(GameEnums.GearType.ROPE):
			_add_stat(stats, "Rope Length", "%.0fm" % current_loadout.get_rope_length())


func _add_stat(parent: Control, label_text: String, value_text: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	row.add_child(label)

	var value := Label.new()
	value.text = value_text
	value.add_theme_font_size_override("font_size", 12)
	value.add_theme_color_override("font_color", Color(0.85, 0.83, 0.8))
	row.add_child(value)


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_gear_toggled(pressed: bool, gear_type: GameEnums.GearType) -> void:
	var info := gear_db.get_item_info(gear_type)
	if not info:
		return

	if pressed:
		var item := GearState.GearItem.new(gear_type, 1.0, info.base_weight)
		current_loadout.add_item(item)
	else:
		current_loadout.remove_item(gear_type)

	_update_summary()


func _on_preset_selected(preset_name: String) -> void:
	current_loadout = gear_db.create_preset_loadout(preset_name)

	# Update all toggles
	for gear_type in gear_toggles:
		var toggle: CheckButton = gear_toggles[gear_type]
		toggle.button_pressed = current_loadout.has_item(gear_type)

	_update_summary()


func _on_back_pressed() -> void:
	back_pressed.emit()
	GameStateManager.transition_to(GameEnums.GameState.MOUNTAIN_SELECT)


func _on_start_pressed() -> void:
	# Validate one more time
	var check := gear_db.check_requirements(current_loadout, mountain)
	if not check["met"]:
		return

	start_descent_pressed.emit(current_loadout)

	# Transition to planning or directly to descent
	# For now, go to planning
	GameStateManager.transition_to(GameEnums.GameState.PLANNING)


# =============================================================================
# PUBLIC API
# =============================================================================

func set_mountain(m: MountainDatabase.MountainData) -> void:
	mountain = m
	if ui_built:
		# Would need to rebuild left panel
		pass


func get_loadout() -> GearState:
	return current_loadout
