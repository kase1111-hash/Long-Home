class_name OBSIntegration
extends Node
## OBS WebSocket integration for streaming
## Connects to OBS via obs-websocket protocol
##
## Design Philosophy:
## - Non-intrusive: Game plays normally if OBS unavailable
## - Automatic markers: Key moments bookmarked for editing
## - Scene suggestions: Game hints at scene changes, OBS decides

# =============================================================================
# SIGNALS
# =============================================================================

signal connected()
signal disconnected()
signal connection_failed(reason: String)
signal stream_started()
signal stream_stopped()
signal recording_started()
signal recording_stopped()
signal replay_buffer_saved(path: String)
signal scene_changed(scene_name: String)
signal marker_created(name: String, time: float)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Connection")
## OBS WebSocket host
@export var host: String = "127.0.0.1"
## OBS WebSocket port
@export var port: int = 4455
## Connection password (empty for no auth)
@export var password: String = ""
## Auto-reconnect on disconnect
@export var auto_reconnect: bool = true
## Reconnect delay in seconds
@export var reconnect_delay: float = 5.0

@export_group("Automatic Markers")
## Create markers for slides
@export var marker_slides: bool = true
## Create markers for rope deployments
@export var marker_rope: bool = true
## Create markers for injuries
@export var marker_injuries: bool = true
## Create markers for decisions
@export var marker_decisions: bool = false
## Create markers for weather changes
@export var marker_weather: bool = true

@export_group("Scene Suggestions")
## Suggest scene changes to OBS
@export var enable_scene_hints: bool = true
## Scene for gameplay
@export var scene_gameplay: String = "Gameplay"
## Scene for death/ending
@export var scene_ending: String = "Ending"
## Scene for pause/menu
@export var scene_menu: String = "Menu"
## Scene for post-game stats
@export var scene_stats: String = "Stats"

# =============================================================================
# STATE
# =============================================================================

## WebSocket client
var _ws: WebSocketPeer

## Connection state
var is_connected: bool = false

## Is currently streaming
var is_streaming: bool = false

## Is currently recording
var is_recording: bool = false

## Has replay buffer
var has_replay_buffer: bool = false

## Current scene
var current_scene: String = ""

## Message ID counter
var _message_id: int = 0

## Pending requests
var _pending_requests: Dictionary = {}

## Authentication challenge
var _auth_challenge: String = ""
var _auth_salt: String = ""

## Reconnect timer
var _reconnect_timer: Timer

## Time of last marker (prevent spam)
var _last_marker_time: float = 0.0
const MARKER_COOLDOWN := 2.0

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("OBSIntegration", self)

	_setup_reconnect_timer()
	_connect_game_events()

	# Attempt initial connection
	call_deferred("connect_to_obs")

	print("[OBSIntegration] Initialized")


func _process(_delta: float) -> void:
	if _ws == null:
		return

	_ws.poll()

	var state := _ws.get_ready_state()
	match state:
		WebSocketPeer.STATE_OPEN:
			while _ws.get_available_packet_count() > 0:
				_handle_message(_ws.get_packet().get_string_from_utf8())
		WebSocketPeer.STATE_CLOSED:
			if is_connected:
				is_connected = false
				disconnected.emit()
				print("[OBSIntegration] Connection closed")
				if auto_reconnect:
					_schedule_reconnect()


func _setup_reconnect_timer() -> void:
	_reconnect_timer = Timer.new()
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_on_reconnect_timeout)
	add_child(_reconnect_timer)


func _connect_game_events() -> void:
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.run_started.connect(_on_run_started)
	EventBus.run_ended.connect(_on_run_ended)
	EventBus.slide_started.connect(_on_slide_started)
	EventBus.slide_ended.connect(_on_slide_ended)
	EventBus.rope_deployment_started.connect(_on_rope_deployment)
	EventBus.injury_occurred.connect(_on_injury)
	EventBus.weather_changed.connect(_on_weather_changed)
	EventBus.fatal_event_started.connect(_on_fatal_event)
	EventBus.decision_recorded.connect(_on_decision)


# =============================================================================
# CONNECTION
# =============================================================================

func connect_to_obs() -> void:
	if is_connected:
		return

	_ws = WebSocketPeer.new()
	var url := "ws://%s:%d" % [host, port]
	var err := _ws.connect_to_url(url)

	if err != OK:
		connection_failed.emit("Failed to initiate connection")
		print("[OBSIntegration] Failed to connect: %s" % error_string(err))
		if auto_reconnect:
			_schedule_reconnect()


func disconnect_from_obs() -> void:
	if _ws:
		_ws.close()
		_ws = null
	is_connected = false
	disconnected.emit()


func _schedule_reconnect() -> void:
	if not _reconnect_timer.is_stopped():
		return
	_reconnect_timer.start(reconnect_delay)


func _on_reconnect_timeout() -> void:
	print("[OBSIntegration] Attempting reconnect...")
	connect_to_obs()


# =============================================================================
# MESSAGE HANDLING
# =============================================================================

