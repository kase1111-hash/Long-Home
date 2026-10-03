class_name TractionModel
extends RefCounted
## Footing and sliding physics shared by walking, downclimbing, glissading,
## self-arrest and skiing.
##
## Every coefficient here is an effective friction between climber and
## mountain. A stance on a slope of angle a needs tan(a) of it, so boots with
## 0.7 on firm snow hold to about 35 degrees and skate beyond; crampons with
## 1.05 hold to about 46. Downclimbing adds the hands and the axe, braking adds
## the heels and the spike, and an arrest adds the pick. The numbers follow
## mountaineering rules of thumb (boots skate on ice, crampons ball up in warm
## slush, a glissade on soft snow is controllable and one on hard snow is not,
## an axe arrest works on firm snow and fails on ice) rather than lab data;
## tests/test_physics_model.gd pins the behaviour so tuning stays deliberate.
##
## Everything is static and side-effect free so it can be checked headless.

# =============================================================================
# CONSTANTS
# =============================================================================

const GRAVITY := 9.8

## Extra friction a moving stance needs per m/s (braking each step downhill)
const SPEED_GRIP_DEMAND := 0.04

## Air and snow drag on a sliding body (1/m): v_terminal = sqrt(a / drag)
const BODY_DRAG := 0.008
## Skier drag, upright and tucked (0.5 * rho * CdA / mass at altitude)
const SKI_DRAG_UPRIGHT := 0.0029
const SKI_DRAG_TUCK := 0.0013

## Margin (grip minus demand) scale for the slip hazard: every 0.04 of spare
## grip makes a slip e times rarer
const SLIP_MARGIN_SCALE := 0.04
## Slips per second with no margin to spare
const SLIP_RATE_AT_ZERO := 2.0
## Slips per second once the footing cannot hold at all
const SLIP_RATE_NO_GRIP := 20.0

## Mountaineering boots: kicked steps in snow, rubber on rock
const BOOT_GRIP := {
	GameEnums.SurfaceType.SNOW_FIRM: 0.70,
	GameEnums.SurfaceType.SNOW_SOFT: 0.85,
	GameEnums.SurfaceType.SNOW_PACKED: 0.60,
	GameEnums.SurfaceType.SNOW_POWDER: 0.75,
	GameEnums.SurfaceType.ICE: 0.12,
	GameEnums.SurfaceType.ROCK: 0.90,
	GameEnums.SurfaceType.ROCK_DRY: 0.95,
	GameEnums.SurfaceType.ROCK_WET: 0.45,
	GameEnums.SurfaceType.SCREE: 0.75,
	GameEnums.SurfaceType.GRASS: 0.65,
	GameEnums.SurfaceType.MUD: 0.32,
	GameEnums.SurfaceType.MIXED: 0.50,
}

## 12-point crampons: bite in ice and hard snow, skate on bare rock
const CRAMPON_GRIP := {
	GameEnums.SurfaceType.SNOW_FIRM: 1.05,
	GameEnums.SurfaceType.SNOW_SOFT: 0.90,
	GameEnums.SurfaceType.SNOW_PACKED: 1.00,
	GameEnums.SurfaceType.SNOW_POWDER: 0.78,
	GameEnums.SurfaceType.ICE: 1.15,
	GameEnums.SurfaceType.ROCK: 0.72,
	GameEnums.SurfaceType.ROCK_DRY: 0.75,
	GameEnums.SurfaceType.ROCK_WET: 0.55,
	GameEnums.SurfaceType.SCREE: 0.72,
	GameEnums.SurfaceType.GRASS: 0.70,
	GameEnums.SurfaceType.MUD: 0.50,
	GameEnums.SurfaceType.MIXED: 0.95,
}

## Wet snow packs into the crampon frame above this air temperature (C)
const BALLING_TEMPERATURE := -1.0
## Grip of balled-up crampons in soft snow (worse than bare boots)
const BALLED_CRAMPON_GRIP := 0.70

