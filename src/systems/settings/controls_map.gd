class_name ControlsMap
extends RefCounted
## The game's controls: which actions there are, the key and the gamepad
## button each starts with, and what to call them on screen.
##
## The defaults here are also in project.godot's [input] section (so the
## actions exist before anything is loaded); GameSettings holds the player's
## own bindings and puts them into the InputMap with apply().
##
## Keys and buttons can be rebound (Settings > Controls). The sticks cannot:
## the left stick moves (alongside the move keys), the right stick looks.
##
## Text that names a control uses a placeholder, so it follows the bindings
## and the device in the player's hands:
##   ControlsMap.fill("{slide_initiate} self-arrest")   # "Space self-arrest", or "A self-arrest"
##   ControlsMap.prompt("crampons_toggle")              # "F", or "B"
## Besides every action, there are {move}, {look}, {lean} and {steer}.

enum Device { KEYBOARD, GAMEPAD }

## How a gamepad's buttons are named
enum PadStyle { XBOX, PLAYSTATION }

## Every action that can be rebound, in the order a player meets them:
## [action, what it does, default key (physical), default gamepad button (-1: none)]
const ACTIONS := [
	["move_forward", "Move forward", KEY_W, -1],
	["move_back", "Move back; brake a glissade", KEY_S, -1],
	["move_left", "Move left", KEY_A, -1],
	["move_right", "Move right", KEY_D, -1],
	["lean_left", "Lean left in a glissade", KEY_Q, JOY_BUTTON_LEFT_SHOULDER],
	["lean_right", "Lean right in a glissade", KEY_E, JOY_BUTTON_RIGHT_SHOULDER],
	["slide_initiate", "Glissade; self-arrest; airbag; dig", KEY_SPACE, JOY_BUTTON_A],
	["rope_deploy", "Rope: anchor, rappel, unclip", KEY_R, JOY_BUTTON_X],
	["crampons_toggle", "Crampons on or off", KEY_F, JOY_BUTTON_B],
	["skis_toggle", "Skis or splitboard on or off", KEY_T, JOY_BUTTON_DPAD_DOWN],
	["probe", "Probe the snow ahead", KEY_G, JOY_BUTTON_DPAD_LEFT],
	["snow_pit", "Dig a snow pit", KEY_V, JOY_BUTTON_DPAD_RIGHT],
	["check_self", "Check yourself", KEY_C, JOY_BUTTON_DPAD_UP],
	["open_map", "Map", KEY_M, JOY_BUTTON_Y],
	["drone_view", "Watch through the film crew's drone", KEY_B, JOY_BUTTON_BACK],
	["pause", "Pause", KEY_ESCAPE, JOY_BUTTON_START],
	["toggle_hints", "Show or hide the control hints", KEY_H, JOY_BUTTON_LEFT_STICK],
]

## The left stick moves: action -> [axis, direction]
const STICK_MOVES := {
	"move_left": [JOY_AXIS_LEFT_X, -1.0],
	"move_right": [JOY_AXIS_LEFT_X, 1.0],
	"move_forward": [JOY_AXIS_LEFT_Y, -1.0],
	"move_back": [JOY_AXIS_LEFT_Y, 1.0],
}

## The right stick looks: action -> [axis, direction]
const STICK_LOOKS := {
	"look_left": [JOY_AXIS_RIGHT_X, -1.0],
	"look_right": [JOY_AXIS_RIGHT_X, 1.0],
	"look_up": [JOY_AXIS_RIGHT_Y, -1.0],
	"look_down": [JOY_AXIS_RIGHT_Y, 1.0],
}

## What a move action is called when it is the stick doing it
const STICK_MOVE_LABELS := {
	"move_forward": "Stick up",
	"move_back": "Stick down",
	"move_left": "Stick left",
	"move_right": "Stick right",
}

const ACTION_DEADZONE := 0.5
const LOOK_DEADZONE := 0.2

