class_name ProgressionTracker
extends RefCounted
## Tracks player progression, achievements, and milestones
## Provides feedback on growth and accomplishments
##
## Design Philosophy:
## - Progress is learning, not leveling
## - Achievements celebrate skill, not grind
## - Every milestone has meaning

# =============================================================================
# SIGNALS
# =============================================================================

signal achievement_unlocked(achievement_id: String, achievement: Achievement)
signal milestone_reached(milestone_id: String)
signal skill_improved(skill_id: String, new_level: int)

# =============================================================================
# DATA STRUCTURES
# =============================================================================

class Achievement:
	var id: String
	var name: String
	var description: String
	var category: String
	var is_unlocked: bool = false
	var unlocked_at: float = 0.0
	var is_hidden: bool = false
	var progress: float = 0.0
	var target: float = 1.0

	func get_progress_percent() -> float:
		if target <= 0:
			return 0.0
		return clampf(progress / target, 0.0, 1.0) * 100.0

	func to_dict() -> Dictionary:
		return {
			"id": id,
			"is_unlocked": is_unlocked,
			"unlocked_at": unlocked_at,
			"progress": progress
		}


class Skill:
	var id: String
	var name: String
	var description: String
	var level: int = 0
	var max_level: int = 5
	var experience: float = 0.0
	var experience_per_level: float = 100.0

	func add_experience(amount: float) -> bool:
		experience += amount
		var level_ups := 0
		while experience >= experience_per_level and level < max_level:
			experience -= experience_per_level
			level += 1
			level_ups += 1
		return level_ups > 0

	func get_level_progress() -> float:
		if level >= max_level:
			return 1.0
		return experience / experience_per_level

	func to_dict() -> Dictionary:
		return {
			"id": id,
			"level": level,
			"experience": experience
		}


# =============================================================================
# ACHIEVEMENT DEFINITIONS
# =============================================================================

const ACHIEVEMENTS := {
	# Completion achievements
	"first_descent": {
		"name": "First Steps",
		"description": "Complete your first descent",
		"category": "completion"
	},
	"clean_descent": {
		"name": "Clean Line",
		"description": "Complete a descent with no injuries",
		"category": "completion"
	},
	"all_mountains": {
		"name": "Surveyor",
		"description": "Attempt every mountain at least once",
		"category": "completion",
		"target": 5
	},
	"master_mountain": {
		"name": "Mountain Master",
		"description": "Achieve mastery on any mountain (5 clean returns)",
		"category": "completion"
	},

	# Skill achievements
	"self_arrest_master": {
		"name": "Ice Anchor",
		"description": "Successfully self-arrest 10 times",
		"category": "skill",
		"target": 10
	},
	"rope_expert": {
		"name": "Rope Work",
		"description": "Complete 20 rope sections",
		"category": "skill",
		"target": 20
	},
	"no_rope_clean": {
		"name": "Light and Fast",
		"description": "Complete a descent without using rope",
		"category": "skill"
	},

	# Endurance achievements
	"long_descent": {
		"name": "The Long Way",
		"description": "Descend more than 2000m in a single run",
		"category": "endurance"
	},
	"marathon": {
		"name": "Marathon",
		"description": "Complete a descent lasting over 6 hours",
		"category": "endurance"
	},
	"streak_5": {
		"name": "Consistency",
		"description": "Achieve a 5-run clean return streak",
		"category": "endurance"
	},
	"streak_10": {
		"name": "Reliable",
		"description": "Achieve a 10-run clean return streak",
		"category": "endurance"
	},

	# Conditions achievements
	"storm_survivor": {
		"name": "Storm Rider",
		"description": "Complete a descent during a storm",
		"category": "conditions"
	},
	"night_descent": {
		"name": "Nightfall",
		"description": "Complete a descent that started after 16:00",
		"category": "conditions"
	},
	"cold_master": {
		"name": "Cold Blooded",
		"description": "Complete a descent at -20°C or colder",
		"category": "conditions"
	},

	# Learning achievements
	"learn_from_failure": {
		"name": "Lessons Learned",
		"description": "Successfully complete a mountain after 3 failed attempts",
		"category": "learning"
	},
	"improvement": {
		"name": "Getting Better",
		"description": "Beat your previous best time on any mountain",
		"category": "learning"
	},

	# Hidden achievements
	"bivy_master": {
		"name": "Shelter",
		"description": "Survive a forced bivy",
		"category": "hidden",
		"is_hidden": true
	},
	"close_call": {
		"name": "Close Call",
		"description": "Complete a descent with less than 10% health",
		"category": "hidden",
		"is_hidden": true
	}
}

# =============================================================================
# SKILL DEFINITIONS
# =============================================================================

