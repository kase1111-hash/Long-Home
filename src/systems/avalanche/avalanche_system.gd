class_name AvalancheSystem
extends Node
## Avalanches during a descent: triggering, warning signs, natural releases,
## the flow itself, being caught, buried and dug out.
##
## Triggering. Every step on an unstable slope (AvalancheField) loads the
## weak layer: the hazard per second grows with the square of the
## instability and with the load (a walker or a kicked step more than a
## skier, a crash or a hard landing most of all). Slab problems give warning
## first: a collapse ("whumpf") underfoot or cracks shooting out from the
## skis, and a collapse can release a steep slope nearby (remote trigger).
##
## Natural releases follow the danger (none at Low, several an hour at High)
## and the warmth (wet snow in the afternoon); icefalls shed seracs, most in
## the afternoon. Before the run, the last day's naturals have already run:
## crowns and debris are on the mountain to be read.
##
## The flow (AvalancheFlow) runs over the real terrain; when it stops, the
## bed it slid off and the debris it left are carved into the heightfield.
##
## Caught. The climber is carried with the snow. Space pulls the airbag (in
## the first seconds) or swims; pushing across the flow fights toward its
## edge. Trees, rocks and cliffs on the way hurt. As the snow slows, Space
## punches a hand up and makes an air pocket. Where it stops decides the
## burial: on the surface, partly buried (dig out), buried with the head under
## (dig before the air runs out), or deep, where only rescuers can help: a
## party that saw it, homing on a transceiver, or a slow probe line without.
##
## Snow pit (V, with a shovel): an extended column test reads the snowpack
## where you stand.

# =============================================================================
# CONSTANTS
# =============================================================================

## Release hazard per second at instability 1 (scaled by instability squared)
const TRIGGER_RATE := 0.012
## Collapses and shooting cracks per second at slab instability 1
const SIGN_RATE := 0.035
## A collapse can release a steep slope this far away (metres)
const REMOTE_REACH := 25.0
## Natural releases per game hour, by the day's highest danger (1-5)
const NATURAL_RATE: Array[float] = [0.0, 0.0, 0.15, 0.8, 3.0, 8.0]
## Serac falls per game hour from a glacier's icefalls in afternoon warmth
const ICEFALL_RATE := 0.6
## Slab area by size (m^2)
const SLAB_AREA: Array[float] = [0.0, 220.0, 1100.0, 4000.0, 10000.0]
## Parcels per avalanche (bigger slabs share them out)
const MAX_PARCELS := 220
const PRESIM_PARCELS := 70
## Simulation substep (seconds)
const SUBSTEP := 1.0 / 30.0
const MAX_FLOWS := 3
## Caught by moving snow this close (metres) and this fast (m/s)
const CATCH_RADIUS := 3.0
const CATCH_SPEED := 2.0

## Burial depth gained per second in moving snow, per 10 m/s of flow
const SINK_RATE := 0.32
## Depth shed per second while swimming hard
const SWIM_RATE := 0.45
## An inflated airbag rises in the moving snow (m/s of depth shed)
const AIRBAG_LIFT := 0.6
## Seconds after being caught to pull the airbag handle
const AIRBAG_WINDOW := 3.0
## Sideways speed fighting for the edge of the flow (m/s)
const ESCAPE_DRIFT := 2.2
## The snow is slowing: a last chance to make an air pocket (m/s)
const POCKET_SPEED := 6.0
## Burial: free by itself, partly buried, head under, beyond self-rescue (m)
const SURFACE_DEPTH := 0.15
const PARTIAL_DEPTH := 0.35
const HEAD_UNDER_DEPTH := 0.5
const DEEP_BURIAL := 1.0
## Game minutes of air under the snow, without and with an air pocket
const AIR_MINUTES := 15.0
const POCKET_AIR_MINUTES := 35.0
## Dig strokes per metre of snow above you (a free hand halves it)
const DIG_STROKES_PER_METRE := 40.0
## Real seconds before a deep burial is resolved
const DEEP_WAIT := 8.0
## Snow pit: real seconds to dig and test
const PIT_TIME := 25.0

# =============================================================================
# SIGNALS
# =============================================================================

signal avalanche_released(flow: AvalancheFlow)
signal avalanche_stopped(flow: AvalancheFlow)
signal climber_caught(flow: AvalancheFlow)
signal climber_buried(depth: float)
signal climber_freed()
signal warning_sign(kind: String)
signal pit_dug(result: String)

# =============================================================================
# STATE
# =============================================================================

## Tuning hooks (tests): multiply the trigger and natural rates
@export var trigger_scale: float = 1.0
@export var natural_scale: float = 1.0

var terrain_service: TerrainService = null
var player: PlayerController = null
var conditions: AvalancheConditions = null
var field: AvalancheField = null
var active: bool = false

var flows: Array[AvalancheFlow] = []
var _visuals: Dictionary = {}  # flow id -> AvalancheVisual
var _next_id: int = 1

## Caught and buried
var caught_flow: AvalancheFlow = null
var caught_time: float = 0.0
var burial_depth: float = 0.0
var airbag_deployed: bool = false
var air_pocket: bool = false
var buried: bool = false
var dig_progress: float = 0.0
var air_left: float = 0.0  # game minutes
var _deep_wait: float = 0.0
var _trauma_cooldown: float = 0.0
var _escape_dir: Vector2 = Vector2.ZERO

## Snow pit (seconds left, -1 when not digging)
var pit_timer: float = -1.0

## Storm loading during the run (instability multiplier)
var loading: float = 1.0
var _natural_clock: float = 0.0
var _icefall_clock: float = 0.0
var _signs_left: int = 12
var _cracks: Array[Node3D] = []
var _rng := RandomNumberGenerator.new()


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("AvalancheSystem", self)
	_rng.randomize()
	EventBus.descent_ready.connect(_on_descent_ready)
	EventBus.run_ended.connect(_on_run_ended)
	# After the climber's own physics step, so the snow places them last
	process_physics_priority = 11


func _on_descent_ready() -> void:
	_reset()
	var run := GameStateManager.current_run
	conditions = null
	if run != null and run.start_conditions != null:
		conditions = run.start_conditions.avalanche
	# The day runs as warm or cold as the bulletin's freezing level said
	var temperature := ServiceLocator.get_service("TemperatureSystem") as TemperatureSystem
	if temperature != null:
		temperature.base_temperature = AvalancheConditions.SEA_LEVEL_TEMPERATURE + (conditions.temperature_offset if conditions != null else 0.0)
	if conditions == null or not _resolve():
		active = false
		return
	var started := Time.get_ticks_msec()
	field = AvalancheField.build(terrain_service, conditions)
	_rng.seed = conditions.seed ^ 0x5A17
	active = true
	_place_recent_avalanches()
	if player != null and not player.landed.is_connected(_on_player_landed):
		player.landed.connect(_on_player_landed)
	print("[AvalancheSystem] %s danger (%s), %d start cells, %d icefall cells, ready in %d ms" % [
		AvalancheConditions.LEVEL_NAMES[conditions.get_max_danger()],
		"/".join(Array(conditions.danger).map(func(d: int) -> String: return str(d))),
		field.start_cells.size(), field.icefall_cells.size(), Time.get_ticks_msec() - started
	])


