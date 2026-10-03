class_name RouteScorer
extends RefCounted
## Scores a finished run the way a logbook entry would read: which line was
## actually climbed and what it grades, in what style, how long it took
## against the book, whether it went as planned, and whether you came home.
##
##   points = line points x outcome x style x pace x plan x on-sight x daylight
##
## Line points come from the grade of the line actually travelled (measured
## by RouteMetrics from the path history, the same yardstick the guidebook
## uses), scaled by the height covered under control. Ground crossed out of control (a fall, a
## tumbling slide) earns nothing, and only abseils actually made count as
## abseils, so a fall down a cliff band never scores as a hard route.
##
## Pace compares the time taken with the book time of the same line, so a
## hard line is not punished for being slow and a glissade that beats the
## book is rewarded. Style counts the incidents on the way. A full route
## scores the ascent and the descent as two lines; turning back short of the
## summit keeps a fraction of the ascent.

# =============================================================================
# CONSTANTS
# =============================================================================

const OUTCOME_FACTORS := {
	GameEnums.ResolutionType.CLEAN_RETURN: 1.0,
	GameEnums.ResolutionType.INJURED_RETURN: 0.6,
	GameEnums.ResolutionType.FORCED_BIVY: 0.35,
	GameEnums.ResolutionType.RESCUE: 0.1,
	GameEnums.ResolutionType.FATALITY: 0.0,
}

const OUTCOME_WORDS := {
	GameEnums.ResolutionType.CLEAN_RETURN: "clean return",
	GameEnums.ResolutionType.INJURED_RETURN: "home, injured",
	GameEnums.ResolutionType.FORCED_BIVY: "forced bivouac",
	GameEnums.ResolutionType.RESCUE: "rescued",
	GameEnums.ResolutionType.FATALITY: "did not return",
}

## Style deductions per incident type: [per incident, cap for the type, label]
const STYLE_COSTS := {
	"fall_started": [0.10, 0.30, "fall"],
	"fall_from_slip": [0.06, 0.18, "slip into a fall"],
	"slide_from_slip": [0.08, 0.24, "uncontrolled slide"],
	"slide_upset": [0.06, 0.18, "upset in a slide"],
	"self_arrest_success": [0.03, 0.09, "self-arrest"],
	"self_arrest_failed": [0.08, 0.24, "failed self-arrest"],
	"hard_landing": [0.05, 0.15, "hard landing"],
	"fall_injury": [0.10, 0.30, "injury"],
	"injury": [0.10, 0.30, "injury"],
	"anchor_failure": [0.10, 0.20, "anchor failure"],
	"rope_lost": [0.10, 0.10, "rope lost"],
	"rope_jam": [0.03, 0.09, "stuck rope"],
	"rope_end_reached": [0.04, 0.08, "ran out of rope"],
	"ski_crash": [0.06, 0.18, "ski crash"],
	"skis_broken": [0.05, 0.05, "broken skis"],
	"micro_slip": [0.005, 0.05, "slip"],
	"collapse": [0.15, 0.30, "collapse"],
	"obstacle_impact": [0.08, 0.24, "collision"],
	"crevasse_fall": [0.2, 0.4, "crevasse fall"],
	"crevasse_slip": [0.03, 0.09, "slip on the crevasse wall"],
	"avalanche_triggered": [0.15, 0.3, "avalanche triggered"],
	"avalanche_caught": [0.3, 0.5, "caught in an avalanche"],
	"avalanche_burial": [0.15, 0.3, "buried"],
}

## Style never drops below this (the line still went)
const STYLE_FLOOR := 0.4
## Pace factor bounds
const PACE_MIN := 0.75
const PACE_MAX := 1.25
## A path within this of the plan is "on plan" (metres)
const PLAN_TOLERANCE := 25.0
## Reference vertical for line points (metres)
const REFERENCE_VERTICAL := 300.0
## Share of the ascent's points kept on a retreat
const RETREAT_SHARE := 0.3
const ONSIGHT_BONUS := 1.10
const BENIGHTED_FACTOR := 0.9


# =============================================================================
# DATA
# =============================================================================

