class_name CrevasseSystem
extends Node
## Crevasses during a descent: snow bridges that give way, falls into the
## slot, climbing out, and probing ahead with the axe.
##
## Bridges. Standing on a hidden crevasse's snow bridge has a collapse hazard
## per second that grows steeply as the bridge thins (GlacierField bridge
## strength), doubles in the afternoon warmth and eases in the cold, and is
## far lower on skis (the load is spread) or lying in a glissade. When a
## bridge goes, TerrainService carves that stretch of the crevasse open down
## to the debris it leaves (4-8.5 m), and the climber falls in for real:
## physics, landing on soft debris, an injury likely.
##
## In the slot. With an axe and crampons on, pushing against a wall climbs
## out: front points and pick, about 0.2 m/s, tiring, and a tired climber can
## skate back down. Without them there is no way up the ice; after a long
## wait the run ends in a rescue.
##
## Probing (G). The climber plunges the axe shaft (or a ski pole) into the
## snow ahead: a hollow bridge within reach is found and a dark probe hole
## left in the snow. Nothing on the mountain is labelled; what the climber
## learns is what the shaft tells them, and the faint sag a bridge leaves.

# =============================================================================
# CONSTANTS
# =============================================================================

## Collapse hazard per second: HAZARD_BASE * exp(HAZARD_RISE * (1 - strength))
## A thin bridge (0.2) goes in about a second under a walker; a thick one
## (0.85) holds a crossing nearly always
const HAZARD_BASE := 0.012
const HAZARD_RISE := 5.5
## Load spread: on skis, lying in a slide
const SKI_LOAD := 0.35
const SLIDE_LOAD := 0.5
## Depth of the debris a fallen bridge leaves (metres below the surface)
const DEBRIS_DEPTH_MIN := 4.0
const DEBRIS_DEPTH_MAX := 8.5
## Below the lip by this much counts as down in the slot (metres)
const IN_SLOT_DEPTH := 1.8
## Front-pointing up an ice wall (m/s real), fatigue per metre climbed
const CLIMB_SPEED := 0.22
const CLIMB_FATIGUE_PER_METRE := 0.012
## Share of the climb spent on the wall before the step over the lip
const WALL_SHARE := 0.85
## Probing: how long it takes, how far ahead the shaft reaches (metres)
const PROBE_TIME := 1.2
const PROBE_REACH := 3.0

# =============================================================================
# SIGNALS
# =============================================================================

signal crevasse_fall(crevasse: GlacierField.Crevasse)
signal climbed_out(crevasse: GlacierField.Crevasse)
signal probed(found: bool)

# =============================================================================
# STATE
# =============================================================================

## Real seconds trapped without the means to climb before the run ends in a rescue
@export var trapped_rescue_time: float = 150.0

## Climbing speed up the ice (m/s real; CLIMB_SPEED unless tuned)
@export var climb_speed: float = CLIMB_SPEED

var terrain_service: TerrainService = null
var player: PlayerController = null

## The crevasse the climber is down in (null when not in one)
var in_crevasse: GlacierField.Crevasse = null
## Climbing out (the climber is held and moved up the wall)
var climbing: bool = false
var climb_progress: float = 0.0
## Probing ahead (seconds left, -1 when not)
var probe_timer: float = -1.0
var trapped_time: float = 0.0

var _climb_from: Vector3 = Vector3.ZERO
var _climb_wall_top: Vector3 = Vector3.ZERO
var _climb_to: Vector3 = Vector3.ZERO
var _climb_height: float = 1.0
var _climb_crevasse: GlacierField.Crevasse = null
var _told_trapped: bool = false
var _probe_holes: Array[Node3D] = []
var _rng := RandomNumberGenerator.new()


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("CrevasseSystem", self)
	_rng.randomize()
	EventBus.run_started.connect(_on_run_started)
	EventBus.run_ended.connect(_on_run_ended)
	# After the climber's own physics step, so a climb places them last
	process_physics_priority = 10


func _on_run_started(_run: RunContext) -> void:
	_reset()


func _on_run_ended(_run: RunContext, _outcome: GameEnums.ResolutionType) -> void:
	_release_climb()
	probe_timer = -1.0


