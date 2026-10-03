class_name RopeService
extends Node
## Central service for rope and anchor system
## Manages strategic integration and time/risk tradeoffs
##
## The sequence a player lives through (R at the top of something steep):
##   1. find an anchor within reach (a horn, a boulder, a crack for a nut,
##      screws or a V-thread in ice, a picket or a cut bollard in snow)
##   2. build it, weight-test it, thread the rope (half a minute and more:
##      longer with tired legs, numb hands or wind). A failed test means
##      another anchor, or none
##   3. rappel: RappelController lowers the climber down the face
##   4. off rope at the bottom (or unclip on a ledge with R), then pull the
##      rope down through the anchor. It can snag and stay up there
##   At the knots at the rope's end, R builds the next anchor on the face and
##   pulls the rope down to it. R during the build strips the anchor again.
##
## Design Philosophy:
## - Rope use is a strategic decision, not an ability
## - Time cost must be weighed against safety
## - Some terrain is "mandatory rope" - no choice
## - Knowledge helps identify when to rope

# =============================================================================
# SIGNALS
# =============================================================================

signal rope_decision_point(terrain_ahead: TerrainAnalysis)
signal mandatory_rope_terrain()
signal rope_recommended(reason: String)
signal time_cost_calculated(minutes: float)
signal recovery_started(rope: Rope)
signal recovery_complete(success: bool, rope: Rope)
signal rope_abandoned(rope: Rope, reason: String)
signal phase_changed(phase: RopePhase)

# =============================================================================
# ENUMS
# =============================================================================

enum RopePhase {
	NONE,        # Rope in the pack
	DEPLOYING,   # Building, testing and threading an anchor
	RAPPELLING,  # On the rope
	PULLING,     # Pulling the rope down through the anchor
	ABORTING     # Stripping an anchor before rappelling
}

# =============================================================================
# CONSTANTS
# =============================================================================

## A face this steep under you needs the rope (or great care)
const ROPE_WORTHY_SLOPE := 40.0
## Steep ground this close below also makes the rope worth getting out
const LOOK_DOWN_DISTANCE := 8.0
## Below this slope a climber can unclip and stand
const STANCE_SLOPE := 55.0

# =============================================================================
# COMPONENTS
# =============================================================================

## Rope inventory
var inventory: RopeInventory

## Anchor detector
var anchor_detector: AnchorDetector

## Deployment system
var deployment_system: RopeDeploymentSystem

## Rappel controller
var rappel_controller: RappelController


# =============================================================================
# DEPENDENCIES
# =============================================================================

## Terrain service reference
var terrain_service: TerrainService

## Player reference
var player: Node

## Time service reference (would track game time)
var time_service: Node


# =============================================================================
# CONFIGURATION
# =============================================================================

## Slope angle that makes rope mandatory
var mandatory_rope_slope: float = 55.0

## Cliff height that makes rope mandatory
var mandatory_rope_cliff_height: float = 3.0

## Time multiplier for game time (real seconds to game minutes)
var time_scale: float = 10.0


# =============================================================================
# STATE
# =============================================================================

## Is rope currently in use
var rope_in_use: bool = false

## Current rope operation
var current_operation: String = "none"

## Time spent on rope operations this descent
var rope_time_total: float = 0.0

## Where the rope work is
var phase: RopePhase = RopePhase.NONE

var _climber: PlayerController
var _tried_anchors: Array = []
var _active_anchor: AnchorPoint
var _reanchor_target: AnchorPoint
var _pull_elapsed: float = 0.0
var _pull_duration: float = 0.0
var _pull_reason: String = ""
var _finishing: bool = false


# =============================================================================
# TERRAIN ANALYSIS
# =============================================================================

