class_name HazardAudioManager
extends Node
## The sounds of the mountain trying to kill you: avalanches and crevasses
##
## Design Philosophy:
## - The warnings are quiet and close: a whumpf underfoot, cracks running out
## - An avalanche is heard where it is: the release is a crack at the crown
##   and the roar travels down the slope with the debris
## - Caught and buried is heard from inside: the world goes dark and muffled
##   and what is left is the climber's own heart and breath
## - A crevasse is a different room: the wind stays above, the ice answers back
##
## AvalancheSystem and CrevasseSystem say what happened (signals); this turns
## it into sound and tells AudioService how the world should be heard.

# =============================================================================
# CONFIGURATION
# =============================================================================

## An avalanche closer than this is heard breaking; further off it is a
## distant roar
const NEAR_DISTANCE := 220.0

## How far the roar of a size 1 avalanche carries at full level (m); each
## size up carries half as far again
const ROAR_REACH := 28.0

## Front speed (m/s) at which the roar is at full level
const ROAR_FULL_SPEED := 18.0

## Level of a size 0 avalanche's roar (dB); each size up is 2 dB more
const ROAR_TRIM := -10.0

## How muffled the world is when carried along, buried to the chest, and
## buried with the head under (0-1)
const MUFFLE_CAUGHT := 0.55
const MUFFLE_PARTIAL := 0.35
const MUFFLE_BURIED := 1.0

## Seconds between groans of the ice while down a crevasse
const GROAN_GAP := Vector2(9.0, 24.0)

# =============================================================================
# STATE
# =============================================================================

var _service: AudioService
var _library: SoundLibrary
var _avalanches: AvalancheSystem
var _crevasses: CrevasseSystem

## Flow id -> {"flow": AvalancheFlow, "fader": AudioFader}
var _roars: Dictionary = {}

## Carried in the flow, and down a crevasse: looping beds heard from inside
var _inside: AudioFader
var _slot: AudioFader

var _caught: bool = false
var _buried: bool = false
var _in_crevasse: bool = false
var _next_groan: float = 12.0


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_library = ServiceLocator.get_service("SoundLibrary") as SoundLibrary
	_inside = _make_bed("avalanche_inside_loop", -9.0, 0.3, 0.8)
	_slot = _make_bed("crevasse_ambience_loop", -3.0, 1.5, 2.0)

	ServiceLocator.get_service_async("AudioService", func(service): _service = service as AudioService)
	ServiceLocator.get_service_async("AvalancheSystem", _on_avalanche_system_ready)
	ServiceLocator.get_service_async("CrevasseSystem", _on_crevasse_system_ready)
	EventBus.decision_recorded.connect(_on_decision)
	print("[HazardAudioManager] Initialized")


func _make_bed(sound_id: String, trim_db: float, attack: float, release: float) -> AudioFader:
	var player := AudioStreamPlayer.new()
	# On the climber's bus: these are heard from inside, so the muffling of
	# the outside world must not reach them
	player.bus = AudioService.BUS_PLAYER
	if _library != null and _library.has_sound(sound_id):
		player.stream = _library.get_stream(sound_id)
	add_child(player)
	return AudioFader.new(player, trim_db, attack, release)


func _on_avalanche_system_ready(service: Object) -> void:
	_avalanches = service as AvalancheSystem
	if _avalanches == null:
		return
	_avalanches.avalanche_released.connect(_on_avalanche_released)
	_avalanches.avalanche_stopped.connect(_on_avalanche_stopped)
	_avalanches.warning_sign.connect(_on_warning_sign)
	_avalanches.climber_caught.connect(_on_climber_caught)
	_avalanches.climber_buried.connect(_on_climber_buried)
	_avalanches.climber_freed.connect(_on_climber_freed)


func _on_crevasse_system_ready(service: Object) -> void:
	_crevasses = service as CrevasseSystem
	if _crevasses == null:
		return
	_crevasses.crevasse_fall.connect(_on_crevasse_fall)
	_crevasses.climbed_out.connect(_on_climbed_out)