class RouteScore:
	var total: int = 0
	var mode: int = GameEnums.RouteMode.DESCENT
	var outcome: int = GameEnums.ResolutionType.FATALITY
	## Grade of the line travelled (the harder leg on a full route)
	var grade: String = "F"
	var grade_value: float = 0.0
	var commitment: String = "I"
	var ascent_grade: String = ""
	var descent_grade: String = ""
	## Guidebook line followed, if any ("" = own line)
	var route_name: String = ""
	var ascent_route_name: String = ""
	var line_points: float = 0.0
	var outcome_factor: float = 0.0
	var style_factor: float = 1.0
	var style_label: String = "Clean"
	var pace_factor: float = 1.0
	var plan_factor: float = 1.0
	var plan_share: float = 0.0
	var onsight: bool = false
	var benighted: bool = false
	var summit_reached: bool = false
	var retreated: bool = false
	var minutes_taken: float = 0.0
	var book_minutes: float = 0.0
	var vertical: float = 0.0
	var rappels: int = 0
	## Breakdown lines for the logbook: {"label": String, "value": String}
	var lines: Array[Dictionary] = []
	## Style notes ("2 uncontrolled slides")
	var style_notes: Array[String] = []

	## Short logbook title: "North Rib, PD+ I"
	func get_title() -> String:
		var line_name := route_name if not route_name.is_empty() else "Own line"
		if mode == GameEnums.RouteMode.FULL_ROUTE:
			line_name = "Full route"
			if not ascent_route_name.is_empty() and not route_name.is_empty():
				line_name = "Up %s, down %s" % [ascent_route_name, route_name]
		return "%s, %s %s" % [line_name, grade, commitment]

	func to_dict() -> Dictionary:
		return {
			"total": total,
			"mode": mode,
			"outcome": outcome,
			"grade": grade,
			"grade_value": grade_value,
			"commitment": commitment,
			"route": route_name,
			"ascent_route": ascent_route_name,
			"style": style_label,
			"minutes": minutes_taken,
			"book_minutes": book_minutes,
			"summit": summit_reached,
			"onsight": onsight,
			"date": Time.get_date_string_from_system(),
		}


# =============================================================================
# SCORING
# =============================================================================