class TerrainAnalysis:
	## Is rope mandatory for this terrain
	var is_mandatory: bool = false
	## Is rope recommended
	var is_recommended: bool = false
	## Reason for recommendation
	var recommendation_reason: String = ""
	## Risk without rope (0-1)
	var risk_without_rope: float = 0.0
	## Estimated time cost (game minutes)
	var time_cost: float = 0.0
	## Available anchors nearby
	var anchors_available: int = 0
	## Best anchor quality (hidden, for calculations)
	var best_anchor_quality: float = 0.0
	## Distance that can be covered with rope
	var rappel_distance: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	# Create components
	inventory = RopeInventory.create_standard_loadout()
	anchor_detector = AnchorDetector.new()
	deployment_system = RopeDeploymentSystem.new()
	rappel_controller = RappelController.new()

	# Add as children
	add_child(anchor_detector)
	add_child(deployment_system)
	add_child(rappel_controller)

	# Initialize deployment system with references
	deployment_system.initialize(anchor_detector, inventory)

	# Connect signals
	_connect_signals()

	# Get services
	ServiceLocator.get_service_async("TerrainService", _on_terrain_ready)
	ServiceLocator.get_service_async("PlayerController", _on_player_ready)

	# A fresh pack for every descent; rope work stops when the run does
	EventBus.descent_ready.connect(reset_for_run)
	EventBus.run_ended.connect(_on_run_ended)
	EventBus.player_movement_changed.connect(_on_player_movement_changed)

	# Register self
	ServiceLocator.register_service("RopeService", self)

	print("[RopeService] Initialized")


func _on_terrain_ready(service: Object) -> void:
	terrain_service = service as TerrainService


func _on_player_ready(service: Object) -> void:
	player = service
	_climber = service as PlayerController


func _connect_signals() -> void:
	deployment_system.deployment_started.connect(_on_deployment_started)
	deployment_system.deployment_complete.connect(_on_deployment_complete)
	deployment_system.deployment_failed.connect(_on_deployment_failed)
	deployment_system.deployment_cancelled.connect(_on_deployment_cancelled)
	deployment_system.state_changed.connect(_on_deployment_state_changed)

	rappel_controller.rappel_started.connect(_on_rappel_started)
	rappel_controller.rappel_ended.connect(_on_rappel_ended)
	rappel_controller.rope_jam_occurred.connect(_on_rope_jam)
	rappel_controller.rope_jam_cleared.connect(_on_rope_jam_cleared)
	rappel_controller.rope_end_reached.connect(_on_rope_end_reached)
	rappel_controller.rope_running_low.connect(_on_rope_running_low)

	_connect_inventory()


func _connect_inventory() -> void:
	if not inventory.rope_lost.is_connected(_on_rope_lost):
		inventory.rope_lost.connect(_on_rope_lost)


## Pack the rope the loadout actually carries and forget the last descent
func reset_for_run() -> void:
	if rappel_controller.is_rappelling:
		rappel_controller.is_rappelling = false
	if deployment_system.current_state != RopeDeploymentSystem.DeploymentState.IDLE:
		deployment_system.force_abort()

	var gear: GearState = null
	var run := GameStateManager.current_run
	if run != null:
		gear = run.gear_state
	inventory = RopeInventory.create_from_gear(gear)
	deployment_system.initialize(anchor_detector, inventory)
	anchor_detector.has_anchor_kit = gear != null and gear.has_item(GameEnums.GearType.ANCHOR_KIT)
	_connect_inventory()

	_set_phase(RopePhase.NONE)
	rope_in_use = false
	current_operation = "none"
	rope_time_total = 0.0
	_tried_anchors.clear()
	_active_anchor = null
	_reanchor_target = null


## The run is over: drop whatever rope work was going on
func _on_run_ended(_run: RunContext, _outcome: GameEnums.ResolutionType) -> void:
	stop_rope_work()


## Stop building, rappelling and pulling right now (run over, climber gone)
func stop_rope_work() -> void:
	rappel_controller.is_rappelling = false
	if deployment_system.current_state != RopeDeploymentSystem.DeploymentState.IDLE:
		deployment_system.force_abort()
	_set_phase(RopePhase.NONE)
	rope_in_use = false
	_reanchor_target = null


func _physics_process(delta: float) -> void:
	if phase != RopePhase.NONE and not GameStateManager.is_run_active():
		stop_rope_work()
		return
	if phase != RopePhase.NONE:
		rope_time_total += delta
	if phase == RopePhase.PULLING:
		_pull_elapsed += delta
		if _pull_elapsed >= _pull_duration:
			_finish_pull()


