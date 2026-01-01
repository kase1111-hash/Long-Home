class_name StatsDisplay
extends Control
## Displays player statistics and progression
## Shows lifetime stats, recent runs, and achievements
##
## Design Philosophy:
## - Stats tell your story
## - Progress is visible and meaningful
## - History informs future decisions

# =============================================================================
# SIGNALS
# =============================================================================

signal close_requested()
signal achievement_selected(achievement_id: String)

# =============================================================================
# STATE
# =============================================================================

var save_manager: SaveManager
var is_built: bool = false

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("SaveManager", func(sm):
		save_manager = sm
		_build_ui()
	)


func _build_ui() -> void:
	if is_built or save_manager == null:
		return
	is_built = true

	# Clear existing
	for child in get_children():
		child.queue_free()

	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.09, 0.12, 0.95)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Main container
	var main := VBoxContainer.new()
	main.name = "Main"
	main.set_anchors_preset(Control.PRESET_FULL_RECT)
	main.add_theme_constant_override("separation", 20)
	add_child(main)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 40)
	margin.add_theme_constant_override("margin_bottom", 40)
	main.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 20)
	margin.add_child(content)

	# Header
	_create_header(content)

	# Stats sections
	var sections := HBoxContainer.new()
	sections.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sections.add_theme_constant_override("separation", 30)
	content.add_child(sections)

	_create_lifetime_stats(sections)
	_create_recent_runs(sections)
	_create_achievements(sections)

	# Close button
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(120, 40)
	close.pressed.connect(func(): close_requested.emit())
	content.add_child(close)


func _create_header(parent: Control) -> void:
	var header := VBoxContainer.new()
	parent.add_child(header)

	var title := Label.new()
	title.text = "Your Journey"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88))
	header.add_child(title)

	var profile := save_manager.get_profile()
	if profile:
		var subtitle := Label.new()
		subtitle.text = "%s | %s | %d runs" % [
			profile.display_name,
			profile.get_experience_level(),
			profile.total_runs
		]
		subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		subtitle.add_theme_font_size_override("font_size", 16)
		subtitle.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		header.add_child(subtitle)


func _create_lifetime_stats(parent: Control) -> void:
	var panel := _create_panel("Lifetime Statistics")
	parent.add_child(panel)

	var content := panel.get_node("Content")
	var profile := save_manager.get_profile()

	if profile == null:
		return

	_add_stat_row(content, "Total Runs", str(profile.total_runs))
	_add_stat_row(content, "Successful Runs", str(profile.successful_runs))
	_add_stat_row(content, "Clean Returns", str(profile.clean_returns))
	_add_stat_row(content, "Success Rate", "%.0f%%" % (profile.get_success_rate() * 100))
	_add_stat_row(content, "", "")  # Spacer
	_add_stat_row(content, "Total Descent", "%.0fm" % profile.total_descent_meters)
	_add_stat_row(content, "Longest Descent", "%.0fm" % profile.longest_descent)
	_add_stat_row(content, "Play Time", profile.get_formatted_play_time())
	_add_stat_row(content, "", "")  # Spacer
	_add_stat_row(content, "Best Streak", str(profile.best_streak))
	_add_stat_row(content, "Current Streak", str(profile.current_streak))
	_add_stat_row(content, "Mountains Completed", str(profile.mountains_completed.size()))


func _create_recent_runs(parent: Control) -> void:
	var panel := _create_panel("Recent Runs")
	parent.add_child(panel)

	var content := panel.get_node("Content")
	var history := save_manager.get_history()

	if history == null:
		return

	var recent := history.get_recent_entries(10)

	if recent.size() == 0:
		var empty := Label.new()
		empty.text = "No runs yet"
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		content.add_child(empty)
		return

	for entry in recent:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		content.add_child(row)

		# Outcome indicator
		var indicator := ColorRect.new()
		indicator.custom_minimum_size = Vector2(8, 8)
		match entry.outcome:
			GameEnums.ResolutionType.CLEAN_RETURN:
				indicator.color = Color(0.3, 0.8, 0.4)
			GameEnums.ResolutionType.INJURED_RETURN:
				indicator.color = Color(0.8, 0.7, 0.3)
			GameEnums.ResolutionType.FORCED_BIVY:
				indicator.color = Color(0.7, 0.5, 0.3)
			GameEnums.ResolutionType.RESCUE:
				indicator.color = Color(0.8, 0.4, 0.3)
			GameEnums.ResolutionType.FATALITY:
				indicator.color = Color(0.6, 0.3, 0.3)
		row.add_child(indicator)

		# Mountain name
		var mountain := Label.new()
		mountain.text = entry.mountain_id
		mountain.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mountain.add_theme_font_size_override("font_size", 13)
		mountain.add_theme_color_override("font_color", Color(0.85, 0.83, 0.8))
		row.add_child(mountain)

		# Duration
		var duration := Label.new()
		var minutes := int(entry.duration / 60)
		duration.text = "%dm" % minutes
		duration.add_theme_font_size_override("font_size", 12)
		duration.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		row.add_child(duration)


func _create_achievements(parent: Control) -> void:
	var panel := _create_panel("Achievements")
	parent.add_child(panel)

	var content := panel.get_node("Content")
	var progression := save_manager.get_progression()

	if progression == null:
		return

	var progress := progression.get_achievement_progress()
	var header := Label.new()
	header.text = "%d / %d unlocked" % [progress["unlocked"], progress["total"]]
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", Color(0.6, 0.7, 0.5))
	content.add_child(header)

	var sep := HSeparator.new()
	content.add_child(sep)

	# Show recent achievements
	var unlocked := progression.get_unlocked_achievements()
	unlocked.sort_custom(func(a, b): return a.unlocked_at > b.unlocked_at)

	var shown := 0
	for achievement in unlocked:
		if shown >= 5:
			break
		shown += 1

		var row := HBoxContainer.new()
		content.add_child(row)

		var icon := Label.new()
		icon.text = "★"
		icon.add_theme_color_override("font_color", Color(0.9, 0.8, 0.3))
		row.add_child(icon)

		var name_label := Label.new()
		name_label.text = achievement.name
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.add_theme_font_size_override("font_size", 13)
		name_label.add_theme_color_override("font_color", Color(0.85, 0.83, 0.8))
		row.add_child(name_label)

	# Show locked count
	if progress["unlocked"] < progress["total"]:
		var locked := Label.new()
		locked.text = "+ %d more to unlock" % (progress["total"] - progress["unlocked"])
		locked.add_theme_font_size_override("font_size", 12)
		locked.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		content.add_child(locked)


func _create_panel(title: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

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

	var scroll := ScrollContainer.new()
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.name = "Content"
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 18)
	title_label.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88))
	vbox.add_child(title_label)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	return panel


func _add_stat_row(parent: Control, label_text: String, value_text: String) -> void:
	if label_text.is_empty():
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, 8)
		parent.add_child(spacer)
		return

	var row := HBoxContainer.new()
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	row.add_child(label)

	var value := Label.new()
	value.text = value_text
	value.add_theme_font_size_override("font_size", 13)
	value.add_theme_color_override("font_color", Color(0.9, 0.88, 0.85))
	row.add_child(value)


# =============================================================================
# REFRESH
# =============================================================================

func refresh() -> void:
	is_built = false
	_build_ui()