const SKILLS := {
	"self_arrest": {
		"name": "Self-Arrest",
		"description": "Ability to stop a slide using ice axe",
		"exp_per_level": 100.0
	},
	"route_reading": {
		"name": "Route Reading",
		"description": "Ability to identify safe paths",
		"exp_per_level": 150.0
	},
	"rope_work": {
		"name": "Rope Work",
		"description": "Proficiency with technical rope sections",
		"exp_per_level": 120.0
	},
	"weather_sense": {
		"name": "Weather Sense",
		"description": "Ability to read weather changes",
		"exp_per_level": 200.0
	},
	"pacing": {
		"name": "Pacing",
		"description": "Managing energy and timing",
		"exp_per_level": 180.0
	}
}

# =============================================================================
# STATE
# =============================================================================

## All achievements
var achievements: Dictionary = {}

## All skills
var skills: Dictionary = {}

## Milestones reached
var milestones: Dictionary = {}

## Total achievement points
var achievement_points: int = 0

# =============================================================================
# INITIALIZATION
# =============================================================================

func _init() -> void:
	_initialize_achievements()
	_initialize_skills()


func _initialize_achievements() -> void:
	for id in ACHIEVEMENTS:
		var data: Dictionary = ACHIEVEMENTS[id]
		var achievement := Achievement.new()
		achievement.id = id
		achievement.name = data.get("name", id)
		achievement.description = data.get("description", "")
		achievement.category = data.get("category", "general")
		achievement.is_hidden = data.get("is_hidden", false)
		achievement.target = data.get("target", 1.0)
		achievements[id] = achievement


func _initialize_skills() -> void:
	for id in SKILLS:
		var data: Dictionary = SKILLS[id]
		var skill := Skill.new()
		skill.id = id
		skill.name = data.get("name", id)
		skill.description = data.get("description", "")
		skill.experience_per_level = data.get("exp_per_level", 100.0)
		skills[id] = skill


# =============================================================================
# UPDATE FROM RUN
# =============================================================================

