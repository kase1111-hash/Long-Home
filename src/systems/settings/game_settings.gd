class_name GameSettings
extends Node
## The player's own settings: how loud each kind of sound is, how the game is
## displayed, and how the camera handles.
##
## Kept in user://settings.json, applied when the game starts and again
## whenever one changes. Registered as the "GameSettings" service.
##
## Reading and changing a setting:
##   var settings := ServiceLocator.get_service("GameSettings") as GameSettings
##   settings.get_value("camera_sway")            # 0-1
##   settings.set_value("volume_ambient", 0.5)     # applied and saved
##   settings.changed.connect(_on_setting_changed) # (key, value)
##
## Sound levels and the display are applied here. Things that live in the
## world (the climber's camera) read their settings themselves and follow
## the changed signal, because they come and go with each descent.

signal changed(key: String, value: Variant)

const SETTINGS_PATH := "user://settings.json"

## Every setting and its value on a fresh install
const DEFAULTS := {
	# Sound: slider positions, 0-1 (the level heard is the square: see level_for)
	"volume_master": 1.0,
	"volume_ambient": 1.0,
	"volume_climber": 1.0,
	"volume_effects": 1.0,
	"volume_interface": 1.0,
	# Display
	"fullscreen": false,
	"vsync": true,
	"antialiasing": 2,       # Viewport.MSAA: 0 off, 1 2x, 2 4x, 3 8x
	"render_scale": 1.0,     # 3D resolution, 0.5-1
	# Camera
	"mouse_sensitivity": 1.0,  # multiplier, 0.25-3
	"invert_y": false,
	"camera_sway": 1.0,        # sway and shake, 0-1
}

## Range of each numeric setting
const LIMITS := {
	"volume_master": Vector2(0.0, 1.0),
	"volume_ambient": Vector2(0.0, 1.0),
	"volume_climber": Vector2(0.0, 1.0),
	"volume_effects": Vector2(0.0, 1.0),
	"volume_interface": Vector2(0.0, 1.0),
	"antialiasing": Vector2(0, 3),
	"render_scale": Vector2(0.5, 1.0),
	"mouse_sensitivity": Vector2(0.25, 3.0),
	"camera_sway": Vector2(0.0, 1.0),
}

## Which group of sounds each volume setting turns (AudioService.set_user_volume)
const VOLUME_GROUPS := {
	"volume_master": "master",
	"volume_ambient": "ambient",
	"volume_climber": "climber",
	"volume_effects": "effects",
	"volume_interface": "interface",
}

## Seconds after the last change before the file is written (a slider being
## dragged changes many times a second)
const SAVE_DELAY := 0.4

## Where the settings are kept, and whether changes are written there. Tests
## turn persist off (or point the path elsewhere) so that running them never
## touches the settings of whoever runs them.
var settings_path: String = SETTINGS_PATH
var persist: bool = true

var _values: Dictionary = {}
var _save_in: float = -1.0


func _ready() -> void:
	# Settings are changed from the pause menu
	process_mode = Node.PROCESS_MODE_ALWAYS
	ServiceLocator.register_service("GameSettings", self)
	load_settings()
	apply_all()
	print("[GameSettings] Ready (%s)" % ("defaults" if not FileAccess.file_exists(settings_path) else settings_path))


func _process(delta: float) -> void:
	if _save_in < 0.0:
		return
	_save_in -= delta
	if _save_in <= 0.0:
		save_settings()


func _exit_tree() -> void:
	if _save_in >= 0.0:
		save_settings()


# =============================================================================
# VALUES
# =============================================================================

func get_value(key: String) -> Variant:
	return _values.get(key, DEFAULTS.get(key))


## Change a setting: it is applied at once and written to disk shortly after.
## Unknown keys are refused; numbers are kept inside their range.
func set_value(key: String, value: Variant) -> void:
	if not DEFAULTS.has(key):
		push_warning("[GameSettings] No such setting: %s" % key)
		return
	var cleaned: Variant = _clean(key, value)
	if _values.get(key) == cleaned:
		return
	_values[key] = cleaned
	_apply(key)
	changed.emit(key, cleaned)
	if persist:
		_save_in = SAVE_DELAY


