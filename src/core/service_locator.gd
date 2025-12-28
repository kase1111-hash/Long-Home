extends Node
## Service locator for dependency management
## Autoloaded as ServiceLocator
##
## Provides a central registry for game systems/services.
## Systems register themselves on ready and can be retrieved by other systems.
##
## Usage:
##   # Registering a service (typically in _ready)
##   ServiceLocator.register_service("TerrainService", self)
##
##   # Getting a service
##   var terrain = ServiceLocator.get_service("TerrainService")
##   if terrain:
##       terrain.query_slope(position)

# =============================================================================
# SERVICE REGISTRY
# =============================================================================

## Dictionary of service name -> service instance
var _services: Dictionary = {}

## Dictionary of service name -> Array of callbacks waiting for service
var _pending_requests: Dictionary = {}

## Whether all core services are registered
var _core_services_ready: bool = false

## List of core services that must be registered
const CORE_SERVICES := [
	"TimeService",
	"WeatherService",
	"TerrainService",
	"PlayerController",
	"CameraDirector",
	"AudioManager",
	"UIManager",
]

# =============================================================================
# SIGNALS
# =============================================================================

## Emitted when a service is registered
signal service_registered(service_name: String)

## Emitted when all core services are ready
signal core_services_ready()

# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	print("[ServiceLocator] Initialized")


# =============================================================================
# SERVICE REGISTRATION
# =============================================================================

## Register a service with the locator
func register_service(service_name: String, service: Object) -> void:
	if _services.has(service_name):
		push_warning("[ServiceLocator] Overwriting existing service: %s" % service_name)

	_services[service_name] = service
	print("[ServiceLocator] Registered: %s" % service_name)

	# Notify waiting callbacks
	if _pending_requests.has(service_name):
		var callbacks: Array = _pending_requests[service_name]
		for callback in callbacks:
			if callback.is_valid():
				callback.call(service)
		_pending_requests.erase(service_name)

	service_registered.emit(service_name)

	# Check if all core services are ready
	_check_core_services()


## Unregister a service
func unregister_service(service_name: String) -> void:
	if _services.has(service_name):
		_services.erase(service_name)
		print("[ServiceLocator] Unregistered: %s" % service_name)

		# Reset core services ready flag if a core service was removed
		if service_name in CORE_SERVICES:
			_core_services_ready = false


## Check if all core services are registered
func _check_core_services() -> void:
	if _core_services_ready:
		return

	for service_name in CORE_SERVICES:
		if not _services.has(service_name):
			return

	_core_services_ready = true
	core_services_ready.emit()
	print("[ServiceLocator] All core services ready")


# =============================================================================
# SERVICE RETRIEVAL
# =============================================================================

## Get a service by name (returns null if not registered)
func get_service(service_name: String) -> Object:
	return _services.get(service_name, null)


## Get a service, asserting it exists
func require_service(service_name: String) -> Object:
	var service = _services.get(service_name, null)
	assert(service != null, "Required service not registered: %s" % service_name)
	return service


## Check if a service is registered
func has_service(service_name: String) -> bool:
	return _services.has(service_name)


## Get a service when it becomes available
## If already available, callback is called immediately
func get_service_async(service_name: String, callback: Callable) -> void:
	if _services.has(service_name):
		callback.call(_services[service_name])
		return

	if not _pending_requests.has(service_name):
		_pending_requests[service_name] = []

	_pending_requests[service_name].append(callback)


## Wait for a service to be available (for use with await)
func wait_for_service(service_name: String) -> Object:
	if _services.has(service_name):
		return _services[service_name]

	# Wait for the service to be registered
	while not _services.has(service_name):
		await service_registered
		if _services.has(service_name):
			return _services[service_name]

	return _services[service_name]


## Check if all core services are ready
func are_core_services_ready() -> bool:
	return _core_services_ready


## Wait for all core services to be ready
func wait_for_core_services() -> void:
	if _core_services_ready:
		return
	await core_services_ready


# =============================================================================
# TYPED ACCESSORS (Convenience methods for common services)
# =============================================================================

## Get the terrain service
func get_terrain() -> Object:  # TerrainService
	return get_service("TerrainService")


## Get the time service
func get_time() -> Object:  # TimeService
	return get_service("TimeService")


## Get the weather service
func get_weather() -> Object:  # WeatherService
	return get_service("WeatherService")


## Get the player controller
func get_player() -> Object:  # PlayerController
	return get_service("PlayerController")


## Get the camera director
func get_camera() -> Object:  # CameraDirector
	return get_service("CameraDirector")


## Get the audio manager
func get_audio() -> Object:  # AudioManager
	return get_service("AudioManager")


## Get the UI manager
func get_ui() -> Object:  # UIManager
	return get_service("UIManager")


## Get the replay recorder
func get_replay() -> Object:  # ReplayRecorder
	return get_service("ReplayRecorder")


# =============================================================================
# DEBUG
# =============================================================================

## Get list of registered services
func get_registered_services() -> Array[String]:
	var names: Array[String] = []
	for key in _services.keys():
		names.append(key)
	return names


## Get list of pending service requests
func get_pending_requests() -> Dictionary:
	var pending := {}
	for key in _pending_requests.keys():
		pending[key] = _pending_requests[key].size()
	return pending


## Get debug info
func get_debug_info() -> Dictionary:
	return {
		"registered": get_registered_services(),
		"pending": get_pending_requests(),
		"core_ready": _core_services_ready
	}


## Print status to console
func print_status() -> void:
	print("[ServiceLocator] Status:")
	print("  Registered services: %s" % str(get_registered_services()))
	print("  Core services ready: %s" % _core_services_ready)
	if _pending_requests.size() > 0:
		print("  Pending requests: %s" % str(get_pending_requests()))
