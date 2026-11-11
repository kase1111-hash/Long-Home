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
##
## The controls live here too: which key and which gamepad button each action
## has (ControlsMap lists the actions and their defaults), and which device
## the player last touched, so that on-screen text can name the right control.
##   settings.set_binding("crampons_toggle", ControlsMap.Device.KEYBOARD, KEY_X)
##   settings.get_binding("pause", ControlsMap.Device.GAMEPAD)   # a JoyButton
##   settings.device                                              # KEYBOARD or GAMEPAD
##   settings.bindings_changed, settings.device_changed

signal changed(key: String, value: Variant)
## A key or a gamepad button was bound to another action (or all were reset)
signal bindings_changed()
## The player picked up the other device (ControlsMap.Device)
signal device_changed(device: int)

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
	"show_timer": false,     # The run timer on the HUD and the resolution screen
	# Camera
	"mouse_sensitivity": 1.0,  # multiplier, 0.25-3
	"stick_sensitivity": 1.0,  # multiplier for looking with the right stick, 0.25-3
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
	"stick_sensitivity": Vector2(0.25, 3.0),
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

## The player's controls: action -> {"key": physical keycode, "pad": gamepad button or -1}
var _bindings: Dictionary = ControlsMap.defaults()

## The device the player last touched, and how its buttons are named
var device: int = ControlsMap.Device.KEYBOARD
var pad_style: int = ControlsMap.PadStyle.XBOX

## A stick has to move this far to count as the player picking the gamepad up
const STICK_WAKE := 0.5


func _ready() -> void:
	# Settings are changed from the pause menu
	process_mode = Node.PROCESS_MODE_ALWAYS
	ServiceLocator.register_service("GameSettings", self)
	load_settings()
	apply_all()
	ControlsMap.apply(_bindings)
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


## Which device is in the player's hands: the last one they touched
func _input(event: InputEvent) -> void:
	var touched := device
	if event is InputEventKey or event is InputEventMouseButton:
		touched = ControlsMap.Device.KEYBOARD
	elif event is InputEventMouseMotion:
		# A mouse that is only being nudged does not take the screen back
		if (event as InputEventMouseMotion).relative.length() > 4.0:
			touched = ControlsMap.Device.KEYBOARD
	elif event is InputEventJoypadButton:
		touched = ControlsMap.Device.GAMEPAD
	elif event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) >= STICK_WAKE:
			touched = ControlsMap.Device.GAMEPAD
	if touched == device:
		return
	device = touched
	if device == ControlsMap.Device.GAMEPAD:
		pad_style = ControlsMap.pad_style_of(Input.get_joy_name(event.device))
	device_changed.emit(device)


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
# CONTROLS
# =============================================================================

## Every action's bindings (a copy): action -> {"key": int, "pad": int}
func get_bindings() -> Dictionary:
	return _bindings.duplicate(true)


## The key (physical keycode) or gamepad button of an action; KEY_NONE or -1
## when it has none on that device
func get_binding(action: String, on_device: int) -> int:
	var bound: Dictionary = _bindings.get(action, {})
	if on_device == ControlsMap.Device.GAMEPAD:
		return int(bound.get("pad", -1))
	return int(bound.get("key", KEY_NONE))


## Give an action another key or gamepad button. If another action had it,
## the two change places (no control is ever left doing two things, or
## nothing). Returns that other action ("" when there was none).
func set_binding(action: String, on_device: int, code: int) -> String:
	if not ControlsMap.has_action(action):
		push_warning("[GameSettings] No such action: %s" % action)
		return ""
	var field := "pad" if on_device == ControlsMap.Device.GAMEPAD else "key"
	if on_device == ControlsMap.Device.GAMEPAD and (code < 0 or code > ControlsMap.MAX_PAD_BUTTON):
		return ""
	if on_device == ControlsMap.Device.KEYBOARD and code == KEY_NONE:
		return ""
	var before := int(_bindings[action][field])
	if before == code:
		return ""
	var swapped := ""
	for other in _bindings:
		if other != action and int(_bindings[other][field]) == code:
			_bindings[other][field] = before
			swapped = other
	_bindings[action][field] = code
	_bindings_changed()
	return swapped


## Every control back to its default
func reset_bindings() -> void:
	if bindings_are_default():
		return
	_bindings = ControlsMap.defaults()
	_bindings_changed()


func bindings_are_default() -> bool:
	return _bindings == ControlsMap.defaults()


func _bindings_changed() -> void:
	ControlsMap.apply(_bindings)
	bindings_changed.emit()
	if persist:
		_save_in = SAVE_DELAY


## Bindings read from a file: only actions this version has, each a key and a
## button that can be one; anything else keeps its default
func _clean_bindings(saved: Variant) -> Dictionary:
	var bindings := ControlsMap.defaults()
	if not (saved is Dictionary):
		return bindings
	for action in bindings:
		var entry: Variant = (saved as Dictionary).get(action)
		if not (entry is Dictionary):
			continue
		var key: Variant = entry.get("key")
		if (key is int or key is float) and int(key) > 0:
			bindings[action]["key"] = int(key)
		var pad: Variant = entry.get("pad")
		if (pad is int or pad is float) and int(pad) >= -1 and int(pad) <= ControlsMap.MAX_PAD_BUTTON:
			bindings[action]["pad"] = int(pad)
	# A file edited by hand can give two actions one control: the later one
	# goes back to its default if that is free, else it goes without
	for field in ["key", "pad"]:
		var taken := {}
		for action in bindings:
			var code := int(bindings[action][field])
			if code <= 0 and field == "key" or code < 0:
				continue
			if taken.has(code):
				var fallback := int(ControlsMap.defaults()[action][field])
				bindings[action][field] = fallback if not taken.has(fallback) else (KEY_NONE if field == "key" else -1)
				code = int(bindings[action][field])
			taken[code] = true
	return bindings


# =============================================================================
# FILE
# =============================================================================

func load_settings() -> void:
	_values = DEFAULTS.duplicate()
	_bindings = ControlsMap.defaults()
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
	_bindings = _clean_bindings((parsed as Dictionary).get("bindings"))


func save_settings() -> bool:
	_save_in = -1.0
	if not persist:
		return false
	var file := FileAccess.open(settings_path, FileAccess.WRITE)
	if file == null:
		push_warning("[GameSettings] Could not write %s" % settings_path)
		return false
	var data := _values.duplicate()
	data["bindings"] = _bindings
	file.store_string(JSON.stringify(data, "\t"))
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
		if key.physical_keycode != KEY_NONE:
			return ControlsMap.key_label(key.physical_keycode)
		if key.keycode != KEY_NONE:
			return OS.get_keycode_string(key.keycode)
	return ""
