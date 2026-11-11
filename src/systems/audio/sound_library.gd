class_name SoundLibrary
extends Node
## Every sound effect the game can play, looked up by id
##
## Sounds are files named res://assets/audio/<folder>/<id>_<NN>.wav (ogg and
## mp3 work too). The folder is only for tidiness: the id is the file name
## without its number, and files that share an id are variants of one sound,
## picked at random so nothing repeats back to back. An id ending in "_loop"
## loops.
##
## To replace a sound with a recording, overwrite its file. To add a variant,
## add a file with the next number. Nothing else needs to change.
##
## The files in assets/audio are rendered by tools/sfx/generate.py.

# =============================================================================
# CONFIGURATION
# =============================================================================

const AUDIO_ROOT := "res://assets/audio"
const EXTENSIONS: Array[String] = ["wav", "ogg", "mp3"]
const LOOP_SUFFIX := "_loop"

# =============================================================================
# STATE
# =============================================================================

## id -> Array of AudioStream (the variants, in file order)
var _sounds: Dictionary = {}

## id -> index of the variant played last
var _last_pick: Dictionary = {}

## Ids that were asked for and are not in the library (each reported once)
var _missing: Dictionary = {}

## id -> how many times it has been asked for (what did this run sound like?)
var _requests: Dictionary = {}

## True when no files were found and rough stand-ins were generated instead
var using_placeholders: bool = false

var _rng := RandomNumberGenerator.new()


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	_rng.randomize()
	ServiceLocator.register_service("SoundLibrary", self)


# =============================================================================
# LOADING
# =============================================================================

## Load every sound under root. Returns how many files were loaded.
## With no files at all, falls back to generated stand-ins for the sounds the
## game cannot do without (wind, breath, footsteps, a slide).
func load_all(root: String = AUDIO_ROOT) -> int:
	_sounds.clear()
	_last_pick.clear()
	_missing.clear()
	using_placeholders = false

	var count := _load_folder(root)
	if count == 0:
		push_warning("[SoundLibrary] No sound files under %s; using generated stand-ins" % root)
		_build_placeholders()
		using_placeholders = true
		count = _sounds.size()
	print("[SoundLibrary] %d sounds, %d files%s" % [
		_sounds.size(), count, " (placeholders)" if using_placeholders else ""])
	return count


func _load_folder(folder: String) -> int:
	var dir := DirAccess.open(folder)
	if dir == null:
		return 0
	var count := 0
	for sub in dir.get_directories():
		count += _load_folder(folder.path_join(sub))

	# In an exported game only "<file>.import" is listed; in the editor both are
	var names := {}
	for file in dir.get_files():
		var name: String = file
		if name.ends_with(".import"):
			name = name.trim_suffix(".import")
		elif name.ends_with(".remap"):
			name = name.trim_suffix(".remap")
		if name.get_extension().to_lower() in EXTENSIONS:
			names[name] = true
	var sorted_names: Array = names.keys()
	sorted_names.sort()

	for file in sorted_names:
		var path := folder.path_join(str(file))
		if not ResourceLoader.exists(path):
			# Present on disk but never imported: say how to fix it, once per folder
			push_warning("[SoundLibrary] %s is not imported (run: godot --headless --path . --import)" % path)
			break
		var stream := load(path) as AudioStream
		if stream == null:
			push_warning("[SoundLibrary] Could not load %s" % path)
			continue
		var id := id_of(str(file))
		if id.ends_with(LOOP_SUFFIX):
			_make_loop(stream)
		if not _sounds.has(id):
			_sounds[id] = []
		var variants: Array = _sounds[id]
		variants.append(stream)
		count += 1
	return count


## "footstep_snow_firm_03.wav" -> "footstep_snow_firm"
static func id_of(file_name: String) -> String:
	var stem := file_name.get_basename()
	var cut := stem.rfind("_")
	if cut > 0 and stem.substr(cut + 1).is_valid_int():
		return stem.substr(0, cut)
	return stem


