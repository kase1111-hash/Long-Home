class_name BodyConditionService
extends Node
## Central service coordinating all body condition systems
## Provides unified API and diegetic feedback hooks
##
## Design Philosophy:
## - Body state is felt, not displayed numerically
## - Self-check action reveals detailed state
## - Visual/audio cues indicate condition
## - Condition affects all other systems

# =============================================================================
# SIGNALS
# =============================================================================

signal condition_changed(overall: float)
signal self_check_started()
signal self_check_completed(messages: Array[String])
signal condition_critical()
signal collapse_occurred()
signal incapacitated()

# =============================================================================
# CHILD SYSTEMS
# =============================================================================

## Fatigue management
var fatigue_manager: FatigueManager

## Cold exposure management
var cold_manager: ColdExposureManager

## Injury management
var injury_manager: InjuryManager

## Body state data
var body_state: BodyState


# =============================================================================
# STATE
# =============================================================================

## Overall condition rating (0 = incapacitated, 1 = perfect)
var overall_condition: float = 1.0

## Previous condition (for change detection)
var previous_condition: float = 1.0

## Timer for throttled body state emission
var body_state_emit_timer: float = 0.0

## Interval between body state emissions (seconds)
var body_state_emit_interval: float = 0.5

## Whether body state has changed since last emission
var body_state_dirty: bool = false

## Is player doing self-check
var is_self_checking: bool = false

## Self-check duration
var self_check_time: float = 3.0

## Self-check timer
var self_check_timer: float = 0.0

## Has collapsed
var has_collapsed: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	# Create body state
	body_state = BodyState.new()

	# Create child systems
	fatigue_manager = FatigueManager.new()
	cold_manager = ColdExposureManager.new()
	injury_manager = InjuryManager.new()

	# Add as children
	add_child(fatigue_manager)
	add_child(cold_manager)
	add_child(injury_manager)

	# Set body state references
	fatigue_manager.set_body_state(body_state)
	cold_manager.set_body_state(body_state)
	injury_manager.set_body_state(body_state)

	# Connect signals
	_connect_signals()

	# Register service
	ServiceLocator.register_service("BodyConditionService", self)

	print("[BodyConditionService] Initialized")


func _connect_signals() -> void:
	fatigue_manager.critical_fatigue.connect(_on_critical_fatigue)
	fatigue_manager.collapse_imminent.connect(_on_collapse_imminent)

	cold_manager.hypothermia_onset.connect(_on_hypothermia)
	cold_manager.frostbite_risk.connect(_on_frostbite_risk)

	injury_manager.incapacitating_injury.connect(_on_incapacitating_injury)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	_update_overall_condition()
	_check_collapse()
	_process_self_check(delta)

	# Emit body state update only when changed and at throttled intervals
	body_state_emit_timer += delta
	if body_state_dirty and body_state_emit_timer >= body_state_emit_interval:
		EventBus.body_state_updated.emit(body_state)
		body_state_emit_timer = 0.0
		body_state_dirty = false


func _update_overall_condition() -> void:
	previous_condition = overall_condition

	# Calculate overall condition
	var condition := 1.0

	# Fatigue impact
	condition -= body_state.fatigue * 0.3

	# Cold impact
	condition -= body_state.cold_exposure * 0.3

	# Hydration impact
	condition -= (1.0 - body_state.hydration) * 0.2

	# Injury impact
	condition -= body_state.get_total_injury_severity() * 0.3

	# Mental state impact
	condition *= body_state.mental_state

	overall_condition = clampf(condition, 0.0, 1.0)

	# Check for significant change
	if absf(overall_condition - previous_condition) > 0.01:
		body_state_dirty = true

	if absf(overall_condition - previous_condition) > 0.1:
		condition_changed.emit(overall_condition)

	# Check critical
	if overall_condition < 0.2 and previous_condition >= 0.2:
		condition_critical.emit()


func _check_collapse() -> void:
	if has_collapsed:
		return

	if body_state.would_collapse():
		has_collapsed = true
		collapse_occurred.emit()
		EventBus.record_incident("collapse", {
			"fatigue": body_state.fatigue,
			"cold": body_state.cold_exposure,
			"injuries": body_state.get_total_injury_severity()
		})


func _process_self_check(delta: float) -> void:
	if not is_self_checking:
		return

	self_check_timer += delta
	if self_check_timer >= self_check_time:
		_complete_self_check()


# =============================================================================
# SELF-CHECK ACTION
# =============================================================================

## Start self-check (player inspects their condition)
func start_self_check() -> void:
	if is_self_checking:
		return

	is_self_checking = true
	self_check_timer = 0.0
	self_check_started.emit()
	EventBus.self_check_started.emit()

	# Pause for self-check
	fatigue_manager.start_resting()


## Cancel self-check
func cancel_self_check() -> void:
	is_self_checking = false
	self_check_timer = 0.0
	fatigue_manager.stop_resting()


func _complete_self_check() -> void:
	is_self_checking = false

	var messages := body_state.get_status_messages()
	self_check_completed.emit(messages)
	EventBus.self_check_completed.emit(body_state)

	fatigue_manager.stop_resting()


# =============================================================================
# INPUT FROM OTHER SYSTEMS
# =============================================================================

