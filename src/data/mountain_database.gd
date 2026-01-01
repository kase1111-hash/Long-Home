class_name MountainDatabase
extends Node
## Database of available mountains for descent
## Manages mountain data, player progress, and unlocks
##
## Design Philosophy:
## - Mountains are characters with personality
## - Progress unlocks knowledge, not access
## - Familiarity reduces unknown risk

# =============================================================================
# SIGNALS
# =============================================================================

signal mountain_unlocked(mountain_id: String)
signal mountain_knowledge_updated(mountain_id: String, level: GameEnums.KnowledgeLevel)
signal database_loaded()

# =============================================================================
# DATA STRUCTURES
# =============================================================================

class MountainData:
	## Unique identifier
	var id: String
	## Display name
	var name: String
	## Description/flavor text
	var description: String
	## Region/location
	var region: String

	## Summit elevation (meters)
	var summit_elevation: float
	## Base elevation (meters)
	var base_elevation: float
	## Total descent (meters)
	var total_descent: float

	## Difficulty rating (1-5)
	var difficulty: int
	## Technical sections count
	var technical_sections: int
	## Estimated descent time (minutes)
	var estimated_time: float

	## Terrain characteristics
	var primary_terrain: GameEnums.SurfaceType
	var has_mixed_terrain: bool
	var cliff_exposure: float  # 0-1
	var slide_risk: float  # 0-1

	## Weather patterns
	var weather_volatility: float  # 0-1, how quickly weather changes
	var typical_temperature: float  # Celsius at summit
	var wind_exposure: float  # 0-1

	## Gear recommendations
	var rope_recommended: bool
	var rope_required: bool
	var bivy_possible: bool
	var crampons_required: bool

	## Path to terrain data file
	var terrain_file: String
	## Preview image path
	var preview_image: String
	## Topo map image path
	var topo_image: String

	## Unlock requirements
	var unlock_requirement: String  # empty = always available
	var prerequisite_mountains: Array[String] = []

	func get_vertical() -> float:
		return summit_elevation - base_elevation

	func get_difficulty_name() -> String:
		match difficulty:
			1: return "Beginner"
			2: return "Moderate"
			3: return "Challenging"
			4: return "Expert"
			5: return "Extreme"
			_: return "Unknown"

	func to_dict() -> Dictionary:
		return {
			"id": id,
			"name": name,
			"description": description,
			"region": region,
			"summit_elevation": summit_elevation,
			"base_elevation": base_elevation,
			"difficulty": difficulty,
			"technical_sections": technical_sections,
			"estimated_time": estimated_time,
			"terrain_file": terrain_file
		}


class MountainProgress:
	## Best outcome achieved
	var best_outcome: GameEnums.ResolutionType = GameEnums.ResolutionType.FATALITY
	## Number of attempts
	var attempts: int = 0
	## Number of clean returns
	var clean_returns: int = 0
	## Best time (minutes)
	var best_time: float = -1.0
	## Knowledge level
	var knowledge: GameEnums.KnowledgeLevel = GameEnums.KnowledgeLevel.UNKNOWN
	## Routes discovered
	var discovered_routes: Array[String] = []
	## Hazards discovered
	var discovered_hazards: Array[String] = []

	func update_from_run(outcome: GameEnums.ResolutionType, time: float) -> void:
		attempts += 1

		if outcome < best_outcome:  # Lower enum = better outcome
			best_outcome = outcome

		if outcome == GameEnums.ResolutionType.CLEAN_RETURN:
			clean_returns += 1
			if best_time < 0 or time < best_time:
				best_time = time

		_update_knowledge()

	func _update_knowledge() -> void:
		if attempts == 0:
			knowledge = GameEnums.KnowledgeLevel.UNKNOWN
		elif clean_returns == 0:
			knowledge = GameEnums.KnowledgeLevel.ATTEMPTED
		elif clean_returns == 1:
			knowledge = GameEnums.KnowledgeLevel.FAMILIAR
		elif clean_returns < 5:
			knowledge = GameEnums.KnowledgeLevel.EXPERIENCED
		else:
			knowledge = GameEnums.KnowledgeLevel.MASTERED

	func to_dict() -> Dictionary:
		return {
			"best_outcome": best_outcome,
			"attempts": attempts,
			"clean_returns": clean_returns,
			"best_time": best_time,
			"knowledge": knowledge,
			"routes": discovered_routes,
			"hazards": discovered_hazards
		}

	static func from_dict(data: Dictionary) -> MountainProgress:
		var progress := MountainProgress.new()
		progress.best_outcome = data.get("best_outcome", GameEnums.ResolutionType.FATALITY)
		progress.attempts = data.get("attempts", 0)
		progress.clean_returns = data.get("clean_returns", 0)
		progress.best_time = data.get("best_time", -1.0)
		progress.knowledge = data.get("knowledge", GameEnums.KnowledgeLevel.UNKNOWN)
		progress.discovered_routes.assign(data.get("routes", []))
		progress.discovered_hazards.assign(data.get("hazards", []))
		return progress


