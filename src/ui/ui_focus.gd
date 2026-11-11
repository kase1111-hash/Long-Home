class_name UIFocus
extends RefCounted
## Keyboard and gamepad access to the menus.
##
## Godot moves the focus between buttons, sliders and lists by itself (arrows
## or the D-pad, Enter or A), but only once something has it. A screen hands
## the focus to its main control when it comes up:
##   UIFocus.take(confirm_button)
## and screens with pages turn them with LB/RB or Page Up/Page Down:
##   var step := UIFocus.page_step(event)   # -1, 0 or +1


## Give a control the focus once it is on screen (after this frame, so that a
## screen being shown has been laid out and made visible first)
static func take(control: Control) -> void:
	if control == null or control.focus_mode == Control.FOCUS_NONE:
		return
	(func() -> void:
		if is_instance_valid(control) and control.is_visible_in_tree() and control.is_inside_tree():
			control.grab_focus()).call_deferred()


## Whether an input event asks for the previous (-1) or the next (+1) page:
## the shoulder buttons of a gamepad, or Page Up and Page Down
static func page_step(event: InputEvent) -> int:
	if event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		match (event as InputEventJoypadButton).button_index:
			JOY_BUTTON_LEFT_SHOULDER:
				return -1
			JOY_BUTTON_RIGHT_SHOULDER:
				return 1
	elif event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		match (event as InputEventKey).keycode:
			KEY_PAGEUP:
				return -1
			KEY_PAGEDOWN:
				return 1
	return 0


## Make a panel that is clicked with the mouse reachable without one: it can
## take the focus, shows that it has it (highlight: called with true/false),
## and Enter or A does what a click does (chosen)
static func make_choosable(panel: Control, chosen: Callable, highlight: Callable = Callable()) -> void:
	panel.focus_mode = Control.FOCUS_ALL
	panel.gui_input.connect(func(event: InputEvent) -> void:
		if event.is_action_pressed("ui_accept"):
			chosen.call()
			panel.accept_event())
	if highlight.is_valid():
		panel.focus_entered.connect(highlight.bind(true))
		panel.focus_exited.connect(highlight.bind(false))