## Forget every hazard (the run ended, or the fatal sequence has taken over)
func reset() -> void:
	for id in _roars.keys():
		_drop_roar(int(id))
	_inside.cut()
	_slot.cut()
	_caught = false
	_buried = false
	_in_crevasse = false
	if _service != null:
		_service.set_muffle(0.0)
		_service.set_cavern(0.0)
	_set_tension(0.0)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	_update_roars(delta)
	_update_crevasse(delta)
	_inside.level = 1.0 if _caught and not _buried else 0.0
	_inside.update(delta)
	_slot.level = 1.0 if _in_crevasse else 0.0
	_slot.update(delta)


## Each running avalanche roars from its front, louder the faster it runs
func _update_roars(delta: float) -> void:
	for id in _roars.keys():
		var entry: Dictionary = _roars[id]
		var flow: AvalancheFlow = entry["flow"]
		var fader: AudioFader = entry["fader"]
		var voice := fader.player as AudioStreamPlayer3D
		if flow.finished:
			fader.level = 0.0
		else:
			var front: Dictionary = flow.front()
			var velocity: Vector3 = front["velocity"]
			var where: Vector3 = front["position"]
			# With nothing moving the front is the flow's lowest point, which
			# is not a place at all until something has run
			if is_finite(where.y):
				voice.global_position = where
			var moving := clampf(velocity.length() / ROAR_FULL_SPEED, 0.0, 1.0)
			fader.level = 0.25 + 0.75 * moving
			fader.pitch = 0.8 + 0.3 * moving
		fader.update(delta)
		if flow.finished and not fader.is_audible():
			_drop_roar(int(id))


func _drop_roar(id: int) -> void:
	if not _roars.has(id):
		return
	var entry: Dictionary = _roars[id]
	var fader: AudioFader = entry["fader"]
	fader.cut()
	if is_instance_valid(fader.player):
		fader.player.queue_free()
	_roars.erase(id)


## Down a crevasse: the reverb, the dripping, and now and then the ice
func _update_crevasse(delta: float) -> void:
	var inside := _crevasses != null and is_instance_valid(_crevasses) and _crevasses.is_in_crevasse()
	if inside != _in_crevasse:
		_in_crevasse = inside
		if _service != null:
			_service.set_cavern(1.0 if inside else 0.0)
		_next_groan = AudioService.roll_range(4.0, 10.0)
	if not _in_crevasse:
		return
	_next_groan -= delta
	if _next_groan <= 0.0:
		_next_groan = AudioService.roll_range(GROAN_GAP.x, GROAN_GAP.y)
		_play("ice_groan", -6.0)


# =============================================================================
# PLAYBACK
# =============================================================================

func _play(id: String, volume_db: float = 0.0, pitch: float = -1.0, bus: String = AudioService.BUS_EFFECTS) -> void:
	if _service != null:
		_service.play(id, volume_db, AudioService.vary(0.05) if pitch < 0.0 else pitch, bus)


func _play_at(id: String, position: Vector3, volume_db: float, reach: float) -> void:
	if _service != null:
		_service.play_at(id, position, volume_db, AudioService.vary(0.05), reach)


func _set_tension(level: float) -> void:
	if _service != null and _service.player_audio != null:
		_service.player_audio.set_tension(level)


func _startle(amount: float) -> void:
	if _service != null and _service.player_audio != null:
		_service.player_audio.startle(amount)


func _listener_position() -> Vector3:
	var player := ServiceLocator.get_service("PlayerController") as PlayerController
	return player.global_position if player != null else Vector3.ZERO


# =============================================================================
# AVALANCHES
# =============================================================================

func _on_warning_sign(kind: String) -> void:
	# Underfoot, so not placed in the world: it is everywhere at once
	if kind == "cracks":
		_play("snow_crack", -7.0)
	else:
		_play("whumpf", -6.0)
	_startle(0.6)