## Pick and shaft placements while facing in
const AXE_SUPPORT := {
	GameEnums.SurfaceType.SNOW_FIRM: 0.35,
	GameEnums.SurfaceType.SNOW_PACKED: 0.35,
	GameEnums.SurfaceType.SNOW_SOFT: 0.30,
	GameEnums.SurfaceType.SNOW_POWDER: 0.18,
	GameEnums.SurfaceType.ICE: 0.45,
	GameEnums.SurfaceType.MIXED: 0.35,
}

## Hand holds while facing in (scaled by hand dexterity)
const HAND_SUPPORT := {
	GameEnums.SurfaceType.ROCK: 0.45,
	GameEnums.SurfaceType.ROCK_DRY: 0.45,
	GameEnums.SurfaceType.ROCK_WET: 0.25,
	GameEnums.SurfaceType.MIXED: 0.30,
	GameEnums.SurfaceType.SCREE: 0.10,
	GameEnums.SurfaceType.GRASS: 0.15,
	GameEnums.SurfaceType.MUD: 0.05,
	GameEnums.SurfaceType.SNOW_FIRM: 0.10,
	GameEnums.SurfaceType.SNOW_PACKED: 0.10,
	GameEnums.SurfaceType.SNOW_SOFT: 0.10,
	GameEnums.SurfaceType.SNOW_POWDER: 0.08,
}

## Kinetic friction of a sliding body (sitting glissade, or a fall)
const GLIDE_FRICTION := {
	GameEnums.SurfaceType.SNOW_FIRM: 0.22,
	GameEnums.SurfaceType.SNOW_PACKED: 0.20,
	GameEnums.SurfaceType.SNOW_SOFT: 0.42,
	GameEnums.SurfaceType.SNOW_POWDER: 0.50,
	GameEnums.SurfaceType.ICE: 0.06,
	GameEnums.SurfaceType.ROCK: 0.65,
	GameEnums.SurfaceType.ROCK_DRY: 0.70,
	GameEnums.SurfaceType.ROCK_WET: 0.35,
	GameEnums.SurfaceType.SCREE: 0.50,
	GameEnums.SurfaceType.GRASS: 0.45,
	GameEnums.SurfaceType.MUD: 0.30,
	GameEnums.SurfaceType.MIXED: 0.38,
}

## Static friction margin of a body at rest over its kinetic friction
const BODY_STATIC_EXTRA := 0.12

## Heels dug in while glissading
const HEEL_BRAKE := {
	GameEnums.SurfaceType.SNOW_FIRM: 0.30,
	GameEnums.SurfaceType.SNOW_PACKED: 0.27,
	GameEnums.SurfaceType.SNOW_SOFT: 0.35,
	GameEnums.SurfaceType.SNOW_POWDER: 0.30,
	GameEnums.SurfaceType.ICE: 0.03,
	GameEnums.SurfaceType.SCREE: 0.20,
	GameEnums.SurfaceType.MIXED: 0.10,
	GameEnums.SurfaceType.GRASS: 0.20,
	GameEnums.SurfaceType.MUD: 0.15,
}

## Axe spike dragged as a rudder and brake while glissading
const SPIKE_BRAKE := {
	GameEnums.SurfaceType.SNOW_FIRM: 0.30,
	GameEnums.SurfaceType.SNOW_PACKED: 0.27,
	GameEnums.SurfaceType.SNOW_SOFT: 0.30,
	GameEnums.SurfaceType.SNOW_POWDER: 0.22,
	GameEnums.SurfaceType.ICE: 0.04,
	GameEnums.SurfaceType.SCREE: 0.10,
	GameEnums.SurfaceType.MIXED: 0.10,
}

## Friction of a full self-arrest: body on the axe, pick driven in
const ARREST_AXE := {
	GameEnums.SurfaceType.SNOW_FIRM: 1.25,
	GameEnums.SurfaceType.SNOW_PACKED: 1.15,
	GameEnums.SurfaceType.SNOW_SOFT: 0.95,
	GameEnums.SurfaceType.SNOW_POWDER: 0.70,
	GameEnums.SurfaceType.ICE: 0.30,
	GameEnums.SurfaceType.SCREE: 0.45,
	GameEnums.SurfaceType.MIXED: 0.55,
	GameEnums.SurfaceType.GRASS: 0.50,
	GameEnums.SurfaceType.MUD: 0.40,
}

