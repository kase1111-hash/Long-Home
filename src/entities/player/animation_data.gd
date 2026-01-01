class_name AnimationData
extends Resource
## Animation data for player movement states
## Defines parameters for procedural and skeletal animations
##
## Can be extended with AnimationPlayer clips when character model is added

# =============================================================================
# ANIMATION DEFINITIONS
# =============================================================================

## Base animation parameters per state
const STATE_ANIMATIONS := {
	# IDLE STATES
	"idle": {
		"clip": "idle_breathe",
		"loop": true,
		"base_speed": 1.0,
		"blend_in": 0.2,
		"blend_out": 0.2,
		# Procedural parameters
		"sway_amount": 0.02,
		"breathing_speed": 0.5,
		"posture_height": 1.0,  # Full height
	},

	"idle_tired": {
		"clip": "idle_breathe_heavy",
		"loop": true,
		"base_speed": 0.8,
		"blend_in": 0.3,
		"blend_out": 0.2,
		"sway_amount": 0.03,
		"breathing_speed": 0.8,
		"posture_height": 0.95,
	},

	# WALKING STATES
	"walking": {
		"clip": "walk_normal",
		"loop": true,
		"base_speed": 1.0,
		"blend_in": 0.15,
		"blend_out": 0.15,
		"sway_amount": 0.025,
		"breathing_speed": 0.7,
		"posture_height": 1.0,
		"footstep_interval": 0.5,  # Seconds between footsteps at base speed
	},

	"walking_uphill": {
		"clip": "walk_uphill",
		"loop": true,
		"base_speed": 0.8,
		"blend_in": 0.2,
		"blend_out": 0.2,
		"sway_amount": 0.035,
		"breathing_speed": 1.0,
		"posture_height": 0.95,
		"lean_forward": 0.1,  # Forward lean on slopes
		"footstep_interval": 0.6,
	},

	"walking_downhill": {
		"clip": "walk_downhill",
		"loop": true,
		"base_speed": 1.1,
		"blend_in": 0.15,
		"blend_out": 0.2,
		"sway_amount": 0.03,
		"breathing_speed": 0.8,
		"posture_height": 0.97,
		"lean_back": 0.05,
		"footstep_interval": 0.45,
	},

	"walking_tired": {
		"clip": "walk_tired",
		"loop": true,
		"base_speed": 0.7,
		"blend_in": 0.25,
		"blend_out": 0.2,
		"sway_amount": 0.04,
		"breathing_speed": 1.2,
		"posture_height": 0.9,
		"footstep_interval": 0.7,
	},

	# TRAVERSING
	"traversing_left": {
		"clip": "traverse_left",
		"loop": true,
		"base_speed": 0.8,
		"blend_in": 0.2,
		"blend_out": 0.2,
		"sway_amount": 0.025,
		"breathing_speed": 0.8,
		"posture_height": 0.95,
		"footstep_interval": 0.55,
	},

	"traversing_right": {
		"clip": "traverse_right",
		"loop": true,
		"base_speed": 0.8,
		"blend_in": 0.2,
		"blend_out": 0.2,
		"sway_amount": 0.025,
		"breathing_speed": 0.8,
		"posture_height": 0.95,
		"footstep_interval": 0.55,
	},

	# DOWNCLIMBING
	"downclimbing": {
		"clip": "downclimb",
		"loop": true,
		"base_speed": 0.6,
		"blend_in": 0.3,
		"blend_out": 0.3,
		"sway_amount": 0.015,
		"breathing_speed": 0.9,
		"posture_height": 0.85,
		"facing_slope": true,  # Character faces the terrain
		"footstep_interval": 0.8,
	},

	# SLIDING STATES
	"slide_start": {
		"clip": "slide_entry",
		"loop": false,
		"base_speed": 1.5,
		"blend_in": 0.1,
		"blend_out": 0.1,
		"sway_amount": 0.06,
		"breathing_speed": 1.5,
		"posture_height": 0.7,
	},

	"sliding": {
		"clip": "slide_uncontrolled",
		"loop": true,
		"base_speed": 1.5,
		"blend_in": 0.1,
		"blend_out": 0.2,
		"sway_amount": 0.1,
		"breathing_speed": 1.8,
		"posture_height": 0.5,
		"tumble_chance": 0.3,  # Random rotation during slide
	},

	"sliding_controlled": {
		"clip": "slide_controlled",
		"loop": true,
		"base_speed": 1.2,
		"blend_in": 0.15,
		"blend_out": 0.2,
		"sway_amount": 0.05,
		"breathing_speed": 1.3,
		"posture_height": 0.65,
	},

	"slide_end": {
		"clip": "slide_stop",
		"loop": false,
		"base_speed": 1.0,
		"blend_in": 0.1,
		"blend_out": 0.2,
		"sway_amount": 0.04,
		"breathing_speed": 1.2,
		"posture_height": 0.8,
	},

	# ROPING
	"rope_setup": {
		"clip": "rope_deploy",
		"loop": false,
		"base_speed": 0.8,
		"blend_in": 0.2,
		"blend_out": 0.3,
		"sway_amount": 0.02,
		"breathing_speed": 0.9,
		"posture_height": 0.9,
	},

	"roping": {
		"clip": "rappel",
		"loop": true,
		"base_speed": 0.8,
		"blend_in": 0.2,
		"blend_out": 0.3,
		"sway_amount": 0.02,
		"breathing_speed": 0.7,
		"posture_height": 0.8,
		"hanging": true,
	},

	"rope_land": {
		"clip": "rope_touchdown",
		"loop": false,
		"base_speed": 1.0,
		"blend_in": 0.15,
		"blend_out": 0.2,
		"sway_amount": 0.03,
		"breathing_speed": 0.8,
		"posture_height": 0.85,
	},

	# FALLING
	"fall_start": {
		"clip": "fall_entry",
		"loop": false,
		"base_speed": 2.0,
		"blend_in": 0.05,
		"blend_out": 0.1,
		"sway_amount": 0.15,
		"breathing_speed": 2.0,
		"posture_height": 0.6,
		"flailing": true,
	},

	"falling": {
		"clip": "fall_loop",
		"loop": true,
		"base_speed": 1.5,
		"blend_in": 0.1,
		"blend_out": 0.1,
		"sway_amount": 0.2,
		"breathing_speed": 2.5,
		"posture_height": 0.5,
		"tumbling": true,
	},

	"land_soft": {
		"clip": "land_recover",
		"loop": false,
		"base_speed": 1.0,
		"blend_in": 0.1,
		"blend_out": 0.3,
		"sway_amount": 0.05,
		"breathing_speed": 1.5,
		"posture_height": 0.7,
	},

	"land_hard": {
		"clip": "land_impact",
		"loop": false,
		"base_speed": 0.8,
		"blend_in": 0.05,
		"blend_out": 0.5,
		"sway_amount": 0.08,
		"breathing_speed": 2.0,
		"posture_height": 0.4,
	},

	# ARRESTED (self-arrest)
	"arrested": {
		"clip": "self_arrest",
		"loop": true,
		"base_speed": 1.0,
		"blend_in": 0.1,
		"blend_out": 0.2,
		"sway_amount": 0.06,
		"breathing_speed": 1.8,
		"posture_height": 0.4,
		"bracing": true,  # Digging in with ice axe
	},

	"arrest_fail": {
		"clip": "arrest_slip",
		"loop": false,
		"base_speed": 1.2,
		"blend_in": 0.1,
		"blend_out": 0.15,
		"sway_amount": 0.1,
		"breathing_speed": 2.0,
		"posture_height": 0.5,
	},

	# RESTING
	"resting": {
		"clip": "rest_sitting",
		"loop": true,
		"base_speed": 0.3,
		"blend_in": 0.5,
		"blend_out": 0.3,
		"sway_amount": 0.01,
		"breathing_speed": 0.4,
		"posture_height": 0.5,
	},

	"resting_exhausted": {
		"clip": "rest_collapsed",
		"loop": true,
		"base_speed": 0.2,
		"blend_in": 0.5,
		"blend_out": 0.5,
		"sway_amount": 0.015,
		"breathing_speed": 0.6,
		"posture_height": 0.3,
	},

	# INCAPACITATED
	"incapacitated": {
		"clip": "incapacitated",
		"loop": true,
		"base_speed": 0.1,
		"blend_in": 0.5,
		"blend_out": 1.0,
		"sway_amount": 0.005,
		"breathing_speed": 0.2,
		"posture_height": 0.2,
	},
}