func _on_run_ended(_run: RunContext, _outcome: GameEnums.ResolutionType) -> void:
	_release_player()
	pit_timer = -1.0


func _reset() -> void:
	_release_player()
	flows.clear()
	for visual in _visuals.values():
		if is_instance_valid(visual):
			visual.queue_free()
	_visuals.clear()
	for crack in _cracks:
		if is_instance_valid(crack):
			crack.queue_free()
	_cracks.clear()
	caught_flow = null
	buried = false
	burial_depth = 0.0
	airbag_deployed = false
	air_pocket = false
	pit_timer = -1.0
	loading = 1.0
	_natural_clock = 0.0
	_icefall_clock = 0.0
	_signs_left = 12
	field = null
	active = false


func _resolve() -> bool:
	if not is_instance_valid(terrain_service):
		terrain_service = ServiceLocator.get_service("TerrainService") as TerrainService
	if not is_instance_valid(player):
		player = ServiceLocator.get_service("PlayerController") as PlayerController
	return terrain_service != null and player != null and player.is_inside_tree()


func _physics_process(delta: float) -> void:
	if not active or field == null:
		return
	if GameStateManager.current_state != GameEnums.GameState.DESCENT or not GameStateManager.is_run_active():
		return
	if not _resolve():
		return

	_update_loading(delta)
	_step_flows(delta)

	if caught_flow != null or buried:
		_update_caught(delta)
		return

	_check_caught()
	if caught_flow != null:
		return
	_update_pit(delta)
	_check_triggers(delta)
	_check_naturals(delta)


# =============================================================================
# CONDITIONS NOW
# =============================================================================

## How active the wet problems are now (0 in the cold, 1+ in afternoon warmth)
func wet_activity() -> float:
	var temperature := -8.0
	var system := ServiceLocator.get_service("TemperatureSystem") as TemperatureSystem
	if system != null:
		temperature = system.get_air_temperature()
	var hour := 12.0
	var time := ServiceLocator.get_service("TimeService") as TimeService
	if time != null:
		hour = time.current_time
	var sun := 1.0 if hour >= 10.0 and hour <= 18.0 else 0.25
	return clampf((temperature + 1.5) / 3.0, 0.0, 1.5) * sun


## Instability of the snowpack at a world point now (0-1)
func instability_at(p: Vector2) -> float:
	if field == null:
		return 0.0
	return clampf(field.instability(field.index_of(p), wet_activity()) * loading, 0.0, 1.0)


## Heavy snow during the run loads the slopes
func _update_loading(delta: float) -> void:
	var weather := ServiceLocator.get_service("WeatherService") as WeatherService
	if weather == null:
		return
	if weather.precipitation == WeatherService.PrecipitationType.HEAVY_SNOW:
		var game_hours := delta * GameEnums.TIME_SCALE / 3600.0
		loading = minf(loading + 0.15 * game_hours, 1.4)


# =============================================================================
# HUMAN TRIGGERS AND WARNING SIGNS
# =============================================================================

## Load the climber puts on the snowpack now (0 when it cannot)
func _load_factor() -> float:
	if player.held_by != null:
		return 0.0
	match player.current_state:
		GameEnums.PlayerMovementState.WALKING, GameEnums.PlayerMovementState.TRAVERSING:
			return 1.0
		GameEnums.PlayerMovementState.DOWNCLIMBING:
			return 1.1  # Kicking steps into the slope
		GameEnums.PlayerMovementState.SKIING:
			return 0.8 if player.get_current_speed() > 0.5 else 0.35
		GameEnums.PlayerMovementState.SLIDING:
			return 0.7
		GameEnums.PlayerMovementState.STANDING, GameEnums.PlayerMovementState.RESTING, GameEnums.PlayerMovementState.ARRESTED:
			return 0.3
	return 0.0


func _check_triggers(delta: float) -> void:
	var load := _load_factor()
	# Clinging to the face (downclimbing) loads the slope as much as standing on it
	if load <= 0.0 or (not player.is_on_floor() and not player.is_clinging()):
		return
	var pos := player.global_position
	var flat := Vector2(pos.x, pos.z)
	if not field.contains(flat):
		return
	var i := field.index_of(flat)
	if field.snow[i] == 0:
		return
	var wet := wet_activity()
	var inst := clampf(field.instability(i, wet) * loading, 0.0, 1.0)
	if inst > 0.0 and field.slope[i] >= AvalancheField.START_ZONE_SLOPE:
		var hazard := TRIGGER_RATE * trigger_scale * inst * inst * load
		if _rng.randf() < 1.0 - exp(-hazard * delta):
			release(i, false)
			return
	var pack := clampf(field.pack[i] * loading, 0.0, 1.0)
	if pack > 0.05 and _signs_left > 0:
		var sign_hazard := SIGN_RATE * trigger_scale * pack * pack * load
		if _rng.randf() < 1.0 - exp(-sign_hazard * delta):
			warning(i)


## A collapse underfoot or shooting cracks; a collapse may release a slope nearby
func warning(i: int) -> void:
	_signs_left -= 1
	var problem := field.pack_problem_at(i)
	var cracks := problem != null and problem.type == AvalancheConditions.ProblemType.WIND_SLAB
	var pos := player.global_position
	if cracks:
		player.say("Cracks shoot out across the snow from your feet.", 3.5)
		_spawn_cracks(pos)
		_play_at(ProceduralAudio.create_ice_crack_stream(), pos, -4.0, 1.4)
		EventBus.record_decision("shooting_cracks", {"position": pos})
		warning_sign.emit("cracks")
	else:
		player.say("Whumpf. The snowpack drops under you with a deep thud.", 3.5)
		_play_at(ProceduralAudio.create_snow_settle_stream(), pos, 2.0, 0.45)
		_shake(0.18)
		EventBus.record_decision("whumpf", {"position": pos})
		warning_sign.emit("whumpf")
	# A collapse travels: it can release a steep slope nearby
	if problem != null and problem.remote:
		var target := _remote_target(Vector2(pos.x, pos.z))
		if target >= 0 and _rng.randf() < 0.35 * field.instability(target, wet_activity()) * loading:
			release(target, false, true)


func _remote_target(flat: Vector2) -> int:
	var best := -1
	var best_value := 0.15
	var reach := int(ceil(REMOTE_REACH / AvalancheField.STEP))
	var centre := field.index_of(flat)
	var cx := centre % field.width
	var cz := centre / field.width
	var wet := wet_activity()
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var x := cx + dx
			var z := cz + dz
			if x < 0 or z < 0 or x >= field.width or z >= field.height:
				continue
			var n := z * field.width + x
			if field.slope[n] < AvalancheField.START_ZONE_SLOPE:
				continue
			if field.world_of(n).distance_to(flat) > REMOTE_REACH:
				continue
			var v := field.instability(n, wet)
			if v > best_value:
				best_value = v
				best = n
	return best