## The menus on a gamepad. Godot's own menu actions come with keys only (and
## the D-pad for moving the focus): A chooses, B goes back, and the left stick
## moves the focus as the D-pad does. These are not rebound.
const MENU_BUTTONS := {
	"ui_accept": JOY_BUTTON_A,
	"ui_cancel": JOY_BUTTON_B,
	"ui_up": JOY_BUTTON_DPAD_UP,
	"ui_down": JOY_BUTTON_DPAD_DOWN,
	"ui_left": JOY_BUTTON_DPAD_LEFT,
	"ui_right": JOY_BUTTON_DPAD_RIGHT,
}
const MENU_STICK := {
	"ui_up": [JOY_AXIS_LEFT_Y, -1.0],
	"ui_down": [JOY_AXIS_LEFT_Y, 1.0],
	"ui_left": [JOY_AXIS_LEFT_X, -1.0],
	"ui_right": [JOY_AXIS_LEFT_X, 1.0],
}

## Button names by JoyButton index
const PAD_NAMES := {
	PadStyle.XBOX: ["A", "B", "X", "Y", "Back", "Guide", "Start", "L3", "R3", "LB", "RB",
		"D-pad up", "D-pad down", "D-pad left", "D-pad right"],
	PadStyle.PLAYSTATION: ["Cross", "Circle", "Square", "Triangle", "Share", "PS", "Options", "L3", "R3", "L1", "R1",
		"D-pad up", "D-pad down", "D-pad left", "D-pad right"],
}

## Buttons a player can bind (JoyButton indices)
const MAX_PAD_BUTTON := JOY_BUTTON_DPAD_RIGHT


# =============================================================================
# BINDINGS
# =============================================================================

## The bindings of a fresh install: action -> {"key": physical keycode, "pad": button or -1}
static func defaults() -> Dictionary:
	var bindings := {}
	for row in ACTIONS:
		bindings[row[0]] = {"key": int(row[2]), "pad": int(row[3])}
	return bindings


## Whether an action is one the player can rebind
static func has_action(action: String) -> bool:
	for row in ACTIONS:
		if row[0] == action:
			return true
	return false


## What an action does, in a few words ("" when it is not one of ours)
static func describe(action: String) -> String:
	for row in ACTIONS:
		if row[0] == action:
			return row[1]
	return ""


## Put bindings into the InputMap: each action gets its key, its gamepad
## button and (the move actions) its half of the left stick; the right stick
## looks. Actions missing from the dictionary get their defaults.
static func apply(bindings: Dictionary) -> void:
	for row in ACTIONS:
		var action: String = row[0]
		if not InputMap.has_action(action):
			InputMap.add_action(action, ACTION_DEADZONE)
		InputMap.action_erase_events(action)
		var bound: Dictionary = bindings.get(action, {})
		var key := int(bound.get("key", row[2]))
		if key != KEY_NONE:
			var key_event := InputEventKey.new()
			key_event.physical_keycode = key as Key
			InputMap.action_add_event(action, key_event)
		var pad := int(bound.get("pad", row[3]))
		if pad >= 0 and pad <= MAX_PAD_BUTTON:
			var button_event := InputEventJoypadButton.new()
			button_event.device = -1
			button_event.button_index = pad as JoyButton
			InputMap.action_add_event(action, button_event)
		if STICK_MOVES.has(action):
			InputMap.action_add_event(action, _stick_event(STICK_MOVES[action]))
	for action in STICK_LOOKS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, LOOK_DEADZONE)
		InputMap.action_erase_events(action)
		InputMap.action_add_event(action, _stick_event(STICK_LOOKS[action]))
	_add_menu_events()


## Give the menu actions their gamepad button and stick, where they lack them
static func _add_menu_events() -> void:
	for action in MENU_BUTTONS:
		if not InputMap.has_action(action):
			continue
		var button_event := InputEventJoypadButton.new()
		button_event.device = -1
		button_event.button_index = int(MENU_BUTTONS[action]) as JoyButton
		if not InputMap.action_has_event(action, button_event):
			InputMap.action_add_event(action, button_event)
	for action in MENU_STICK:
		if not InputMap.has_action(action):
			continue
		var stick_event := _stick_event(MENU_STICK[action])
		if not InputMap.action_has_event(action, stick_event):
			InputMap.action_add_event(action, stick_event)