# =============================================================================
# PLAYER REQUESTS
# =============================================================================

## R pressed off the rope: set up a rappel here, or say why not
func request_rappel(climber: PlayerController) -> void:
	_climber = climber
	if phase != RopePhase.NONE:
		on_rope_key()
		return
	if climber.is_on_skis():
		climber.say("Take your skis off before you rope up.")
		return
	if not climber.current_state in [
		GameEnums.PlayerMovementState.STANDING,
		GameEnums.PlayerMovementState.WALKING,
		GameEnums.PlayerMovementState.DOWNCLIMBING,
	]:
		return
	if not inventory.has_usable_rope():
		climber.say("You have no rope.")
		return
	if not _needs_rope_below(climber):
		climber.say("Nothing below here needs the rope.")
		return
	var anchor := anchor_detector.find_anchor(climber.global_position, anchor_detector.has_anchor_kit)
	if anchor == null:
		climber.say("Nothing here to build an anchor on.")
		return

	_tried_anchors.clear()
	climber.change_state(GameEnums.PlayerMovementState.ROPING)
	_start_deployment(anchor)


## R pressed while on the rope: strip the anchor, unclip, or build the next one
func on_rope_key() -> void:
	if _climber == null:
		return
	match phase:
		RopePhase.DEPLOYING:
			_set_phase(RopePhase.ABORTING)
			deployment_system.cancel_deployment()
			if deployment_system.current_state == RopeDeploymentSystem.DeploymentState.ABORTING:
				_climber.say("You strip the anchor.", 2.0)
			else:
				deployment_system.force_abort()
		RopePhase.RAPPELLING:
			var cell: TerrainCell = terrain_service.get_cell_at(_climber.global_position) if terrain_service else null
			if cell != null and cell.slope_angle < STANCE_SLOPE:
				_climber.say("You find a stance and unclip.", 2.0)
				rappel_controller.end_rappel(RappelController.RappelOutcome.ABORTED)
				return
			var anchor := anchor_detector.find_anchor(_climber.global_position, anchor_detector.has_anchor_kit)
			if anchor == null:
				_climber.say("Nothing to build on here. Up the rope, or on down.", 2.5)
				return
			_reanchor_target = anchor
			rappel_controller.end_rappel(RappelController.RappelOutcome.ABORTED)


func _needs_rope_below(climber: PlayerController) -> bool:
	if terrain_service == null:
		return false
	var pos := climber.global_position
	var cell := terrain_service.get_cell_at(pos)
	if cell == null:
		return false
	if cell.slope_angle >= ROPE_WORTHY_SLOPE or cell.distance_to_cliff < LOOK_DOWN_DISTANCE:
		return true
	var directions: Array[Vector3] = [cell.slope_direction, climber.get_facing_direction()]
	var camera: Camera3D = climber.get_viewport().get_camera_3d() if climber.is_inside_tree() else null
	if camera != null:
		directions.append(-camera.global_transform.basis.z)
	for direction in directions:
		var flat := Vector3(direction.x, 0.0, direction.z)
		if flat.length_squared() < 0.01:
			continue
		flat = flat.normalized()
		for step in range(1, 5):
			var ahead := terrain_service.get_cell_at(pos + flat * (step * LOOK_DOWN_DISTANCE / 4.0))
			if ahead != null and (ahead.slope_angle >= 45.0 or ahead.is_cliff):
				return true
	return false


func _start_deployment(anchor: AnchorPoint) -> void:
	# A finished deployment sits in READY until cleared; clear it while the
	# phase is not DEPLOYING so the cancellation is not taken for a new abort
	if deployment_system.current_state != RopeDeploymentSystem.DeploymentState.IDLE:
		deployment_system.force_abort()
	_active_anchor = anchor
	_set_phase(RopePhase.DEPLOYING)
	if deployment_system.current_state == RopeDeploymentSystem.DeploymentState.IDLE:
		if not deployment_system.begin_deployment():
			_finish_rope_work()
			return
	if not deployment_system.select_anchor(anchor):
		deployment_system.force_abort()
		_finish_rope_work()
		return
	deployment_system.confirm_at_anchor()
	_climber.say(anchor.get_build_description(), 3.0)
	EventBus.rope_deployment_started.emit(anchor.get_quality_class())


