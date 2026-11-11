class_name AudioInitializer
extends Node
## Builds the audio system: the buses, the sound library and the managers
## Add this node to the main scene (Main does) and audio is set up

# =============================================================================
# CHILDREN
# =============================================================================

var library: SoundLibrary
var audio_service: AudioService
var ambient_manager: AmbientAudioManager
var player_audio: PlayerAudioManager
var ui_audio: UIAudioManager
var gear_audio: GearAudioManager
var hazard_audio: HazardAudioManager

## The loudest the Master bus is allowed to get (dB)
const GUARD_THRESHOLD_DB := -4.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	print("[AudioInitializer] Setting up audio system...")

	# Buses must exist before the audio managers assign their players to them,
	# and the sounds before the managers ask for them
	_setup_audio_buses()
	library = SoundLibrary.new()
	library.name = "SoundLibrary"
	add_child(library)
	library.load_all()
	_create_audio_nodes()

	EventBus.audio_ready.emit()
	audio_service.audio_initialized.emit()
	print("[AudioInitializer] Audio system ready")


func _create_audio_nodes() -> void:
	audio_service = AudioService.new()
	audio_service.name = "AudioService"
	audio_service.library = library
	add_child(audio_service)

	ambient_manager = AmbientAudioManager.new()
	ambient_manager.name = "AmbientAudioManager"
	add_child(ambient_manager)

	player_audio = PlayerAudioManager.new()
	player_audio.name = "PlayerAudioManager"
	add_child(player_audio)

	ui_audio = UIAudioManager.new()
	ui_audio.name = "UIAudioManager"
	add_child(ui_audio)

	gear_audio = GearAudioManager.new()
	gear_audio.name = "GearAudioManager"
	add_child(gear_audio)

	hazard_audio = HazardAudioManager.new()
	hazard_audio.name = "HazardAudioManager"
	add_child(hazard_audio)

	# Link managers to audio service
	audio_service.ambient_manager = ambient_manager
	audio_service.player_audio = player_audio
	audio_service.ui_audio = ui_audio
	audio_service.gear_audio = gear_audio
	audio_service.hazard_audio = hazard_audio


# =============================================================================
# BUSES
# =============================================================================

## The bus layout, built in code so the project needs no bus resource:
##
##   Master (peak compressor)
##     Ambient (low-pass)          wind, weather, the mountain in the distance
##       AmbientLeft / AmbientRight  the two halves of the wind
##     Player (reverb)             breath, heart, footsteps, the body
##     Effects (low-pass, reverb)  gear, hazards, anything else in the world
##     UI                          menus and the map
##
## The low-passes and reverbs are off until AudioService turns them on (buried
## in snow, down a crevasse). Their order on each bus matches the FX_
## constants in AudioService.
func _setup_audio_buses() -> void:
	# The mix is balanced to stay under -6 dB; this only catches the moments
	# when several loud things land together. Two things measured in 4.2:
	# AudioEffectLimiter adds make-up gain and clips rather than limits, and
	# AudioEffectCompressor reduces gain about twice as much as its ratio
	# says. So a ratio of 2 holds the output at the threshold (a limiter),
	# and anything higher makes loud passages quieter than soft ones.
	var master := AudioServer.get_bus_index(AudioService.BUS_MASTER)
	if master >= 0 and not _has_effect(master, "AudioEffectCompressor"):
		var guard := AudioEffectCompressor.new()
		guard.threshold = GUARD_THRESHOLD_DB
		guard.ratio = 2.0
		guard.attack_us = 20.0
		guard.release_ms = 120.0
		guard.gain = 0.0
		AudioServer.add_bus_effect(master, guard)

	var ambient := _ensure_bus(AudioService.BUS_AMBIENT, AudioService.BUS_MASTER)
	_ensure_effects(ambient, [_muffle_filter()])
	var left := _ensure_bus(AudioService.BUS_AMBIENT_LEFT, AudioService.BUS_AMBIENT)
	_ensure_effects(left, [_panner(-0.7)])
	var right := _ensure_bus(AudioService.BUS_AMBIENT_RIGHT, AudioService.BUS_AMBIENT)
	_ensure_effects(right, [_panner(0.7)])

	var player_bus := _ensure_bus(AudioService.BUS_PLAYER, AudioService.BUS_MASTER)
	_ensure_effects(player_bus, [_ice_reverb()])

	var effects := _ensure_bus(AudioService.BUS_EFFECTS, AudioService.BUS_MASTER)
	_ensure_effects(effects, [_muffle_filter(), _ice_reverb()])

	_ensure_bus(AudioService.BUS_UI, AudioService.BUS_MASTER)

	for bus in [ambient, player_bus, effects]:
		for slot in range(AudioServer.get_bus_effect_count(bus)):
			AudioServer.set_bus_effect_enabled(bus, slot, false)


func _ensure_bus(bus_name: String, send_to: String) -> int:
	var index := AudioServer.get_bus_index(bus_name)
	if index == -1:
		index = AudioServer.bus_count
		AudioServer.add_bus()
		AudioServer.set_bus_name(index, bus_name)
		AudioServer.set_bus_send(index, send_to)
		print("[AudioInitializer] Created audio bus: %s" % bus_name)
	return index


## Add the effects a bus should have, unless a previous run already did
func _ensure_effects(bus: int, effects: Array) -> void:
	if AudioServer.get_bus_effect_count(bus) > 0:
		return
	for effect in effects:
		AudioServer.add_bus_effect(bus, effect)


func _has_effect(bus: int, type_name: String) -> bool:
	for slot in range(AudioServer.get_bus_effect_count(bus)):
		if AudioServer.get_bus_effect(bus, slot).is_class(type_name):
			return true
	return false


func _muffle_filter() -> AudioEffectLowPassFilter:
	var filter := AudioEffectLowPassFilter.new()
	filter.cutoff_hz = AudioService.MUFFLE_OPEN_HZ
	filter.resonance = 0.5
	return filter


func _panner(pan: float) -> AudioEffectPanner:
	var panner := AudioEffectPanner.new()
	panner.pan = pan
	return panner


## The inside of a crevasse: hard walls close by, a long narrow space
func _ice_reverb() -> AudioEffectReverb:
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.55
	reverb.damping = 0.35
	reverb.spread = 0.8
	reverb.predelay_msec = 28.0
	reverb.predelay_feedback = 0.25
	reverb.hipass = 0.12
	reverb.dry = 1.0
	reverb.wet = 0.0
	return reverb


# =============================================================================
# PUBLIC API
# =============================================================================

## Get the audio service
func get_audio_service() -> AudioService:
	return audio_service


## Get the sound library
func get_library() -> SoundLibrary:
	return library


## Get the ambient manager
func get_ambient_manager() -> AmbientAudioManager:
	return ambient_manager


## Get the player audio manager
func get_player_audio() -> PlayerAudioManager:
	return player_audio


## Get the UI audio manager
func get_ui_audio() -> UIAudioManager:
	return ui_audio


## Get the gear audio manager
func get_gear_audio() -> GearAudioManager:
	return gear_audio


## Get the hazard audio manager
func get_hazard_audio() -> HazardAudioManager:
	return hazard_audio


## Load the sound files again (after re-rendering or replacing some while the
## game is running)
func reload_audio() -> void:
	print("[AudioInitializer] Reloading audio...")
	ambient_manager.stop_ambient()
	player_audio.disable()
	library.load_all()
	ambient_manager.assign_streams()
	if GameStateManager.current_state == GameEnums.GameState.DESCENT:
		ambient_manager.start_ambient()
		player_audio.enable()
