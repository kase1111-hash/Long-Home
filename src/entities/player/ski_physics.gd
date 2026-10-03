class_name SkiPhysics
extends Node
## Skis and the splitboard: carving, skidding, and speed control by turn shape
##
## The skier's velocity lives on the slope plane, like a slide's, and this
## steps it before move_and_slide each tick:
## - gravity along the plane
## - the base glides along the skis (kinetic friction about 0.05 on snow),
##   air drag grows with speed squared (less in a tuck), deep snow drags in
##   proportion to speed
## - the edges hold the skis' line: sideways motion is cancelled up to the
##   surface's edge grip and the momentum carries round with the skis (a
##   carve); past the grip they skid, and the skid scrubs speed
## A/D (or Q/E) turn the skis: quickly when slow, but at speed a hard turn is
## a skid. S pivots the skis across the direction of travel for a hockey stop
## or a sideslip. W tucks, or poles and skates on the flat. Straight-lining a
## 35 degree slope reaches 40 m/s, so speed is controlled the way a skier
## controls it: by turning across the fall line and by skidding.
##
## Ice, rock and over-speed are where it goes wrong. Crash risk climbs with
## speed, overloaded edges, ice and tired legs; a crash on a slope a body
## cannot rest on becomes a slide (and arresting with skis on is slower).
## Skis grind to a halt on rock and scree, and every metre costs the bases.

# =============================================================================
# CONSTANTS
# =============================================================================

## Turn rate of the skis (rad/s) when slow and at speed
const PIVOT_RATE := 2.6
const CARVE_RATE := 1.4
## How fast S swings the skis across the line of travel (rad/s)
const BRAKE_PIVOT_RATE := 4.0
## Poling and skating on the flat: push (m/s^2) and the speed it stops helping
const POLE_ACCEL := 1.6
const POLE_TOP_SPEED := 4.0
const BOARD_SKATE_ACCEL := 0.6
const BOARD_SKATE_TOP_SPEED := 1.5
## Side-stepping or herringboning back up a gentle slope (m/s)
const CLIMB_SPEED := 0.35
const CLIMB_MAX_SLOPE := 25.0
## Hard cap on speed (m/s)
const MAX_SPEED := 32.0
## Static friction of a ski at rest on its edges (a few degrees off the
## horizontal and it still stays put)
const STATIC_GLIDE := 0.15
## Crash hazard: base rate at 10 m/s, and the speed scale it grows over
const CRASH_RATE_AT_10 := 0.002
const CRASH_SPEED_SCALE := 4.0
## Seconds without control after a tumble on the spot
const CRASH_RECOVERY := 1.5
## Base damage per metre skied over rock
const ROCK_DAMAGE_PER_METRE := 0.01

# =============================================================================
# STATE
# =============================================================================

var player: PlayerController

## Where the skis point (horizontal unit vector)
var heading: Vector3 = Vector3.FORWARD

## On a splitboard rather than two skis
var is_board: bool = false

## Inputs this tick
var tucked: bool = false
var braking: bool = false

## Sideways slip as a fraction of speed (0 = clean carve), for feedback
var skid: float = 0.0

## Lateral demand over edge grip (above 1 the edges are letting go)
var edge_load: float = 0.0

## Current speed (m/s)
var speed: float = 0.0

var _crash_cooldown: float = 0.0
var _recovery: float = 0.0
var _warned_rock: bool = false
var _rock_distance: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(controller: PlayerController) -> void:
	player = controller
	name = "SkiPhysics"


func _ready() -> void:
	player.state_changed.connect(_on_state_changed)