static func _stick_event(half: Array) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.device = -1
	event.axis = int(half[0]) as JoyAxis
	event.axis_value = float(half[1])
	return event


# =============================================================================
# NAMES
# =============================================================================

## A key as the player's keyboard labels it ("W", "Space", "Esc")
static func key_label(physical_keycode: int) -> String:
	if physical_keycode == KEY_NONE:
		return ""
	var code := physical_keycode
	# With no keyboard to ask (a headless run) the key's own name will do
	if DisplayServer.get_name() != "headless":
		var mapped := DisplayServer.keyboard_get_keycode_from_physical(physical_keycode as Key)
		if mapped != KEY_NONE:
			code = mapped
	if code == KEY_ESCAPE:
		return "Esc"
	return OS.get_keycode_string(code as Key)


## A gamepad button by name ("A", "LB"; "Cross", "L1" on a PlayStation pad)
static func pad_label(button: int, style: int = PadStyle.XBOX) -> String:
	var names: Array = PAD_NAMES.get(style, PAD_NAMES[PadStyle.XBOX])
	if button < 0 or button >= names.size():
		return ""
	return names[button]


## How a connected gamepad names its buttons, from what it calls itself
static func pad_style_of(joy_name: String) -> int:
	var lower := joy_name.to_lower()
	for word in ["ps3", "ps4", "ps5", "playstation", "dualshock", "dualsense", "sony"]:
		if lower.contains(word):
			return PadStyle.PLAYSTATION
	return PadStyle.XBOX


## What to call an action's control on a device, from a set of bindings
## ("" when the action has none there)
static func label_for(action: String, device: int, bindings: Dictionary, style: int = PadStyle.XBOX) -> String:
	var bound: Dictionary = bindings.get(action, defaults().get(action, {}))
	if device == Device.GAMEPAD:
		var pad := int(bound.get("pad", -1))
		if pad >= 0:
			return pad_label(pad, style)
		return STICK_MOVE_LABELS.get(action, "")
	return key_label(int(bound.get("key", KEY_NONE)))


## What to call an action's control right now: the player's own binding, on
## the device they last touched
static func prompt(action: String) -> String:
	var settings := _settings()
	if settings == null:
		return label_for(action, Device.KEYBOARD, defaults())
	return label_for(action, int(settings.get("device")), settings.call("get_bindings"), int(settings.get("pad_style")))


## Replace every {placeholder} in a text with the control it names
static func fill(text: String) -> String:
	if not text.contains("{"):
		return text
	var settings := _settings()
	var device: int = int(settings.get("device")) if settings != null else Device.KEYBOARD
	var pattern := RegEx.new()
	pattern.compile("\\{([a-z_]+)\\}")
	var out := text
	for found in pattern.search_all(text):
		var name := found.get_string(1)
		var label := ""
		match name:
			"move":
				label = "Left stick" if device == Device.GAMEPAD else _joined(["move_forward", "move_left", "move_back", "move_right"])
			"look":
				label = "Right stick" if device == Device.GAMEPAD else "Mouse"
			"lean":
				label = "%s/%s" % [prompt("lean_left"), prompt("lean_right")]
			"steer":
				label = "Left stick" if device == Device.GAMEPAD else "%s/%s" % [prompt("move_left"), prompt("move_right")]
			_:
				if not has_action(name):
					continue
				label = prompt(name)
		out = out.replace("{%s}" % name, label)
	return out


## Several keys as one label: "WASD" when each is a single letter, else "Up/Left/Down/Right"
static func _joined(actions: Array) -> String:
	var labels: Array[String] = []
	var short := true
	for action in actions:
		var label := prompt(action)
		labels.append(label)
		if label.length() != 1:
			short = false
	return "".join(labels) if short else "/".join(labels)


## The settings service, when the game has one up (GameSettings; untyped, so
## that this script does not depend on the one that depends on it)
static func _settings() -> Object:
	var settings: Object = ServiceLocator.get_service("GameSettings")
	return settings if is_instance_valid(settings) else null