## Self-arrest without an axe: hands, knees and boot toes
const ARREST_HANDS := {
	GameEnums.SurfaceType.SNOW_FIRM: 0.50,
	GameEnums.SurfaceType.SNOW_PACKED: 0.45,
	GameEnums.SurfaceType.SNOW_SOFT: 0.70,
	GameEnums.SurfaceType.SNOW_POWDER: 0.60,
	GameEnums.SurfaceType.ICE: 0.08,
	GameEnums.SurfaceType.SCREE: 0.55,
	GameEnums.SurfaceType.MIXED: 0.30,
	GameEnums.SurfaceType.GRASS: 0.55,
	GameEnums.SurfaceType.MUD: 0.35,
}

## Speed (m/s) above which the pick is torn out when it bites
const ARREST_HOLD_SPEED := {
	GameEnums.SurfaceType.SNOW_FIRM: 9.0,
	GameEnums.SurfaceType.SNOW_PACKED: 8.5,
	GameEnums.SurfaceType.SNOW_SOFT: 11.0,
	GameEnums.SurfaceType.SNOW_POWDER: 12.0,
	GameEnums.SurfaceType.ICE: 5.0,
}

## Ski base on the surface (waxed ski on snow glides; on rock it grinds)
const SKI_GLIDE := {
	GameEnums.SurfaceType.SNOW_FIRM: 0.05,
	GameEnums.SurfaceType.SNOW_PACKED: 0.04,
	GameEnums.SurfaceType.SNOW_SOFT: 0.08,
	GameEnums.SurfaceType.SNOW_POWDER: 0.07,
	GameEnums.SurfaceType.ICE: 0.03,
	GameEnums.SurfaceType.MIXED: 0.18,
	GameEnums.SurfaceType.SCREE: 0.50,
	GameEnums.SurfaceType.GRASS: 0.35,
	GameEnums.SurfaceType.MUD: 0.40,
	GameEnums.SurfaceType.ROCK: 0.60,
	GameEnums.SurfaceType.ROCK_DRY: 0.60,
	GameEnums.SurfaceType.ROCK_WET: 0.45,
}

## Lateral hold of a set edge (how hard you can carve before it skids)
const SKI_EDGE := {
	GameEnums.SurfaceType.SNOW_FIRM: 0.95,
	GameEnums.SurfaceType.SNOW_PACKED: 1.00,
	GameEnums.SurfaceType.SNOW_SOFT: 0.85,
	GameEnums.SurfaceType.SNOW_POWDER: 0.75,
	GameEnums.SurfaceType.ICE: 0.32,
	GameEnums.SurfaceType.MIXED: 0.50,
}

## Resistance of a deliberate skid (hockey stop, sideslip, snowplough). A set
## edge plows a groove instead of sliding, so on snow this tops a carving
## edge's hold; on ice it has nothing to bite
const SKI_BRAKE := {
	GameEnums.SurfaceType.SNOW_FIRM: 1.05,
	GameEnums.SurfaceType.SNOW_PACKED: 1.05,
	GameEnums.SurfaceType.SNOW_SOFT: 1.10,
	GameEnums.SurfaceType.SNOW_POWDER: 0.90,
	GameEnums.SurfaceType.ICE: 0.25,
	GameEnums.SurfaceType.MIXED: 0.70,
}

## Deep-snow drag on skis (1/s per m/s of speed): powder floats but slows
const SKI_SINK_DRAG := {
	GameEnums.SurfaceType.SNOW_POWDER: 0.22,
	GameEnums.SurfaceType.SNOW_SOFT: 0.10,
}

## How much a surface cushions a landing (divides impact speed)
const LANDING_SOFTNESS := {
	GameEnums.SurfaceType.SNOW_POWDER: 1.6,
	GameEnums.SurfaceType.SNOW_SOFT: 1.4,
	GameEnums.SurfaceType.SNOW_FIRM: 1.15,
	GameEnums.SurfaceType.SNOW_PACKED: 1.1,
	GameEnums.SurfaceType.ICE: 0.9,
	GameEnums.SurfaceType.GRASS: 1.15,
	GameEnums.SurfaceType.MUD: 1.25,
	GameEnums.SurfaceType.SCREE: 1.05,
}

