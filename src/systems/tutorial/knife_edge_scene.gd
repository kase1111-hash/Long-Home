class_name KnifeEdgeScene
extends Node3D
## Knife edge summit scene for tutorial
## Creates the constrained, dangerous opening environment
##
## Design Philosophy:
## - Immediate spatial danger communicates game tone
## - Narrow ridge forces careful movement discovery
## - Wind and visual exposure create tension
## - No safety nets

# =============================================================================
# SIGNALS
# =============================================================================

signal scene_ready()
signal player_fell()
signal player_progressed()

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Ridge Geometry")
## Length of the knife edge ridge (meters)
@export var ridge_length: float = 20.0
## Width at narrowest point (meters)
@export var ridge_width_min: float = 0.8
## Width at widest point (meters)
@export var ridge_width_max: float = 2.0
## Drop distance on each side (meters)
@export var drop_distance: float = 500.0

@export_group("Spawn")
## Player spawn offset from ridge start
@export var player_spawn_offset: Vector3 = Vector3(0, 0.1, 2)
## Instructor spawn offset from player
@export var instructor_offset: Vector3 = Vector3(1.5, 0, 1)

@export_group("Environment")
## Base wind intensity on ridge
@export var ridge_wind_intensity: float = 0.4
## Sun position (for dramatic shadows)
@export var sun_angle: Vector3 = Vector3(-30, 45, 0)

# =============================================================================
# SCENE COMPONENTS
# =============================================================================

## The ridge mesh
var ridge_mesh: MeshInstance3D

## Ridge collision
var ridge_collision: StaticBody3D

## Left drop zone (triggers fall)
var left_drop_zone: Area3D

## Right drop zone (triggers fall)
var right_drop_zone: Area3D

## Progress trigger (end of safe ridge)
var progress_zone: Area3D

## Spawn marker for player
var player_spawn: Marker3D

## Spawn marker for instructor
var instructor_spawn: Marker3D


# =============================================================================
# STATE
# =============================================================================

## Tutorial manager reference
var tutorial_manager: TutorialManager

## Player reference
var player: PlayerController

## Instructor reference
var instructor: Instructor

## Is scene active
var is_active: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_create_ridge_geometry()
	_create_drop_zones()
	_create_spawn_markers()
	_connect_signals()

	print("[KnifeEdgeScene] Ready")


func _create_ridge_geometry() -> void:
	# Create ridge collision body
	ridge_collision = StaticBody3D.new()
	ridge_collision.name = "RidgeCollision"
	add_child(ridge_collision)

	# Create ridge mesh - elongated prism with tapered width
	ridge_mesh = MeshInstance3D.new()
	ridge_mesh.name = "RidgeMesh"

	# Use a box mesh as base (would be more complex in full implementation)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(ridge_width_min, 2.0, ridge_length)
	ridge_mesh.mesh = mesh

	# Position mesh
	ridge_mesh.position = Vector3(0, -1.0, ridge_length / 2.0)
	ridge_collision.add_child(ridge_mesh)

	# Collision shape
	var collision_shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(ridge_width_min, 2.0, ridge_length)
	collision_shape.shape = box_shape
	collision_shape.position = Vector3(0, -1.0, ridge_length / 2.0)
	ridge_collision.add_child(collision_shape)

	# Apply mountain material (placeholder)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.4, 0.4, 0.45)  # Grey rock
	material.roughness = 0.9
	ridge_mesh.material_override = material


func _create_drop_zones() -> void:
	# Left drop zone
	left_drop_zone = _create_drop_area("LeftDrop", Vector3(-ridge_width_min, 0, ridge_length / 2.0))
	add_child(left_drop_zone)

	# Right drop zone
	right_drop_zone = _create_drop_area("RightDrop", Vector3(ridge_width_min, 0, ridge_length / 2.0))
	add_child(right_drop_zone)

	# Connect signals
	left_drop_zone.body_entered.connect(_on_drop_zone_entered)
	right_drop_zone.body_entered.connect(_on_drop_zone_entered)


func _create_drop_area(area_name: String, position: Vector3) -> Area3D:
	var area := Area3D.new()
	area.name = area_name

	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10.0, drop_distance, ridge_length)
	collision.shape = box
	collision.position = Vector3(0, -drop_distance / 2.0, 0)

	area.add_child(collision)
	area.position = position

	return area


