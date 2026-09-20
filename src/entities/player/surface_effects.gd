class_name PlayerSurfaceEffects
extends Node3D
## Particles the climber kicks up. While sliding (or digging in to self-arrest)
## a plume of snow spray or dust trails the boots: the medium and colour follow
## the surface underfoot, the rate and reach follow speed. A slide ending in a
## tumble, a hard landing or a stumble throws up a burst, and footsteps on
## loose ground leave small puffs. Lives in the player scene next to the mesh.
##
## Every emitter is top-level and placed in world space each physics frame,
## so the climber's own rotation never bends the plume, and all of them use
## CPUParticles3D with soft billboard sprites (works on every renderer).

# =============================================================================
# CONSTANTS
# =============================================================================

## What is being thrown up
enum Medium { NONE, SNOW, ICE, MIXED, DUST, MUD, GRASS }

## Speed (m/s) at which a slide starts throwing material, and where the
## plume reaches full size
const SLIDE_MIN_SPEED := 1.6
const SLIDE_FULL_SPEED := 14.0

## Walking fast over loose ground raises a little dust from this speed
const WALK_DUST_SPEED := 2.8

## Buffer sizes (fixed: changing amount resets an emitter)
const SPRAY_AMOUNT := 220
const DUST_AMOUNT := 150
const BURST_AMOUNT := 32
const STEP_AMOUNT := 7
const BURST_POOL_SIZE := 5

## Vertical speed (m/s, downward) from which a landing throws material
const LANDING_MIN_SPEED := 3.0

# =============================================================================
# STATE
# =============================================================================

## The climber this node belongs to
var player: PlayerController

## Continuous plumes: snow/ice spray and dust
var _spray: CPUParticles3D
var _dust: CPUParticles3D

## One-shot bursts (impacts) and footstep puffs
var _bursts: Array[CPUParticles3D] = []
var _burst_index: int = 0
var _step_puff: CPUParticles3D

## Soft radial sprite shared by every emitter
var _puff_texture: GradientTexture2D

## Downward speed seen on the previous physics frame (landing strength)
var _last_fall_speed: float = 0.0

## Set once the player's footstep system has been found
var _footsteps_connected: bool = false


# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	player = get_parent() as PlayerController
	if player == null:
		push_warning("[PlayerSurfaceEffects] Expected a PlayerController parent; effects disabled")
		set_physics_process(false)
		return

	_puff_texture = _make_puff_texture()

	_spray = _make_emitter("SnowSpray", SPRAY_AMOUNT, 0.9, false, 0.9)
	_spray.gravity = Vector3(0.0, -3.5, 0.0)
	_spray.scale_amount_curve = _make_growth_curve(0.35, 1.0)
	add_child(_spray)

	_dust = _make_emitter("Dust", DUST_AMOUNT, 1.6, false, 0.45)
	_dust.gravity = Vector3(0.0, -0.6, 0.0)
	_dust.damping_min = 1.0
	_dust.damping_max = 2.0
	_dust.scale_amount_curve = _make_growth_curve(0.3, 1.0)
	add_child(_dust)

	for i in range(BURST_POOL_SIZE):
		var burst := _make_emitter("Burst%d" % i, BURST_AMOUNT, 1.3, true, 0.7)
		burst.gravity = Vector3(0.0, -2.5, 0.0)
		burst.damping_min = 1.5
		burst.damping_max = 3.0
		burst.scale_amount_curve = _make_growth_curve(0.4, 1.0)
		add_child(burst)
		_bursts.append(burst)

	_step_puff = _make_emitter("StepPuff", STEP_AMOUNT, 0.7, true, 0.5)
	_step_puff.gravity = Vector3(0.0, -0.8, 0.0)
	_step_puff.damping_min = 2.0
	_step_puff.damping_max = 3.0
	_step_puff.scale_amount_curve = _make_growth_curve(0.5, 1.0)
	add_child(_step_puff)

	EventBus.player_movement_changed.connect(_on_movement_changed)
	EventBus.slide_ended.connect(_on_slide_ended)
	EventBus.stumble_occurred.connect(_on_stumble)
	EventBus.micro_slip_occurred.connect(_on_micro_slip)
	_connect_footsteps()

	print("[PlayerSurfaceEffects] Ready (spray, dust, bursts, footstep puffs)")