## Loops rendered by the generator carry their loop points; a file dropped in
## by hand may not, so loop it end to end
func _make_loop(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		if wav.loop_mode == AudioStreamWAV.LOOP_DISABLED:
			wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
			wav.loop_begin = 0
			wav.loop_end = int(round(wav.get_length() * wav.mix_rate))
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true


# =============================================================================
# LOOKUP
# =============================================================================

func has_sound(id: String) -> bool:
	return _sounds.has(id)


## A variant of the sound, never the same one twice running. Null (with one
## warning per id) when the library has no such sound.
func get_stream(id: String) -> AudioStream:
	_requests[id] = int(_requests.get(id, 0)) + 1
	if not _sounds.has(id):
		if not _missing.has(id):
			_missing[id] = true
			push_warning("[SoundLibrary] No sound '%s'" % id)
		return null
	var variants: Array = _sounds[id]
	var index := 0
	if variants.size() > 1:
		var last: int = _last_pick.get(id, -1)
		index = _rng.randi_range(0, variants.size() - 1)
		if index == last:
			index = (index + 1 + _rng.randi_range(0, variants.size() - 2)) % variants.size()
	_last_pick[id] = index
	var stream: AudioStream = variants[index]
	return stream


## A particular variant (wrapping), for layers that must differ from each other
func get_variant(id: String, index: int) -> AudioStream:
	if not _sounds.has(id):
		return get_stream(id)
	_requests[id] = int(_requests.get(id, 0)) + 1
	var variants: Array = _sounds[id]
	var stream: AudioStream = variants[posmod(index, variants.size())]
	return stream


func variant_count(id: String) -> int:
	if not _sounds.has(id):
		return 0
	var variants: Array = _sounds[id]
	return variants.size()


func get_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for id in _sounds.keys():
		ids.append(str(id))
	ids.sort()
	return ids


## Ids the game asked for that the library does not have
func get_missing() -> PackedStringArray:
	var ids := PackedStringArray()
	for id in _missing.keys():
		ids.append(str(id))
	ids.sort()
	return ids


## How many times a sound has been asked for since clear_requests()
func get_request_count(id: String) -> int:
	return int(_requests.get(id, 0))


## Every id asked for since clear_requests(), in name order
func get_requested_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for id in _requests.keys():
		ids.append(str(id))
	ids.sort()
	return ids


func clear_requests() -> void:
	_requests.clear()


func get_summary() -> Dictionary:
	var files := 0
	for id in _sounds.keys():
		files += variant_count(str(id))
	return {
		"sounds": _sounds.size(),
		"files": files,
		"placeholders": using_placeholders,
		"missing": get_missing(),
	}


# =============================================================================
# PLACEHOLDERS
# =============================================================================

## Rough generated stand-ins, so a checkout without assets/audio still makes
## the sounds play depends on. Everything else is silent until the files exist.
func _build_placeholders() -> void:
	_add_placeholder("wind_low_loop", ProceduralAudio.create_wind_stream(4.0, 0.5))
	_add_placeholder("wind_mid_loop", ProceduralAudio.create_wind_stream(4.0, 0.3))
	_add_placeholder("wind_howl_loop", ProceduralAudio.create_wind_howl_stream(3.0))
	_add_placeholder("wind_gust", ProceduralAudio.create_wind_gust_stream(2.0))
	for id in ["breath_calm_in", "breath_hard_in", "breath_gasp_in"]:
		_add_placeholder(id, ProceduralAudio.create_gasp_stream())
	for id in ["breath_calm_out", "breath_hard_out", "breath_gasp_out", "reaction_relief"]:
		_add_placeholder(id, ProceduralAudio.create_relief_exhale_stream())
	for id in ["footstep_snow_firm", "footstep_snow_soft", "footstep_snow_powder", "crampon_snow"]:
		_add_placeholder(id, ProceduralAudio.create_footstep_snow_stream())
	_add_placeholder("footstep_ice", ProceduralAudio.create_footstep_ice_stream())
	_add_placeholder("crampon_ice", ProceduralAudio.create_crampon_scrape_stream())
	_add_placeholder("footstep_rock", ProceduralAudio.create_footstep_rock_stream())
	_add_placeholder("footstep_scree", ProceduralAudio.create_footstep_scree_stream())
	_add_placeholder("slide_snow_loop", ProceduralAudio.create_slide_snow_stream(2.0))
	_add_placeholder("slide_ice_loop", ProceduralAudio.create_slide_ice_stream(2.0))
	_add_placeholder("tumble", ProceduralAudio.create_tumble_stream())
	_add_placeholder("ice_crack", ProceduralAudio.create_ice_crack_stream())
	_add_placeholder("snow_settle", ProceduralAudio.create_snow_settle_stream())
	_add_placeholder("cloth_rustle", ProceduralAudio.create_gear_rustle_stream())
	_add_placeholder("rope_thread", ProceduralAudio.create_rope_handling_stream())


func _add_placeholder(id: String, stream: AudioStream) -> void:
	if id.ends_with(LOOP_SUFFIX):
		_make_loop(stream)
	_sounds[id] = [stream]