## Score a finished run. routes: the guidebook for this terrain (RouteSurvey)
static func score_run(run: RunContext, terrain: TerrainService, routes: Array = []) -> RouteScore:
	var score := RouteScore.new()
	if run == null:
		return score
	score.mode = run.route_mode
	score.outcome = run.outcome
	score.summit_reached = run.summit_reached
	score.minutes_taken = run.game_time_elapsed * 60.0
	score.outcome_factor = OUTCOME_FACTORS.get(run.outcome, 0.0)

	var path := run.path_history
	var modes := _travel_modes(run)
	var options := _measure_options(run)
	var guide: Array[RouteSurvey.GuideRoute] = []
	for route in routes:
		guide.append(route)

	# --- the line travelled, leg by leg ---------------------------------
	var legs: Array[Dictionary] = []
	if run.is_full_route():
		var split := run.summit_path_index if run.summit_reached else _highest_index(path)
		var up_rappels := _rappels_made(run, -INF, run.summit_time if run.summit_reached else INF)
		legs.append({"phase": GameEnums.RunPhase.ASCENT, "path": path.slice(0, split + 1), "modes": modes.slice(0, split + 1) if not modes.is_empty() else modes, "rappels": up_rappels})
		if run.summit_reached:
			var down_rappels := _rappels_made(run, run.summit_time, INF)
			legs.append({"phase": GameEnums.RunPhase.DESCENT, "path": path.slice(split), "modes": modes.slice(split) if not modes.is_empty() else modes, "rappels": down_rappels})
		else:
			score.retreated = run.outcome != GameEnums.ResolutionType.FATALITY
	else:
		legs.append({"phase": GameEnums.RunPhase.DESCENT, "path": path, "modes": modes, "rappels": _rappels_made(run, -INF, INF)})

	var hardest := 0.0
	for leg in legs:
		var leg_path: PackedVector3Array = leg["path"]
		if leg_path.size() < 2 or terrain == null:
			continue
		var leg_options := options.duplicate()
		leg_options["modes"] = leg["modes"]
		leg_options["rappels_made"] = leg["rappels"]
		var m := RouteMetrics.measure(leg_path, terrain, leg_options)
		var points := line_points(m.grade_value, m.controlled_vertical)
		var is_ascent: bool = leg["phase"] == GameEnums.RunPhase.ASCENT
		var matched := RouteSurvey.match_route(_voluntary_path(leg_path, leg["modes"]), guide)
		var matched_name := matched.name if matched != null else ""
		if is_ascent:
			score.ascent_grade = m.grade
			score.ascent_route_name = matched_name
			if score.retreated or not run.summit_reached:
				points *= RETREAT_SHARE
		else:
			score.descent_grade = m.grade
			score.route_name = matched_name
		score.line_points += points
		score.book_minutes += m.minutes
		score.vertical += m.controlled_vertical
		score.rappels += m.rappels
		if m.grade_value >= hardest:
			hardest = m.grade_value
			score.grade_value = m.grade_value
			score.grade = m.grade
		var leg_word := "Ascent" if is_ascent else "Descent"
		if not run.is_full_route():
			leg_word = "Line"
		var line_label := "%s: %s, %s (%d m)" % [
			leg_word, matched_name if not matched_name.is_empty() else "own line", m.grade, roundi(m.controlled_vertical)
		]
		if is_ascent and not run.summit_reached:
			line_label += ", turned back"
		score.lines.append({"label": line_label, "value": "%d pts" % roundi(points)})
	score.commitment = AlpineGrade.commitment(score.book_minutes)

	# --- outcome ------------------------------------------------------------
	var outcome_word: String = OUTCOME_WORDS.get(run.outcome, "")
	if score.retreated:
		outcome_word = "retreated to base camp"
	score.lines.append({"label": "Outcome: %s" % outcome_word, "value": "x%.2f" % score.outcome_factor})

	# --- style --------------------------------------------------------------
	_score_style(run, score)
	var style_text := "Style: %s" % score.style_label
	if not score.style_notes.is_empty():
		style_text += " (%s)" % ", ".join(score.style_notes)
	score.lines.append({"label": style_text, "value": "x%.2f" % score.style_factor})

	# --- pace against the book (only for a finished route) ------------------
	var success := run.outcome == GameEnums.ResolutionType.CLEAN_RETURN or run.outcome == GameEnums.ResolutionType.INJURED_RETURN
	if success and score.book_minutes > 0.0 and score.minutes_taken > 0.0:
		score.pace_factor = pace_factor(score.minutes_taken, score.book_minutes)
		score.lines.append({
			"label": "Pace: %s against the book's %s" % [RouteMetrics.format_minutes(score.minutes_taken), RouteMetrics.format_minutes(score.book_minutes)],
			"value": "x%.2f" % score.pace_factor
		})

	# --- the plan -------------------------------------------------------------
	var plan := _planned_line(run)
	if plan.size() >= 2 and path.size() >= 2:
		score.plan_share = RouteSurvey.share_near(_voluntary_path(path, modes), plan, PLAN_TOLERANCE)
		score.plan_factor = 0.9 + 0.2 * score.plan_share
		score.lines.append({"label": "Plan: %d%% of the way on the planned line" % roundi(score.plan_share * 100.0), "value": "x%.2f" % score.plan_factor})

	# --- on-sight: first time on the mountain, no beta but the book ---------
	if success and run.start_conditions != null and run.start_conditions.knowledge_level == GameEnums.KnowledgeLevel.UNKNOWN:
		score.onsight = true
		score.lines.append({"label": "On-sight: first time on this mountain", "value": "x%.2f" % ONSIGHT_BONUS})

	# --- benighted ------------------------------------------------------------
	if success and run.is_dark():
		score.benighted = true
		score.lines.append({"label": "Benighted: finished after dark", "value": "x%.2f" % BENIGHTED_FACTOR})

	var total := score.line_points * score.outcome_factor * score.style_factor * score.pace_factor * score.plan_factor
	if score.onsight:
		total *= ONSIGHT_BONUS
	if score.benighted:
		total *= BENIGHTED_FACTOR
	score.total = maxi(0, roundi(total))
	return score