# =============================================================================
# BLEND SPACES
# =============================================================================

## Blend space for walking speed (0 = standing, 1 = full speed)
const WALK_SPEED_BLEND := {
	"points": [0.0, 0.3, 0.7, 1.0],
	"clips": ["idle", "walk_slow", "walk_normal", "walk_fast"],
}

## Blend space for fatigue (0 = fresh, 1 = exhausted)
const FATIGUE_BLEND := {
	"points": [0.0, 0.3, 0.6, 0.9],
	"modifiers": {
		"speed_mult": [1.0, 0.9, 0.75, 0.5],
		"sway_mult": [1.0, 1.2, 1.5, 2.0],
		"breathing_mult": [1.0, 1.3, 1.8, 2.5],
	},
}

## Blend space for stability/posture (0 = stable, 1 = falling)
const POSTURE_BLEND := {
	"points": [0.0, 0.33, 0.66, 1.0],
	"height_mult": [1.0, 0.95, 0.85, 0.7],
	"sway_mult": [1.0, 1.5, 2.5, 4.0],
}

# =============================================================================
# TRANSITION RULES
# =============================================================================

## Special transition animations between states
const TRANSITIONS := {
	# Format: "from_state|to_state": transition_clip
	"idle|walking": "start_walk",
	"walking|idle": "stop_walk",
	"walking|sliding": "trip_to_slide",
	"sliding|standing": "slide_recover",
	"standing|falling": "lose_balance",
	"falling|standing": "land_recover",
	"walking|roping": "rope_attach",
	"roping|standing": "rope_detach",
}