# =============================================================================
# STATE
# =============================================================================

## All mountains in database
var mountains: Dictionary = {}  # id -> MountainData

## Player progress per mountain
var progress: Dictionary = {}  # id -> MountainProgress

## Currently selected mountain
var selected_mountain: String = ""

## Is database loaded
var is_loaded: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("MountainDatabase", self)
	_load_mountains()
	_load_progress()
	print("[MountainDatabase] Initialized with %d mountains" % mountains.size())


func _load_mountains() -> void:
	# Create built-in mountains
	_create_builtin_mountains()

	# Load any custom mountains from files
	_load_custom_mountains()

	is_loaded = true
	database_loaded.emit()


func _create_builtin_mountains() -> void:
	# Tutorial Mountain - The Knife Edge
	var knife_edge := MountainData.new()
	knife_edge.id = "knife_edge"
	knife_edge.name = "The Knife Edge"
	knife_edge.description = "A narrow ridge descent. Perfect for learning the basics of alpine movement and understanding terrain."
	knife_edge.region = "Training Grounds"
	knife_edge.summit_elevation = 3200.0
	knife_edge.base_elevation = 2400.0
	knife_edge.total_descent = 800.0
	knife_edge.difficulty = 1
	knife_edge.technical_sections = 0
	knife_edge.estimated_time = 60.0
	knife_edge.primary_terrain = GameEnums.SurfaceType.SNOW_FIRM
	knife_edge.has_mixed_terrain = false
	knife_edge.cliff_exposure = 0.2
	knife_edge.slide_risk = 0.3
	knife_edge.weather_volatility = 0.2
	knife_edge.typical_temperature = -5.0
	knife_edge.wind_exposure = 0.4
	knife_edge.rope_recommended = false
	knife_edge.rope_required = false
	knife_edge.bivy_possible = false
	knife_edge.crampons_required = false
	knife_edge.terrain_file = "res://assets/terrain/knife_edge.tres"
	knife_edge.preview_image = "res://assets/images/mountains/knife_edge.png"
	mountains[knife_edge.id] = knife_edge

	# North Face - Moderate difficulty
	var north_face := MountainData.new()
	north_face.id = "north_face"
	north_face.name = "North Face"
	north_face.description = "A classic alpine descent with varied terrain. Mixed snow and ice with some exposed sections."
	north_face.region = "Alpine Peaks"
	north_face.summit_elevation = 4100.0
	north_face.base_elevation = 2800.0
	north_face.total_descent = 1300.0
	north_face.difficulty = 2
	north_face.technical_sections = 2
	north_face.estimated_time = 120.0
	north_face.primary_terrain = GameEnums.SurfaceType.SNOW_FIRM
	north_face.has_mixed_terrain = true
	north_face.cliff_exposure = 0.4
	north_face.slide_risk = 0.5
	north_face.weather_volatility = 0.4
	north_face.typical_temperature = -10.0
	north_face.wind_exposure = 0.6
	north_face.rope_recommended = true
	north_face.rope_required = false
	north_face.bivy_possible = true
	north_face.crampons_required = true
	north_face.terrain_file = "res://assets/terrain/north_face.tres"
	north_face.preview_image = "res://assets/images/mountains/north_face.png"
	north_face.prerequisite_mountains = ["knife_edge"]
	mountains[north_face.id] = north_face

	# The Couloir - Challenging
	var couloir := MountainData.new()
	couloir.id = "the_couloir"
	couloir.name = "The Couloir"
	couloir.description = "A steep gully descent requiring technical skills. Ice and hard snow with mandatory rope sections."
	couloir.region = "High Peaks"
	couloir.summit_elevation = 4500.0
	couloir.base_elevation = 3000.0
	couloir.total_descent = 1500.0
	couloir.difficulty = 3
	couloir.technical_sections = 4
	couloir.estimated_time = 180.0
	couloir.primary_terrain = GameEnums.SurfaceType.ICE
	couloir.has_mixed_terrain = true
	couloir.cliff_exposure = 0.6
	couloir.slide_risk = 0.7
	couloir.weather_volatility = 0.5
	couloir.typical_temperature = -15.0
	couloir.wind_exposure = 0.3  # Protected in gully
	couloir.rope_recommended = true
	couloir.rope_required = true
	couloir.bivy_possible = false
	couloir.crampons_required = true
	couloir.terrain_file = "res://assets/terrain/couloir.tres"
	couloir.preview_image = "res://assets/images/mountains/couloir.png"
	couloir.prerequisite_mountains = ["north_face"]
	mountains[couloir.id] = couloir

	# Storm Peak - Expert
	var storm_peak := MountainData.new()
	storm_peak.id = "storm_peak"
	storm_peak.name = "Storm Peak"
	storm_peak.description = "Infamous for sudden weather changes. Long descent with exposure and unpredictable conditions."
	storm_peak.region = "Remote Range"
	storm_peak.summit_elevation = 5200.0
	storm_peak.base_elevation = 3200.0
	storm_peak.total_descent = 2000.0
	storm_peak.difficulty = 4
	storm_peak.technical_sections = 6
	storm_peak.estimated_time = 300.0
	storm_peak.primary_terrain = GameEnums.SurfaceType.MIXED
	storm_peak.has_mixed_terrain = true
	storm_peak.cliff_exposure = 0.7
	storm_peak.slide_risk = 0.6
	storm_peak.weather_volatility = 0.9
	storm_peak.typical_temperature = -20.0
	storm_peak.wind_exposure = 0.8
	storm_peak.rope_recommended = true
	storm_peak.rope_required = true
	storm_peak.bivy_possible = true
	storm_peak.crampons_required = true
	storm_peak.terrain_file = "res://assets/terrain/storm_peak.tres"
	storm_peak.preview_image = "res://assets/images/mountains/storm_peak.png"
	storm_peak.prerequisite_mountains = ["the_couloir"]
	mountains[storm_peak.id] = storm_peak

	# The Long Way Down - Extreme
	var long_way := MountainData.new()
	long_way.id = "long_way_down"
	long_way.name = "The Long Way Down"
	long_way.description = "The ultimate test. Massive vertical, multiple technical sections, and unforgiving terrain. Many have tried. Few return."
	long_way.region = "The Barrier"
	long_way.summit_elevation = 6100.0
	long_way.base_elevation = 3400.0
	long_way.total_descent = 2700.0
	long_way.difficulty = 5
	long_way.technical_sections = 10
	long_way.estimated_time = 480.0
	long_way.primary_terrain = GameEnums.SurfaceType.MIXED
	long_way.has_mixed_terrain = true
	long_way.cliff_exposure = 0.9
	long_way.slide_risk = 0.8
	long_way.weather_volatility = 0.7
	long_way.typical_temperature = -25.0
	long_way.wind_exposure = 0.7
	long_way.rope_recommended = true
	long_way.rope_required = true
	long_way.bivy_possible = true
	long_way.crampons_required = true
	long_way.terrain_file = "res://assets/terrain/long_way_down.tres"
	long_way.preview_image = "res://assets/images/mountains/long_way_down.png"
	long_way.prerequisite_mountains = ["storm_peak"]
	mountains[long_way.id] = long_way