func _set_phase(new_phase: RopePhase) -> void:
	if new_phase == phase:
		return
	phase = new_phase
	match phase:
		RopePhase.NONE:
			current_operation = "none"
		RopePhase.DEPLOYING:
			current_operation = "deploying"
		RopePhase.RAPPELLING:
			current_operation = "rappelling"
		RopePhase.PULLING:
			current_operation = "recovering"
		RopePhase.ABORTING:
			current_operation = "aborting"
	phase_changed.emit(phase)


## Rope work over: back on your feet (or still clinging if it is steep)
func _finish_rope_work() -> void:
	_set_phase(RopePhase.NONE)
	rope_in_use = false
	_reanchor_target = null
	if _climber == null or _climber.current_state != GameEnums.PlayerMovementState.ROPING:
		return
	_finishing = true
	var cell: TerrainCell = terrain_service.get_cell_at(_climber.global_position) if terrain_service else null
	if cell != null and cell.slope_angle > PlayerController.DOWNCLIMB_ENTER_SLOPE:
		_climber.change_state(GameEnums.PlayerMovementState.DOWNCLIMBING)
	else:
		_climber.change_state(GameEnums.PlayerMovementState.STANDING)
	_finishing = false


# =============================================================================
# PULLING THE ROPE
# =============================================================================

func _start_pull(reason: String) -> void:
	_pull_reason = reason
	_pull_elapsed = 0.0
	var length := 25.0
	if inventory.deployed_rope != null:
		length = inventory.deployed_rope.deployed_length
	_pull_duration = 4.0 + length * 0.25
	_set_phase(RopePhase.PULLING)
	if inventory.deployed_rope != null:
		recovery_started.emit(inventory.deployed_rope)
	_climber.say("Pulling the rope down...", minf(_pull_duration, 3.0))


func _finish_pull() -> void:
	var rope := inventory.deployed_rope
	var success := _attempt_recovery()
	recovery_complete.emit(success, rope)
	if success:
		inventory.recover_rope()
		EventBus.rope_recovered.emit()
		_climber.say("The rope comes down. You coil it.", 2.0)
	else:
		_handle_stuck_rope()
		_climber.say("The rope won't come. You leave it hanging.", 2.5)

	if _pull_reason == "reanchor" and _reanchor_target != null:
		var target := _reanchor_target
		_reanchor_target = null
		if inventory.has_usable_rope():
			_start_deployment(target)
			return
		_climber.say("No rope. Nothing for it but to climb.", 2.5)
	_finish_rope_work()


## Attempt to recover rope after use
func recover_rope() -> void:
	if inventory.deployed_rope == null:
		return
	_start_pull("manual")


func _attempt_recovery() -> bool:
	var rope := inventory.deployed_rope
	if rope == null:
		return false

	# Rock edges and flakes catch a rope being pulled; snow lets it go
	var snag := 0.06
	if _active_anchor != null:
		match _active_anchor.anchor_type:
			AnchorPoint.AnchorType.ROCK_HORN, AnchorPoint.AnchorType.ROCK_CRACK, AnchorPoint.AnchorType.BOULDER:
				snag = 0.10
			AnchorPoint.AnchorType.SNOW_STAKE, AnchorPoint.AnchorType.SNOW_BOLLARD:
				snag = 0.04

	# Wet rope harder to recover
	if rope.is_wet:
		snag += 0.05

	# Poor condition may snag
	snag += (1.0 - rope.condition) * 0.2

	return randf() >= snag


func _handle_stuck_rope() -> void:
	var rope := inventory.deployed_rope
	if rope == null:
		return
	rope_abandoned.emit(rope, "stuck")
	inventory.abandon_rope()
	_drop_rope_from_gear()


func _drop_rope_from_gear() -> void:
	if inventory.has_usable_rope():
		return
	var gear: GearState = _climber.gear_state if _climber else null
	if gear != null and gear.has_item(GameEnums.GearType.ROPE):
		gear.remove_item(GameEnums.GearType.ROPE)