# =============================================================================
# SURFACE CLASSES
# =============================================================================

static func is_snow(surface: GameEnums.SurfaceType) -> bool:
	return surface in [
		GameEnums.SurfaceType.SNOW_FIRM,
		GameEnums.SurfaceType.SNOW_SOFT,
		GameEnums.SurfaceType.SNOW_PACKED,
		GameEnums.SurfaceType.SNOW_POWDER,
	]


static func is_rock(surface: GameEnums.SurfaceType) -> bool:
	return surface in [
		GameEnums.SurfaceType.ROCK,
		GameEnums.SurfaceType.ROCK_DRY,
		GameEnums.SurfaceType.ROCK_WET,
	]


## Surfaces a body can glissade or slide down (snow, scree)
static func is_glissadable(surface: GameEnums.SurfaceType) -> bool:
	return is_snow(surface) or surface == GameEnums.SurfaceType.SCREE


## Surfaces skis run on without grinding to a halt
static func is_skiable(surface: GameEnums.SurfaceType) -> bool:
	return is_snow(surface) or surface == GameEnums.SurfaceType.ICE or surface == GameEnums.SurfaceType.MIXED


static func _lookup(table: Dictionary, surface: GameEnums.SurfaceType, fallback: float) -> float:
	var value: float = table.get(surface, fallback)
	return value

# =============================================================================
# FOOTING
# =============================================================================

## Effective grip of what is on the feet. crampon_effectiveness blends boots
## (0) into crampons (1) for worn or damaged points. Skis are handled by the
## ski physics and answer with boot grip here (a stance beside the skis).
static func foot_grip(
	surface: GameEnums.SurfaceType,
	footwear: GameEnums.Footwear,
	crampon_effectiveness: float = 1.0,
	air_temperature: float = -8.0
) -> float:
	var boot := _lookup(BOOT_GRIP, surface, 0.6)
	if footwear != GameEnums.Footwear.CRAMPONS:
		return boot

	var crampon := _lookup(CRAMPON_GRIP, surface, 0.7)
	if surface == GameEnums.SurfaceType.SNOW_SOFT and air_temperature > BALLING_TEMPERATURE:
		crampon = BALLED_CRAMPON_GRIP
	return lerpf(boot, crampon, clampf(crampon_effectiveness, 0.0, 1.0))


## Friction a stance needs: the slope itself plus braking each step
static func required_grip(slope_degrees: float, speed: float) -> float:
	var slope := clampf(slope_degrees, 0.0, 89.0)
	return tan(deg_to_rad(slope)) + SPEED_GRIP_DEMAND * maxf(speed, 0.0)


## Steepest slope (degrees) a grip can hold standing still
static func max_holding_slope(grip: float) -> float:
	return rad_to_deg(atan(maxf(grip, 0.0)))


## Extra hold from facing in: axe placements in snow and ice, hand holds on
## rock. hand_dexterity is 0-1 (gloves, cold hands). Pick placements in ice
## need crampons under you to be worth much.
static func downclimb_support(
	surface: GameEnums.SurfaceType,
	has_axe: bool,
	axe_effectiveness: float,
	hand_dexterity: float,
	footwear: GameEnums.Footwear
) -> float:
	var axe := 0.0
	if has_axe:
		axe = _lookup(AXE_SUPPORT, surface, 0.0) * clampf(axe_effectiveness, 0.0, 1.0)
		if surface == GameEnums.SurfaceType.ICE and footwear != GameEnums.Footwear.CRAMPONS:
			axe *= 0.5
	var hands := _lookup(HAND_SUPPORT, surface, 0.05) * clampf(hand_dexterity, 0.0, 1.0)
	return maxf(axe, hands) + 0.5 * minf(axe, hands)


## Expected slips per second for a grip margin (grip minus demand)
static func slip_rate(margin: float) -> float:
	if margin <= 0.0:
		return SLIP_RATE_NO_GRIP
	return SLIP_RATE_AT_ZERO * exp(-margin / SLIP_MARGIN_SCALE)


