class_name MountainSelectScreen
extends Control
## Screen for selecting which mountain to descend
## Shows available mountains with difficulty, stats, and unlock status
##
## Design Philosophy:
## - Mountains are characters with personality
## - Progress unlocks knowledge, not just access
## - Show just enough to intrigue, not overwhelm

# =============================================================================
# SIGNALS
# =============================================================================

signal mountain_selected(mountain_id: String)
signal back_pressed()
signal continue_pressed()

# =============================================================================
# CONFIGURATION
# =============================================================================

## Card layout settings
const CARD_SIZE := Vector2(280, 180)
const CARD_SPACING := Vector2(20, 20)
const CARDS_PER_ROW := 3

## Colors
const UNLOCKED_COLOR := Color(0.95, 0.93, 0.88, 1.0)
const LOCKED_COLOR := Color(0.4, 0.4, 0.45, 0.7)
const SELECTED_COLOR := Color(0.4, 0.6, 0.8, 1.0)
const DIFFICULTY_COLORS := [
	Color(0.3, 0.7, 0.4),  # Beginner - green
	Color(0.5, 0.7, 0.3),  # Moderate - yellow-green
	Color(0.8, 0.6, 0.2),  # Challenging - orange
	Color(0.8, 0.3, 0.2),  # Expert - red
	Color(0.6, 0.2, 0.5),  # Extreme - purple
]

# =============================================================================
# STATE
# =============================================================================

## Reference to mountain database
var mountain_db: MountainDatabase

## Currently selected mountain ID
var selected_mountain_id: String = ""

## Mountain card nodes
var mountain_cards: Dictionary = {}  # id -> Control

## UI building flag
var ui_built: bool = false

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("MountainDatabase", _on_database_ready)


func _on_database_ready(db: MountainDatabase) -> void:
	mountain_db = db
	if mountain_db.is_loaded:
		_build_ui()
	else:
		mountain_db.database_loaded.connect(_build_ui)


func _build_ui() -> void:
	if ui_built:
		return
	ui_built = true

	# Clear existing content
	for child in get_children():
		child.queue_free()

	# Main layout
	var main_container := VBoxContainer.new()
	main_container.name = "MainContainer"
	main_container.anchor_right = 1.0
	main_container.anchor_bottom = 1.0
	main_container.add_theme_constant_override("separation", 20)
	add_child(main_container)

	# Header
	_create_header(main_container)

	# Content area - split view
	var content := HSplitContainer.new()
	content.name = "Content"
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_container.add_child(content)

	# Mountain grid (left side)
	_create_mountain_grid(content)

	# Detail panel (right side)
	_create_detail_panel(content)

	# Bottom buttons
	_create_button_bar(main_container)

	# Select first available mountain
	_select_first_available()

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
	title.text = "Select Descent"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", UNLOCKED_COLOR)
	header.add_child(title)

	var subtitle := Label.new()
	subtitle.name = "Subtitle"
	subtitle.text = "Choose your mountain"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.add_theme_color_override("font_color", Color(0.7, 0.7, 0.72, 0.8))
	header.add_child(subtitle)