func _physics_process(_delta: float) -> void:
	if not _footsteps_connected:
		_connect_footsteps()

	var state := player.current_state
	var velocity := player.velocity
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var speed := horizontal.length()
	if speed < 0.05:
		var smooth := player.smooth_velocity
		horizontal = Vector3(smooth.x, 0.0, smooth.z)
		speed = horizontal.length()

	var feet := player.global_position
	# A sliding climber hops off the ground for a frame or two over every
	# bump; keep the plume going while the boots are within reach of it
	var grounded := player.is_on_floor()
	if not grounded and player.terrain_service != null and player.terrain_service.has_terrain_at(feet):
		grounded = feet.y - player.terrain_service.get_height_at(feet) < 0.6
	var medium := _medium_for_cell(player.current_cell)

	# Track the fall speed so a landing knows how hard it was
	if not grounded:
		_last_fall_speed = maxf(-velocity.y, 0.0)

	var sliding := state == GameEnums.PlayerMovementState.SLIDING \
		or state == GameEnums.PlayerMovementState.ARRESTED
	var plume := 0.0
	if grounded and medium != Medium.NONE:
		if sliding and speed > SLIDE_MIN_SPEED:
			plume = clampf((speed - SLIDE_MIN_SPEED) / (SLIDE_FULL_SPEED - SLIDE_MIN_SPEED), 0.0, 1.0)
			# Digging the axe in throws more than gliding does
			if state == GameEnums.PlayerMovementState.ARRESTED:
				plume = minf(plume + 0.35, 1.0)
		elif speed > WALK_DUST_SPEED and _is_loose(medium):
			# Fast walking on scree, mud or powder raises a little
			plume = clampf((speed - WALK_DUST_SPEED) / 6.0, 0.0, 0.25)

	var use_spray := medium == Medium.SNOW or medium == Medium.ICE or medium == Medium.MIXED
	_drive_plume(_spray, use_spray and plume > 0.0, plume, medium, feet, horizontal, speed)
	_drive_plume(_dust, (not use_spray) and plume > 0.0, plume, medium, feet, horizontal, speed)


# =============================================================================
# CONTINUOUS PLUMES
# =============================================================================

func _drive_plume(
	emitter: CPUParticles3D, active: bool, strength: float, medium: int,
	feet: Vector3, horizontal: Vector3, speed: float
) -> void:
	if not active:
		if emitter.emitting:
			emitter.emitting = false
		return

	var back := -horizontal.normalized() if speed > 0.05 else Vector3.BACK
	# Throw material back and up from just behind the boots
	emitter.global_position = feet + back * 0.35 + Vector3(0.0, 0.12, 0.0)
	emitter.direction = (back * 0.85 + Vector3.UP * 0.75).normalized()
	emitter.spread = lerpf(28.0, 42.0, strength)
	var throw := clampf(speed * 0.45, 1.5, 9.0)
	emitter.initial_velocity_min = throw * 0.5
	emitter.initial_velocity_max = throw * 1.1
	emitter.emission_sphere_radius = lerpf(0.25, 0.5, strength)

	var color := _medium_color(medium)
	color.a *= lerpf(0.45, 1.0, strength)
	emitter.color = color
	_tint_self_light(emitter, color)
	emitter.scale_amount_min = lerpf(0.2, 0.35, strength)
	emitter.scale_amount_max = lerpf(0.5, 1.2, strength)

	if not emitter.emitting:
		emitter.emitting = true


# =============================================================================
# BURSTS
# =============================================================================

## Throw a one-shot burst at the feet. [param strength] 0..1 sets size and reach
func _burst(strength: float, medium: int = -1) -> void:
	if player == null or _bursts.is_empty():
		return
	if medium < 0:
		medium = _medium_for_cell(player.current_cell)
	if medium == Medium.NONE:
		return
	strength = clampf(strength, 0.0, 1.0)
	if strength < 0.05:
		return

	var burst := _bursts[_burst_index]
	_burst_index = (_burst_index + 1) % _bursts.size()

	burst.global_position = player.global_position + Vector3(0.0, 0.1, 0.0)
	burst.direction = Vector3.UP
	burst.spread = 70.0
	burst.initial_velocity_min = lerpf(1.0, 2.5, strength)
	burst.initial_velocity_max = lerpf(2.5, 6.0, strength)
	burst.emission_sphere_radius = lerpf(0.3, 0.7, strength)
	var color := _medium_color(medium)
	color.a *= lerpf(0.4, 0.8, strength)
	burst.color = color
	_tint_self_light(burst, color)
	burst.scale_amount_min = lerpf(0.2, 0.35, strength)
	burst.scale_amount_max = lerpf(0.55, 1.0, strength)
	burst.restart()
	burst.emitting = true