func _create_spawn_markers() -> void:
	# Player spawn point
	player_spawn = Marker3D.new()
	player_spawn.name = "PlayerSpawn"
	player_spawn.position = player_spawn_offset
	add_child(player_spawn)

	# Instructor spawn point
	instructor_spawn = Marker3D.new()
	instructor_spawn.name = "InstructorSpawn"
	instructor_spawn.position = player_spawn_offset + instructor_offset
	add_child(instructor_spawn)

	# Progress zone (end of tutorial ridge)
	progress_zone = Area3D.new()
	progress_zone.name = "ProgressZone"

	var progress_collision := CollisionShape3D.new()
	var progress_shape := BoxShape3D.new()
	progress_shape.size = Vector3(ridge_width_max * 2, 3.0, 3.0)
	progress_collision.shape = progress_shape

	progress_zone.add_child(progress_collision)
	progress_zone.position = Vector3(0, 1.0, ridge_length - 2.0)
	progress_zone.body_entered.connect(_on_progress_zone_entered)
	add_child(progress_zone)


func _connect_signals() -> void:
	ServiceLocator.get_service_async("TutorialManager", func(s): tutorial_manager = s)
	ServiceLocator.get_service_async("PlayerController", func(s): player = s)


# =============================================================================
# SCENE CONTROL
# =============================================================================

## Activate the knife edge scene
func activate() -> void:
	is_active = true
	visible = true

	# Set up wind
	_setup_wind()

	# Spawn instructor
	_spawn_instructor()

	scene_ready.emit()
	print("[KnifeEdgeScene] Activated")


## Deactivate the scene
func deactivate() -> void:
	is_active = false
	visible = false

	# Clean up instructor
	if instructor:
		instructor.queue_free()
		instructor = null


func _setup_wind() -> void:
	# Notify ambient audio of ridge wind
	var ambient := ServiceLocator.get_service("AmbientAudioManager") as AmbientAudioManager
	if ambient:
		ambient.set_wind_intensity(ridge_wind_intensity)


func _spawn_instructor() -> void:
	if tutorial_manager:
		instructor = tutorial_manager.spawn_instructor(instructor_spawn.global_position)
		add_child(instructor)

		# Connect to tutorial manager
		tutorial_manager.set_instructor(instructor)


## Get the player spawn position
func get_player_spawn_position() -> Vector3:
	return player_spawn.global_position


## Get the instructor spawn position
func get_instructor_spawn_position() -> Vector3:
	return instructor_spawn.global_position


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_drop_zone_entered(body: Node3D) -> void:
	if not is_active:
		return

	if body is PlayerController:
		_handle_player_fall()


func _on_progress_zone_entered(body: Node3D) -> void:
	if not is_active:
		return

	if body is PlayerController:
		_handle_player_progress()


func _handle_player_fall() -> void:
	player_fell.emit()

	# In tutorial, this triggers a reload with no commentary
	print("[KnifeEdgeScene] Player fell - reloading")

	# Lesson: the world is live from second one
	if tutorial_manager:
		tutorial_manager.record_lesson("fall_consequence")

	# Fade to black and reload (would be handled by game manager)


func _handle_player_progress() -> void:
	player_progressed.emit()

	# Player has navigated the knife edge successfully
	if tutorial_manager:
		tutorial_manager.record_lesson("knife_edge_navigation")


# =============================================================================
# VISUAL SETUP
# =============================================================================

## Add environmental details
func add_environmental_details() -> void:
	_add_distant_peaks()
	_add_clouds_below()
	_add_wind_particles()


func _add_distant_peaks() -> void:
	# Would add distant mountain meshes for scale
	pass


func _add_clouds_below() -> void:
	# Would add cloud layer below the ridge for exposure feel
	pass


func _add_wind_particles() -> void:
	# Would add subtle snow/ice particles blown by wind
	pass


# =============================================================================
# QUERIES
# =============================================================================

func is_scene_active() -> bool:
	return is_active


func get_ridge_bounds() -> AABB:
	return AABB(
		Vector3(-ridge_width_max / 2.0, -2.0, 0),
		Vector3(ridge_width_max, 4.0, ridge_length)
	)


func get_summary() -> Dictionary:
	return {
		"active": is_active,
		"ridge_length": ridge_length,
		"ridge_width": ridge_width_min,
		"has_instructor": instructor != null
	}