## A sudden load (a crash, a hard landing): a one-off chance to release
func shock(magnitude: float) -> void:
	if not active or field == null or caught_flow != null:
		return
	var pos := player.global_position
	var flat := Vector2(pos.x, pos.z)
	if not field.contains(flat):
		return
	var i := field.index_of(flat)
	if field.slope[i] < AvalancheField.START_ZONE_SLOPE:
		return
	var inst := clampf(field.instability(i, wet_activity()) * loading, 0.0, 1.0)
	if _rng.randf() < inst * clampf(magnitude / 6.0, 0.0, 1.0) * 0.5 * trigger_scale:
		release(i, false)


func _on_player_landed(impact: float) -> void:
	if impact > 3.0:
		shock(impact)


# =============================================================================
# NATURAL RELEASES
# =============================================================================

func _check_naturals(delta: float) -> void:
	var game_hours := delta * GameEnums.TIME_SCALE / 3600.0
	var wet := wet_activity()
	var rate := NATURAL_RATE[conditions.get_max_danger()] * natural_scale
	# Wet snow comes down in the warmth, whatever the morning rating said
	rate += 1.5 * maxf(wet - 0.5, 0.0) * natural_scale
	if flows.size() < MAX_FLOWS and _rng.randf() < 1.0 - exp(-rate * game_hours):
		var start := field.pick_start(_rng, wet)
		if start >= 0:
			release(start, true)
	if not field.icefall_cells.is_empty():
		var ice_rate := ICEFALL_RATE * (0.3 + clampf(wet, 0.0, 1.0)) * natural_scale
		if flows.size() < MAX_FLOWS and _rng.randf() < 1.0 - exp(-ice_rate * game_hours):
			release_serac(field.icefall_cells[_rng.randi() % field.icefall_cells.size()])


## The last day's naturals: run them to the end before the climber arrives,
## leaving crowns and debris to be read. Kept clear of the summit and camp.
func _place_recent_avalanches() -> void:
	var count := clampi(roundi(NATURAL_RATE[conditions.get_max_danger()] * 1.6), 0, 4)
	if conditions.new_snow_cm >= 30.0:
		count += 1
	if count == 0:
		return
	var started := Time.get_ticks_msec()
	var finished: Array[AvalancheFlow] = []
	var keep_clear: Array[Vector3] = [terrain_service.start_position, terrain_service.goal_position]
	var tries := 0
	while finished.size() < count and tries < count * 4:
		tries += 1
		var start := field.pick_start(_rng, 0.6)
		if start < 0:
			break
		var flow := _build_flow(start, true, PRESIM_PARCELS)
		if flow == null:
			continue
		var clear := true
		for point in flow.slab_points:
			for spot in keep_clear:
				if point.distance_to(Vector2(spot.x, spot.z)) < 40.0:
					clear = false
		if not clear:
			continue
		flow.run_to_end(terrain_service, 0.2)
		var near_camp := false
		for spot in keep_clear:
			if flow.debris_depth_at(Vector2(spot.x, spot.z)) > 0.05:
				near_camp = true
		if near_camp:
			continue
		finished.append(flow)
	if finished.is_empty():
		return
	_apply_terrain(finished)
	for flow in finished:
		var visual := AvalancheVisual.new()
		visual.name = "RecentAvalanche%d" % flow.id
		add_child(visual)
		visual.build_static(flow, terrain_service)
		_visuals[flow.id] = visual
	print("[AvalancheSystem] %d recent avalanches on the mountain (%d ms)" % [finished.size(), Time.get_ticks_msec() - started])


# =============================================================================
# RELEASE
# =============================================================================

## Release the slope at a field cell. Returns the flow (null when nothing went)
func release(i: int, natural: bool, remote: bool = false) -> AvalancheFlow:
	var flow := _build_flow(i, natural, MAX_PARCELS)
	if flow == null:
		return null
	flows.append(flow)
	var visual := AvalancheVisual.new()
	visual.name = "Avalanche%d" % flow.id
	add_child(visual)
	visual.build(flow, terrain_service)
	_visuals[flow.id] = visual

	var pos := player.global_position
	var distance := Vector2(pos.x, pos.z).distance_to(Vector2(flow.origin.x, flow.origin.z))
	if natural:
		if distance < 350.0:
			EventBus.record_incident("avalanche_natural", {"size": flow.size, "distance": distance, "kind": AvalancheFlow.KIND_NAMES[flow.kind]})
			if distance < 150.0:
				player.say("A roar above. The slope is coming down.", 3.0)
			else:
				player.say("A distant roar. An avalanche runs somewhere on the mountain.", 3.0)
			_shake(0.12 if distance < 150.0 else 0.04)
	else:
		EventBus.record_incident("avalanche_triggered", {
			"size": flow.size,
			"remote": remote,
			"problem": AvalancheConditions.PROBLEM_NAMES.get(flow.problem_type, "loose"),
			"slope": field.slope[i],
		})
		if remote:
			player.say("The collapse runs away from you. A slope beside you breaks.", 3.5)
		elif flow.kind == AvalancheFlow.Kind.SLAB:
			player.say("A crack shoots across the slope above you. Everything moves.", 3.5)
		else:
			player.say("The snow around your feet starts to slide.", 3.0)
		_shake(0.35)
	EventBus.emit_camera_signal(GameEnums.CameraSignal.CRITICAL_MOMENT, 1.0)

	# Standing on the slab that broke: you go with it
	var flat := Vector2(pos.x, pos.z)
	if caught_flow == null and player.held_by == null:
		for point in flow.slab_points:
			if point.distance_to(flat) < AvalancheField.STEP * 0.9:
				_catch(flow)
				break
	avalanche_released.emit(flow)
	return flow


## A serac breaks off an icefall
func release_serac(i: int) -> AvalancheFlow:
	var p2 := field.world_of(i)
	var flow := AvalancheFlow.new()
	flow.id = _next_id
	_next_id += 1
	flow.natural = true
	flow.configure(AvalancheFlow.Kind.ICE, 2 if _rng.randf() < 0.4 else 1, 1.5, _rng.randi())
	flow.deposit_origin = Vector2(terrain_service.terrain_bounds_min.x, terrain_service.terrain_bounds_min.z)
	var down := field.downhill[i].normalized()
	var across := Vector2(-down.y, down.x)
	var blocks := 24 if flow.size == 1 else 50
	for k in range(blocks):
		var q := p2 + across * _rng.randf_range(-5.0, 5.0) + down * _rng.randf_range(-3.0, 3.0)
		var y := terrain_service.get_height_at(Vector3(q.x, 0.0, q.y))
		flow.add_parcel(Vector3(q.x, y + AvalancheFlow.FLOW_LIFT, q.y), _rng.randf_range(1.5, 4.0), Vector3(down.x, 0.0, down.y) * 2.0)
	flow.origin = Vector3(p2.x, terrain_service.get_height_at(Vector3(p2.x, 0.0, p2.y)), p2.y)
	flow.slab_points.append(p2)
	flows.append(flow)
	var visual := AvalancheVisual.new()
	visual.name = "Serac%d" % flow.id
	add_child(visual)
	visual.build(flow, terrain_service)
	_visuals[flow.id] = visual
	var pos := player.global_position
	var distance := Vector2(pos.x, pos.z).distance_to(p2)
	if distance < 350.0:
		EventBus.record_incident("serac_fall", {"distance": distance, "size": flow.size})
		player.say("A crack like a gunshot from the icefall. Ice is falling.", 3.0)
	avalanche_released.emit(flow)
	return flow