func _create_mountain_grid(parent: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "MountainScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(600, 0)
	parent.add_child(scroll)

	var grid := GridContainer.new()
	grid.name = "MountainGrid"
	grid.columns = CARDS_PER_ROW
	grid.add_theme_constant_override("h_separation", int(CARD_SPACING.x))
	grid.add_theme_constant_override("v_separation", int(CARD_SPACING.y))
	scroll.add_child(grid)

	# Create cards for each mountain
	var mountains := mountain_db.get_all_mountains()
	mountains.sort_custom(func(a, b): return a.difficulty < b.difficulty)

	for mountain in mountains:
		var card := _create_mountain_card(mountain)
		grid.add_child(card)
		mountain_cards[mountain.id] = card


func _create_mountain_card(mountain: MountainDatabase.MountainData) -> Control:
	var is_unlocked := mountain_db.is_unlocked(mountain.id)
	var progress := mountain_db.get_progress(mountain.id)

	var card := PanelContainer.new()
	card.name = "Card_" + mountain.id
	card.custom_minimum_size = CARD_SIZE

	# Style
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.18, 0.9) if is_unlocked else Color(0.1, 0.1, 0.12, 0.7)
	style.border_width_left = 3
	style.border_width_right = 3
	style.border_width_top = 3
	style.border_width_bottom = 3
	style.border_color = Color(0.3, 0.3, 0.35, 0.5)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	card.add_theme_stylebox_override("panel", style)

	# Card content
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	card.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	# Mountain name
	var name_label := Label.new()
	name_label.text = mountain.name if is_unlocked else "???"
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", UNLOCKED_COLOR if is_unlocked else LOCKED_COLOR)
	content.add_child(name_label)

	# Region
	var region_label := Label.new()
	region_label.text = mountain.region if is_unlocked else "Unknown Region"
	region_label.add_theme_font_size_override("font_size", 14)
	region_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65, 0.8))
	content.add_child(region_label)

	# Difficulty indicator
	var difficulty_container := HBoxContainer.new()
	difficulty_container.add_theme_constant_override("separation", 4)
	content.add_child(difficulty_container)

	for i in range(5):
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(12, 12)
		if i < mountain.difficulty:
			dot.color = DIFFICULTY_COLORS[mountain.difficulty - 1] if is_unlocked else LOCKED_COLOR
		else:
			dot.color = Color(0.2, 0.2, 0.22, 0.5)
		difficulty_container.add_child(dot)

	var difficulty_label := Label.new()
	difficulty_label.text = " " + mountain.get_difficulty_name() if is_unlocked else " Locked"
	difficulty_label.add_theme_font_size_override("font_size", 12)
	difficulty_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	difficulty_container.add_child(difficulty_label)

	# Stats row
	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 16)
	content.add_child(stats)

	if is_unlocked:
		# Elevation
		var elev := Label.new()
		elev.text = "%dm" % int(mountain.summit_elevation)
		elev.add_theme_font_size_override("font_size", 12)
		elev.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		stats.add_child(elev)

		# Descent
		var descent := Label.new()
		descent.text = "↓%dm" % int(mountain.total_descent)
		descent.add_theme_font_size_override("font_size", 12)
		descent.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		stats.add_child(descent)
	else:
		var locked := Label.new()
		locked.text = "Complete prerequisites to unlock"
		locked.add_theme_font_size_override("font_size", 11)
		locked.add_theme_color_override("font_color", LOCKED_COLOR)
		stats.add_child(locked)

	# Progress indicator
	if progress.attempts > 0 and is_unlocked:
		var progress_label := Label.new()
		var knowledge_text := _get_knowledge_text(progress.knowledge)
		progress_label.text = knowledge_text
		progress_label.add_theme_font_size_override("font_size", 11)
		progress_label.add_theme_color_override("font_color", Color(0.4, 0.6, 0.5))
		content.add_child(progress_label)

	# Make clickable
	if is_unlocked:
		card.gui_input.connect(_on_card_input.bind(mountain.id))
		card.mouse_entered.connect(_on_card_hover.bind(mountain.id, true))
		card.mouse_exited.connect(_on_card_hover.bind(mountain.id, false))

	return card


func _create_detail_panel(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.name = "DetailPanel"
	panel.custom_minimum_size = Vector2(350, 0)
	parent.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.95)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	panel.add_theme_stylebox_override("panel", style)

	var scroll := ScrollContainer.new()
	scroll.name = "DetailScroll"
	panel.add_child(scroll)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	scroll.add_child(margin)

	var content := VBoxContainer.new()
	content.name = "DetailContent"
	content.add_theme_constant_override("separation", 16)
	margin.add_child(content)

	# Placeholder text
	var placeholder := Label.new()
	placeholder.name = "Placeholder"
	placeholder.text = "Select a mountain to view details"
	placeholder.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	content.add_child(placeholder)


func _create_button_bar(parent: Control) -> void:
	var bar := HBoxContainer.new()
	bar.name = "ButtonBar"
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 20)
	parent.add_child(bar)

	# Back button
	var back_btn := Button.new()
	back_btn.name = "BackButton"
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(120, 40)
	back_btn.pressed.connect(_on_back_pressed)
	bar.add_child(back_btn)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	# Continue button
	var continue_btn := Button.new()
	continue_btn.name = "ContinueButton"
	continue_btn.text = "Select Loadout"
	continue_btn.custom_minimum_size = Vector2(160, 40)
	continue_btn.disabled = true
	continue_btn.pressed.connect(_on_continue_pressed)
	bar.add_child(continue_btn)