## Chance that a slip is more than a stagger (becomes a slide or a fall)
## before any self-belay catches it
static func slip_escalation_chance(margin: float) -> float:
	if margin <= 0.0:
		return 1.0
	return clampf(0.4 - 2.5 * margin, 0.03, 1.0)


## Balance (0-1) that a grip margin supports; feeds PostureSystem
static func stability_from_margin(margin: float) -> float:
	return clampf(0.2 + margin * 2.7, 0.15, 1.0)

# =============================================================================
# FOOT SPEED
# =============================================================================

## Walking pace multiplier for the surface underfoot (postholing, shuffling
## on ice in boots, crampons scraping over rock)
static func walk_surface_speed(surface: GameEnums.SurfaceType, footwear: GameEnums.Footwear) -> float:
	var crampons := footwear == GameEnums.Footwear.CRAMPONS
	match surface:
		GameEnums.SurfaceType.SNOW_SOFT:
			return 0.75
		GameEnums.SurfaceType.SNOW_POWDER:
			return 0.6
		GameEnums.SurfaceType.ICE:
			return 0.9 if crampons else 0.55
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY:
			return 0.8 if crampons else 1.0
		GameEnums.SurfaceType.ROCK_WET:
			return 0.75 if crampons else 0.85
		GameEnums.SurfaceType.SCREE:
			return 0.7 if crampons else 0.75
		GameEnums.SurfaceType.GRASS:
			return 0.85 if crampons else 1.0
		GameEnums.SurfaceType.MUD:
			return 0.8
		GameEnums.SurfaceType.MIXED:
			return 0.85 if crampons else 0.8
	return 1.0


## Tobler's hiking function, normalised to 1 on the flat and softened for a
## game-length descent. grade is rise over run along the direction of travel
## (negative downhill); cross_grade is the side slope you walk across.
## Steep descents are slower than the flat, steep climbs much slower still.
static func tobler_factor(grade: float, cross_grade: float, surface: GameEnums.SurfaceType) -> float:
	var excess := absf(grade + 0.05) - 0.05
	var factor := 1.0
	if excess > 0.0:
		var k := 3.5
		if grade < -0.05:
			# Plunge-stepping down soft snow is the fast way down
			match surface:
				GameEnums.SurfaceType.SNOW_SOFT:
					k = 0.7
				GameEnums.SurfaceType.SNOW_POWDER:
					k = 0.8
				_:
					k = 1.1
		factor = exp(-k * excess)
	factor *= 1.0 - 0.45 * clampf(absf(cross_grade), 0.0, 1.0)
	return clampf(factor, 0.15, 1.2)


## Downclimbing pace along the face (m/s) before body condition: deliberate
## on snow, slower on rock, slow on ice even with points, very slow in boots
static func downclimb_speed(slope_degrees: float, surface: GameEnums.SurfaceType, footwear: GameEnums.Footwear) -> float:
	var base := 0.55
	var steep := clampf(1.0 - (slope_degrees - 40.0) / 35.0, 0.3, 1.0)
	var crampons := footwear == GameEnums.Footwear.CRAMPONS
	var surface_factor := 1.0
	match surface:
		GameEnums.SurfaceType.SNOW_SOFT:
			surface_factor = 0.85
		GameEnums.SurfaceType.SNOW_POWDER:
			surface_factor = 0.7
		GameEnums.SurfaceType.ICE:
			surface_factor = 0.65 if crampons else 0.35
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY:
			surface_factor = 0.8 * (0.85 if crampons else 1.0)
		GameEnums.SurfaceType.ROCK_WET:
			surface_factor = 0.55
		GameEnums.SurfaceType.MIXED:
			surface_factor = 0.6
		GameEnums.SurfaceType.SCREE:
			surface_factor = 0.7
		GameEnums.SurfaceType.GRASS:
			surface_factor = 0.8
		GameEnums.SurfaceType.MUD:
			surface_factor = 0.6
	return base * steep * surface_factor