func _reset() -> void:
	_release_climb()
	in_crevasse = null
	probe_timer = -1.0
	trapped_time = 0.0
	_told_trapped = false
	for hole in _probe_holes:
		if is_instance_valid(hole):
			hole.queue_free()
	_probe_holes.clear()


func _resolve() -> bool:
	if not is_instance_valid(terrain_service):
		terrain_service = ServiceLocator.get_service("TerrainService") as TerrainService
	if not is_instance_valid(player):
		player = ServiceLocator.get_service("PlayerController") as PlayerController
	return terrain_service != null and player != null and player.is_inside_tree()


func _physics_process(delta: float) -> void:
	if GameStateManager.current_state != GameEnums.GameState.DESCENT or not GameStateManager.is_run_active():
		return
	if not _resolve() or terrain_service.glacier == null:
		return
	var glacier := terrain_service.glacier

	if climbing:
		_update_climb(delta)
		return

	var pos := player.global_position
	var flat := Vector2(pos.x, pos.z)
	_update_probe(delta, flat, glacier)

	var slot := glacier.crevasse_at(flat, 0.6)
	if slot != null and not slot.is_bridged_at(flat) and pos.y < slot.lip_height_at(flat) - IN_SLOT_DEPTH:
		_update_in_slot(slot, flat, delta)
		return
	if in_crevasse != null:
		in_crevasse = null
		trapped_time = 0.0
		_told_trapped = false

	if slot != null and slot.is_bridged_at(flat) and player.is_on_floor():
		_check_bridge(slot, flat, delta)


# =============================================================================
# BRIDGES
# =============================================================================

## Collapse hazard per second for the climber standing on this bridge now
func collapse_hazard(slot: GlacierField.Crevasse) -> float:
	var hazard := HAZARD_BASE * exp(HAZARD_RISE * (1.0 - clampf(slot.bridge_strength, 0.0, 1.0)))
	return hazard * _temperature_factor() * _load_factor()


func _check_bridge(slot: GlacierField.Crevasse, flat: Vector2, delta: float) -> void:
	if player.current_state == GameEnums.PlayerMovementState.ROPING:
		return
	var chance := 1.0 - exp(-collapse_hazard(slot) * delta)
	if _rng.randf() < chance:
		collapse_bridge(slot, flat)


## The bridge under the climber gives way: carve the slot open, fall in
func collapse_bridge(slot: GlacierField.Crevasse, flat: Vector2) -> void:
	var where := slot.locate(flat)
	var seg := int(where.z)
	var centre := slot.points[seg].lerp(slot.points[seg + 1], where.y)
	var depth := minf(_rng.randf_range(DEBRIS_DEPTH_MIN, DEBRIS_DEPTH_MAX), slot.depth)
	EventBus.diegetic_message.emit("The snow drops away beneath you.", 3.0)
	EventBus.record_incident("crevasse_fall", {
		"width": slot.width,
		"depth": depth,
		"bridge_strength": slot.bridge_strength,
		"kind": GlacierField.CrevasseKind.keys()[slot.kind]
	})
	terrain_service.carve_crevasse_section(slot, centre, depth)
	# The ground is gone: let the body drop
	player.velocity = Vector3(player.velocity.x * 0.3, -1.0, player.velocity.z * 0.3)
	crevasse_fall.emit(slot)


## Warm snow is weak: afternoon sun on a bridge doubles the hazard, deep cold
## nearly halves it
func _temperature_factor() -> float:
	var temperature := -8.0
	var system := ServiceLocator.get_service("TemperatureSystem") as TemperatureSystem
	if system != null:
		temperature = system.get_air_temperature()
	return clampf(1.0 + (temperature + 5.0) / 10.0, 0.6, 2.2)


## Load on the bridge: skis and a sliding body spread it; a heavy pack adds
func _load_factor() -> float:
	var factor := 1.0
	if player.is_on_skis():
		factor = SKI_LOAD
	elif player.current_state == GameEnums.PlayerMovementState.SLIDING:
		factor = SLIDE_LOAD
	if player.gear_state != null:
		factor *= 0.8 + player.gear_state.total_weight / 40.0
	return factor


