class_name CloudLayer
extends MeshInstance3D
## A wide sheet of procedural clouds a few hundred metres above the summit.
## Coverage, softness and colour are handed in by EnvironmentVisuals from the
## weather and the sun; the sheet drifts with the wind and follows the camera
## horizontally so it never runs out. One small spatial shader and two
## seamless noise textures, so it renders on Forward+, Mobile and
## Compatibility alike. The depth fog applies to it like any other geometry,
## which is what fades it into the haze on the horizon and swallows it whole
## in a whiteout.

# =============================================================================
# CONSTANTS
# =============================================================================

## Width of the cloud sheet (metres). Past the camera's far plane on purpose;
## the shader fades the sheet out well before that
const SHEET_SIZE := 9000.0

## Noise texture resolution
const NOISE_SIZE := 512

## Coverage easing rate (per second). Fronts roll in over a minute or so
const COVERAGE_RATE := 0.03

## World-space metres per noise tile is 1 / UV_SCALE (~4.5 km)
const UV_SCALE := 0.00022

## Apparent cloud drift as a fraction of the surface wind
const WIND_DRIFT := 0.35

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform sampler2D shape_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_noise : filter_linear_mipmap, repeat_enable;
uniform float coverage : hint_range(0.0, 1.0) = 0.4;
uniform float softness : hint_range(0.02, 1.0) = 0.35;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform vec4 lit_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 shade_color : source_color = vec4(0.62, 0.66, 0.74, 1.0);
uniform vec2 scroll = vec2(0.0, 0.0);
uniform float uv_scale = 0.00022;
uniform float fade_start = 1400.0;
uniform float fade_end = 3200.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = world_pos.xz * uv_scale + scroll;
	float shape = texture(shape_noise, uv).r;
	float detail = texture(detail_noise, uv * 3.7 + scroll * 1.6).r;
	// FBM noise piles up in the middle of its range; widen it so coverage
	// behaves roughly linearly from wisps to a closed sheet
	float density = smoothstep(0.2, 0.8, shape * 0.72 + detail * 0.28);
	float threshold = 1.0 - coverage;
	float alpha = smoothstep(threshold - softness * 0.5, threshold + softness * 0.5, density);
	float thickness = smoothstep(threshold, threshold + 0.45, density);
	vec3 color = mix(lit_color.rgb, shade_color.rgb, thickness * 0.75);
	float dist = length(world_pos.xz - CAMERA_POSITION_WORLD.xz);
	float fade = 1.0 - smoothstep(fade_start, fade_end, dist);
	ALBEDO = color;
	ALPHA = alpha * opacity * fade;
}
"""

# =============================================================================
# STATE
# =============================================================================

## The sheet's material (shader uniforms are written through this)
var cloud_material: ShaderMaterial

## Current and target coverage (0 = clear sky, 1 = closed sheet)
var coverage: float = 0.0
var _target_coverage: float = 0.0

## Scroll offset in noise UV space and the wind driving it (m/s, XZ)
var _scroll: Vector2 = Vector2.ZERO
var _wind: Vector2 = Vector2.ZERO

## True until the first set_conditions() call has been applied
var _snap: bool = true


# =============================================================================
# LIFECYCLE
# =============================================================================

func _init() -> void:
	name = "CloudLayer"

	var plane := PlaneMesh.new()
	plane.size = Vector2(SHEET_SIZE, SHEET_SIZE)
	mesh = plane
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The sheet is huge and always around the camera; never let it be culled
	ignore_occlusion_culling = true
	extra_cull_margin = SHEET_SIZE

	var shader := Shader.new()
	shader.code = SHADER_CODE
	cloud_material = ShaderMaterial.new()
	cloud_material.shader = shader
	cloud_material.set_shader_parameter("shape_noise", _make_noise(4021, 0.0045, 5, 0.5))
	cloud_material.set_shader_parameter("detail_noise", _make_noise(911, 0.012, 3, 0.55))
	cloud_material.set_shader_parameter("uv_scale", UV_SCALE)
	material_override = cloud_material


func _process(delta: float) -> void:
	_scroll += _wind * (WIND_DRIFT * UV_SCALE * delta)
	# Keep the offset small so float precision in the shader stays fine
	_scroll = Vector2(fposmod(_scroll.x, 1.0), fposmod(_scroll.y, 1.0))
	cloud_material.set_shader_parameter("scroll", _scroll)

	if not is_equal_approx(coverage, _target_coverage):
		coverage = move_toward(coverage, _target_coverage, COVERAGE_RATE * delta)
		cloud_material.set_shader_parameter("coverage", coverage)


# =============================================================================
# PUBLIC API
# =============================================================================

## Set the look of the sheet. Coverage eases toward the target unless
## [param snap] is true (start of a run); everything else applies at once.
func set_conditions(
	target_coverage: float, softness: float, opacity: float,
	lit_color: Color, shade_color: Color, snap: bool = false
) -> void:
	_target_coverage = clampf(target_coverage, 0.0, 1.0)
	if snap or _snap:
		coverage = _target_coverage
		cloud_material.set_shader_parameter("coverage", coverage)
		_snap = false
	cloud_material.set_shader_parameter("softness", clampf(softness, 0.02, 1.0))
	cloud_material.set_shader_parameter("opacity", clampf(opacity, 0.0, 1.0))
	cloud_material.set_shader_parameter("lit_color", lit_color)
	cloud_material.set_shader_parameter("shade_color", shade_color)


## Surface wind in m/s (horizontal components) that drifts the sheet
func set_wind(wind_xz: Vector2) -> void:
	_wind = wind_xz


## Keep the sheet centred over the camera at the given altitude
func follow(camera_position: Vector3, altitude: float) -> void:
	global_position = Vector3(camera_position.x, altitude, camera_position.z)


## Snap the next set_conditions() call instead of easing (new run)
func snap_next() -> void:
	_snap = true


# =============================================================================
# HELPERS
# =============================================================================

func _make_noise(noise_seed: int, frequency: float, octaves: int, gain: float) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_gain = gain
	noise.frequency = frequency

	var texture := NoiseTexture2D.new()
	texture.width = NOISE_SIZE
	texture.height = NOISE_SIZE
	texture.seamless = true
	texture.seamless_blend_skirt = 0.15
	texture.generate_mipmaps = true
	texture.noise = noise
	return texture
