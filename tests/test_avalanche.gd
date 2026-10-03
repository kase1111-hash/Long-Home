extends SceneTree
## Headless checks for avalanches: the day's snowpack and bulletin (problems,
## danger, determinism), where the field says slopes can release, the flow
## physics (Voellmy runout, mass, the bed and debris carved into the
## terrain), the planning tools (bulletin, slope-angle classes, ATES, the
## reduction method); then, in a live descent at High danger: the last day's
## avalanches are on the mountain, natural releases and a serac fall run,
## a collapse gives warning, a slope releases under the climber, who is
## carried, pulls the airbag and comes out; a burial is dug out; a snow pit
## reads the snowpack; and a burial with the head under and no one digging
## ends the run.
##
##   godot --headless --audio-driver Dummy --path . -s res://tests/test_avalanche.gd
##
## A "-s" script is compiled before the autoloads exist, so project classes
## are reached with load() and autoloads through /root (see smoke_goal.gd).

const SNOW_FIRM := 0
const SNOW_PACKED := 2

var _enums: Node
var _locator: Node
var _state_manager: Node
var _main: Node
var _conditions_script: GDScript
var _field_script: GDScript
var _metrics_script: GDScript
var _reduction_script: GDScript
var _system_script: GDScript
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
	_conditions_script = load("res://src/systems/avalanche/avalanche_conditions.gd")
	_field_script = load("res://src/systems/avalanche/avalanche_field.gd")
	_metrics_script = load("res://src/systems/planning/route_metrics.gd")
	_reduction_script = load("res://src/systems/avalanche/reduction_method.gd")
	_system_script = load("res://src/systems/avalanche/avalanche_system.gd")
	_main = (load("res://src/scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	for _i in range(4):
		await process_frame

	_check_conditions()
	_check_reduction_method()
	_main._ensure_terrain_loaded("knife_edge")
	await process_frame
	var terrain: Object = _locator.get_service("TerrainService")
	_check_forest(terrain)
	_main._ensure_terrain_loaded("north_face")
	await process_frame
	_check_field(terrain)
	_check_planning(terrain)
	await _check_live(terrain)
	_finish("")


# =============================================================================
# THE DAY AND THE BULLETIN
# =============================================================================

func _check_conditions() -> void:
	var service: Object = _locator.get_service("AvalancheService")
	_expect(service != null, "the avalanche service runs from the start")
	var a: Object = service.generate("north_face", 1234)
	var b: Object = service.generate("north_face", 1234)
	_expect(a.headline == b.headline and a.danger == b.danger and a.problems.size() == b.problems.size(),
		"the same seed draws the same day")

	var low: Object = _day(0.0, 10.0, 270.0, false, -8.0)
	_expect(low.get_max_danger() == 1 and low.problems.is_empty(), "no new snow, little wind, a bonded pack, cold: Low danger")
	var storm: Object = _day(65.0, 20.0, 270.0, false, -8.0)
	_expect(_has_problem(storm, "Storm slab") and storm.get_max_danger() >= 3,
		"65 cm of new snow: a storm slab problem and at least Considerable (%s)" % storm.LEVEL_NAMES[storm.get_max_danger()])
	var windy: Object = _day(25.0, 60.0, 270.0, false, -8.0)
	var wind: Object = _problem(windy, "Wind slab")
	_expect(wind != null, "strong wind with snow to move: a wind slab problem")
	if wind != null:
		# Wind from the west loads the east-facing lee slopes (E is sector 2)
		_expect((wind.aspects >> 2) & 1 == 1 and (wind.aspects >> 6) & 1 == 0,
			"wind from the west loads the lee (east) slopes, not the windward ones (%s)" % wind.aspect_text())
	var weak: Object = _day(10.0, 10.0, 270.0, true, -8.0)
	_expect(_has_problem(weak, "Persistent slab") and _problem(weak, "Persistent slab").remote,
		"a buried weak layer: a persistent slab, remote triggering possible")
	var cold: Object = _day(0.0, 10.0, 270.0, false, -12.0)
	var warm: Object = _day(15.0, 10.0, 270.0, false, 4.0)
	_expect(not _has_problem(cold, "Wet loose"), "a cold day: no wet snow problem")
	_expect(_has_problem(warm, "Wet loose") and _problem(warm, "Wet loose").active_hours.x >= 10.0,
		"a warm day: wet loose snow in the afternoon")
	_expect(_problem(warm, "Wet loose") == null or _problem(warm, "Wet loose").aspects & 0b01111100 == _problem(warm, "Wet loose").aspects,
		"wet snow on the sunny aspects")
	_expect(storm.get_max_danger() > low.get_max_danger(), "more new snow, higher danger")

	# Many days: the levels a bulletin season sees
	var hist := [0, 0, 0, 0, 0, 0]
	for k in range(200):
		var day: Object = service.generate("storm_peak", 500 + k * 13)
		hist[day.get_max_danger()] += 1
	_expect(hist[1] > 10 and hist[2] > 10 and hist[3] > 10 and hist[4] > 0,
		"a stormy peak sees Low, Moderate, Considerable and High days (%s)" % str(hist.slice(1)))
	var high: Object = service.generate_with_danger("long_way_down", 4, 77)
	_expect(high.get_max_danger() == 4, "a High day can be asked for (developer shortcut)")
	_expect(high.headline.begins_with("High"), "the headline names the danger (%s)" % high.headline)
	_expect(high.get_snowpack_lines().size() == 4 and not high.get_advice().is_empty(), "the bulletin describes the snowpack and gives advice")

	# Compass: north is -z, east +x (as on the maps)
	_expect(_conditions_script.aspect_of(Vector2(0, -1)) == 0 and _conditions_script.aspect_of(Vector2(1, 0)) == 2 and _conditions_script.aspect_of(Vector2(0, 1)) == 4,
		"aspects read the map's compass (downhill to -z faces north)")


## A day with chosen weather (seeded otherwise), its problems rebuilt
func _day(new_snow: float, wind: float, wind_from: float, weak_layer: bool, temperature_offset: float) -> Object:
	var c: Object = _conditions_script.new()
	c.seed = 99
	c.elevation_range = Vector2(3700.0, 4100.0)
	c.band_edges = Vector2(3833.0, 3967.0)
	c.new_snow_cm = new_snow
	c.wind_kmh = wind
	c.wind_from = wind_from
	c.weak_layer = weak_layer
	c.weak_layer_kind = "facets above a crust" if weak_layer else ""
	c.weak_layer_depth = 0.7
	c.temperature_offset = temperature_offset
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	c._build_problems(rng)
	c._rate_danger()
	c._write_headline()
	return c


func _problem(c: Object, name: String) -> Object:
	for p in c.problems:
		if p.get_name() == name:
			return p
	return null


func _has_problem(c: Object, name: String) -> bool:
	return _problem(c, name) != null


func _check_reduction_method() -> void:
	var c: Object = _day(15.0, 50.0, 270.0, false, -8.0)  # Wind slab on the east side, loose snow in the shade
	var metrics: Object = _metrics_script.Result.new()
	metrics.start_elevation = 4100.0
	metrics.end_elevation = 3700.0
	metrics.avalanche_metres = 120.0
	metrics.avalanche_max_slope = 38.0
	metrics.avalanche_aspect_metres[4] = 120.0  # All of it facing south
	var lee: Object = _problem(c, "Wind slab")
	var lee_has_south: bool = lee != null and (lee.aspects >> 4) & 1 == 1
	var out: Dictionary = _reduction_script.evaluate(c, metrics)
	_expect(out.applies and float(out.rf1) == 2.0, "reduction method: steepest 38 deg divides by 2 (%s)" % out.text)
	if not lee_has_south:
		_expect(float(out.rf2) == 4.0, "a line off the bulletin's aspects divides by 4")
	metrics.avalanche_max_slope = 43.0
	metrics.avalanche_aspect_metres[4] = 0.0
	metrics.avalanche_aspect_metres[1] = 120.0  # Now on the loaded north-east slope
	var bad: Dictionary = _reduction_script.evaluate(c, metrics)
	_expect(float(bad.rf1) == 1.0 and float(bad.rf2) == 1.0 and not bad.acceptable,
		"a 43 deg slope on the loaded aspect: no reduction, not recommended (%s)" % bad.text)
	metrics.avalanche_metres = 0.0
	var none: Dictionary = _reduction_script.evaluate(c, metrics)
	_expect(not none.applies and none.acceptable, "a line without 30 deg slopes is outside the method")


# =============================================================================
# THE FIELD
# =============================================================================

func _check_forest(terrain: Object) -> void:
	var service: Object = _locator.get_service("AvalancheService")
	var day: Object = service.generate_with_danger("knife_edge", 3, 11)
	var field: Object = _field_script.build(terrain, day)
	var open_sum := 0.0
	var open_n := 0
	var wood_sum := 0.0
	var wood_n := 0
	for i in range(field.slope.size()):
		if field.snow[i] == 0 or field.slope[i] < 32.0 or field.slope[i] > 45.0:
			continue
		var value: float = maxf(field.dry[i], field.wet[i])
		if field.forest[i] >= 0.6:
			wood_sum += value
			wood_n += 1
		elif field.forest[i] == 0.0:
			open_sum += value
			open_n += 1
	if wood_n >= 5 and open_n >= 5:
		_expect(wood_sum / wood_n < 0.5 * open_sum / open_n, "dense forest anchors the snowpack (%.2f in the trees, %.2f in the open)" % [wood_sum / wood_n, open_sum / open_n])
	else:
		_expect(true, "too little steep forest on the beginner's mountain to compare (%d cells)" % wood_n)


func _check_field(terrain: Object) -> void:
	var service: Object = _locator.get_service("AvalancheService")
	var day: Object = service.generate_with_danger("north_face", 4, 77)
	var field: Object = _field_script.build(terrain, day)
	_expect(field.start_cells.size() > 50, "a High day leaves many unstable start zones (%d)" % field.start_cells.size())
	var bad := 0
	for i in field.start_cells:
		if field.slope[i] < 30.0 or field.snow[i] == 0:
			bad += 1
	_expect(bad == 0, "start zones are snow slopes of 30 deg or more")
	var steep_rock := 0
	for i in range(field.slope.size()):
		if field.snow[i] == 0 and field.dry[i] > 0.0:
			steep_rock += 1
	_expect(steep_rock == 0, "rock, scree and bare ice do not release")
	var flat := 0
	for i in range(field.slope.size()):
		if field.slope[i] < 27.0 and field.dry[i] > 0.0:
			flat += 1
	_expect(flat == 0, "gentle slopes do not release")
	# The normal route keeps off the start zones
	var corridor: PackedVector3Array = terrain.corridor
	var exposed := 0
	for p in corridor:
		var i: int = field.index_of(Vector2(p.x, p.z))
		if field.dry[i] > 0.1:
			exposed += 1
	_expect(corridor.size() > 10 and float(exposed) / float(corridor.size()) < 0.1,
		"the normal route rarely crosses a start zone (%d of %d points)" % [exposed, corridor.size()])
	# A slab: spreads from the trigger, steep snow, crown above
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var trigger: int = field.pick_start(rng, 0.0)
	var area: PackedInt32Array = field.slab_area(trigger, 1200.0, 0.0)
	_expect(area.size() >= 10 and area.has(trigger), "a slab breaks around its trigger (%d cells)" % area.size())
	var mean_y := 0.0
	for i in area:
		mean_y += field.elevation[i]
	mean_y /= float(maxi(area.size(), 1))
	var crown: PackedInt32Array = field.crown_of(area)
	var crown_y := 0.0
	for i in crown:
		crown_y += field.elevation[i]
	crown_y /= float(maxi(crown.size(), 1))
	_expect(not crown.is_empty() and crown_y > mean_y, "the crown is the slab's upper edge (%.0f m above the slab's mean)" % (crown_y - mean_y))


# =============================================================================
# PLANNING
# =============================================================================

func _check_planning(terrain: Object) -> void:
	var survey: GDScript = load("res://src/systems/planning/route_survey.gd")
	var routes: Array = survey.survey(terrain)
	_expect(routes.size() >= 2, "the guidebook has lines to rate")
	if routes.size() >= 2:
		var normal: Object = routes[0].metrics
		var direct: Object = routes[1].metrics
		_expect(normal.ates <= 2, "the normal route is not Complex avalanche terrain (ATES %d)" % normal.ates)
		_expect(direct.ates >= normal.ates and direct.avalanche_metres >= normal.avalanche_metres,
			"the face direct has at least as much avalanche terrain (%d m vs %d m)" % [roundi(direct.avalanche_metres), roundi(normal.avalanche_metres)])
		_expect(_metrics_script.avalanche_line(direct).begins_with("Avalanche terrain:"), "route cards print the avalanche terrain (%s)" % _metrics_script.avalanche_line(direct))

	var display: Object = load("res://src/ui/planning/topo_map_display.gd").new()
	var c20: Color = display._get_slope_color(20.0)
	var c32: Color = display._get_slope_color(32.0)
	var c47: Color = display._get_slope_color(47.0)
	_expect(c20.a == 0.0 and c32.a > 0.0 and c32.r > 0.9 and c32.g > 0.8 and c47.b > 0.6,
		"slope shading prints the avalanche classes: nothing under 30, yellow from 30, violet from 45")
	display.free()

	var screen: Control = load("res://src/ui/planning/planning_screen.gd").new()
	root.add_child(screen)
	await_frames_sync()
	screen._refresh_all()
	var bulletin: Node = screen.find_child("BulletinContent", true, false)
	_expect(bulletin != null and bulletin.get_child_count() > 6, "the planning screen has an avalanche bulletin tab")
	_expect(screen.find_child("SlopeToggle", true, false) != null, "the map has a slope-angle toggle")
	# Hidden, not freed: it still waits on services that register later
	screen.visible = false


func await_frames_sync() -> void:
	pass


# =============================================================================
# LIVE
# =============================================================================

func _check_live(terrain: Object) -> void:
	var states: Dictionary = _enums.GameState
	var db: Object = _locator.get_service("MountainDatabase")
	db.select_mountain("north_face", true)
	_state_manager.transition_to(int(states["MOUNTAIN_SELECT"]))
	await process_frame
	_state_manager.transition_to(int(states["LOADOUT_CONFIG"]))
	await process_frame
	_state_manager.transition_to(int(states["PLANNING"]))
	await process_frame
	var service: Object = _locator.get_service("AvalancheService")
	var conditions: Resource = (load("res://src/core/data/start_conditions.gd") as GDScript).create_moderate()
	conditions.mountain_id = "north_face"
	conditions.avalanche = service.generate_with_danger("north_face", 4, 77)
	var run: Object = _state_manager.start_run("north_face", conditions)
	_state_manager.transition_to(int(states["DESCENT"]))
	for _i in range(30):
		await process_frame
	var player: CharacterBody3D = _locator.get_service("PlayerController") as CharacterBody3D
	var system: Object = _locator.get_service("AvalancheSystem")
	_expect(system != null and system.active, "the avalanche system runs a descent with a bulletin")
	if system == null or not system.active:
		return
	var field: Object = system.field
	system.natural_scale = 0.0
	system.trigger_scale = 0.0
	Engine.time_scale = 4.0

	# --- The last day's avalanches are on the mountain
	var recent: Array = system.find_children("RecentAvalanche*", "", false, false)
	_expect(recent.size() >= 1, "a High day: the last day's avalanches lie on the mountain (%d)" % recent.size())
	_expect(terrain.modified, "their debris changed the terrain")
	_expect(_find_cell(terrain, func(cell): return cell.debris_depth > 0.3) != null, "old debris lies on the slopes")

	# Stand safe on the summit while the mountain moves
	_place(player, terrain, Vector2(terrain.start_position.x, terrain.start_position.z))

	# --- Flow physics on a slope away from the climber
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	# A path whose snow mostly stops on the mapped mountain (some run off it)
	var flow: Object = null
	var burial_spot := Vector2.INF
	for _attempt in range(8):
		var start: int = field.pick_start(rng, 0.0)
		var candidate: Object = system._build_flow(start, true, 120)
		if candidate == null:
			continue
		candidate.run_to_end(terrain, 0.05)
		if candidate.deposited_volume > 0.5 * (candidate.released_volume + candidate.entrained_volume):
			flow = system._build_flow(start, true, 120)
			# Same slope again, from the start, so heights can be compared
			break
	_expect(flow != null and flow.positions.size() > 5, "a release builds a flow (%d parcels, %d m3)" % [flow.positions.size() if flow else 0, roundi(flow.released_volume) if flow else 0])
	if flow != null:
		var bed_point: Vector2 = flow.slab_points[0]
		var bed_before: float = terrain.get_height_at(Vector3(bed_point.x, 0, bed_point.y))
		flow.run_to_end(terrain, 0.05)
		_expect(flow.finished and flow.time < 100.0, "the snow comes to rest (%.0f s)" % flow.time)
		_expect(flow.runout_angle() > 15.0 and flow.runout_angle() < 40.0, "runout angle in the range avalanche atlases give (%.1f deg)" % flow.runout_angle())
		_expect(flow.max_speed > 5.0 and flow.max_speed < 45.0, "speeds a slab reaches (%.1f m/s)" % flow.max_speed)
		_expect(absf(flow.deposited_volume + flow.lost_volume - flow.released_volume - flow.entrained_volume) < 0.01 * (flow.released_volume + flow.entrained_volume),
			"mass is kept: released + entrained = deposited + run off the map (%.0f + %.0f = %.0f + %.0f m3)" % [flow.released_volume, flow.entrained_volume, flow.deposited_volume, flow.lost_volume])
		_expect(flow.entrained_volume <= flow.released_volume * 1.01, "the track adds at most what released")
		system._apply_terrain([flow])
		terrain.flush_pending_meshes()
		var deepest := Vector2i.ZERO
		var deepest_depth := 0.0
		for key in flow.deposit:
			var d: float = flow.debris_depth(key)
			var at: Vector2 = flow.deposit_point(key)
			if not terrain.has_terrain_at(Vector3(at.x, 0, at.y)):
				continue
			if d > deepest_depth:
				deepest_depth = d
				deepest = key
		var bed_after: float = terrain.get_height_at(Vector3(bed_point.x, 0, bed_point.y))
		_expect(bed_before - bed_after > flow.slab_depth * 0.6, "the bed is lowered by the slab (%.2f m of %.2f)" % [bed_before - bed_after, flow.slab_depth])
		var deep_point: Vector2 = flow.deposit_point(deepest)
		if deepest_depth > 0.8:
			burial_spot = deep_point
		var deep_cell: Object = terrain.get_cell_at(Vector3(deep_point.x, 0, deep_point.y))
		_expect(deepest_depth > 0.5 and deep_cell != null and deep_cell.debris_depth > 0.4, "debris piles up where it stopped (%.1f m)" % deepest_depth)
		_expect(deep_cell != null and deep_cell.surface_type == SNOW_PACKED, "the debris is hard, packed snow")
		var bed_cell: Object = terrain.get_cell_at(Vector3(bed_point.x, 0, bed_point.y))
		_expect(bed_cell != null and bed_cell.avalanche_bed and bed_cell.surface_type == SNOW_FIRM, "the bed is the old, firm surface")
		_expect(not terrain.has_pending_meshes(), "terrain meshes rebuilt")

		# --- A burial in that debris: dug out stroke by stroke
		if deepest_depth > 0.8:
			_place(player, terrain, deep_point)
			system._rng.seed = 5
			system._catch(flow)
			system.burial_depth = 0.6
			system.air_pocket = false
			system._bury()
			_expect(system.is_buried() and system.burial_depth >= 0.5, "buried with the head under (%.2f m)" % system.burial_depth)
			_expect(player.current_state == _enums.PlayerMovementState["CAUGHT"] and player.held_by == system, "the debris holds the climber")
			_expect(not run.get_incidents_by_type("avalanche_burial").is_empty(), "the burial is in the run's history")
			var strokes := 0
			while system.is_buried() and strokes < 100:
				system.dig_stroke()
				strokes += 1
			_expect(not system.is_buried() and player.held_by == null, "dug out after %d strokes" % strokes)
			_expect(strokes > 10, "digging out of 60 cm of debris takes work")
			_expect(player.current_state != _enums.PlayerMovementState["CAUGHT"], "standing again")
			for _f in range(10):
				await physics_frame

	# --- Natural releases and a serac fall
	_place(player, terrain, Vector2(terrain.start_position.x, terrain.start_position.z))
	var released := []
	var on_release := func(f): released.append(f)
	system.avalanche_released.connect(on_release)
	system.natural_scale = 300.0
	for _f in range(600):
		await physics_frame
		if not released.is_empty():
			break
	system.natural_scale = 0.0
	_expect(not released.is_empty() and released[0].natural, "the snowpack lets go on its own at High danger")
	if not field.icefall_cells.is_empty():
		var serac: Object = system.release_serac(field.icefall_cells[0])
		_expect(serac != null and serac.kind == 3, "an icefall sheds a serac")
	for _f in range(3000):
		await physics_frame
		if not system.is_running():
			break
	_expect(not system.is_running(), "the avalanches come to rest")
	_expect(not system.is_caught(), "the summit stays out of their way")
	system.avalanche_released.disconnect(on_release)

	# --- Warning signs
	var sign_cell := -1
	for i in range(field.pack.size()):
		if field.pack[i] > 0.25 and field.slope[i] < 25.0 and field.snow[i] == 1:
			sign_cell = i
			break
	if sign_cell >= 0:
		_place(player, terrain, field.world_of(sign_cell))
		var before_signs: int = run.get_decisions_by_type("whumpf").size() + run.get_decisions_by_type("shooting_cracks").size()
		system.warning(sign_cell)
		var after_signs: int = run.get_decisions_by_type("whumpf").size() + run.get_decisions_by_type("shooting_cracks").size()
		_expect(after_signs == before_signs + 1, "a collapse or shooting cracks give warning")
		for _f in range(3000):
			await physics_frame
			if not system.is_running():
				break
		if system.is_caught():
			await _wait_free(system, run)

	# --- Snow pit
	var pit_cell := -1
	for i in range(field.slope.size()):
		if field.snow[i] == 1 and field.slope[i] < 12.0 and field.pack[i] > 0.0:
			pit_cell = i
			break
	if pit_cell >= 0 and _state_manager.is_run_active():
		_place(player, terrain, field.world_of(pit_cell))
		player.gear_state.add_item(_gear_item(_enums.GearType["SHOVEL_PROBE"], 1.0, 0.95))
		for _f in range(10):
			await physics_frame
		system.start_pit()
		_expect(system.pit_timer > 0.0, "with a shovel, the climber digs a pit")
		for _f in range(900):
			await physics_frame
			if system.pit_timer < 0.0:
				break
		var pits: Array = run.get_decisions_by_type("snow_pit")
		_expect(not pits.is_empty() and str(pits[0].get("details", {}).get("result", "")).begins_with("ECT"),
			"an extended column test reads the snowpack (%s)" % (str(pits[0].get("details", {}).get("result", "")) if not pits.is_empty() else "none"))
		player.gear_state.remove_item(_enums.GearType["SHOVEL_PROBE"])
		system.start_pit()
		_expect(system.pit_timer < 0.0, "without a shovel there is no pit")

	# --- A slope releases under the climber: caught, the airbag, out again
	var slope_cell := -1
	var best := 0.0
	for i in field.start_cells:
		var v: float = field.instability(i, 0.0)
		if field.slope[i] > 32.0 and field.slope[i] < 40.0 and v > best:
			best = v
			slope_cell = i
	_expect(slope_cell >= 0, "a loaded slope to stand on")
	if slope_cell >= 0 and _state_manager.is_run_active():
		player.gear_state.add_item(_gear_item(_enums.GearType["AIRBAG"], 1.0, 2.6))
		_place(player, terrain, field.world_of(slope_cell))
		for _f in range(5):
			await physics_frame
		var triggered := false
		system.trigger_scale = 2000.0
		for _f in range(900):
			await physics_frame
			if system.is_caught() or not run.get_incidents_by_type("avalanche_triggered").is_empty():
				triggered = true
				break
		system.trigger_scale = 0.0
		if not system.is_caught() and not triggered:
			# The hazard did not fire in time: release it by hand
			system.release(field.index_of(Vector2(player.global_position.x, player.global_position.z)), false)
		_expect(not run.get_incidents_by_type("avalanche_triggered").is_empty(), "the climber's weight releases the slope")
		_expect(system.is_caught(), "standing on the slab that broke, the climber goes with it")
		var y0: float = player.global_position.y
		_expect(player.current_state == _enums.PlayerMovementState["CAUGHT"], "caught: the movement state says so")
		Input.action_press("slide_initiate")
		await physics_frame
		await physics_frame
		Input.action_release("slide_initiate")
		await physics_frame
		_expect(system.airbag_deployed, "Space in the first seconds pulls the airbag")
		await physics_frame
		_expect(run.travel_mode == 4, "carried by the snow counts as out of control (mode %d)" % run.travel_mode)
		var carried := 0.0
		for _f in range(120):
			await physics_frame
			carried = maxf(carried, y0 - player.global_position.y)
		_expect(carried > 3.0, "the snow carries the climber down (%.0f m)" % carried)
		var final_depth: float = await _wait_free(system, run)
		_expect(final_depth < 1.0, "the airbag keeps the climber near the surface (%.2f m)" % final_depth)
		_expect(not run.get_incidents_by_type("avalanche_caught").is_empty(), "being caught is in the run's history")

	# --- Head under, no one digging: the air runs out
	if _state_manager.is_run_active():
		if burial_spot != Vector2.INF and flow != null:
			_place(player, terrain, burial_spot)
			system._catch(flow)
			system.burial_depth = 0.7
			system.air_pocket = false
			system._bury()
			# In case the debris here is shallower than asked
			system.burial_depth = 0.7
			Engine.time_scale = 8.0
			for _f in range(4000):
				await physics_frame
				if run.is_complete:
					break
			_expect(run.is_complete and run.outcome == _enums.ResolutionType["FATALITY"] and run.end_cause.contains("avalanche"),
				"buried with the head under and no one digging: the air runs out (%s)" % run.end_cause)
	Engine.time_scale = 1.0

	# --- Without a bulletin the system stays out of the way (tests and tools)
	if _state_manager.is_run_active():
		_state_manager.complete_run(_enums.ResolutionType["CLEAN_RETURN"], "test")
	await process_frame
	_state_manager.transition_to(int(states["POST_GAME"]))
	await process_frame
	_state_manager.transition_to(int(states["PLANNING"]))
	await process_frame
	var plain: Resource = (load("res://src/core/data/start_conditions.gd") as GDScript).create_moderate()
	plain.mountain_id = "north_face"
	_state_manager.start_run("north_face", plain)
	_state_manager.transition_to(int(states["DESCENT"]))
	for _i in range(30):
		await process_frame
	_expect(not system.active, "a run without a bulletin has no avalanches")
	_expect(not terrain.modified, "and starts on a fresh mountain")


## Wait until the climber is out of the snow (or the run ends); returns the
## deepest burial seen at the end
func _wait_free(system: Object, run: Object) -> float:
	var depth := 0.0
	for _f in range(6000):
		await physics_frame
		if system.is_buried():
			depth = system.burial_depth
			# Dig out so the test can go on
			system.dig_stroke()
		if not system.is_caught() or run.is_complete:
			break
	return depth


func _gear_item(type: int, condition: float, weight: float) -> Object:
	var gear_state: GDScript = load("res://src/core/data/gear_state.gd")
	return gear_state.GearItem.new(type, condition, weight)


func _place(player: CharacterBody3D, terrain: Object, p: Vector2) -> void:
	player.global_position = Vector3(p.x, terrain.get_height_at(Vector3(p.x, 0, p.y)) + 0.3, p.y)
	player.velocity = Vector3.ZERO


func _find_cell(terrain: Object, test: Callable) -> Object:
	for chunk in terrain.chunks.values():
		for column in chunk.cells:
			for cell in column:
				if test.call(cell):
					return cell
	return null


# =============================================================================
# HARNESS
# =============================================================================

func _expect(condition: bool, what: String) -> void:
	_checks += 1
	if condition:
		print("[test_avalanche] ok: %s" % what)
	else:
		print("[test_avalanche] FAILED: %s" % what)
		_failures.append(what)


func _finish(fatal: String) -> void:
	if fatal != "":
		_failures.append(fatal)
	Engine.time_scale = 1.0
	if _failures.is_empty():
		print("[test_avalanche] PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("[test_avalanche] FAIL: %d of %d: %s" % [_failures.size(), _checks, "; ".join(_failures)])
		quit(1)