## Put settings back to their fresh-install values (all of them, or the keys given)
func reset(keys: Array = []) -> void:
	for key in (DEFAULTS.keys() if keys.is_empty() else keys):
		set_value(str(key), DEFAULTS.get(str(key)))


func is_default(key: String) -> bool:
	return get_value(key) == DEFAULTS.get(key)


## A value of the right type and inside its range for a setting
func _clean(key: String, value: Variant) -> Variant:
	var fallback: Variant = DEFAULTS[key]
	if fallback is bool:
		return bool(value) if (value is bool or value is int or value is float) else fallback
	if not (value is int or value is float):
		return fallback
	var number := float(value)
	if is_nan(number) or is_inf(number):
		return fallback
	if LIMITS.has(key):
		var limit: Vector2 = LIMITS[key]
		number = clampf(number, limit.x, limit.y)
	return int(round(number)) if fallback is int else number


# =============================================================================
# FILE
# =============================================================================

func load_settings() -> void:
	_values = DEFAULTS.duplicate()
	if not FileAccess.file_exists(settings_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(settings_path))
	if not (parsed is Dictionary):
		push_warning("[GameSettings] %s is not readable; using defaults" % settings_path)
		return
	# Only settings this version knows, each checked: a file from another
	# version, or one edited by hand, cannot put the game in a bad state
	for key in DEFAULTS.keys():
		if (parsed as Dictionary).has(key):
			_values[key] = _clean(key, parsed[key])


func save_settings() -> bool:
	_save_in = -1.0
	if not persist:
		return false
	var file := FileAccess.open(settings_path, FileAccess.WRITE)
	if file == null:
		push_warning("[GameSettings] Could not write %s" % settings_path)
		return false
	file.store_string(JSON.stringify(_values, "\t"))
	return true


# =============================================================================
# APPLYING
# =============================================================================

func apply_all() -> void:
	for key in DEFAULTS.keys():
		_apply(key)


func _apply(key: String) -> void:
	if VOLUME_GROUPS.has(key):
		var audio := ServiceLocator.get_service("AudioService") as AudioService
		if audio != null:
			audio.set_user_volume(VOLUME_GROUPS[key], level_for(float(get_value(key))))
		return
	match key:
		"fullscreen":
			_apply_fullscreen(bool(get_value(key)))
		"vsync":
			if _has_window():
				DisplayServer.window_set_vsync_mode(
					DisplayServer.VSYNC_ENABLED if bool(get_value(key)) else DisplayServer.VSYNC_DISABLED)
		"antialiasing":
			get_tree().root.msaa_3d = int(get_value(key)) as Viewport.MSAA
		"render_scale":
			get_tree().root.scaling_3d_scale = float(get_value(key))


## Fullscreen on, or back to a window. Off leaves the window as the player has
## it (the game starts maximised) unless it is fullscreen now.
func _apply_fullscreen(on: bool) -> void:
	if not _has_window():
		return
	var mode := DisplayServer.window_get_mode()
	var is_full := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if on and not is_full:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif not on and is_full:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)


## False when the game runs without a window (tests, servers)
func _has_window() -> bool:
	return DisplayServer.get_name() != "headless"


## The level a volume slider at a position (0-1) gives, as a linear gain. The
## square, so the middle of the slider sounds like about half as loud.
static func level_for(slider: float) -> float:
	var at := clampf(slider, 0.0, 1.0)
	return at * at


## The key the player presses for an action, as their keyboard labels it
## ("W", "Space"); "" when the action has no key
static func key_name(action: String) -> String:
	if not InputMap.has_action(action):
		return ""
	for event in InputMap.action_get_events(action):
		var key := event as InputEventKey
		if key == null:
			continue
		var code := key.keycode
		if code == KEY_NONE and key.physical_keycode != KEY_NONE:
			code = DisplayServer.keyboard_get_keycode_from_physical(key.physical_keycode)
		if code != KEY_NONE:
			return OS.get_keycode_string(code)
	return ""
