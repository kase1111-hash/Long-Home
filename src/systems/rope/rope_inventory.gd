class_name RopeInventory
extends Resource
## Manages rope collection and selection
## Handles rope weight impact and deployment tracking

# =============================================================================
# SIGNALS
# =============================================================================

signal rope_added(rope: Rope)
signal rope_removed(rope: Rope)
signal rope_deployed(rope: Rope)
signal rope_recovered(rope: Rope)
signal rope_damaged(rope: Rope, damage: float)
signal rope_lost(rope: Rope)

# =============================================================================
# PROPERTIES
# =============================================================================

## All ropes in inventory
@export var ropes: Array[Rope] = []

## Currently deployed rope (if any)
var deployed_rope: Rope = null

## Maximum ropes player can carry
@export var max_ropes: int = 2


# =============================================================================
# DERIVED PROPERTIES
# =============================================================================

## Get total weight of all ropes
func get_total_weight() -> float:
	var weight := 0.0
	for rope in ropes:
		weight += rope.get_weight()
	return weight


## Get total available rope length
func get_total_length() -> float:
	var length := 0.0
	for rope in ropes:
		if not rope.is_deployed:
			length += rope.available_length
	return length


## Check if any rope is deployed
func has_deployed_rope() -> bool:
	return deployed_rope != null


## Get best rope for deployment (highest condition)
func get_best_rope() -> Rope:
	var best: Rope = null
	var best_score := -1.0

	for rope in ropes:
		if rope.is_deployed:
			continue
		if not rope.is_safe():
			continue

		var score := rope.get_reliability() * rope.available_length
		if score > best_score:
			best_score = score
			best = rope

	return best


## Get longest available rope
func get_longest_rope() -> Rope:
	var longest: Rope = null
	var max_length := 0.0

	for rope in ropes:
		if rope.is_deployed:
			continue
		if rope.available_length > max_length:
			max_length = rope.available_length
			longest = rope

	return longest


## Check if player has any usable rope
func has_usable_rope() -> bool:
	for rope in ropes:
		if not rope.is_deployed and rope.is_safe():
			return true
	return false


## Get count of available ropes
func get_available_count() -> int:
	var count := 0
	for rope in ropes:
		if not rope.is_deployed:
			count += 1
	return count


# =============================================================================
# OPERATIONS
# =============================================================================

## Add rope to inventory
func add_rope(rope: Rope) -> bool:
	if ropes.size() >= max_ropes:
		return false

	ropes.append(rope)
	rope_added.emit(rope)
	return true


## Remove rope from inventory
func remove_rope(rope: Rope) -> bool:
	var idx := ropes.find(rope)
	if idx < 0:
		return false

	if rope == deployed_rope:
		deployed_rope = null

	ropes.remove_at(idx)
	rope_removed.emit(rope)
	return true


## Deploy specific rope
func deploy(rope: Rope, length: float) -> bool:
	if deployed_rope != null:
		return false  # Already have deployed rope

	if not ropes.has(rope):
		return false

	if rope.deploy(length):
		deployed_rope = rope
		rope_deployed.emit(rope)
		return true

	return false


## Deploy best available rope
func deploy_best(length: float) -> Rope:
	var rope := get_best_rope()
	if rope == null:
		return null

	if deploy(rope, length):
		return rope

	return null


## Recover deployed rope
func recover_rope() -> bool:
	if deployed_rope == null:
		return false

	deployed_rope.recover()
	var rope := deployed_rope
	deployed_rope = null
	rope_recovered.emit(rope)
	return true


## Abandon deployed rope (can't recover - stuck, etc.)
func abandon_rope() -> void:
	if deployed_rope == null:
		return

	var rope := deployed_rope
	remove_rope(rope)
	rope_lost.emit(rope)


## Apply damage to deployed rope
func damage_deployed(amount: float) -> void:
	if deployed_rope == null:
		return

	deployed_rope.apply_damage(amount)
	rope_damaged.emit(deployed_rope, amount)

	# Check if rope is now unusable
	if not deployed_rope.is_safe():
		rope_lost.emit(deployed_rope)


## Apply environment to all ropes
func apply_environment(temperature: float, is_snowing: bool) -> void:
	for rope in ropes:
		rope.apply_environment(temperature, is_snowing, false)


# =============================================================================
# QUERIES
# =============================================================================

## Get rope by ID
func get_rope_by_id(id: String) -> Rope:
	for rope in ropes:
		if rope.id == id:
			return rope
	return null


## Check if inventory can take more ropes
func can_add_rope() -> bool:
	return ropes.size() < max_ropes


## Get summary for UI/debug
func get_summary() -> Dictionary:
	return {
		"total_ropes": ropes.size(),
		"available": get_available_count(),
		"deployed": deployed_rope != null,
		"total_length": get_total_length(),
		"total_weight": get_total_weight(),
		"has_usable": has_usable_rope()
	}


# =============================================================================
# FACTORY
# =============================================================================

static func create_standard_loadout() -> RopeInventory:
	var inventory := RopeInventory.new()
	inventory.add_rope(Rope.create_standard())
	return inventory


static func create_full_loadout() -> RopeInventory:
	var inventory := RopeInventory.new()
	inventory.add_rope(Rope.create_standard())
	inventory.add_rope(Rope.create_lightweight())
	return inventory