# =============================================================================
# STRATEGIC ANALYSIS
# =============================================================================

## Analyze terrain ahead for rope decision
func analyze_terrain_ahead(look_distance: float = 30.0) -> TerrainAnalysis:
	var analysis := TerrainAnalysis.new()

	if player == null or terrain_service == null:
		return analysis

	var player_pos: Vector3 = player.global_position
	var player_forward: Vector3 = -player.global_transform.basis.z

	# Sample terrain ahead
	var max_slope := 0.0
	var min_cliff_distance := INF
	var has_cliff := false

	for i in range(1, 10):
		var sample_pos: Vector3 = player_pos + player_forward * (look_distance * i / 10.0)
		var cell := terrain_service.get_cell_at(sample_pos)
		if cell == null:
			continue

		max_slope = maxf(max_slope, cell.slope_angle)

		if cell.distance_to_cliff < min_cliff_distance:
			min_cliff_distance = cell.distance_to_cliff

		if cell.is_cliff or cell.distance_to_cliff < 5.0:
			has_cliff = true

	# Determine if mandatory
	if max_slope >= mandatory_rope_slope:
		analysis.is_mandatory = true
		analysis.recommendation_reason = "Slope too steep to descend safely"
	elif has_cliff and min_cliff_distance < mandatory_rope_cliff_height:
		analysis.is_mandatory = true
		analysis.recommendation_reason = "Cliff requires rope"

	# Determine if recommended (not mandatory but safer)
	if not analysis.is_mandatory:
		if max_slope > 45.0:
			analysis.is_recommended = true
			analysis.recommendation_reason = "Steep terrain - rope advised"
		elif has_cliff:
			analysis.is_recommended = true
			analysis.recommendation_reason = "Cliff nearby - rope provides safety"

	# Calculate risk without rope
	if max_slope >= 55.0:
		analysis.risk_without_rope = 0.9
	elif max_slope >= 45.0:
		analysis.risk_without_rope = 0.6
	elif max_slope >= 35.0:
		analysis.risk_without_rope = 0.3
	else:
		analysis.risk_without_rope = 0.1

	if has_cliff:
		analysis.risk_without_rope = minf(1.0, analysis.risk_without_rope + 0.3)

	# Calculate time cost
	analysis.time_cost = _estimate_rope_time()

	# Check available anchors
	var anchor := anchor_detector.find_anchor(player_pos, anchor_detector.has_anchor_kit)
	if anchor != null:
		analysis.anchors_available = 1
		analysis.best_anchor_quality = anchor.get_effective_quality()

	# Calculate rappel distance (doubled rope)
	analysis.rappel_distance = inventory.get_total_length() * 0.5

	return analysis


## Check if current position requires rope
func is_rope_mandatory_here() -> bool:
	if player == null or terrain_service == null:
		return false

	var cell := terrain_service.get_cell_at(player.global_position)
	if cell == null:
		return false

	if cell.slope_angle >= mandatory_rope_slope:
		return true

	if cell.is_cliff and cell.distance_to_cliff < 2.0:
		return true

	return false


## Get recommendation text for player
func get_recommendation_text() -> String:
	var analysis := analyze_terrain_ahead()

	if analysis.is_mandatory:
		return "Rope required: " + analysis.recommendation_reason

	if analysis.is_recommended:
		return "Rope advised: " + analysis.recommendation_reason

	return ""


# =============================================================================
# TIME CALCULATIONS
# =============================================================================

## Estimate total time for rope operation (in game minutes)
func _estimate_rope_time() -> float:
	var real_seconds := deployment_system.get_estimated_total_time()

	# Add rappel time estimate
	var rappel_distance := inventory.get_total_length() * 0.5
	var rappel_time := rappel_distance / rappel_controller.safe_speed

	# Add recovery time estimate
	var recovery_time := 4.0 + rappel_distance * 0.25

	var total_real := real_seconds + rappel_time + recovery_time

	# Convert to game minutes
	return total_real * time_scale / 60.0


