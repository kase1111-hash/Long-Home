extends SceneTree
## Headless checks for glaciers and crevasses: where the generator puts them,
## that the corridor stays safe, glacier surfaces, open slots cut deep and
## bridges left walkable, maps, routes and scatter; then, in a live descent:
## probing finds a hidden crevasse, the collapse hazard behaves, a bridge
## gives way and the climber falls in, climbs out with axe and crampons, and
## without them is trapped until rescued.
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/test_glacier.gd
##
## A "-s" script is compiled before the autoloads exist, so project classes
## are reached with load() and autoloads through /root (see smoke_goal.gd).

const ICE := 4
const SCREE := 8

var _enums: Node
var _locator: Node
var _state_manager: Node
var _main: Node
var _failures: Array[String] = []
var _checks := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_enums = root.get_node_or_null("/root/GameEnums")
	_locator = root.get_node_or_null("/root/ServiceLocator")
	_state_manager = root.get_node_or_null("/root/GameStateManager")
	if _enums == null or _locator == null or _state_manager == null:
		_finish("autoloads missing; run with --path <project root>")
		return
	_main = (load("res://src/scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	for _i in range(4):
		await process_frame

	_main._ensure_terrain_loaded("knife_edge")
	await process_frame
	var terrain: Object = _locator.get_service("TerrainService")
	_expect(terrain.glacier == null, "the beginner's mountain has no glacier")

	_main._ensure_terrain_loaded("north_face")
	await process_frame
	_check_generation(terrain, "north_face")
	var first_point: Vector2 = terrain.glacier.crevasses[0].points[0]
	var count: int = terrain.glacier.crevasses.size()
	_main._ensure_terrain_loaded("knife_edge")
	await process_frame
	_main._ensure_terrain_loaded("north_face")
	await process_frame
	_expect(terrain.glacier.crevasses.size() == count and terrain.glacier.crevasses[0].points[0].distance_to(first_point) < 0.001,
		"the same mountain grows the same glacier")

	_main._ensure_terrain_loaded("long_way_down")
	await process_frame
	_check_generation(terrain, "long_way_down")
	_check_integration(terrain)
	await _check_live(terrain)
	_finish("")


# =============================================================================
# GENERATION
# =============================================================================

func _check_generation(terrain: Object, id: String) -> void:
	var glacier: Object = terrain.glacier
	_expect(glacier != null, "%s has a glacier" % id)
	if glacier == null:
		return
	_expect(glacier.crevasses.size() > 5 and glacier.count_open() > 0 and glacier.count_bridged() > 0,
		"%s: open and hidden crevasses (%d open, %d bridged)" % [id, glacier.count_open(), glacier.count_bridged()])
	var kinds := {}
	for c in glacier.crevasses:
		kinds[c.kind] = true
	_expect(kinds.size() == 3, "%s: transverse, marginal and a bergschrund" % id)
	_expect(glacier.ela_elevation < glacier.head_elevation and glacier.ela_elevation > glacier.snout_elevation,
		"%s: the equilibrium line lies between head and snout" % id)

	# The normal route stays safe
	var corridor: PackedVector3Array = terrain.corridor
	var nearest := INF
	for c in glacier.crevasses:
		for p in c.points:
			for i in range(0, corridor.size(), 2):
				nearest = minf(nearest, p.distance_to(Vector2(corridor[i].x, corridor[i].z)))
	_expect(nearest >= 18.0, "%s: no crevasse within 18 m of the normal route (%.0f m)" % [id, nearest])
	var stats: Dictionary = terrain.get_corridor_stats()
	_expect(stats.max_slope <= 27.6, "%s: the normal route keeps its gentle grade (%.1f deg)" % [id, stats.max_slope])

	# Surfaces: bare ice below the equilibrium line, snow above, rubble moraines
	var below := 0
	var below_ice := 0
	var above := 0
	var above_snow := 0
	var scree := 0
	var nearest_ice := INF
	for chunk in terrain.chunks.values():
		for column in chunk.cells:
			for cell in column:
				var flat := Vector2(cell.position.x, cell.position.z)
				if cell.is_glacier:
					if glacier.crevasse_at(flat, 1.2) != null:
						continue
					if cell.elevation < glacier.ela_elevation:
						below += 1
						if cell.surface_type == ICE:
							below_ice += 1
					elif cell.slope_angle <= 40.0:
						above += 1
						if cell.surface_type <= 3:
							above_snow += 1
					for i in range(0, corridor.size(), 6):
						nearest_ice = minf(nearest_ice, flat.distance_to(Vector2(corridor[i].x, corridor[i].z)))
				elif glacier.moraine_at(flat) > 1.2 and cell.surface_type == SCREE:
					scree += 1
	_expect(below > 0 and float(below_ice) / float(below) > 0.9, "%s: the glacier is bare ice below the equilibrium line (%d of %d)" % [id, below_ice, below])
	_expect(above > 0 and float(above_snow) / float(above) > 0.9, "%s: snow-covered above it (%d of %d)" % [id, above_snow, above])
	_expect(scree > 50, "%s: the moraines are rubble (%d cells)" % [id, scree])
	_expect(nearest_ice >= 14.0, "%s: the ice keeps clear of the normal route (%.0f m)" % [id, nearest_ice])

	# Open slots are cut deep and are rope ground; bridges are walkable with a sag
	var open_ok := true
	var bridge_ok := true
	for c in glacier.crevasses:
		var mid: Vector2 = c.points[1] if c.points.size() > 2 else c.points[0].lerp(c.points[1], 0.5)
		var ground: float = terrain.get_height_at(Vector3(mid.x, 0, mid.y))
		# The surface the slot cuts: midway between its two lips
		var along: Vector2 = c.direction_at(mid)
		var across := Vector2(-along.y, along.x) * (maxf(c.width * 0.5, 1.1) + 2.5)
		var surface: float = 0.5 * (terrain.get_height_at(Vector3(mid.x + across.x, 0, mid.y + across.y)) + terrain.get_height_at(Vector3(mid.x - across.x, 0, mid.y - across.y)))
		if not c.bridged and c.width >= 1.5:
			if surface - ground < 3.0:
				open_ok = false
				print("[test_glacier] shallow open crevasse %d: surface %.1f ground %.1f" % [c.id, surface, ground])
		elif c.bridged:
			var cell: Object = terrain.get_cell_at(Vector3(mid.x, 0, mid.y))
			var side_cell: Object = terrain.get_cell_at(Vector3(mid.x + across.x, 0, mid.y + across.y))
			if side_cell != null and side_cell.slope_angle > 35.0:
				continue  # In an icefall: steep ice either way
			if surface - ground > 1.5 or (cell != null and cell.requires_rope):
				bridge_ok = false
				print("[test_glacier] bridge %d not walkable: surface %.1f ground %.1f" % [c.id, surface, ground])
	_expect(open_ok, "%s: open crevasses are cut deep below their lips" % id)
	_expect(bridge_ok, "%s: snow bridges are walkable, with only a sag" % id)


func _check_integration(terrain: Object) -> void:
	var glacier: Object = terrain.glacier
	# Nothing grows or lies on the ice
	var on_ice := 0
	for obj in terrain.scatter.objects:
		var cell: Object = terrain.get_cell_at(obj.position)
		if cell != null and cell.is_glacier:
			on_ice += 1
	_expect(on_ice == 0, "no trees or boulders on the ice (%d)" % on_ice)

	# The map prints the glacier and the open crevasses, not the hidden ones
	var generator: Object = (load("res://src/systems/terrain/topo_map_generator.gd") as GDScript).new()
	var map: Object = generator.get_terrain_map(terrain)
	_expect(map.glacier_points.size() > 100, "the map tints the glacier (%d samples)" % map.glacier_points.size())
	_expect(map.crevasse_lines.size() == glacier.count_open(), "the map shows the open crevasses only (%d)" % map.crevasse_lines.size())

	# A line down the glacier knows it
	var line := PackedVector3Array()
	for p in glacier.centreline:
		line.append(Vector3(p.x, 0, p.y))
	var metrics: Object = (load("res://src/systems/planning/route_metrics.gd") as GDScript).measure(line, terrain)
	_expect(metrics.glacier_metres > 100.0, "a line down the glacier measures its glacier metres (%d m)" % roundi(metrics.glacier_metres))
	var flagged := false
	for pitch in metrics.pitches:
		if pitch.glacier:
			flagged = true
	_expect(flagged, "the topo marks its glacier pitches")
	var grade: GDScript = load("res://src/systems/planning/alpine_grade.gd")
	_expect(grade.grade_value(28.0, 0.0, 0, 0.0, 0.0, 200.0) > grade.grade_value(28.0, 0.0, 0, 0.0, 0.0, 0.0),
		"glacier travel raises the grade")


# =============================================================================
# LIVE
# =============================================================================

func _check_live(terrain: Object) -> void:
	var states: Dictionary = _enums.GameState
	var db: Object = _locator.get_service("MountainDatabase")
	db.select_mountain("long_way_down", true)
	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await process_frame
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await process_frame
	_state_manager.transition_to(int(states["PLANNING"]))
	await process_frame
	var conditions: Resource = (load("res://src/core/data/start_conditions.gd") as GDScript).create_moderate()
	conditions.mountain_id = "long_way_down"
	var run: Object = _state_manager.start_run("long_way_down", conditions)
	_state_manager.transition_to(int(states["DESCENT"]))
	for _i in range(30):
		await process_frame
	var player: CharacterBody3D = _locator.get_service("PlayerController") as CharacterBody3D
	var system: Object = _locator.get_service("CrevasseSystem")
	_expect(system != null, "the crevasse system runs in a descent")
	var glacier: Object = terrain.glacier
	Engine.time_scale = 4.0

	var bridge = _gentle_crevasse(terrain, true)
	_expect(bridge != null, "a hidden crevasse on gentle ice to work with")
	if bridge == null:
		Engine.time_scale = 1.0
		return
	var mid: Vector2 = bridge.points[1] if bridge.points.size() > 2 else bridge.points[0].lerp(bridge.points[1], 0.5)
	var along: Vector2 = bridge.direction_at(mid)
	var across := Vector2(-along.y, along.x)

	# --- Probing: hollow ahead, firm behind
	var stand: Vector2 = mid + across * (bridge.width * 0.5 + 1.2)
	player.global_position = Vector3(stand.x, terrain.get_height_at(Vector3(stand.x, 0, stand.y)) + 0.3, stand.y)
	player.velocity = Vector3.ZERO
	for _f in range(10):
		await physics_frame
	player.rotation.y = atan2(across.x, across.y)  # face -across: toward the crevasse (model faces -Z)
	var found: bool = system.probe_ahead(glacier)
	_expect(found and bridge.probed, "probing finds the hidden crevasse ahead")
	_expect(terrain.find_children("ProbeHole", "", true, false).size() > 0, "the shaft leaves a hole in the snow")
	player.rotation.y = atan2(-across.x, -across.y)
	_expect(not system.probe_ahead(glacier), "probing the other way finds firm snow")

	# --- The hazard: thin bridges go, thick ones hold, skis spread the load
	var saved_strength: float = bridge.bridge_strength
	bridge.bridge_strength = 0.2
	var thin: float = system.collapse_hazard(bridge)
	bridge.bridge_strength = 0.9
	var thick: float = system.collapse_hazard(bridge)
	var saved_footwear: int = player.footwear
	player.footwear = _enums.Footwear["SKIS"]
	var on_skis: float = system.collapse_hazard(bridge)
	player.footwear = saved_footwear
	bridge.bridge_strength = saved_strength
	_expect(thin > 0.5 and thick < 0.06, "a thin bridge goes in a second or two, a thick one holds (%.2f/s, %.3f/s)" % [thin, thick])
	_expect(on_skis < thick * 0.5, "skis spread the load (%.3f/s)" % on_skis)

	# --- A bridge gives way: the climber falls in for real
	bridge.bridge_strength = 0.0
	bridge.depth = 4.5
	var before: float = terrain.get_height_at(Vector3(mid.x, 0, mid.y))
	player.global_position = Vector3(mid.x, before + 0.3, mid.y)
	player.velocity = Vector3.ZERO
	var fell := false
	for _f in range(240):
		await physics_frame
		if not run.get_incidents_by_type("crevasse_fall").is_empty():
			fell = true
		if system.in_crevasse != null:
			break
	_expect(fell, "the bridge gives way under a walker")
	var after: float = terrain.get_height_at(Vector3(mid.x, 0, mid.y))
	_expect(before - after > 3.0, "the slot is carved open (%.1f m deeper)" % (before - after))
	_expect(system.in_crevasse == bridge, "the climber is down in the crevasse (%.1f m below the lip)" % (bridge.lip_height_at(mid) - player.global_position.y))
	var cell: Object = terrain.get_cell_at(Vector3(mid.x, 0, mid.y))
	_expect(cell != null and cell.surface_type != ICE, "the bottom is the fallen bridge's soft debris")

	# --- Climbing out with axe and crampons
	if system.in_crevasse == bridge and player.current_state != _enums.PlayerMovementState["INCAPACITATED"]:
		player.footwear = _enums.Footwear["CRAMPONS"]
		var flat := Vector2(player.global_position.x, player.global_position.z)
		system.start_climb(bridge, flat, across)
		Input.action_press("move_forward")
		for _f in range(1200):
			await physics_frame
			if not system.climbing:
				break
		Input.action_release("move_forward")
		var out := Vector2(player.global_position.x, player.global_position.z)
		_expect(not system.climbing and bridge.distance_to(out) > bridge.width * 0.5,
			"axe and crampons: the climber climbs out over the lip (%.1f m from the slot)" % bridge.distance_to(out))
		_expect(player.global_position.y > bridge.lip_height_at(out) - 1.0, "and stands on the surface again")
		_expect(not run.get_decisions_by_type("crevasse_climbed_out").is_empty(), "the climb out is in the run's history")

	# --- Without axe and crampons: trapped until rescued
	var open = _gentle_crevasse(terrain, false)
	_expect(open != null, "an open crevasse to fall into")
	if open != null and GameStateManager_active():
		player.gear_state.remove_item(_enums.GearType["ICE_AXE"])
		player.gear_state.remove_item(_enums.GearType["CRAMPONS"])
		player.footwear = _enums.Footwear["BOOTS"]
		system.trapped_rescue_time = 1.5
		var omid: Vector2 = open.points[1] if open.points.size() > 2 else open.points[0].lerp(open.points[1], 0.5)
		player.global_position = Vector3(omid.x, terrain.get_height_at(Vector3(omid.x, 0, omid.y)) + 0.3, omid.y)
		player.velocity = Vector3.ZERO
		for _f in range(360):
			await physics_frame
			if run.is_complete:
				break
		_expect(run.is_complete and run.outcome == _enums.ResolutionType["RESCUE"] and run.end_cause.contains("crevasse"),
			"with nothing to climb with, the climber waits for a rescue (%s)" % run.end_cause)
	Engine.time_scale = 1.0


func GameStateManager_active() -> bool:
	return _state_manager.is_run_active()


## A crevasse (bridged or open) whose surroundings are gentle enough to stand on
func _gentle_crevasse(terrain: Object, bridged: bool):
	var glacier: Object = terrain.glacier
	for c in glacier.crevasses:
		if c.bridged != bridged or c.width < 1.4 or c.length() < 8.0:
			continue
		var mid: Vector2 = c.points[1] if c.points.size() > 2 else c.points[0].lerp(c.points[1], 0.5)
		var along: Vector2 = c.direction_at(mid)
		var across := Vector2(-along.y, along.x)
		var ok := true
		for side in [-1.0, 1.0]:
			var p: Vector2 = mid + across * side * (c.width * 0.5 + 2.5)
			var cell: Object = terrain.get_cell_at(Vector3(p.x, 0, p.y))
			if cell == null or cell.slope_angle > 26.0 or not cell.is_glacier:
				ok = false
			elif glacier.crevasse_at(p, 0.5) != null:
				ok = false
		if ok:
			return c
	return null


# =============================================================================
# HARNESS
# =============================================================================

func _expect(condition: bool, what: String) -> void:
	_checks += 1
	if condition:
		print("[test_glacier] ok: %s" % what)
	else:
		print("[test_glacier] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	Engine.time_scale = 1.0
	if _failures.is_empty():
		print("[test_glacier] PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("[test_glacier] FAIL: %d of %d: %s" % [_failures.size(), _checks, "; ".join(_failures)])
		quit(1)