func _footstep_puff(medium: int) -> void:
	if player == null or _step_puff == null:
		return
	if not _is_loose(medium):
		return
	_step_puff.global_position = player.global_position + Vector3(0.0, 0.05, 0.0)
	_step_puff.direction = Vector3.UP
	_step_puff.spread = 60.0
	_step_puff.initial_velocity_min = 0.3
	_step_puff.initial_velocity_max = 0.9
	_step_puff.emission_sphere_radius = 0.2
	var color := _medium_color(medium)
	color.a *= 0.5
	_step_puff.color = color
	_tint_self_light(_step_puff, color)
	_step_puff.scale_amount_min = 0.25
	_step_puff.scale_amount_max = 0.6
	_step_puff.restart()
	_step_puff.emitting = true


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_movement_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	if old_state == GameEnums.PlayerMovementState.FALLING \
			and new_state != GameEnums.PlayerMovementState.FALLING:
		if _last_fall_speed >= LANDING_MIN_SPEED:
			_burst(clampf((_last_fall_speed - LANDING_MIN_SPEED) / 12.0 + 0.3, 0.3, 1.0))
		_last_fall_speed = 0.0


func _on_slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	var strength := clampf(final_speed / 12.0, 0.0, 1.0)
	match outcome:
		GameEnums.SlideOutcome.TUMBLE_STOP, GameEnums.SlideOutcome.TERRAIN_CATCH:
			strength = maxf(strength, 0.7)
		GameEnums.SlideOutcome.CLEAN_STOP:
			strength = maxf(strength * 0.8, 0.25)
		_:
			strength = maxf(strength, 0.4)
	_burst(strength)


func _on_stumble(severity: float, _recovered: bool) -> void:
	_burst(clampf(severity * 0.7 + 0.15, 0.15, 0.8))


func _on_micro_slip(severity: float, _position: Vector3) -> void:
	if severity > 0.35:
		_burst(clampf(severity * 0.4, 0.15, 0.4))


func _on_footstep(surface: GameEnums.SurfaceType, _foot: StringName) -> void:
	_footstep_puff(_medium_for_surface(surface))


func _connect_footsteps() -> void:
	if player == null:
		return
	var footsteps := player.get_node_or_null("FootstepSystem")
	if footsteps == null or not footsteps.has_signal("footstep_played"):
		return
	if not footsteps.footstep_played.is_connected(_on_footstep):
		footsteps.footstep_played.connect(_on_footstep)
	_footsteps_connected = true


# =============================================================================
# SURFACES
# =============================================================================

func _medium_for_cell(cell: TerrainCell) -> int:
	if cell == null:
		return Medium.NONE
	return _medium_for_surface(cell.surface_type)


func _medium_for_surface(surface: GameEnums.SurfaceType) -> int:
	match surface:
		GameEnums.SurfaceType.SNOW_FIRM, GameEnums.SurfaceType.SNOW_SOFT, \
		GameEnums.SurfaceType.SNOW_PACKED, GameEnums.SurfaceType.SNOW_POWDER:
			return Medium.SNOW
		GameEnums.SurfaceType.ICE:
			return Medium.ICE
		GameEnums.SurfaceType.MIXED:
			return Medium.MIXED
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, \
		GameEnums.SurfaceType.SCREE:
			return Medium.DUST
		GameEnums.SurfaceType.ROCK_WET, GameEnums.SurfaceType.MUD:
			return Medium.MUD
		GameEnums.SurfaceType.GRASS:
			return Medium.GRASS
	return Medium.NONE


## Loose ground puffs under a boot; hard snow, ice and bare rock do not
func _is_loose(medium: int) -> bool:
	if medium != Medium.DUST and medium != Medium.MUD and medium != Medium.GRASS:
		if medium == Medium.SNOW and player != null and player.current_cell != null:
			var surface := player.current_cell.surface_type
			return surface == GameEnums.SurfaceType.SNOW_POWDER \
				or surface == GameEnums.SurfaceType.SNOW_SOFT
		return false
	return true