func _on_avalanche_released(flow: AvalancheFlow) -> void:
	var distance := _listener_position().distance_to(flow.origin)
	var reach := ROAR_REACH * pow(1.5, float(flow.size - 1))

	if flow.kind == AvalancheFlow.Kind.ICE:
		# A serac: the crack carries a long way
		_play_at("serac_fall", flow.origin, -4.0, 140.0)
	elif distance < NEAR_DISTANCE:
		if flow.kind == AvalancheFlow.Kind.SLAB:
			_play_at("slab_release", flow.origin, -6.0, reach * 2.0)
		else:
			# Loose or wet snow goes without a report: it just starts to run
			_play_at("snow_settle", flow.origin, -4.0, reach)
		if distance < 60.0:
			_startle(0.9)
	else:
		_play_at("avalanche_distant", flow.origin, -3.0, 320.0)

	_start_roar(flow, reach)


func _start_roar(flow: AvalancheFlow, reach: float) -> void:
	if _library == null or not _library.has_sound("avalanche_roar_loop") or _roars.has(flow.id):
		return
	var voice := AudioStreamPlayer3D.new()
	voice.bus = AudioService.BUS_EFFECTS
	voice.stream = _library.get_stream("avalanche_roar_loop")
	voice.unit_size = reach
	voice.max_distance = 0.0
	# Inside its reach it is as loud as it gets: no closer, no louder
	voice.max_db = 0.0
	# A big sound is still broad a long way off: let the highs through further
	voice.attenuation_filter_cutoff_hz = 2400.0
	voice.attenuation_filter_db = -18.0
	add_child(voice)
	voice.global_position = flow.origin
	var fader := AudioFader.new(voice, ROAR_TRIM + 2.0 * float(flow.size), 0.5, 1.3)
	_roars[flow.id] = {"flow": flow, "fader": fader}


func _on_avalanche_stopped(flow: AvalancheFlow) -> void:
	# The debris setting where it came to rest (a flow that never ran has no
	# lowest point: its crown will do)
	var where := flow.lowest if is_finite(flow.lowest.y) else flow.origin
	_play_at("debris_settle", where, -2.0, ROAR_REACH * 1.5)


func _on_climber_caught(_flow: AvalancheFlow) -> void:
	_caught = true
	_buried = false
	if _service != null:
		_service.set_muffle(MUFFLE_CAUGHT)
	_set_tension(1.0)
	_startle(1.0)


func _on_climber_buried(depth: float) -> void:
	_buried = true
	var head_under := depth >= AvalancheSystem.HEAD_UNDER_DEPTH
	if _service != null:
		_service.set_muffle(MUFFLE_BURIED if head_under else MUFFLE_PARTIAL)
	_set_tension(1.0 if head_under else 0.7)


func _on_climber_freed() -> void:
	_caught = false
	_buried = false
	if _service != null:
		_service.set_muffle(0.0)
		if _service.player_audio != null:
			_service.player_audio.play_relief()
	_set_tension(0.0)


func _on_decision(decision_type: String, _context: Dictionary) -> void:
	match decision_type:
		"air_pocket":
			# A hand to the face: a breath saved
			_startle(0.5)


# =============================================================================
# CREVASSES
# =============================================================================

func _on_crevasse_fall(_crevasse: GlacierField.Crevasse) -> void:
	# The bridge goes: the floor drops and the pieces fall a long way
	_play("bridge_collapse", -5.0)
	_startle(1.0)


func _on_climbed_out(_crevasse: GlacierField.Crevasse) -> void:
	if _service != null and _service.player_audio != null:
		_service.play_later(0.6, "reaction_relief", -9.0, 1.0, AudioService.BUS_PLAYER)


# =============================================================================
# QUERIES
# =============================================================================

func get_summary() -> Dictionary:
	return {
		"roars": _roars.size(),
		"caught": _caught,
		"buried": _buried,
		"in_crevasse": _in_crevasse,
	}