## Build the flow for a release at field cell i (null when the snow holds)
func _build_flow(i: int, natural: bool, max_parcels: int) -> AvalancheFlow:
	var wet := wet_activity() if active else 0.6
	var problem := field.problem_now(i, wet)
	if problem == null:
		problem = field.pack_problem_at(i)
	if problem == null:
		return null
	var flow := AvalancheFlow.new()
	flow.id = _next_id
	_next_id += 1
	flow.natural = natural
	flow.problem_type = problem.type
	var size := problem.size
	if not natural and size > 1 and _rng.randf() < 0.4:
		size -= 1  # Most human-triggered slides are smaller than the worst case
	var kind := AvalancheFlow.Kind.SLAB
	if problem.type == AvalancheConditions.ProblemType.LOOSE_DRY:
		kind = AvalancheFlow.Kind.LOOSE
	elif problem.is_wet():
		kind = AvalancheFlow.Kind.WET
	var depth := problem.depth * _rng.randf_range(0.8, 1.2)
	flow.configure(kind, size, depth, _rng.randi())
	flow.deposit_origin = Vector2(terrain_service.terrain_bounds_min.x, terrain_service.terrain_bounds_min.z)

	var cells := PackedInt32Array()
	if problem.is_slab():
		cells = field.slab_area(i, SLAB_AREA[size] * _rng.randf_range(0.6, 1.4), wet)
	else:
		# Loose snow starts at a point and fans out, gathering snow as it goes
		cells.append(i)
		var cx := i % field.width
		var cz := i / field.width
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var n := (cz + dz) * field.width + (cx + dx)
				if (dx != 0 or dz != 0) and n >= 0 and n < field.slope.size() and field.snow[n] == 1 and field.slope[n] >= AvalancheField.MIN_RELEASE_SLOPE:
					cells.append(n)
	if cells.is_empty():
		return null

	# Parcels: one per cell, or shared out on big slabs
	var stride := maxi(1, int(ceil(float(cells.size()) / float(max_parcels))))
	var cell_volume := AvalancheField.STEP * AvalancheField.STEP * depth
	var top := Vector3(0.0, -INF, 0.0)
	for k in range(cells.size()):
		var c := cells[k]
		var p2 := field.world_of(c)
		flow.slab_points.append(p2)
		var y := terrain_service.get_height_at(Vector3(p2.x, 0.0, p2.y))
		if y > top.y:
			top = Vector3(p2.x, y, p2.y)
		if k % stride != 0:
			continue
		var jitter := Vector2(_rng.randf_range(-1.2, 1.2), _rng.randf_range(-1.2, 1.2))
		var q := p2 + jitter
		var qy := terrain_service.get_height_at(Vector3(q.x, 0.0, q.y))
		var down := field.downhill[c]
		var share := mini(stride, cells.size() - k)
		flow.add_parcel(Vector3(q.x, qy + AvalancheFlow.FLOW_LIFT, q.y), cell_volume * float(share), Vector3(down.x, 0.0, down.y) * 0.5)
	flow.origin = top
	if problem.is_slab():
		for c in field.crown_of(cells):
			flow.crown_points.append(field.world_of(c))
			flow.crown_downhill.append(field.downhill[c].normalized())
	return flow


# =============================================================================
# FLOWS
# =============================================================================

func _step_flows(delta: float) -> void:
	if flows.is_empty():
		return
	var steps := maxi(1, int(ceil(delta / SUBSTEP)))
	var dt := delta / float(steps)
	var done: Array[AvalancheFlow] = []
	for flow in flows:
		for _s in range(steps):
			flow.step(dt, terrain_service)
		var visual: AvalancheVisual = _visuals.get(flow.id)
		if visual != null:
			visual.update(flow, delta)
		if flow.finished:
			done.append(flow)
	for flow in done:
		flows.erase(flow)
		_finish_flow(flow)


## The snow has stopped: carve the bed and the debris, settle the visuals
func _finish_flow(flow: AvalancheFlow) -> void:
	_apply_terrain([flow])
	var visual: AvalancheVisual = _visuals.get(flow.id)
	if visual != null:
		visual.settle(flow, terrain_service)
	EventBus.record_decision("avalanche_stopped", {
		"size": flow.size,
		"runout_angle": flow.runout_angle(),
		"released": flow.released_volume,
		"entrained": flow.entrained_volume,
	})
	avalanche_stopped.emit(flow)
	if flow == caught_flow:
		_bury()


## One terrain edit for the beds and the debris of finished flows: the bed
## a slab slid off is lowered by the slab's thickness, the debris raised
## where it stopped
func _apply_terrain(finished: Array) -> void:
	var deltas := {}  # vertex key -> metres
	var debris_at := {}  # vertex key -> metres of debris
	var bed_keys := {}
	for f in finished:
		var flow: AvalancheFlow = f
		flow.smooth_deposit()
		flow.smooth_deposit()
		if flow.kind == AvalancheFlow.Kind.SLAB or flow.kind == AvalancheFlow.Kind.WET:
			var nodes := {}
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for point in flow.slab_points:
				nodes[field.index_of(point)] = true
				lo = Vector2(minf(lo.x, point.x), minf(lo.y, point.y))
				hi = Vector2(maxf(hi.x, point.x), maxf(hi.y, point.y))
			var k_lo := terrain_service.vertex_key(lo - Vector2.ONE * AvalancheField.STEP)
			var k_hi := terrain_service.vertex_key(hi + Vector2.ONE * AvalancheField.STEP)
			for kz in range(k_lo.y, k_hi.y + 1):
				for kx in range(k_lo.x, k_hi.x + 1):
					var key := Vector2i(kx, kz)
					if nodes.has(field.index_of(terrain_service.vertex_position(key))):
						deltas[key] = float(deltas.get(key, 0.0)) - flow.slab_depth
						bed_keys[key] = true
		for k in flow.deposit:
			var depth := flow.debris_depth(k)
			if depth < AvalancheFlow.MIN_DEBRIS:
				continue
			var key := terrain_service.vertex_key(flow.deposit_point(k))
			deltas[key] = float(deltas.get(key, 0.0)) + depth
			debris_at[key] = float(debris_at.get(key, 0.0)) + depth
	var terrain := terrain_service
	var mark := func(cell: TerrainCell, _delta: float) -> void:
		var key := terrain.vertex_key(Vector2(cell.position.x, cell.position.z))
		if debris_at.has(key):
			cell.debris_depth += float(debris_at[key])
		elif bed_keys.has(key):
			cell.avalanche_bed = true
	terrain_service.apply_height_deltas(deltas, mark, "Avalanche", true)


