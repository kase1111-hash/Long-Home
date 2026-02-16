class_name RopeService
extends Node
## Central service for rope and anchor system
## Manages strategic integration and time/risk tradeoffs
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

	# Register self
	ServiceLocator.register_service("RopeService", self)

	print("[RopeService] Initialized")


func _on_terrain_ready(service: Object) -> void:
	terrain_service = service as TerrainService


func _on_player_ready(service: Object) -> void:
	player = service


func _connect_signals() -> void:
	deployment_system.deployment_started.connect(_on_deployment_started)
	deployment_system.deployment_complete.connect(_on_deployment_complete)
	deployment_system.deployment_failed.connect(_on_deployment_failed)
	deployment_system.deployment_cancelled.connect(_on_deployment_cancelled)

	rappel_controller.rappel_started.connect(_on_rappel_started)
	rappel_controller.rappel_ended.connect(_on_rappel_ended)

	inventory.rope_lost.connect(_on_rope_lost)


# =============================================================================
# STRATEGIC ANALYSIS
# =============================================================================

## Analyze terrain ahead for rope decision
func analyze_terrain_ahead(look_distance: float = 30.0) -> TerrainAnalysis:
	var analysis := TerrainAnalysis.new()

	if player == null or terrain_service == null:
		return analysis

	var player_pos := player.global_position
	var player_forward := -player.global_transform.basis.z

	# Sample terrain ahead
	var max_slope := 0.0
	var min_cliff_distance := INF
	var has_cliff := false

	for i in range(1, 10):
		var sample_pos := player_pos + player_forward * (look_distance * i / 10.0)
		var cell := terrain_service.get_cell_at(sample_pos)
		if cell == null:
			continue

		max_slope = maxf(max_slope, cell.slope_angle)

		if cell.distance_to_cliff < min_cliff_distance:
			min_cliff_distance = cell.distance_to_cliff

		if cell.has_cliff or cell.distance_to_cliff < 5.0:
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
	var anchors := anchor_detector.get_all_anchors()
	if anchors:
		analysis.anchors_available = anchors.size()
		for anchor in anchors:
			if anchor and anchor.has_method("get_effective_quality"):
				var quality := anchor.get_effective_quality()
				if quality > analysis.best_anchor_quality:
					analysis.best_anchor_quality = quality

	# Calculate rappel distance
	analysis.rappel_distance = inventory.get_total_length()

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

	if cell.has_cliff and cell.distance_to_cliff < 2.0:
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
	var rappel_distance := inventory.get_total_length()
	var rappel_time := rappel_distance / rappel_controller.safe_speed

	# Add recovery time estimate
	var recovery_time := 30.0  # Seconds

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

## Start rope deployment process
func begin_rope_use() -> bool:
	if rope_in_use:
		return false

	if not deployment_system.can_deploy():
		return false

	return deployment_system.begin_deployment()


## Cancel rope deployment
func cancel_rope_use() -> void:
	if current_operation == "deploying":
		deployment_system.cancel_deployment()


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


## Attempt to recover rope after use
func recover_rope() -> void:
	if inventory.deployed_rope == null:
		return

	current_operation = "recovering"
	recovery_started.emit(inventory.deployed_rope)

	# Recovery would be timed process
	# For now, immediate with chance of failure
	var success := _attempt_recovery()
	recovery_complete.emit(success, inventory.deployed_rope)

	if success:
		inventory.recover_rope()
	else:
		_handle_stuck_rope()


func _attempt_recovery() -> bool:
	var rope := inventory.deployed_rope
	if rope == null:
		return false

	# Base recovery chance
	var chance := 0.9

	# Wet rope harder to recover
	if rope.is_wet:
		chance -= 0.1

	# Poor condition may snag
	chance -= (1.0 - rope.condition) * 0.2

	# Terrain affects recovery (would check)
	# Rocky terrain has more snag points

	return randf() < chance


func _handle_stuck_rope() -> void:
	# Rope is stuck - options:
	# 1. Spend more time trying
	# 2. Cut and abandon
	# 3. Leave and continue without

	var rope := inventory.deployed_rope
	if rope == null:
		return

	rope_abandoned.emit(rope, "stuck")
	inventory.abandon_rope()


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_deployment_started() -> void:
	rope_in_use = true
	current_operation = "deploying"


func _on_deployment_complete(anchor: AnchorPoint, rope: Rope) -> void:
	current_operation = "ready"
	EventBus.record_decision("rope_deployed", {
		"position": player.global_position if player else Vector3.ZERO,
		"anchor_type": AnchorPoint.AnchorType.keys()[anchor.anchor_type],
		"rope_length": rope.deployed_length
	})


func _on_deployment_failed(reason: String) -> void:
	rope_in_use = false
	current_operation = "none"
	EventBus.record_incident("rope_deployment_failed", {"reason": reason})


func _on_deployment_cancelled() -> void:
	rope_in_use = false
	current_operation = "none"


func _on_rappel_started(_rope: Rope, _anchor: AnchorPoint) -> void:
	current_operation = "rappelling"


func _on_rappel_ended(outcome: RappelController.RappelOutcome) -> void:
	current_operation = "none"
	rope_in_use = false

	if outcome == RappelController.RappelOutcome.ANCHOR_FAILURE:
		# Lost the rope with the failed anchor
		inventory.abandon_rope()


func _on_rope_lost(rope: Rope) -> void:
	rope_abandoned.emit(rope, "lost")
	EventBus.record_incident("rope_lost", {
		"position": player.global_position if player else Vector3.ZERO
	})


# =============================================================================
# QUERIES
# =============================================================================

## Get current rope system state
func get_state() -> Dictionary:
	return {
		"rope_in_use": rope_in_use,
		"operation": current_operation,
		"inventory": inventory.get_summary(),
		"deployment": deployment_system.get_progress_info() if rope_in_use else {},
		"rappel": rappel_controller.get_state() if current_operation == "rappelling" else {},
		"time_spent": rope_time_total
	}


## Check if can use rope
func can_use_rope() -> bool:
	return inventory.has_usable_rope() and not rope_in_use


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