func _medium_color(medium: int) -> Color:
	match medium:
		Medium.SNOW:
			return Color(0.94, 0.96, 1.0, 0.8)
		Medium.ICE:
			return Color(0.86, 0.93, 1.0, 0.5)
		Medium.MIXED:
			# Thin snow over broken rock: a greyer, dirtier spray
			return Color(0.84, 0.84, 0.86, 0.65)
		Medium.DUST:
			return Color(0.66, 0.58, 0.47, 0.6)
		Medium.MUD:
			return Color(0.40, 0.33, 0.26, 0.5)
		Medium.GRASS:
			return Color(0.55, 0.52, 0.36, 0.45)
	return Color(1.0, 1.0, 1.0, 0.0)


# =============================================================================
# CONSTRUCTION HELPERS
# =============================================================================

func _make_emitter(
	emitter_name: String, amount: int, lifetime: float, one_shot: bool, self_light: float
) -> CPUParticles3D:
	var emitter := CPUParticles3D.new()
	emitter.name = emitter_name
	emitter.top_level = true
	emitter.emitting = false
	emitter.amount = amount
	emitter.lifetime = lifetime
	emitter.one_shot = one_shot
	emitter.explosiveness = 0.95 if one_shot else 0.0
	emitter.randomness = 0.6
	emitter.local_coords = false
	emitter.mesh = _make_puff_mesh(self_light)
	emitter.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	emitter.emission_sphere_radius = 0.3
	emitter.direction = Vector3.UP
	emitter.spread = 45.0
	emitter.angular_velocity_min = -60.0
	emitter.angular_velocity_max = 60.0
	emitter.color_ramp = _make_fade_ramp()
	emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Particles live in world space around a moving climber; a generous
	# bounds box keeps them from being frustum-culled mid-plume
	emitter.custom_aabb = AABB(Vector3(-25, -25, -25), Vector3(50, 50, 50))
	return emitter


## Lit billboard sprite. The puffs take the sun and ambient light of the
## snow they fly over, plus [param self_light] worth of emission in the
## medium's colour (set per emitter by _tint_self_light), so a backlit plume
## glows the way scattered snow does instead of going dark. An unshaded
## white sprite is no good either: after exposure it sits below sunlit snow
## and reads as a grey smudge. Note the emission texture defaults to black,
## so the operator must stay additive or the emission vanishes
func _make_puff_mesh(self_light: float) -> QuadMesh:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.roughness = 1.0
	material.metallic_specular = 0.0
	material.emission_enabled = true
	material.emission = Color(1.0, 1.0, 1.0)
	material.emission_energy_multiplier = self_light
	material.emission_operator = BaseMaterial3D.EMISSION_OP_ADD
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	# The particle billboard mode keeps each puff's own spin (angular
	# velocity) so a plume is not a stream of identical sprites
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.billboard_keep_scale = true
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _puff_texture
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.disable_receive_shadows = true
	material.no_depth_test = false
	# Soft intersection with the ground needs the depth texture, which the
	# Compatibility renderer does not expose in 4.2
	if EnvironmentVisuals.detect_rendering_method() != "gl_compatibility":
		material.proximity_fade_enabled = true
		material.proximity_fade_distance = 0.5

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = material
	return quad


## Emission takes the medium's colour so dust glows dusty and snow glows white
func _tint_self_light(emitter: CPUParticles3D, color: Color) -> void:
	var quad := emitter.mesh as QuadMesh
	if quad == null:
		return
	var material := quad.material as StandardMaterial3D
	if material != null:
		material.emission = Color(color.r, color.g, color.b, 1.0)


## Soft radial sprite: opaque core fading to nothing at the edge
func _make_puff_texture() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	gradient.add_point(0.35, Color(1.0, 1.0, 1.0, 0.75))
	gradient.add_point(0.7, Color(1.0, 1.0, 1.0, 0.25))

	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 64
	texture.height = 64
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	return texture


## Particles pop in, hold, then thin out and vanish
func _make_fade_ramp() -> Gradient:
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
	ramp.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	ramp.add_point(0.08, Color(1.0, 1.0, 1.0, 1.0))
	ramp.add_point(0.45, Color(1.0, 1.0, 1.0, 0.7))
	return ramp


## Particles grow from [param start] of their size to full over their life
func _make_growth_curve(start: float, end: float) -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, start))
	curve.add_point(Vector2(0.3, lerpf(start, end, 0.7)))
	curve.add_point(Vector2(1.0, end))
	return curve