# =============================================================================
# CAUGHT
# =============================================================================

func _check_caught() -> void:
	if flows.is_empty() or player.held_by != null:
		return
	var pos := player.global_position
	for flow in flows:
		var here: Dictionary = flow.flow_at(pos, CATCH_RADIUS)
		if int(here.count) >= 2 and (here.velocity as Vector3).length() > CATCH_SPEED:
			if player.current_state == GameEnums.PlayerMovementState.ROPING:
				# The anchor holds; the snow pours over you
				player.say("The snow pours over you. The anchor holds.", 3.0)
				player._apply_impact_injury(0.2, (here.velocity as Vector3).length(), "avalanche", false)
				return
			_catch(flow)
			return


func _catch(flow: AvalancheFlow) -> void:
	caught_flow = flow
	caught_time = 0.0
	burial_depth = 0.1
	air_pocket = false
	buried = false
	_trauma_cooldown = 0.5
	_escape_dir = Vector2.ZERO
	pit_timer = -1.0
	if player.current_state == GameEnums.PlayerMovementState.ROPING:
		var rope := ServiceLocator.get_service("RopeService") as RopeService
		if rope != null:
			rope.stop_rope_work()
	# Skis are ripped off in the tumble
	if player.is_on_skis():
		player.set_footwear(GameEnums.Footwear.BOOTS)
	player.held_by = self
	player.velocity = Vector3.ZERO
	player.change_state(GameEnums.PlayerMovementState.CAUGHT)
	var has_airbag := player.gear_state != null and player.gear_state.has_item(GameEnums.GearType.AIRBAG)
	player.say("You're caught. Swim (Space)%s!" % (" and pull the airbag" if has_airbag else ""), 3.0)
	EventBus.record_incident("avalanche_caught", {"size": flow.size, "natural": flow.natural})
	climber_caught.emit(flow)


func _update_caught(delta: float) -> void:
	var fatal := ServiceLocator.get_service("FatalEventManager") as FatalEventManager
	if fatal != null and fatal.is_in_fatal_sequence():
		return
	if GameStateManager.current_run != null:
		GameStateManager.current_run.travel_mode = RouteMetrics.MODE_ADRIFT
	if buried:
		_update_buried(delta)
		return
	caught_time += delta
	_trauma_cooldown -= delta
	var pos := player.global_position
	var flat := Vector2(pos.x, pos.z)
	var here: Dictionary = caught_flow.flow_at(pos, 6.0)
	var flow_velocity: Vector3 = here.velocity
	var speed := flow_velocity.length()
	var swim := player.input_handler.is_action_just_pressed("slide_initiate")
	var has_airbag := player.gear_state != null and player.gear_state.has_item(GameEnums.GearType.AIRBAG)

	# The airbag handle, then swimming
	if swim and has_airbag and not airbag_deployed and caught_time <= AIRBAG_WINDOW:
		airbag_deployed = true
		swim = false
		player.say("You pull the handle. The airbag bangs open.", 2.5)
		EventBus.record_decision("airbag_deployed", {})
	if swim and speed < POCKET_SPEED and not air_pocket and caught_time > 0.8:
		air_pocket = true
		player.say("You thrust a hand up and cup the other over your face.", 3.0)
		EventBus.record_decision("air_pocket", {})
	elif swim:
		burial_depth = maxf(0.0, burial_depth - SWIM_RATE * 0.35)
		player.add_fatigue(0.01)

	# Sinking in the moving snow; an airbag rises
	burial_depth += SINK_RATE * (speed / 10.0) * delta * _rng.randf_range(0.5, 1.5)
	if airbag_deployed:
		burial_depth = maxf(0.0, burial_depth - AIRBAG_LIFT * delta)
	burial_depth = clampf(burial_depth, 0.0, 3.0)

	# Fight across the flow toward its edge
	var push := player.movement.get_input_direction_world()
	var drift := Vector3.ZERO
	if push != Vector3.ZERO and speed > 0.5:
		var along := flow_velocity / speed
		var across := push - along * push.dot(along)
		if across.length() > 0.3:
			drift = across.normalized() * ESCAPE_DRIFT * (0.5 if burial_depth > 0.6 else 1.0)
	var move := flow_velocity + drift
	if int(here.count) == 0:
		# Out of the moving snow: thrown clear at the edge
		_free("You claw out at the edge of the slide.", true)
		return
	var next := pos + move * delta
	if not terrain_service.has_terrain_at(next):
		next = pos  # The snow piles up at the edge of the world, and you with it
	next.y = terrain_service.get_height_at(next) + AvalancheFlow.FLOW_LIFT - minf(burial_depth, 1.2) * 0.5
	player.global_position = next
	player.velocity = Vector3.ZERO

	# What the snow carries you into
	if _trauma_cooldown <= 0.0 and speed > 6.0:
		_check_trauma(next, speed)
	if player.body_state != null:
		player.body_state.cold_exposure = minf(1.0, player.body_state.cold_exposure + 0.002 * delta)


func _check_trauma(pos: Vector3, speed: float) -> void:
	var scatter := terrain_service.scatter
	if scatter != null:
		for obj in scatter.get_objects_near(pos, 1.6):
			if obj.collider_radius <= 0.0:
				continue
			_trauma_cooldown = 1.0
			var kind := obj.get_kind_name()
			var serious := speed > 11.0
			player._apply_impact_injury(clampf(0.25 + (speed - 6.0) / 15.0, 0.2, 0.9), speed, kind, serious)
			player.say("The snow slams you into a %s." % ("rock" if kind == "boulder" or kind == "rock" else "tree"), 2.5)
			_shake(0.3)
			return
	var cell := terrain_service.get_cell_at(pos)
	if cell != null and cell.is_cliff and speed > 9.0 and _rng.randf() < 0.4:
		_trauma_cooldown = 1.5
		player._apply_landing_injury(clampf(0.3 + (speed - 9.0) / 20.0, 0.3, 0.9), speed)
		player.say("Over a rock band. You hit hard.", 2.5)
		_shake(0.35)