## Update activity level (from movement)
func set_activity_level(level: float) -> void:
	fatigue_manager.set_activity_level(level)
	cold_manager.set_activity_level(level)
	body_state_dirty = true


## Update slope (from terrain)
func set_slope(angle: float) -> void:
	fatigue_manager.set_slope(angle)


## Update carried weight (from gear)
func set_weight(weight: float) -> void:
	fatigue_manager.set_weight(weight)


## Set wet state
func set_wet(wet: bool) -> void:
	cold_manager.set_wet(wet)


## Set clothing insulation
func set_insulation(level: float) -> void:
	cold_manager.set_insulation(level)


## Apply impact damage
func apply_impact(force: float, direction: Vector3, context: Dictionary = {}) -> Injury:
	body_state_dirty = true
	return injury_manager.process_impact(force, direction, context)


## Apply slide damage
func apply_slide_impact(speed: float, surface: GameEnums.SurfaceType) -> Injury:
	body_state_dirty = true
	return injury_manager.process_slide_impact(speed, surface)


## Apply fall damage
func apply_fall(height: float, surface: GameEnums.SurfaceType) -> Injury:
	body_state_dirty = true
	return injury_manager.process_fall(height, surface)


## Apply sudden cold exposure
func apply_cold_exposure(amount: float) -> void:
	body_state_dirty = true
	cold_manager.apply_sudden_exposure(amount)


## Apply burst fatigue
func apply_fatigue(amount: float) -> void:
	body_state_dirty = true
	fatigue_manager.apply_burst_fatigue(amount)


## Add hydration
func add_hydration(amount: float) -> void:
	body_state.hydration = minf(1.0, body_state.hydration + amount)


## Reduce hydration
func reduce_hydration(amount: float) -> void:
	body_state.hydration = maxf(0.0, body_state.hydration - amount)


## Set mental state
func set_mental_state(state: float) -> void:
	body_state.mental_state = clampf(state, 0.0, 1.0)


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_critical_fatigue() -> void:
	body_state.mental_state = maxf(0.3, body_state.mental_state - 0.2)


func _on_collapse_imminent() -> void:
	# Warning before collapse
	pass


func _on_hypothermia() -> void:
	# Generate hypothermia injury if not already present
	var has_hypothermia := false
	for injury in body_state.injuries:
		if injury.type == GameEnums.InjuryType.HYPOTHERMIA:
			has_hypothermia = true
			break

	if not has_hypothermia:
		var injury := Injury.new(
			GameEnums.InjuryType.HYPOTHERMIA,
			0.5,
			GameEnums.BodyPart.TORSO,
			0.0
		)
		body_state.add_injury(injury)


func _on_frostbite_risk(body_part: GameEnums.BodyPart) -> void:
	injury_manager.process_frostbite(body_part)


func _on_incapacitating_injury(_injury: Injury) -> void:
	incapacitated.emit()


# =============================================================================
# QUERIES
# =============================================================================

## Get body state
func get_body_state() -> BodyState:
	return body_state


## Get overall condition (0-1)
func get_overall_condition() -> float:
	return overall_condition


## Get movement speed modifier
func get_movement_modifier() -> float:
	var modifier := body_state.get_movement_modifier()
	modifier *= fatigue_manager.get_movement_modifier()
	modifier *= 1.0 - injury_manager.get_movement_penalty()
	return clampf(modifier, 0.1, 1.0)


## Get stability modifier
func get_stability_modifier() -> float:
	var modifier := body_state.get_stability_modifier()
	modifier *= cold_manager.get_foot_stability()
	return clampf(modifier, 0.1, 1.0)


## Get input delay
func get_input_delay() -> float:
	return maxf(body_state.get_input_delay(), fatigue_manager.get_input_delay())


## Get camera sway
func get_camera_sway() -> float:
	return fatigue_manager.get_camera_sway()


## Get rope handling modifier
func get_rope_handling_modifier() -> float:
	var modifier := body_state.get_rope_handling_modifier()
	modifier *= cold_manager.get_hand_dexterity()
	return clampf(modifier, 0.1, 1.0)


## Get slide control modifier
func get_slide_control_modifier() -> float:
	return body_state.get_slide_control_modifier()


## Check if condition is critical
func is_critical() -> bool:
	return body_state.is_critical() or overall_condition < 0.2


## Check if can continue
func can_continue() -> bool:
	return not has_collapsed and injury_manager.can_continue() and overall_condition > 0.1


## Get diegetic feedback data
func get_feedback_data() -> Dictionary:
	return {
		"breathing_intensity": fatigue_manager.breathing_intensity,
		"is_shivering": cold_manager.is_shivering,
		"frost_effect": cold_manager.get_frost_effect_intensity(),
		"breath_visibility": cold_manager.get_breath_visibility(),
		"camera_sway": get_camera_sway(),
		"limp": injury_manager.has_limb_injury()
	}


## Get full summary
func get_summary() -> Dictionary:
	return {
		"overall": overall_condition,
		"fatigue": fatigue_manager.get_summary(),
		"cold": cold_manager.get_summary(),
		"injuries": injury_manager.get_summary(),
		"hydration": body_state.hydration,
		"mental_state": body_state.mental_state,
		"can_continue": can_continue()
	}