# =============================================================================
# GLISSADE, TUMBLE AND SELF-ARREST
# =============================================================================

## Kinetic friction of a body sliding on the surface
static func glide_friction(surface: GameEnums.SurfaceType) -> float:
	return _lookup(GLIDE_FRICTION, surface, 0.5)


## Friction that brings a sliding body to rest (it stops once tan(slope)
## drops below this)
static func body_static_friction(surface: GameEnums.SurfaceType) -> float:
	return glide_friction(surface) + BODY_STATIC_EXTRA


## Extra friction from braking: heels always, the spike if an axe is in hand
static func brake_friction(surface: GameEnums.SurfaceType, has_axe: bool) -> float:
	var brake := _lookup(HEEL_BRAKE, surface, 0.1)
	if has_axe:
		brake += _lookup(SPIKE_BRAKE, surface, 0.05)
	return brake


## Friction of a self-arrest once the pick (or the hands) bite
static func arrest_friction(surface: GameEnums.SurfaceType, has_axe: bool) -> float:
	if has_axe:
		return _lookup(ARREST_AXE, surface, 0.25)
	return _lookup(ARREST_HANDS, surface, glide_friction(surface))


## Speed above which the pick is torn out as it bites
static func arrest_hold_speed(surface: GameEnums.SurfaceType) -> float:
	return _lookup(ARREST_HOLD_SPEED, surface, 6.0)


## Acceleration (m/s^2) down the fall line of a body with friction mu on a
## slope; negative means it decelerates
static func slope_acceleration(slope_degrees: float, mu: float) -> float:
	var a := deg_to_rad(clampf(slope_degrees, 0.0, 89.0))
	return GRAVITY * (sin(a) - mu * cos(a))


## Terminal sliding speed for a slope, friction and drag (0 if it stops)
static func terminal_speed(slope_degrees: float, mu: float, drag: float) -> float:
	var a := slope_acceleration(slope_degrees, mu)
	if a <= 0.0 or drag <= 0.0:
		return 0.0
	return sqrt(a / drag)


## Distance (m) to stop from a speed with friction mu on a slope, or INF when
## the friction cannot beat gravity
static func stopping_distance(speed: float, slope_degrees: float, mu: float) -> float:
	var decel := -slope_acceleration(slope_degrees, mu)
	if decel <= 0.0:
		return INF
	return speed * speed / (2.0 * decel)

# =============================================================================
# SKIS AND SPLITBOARD
# =============================================================================

static func ski_glide(surface: GameEnums.SurfaceType) -> float:
	return _lookup(SKI_GLIDE, surface, 0.5)


static func ski_edge_grip(surface: GameEnums.SurfaceType, is_board: bool) -> float:
	var grip := _lookup(SKI_EDGE, surface, 0.4)
	if is_board:
		grip *= 0.85 if surface == GameEnums.SurfaceType.ICE else 0.92
	return grip


static func ski_brake_grip(surface: GameEnums.SurfaceType) -> float:
	return _lookup(SKI_BRAKE, surface, 0.7)


static func ski_sink_drag(surface: GameEnums.SurfaceType, is_board: bool) -> float:
	var drag := _lookup(SKI_SINK_DRAG, surface, 0.0)
	if is_board:
		drag *= 0.7  # A board floats better in deep snow
	return drag

# =============================================================================
# SLOPE PLANE
# =============================================================================

## Put a CharacterBody3D velocity back on the slope plane. On the floor,
## move_and_slide drops the vertical part of the velocity, so a slide down a
## slope comes back horizontal and a plain projection would shrink it every
## tick. Lifting the horizontal part onto the plane keeps what the slide set
## (and whatever a collision took off it).
static func onto_slope_plane(velocity: Vector3, normal: Vector3) -> Vector3:
	if normal.y < 0.05:
		return velocity - normal * velocity.dot(normal)
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var lift := -horizontal.dot(normal) / normal.y
	return horizontal + Vector3(0.0, lift, 0.0)

# =============================================================================
# FALLS
# =============================================================================

static func landing_softness(surface: GameEnums.SurfaceType) -> float:
	return _lookup(LANDING_SOFTNESS, surface, 1.0)