func update_from_run(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	# Check for achievement progress
	_check_completion_achievements(run_context, outcome)
	_check_skill_achievements(run_context, outcome)
	_check_endurance_achievements(run_context, outcome)
	_check_conditions_achievements(run_context, outcome)
	_check_learning_achievements(run_context, outcome)

	# Update skills
	_update_skills(run_context, outcome)


func _check_completion_achievements(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	# First descent
	if outcome <= GameEnums.ResolutionType.RESCUE:
		_unlock_achievement("first_descent")

	# Clean descent
	if outcome == GameEnums.ResolutionType.CLEAN_RETURN:
		_unlock_achievement("clean_descent")


func _check_skill_achievements(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	# No rope clean
	if outcome == GameEnums.ResolutionType.CLEAN_RETURN:
		var gear: GearState = run_context.gear_state
		if gear and not gear.has_item(GameEnums.GearType.ROPE):
			_unlock_achievement("no_rope_clean")


func _check_endurance_achievements(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	if outcome > GameEnums.ResolutionType.INJURED_RETURN:
		return

	# Long descent
	var descent := run_context.start_elevation - run_context.current_elevation
	if descent >= 2000.0:
		_unlock_achievement("long_descent")

	# Marathon
	if run_context.real_time_elapsed >= 6 * 3600:
		_unlock_achievement("marathon")


func _check_conditions_achievements(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	if outcome > GameEnums.ResolutionType.INJURED_RETURN:
		return

	# Storm survivor
	if run_context.current_weather >= GameEnums.WeatherState.STORM:
		_unlock_achievement("storm_survivor")

	# Night descent
	if run_context.start_conditions and run_context.start_conditions.time_of_day >= 16.0:
		_unlock_achievement("night_descent")


func _check_learning_achievements(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	# These would check run history for patterns
	pass


func _update_skills(run_context: RunContext, outcome: GameEnums.ResolutionType) -> void:
	# Route reading improves with successful navigation
	if outcome <= GameEnums.ResolutionType.INJURED_RETURN:
		var exp := 10.0 + (run_context.start_elevation - run_context.current_elevation) * 0.01
		_add_skill_experience("route_reading", exp)

	# Pacing improves with longer runs
	var time_minutes := run_context.real_time_elapsed / 60.0
	if time_minutes > 30:
		_add_skill_experience("pacing", time_minutes * 0.1)


# =============================================================================
# ACHIEVEMENT MANAGEMENT
# =============================================================================

func _unlock_achievement(id: String) -> void:
	if not achievements.has(id):
		return

	var achievement: Achievement = achievements[id]
	if achievement.is_unlocked:
		return

	achievement.is_unlocked = true
	achievement.unlocked_at = Time.get_unix_time_from_system()
	achievement.progress = achievement.target

	achievement_points += 10
	achievement_unlocked.emit(id, achievement)

	print("[Progression] Achievement unlocked: %s" % achievement.name)


func _add_achievement_progress(id: String, amount: float) -> void:
	if not achievements.has(id):
		return

	var achievement: Achievement = achievements[id]
	if achievement.is_unlocked:
		return

	achievement.progress = minf(achievement.progress + amount, achievement.target)

	if achievement.progress >= achievement.target:
		_unlock_achievement(id)


func get_achievement(id: String) -> Achievement:
	return achievements.get(id)


func get_unlocked_achievements() -> Array[Achievement]:
	var result: Array[Achievement] = []
	for achievement in achievements.values():
		if achievement.is_unlocked:
			result.append(achievement)
	return result


func get_locked_achievements(include_hidden: bool = false) -> Array[Achievement]:
	var result: Array[Achievement] = []
	for achievement in achievements.values():
		if achievement.is_unlocked:
			continue
		if achievement.is_hidden and not include_hidden:
			continue
		result.append(achievement)
	return result


func get_achievements_by_category(category: String) -> Array[Achievement]:
	var result: Array[Achievement] = []
	for achievement in achievements.values():
		if achievement.category == category:
			result.append(achievement)
	return result


func get_achievement_progress() -> Dictionary:
	var unlocked := 0
	var total := 0

	for achievement in achievements.values():
		if not achievement.is_hidden:
			total += 1
			if achievement.is_unlocked:
				unlocked += 1

	return {
		"unlocked": unlocked,
		"total": total,
		"percent": (float(unlocked) / float(total) * 100.0) if total > 0 else 0.0
	}


# =============================================================================
# SKILL MANAGEMENT
# =============================================================================

func _add_skill_experience(id: String, amount: float) -> void:
	if not skills.has(id):
		return

	var skill: Skill = skills[id]
	if skill.add_experience(amount):
		skill_improved.emit(id, skill.level)
		print("[Progression] Skill improved: %s -> Level %d" % [skill.name, skill.level])


func get_skill(id: String) -> Skill:
	return skills.get(id)


func get_all_skills() -> Array[Skill]:
	var result: Array[Skill] = []
	for skill in skills.values():
		result.append(skill)
	return result


func get_skill_level(id: String) -> int:
	var skill := get_skill(id)
	return skill.level if skill else 0


# =============================================================================
# MILESTONES
# =============================================================================

func record_milestone(id: String, data: Dictionary = {}) -> void:
	if milestones.has(id):
		return  # Already recorded

	milestones[id] = {
		"achieved_at": Time.get_unix_time_from_system(),
		"data": data
	}

	milestone_reached.emit(id)


func has_milestone(id: String) -> bool:
	return milestones.has(id)


func get_milestone(id: String) -> Dictionary:
	return milestones.get(id, {})


# =============================================================================
# STATISTICS
# =============================================================================

func get_stats_summary() -> Dictionary:
	var unlocked_count := 0
	for achievement in achievements.values():
		if achievement.is_unlocked:
			unlocked_count += 1

	var total_skill_levels := 0
	for skill in skills.values():
		total_skill_levels += skill.level

	return {
		"achievements_unlocked": unlocked_count,
		"achievement_points": achievement_points,
		"total_skill_levels": total_skill_levels,
		"milestones_reached": milestones.size()
	}


# =============================================================================
# SERIALIZATION
# =============================================================================

func to_dict() -> Dictionary:
	var achievements_data := {}
	for id in achievements:
		achievements_data[id] = achievements[id].to_dict()

	var skills_data := {}
	for id in skills:
		skills_data[id] = skills[id].to_dict()

	return {
		"achievements": achievements_data,
		"skills": skills_data,
		"milestones": milestones,
		"achievement_points": achievement_points
	}


static func from_dict(data: Dictionary) -> ProgressionTracker:
	var tracker := ProgressionTracker.new()

	# Load achievements
	var achievements_data: Dictionary = data.get("achievements", {})
	for id in achievements_data:
		if tracker.achievements.has(id):
			var achievement: Achievement = tracker.achievements[id]
			var saved: Dictionary = achievements_data[id]
			achievement.is_unlocked = saved.get("is_unlocked", false)
			achievement.unlocked_at = saved.get("unlocked_at", 0.0)
			achievement.progress = saved.get("progress", 0.0)

	# Load skills
	var skills_data: Dictionary = data.get("skills", {})
	for id in skills_data:
		if tracker.skills.has(id):
			var skill: Skill = tracker.skills[id]
			var saved: Dictionary = skills_data[id]
			skill.level = saved.get("level", 0)
			skill.experience = saved.get("experience", 0.0)

	# Load milestones
	tracker.milestones = data.get("milestones", {})
	tracker.achievement_points = data.get("achievement_points", 0)

	return tracker