func _on_state_changed(_old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	if new_state == GameEnums.PlayerMovementState.SKIING:
		_enter()


## Stepping into the bindings (or getting up after a fall): skis across the
## slope, the way a skier stands on a hill
func _enter() -> void:
	is_board = player.footwear == GameEnums.Footwear.SNOWBOARD
	_warned_rock = false
	var facing := player.get_facing_direction()
	facing.y = 0.0
	facing = facing.normalized() if facing.length_squared() > 0.01 else Vector3.FORWARD
	var cell := player.current_cell
	var moving := Vector3(player.velocity.x, 0.0, player.velocity.z)
	if moving.length() > 1.0:
		heading = moving.normalized()
	elif cell != null and cell.slope_angle > 5.0 and cell.slope_direction.length_squared() > 0.01:
		var across := cell.slope_direction.cross(Vector3.UP).normalized()
		heading = across if across.dot(facing) >= 0.0 else -across
	else:
		heading = facing


# =============================================================================
# PHYSICS
# =============================================================================

## One tick of ski physics; called by PlayerMovement before move_and_slide
func physics_step(delta: float) -> void:
	if player.current_state != GameEnums.PlayerMovementState.SKIING:
		return
	_crash_cooldown = maxf(0.0, _crash_cooldown - delta)
	_recovery = maxf(0.0, _recovery - delta)

	var cell := player.current_cell
	var surface := cell.surface_type if cell else GameEnums.SurfaceType.SNOW_FIRM
	var slope := cell.slope_angle if cell else 0.0

	var input := player.input_handler.move_input
	var steer := clampf(input.x + player.input_handler.get_lean_input(), -1.0, 1.0)
	if _recovery > 0.0:
		input = Vector2.ZERO
		steer = 0.0
	tucked = input.y < -0.5
	braking = input.y > 0.5

	var velocity := player.velocity
	if not player.is_on_floor():
		# In the air: the skis keep their line, the air drags, gravity is the controller's
		speed = velocity.length()
		if speed > 0.01:
			velocity -= velocity / speed * minf(TractionModel.SKI_DRAG_UPRIGHT * speed * speed * delta, speed)
		player.velocity = velocity
		_face_heading(delta)
		return

	var normal := player.get_floor_normal()
	velocity = TractionModel.onto_slope_plane(velocity, normal)
	speed = velocity.length()

	# Stamping out a platform to step in or out of the bindings: stand still
	if player.is_busy_with_gear():
		player.velocity = velocity.move_toward(Vector3.ZERO, 6.0 * delta)
		speed = player.velocity.length()
		return

	var gravity_vec := Vector3.DOWN * TractionModel.GRAVITY
	var along_plane := gravity_vec - normal * gravity_vec.dot(normal)
	var normal_accel := TractionModel.GRAVITY * maxf(normal.y, 0.05)

	var heading_before := heading
	_steer(steer, velocity, delta)
	var turn_rate := absf(heading_before.signed_angle_to(heading, Vector3.UP)) / maxf(delta, 0.0001)

	# The skis on the slope plane, and the edge direction across them
	var ski := heading - normal * heading.dot(normal)
	if ski.length_squared() < 0.0001:
		ski = along_plane.normalized() if along_plane.length_squared() > 0.0001 else Vector3.FORWARD
	ski = ski.normalized()
	var side := normal.cross(ski).normalized()

	var v_along := velocity.dot(ski)
	var v_side := velocity.dot(side)

	# --- Along the skis: gravity, base glide, air and deep-snow drag
	var gravity_along := along_plane.dot(ski)
	v_along += gravity_along * delta
	var drag := TractionModel.SKI_DRAG_TUCK if (tucked and speed > 3.0) else TractionModel.SKI_DRAG_UPRIGHT
	var glide := TractionModel.ski_glide(surface)
	var loss := (glide * normal_accel + drag * speed * speed + TractionModel.ski_sink_drag(surface, is_board) * speed) * delta
	if absf(v_along) <= loss:
		v_along = 0.0
	else:
		v_along -= signf(v_along) * loss

	# Standing still on the edges, a ski near the horizontal stays put (static
	# friction and a little weight on the uphill edge)
	var resting := speed < 0.3 and absf(steer) < 0.1 and not tucked
	if resting and absf(gravity_along) <= STATIC_GLIDE * normal_accel:
		v_along = 0.0

	# Poling and skating on the flat, side-stepping up a gentle slope
	if tucked and absf(gravity_along) < 1.0:
		var push := BOARD_SKATE_ACCEL if is_board else POLE_ACCEL
		var top := BOARD_SKATE_TOP_SPEED if is_board else POLE_TOP_SPEED
		if v_along < top:
			v_along = minf(v_along + push * delta, top)
	elif input.y < -0.5 and gravity_along < 0.0 and speed < 1.5 and slope < CLIMB_MAX_SLOPE:
		v_along = move_toward(v_along, CLIMB_SPEED, 2.0 * delta)

	# --- Across the skis: the edges
	var grip := TractionModel.ski_brake_grip(surface) if braking else TractionModel.ski_edge_grip(surface, is_board)
	var grip_accel := grip * normal_accel * _technique()
	var capacity := grip_accel * delta
	var gravity_side := along_plane.dot(side)
	v_side += gravity_side * delta
	# How hard the edges are asked to work: the lateral acceleration a clean
	# carve of this turn would need, over what the snow and legs can give
	edge_load = clampf((speed * turn_rate + absf(gravity_side)) / maxf(grip_accel, 0.01), 0.0, 3.0)
	if absf(v_side) <= capacity:
		# The edge holds: the momentum carries round with the skis
		if not braking and absf(v_along) > 0.5:
			v_along = signf(v_along) * sqrt(v_along * v_along + v_side * v_side)
		v_side = 0.0
	else:
		# Skidding: the edge scrapes and scrubs sideways speed
		v_side -= signf(v_side) * capacity

	velocity = ski * v_along + side * v_side
	speed = velocity.length()
	if speed > MAX_SPEED:
		velocity = velocity / speed * MAX_SPEED
		speed = MAX_SPEED
	skid = clampf(absf(v_side) / maxf(speed, 1.0), 0.0, 1.0)

	player.velocity = velocity
	_face_heading(delta)

	_apply_effort(delta)
	_check_surface(surface, delta)
	if player.current_state == GameEnums.PlayerMovementState.SKIING:
		_check_crash(surface, delta)


## Turn the skis: A/D pivot them (quick when slow, gentler at speed); S
## swings them across the line of travel for a stop
func _steer(steer: float, velocity: Vector3, delta: float) -> void:
	var travel := Vector3(velocity.x, 0.0, velocity.z)
	if braking and travel.length() > 0.3:
		var across := travel.normalized().cross(Vector3.UP).normalized()
		var target := across if across.dot(heading) >= 0.0 else -across
		heading = _rotate_toward(heading, target, BRAKE_PIVOT_RATE * delta)
		return
	if absf(steer) < 0.1:
		return
	var rate := lerpf(PIVOT_RATE, CARVE_RATE, clampf(speed / 15.0, 0.0, 1.0))
	heading = heading.rotated(Vector3.UP, -steer * rate * delta).normalized()


func _rotate_toward(from: Vector3, to: Vector3, max_angle: float) -> Vector3:
	var angle := from.signed_angle_to(to, Vector3.UP)
	return from.rotated(Vector3.UP, clampf(angle, -max_angle, max_angle)).normalized()


## Strong, rested legs hold an edge; tired or hurt ones less
func _technique() -> float:
	var technique := 1.0
	if player.body_state:
		technique *= lerpf(0.6, 1.0, player.body_state.get_slide_control_modifier())
	technique *= lerpf(0.7, 1.0, clampf(player.stability, 0.0, 1.0))
	return technique


func _face_heading(delta: float) -> void:
	var target := PlayerMovement.yaw_facing(heading)
	var diff := wrapf(target - player.rotation.y, -PI, PI)
	player.rotation.y += signf(diff) * minf(absf(diff), 8.0 * delta)


func _apply_effort(delta: float) -> void:
	# Legs burn in hard turns and long skids
	var rate := 0.0003 + 0.0004 * clampf(edge_load, 0.0, 2.0) + 0.0004 * skid
	if braking:
		rate += 0.0004
	player.add_fatigue(rate * delta)

# =============================================================================
# HAZARDS
# =============================================================================

## Skis on rock: they grind to a halt, the bases suffer, a fast arrival trips you
func _check_surface(surface: GameEnums.SurfaceType, delta: float) -> void:
	if TractionModel.is_skiable(surface):
		_rock_distance = 0.0
		return
	if not _warned_rock:
		_warned_rock = true
		player.say("Rock under your %s." % ("board" if is_board else "skis"), 2.0)
	_rock_distance += speed * delta
	var item := GameEnums.GearType.SNOWBOARD if is_board else GameEnums.GearType.SKIS
	if player.gear_state != null:
		player.gear_state.damage_item(item, ROCK_DAMAGE_PER_METRE * speed * delta)
		if not player.gear_state.has_item(item):
			player.say("A binding tears out. You walk from here.", 2.5)
			EventBus.record_incident("skis_broken", {"position": player.global_position})
			player.set_footwear(GameEnums.Footwear.BOOTS)
			return
	if speed > 3.0 and _crash_cooldown <= 0.0:
		var trip := clampf((speed - 3.0) / 6.0, 0.0, 0.9) * 2.0
		if randf() < trip * delta:
			_crash("rock")


func _check_crash(surface: GameEnums.SurfaceType, delta: float) -> void:
	if _crash_cooldown > 0.0 or speed < 3.0:
		return
	var surface_factor := 1.0
	match surface:
		GameEnums.SurfaceType.ICE:
			surface_factor = 4.0
		GameEnums.SurfaceType.MIXED:
			surface_factor = 3.0
		GameEnums.SurfaceType.SNOW_POWDER:
			surface_factor = 0.6
		GameEnums.SurfaceType.SNOW_SOFT:
			surface_factor = 0.8
		GameEnums.SurfaceType.SNOW_PACKED:
			surface_factor = 0.9
	var fatigue := player.get_fatigue()
	# Skidding hard at speed is where an edge catches; a deliberate stop less so
	var violence := skid * speed / 10.0
	if braking:
		violence *= 0.5
	var rate := CRASH_RATE_AT_10 * exp((speed - 10.0) / CRASH_SPEED_SCALE)
	rate *= surface_factor * (1.0 + 3.0 * fatigue * fatigue) * (1.0 + 4.0 * violence * violence)
	if randf() < rate * delta:
		_crash("edge" if violence > 0.5 else "speed")


## Landing a drop on skis
func on_landed(impact: float) -> void:
	if player.current_state != GameEnums.PlayerMovementState.SKIING:
		return
	if impact < 5.0:
		return
	if impact > 8.0 or randf() < (impact - 5.0) / 3.0:
		_crash("landing")
		if impact > 8.0 and player.body_state != null:
			_injure(clampf(0.2 + (impact - 8.0) / 8.0, 0.2, 0.9))


func _crash(reason: String) -> void:
	_crash_cooldown = 2.0
	var cell := player.current_cell
	var slope := cell.slope_angle if cell else 0.0
	var surface := cell.surface_type if cell else GameEnums.SurfaceType.SNOW_FIRM
	EventBus.record_incident("ski_crash", {
		"reason": reason,
		"speed": speed,
		"slope": slope,
		"surface": GameEnums.SurfaceType.keys()[surface],
		"board": is_board
	})

	# Knees on skis, wrists on a board
	var injury_chance := clampf(speed / 18.0, 0.05, 0.6) * (0.6 if is_board else 1.0)
	if randf() < injury_chance:
		_injure(clampf(0.15 + speed / 40.0, 0.15, 0.8))

	var body_hold := TractionModel.max_holding_slope(TractionModel.body_static_friction(surface))
	if slope > body_hold and speed > 2.0:
		player.say(_crash_line(reason) + " You're sliding.", 2.0)
		player.velocity *= 0.8
		player.start_slide(true, "ski_crash")
	else:
		player.say(_crash_line(reason), 2.0)
		player.velocity *= 0.2
		player.set_stability(player.stability - 0.4)
		_recovery = CRASH_RECOVERY


func _crash_line(reason: String) -> String:
	match reason:
		"rock":
			return "The skis stop dead on the rock and you don't."
		"landing":
			return "You land it badly."
		"edge":
			return "An edge catches."
	return "Too fast. You go down."


func _injure(severity: float) -> void:
	if player.body_state == null:
		return
	var parts: Array = [GameEnums.BodyPart.LEFT_LEG, GameEnums.BodyPart.RIGHT_LEG]
	if is_board:
		parts = [GameEnums.BodyPart.LEFT_HAND, GameEnums.BodyPart.RIGHT_HAND, GameEnums.BodyPart.LEFT_ARM]
	var part: GameEnums.BodyPart = parts[randi() % parts.size()]
	var kind := GameEnums.InjuryType.SPRAIN if severity < 0.5 else GameEnums.InjuryType.FRACTURE
	var injury := Injury.new(kind, severity, part, 0.0)
	player.body_state.add_injury(injury)
	EventBus.injury_occurred.emit(injury)
	EventBus.body_state_updated.emit(player.body_state)

# =============================================================================
# QUERIES
# =============================================================================

## Balance on the skis (0-1) for posture, camera sway and animation
func get_stability() -> float:
	var stability := 1.0
	stability -= clampf((speed - 8.0) / 20.0, 0.0, 0.4)
	stability -= clampf(edge_load - 1.0, 0.0, 1.0) * 0.2
	stability -= skid * clampf(speed / 15.0, 0.0, 1.0) * 0.3
	var cell := player.current_cell
	if cell != null and cell.surface_type == GameEnums.SurfaceType.ICE:
		stability -= 0.2
	if _recovery > 0.0:
		stability -= 0.5
	return clampf(stability, 0.15, 1.0)


func get_debug_info() -> Dictionary:
	return {
		"speed": speed,
		"heading": heading,
		"skid": skid,
		"edge_load": edge_load,
		"tucked": tucked,
		"braking": braking,
		"board": is_board
	}