func _load_custom_mountains() -> void:
	# Would load from user://mountains/ for mod support
	pass


# =============================================================================
# PROGRESS MANAGEMENT
# =============================================================================

func _load_progress() -> void:
	var file := FileAccess.open("user://mountain_progress.json", FileAccess.READ)
	if file == null:
		return

	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()

	if error != OK:
		return

	var data: Dictionary = json.data
	for mountain_id in data:
		progress[mountain_id] = MountainProgress.from_dict(data[mountain_id])


func save_progress() -> void:
	var data := {}
	for mountain_id in progress:
		data[mountain_id] = progress[mountain_id].to_dict()

	var dir := DirAccess.open("user://")
	if dir == null:
		return

	var file := FileAccess.open("user://mountain_progress.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()


func record_run(mountain_id: String, outcome: GameEnums.ResolutionType, time: float) -> void:
	if not progress.has(mountain_id):
		progress[mountain_id] = MountainProgress.new()

	var old_knowledge: GameEnums.KnowledgeLevel = progress[mountain_id].knowledge
	progress[mountain_id].update_from_run(outcome, time)

	if progress[mountain_id].knowledge != old_knowledge:
		mountain_knowledge_updated.emit(mountain_id, progress[mountain_id].knowledge)

	save_progress()

	# Check for unlocks
	_check_unlocks()


func _check_unlocks() -> void:
	for mountain_id in mountains:
		var mountain: MountainData = mountains[mountain_id]

		if _is_unlocked(mountain_id):
			continue

		# Check prerequisites
		var prereqs_met := true
		for prereq_id in mountain.prerequisite_mountains:
			if not _has_completed(prereq_id):
				prereqs_met = false
				break

		if prereqs_met:
			mountain_unlocked.emit(mountain_id)


func _is_unlocked(mountain_id: String) -> bool:
	var mountain: MountainData = mountains.get(mountain_id)
	if mountain == null:
		return false

	# No prerequisites = always unlocked
	if mountain.prerequisite_mountains.size() == 0:
		return true

	# Check all prerequisites completed
	for prereq_id in mountain.prerequisite_mountains:
		if not _has_completed(prereq_id):
			return false

	return true


func _has_completed(mountain_id: String) -> bool:
	if not progress.has(mountain_id):
		return false

	var p: MountainProgress = progress[mountain_id]
	return p.best_outcome <= GameEnums.ResolutionType.INJURED_RETURN


# =============================================================================
# QUERIES
# =============================================================================

func get_mountain(mountain_id: String) -> MountainData:
	return mountains.get(mountain_id)


func get_progress(mountain_id: String) -> MountainProgress:
	if not progress.has(mountain_id):
		progress[mountain_id] = MountainProgress.new()
	return progress[mountain_id]


func get_all_mountains() -> Array[MountainData]:
	var result: Array[MountainData] = []
	for mountain in mountains.values():
		result.append(mountain)
	return result


func get_available_mountains() -> Array[MountainData]:
	var result: Array[MountainData] = []
	for mountain_id in mountains:
		if _is_unlocked(mountain_id):
			result.append(mountains[mountain_id])
	return result


func get_locked_mountains() -> Array[MountainData]:
	var result: Array[MountainData] = []
	for mountain_id in mountains:
		if not _is_unlocked(mountain_id):
			result.append(mountains[mountain_id])
	return result


func is_unlocked(mountain_id: String) -> bool:
	return _is_unlocked(mountain_id)


func get_knowledge_level(mountain_id: String) -> GameEnums.KnowledgeLevel:
	return get_progress(mountain_id).knowledge


func select_mountain(mountain_id: String) -> bool:
	if not mountains.has(mountain_id):
		return false

	if not _is_unlocked(mountain_id):
		return false

	selected_mountain = mountain_id
	return true


func get_selected_mountain() -> MountainData:
	return mountains.get(selected_mountain)


func get_mountains_by_difficulty(difficulty: int) -> Array[MountainData]:
	var result: Array[MountainData] = []
	for mountain in mountains.values():
		if mountain.difficulty == difficulty:
			result.append(mountain)
	return result


func get_mountains_by_region(region: String) -> Array[MountainData]:
	var result: Array[MountainData] = []
	for mountain in mountains.values():
		if mountain.region == region:
			result.append(mountain)
	return result
