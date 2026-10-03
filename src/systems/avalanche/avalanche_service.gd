class_name AvalancheService
extends Node
## Today's avalanche bulletin for each mountain.
##
## A day is drawn the first time a mountain's bulletin is asked for (at the
## hut, while planning) and holds until a run ends; the next attempt is
## another day with another snowpack. The planning screen prints it, the run
## carries it (StartConditions.avalanche) and AvalancheSystem plays it out.

var _today: Dictionary = {}  # mountain id -> AvalancheConditions
var _day_index: int = 0
var _session_seed: int = 0


func _ready() -> void:
	ServiceLocator.register_service("AvalancheService", self)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_session_seed = rng.randi()
	EventBus.run_ended.connect(_on_run_ended)


## The bulletin for a mountain today (drawn on first ask)
func today(mountain_id: String) -> AvalancheConditions:
	if _today.has(mountain_id):
		return _today[mountain_id]
	var conditions := generate(mountain_id, hash([_session_seed, _day_index, mountain_id]))
	_today[mountain_id] = conditions
	return conditions


## Draw a day for a mountain from a seed (the terrain's elevation range when
## that mountain is loaded, else the database's)
func generate(mountain_id: String, day_seed: int) -> AvalancheConditions:
	var mountain: MountainDatabase.MountainData = null
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	if mountain_db != null:
		mountain = mountain_db.get_mountain(mountain_id)
	var range := elevation_range(mountain_id, mountain)
	return AvalancheConditions.generate(mountain, mountain_id, day_seed, range.x, range.y)


## A day whose highest danger is the given level (developer shortcut and
## tests); searches seeds from start_seed
func generate_with_danger(mountain_id: String, level: int, start_seed: int = 1) -> AvalancheConditions:
	var best: AvalancheConditions = null
	for k in range(400):
		var conditions := generate(mountain_id, start_seed + k * 7919)
		if conditions.get_max_danger() == level:
			return conditions
		if best == null or absi(conditions.get_max_danger() - level) < absi(best.get_max_danger() - level):
			best = conditions
	return best


## Set today's bulletin for a mountain (tests, tools)
func set_today(mountain_id: String, conditions: AvalancheConditions) -> void:
	_today[mountain_id] = conditions


func elevation_range(mountain_id: String, mountain: MountainDatabase.MountainData) -> Vector2:
	var terrain := ServiceLocator.get_service("TerrainService") as TerrainService
	if terrain != null and terrain.current_mountain == mountain_id and terrain.terrain_bounds_max.y > terrain.terrain_bounds_min.y:
		return Vector2(terrain.terrain_bounds_min.y, terrain.terrain_bounds_max.y)
	if mountain != null:
		var drop := clampf(mountain.total_descent * 0.4, 200.0, 400.0)
		return Vector2(mountain.summit_elevation - drop, mountain.summit_elevation)
	return Vector2(3000.0, 3400.0)


## A run ended: the next attempt is another day
func _on_run_ended(_run: RunContext, _outcome: GameEnums.ResolutionType) -> void:
	_today.clear()
	_day_index += 1