## The snow stopped with the climber in it: how deep?
func _bury() -> void:
	var pos := player.global_position
	var flat := Vector2(pos.x, pos.z)
	var debris := caught_flow.debris_depth_at(flat)
	var depth := minf(burial_depth, debris + 0.1)
	caught_flow = null
	burial_depth = depth
	var ground := terrain_service.get_height_at(pos)
	if depth < SURFACE_DEPTH:
		player.global_position = Vector3(pos.x, ground + 0.1, pos.z)
		_free("The snow stops. You are on top of the debris.", false)
		return
	buried = true
	dig_progress = 0.0
	_deep_wait = 0.0
	air_left = POCKET_AIR_MINUTES if air_pocket else AIR_MINUTES
	player.global_position = Vector3(pos.x, ground - depth + 0.9, pos.z)
	EventBus.record_incident("avalanche_burial", {"depth": depth, "air_pocket": air_pocket, "airbag": airbag_deployed})
	climber_buried.emit(depth)
	if depth < PARTIAL_DEPTH:
		player.say("Buried to the waist and set like concrete. Dig (Space)!", 3.0)
	elif depth < DEEP_BURIAL:
		if depth >= HEAD_UNDER_DEPTH:
			player.say("Dark, and the snow is setting. Dig toward the light (Space), and keep your breath.", 4.0)
		else:
			player.say("Buried to the chest. Your face is clear. Dig (Space)!", 3.0)
	else:
		player.say("Buried deep. You cannot move a finger.", 4.0)


func _update_buried(delta: float) -> void:
	var game_minutes := delta * GameEnums.TIME_SCALE / 60.0
	if player.body_state != null:
		player.body_state.cold_exposure = minf(1.0, player.body_state.cold_exposure + 0.003 * delta)
	if burial_depth >= DEEP_BURIAL:
		_deep_wait += delta
		if _deep_wait >= DEEP_WAIT:
			_resolve_deep_burial()
		return
	if burial_depth >= HEAD_UNDER_DEPTH:
		air_left -= game_minutes
		if air_left <= 0.0:
			_asphyxia()
			return
	if player.input_handler.is_action_just_pressed("slide_initiate") or player.input_handler.is_action_just_pressed("probe"):
		dig_stroke()


## One stroke of digging yourself out
func dig_stroke() -> void:
	if not buried:
		return
	var strokes := maxf(burial_depth * DIG_STROKES_PER_METRE, 4.0)
	if air_pocket:
		strokes *= 0.5  # A hand already up
	if player.gear_state != null and player.gear_state.has_item(GameEnums.GearType.SHOVEL_PROBE) and burial_depth < HEAD_UNDER_DEPTH:
		strokes *= 0.7  # Arms free enough to reach the shovel
	dig_progress = minf(1.0, dig_progress + 1.0 / strokes)
	player.add_fatigue(0.004)
	if dig_progress >= 1.0:
		var pos := player.global_position
		player.global_position = Vector3(pos.x, terrain_service.get_height_at(pos) + 0.1, pos.z)
		EventBus.record_decision("dug_out", {"depth": burial_depth})
		_free("You drag yourself out of the debris.", false)


## Deep burial: only rescuers can help, and only if someone saw it
func _resolve_deep_burial() -> void:
	var pos := player.global_position
	var witnessed_chance := 0.2
	if terrain_service.corridor.size() >= 2:
		var corridor_distance := INF
		for point in terrain_service.corridor:
			corridor_distance = minf(corridor_distance, Vector2(point.x, point.z).distance_to(Vector2(pos.x, pos.z)))
		if corridor_distance < 60.0:
			witnessed_chance = 0.5  # Other parties on the normal route
	var witnessed := _rng.randf() < witnessed_chance
	var transceiver := player.gear_state != null and player.gear_state.has_item(GameEnums.GearType.TRANSCEIVER)
	if not witnessed:
		_asphyxia()
		return
	var minutes := _rng.randf_range(12.0, 25.0) if transceiver else _rng.randf_range(45.0, 120.0)
	var survival := burial_survival(minutes, air_pocket)
	if _rng.randf() < survival:
		buried = false
		_release_player()
		var how := "homing on your transceiver" if transceiver else "with a probe line"
		EventBus.record_decision("avalanche_rescue", {"minutes": minutes, "transceiver": transceiver})
		GameStateManager.complete_run(GameEnums.ResolutionType.RESCUE, "Dug out of avalanche debris after %d minutes by a party %s" % [roundi(minutes), how])
	else:
		_asphyxia()


## Survival against burial time (game minutes): the curve from avalanche
## burial statistics. Most survive the first quarter hour; asphyxia takes
## most of the rest by 35 minutes, unless an air pocket buys time.
static func burial_survival(minutes: float, pocket: bool) -> float:
	if minutes <= 18.0:
		return lerpf(0.95, 0.91, minutes / 18.0)
	if minutes <= 35.0:
		return lerpf(0.91, 0.6 if pocket else 0.34, (minutes - 18.0) / 17.0)
	if minutes <= 90.0:
		return lerpf(0.6 if pocket else 0.34, 0.4 if pocket else 0.07, (minutes - 35.0) / 55.0)
	return lerpf(0.4 if pocket else 0.07, 0.03, clampf((minutes - 90.0) / 60.0, 0.0, 1.0))


func _asphyxia() -> void:
	buried = false
	var pos := player.global_position
	EventBus.record_incident("avalanche_fatal", {"depth": burial_depth})
	var fatal := ServiceLocator.get_service("FatalEventManager") as FatalEventManager
	if fatal != null:
		fatal.trigger_avalanche(pos)
	else:
		_release_player()
		GameStateManager.complete_run(GameEnums.ResolutionType.FATALITY, "Buried in avalanche debris")


func _free(message: String, at_edge: bool) -> void:
	caught_flow = null
	buried = false
	burial_depth = 0.0
	_release_player()
	player.say(message, 3.0)
	var next := PlayerStateMachine._back_on_feet(player)
	player.change_state(next)
	EventBus.record_decision("avalanche_survived", {"edge": at_edge, "airbag": airbag_deployed})
	climber_freed.emit()


func _release_player() -> void:
	if is_instance_valid(player) and player.held_by == self:
		player.held_by = null
		player.velocity = Vector3.ZERO


# =============================================================================
# SNOW PIT
# =============================================================================

func _update_pit(delta: float) -> void:
	if pit_timer >= 0.0:
		if player.current_state != GameEnums.PlayerMovementState.STANDING or player.input_handler.move_input.length() > 0.5:
			pit_timer = -1.0
			player.say("You leave the pit half dug.", 2.0)
			return
		pit_timer -= delta
		if pit_timer < 0.0:
			snow_pit_result()
		return
	if player.input_handler.is_action_just_pressed("snow_pit"):
		start_pit()


func start_pit() -> void:
	if player.gear_state == null or not player.gear_state.has_item(GameEnums.GearType.SHOVEL_PROBE):
		player.say("You need a shovel to dig a pit.", 2.0)
		return
	if player.current_state != GameEnums.PlayerMovementState.STANDING:
		player.say("Stand still on the snow to dig a pit.", 2.0)
		return
	var cell := player.current_cell
	if cell == null or not TractionModel.is_snow(cell.surface_type):
		player.say("No snow here to test.", 2.0)
		return
	pit_timer = PIT_TIME
	player.say("You dig a pit and isolate a column (stand still).", 2.5)