# =============================================================================
# IN THE SLOT
# =============================================================================

func _update_in_slot(slot: GlacierField.Crevasse, flat: Vector2, delta: float) -> void:
	if in_crevasse != slot:
		in_crevasse = slot
		trapped_time = 0.0
		_told_trapped = false
		EventBus.record_decision("in_crevasse", {"depth": slot.lip_height_at(flat) - player.global_position.y})
	if player.current_state == GameEnums.PlayerMovementState.INCAPACITATED:
		return

	var has_axe := player.gear_state != null and player.gear_state.has_ice_axe()
	var points_on := player.footwear == GameEnums.Footwear.CRAMPONS
	if not (has_axe and points_on):
		if not _told_trapped:
			_told_trapped = true
			if has_axe and player.gear_state.has_crampons():
				player.say("Blue ice on every side. Crampons on (F), then climb.", 4.0)
			else:
				player.say("Blue ice on every side, and nothing to climb it with. You shout.", 4.0)
		if not has_axe or not player.gear_state.has_crampons():
			trapped_time += delta
			if trapped_time >= trapped_rescue_time:
				GameStateManager.complete_run(GameEnums.ResolutionType.RESCUE, "Trapped in a crevasse")
		return

	# Push against a wall to climb it
	if not player.is_on_floor() or player.input_handler.move_input.length() < 0.5:
		return
	var push := player.movement.get_input_direction_world()
	if push == Vector3.ZERO:
		return
	var along := slot.direction_at(flat)
	var across := Vector2(-along.y, along.x)
	var side := signf(across.dot(Vector2(push.x, push.z)))
	if absf(across.dot(Vector2(push.x, push.z))) < 0.5:
		return
	start_climb(slot, flat, across * side)


## Start climbing the wall on one side of the slot (side: unit xz, out of the slot)
func start_climb(slot: GlacierField.Crevasse, flat: Vector2, side: Vector2) -> void:
	var where := slot.locate(flat)
	var seg := int(where.z)
	var centre := slot.points[seg].lerp(slot.points[seg + 1], where.y)
	var half := slot.width * 0.5
	var wall := centre + side * maxf(half - 0.3, 0.2)
	var out := centre + side * (half + 1.4)
	_climb_crevasse = slot
	_climb_from = Vector3(wall.x, player.global_position.y, wall.y)
	_climb_wall_top = Vector3(wall.x, slot.lip_height_at(flat) - 0.2, wall.y)
	_climb_to = Vector3(out.x, terrain_service.get_height_at(Vector3(out.x, 0.0, out.y)) + 0.3, out.y)
	_climb_height = maxf(_climb_to.y - _climb_from.y, 0.5)
	climb_progress = 0.0
	climbing = true
	player.held_by = self
	player.velocity = Vector3.ZERO
	player.change_state(GameEnums.PlayerMovementState.DOWNCLIMBING)
	player.rotation.y = PlayerMovement.yaw_facing(Vector3(side.x, 0.0, side.y))
	player.say("Front points in, pick in. Up.", 2.5)
	EventBus.record_decision("crevasse_climb", {"height": _climb_height})


func _update_climb(delta: float) -> void:
	if player.input_handler.move_input.length() > 0.3:
		var speed := climb_speed
		if player.body_state != null:
			speed *= player.body_state.get_movement_modifier()
		climb_progress = minf(1.0, climb_progress + speed * delta / _climb_height)
		player.add_fatigue(CLIMB_FATIGUE_PER_METRE * speed * delta)
		# A spent climber's points skate
		var fatigue := player.get_fatigue()
		if fatigue > 0.85 and _rng.randf() < 0.15 * delta:
			_slip_back()
			return

	if climb_progress < WALL_SHARE:
		player.global_position = _climb_from.lerp(_climb_wall_top, climb_progress / WALL_SHARE)
	else:
		player.global_position = _climb_wall_top.lerp(_climb_to, (climb_progress - WALL_SHARE) / (1.0 - WALL_SHARE))
	player.velocity = Vector3.ZERO

	if climb_progress >= 1.0:
		var slot := _climb_crevasse
		_release_climb()
		player.change_state(GameEnums.PlayerMovementState.STANDING)
		player.say("You haul yourself over the lip.", 3.0)
		EventBus.record_decision("crevasse_climbed_out", {})
		in_crevasse = null
		climbed_out.emit(slot)