## Get time spent on rope this descent
func get_rope_time_spent() -> float:
	return rope_time_total


## Calculate daylight impact of rope decision
func get_daylight_impact(analysis: TerrainAnalysis) -> Dictionary:
	# Would integrate with time service
	return {
		"minutes_cost": analysis.time_cost,
		"will_cause_nightfall": false,  # Would calculate
		"remaining_daylight": 0.0  # Would get from time service
	}


# =============================================================================
# ROPE OPERATIONS
# =============================================================================

## Start rope deployment process (from where the player stands)
func begin_rope_use() -> bool:
	if _climber == null or phase != RopePhase.NONE:
		return false
	request_rappel(_climber)
	return phase == RopePhase.DEPLOYING


## Cancel rope deployment
func cancel_rope_use() -> void:
	if phase == RopePhase.DEPLOYING:
		on_rope_key()


## Start rappel after deployment complete
func begin_rappel() -> bool:
	if not deployment_system.is_ready():
		return false

	var info := deployment_system.get_progress_info()
	var anchor: AnchorPoint = info["anchor"]
	var rope: Rope = info["rope"]

	if anchor == null or rope == null:
		return false

	return rappel_controller.begin_rappel(rope, anchor)


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_deployment_started() -> void:
	rope_in_use = true


func _on_deployment_state_changed(_old_state: RopeDeploymentSystem.DeploymentState, new_state: RopeDeploymentSystem.DeploymentState) -> void:
	if _climber == null or phase != RopePhase.DEPLOYING:
		return
	match new_state:
		RopeDeploymentSystem.DeploymentState.TESTING:
			_climber.say("You hang your weight on it.", 2.0)
		RopeDeploymentSystem.DeploymentState.THREADING:
			_climber.say("Threading the rope, both ends down.", 2.0)


func _on_deployment_complete(anchor: AnchorPoint, rope: Rope) -> void:
	EventBus.record_decision("rope_deployed", {
		"position": player.global_position if player else Vector3.ZERO,
		"anchor_type": AnchorPoint.AnchorType.keys()[anchor.anchor_type],
		"rope_length": rope.deployed_length
	})
	EventBus.rope_ready.emit(rope.deployed_length)

	if begin_rappel():
		_set_phase(RopePhase.RAPPELLING)
		# The anchor is built and the rope threaded: the deployment job is done
		deployment_system.force_abort()
		if rappel_controller.is_body_rappel:
			_climber.say("No harness. The rope goes round your hips and over a shoulder.", 3.0)
		else:
			_climber.say("On rappel.", 1.5)
	else:
		_climber.say("You can't get on the rope here.", 2.0)
		inventory.recover_rope()
		deployment_system.force_abort()
		_finish_rope_work()


func _on_deployment_failed(reason: String) -> void:
	EventBus.record_incident("rope_deployment_failed", {"reason": reason})
	if phase != RopePhase.DEPLOYING or _climber == null:
		return

	if _active_anchor != null:
		_tried_anchors.append(_active_anchor)
	var next := anchor_detector.find_anchor(_climber.global_position, anchor_detector.has_anchor_kit, _tried_anchors)
	if next != null and deployment_system.current_state == RopeDeploymentSystem.DeploymentState.SELECTING:
		_climber.say("It shifts under your weight. Not that one.", 2.5)
		_active_anchor = next
		deployment_system.select_anchor(next)
		deployment_system.confirm_at_anchor()
		_climber.say(next.get_build_description(), 3.0)
		return

	_climber.say("Nothing here will hold.", 2.5)
	deployment_system.force_abort()


func _on_deployment_cancelled() -> void:
	if phase == RopePhase.DEPLOYING or phase == RopePhase.ABORTING:
		_finish_rope_work()


func _on_rappel_started(_rope: Rope, _anchor: AnchorPoint) -> void:
	_set_phase(RopePhase.RAPPELLING)