# =============================================================================
# DETAIL PANEL UPDATE
# =============================================================================

func _update_detail_panel(mountain_id: String) -> void:
	var detail_content := get_node_or_null("MainContainer/Content/DetailPanel/DetailScroll/MarginContainer/DetailContent")
	if not detail_content:
		return

	# Clear existing content
	for child in detail_content.get_children():
		child.queue_free()

	if mountain_id.is_empty():
		var placeholder := Label.new()
		placeholder.text = "Select a mountain to view details"
		placeholder.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		detail_content.add_child(placeholder)
		return

	var mountain := mountain_db.get_mountain(mountain_id)
	var progress := mountain_db.get_progress(mountain_id)

	# Mountain name
	var name_label := Label.new()
	name_label.text = mountain.name
	name_label.add_theme_font_size_override("font_size", 28)
	name_label.add_theme_color_override("font_color", UNLOCKED_COLOR)
	detail_content.add_child(name_label)

	# Region
	var region := Label.new()
	region.text = mountain.region
	region.add_theme_font_size_override("font_size", 16)
	region.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	detail_content.add_child(region)

	# Description
	var desc := Label.new()
	desc.text = mountain.description
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_color_override("font_color", Color(0.75, 0.75, 0.78))
	detail_content.add_child(desc)

	# Separator
	var sep := HSeparator.new()
	detail_content.add_child(sep)

	# Stats grid
	var stats_title := Label.new()
	stats_title.text = "Mountain Statistics"
	stats_title.add_theme_font_size_override("font_size", 16)
	stats_title.add_theme_color_override("font_color", UNLOCKED_COLOR)
	detail_content.add_child(stats_title)

	_add_stat_row(detail_content, "Summit", "%dm" % int(mountain.summit_elevation))
	_add_stat_row(detail_content, "Base", "%dm" % int(mountain.base_elevation))
	_add_stat_row(detail_content, "Vertical", "%dm" % int(mountain.get_vertical()))
	_add_stat_row(detail_content, "Difficulty", mountain.get_difficulty_name())
	_add_stat_row(detail_content, "Est. Time", "%dh %dm" % [int(mountain.estimated_time) / 60, int(mountain.estimated_time) % 60])

	# Conditions
	var cond_sep := HSeparator.new()
	detail_content.add_child(cond_sep)

	var cond_title := Label.new()
	cond_title.text = "Conditions"
	cond_title.add_theme_font_size_override("font_size", 16)
	cond_title.add_theme_color_override("font_color", UNLOCKED_COLOR)
	detail_content.add_child(cond_title)

	_add_stat_row(detail_content, "Weather", "%.0f%% volatile" % (mountain.weather_volatility * 100))
	_add_stat_row(detail_content, "Wind", "%.0f%% exposed" % (mountain.wind_exposure * 100))
	_add_stat_row(detail_content, "Temperature", "%.0f°C typical" % mountain.typical_temperature)

	# Gear requirements
	var gear_sep := HSeparator.new()
	detail_content.add_child(gear_sep)

	var gear_title := Label.new()
	gear_title.text = "Gear Notes"
	gear_title.add_theme_font_size_override("font_size", 16)
	gear_title.add_theme_color_override("font_color", UNLOCKED_COLOR)
	detail_content.add_child(gear_title)

	if mountain.rope_required:
		_add_gear_note(detail_content, "Rope required", true)
	elif mountain.rope_recommended:
		_add_gear_note(detail_content, "Rope recommended", false)

	if mountain.crampons_required:
		_add_gear_note(detail_content, "Crampons required", true)

	if mountain.bivy_possible:
		_add_gear_note(detail_content, "Bivy gear possible", false)

	# Progress section
	if progress.attempts > 0:
		var prog_sep := HSeparator.new()
		detail_content.add_child(prog_sep)

		var prog_title := Label.new()
		prog_title.text = "Your History"
		prog_title.add_theme_font_size_override("font_size", 16)
		prog_title.add_theme_color_override("font_color", UNLOCKED_COLOR)
		detail_content.add_child(prog_title)

		_add_stat_row(detail_content, "Attempts", str(progress.attempts))
		_add_stat_row(detail_content, "Clean Returns", str(progress.clean_returns))
		_add_stat_row(detail_content, "Knowledge", _get_knowledge_text(progress.knowledge))

		if progress.best_time > 0:
			_add_stat_row(detail_content, "Best Time", RoutePlanner.format_time(progress.best_time))