## Points for a line: grows with the grade (about x1.22 per grade step) and
## with the height covered under control (a little less than in proportion)
static func line_points(grade_value: float, vertical: float) -> float:
	var height_factor := pow(clampf(vertical / REFERENCE_VERTICAL, 0.0, 3.0), 0.8)
	return 100.0 * pow(1.22, grade_value) * height_factor


## Pace factor from minutes taken against the book time of the same line
static func pace_factor(minutes_taken: float, book_minutes: float) -> float:
	if minutes_taken <= 0.0 or book_minutes <= 0.0:
		return 1.0
	return clampf(1.0 + 0.5 * log(book_minutes / minutes_taken), PACE_MIN, PACE_MAX)


## Style factor and label from the run's incidents
static func _score_style(run: RunContext, score: RouteScore) -> void:
	var counts := {}
	for incident in run.incidents:
		var incident_type: String = incident.get("type", "")
		if STYLE_COSTS.has(incident_type):
			counts[incident_type] = int(counts.get(incident_type, 0)) + 1
	var deduction := 0.0
	for incident_type in counts:
		var cost: Array = STYLE_COSTS[incident_type]
		var count: int = counts[incident_type]
		deduction += minf(float(cost[0]) * float(count), float(cost[1]))
		if float(cost[0]) >= 0.02:
			var label: String = cost[2]
			score.style_notes.append("%d %s%s" % [count, label, "" if count == 1 else "s"] if count > 1 else label)
	score.style_factor = maxf(STYLE_FLOOR, 1.0 - deduction)
	score.style_label = style_label(score.style_factor)


static func style_label(factor: float) -> String:
	if factor >= 0.97:
		return "Clean"
	elif factor >= 0.85:
		return "Tidy"
	elif factor >= 0.65:
		return "Scrappy"
	return "Epic"


static func _measure_options(run: RunContext) -> Dictionary:
	var options := {}
	if run.gear_state != null:
		var rope_length := run.gear_state.get_rope_length()
		if rope_length > 0.0:
			options["rope_length"] = rope_length
		options["has_crampons"] = run.gear_state.has_crampons()
		options["weight_modifier"] = run.gear_state.get_weight_modifier()
	return options


## Abseils completed between two game times (hours elapsed)
static func _rappels_made(run: RunContext, from_time: float, to_time: float) -> int:
	var count := 0
	for decision in run.decisions:
		if decision.get("type", "") != "rappel_complete":
			continue
		var at: float = decision.get("game_time", 0.0)
		if at >= from_time and at <= to_time:
			count += 1
	return count


## The planned line(s): descent, or ascent + descent on a full route
static func _planned_line(run: RunContext) -> PackedVector3Array:
	var plan := PackedVector3Array()
	if run.is_full_route():
		var up = run.get_meta("planned_ascent", PackedVector3Array())
		if up is PackedVector3Array:
			plan.append_array(up)
	var down = run.get_meta("planned_route", PackedVector3Array())
	if down is PackedVector3Array:
		plan.append_array(down)
	return plan


## Travel mode per path sample; a jump between samples (a teleport, a
## respawn) is ground nobody crossed and earns nothing
static func _travel_modes(run: RunContext) -> PackedByteArray:
	var path := run.path_history
	var modes := run.path_modes.duplicate() if run.path_modes.size() == path.size() else PackedByteArray()
	if modes.is_empty() and not path.is_empty():
		modes.resize(path.size())
		modes.fill(RouteMetrics.MODE_FOOT)
	for i in range(1, path.size()):
		if path[i].distance_to(path[i - 1]) > RunContext.MAX_SAMPLE_STEP:
			modes[i - 1] = RouteMetrics.MODE_ADRIFT
	return modes


## Path samples covered under control (falls and tumbling slides removed)
static func _voluntary_path(path: PackedVector3Array, modes: PackedByteArray) -> PackedVector3Array:
	if modes.size() != path.size():
		return path
	var result := PackedVector3Array()
	for i in range(path.size()):
		if modes[i] != RouteMetrics.MODE_ADRIFT:
			result.append(path[i])
	return result


static func _highest_index(path: PackedVector3Array) -> int:
	var best := 0
	for i in range(path.size()):
		if path[i].y > path[best].y:
			best = i
	return best