func _on_rappel_ended(outcome: RappelController.RappelOutcome) -> void:
	if _climber == null:
		_set_phase(RopePhase.NONE)
		rope_in_use = false
		return

	match outcome:
		RappelController.RappelOutcome.COMPLETE:
			_climber.say("Feet on easy ground. Off rope.", 2.0)
			_start_pull("touchdown")
		RappelController.RappelOutcome.ABORTED:
			if _reanchor_target != null:
				_climber.say(_reanchor_target.get_build_description() + " Then you pull the rope down to it.", 3.0)
				_start_pull("reanchor")
			else:
				_start_pull("unclip")
		RappelController.RappelOutcome.ANCHOR_FAILURE:
			_climber.say("The anchor rips.", 2.0)
			var rope := inventory.deployed_rope
			if rope != null:
				rope_abandoned.emit(rope, "anchor_failure")
				inventory.abandon_rope()
			_drop_rope_from_gear()
			_set_phase(RopePhase.NONE)
			rope_in_use = false
			_climber.trigger_fall()
		_:
			_finish_rope_work()


func _on_rope_jam() -> void:
	if _climber:
		_climber.say("The rope snags on an edge above. You flick it, and flick it...", 2.5)


func _on_rope_jam_cleared() -> void:
	if _climber:
		_climber.say("It runs again.", 1.2)


func _on_rope_end_reached() -> void:
	if _climber:
		_climber.say("The knots at the end of the rope.", 2.5)


func _on_rope_running_low(_remaining: float) -> void:
	if _climber:
		_climber.say("Not much rope left below you.", 2.0)


func _on_rope_lost(rope: Rope) -> void:
	rope_abandoned.emit(rope, "lost")
	EventBus.record_incident("rope_lost", {
		"position": player.global_position if player else Vector3.ZERO
	})


## Someone else took the climber off the rope (a fall, a fatal event, a new run)
func _on_player_movement_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	if _finishing or old_state != GameEnums.PlayerMovementState.ROPING or new_state == GameEnums.PlayerMovementState.ROPING:
		return
	if phase == RopePhase.NONE:
		return
	if rappel_controller.is_rappelling:
		rappel_controller.is_rappelling = false
	if deployment_system.current_state != RopeDeploymentSystem.DeploymentState.IDLE and not deployment_system.is_ready():
		deployment_system.force_abort()
	if inventory.deployed_rope != null and new_state != GameEnums.PlayerMovementState.FALLING:
		inventory.recover_rope()
	_set_phase(RopePhase.NONE)
	rope_in_use = false


# =============================================================================
# QUERIES
# =============================================================================

## Get current rope system state
func get_state() -> Dictionary:
	return {
		"rope_in_use": rope_in_use,
		"operation": current_operation,
		"phase": RopePhase.keys()[phase],
		"inventory": inventory.get_summary(),
		"deployment": deployment_system.get_progress_info() if phase == RopePhase.DEPLOYING else {},
		"rappel": rappel_controller.get_state() if phase == RopePhase.RAPPELLING else {},
		"pull_progress": _pull_elapsed / _pull_duration if phase == RopePhase.PULLING and _pull_duration > 0.0 else 0.0,
		"time_spent": rope_time_total
	}


## Short description of the rope work in progress, for the HUD
func get_activity_text() -> String:
	match phase:
		RopePhase.DEPLOYING:
			match deployment_system.current_state:
				RopeDeploymentSystem.DeploymentState.TESTING:
					return "testing the anchor"
				RopeDeploymentSystem.DeploymentState.THREADING:
					return "threading the rope"
			return "building an anchor"
		RopePhase.RAPPELLING:
			if rappel_controller.is_jammed:
				return "rope snagged"
			if rappel_controller.at_rope_end:
				return "at the rope's end"
			return "rappelling"
		RopePhase.PULLING:
			return "pulling the rope"
		RopePhase.ABORTING:
			return "stripping the anchor"
	return ""


## Check if can use rope
func can_use_rope() -> bool:
	return inventory.has_usable_rope() and phase == RopePhase.NONE


## Check if rope is recommended
func is_rope_recommended() -> bool:
	var analysis := analyze_terrain_ahead()
	return analysis.is_mandatory or analysis.is_recommended


## Get inventory
func get_inventory() -> RopeInventory:
	return inventory


## Get anchor detector
func get_anchor_detector() -> AnchorDetector:
	return anchor_detector
