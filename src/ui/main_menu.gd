class_name MainMenu
extends Control
## Main menu screen
## Atmospheric, minimal interface matching the game's philosophy

# =============================================================================
# SIGNALS
# =============================================================================

signal new_descent_pressed()
signal continue_pressed()
signal settings_pressed()
signal logbook_pressed()
signal quit_pressed()

# =============================================================================
# REFERENCES
# =============================================================================

@onready var title_label: Label = $VBoxContainer/TitleLabel
@onready var subtitle_label: Label = $VBoxContainer/SubtitleLabel
@onready var new_descent_button: Button = $VBoxContainer/ButtonContainer/NewDescentButton
@onready var continue_button: Button = $VBoxContainer/ButtonContainer/ContinueButton
@onready var logbook_button: Button = $VBoxContainer/ButtonContainer/LogbookButton
@onready var settings_button: Button = $VBoxContainer/ButtonContainer/SettingsButton
@onready var quit_button: Button = $VBoxContainer/ButtonContainer/QuitButton
@onready var version_label: Label = $VersionLabel

# =============================================================================
# STATE
# =============================================================================

## Whether there is a run set aside to continue (SaveManager's suspended run)
var has_save: bool = false

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_setup_buttons()
	_apply_theme()
	_fade_in()

	refresh()


func _setup_buttons() -> void:
	new_descent_button.pressed.connect(_on_new_descent_pressed)
	continue_button.pressed.connect(_on_continue_pressed)
	logbook_button.pressed.connect(_on_logbook_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	quit_button.pressed.connect(_on_quit_pressed)

	# Set version
	version_label.text = "v0.1.0"


func _apply_theme() -> void:
	# Atmospheric styling - will be enhanced with proper theme resource
	title_label.add_theme_font_size_override("font_size", 72)
	subtitle_label.add_theme_font_size_override("font_size", 18)

	# Muted colors fitting the mountain aesthetic
	var text_color := Color(0.9, 0.9, 0.92, 1.0)
	var dim_color := Color(0.6, 0.6, 0.65, 0.8)

	title_label.add_theme_color_override("font_color", text_color)
	subtitle_label.add_theme_color_override("font_color", dim_color)
	version_label.add_theme_color_override("font_color", dim_color)


func _fade_in() -> void:
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 1.5).set_ease(Tween.EASE_OUT)


# =============================================================================
# SAVE CHECK
# =============================================================================

## Show Continue only when a run has been set aside (pause menu > Save and
## Quit), and say which
func refresh() -> void:
	var summary := _suspended_run_summary()
	has_save = not summary.is_empty()
	continue_button.visible = has_save
	continue_button.text = "Continue"
	if has_save:
		var place := str(summary.get("mountain_name", ""))
		var hours := fposmod(float(summary.get("clock", 0.0)), 24.0)
		var clock := "%02d:%02d" % [int(hours), int(fmod(hours * 60.0, 60.0))]
		continue_button.tooltip_text = "%s, %s, at %d m" % [place, clock, roundi(float(summary.get("elevation", 0.0)))] \
			if not place.is_empty() else "Pick up the descent you set aside"
		if not place.is_empty():
			continue_button.text = "Continue · %s" % place


## What SaveManager says about the run set aside, with the mountain's name
## ({} when there is none)
func _suspended_run_summary() -> Dictionary:
	var save_manager := ServiceLocator.get_service("SaveManager") as SaveManager
	if save_manager == null:
		return {}
	var summary := save_manager.get_suspended_run_summary()
	if summary.is_empty():
		return {}
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	if mountain_db == null:
		return summary
	# A run on a mountain this version does not have cannot be continued
	var mountain: MountainDatabase.MountainData = mountain_db.get_mountain(str(summary.get("mountain_id", "")))
	if mountain == null:
		return {}
	summary["mountain_name"] = mountain.name
	return summary


# =============================================================================
# BUTTON HANDLERS
# =============================================================================

func _on_new_descent_pressed() -> void:
	_play_button_sound()
	new_descent_pressed.emit()
	# Transition to mountain select
	GameStateManager.transition_to(GameEnums.GameState.MOUNTAIN_SELECT)


## Main loads the run that was set aside and carries on with it
func _on_continue_pressed() -> void:
	_play_button_sound()
	continue_pressed.emit()


## Main shows the logbook (lifetime record) over the menu
func _on_logbook_pressed() -> void:
	logbook_pressed.emit()


## Main shows the settings screen over the menu
func _on_settings_pressed() -> void:
	_play_button_sound()
	settings_pressed.emit()


func _on_quit_pressed() -> void:
	_play_button_sound()
	quit_pressed.emit()
	# Fade out then quit
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.5)
	tween.tween_callback(get_tree().quit)


func _play_button_sound() -> void:
	# Subtle click sound - will be connected to AudioManager
	pass


# =============================================================================
# PUBLIC API
# =============================================================================

## Show the menu with optional fade
func show_menu(fade: bool = true) -> void:
	visible = true
	refresh()
	if fade:
		_fade_in()
	else:
		modulate.a = 1.0


## Hide the menu with optional fade
func hide_menu(fade: bool = true) -> void:
	if fade:
		var tween := create_tween()
		tween.tween_property(self, "modulate:a", 0.0, 0.5)
		tween.tween_callback(func(): visible = false)
	else:
		visible = false
