class_name RouteCard
extends RefCounted
## Builds the guidebook's route card (title, grade, book time, abseils, a
## numbered pitch-by-pitch topo) into any VBoxContainer: the planning
## screen's guidebook, the paper map pulled out on the mountain, the pause
## map. The topo gives altitudes, so with an altimeter the climber can tell
## which pitch they are on; nothing about the route is marked on the
## mountain itself.

const PAPER_INK := Color(0.24, 0.2, 0.16)
const PAPER_DIM := Color(0.42, 0.37, 0.3)
const SCREEN_INK := Color(0.9, 0.9, 0.88)
const SCREEN_DIM := Color(0.62, 0.62, 0.66)


## Fill container with a route card. options:
##   on_paper     bool    dark ink for the paper map (default false: light text)
##   description  String  guidebook blurb under the title
##   ascending    bool    the line is climbed (pitch words change)
##   max_pitches  int     cap on listed pitches (default all)
##   font_size    int     body size (default 13)
static func fill(container: Control, title: String, metrics: RouteMetrics.Result, options: Dictionary = {}) -> void:
	for child in container.get_children():
		child.queue_free()
	if metrics == null:
		return
	var on_paper: bool = options.get("on_paper", false)
	var ink := PAPER_INK if on_paper else SCREEN_INK
	var dim := PAPER_DIM if on_paper else SCREEN_DIM
	var body_size: int = options.get("font_size", 13)
	var ascending: bool = options.get("ascending", metrics.ascending)

	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 8)
	container.add_child(heading)
	var title_label := _label(title, body_size + 3, ink)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	heading.add_child(title_label)
	var grade_label := _label(metrics.get_full_grade(), body_size + 3, AlpineGrade.grade_color(metrics.grade_value).darkened(0.25 if on_paper else 0.0))
	heading.add_child(grade_label)

	container.add_child(_label(summary_line(metrics, ascending), body_size, dim))

	var description: String = options.get("description", "")
	if not description.is_empty():
		var blurb := _label(description, body_size, ink)
		blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		container.add_child(blurb)

	var gear := gear_line(metrics, ascending)
	if not gear.is_empty():
		container.add_child(_label(gear, body_size, dim))

	var max_pitches: int = options.get("max_pitches", 99)
	var shown := 0
	for pitch in metrics.pitches:
		if shown >= max_pitches:
			container.add_child(_label("  … %d more" % (metrics.pitches.size() - shown), body_size - 1, dim))
			break
		shown += 1
		var line := _label("%d.  %s  [%s]" % [shown, RouteMetrics.describe_pitch(pitch, ascending), RouteMetrics.format_minutes(pitch.minutes)], body_size - 1, ink)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		container.add_child(line)


## "1h 34m · 526 m, down 205 m · 1 abseil"
static func summary_line(metrics: RouteMetrics.Result, ascending: bool = false) -> String:
	var parts: Array[String] = []
	parts.append(RouteMetrics.format_minutes(metrics.minutes))
	parts.append("%d m, %s %d m" % [roundi(metrics.length), "up" if ascending else "down", roundi(metrics.get_vertical())])
	if metrics.rappels > 0 and not ascending:
		parts.append("%d abseil%s" % [metrics.rappels, "" if metrics.rappels == 1 else "s"])
	if ascending and metrics.ascent_blocked:
		parts.append("no way up on foot")
	return " · ".join(parts)


## Gear the line asks for
static func gear_line(metrics: RouteMetrics.Result, ascending: bool = false) -> String:
	var needs: Array[String] = []
	if metrics.crampons_advised:
		needs.append("crampons")
	if metrics.sustained_slope >= 30.0 or metrics.glacier_metres > 0.0:
		needs.append("axe" if metrics.glacier_metres <= 0.0 else "axe to probe")
	if metrics.rope_required and not ascending:
		needs.append("%d m rope" % roundi(metrics.min_rope_length))
	if needs.is_empty():
		return ""
	return "Take: " + ", ".join(needs)


static func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


# =============================================================================
# THE CARD FOR A RUN
# =============================================================================

## The card a climber carries for this run: the planned line for the leg
## they are on (ascent or descent), measured on the terrain and titled with
## the guidebook line it follows. Cached on the run per leg.
static func for_run(run: RunContext, terrain: TerrainService) -> Dictionary:
	if run == null or terrain == null:
		return {}
	var climbing := run.is_full_route() and run.phase == GameEnums.RunPhase.ASCENT
	var cache_key := "route_card_ascent" if climbing else "route_card_descent"
	if run.has_meta(cache_key):
		return run.get_meta(cache_key)
	var plan = run.get_meta("planned_ascent" if climbing else "planned_route", PackedVector3Array())
	if not (plan is PackedVector3Array) or plan.size() < 2:
		return {}
	var metrics := RouteMetrics.measure(plan, terrain)
	var title := "Your line"
	var description := ""
	var copied_id := str(run.get_meta("guide_route", "")) if not climbing else ""
	var routes := RouteSurvey.survey(terrain)
	for route in routes:
		var line := route.get_ascent_line() if climbing else route.line
		var share := RouteSurvey.share_near(plan, line, 15.0)
		if route.id == copied_id or share >= 0.95:
			# The book's line, copied onto the plan
			title = route.name
			description = route.description
			break
		if share >= 0.8:
			title = "Your line, near the %s" % route.name
	var card := {"title": title, "metrics": metrics, "ascending": climbing, "description": description}
	run.set_meta(cache_key, card)
	return card