## The extended column test where the climber stands: taps to fracture,
## and whether the crack runs across the column
func snow_pit_result() -> String:
	pit_timer = -1.0
	var pos := player.global_position
	var i := field.index_of(Vector2(pos.x, pos.z))
	var problem := field.pack_problem_at(i)
	var value := clampf(field.pack[i] * loading, 0.0, 1.0)
	var wet_problem := field.problem_now(i, wet_activity())
	var text := ""
	if problem == null:
		problem = field.problem_now(i, 0.0)
		value = clampf(field.dry[i], 0.0, 1.0)
	if problem == null or value < 0.12:
		text = "ECTX. Nothing fractures: the snowpack is well bonded here."
	else:
		var depth_cm := roundi(problem.depth * 100.0)
		if value > 0.55:
			text = "ECTP %d. The column fails and the crack runs clean across, %d cm down. Unstable." % [clampi(roundi(11.0 - value * 10.0), 1, 10), depth_cm]
		elif value > 0.35:
			text = "ECTP %d. It propagates, with effort, on a layer %d cm down. Suspect." % [clampi(roundi(28.0 - value * 30.0), 11, 22), depth_cm]
		else:
			text = "ECTN %d. A layer %d cm down fractures but does not propagate." % [clampi(roundi(30.0 - value * 30.0), 12, 30), depth_cm]
	if wet_problem != null and wet_problem.is_wet() and wet_activity() > 0.5:
		text += " The surface snow is wet and weakening."
	player.say(text, 6.0)
	EventBus.record_decision("snow_pit", {"result": text, "instability": value})
	pit_dug.emit(text)
	return text


# =============================================================================
# EFFECTS
# =============================================================================

func _shake(amount: float) -> void:
	var camera := player.camera_pivot as PlayerCamera
	if camera != null:
		camera.add_shake(amount)


func _play_at(stream: AudioStream, pos: Vector3, volume_db: float, pitch: float) -> void:
	var sound := AudioStreamPlayer3D.new()
	sound.stream = stream
	sound.volume_db = volume_db
	sound.pitch_scale = pitch
	sound.unit_size = 12.0
	add_child(sound)
	sound.global_position = pos
	sound.play()
	sound.finished.connect(sound.queue_free)


## Dark crack lines racing out across the snow from the climber
func _spawn_cracks(origin: Vector3) -> void:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var cell := terrain_service.get_cell_at(origin)
	var down := Vector2(cell.slope_direction.x, cell.slope_direction.z).normalized() if cell != null else Vector2.DOWN
	if down.length_squared() < 0.01:
		down = Vector2.DOWN
	var across := Vector2(-down.y, down.x)
	for branch in range(3):
		var dir := (across * (1.0 if branch % 2 == 0 else -1.0) + down * _rng.randf_range(-0.4, 0.4)).normalized()
		var p := Vector2(origin.x, origin.z)
		var length := _rng.randf_range(8.0, 18.0)
		var travelled := 0.0
		while travelled < length:
			dir = dir.rotated(_rng.randf_range(-0.35, 0.35)).normalized()
			var q := p + dir * 1.0
			var side := Vector2(-dir.y, dir.x) * 0.04
			var a := Vector3(p.x, terrain_service.get_height_at(Vector3(p.x, 0.0, p.y)) + 0.03, p.y)
			var b := Vector3(q.x, terrain_service.get_height_at(Vector3(q.x, 0.0, q.y)) + 0.03, q.y)
			var s3 := Vector3(side.x, 0.0, side.y)
			verts.append_array([a - s3, b - s3, b + s3, a - s3, b + s3, a + s3])
			p = q
			travelled += 1.0
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.22, 0.27, 0.34)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var instance := MeshInstance3D.new()
	instance.name = "ShootingCracks"
	instance.mesh = mesh
	instance.material_override = material
	add_child(instance)
	_cracks.append(instance)


# =============================================================================
# QUERIES
# =============================================================================

func is_caught() -> bool:
	return caught_flow != null or buried


func is_buried() -> bool:
	return buried


func is_running() -> bool:
	return not flows.is_empty()


## HUD activity text ("" when nothing avalanche-related is happening)
func get_activity_text() -> String:
	if buried:
		if burial_depth >= DEEP_BURIAL:
			return "Buried deep"
		var text := "Buried, digging %d%%" % roundi(dig_progress * 100.0)
		if burial_depth >= HEAD_UNDER_DEPTH:
			text += " (air: %d min)" % maxi(0, roundi(air_left))
		return text
	if caught_flow != null:
		return "Caught in an avalanche"
	if pit_timer >= 0.0:
		return "Digging a snow pit %d%%" % roundi((1.0 - pit_timer / PIT_TIME) * 100.0)
	return ""


# =============================================================================
# VISUALS
# =============================================================================