func _handle_message(text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		return

	var data: Dictionary = json.data
	var op: int = data.get("op", -1)

	match op:
		0:  # Hello
			_handle_hello(data.get("d", {}))
		2:  # Identified
			_handle_identified()
		5:  # Event
			_handle_event(data.get("d", {}))
		7:  # RequestResponse
			_handle_response(data.get("d", {}))


func _handle_hello(data: Dictionary) -> void:
	var auth_data: Dictionary = data.get("authentication", {})
	if not auth_data.is_empty():
		_auth_challenge = auth_data.get("challenge", "")
		_auth_salt = auth_data.get("salt", "")

	# Send Identify
	_send_identify()


func _send_identify() -> void:
	var identify_data := {
		"rpcVersion": 1
	}

	if not password.is_empty() and not _auth_challenge.is_empty():
		identify_data["authentication"] = _generate_auth_string()

	_send_message(1, identify_data)


func _generate_auth_string() -> String:
	# OBS WebSocket authentication
	# auth = base64(sha256(base64(sha256(password + salt)) + challenge))
	var pass_salt := password + _auth_salt
	var pass_hash := pass_salt.sha256_buffer()
	var pass_base64 := Marshalls.raw_to_base64(pass_hash)
	var challenge_str := pass_base64 + _auth_challenge
	var final_hash := challenge_str.sha256_buffer()
	return Marshalls.raw_to_base64(final_hash)


func _handle_identified() -> void:
	is_connected = true
	connected.emit()
	print("[OBSIntegration] Connected to OBS")

	# Request initial state
	_request_status()


func _handle_event(data: Dictionary) -> void:
	var event_type: String = data.get("eventType", "")
	var event_data: Dictionary = data.get("eventData", {})

	match event_type:
		"StreamStateChanged":
			var output_active: bool = event_data.get("outputActive", false)
			if output_active and not is_streaming:
				is_streaming = true
				stream_started.emit()
			elif not output_active and is_streaming:
				is_streaming = false
				stream_stopped.emit()

		"RecordStateChanged":
			var output_active: bool = event_data.get("outputActive", false)
			if output_active and not is_recording:
				is_recording = true
				recording_started.emit()
			elif not output_active and is_recording:
				is_recording = false
				recording_stopped.emit()

		"ReplayBufferSaved":
			var saved_path: String = event_data.get("savedReplayPath", "")
			replay_buffer_saved.emit(saved_path)

		"CurrentProgramSceneChanged":
			current_scene = event_data.get("sceneName", "")
			scene_changed.emit(current_scene)


func _handle_response(data: Dictionary) -> void:
	var request_id: String = data.get("requestId", "")
	var response_data: Dictionary = data.get("responseData", {})

	if _pending_requests.has(request_id):
		var callback: Callable = _pending_requests[request_id]
		_pending_requests.erase(request_id)
		callback.call(response_data)


func _request_status() -> void:
	# Get stream status
	_send_request("GetStreamStatus", {}, func(data: Dictionary):
		is_streaming = data.get("outputActive", false)
		if is_streaming:
			stream_started.emit()
	)

	# Get record status
	_send_request("GetRecordStatus", {}, func(data: Dictionary):
		is_recording = data.get("outputActive", false)
		if is_recording:
			recording_started.emit()
	)

	# Get replay buffer status
	_send_request("GetReplayBufferStatus", {}, func(data: Dictionary):
		has_replay_buffer = data.get("outputActive", false)
	)

	# Get current scene
	_send_request("GetCurrentProgramScene", {}, func(data: Dictionary):
		current_scene = data.get("currentProgramSceneName", "")
	)


func _send_message(op: int, data: Dictionary) -> void:
	if _ws == null:
		return

	var message := {
		"op": op,
		"d": data
	}

	_ws.send_text(JSON.stringify(message))


func _send_request(request_type: String, request_data: Dictionary, callback: Callable = Callable()) -> void:
	if not is_connected:
		return

	_message_id += 1
	var request_id := str(_message_id)

	var data := {
		"requestType": request_type,
		"requestId": request_id,
		"requestData": request_data
	}

	if callback.is_valid():
		_pending_requests[request_id] = callback

	_send_message(6, data)


# =============================================================================
# MARKERS
# =============================================================================

func create_marker(name: String) -> void:
	## Create a marker/chapter in the recording
	if not is_connected:
		return

	if not is_recording and not is_streaming:
		return

	# Prevent marker spam
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_marker_time < MARKER_COOLDOWN:
		return
	_last_marker_time = now

	# Use source hotkey or create chapter marker
	# OBS doesn't have direct marker API, but we can use hotkeys
	# Alternative: Create a text source that we update

	# For now, emit signal for external handling
	marker_created.emit(name, now)
	print("[OBSIntegration] Marker: %s" % name)


func save_replay_buffer() -> void:
	## Save the replay buffer (if enabled)
	if not is_connected or not has_replay_buffer:
		return

	_send_request("SaveReplayBuffer", {})


# =============================================================================
# SCENE CONTROL
# =============================================================================

func suggest_scene(scene_name: String) -> void:
	## Suggest a scene change (streamer can override)
	if not enable_scene_hints:
		return

	if not is_connected:
		return

	if scene_name == current_scene:
		return

	_send_request("SetCurrentProgramScene", {
		"sceneName": scene_name
	})


func get_available_scenes(callback: Callable) -> void:
	## Get list of available scenes
	if not is_connected:
		callback.call([])
		return

	_send_request("GetSceneList", {}, func(data: Dictionary):
		var scenes: Array = data.get("scenes", [])
		var scene_names: Array[String] = []
		for scene in scenes:
			scene_names.append(scene.get("sceneName", ""))
		callback.call(scene_names)
	)


# =============================================================================
# GAME EVENT HANDLERS
# =============================================================================

func _on_game_state_changed(_old: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	match new_state:
		GameEnums.GameState.DESCENT:
			suggest_scene(scene_gameplay)
			create_marker("Run Start")
		GameEnums.GameState.POST_GAME:
			suggest_scene(scene_stats)
		GameEnums.GameState.PAUSED:
			suggest_scene(scene_menu)


func _on_run_started(_context: RunContext) -> void:
	create_marker("Descent Begin")


func _on_run_ended(_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	match outcome:
		GameEnums.ResolutionType.FATALITY:
			suggest_scene(scene_ending)
			create_marker("Run End - Fatal")
		GameEnums.ResolutionType.CLEAN_RETURN:
			create_marker("Run End - Success")
		_:
			create_marker("Run End")


func _on_slide_started(entry_speed: float, _slope_angle: float) -> void:
	if not marker_slides:
		return

	if entry_speed > 3.0:
		create_marker("Slide - Fast Entry")
	else:
		create_marker("Slide Start")


func _on_slide_ended(outcome: GameEnums.SlideOutcome, _final_speed: float) -> void:
	if not marker_slides:
		return

	match outcome:
		GameEnums.SlideOutcome.CLEAN_STOP:
			create_marker("Slide - Clean Stop")
		GameEnums.SlideOutcome.TUMBLE_STOP:
			create_marker("Slide - Tumble")
		GameEnums.SlideOutcome.TERRAIN_CATCH:
			create_marker("Slide - Terrain Catch")


func _on_rope_deployment(anchor_quality: GameEnums.AnchorQuality) -> void:
	if not marker_rope:
		return

	match anchor_quality:
		GameEnums.AnchorQuality.MARGINAL, GameEnums.AnchorQuality.POOR:
			create_marker("Rope - Risky Anchor")
		_:
			create_marker("Rope Deploy")


func _on_injury(injury: Injury) -> void:
	if not marker_injuries:
		return

	if injury.severity > 0.5:
		create_marker("Injury - Severe")
	else:
		create_marker("Injury")


func _on_weather_changed(_old: GameEnums.WeatherState, new_weather: GameEnums.WeatherState) -> void:
	if not marker_weather:
		return

	match new_weather:
		GameEnums.WeatherState.STORM:
			create_marker("Storm Arrives")
		GameEnums.WeatherState.WHITEOUT:
			create_marker("Whiteout Conditions")


func _on_fatal_event(_phase: GameEnums.FatalPhase) -> void:
	suggest_scene(scene_ending)
	# Don't create marker for fatal - handled by run_ended


func _on_decision(decision_type: String, _context: Dictionary) -> void:
	if not marker_decisions:
		return

	create_marker("Decision: %s" % decision_type.capitalize())


# =============================================================================
# SETTINGS
# =============================================================================

func get_settings() -> Dictionary:
	return {
		"host": host,
		"port": port,
		"auto_reconnect": auto_reconnect,
		"marker_slides": marker_slides,
		"marker_rope": marker_rope,
		"marker_injuries": marker_injuries,
		"marker_decisions": marker_decisions,
		"marker_weather": marker_weather,
		"enable_scene_hints": enable_scene_hints,
		"scene_gameplay": scene_gameplay,
		"scene_ending": scene_ending,
		"scene_menu": scene_menu,
		"scene_stats": scene_stats
	}


func apply_settings(settings: Dictionary) -> void:
	host = settings.get("host", host)
	port = settings.get("port", port)
	auto_reconnect = settings.get("auto_reconnect", auto_reconnect)
	marker_slides = settings.get("marker_slides", marker_slides)
	marker_rope = settings.get("marker_rope", marker_rope)
	marker_injuries = settings.get("marker_injuries", marker_injuries)
	marker_decisions = settings.get("marker_decisions", marker_decisions)
	marker_weather = settings.get("marker_weather", marker_weather)
	enable_scene_hints = settings.get("enable_scene_hints", enable_scene_hints)
	scene_gameplay = settings.get("scene_gameplay", scene_gameplay)
	scene_ending = settings.get("scene_ending", scene_ending)
	scene_menu = settings.get("scene_menu", scene_menu)
	scene_stats = settings.get("scene_stats", scene_stats)


# =============================================================================
# STATUS
# =============================================================================

func get_status() -> Dictionary:
	return {
		"connected": is_connected,
		"streaming": is_streaming,
		"recording": is_recording,
		"replay_buffer": has_replay_buffer,
		"current_scene": current_scene
	}