func _add_stat_row(parent: Control, label_text: String, value_text: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	row.add_child(label)

	var value := Label.new()
	value.text = value_text
	value.add_theme_color_override("font_color", UNLOCKED_COLOR)
	row.add_child(value)


func _add_gear_note(parent: Control, text: String, required: bool) -> void:
	var label := Label.new()
	label.text = ("● " if required else "○ ") + text
	label.add_theme_color_override("font_color", Color(0.8, 0.5, 0.3) if required else Color(0.5, 0.6, 0.5))
	parent.add_child(label)


func _get_knowledge_text(knowledge: GameEnums.KnowledgeLevel) -> String:
	match knowledge:
		GameEnums.KnowledgeLevel.UNKNOWN:
			return "Unknown"
		GameEnums.KnowledgeLevel.ATTEMPTED:
			return "Attempted"
		GameEnums.KnowledgeLevel.FAMILIAR:
			return "Familiar"
		GameEnums.KnowledgeLevel.EXPERIENCED:
			return "Experienced"
		GameEnums.KnowledgeLevel.MASTERED:
			return "Mastered"
		_:
			return "Unknown"


# =============================================================================
# SELECTION
# =============================================================================

func _select_mountain(mountain_id: String) -> void:
	# Update visual selection
	for id in mountain_cards:
		var card: PanelContainer = mountain_cards[id]
		var style: StyleBoxFlat = card.get_theme_stylebox("panel")
		if id == mountain_id:
			style.border_color = SELECTED_COLOR
		else:
			style.border_color = Color(0.3, 0.3, 0.35, 0.5)

	selected_mountain_id = mountain_id
	mountain_selected.emit(mountain_id)

	# Update detail panel
	_update_detail_panel(mountain_id)

	# Enable continue button
	var continue_btn := get_node_or_null("MainContainer/ButtonBar/ContinueButton")
	if continue_btn:
		continue_btn.disabled = mountain_id.is_empty()


func _select_first_available() -> void:
	var available := mountain_db.get_available_mountains()
	if available.size() > 0:
		# Sort by difficulty and select easiest
		available.sort_custom(func(a, b): return a.difficulty < b.difficulty)
		_select_mountain(available[0].id)


# =============================================================================
# INPUT HANDLERS
# =============================================================================

func _on_card_input(event: InputEvent, mountain_id: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_select_mountain(mountain_id)


func _on_card_hover(mountain_id: String, entered: bool) -> void:
	var card := mountain_cards.get(mountain_id) as PanelContainer
	if not card:
		return

	var style: StyleBoxFlat = card.get_theme_stylebox("panel")
	if mountain_id == selected_mountain_id:
		return  # Don't change selected card

	if entered:
		style.border_color = Color(0.5, 0.5, 0.55, 0.7)
	else:
		style.border_color = Color(0.3, 0.3, 0.35, 0.5)


func _on_back_pressed() -> void:
	back_pressed.emit()
	GameStateManager.transition_to(GameEnums.GameState.MAIN_MENU)


func _on_continue_pressed() -> void:
	if selected_mountain_id.is_empty():
		return

	# Store selection in database
	mountain_db.select_mountain(selected_mountain_id)

	continue_pressed.emit()
	GameStateManager.transition_to(GameEnums.GameState.LOADOUT_CONFIG)


# =============================================================================
# PUBLIC API
# =============================================================================

func refresh() -> void:
	## Rebuild UI (after unlock changes)
	ui_built = false
	_build_ui()


func get_selected_mountain() -> MountainDatabase.MountainData:
	return mountain_db.get_mountain(selected_mountain_id)