func _slip_back() -> void:
	_release_climb()
	player.velocity = Vector3(0.0, -2.0, 0.0)
	player.say("A front point skates off the ice. You're back at the bottom.", 3.0)
	EventBus.record_incident("crevasse_slip", {})


func _release_climb() -> void:
	if climbing and is_instance_valid(player) and player.held_by == self:
		player.held_by = null
	climbing = false
	_climb_crevasse = null


# =============================================================================
# PROBING
# =============================================================================

func _update_probe(delta: float, flat: Vector2, glacier: GlacierField) -> void:
	if probe_timer >= 0.0:
		probe_timer -= delta
		if probe_timer < 0.0:
			probe_ahead(glacier)
		return
	if player.input_handler.is_action_just_pressed("probe"):
		start_probe()


## Begin plunging the shaft into the snow ahead (finishes after PROBE_TIME)
func start_probe() -> void:
	var state := player.current_state
	if state != GameEnums.PlayerMovementState.STANDING and state != GameEnums.PlayerMovementState.WALKING and state != GameEnums.PlayerMovementState.SKIING:
		return
	var has_axe := player.gear_state != null and player.gear_state.has_ice_axe()
	if not has_axe and not player.is_on_skis():
		player.say("Nothing to probe with.", 2.0)
		return
	probe_timer = PROBE_TIME
	player.say("You probe the snow ahead.", 1.5)


## What the shaft finds ahead: true when it plunges into a hollow bridge
func probe_ahead(glacier: GlacierField) -> bool:
	probe_timer = -1.0
	var pos := player.global_position
	var flat := Vector2(pos.x, pos.z)
	var facing3 := -player.global_transform.basis.z
	var facing := Vector2(facing3.x, facing3.z)
	if facing.length_squared() < 0.0001:
		facing = Vector2.UP
	facing = facing.normalized()
	var distance := 0.6
	while distance <= PROBE_REACH:
		var point := flat + facing * distance
		var slot := glacier.crevasse_at(point, 0.2)
		if slot != null and slot.is_bridged_at(point):
			slot.probed = true
			_leave_probe_hole(point)
			player.say("The shaft plunges through into nothing. Hollow.", 3.0)
			EventBus.record_decision("probe", {"hollow": true, "distance": distance})
			probed.emit(true)
			return true
		distance += 0.3
	if glacier.is_on_glacier(flat):
		player.say("Firm. The shaft stops in solid snow.", 2.0)
	else:
		player.say("Solid ground.", 1.5)
	EventBus.record_decision("probe", {"hollow": false})
	probed.emit(false)
	return false


## A dark hole where the shaft broke through: the climber's own mark
func _leave_probe_hole(point: Vector2) -> void:
	var hole := MeshInstance3D.new()
	hole.name = "ProbeHole"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.07
	mesh.bottom_radius = 0.05
	mesh.height = 0.04
	mesh.radial_segments = 8
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.08, 0.14, 0.26)
	material.roughness = 1.0
	mesh.material = material
	hole.mesh = mesh
	var y := terrain_service.get_height_at(Vector3(point.x, 0.0, point.y))
	var parent: Node = terrain_service
	parent.add_child(hole)
	hole.global_position = Vector3(point.x, y + 0.01, point.y)
	_probe_holes.append(hole)


# =============================================================================
# QUERIES
# =============================================================================

## Is the climber down in a crevasse?
func is_in_crevasse() -> bool:
	return in_crevasse != null or climbing


## HUD activity text ("" when nothing crevasse-related is happening)
func get_activity_text() -> String:
	if climbing:
		return "Climbing out of a crevasse %d%%" % roundi(climb_progress * 100.0)
	if in_crevasse != null:
		return "In a crevasse"
	if probe_timer >= 0.0:
		return "Probing"
	return ""