# =============================================================================
# INJURY MODIFIERS
# =============================================================================

## How injuries affect animations
const INJURY_MODIFIERS := {
	GameEnums.InjuryType.SPRAIN: {
		"speed_mult": 0.7,
		"limp_amount": 0.3,
		"affects_legs": true,
	},
	GameEnums.InjuryType.STRAIN: {
		"speed_mult": 0.85,
		"sway_mult": 1.2,
	},
	GameEnums.InjuryType.FRACTURE: {
		"speed_mult": 0.4,
		"limp_amount": 0.6,
		"guard_arm": true,  # Holding injured limb
	},
	GameEnums.InjuryType.FROSTBITE: {
		"stiff_extremities": true,
		"reduced_grip": true,
	},
	GameEnums.InjuryType.HYPOTHERMIA: {
		"speed_mult": 0.6,
		"shivering": true,
		"sway_mult": 1.5,
	},
	GameEnums.InjuryType.EXHAUSTION: {
		"speed_mult": 0.5,
		"breathing_mult": 2.0,
		"slouched": true,
	},
}

# =============================================================================
# SURFACE EFFECTS
# =============================================================================

## Animation modifications per surface type
const SURFACE_MODIFIERS := {
	GameEnums.SurfaceType.ICE: {
		"slip_chance": 0.3,
		"careful_steps": true,
	},
	GameEnums.SurfaceType.SNOW_POWDER: {
		"speed_mult": 0.8,
		"high_step": true,  # Lifting feet higher
	},
	GameEnums.SurfaceType.ROCK_WET: {
		"slip_chance": 0.15,
		"careful_steps": true,
	},
	GameEnums.SurfaceType.SCREE: {
		"slide_prone": true,
		"unstable_footing": true,
	},
}

# =============================================================================
# HELPER METHODS
# =============================================================================

static func get_animation_data(state_name: String) -> Dictionary:
	return STATE_ANIMATIONS.get(state_name, STATE_ANIMATIONS["idle"])


static func get_transition_clip(from_state: String, to_state: String) -> String:
	var key := "%s|%s" % [from_state, to_state]
	return TRANSITIONS.get(key, "")


static func get_fatigue_modifier(fatigue: float, modifier_name: String) -> float:
	var points: Array = FATIGUE_BLEND["points"]
	var values: Array = FATIGUE_BLEND["modifiers"].get(modifier_name, [1.0, 1.0, 1.0, 1.0])

	# Find interpolation range
	for i in range(points.size() - 1):
		if fatigue <= points[i + 1]:
			var t := (fatigue - points[i]) / (points[i + 1] - points[i])
			return lerpf(values[i], values[i + 1], t)

	return values[-1]


static func get_posture_modifier(posture: float, modifier_name: String) -> float:
	var points: Array = POSTURE_BLEND["points"]
	var values: Array

	if modifier_name == "height":
		values = POSTURE_BLEND["height_mult"]
	elif modifier_name == "sway":
		values = POSTURE_BLEND["sway_mult"]
	else:
		return 1.0

	# Find interpolation range
	for i in range(points.size() - 1):
		if posture <= points[i + 1]:
			var t := (posture - points[i]) / (points[i + 1] - points[i])
			return lerpf(values[i], values[i + 1], t)

	return values[-1]