## Powder cloud, tumbling blocks, the crown wall and the roar of one avalanche
class AvalancheVisual extends Node3D:
	const BLOCKS_PER_PARCEL := 3
	const MAX_BLOCKS := 480

	var cloud: CPUParticles3D = null
	var blocks: MultiMeshInstance3D = null
	var roar: AudioStreamPlayer3D = null
	## Each block follows a parcel at an offset, with its own size and spin
	var block_parcel: PackedInt32Array = PackedInt32Array()
	var block_offset: PackedVector3Array = PackedVector3Array()
	var block_scale: PackedFloat32Array = PackedFloat32Array()
	var spin: PackedVector3Array = PackedVector3Array()
	var time: float = 0.0
	var _emit_timer: float = 0.0

	func build(flow: AvalancheFlow, terrain: TerrainService) -> void:
		_build_crown(flow, terrain)
		_build_blocks(flow)
		if flow.kind != AvalancheFlow.Kind.ICE:
			_build_cloud(flow)
		roar = AudioStreamPlayer3D.new()
		roar.stream = ProceduralAudio.create_slide_snow_stream(4.0)
		roar.volume_db = 6.0
		roar.unit_size = 40.0
		roar.pitch_scale = 0.55
		add_child(roar)
		roar.global_position = flow.origin
		roar.play()

	## A finished avalanche seen later: crown and settled debris blocks only
	func build_static(flow: AvalancheFlow, terrain: TerrainService) -> void:
		_build_crown(flow, terrain)
		_build_blocks(flow)
		settle(flow, terrain)

	func update(flow: AvalancheFlow, delta: float) -> void:
		time += delta
		var front: Dictionary = flow.front()
		var speed := (front.velocity as Vector3).length()
		if cloud != null:
			_emit_timer -= delta
			var fast := 0
			if _emit_timer <= 0.0:
				_emit_timer = 0.1
				fast = _update_emission(flow)
				cloud.emitting = fast > 0 and speed > 4.0 and not flow.finished
		if roar != null:
			roar.global_position = front.position
			if not roar.playing and speed > 3.0 and not flow.finished:
				roar.play()
		if blocks != null:
			var mm := blocks.multimesh
			for k in range(block_parcel.size()):
				var i := block_parcel[k]
				if flow.moving[i] == 0:
					continue
				var b := Basis.from_euler(spin[k] * time).scaled(Vector3.ONE * block_scale[k])
				var p := flow.positions[i] + block_offset[k]
				mm.set_instance_transform(k, Transform3D(b, p))

	## Blocks come to rest on the new debris surface
	func settle(flow: AvalancheFlow, terrain: TerrainService) -> void:
		if cloud != null:
			cloud.emitting = false
		if blocks != null:
			var mm := blocks.multimesh
			for k in range(block_parcel.size()):
				var p := flow.positions[block_parcel[k]] + block_offset[k] * 1.6
				p.y = terrain.get_height_at(p) + 0.12 * block_scale[k]
				var b := Basis.from_euler(spin[k] * 3.0).scaled(Vector3.ONE * block_scale[k])
				mm.set_instance_transform(k, Transform3D(b, p))

	## Powder rises off the fast-moving snow, not one point; returns how many
	## places it rises from (0: the cloud stops)
	func _update_emission(flow: AvalancheFlow) -> int:
		var points := PackedVector3Array()
		var origin := cloud.global_position
		var step := maxi(1, flow.positions.size() / 48)
		for i in range(0, flow.positions.size(), step):
			if flow.moving[i] == 1 and flow.velocities[i].length() > 4.0:
				points.append(flow.positions[i] - origin + Vector3(0.0, 1.2, 0.0))
		if not points.is_empty():
			cloud.emission_points = points
		return points.size()

	func _build_blocks(flow: AvalancheFlow) -> void:
		if flow.positions.is_empty():
			return
		var per_parcel := clampi(MAX_BLOCKS / flow.positions.size(), 1, BLOCKS_PER_PARCEL)
		var rng := RandomNumberGenerator.new()
		rng.seed = flow.id * 7919
		var ice := flow.kind == AvalancheFlow.Kind.ICE
		for i in range(flow.positions.size()):
			for _b in range(per_parcel):
				if block_parcel.size() >= MAX_BLOCKS:
					break
				block_parcel.append(i)
				block_offset.append(Vector3(rng.randf_range(-1.3, 1.3), rng.randf_range(-0.2, 0.4), rng.randf_range(-1.3, 1.3)))
				block_scale.append(rng.randf_range(0.6, 1.6) * (1.6 if ice else 1.0))
				spin.append(Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(-3.0, 3.0), rng.randf_range(-3.0, 3.0)))
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.75, 0.5, 0.6)
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.72, 0.84, 0.95) if ice else Color(0.94, 0.96, 0.99)
		material.roughness = 0.4 if ice else 0.95
		mesh.material = material
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = block_parcel.size()
		for k in range(block_parcel.size()):
			var b := Basis.from_euler(spin[k]).scaled(Vector3.ONE * block_scale[k])
			mm.set_instance_transform(k, Transform3D(b, flow.positions[block_parcel[k]] + block_offset[k]))
		blocks = MultiMeshInstance3D.new()
		blocks.name = "Blocks"
		blocks.multimesh = mm
		add_child(blocks)

	func _build_cloud(flow: AvalancheFlow) -> void:
		cloud = CPUParticles3D.new()
		cloud.name = "PowderCloud"
		cloud.amount = 340 if flow.size >= 2 else 140
		cloud.lifetime = 4.0
		cloud.local_coords = false
		cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var quad := QuadMesh.new()
		quad.size = Vector2(7.0, 7.0)
		var puff := GradientTexture2D.new()
		puff.fill = GradientTexture2D.FILL_RADIAL
		puff.fill_from = Vector2(0.5, 0.5)
		puff.fill_to = Vector2(1.0, 0.5)
		var soft := Gradient.new()
		soft.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
		soft.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
		puff.gradient = soft
		var material := StandardMaterial3D.new()
		# Particle billboards keep each particle's scale (unspawned ones stay hidden)
		material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.vertex_color_use_as_albedo = true
		material.albedo_texture = puff
		material.albedo_color = Color(0.97, 0.98, 1.0, 1.0)
		material.disable_receive_shadows = true
		material.disable_fog = true
		quad.material = material
		cloud.mesh = quad
		cloud.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINTS
		cloud.emission_points = PackedVector3Array([Vector3.ZERO])
		cloud.direction = Vector3.UP
		cloud.spread = 60.0
		cloud.initial_velocity_min = 1.5
		cloud.initial_velocity_max = 4.0 + float(flow.size) * 1.5
		cloud.gravity = Vector3(0.0, -0.3, 0.0)
		cloud.damping_min = 0.3
		cloud.damping_max = 1.0
		cloud.scale_amount_min = 1.0
		cloud.scale_amount_max = 2.5 + float(flow.size) * 0.8
		var curve := Curve.new()
		curve.add_point(Vector2(0.0, 0.5))
		curve.add_point(Vector2(1.0, 1.6))
		cloud.scale_amount_curve = curve
		var ramp := Gradient.new()
		ramp.set_color(0, Color(1.0, 1.0, 1.0, 0.85))
		ramp.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
		cloud.color_ramp = ramp
		# Starts once the snow is moving (update() turns it on). The node sits
		# well under the slope: emission points are relative to it, and the
		# renderer draws a stray quad at the node itself on some drivers
		cloud.emitting = false
		add_child(cloud)
		cloud.global_position = flow.origin - Vector3(0.0, 80.0, 0.0)

	## The fracture face: a white wall where the slab broke away
	func _build_crown(flow: AvalancheFlow, terrain: TerrainService) -> void:
		if flow.crown_points.is_empty():
			return
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		for k in range(flow.crown_points.size()):
			var c := flow.crown_points[k]
			var d := flow.crown_downhill[k]
			if d.length_squared() < 0.01:
				continue
			var at := c - d * (AvalancheField.STEP * 0.5)
			var across := Vector2(-d.y, d.x) * (AvalancheField.STEP * 0.6)
			var a2 := at - across
			var b2 := at + across
			var top_a := terrain.get_height_at(Vector3(a2.x, 0.0, a2.y))
			var top_b := terrain.get_height_at(Vector3(b2.x, 0.0, b2.y))
			var depth := flow.slab_depth
			var a_top := Vector3(a2.x, top_a + 0.02, a2.y)
			var b_top := Vector3(b2.x, top_b + 0.02, b2.y)
			var a_low := Vector3(a2.x, top_a - depth, a2.y)
			var b_low := Vector3(b2.x, top_b - depth, b2.y)
			# Lit like the snow around it (a crown takes the sky's light too)
			var n := Vector3(d.x * 0.6, 1.0, d.y * 0.6).normalized()
			verts.append_array([a_top, b_top, b_low, a_top, b_low, a_low])
			for _v in range(6):
				normals.append(n)
		if verts.is_empty():
			return
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.86, 0.91, 0.97)
		material.roughness = 0.9
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		var wall := MeshInstance3D.new()
		wall.name = "Crown"
		wall.mesh = mesh
		wall.material_override = material
		add_child(wall)
