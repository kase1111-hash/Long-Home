class_name AvalancheBulletinPanel
extends RefCounted
## Prints the day's avalanche bulletin into a VBoxContainer, laid out the way
## the services print theirs: the danger by elevation band in its colour,
## the headline, each avalanche problem with an aspect rose (the shaded
## sectors are the aspects it lives on) and its likelihood, size and depth,
## the snowpack, and the travel advice.

const INK := Color(0.9, 0.9, 0.88)
const DIM := Color(0.62, 0.62, 0.66)


static func fill(container: Control, conditions: AvalancheConditions, has_glacier: bool = false) -> void:
	for child in container.get_children():
		child.queue_free()
	if conditions == null:
		container.add_child(_label("No bulletin for this mountain.", 13, DIM))
		return

	container.add_child(_label("Avalanche bulletin: today", 16, INK))
	var headline := _label(conditions.headline, 13, INK)
	headline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	container.add_child(headline)

	# Danger by band, top of the mountain first
	var edges := conditions.band_edges
	var range_text: Array[String] = [
		"below %s m" % AvalancheConditions._thousands(edges.x),
		"%s-%s m" % [AvalancheConditions._thousands(edges.x), AvalancheConditions._thousands(edges.y)],
		"above %s m" % AvalancheConditions._thousands(edges.y),
	]
	for band in [2, 1, 0]:
		var level: int = conditions.danger[band]
		var row := HBoxContainer.new()
		row.name = "DangerRow%d" % band
		row.add_theme_constant_override("separation", 8)
		var chip := ColorRect.new()
		chip.custom_minimum_size = Vector2(22, 18)
		chip.color = AvalancheConditions.LEVEL_COLORS[level]
		row.add_child(chip)
		row.add_child(_label("%d %s" % [level, AvalancheConditions.LEVEL_NAMES[level]], 13, INK))
		var where := _label("%s, %s" % [AvalancheConditions.BAND_NAMES[band], range_text[band]], 12, DIM)
		where.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(where)
		container.add_child(row)

	container.add_child(HSeparator.new())
	if conditions.problems.is_empty():
		container.add_child(_label("No avalanche problem of note.", 13, DIM))
	for problem in conditions.problems:
		var row := HBoxContainer.new()
		row.name = "Problem%s" % problem.get_name().replace(" ", "")
		row.add_theme_constant_override("separation", 8)
		var rose := AspectRose.new()
		rose.aspects = problem.aspects
		rose.bands = problem.bands
		rose.custom_minimum_size = Vector2(58, 58)
		row.add_child(rose)
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_child(_label(problem.get_name(), 14, INK))
		var details := "%s · %s aspects · %s" % [problem.likelihood_word(), problem.aspect_text(), _band_words(problem.bands)]
		var detail_label := _label(details, 12, DIM)
		detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.add_child(detail_label)
		var size_label := _label("%s, about %d cm deep%s" % [
			problem.size_word(), roundi(problem.depth * 100.0),
			", afternoons" if problem.active_hours.x > 6.0 else ""
		], 12, DIM)
		size_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.add_child(size_label)
		if problem.remote:
			text.add_child(_label("Collapses ('whumpfs') and remote triggering possible.", 12, DIM))
		row.add_child(text)
		container.add_child(row)

	container.add_child(HSeparator.new())
	for line in conditions.get_snowpack_lines():
		var snowpack := _label(line, 12, DIM)
		snowpack.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		container.add_child(snowpack)
	if has_glacier:
		var seracs := _label("Seracs: the icefalls shed blocks at any hour, most in the afternoon warmth.", 12, DIM)
		seracs.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		container.add_child(seracs)
	container.add_child(HSeparator.new())
	var advice := _label(conditions.get_advice(), 13, INK)
	advice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	container.add_child(advice)
	var pit := _label("On the mountain: whumpfs, shooting cracks and fresh avalanches are the snowpack talking. A shovel lets you dig a pit and test it (V).", 12, DIM)
	pit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	container.add_child(pit)


static func _band_words(bands: int) -> String:
	if bands & 0b111 == 0b111:
		return "all elevations"
	var words: Array[String] = []
	for band in range(3):
		if (bands >> band) & 1 == 1:
			words.append(["low", "middle", "high"][band])
	return " and ".join(words) + " on the mountain"


static func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


## The aspect-and-elevation rose: eight sectors in three rings (low
## elevations outside, high inside), shaded where the problem lives
class AspectRose extends Control:
	var aspects: int = 0
	var bands: int = 0b111

	func _draw() -> void:
		var centre := size * 0.5
		var radius := minf(size.x, size.y) * 0.5 - 2.0
		var off := Color(0.3, 0.3, 0.34)
		var on := Color(0.95, 0.55, 0.15)
		for ring in range(3):
			# Ring 0 (outer) is the lower mountain
			var r_out := radius * (1.0 - float(ring) / 3.0)
			var r_in := radius * (1.0 - float(ring + 1) / 3.0)
			for sector in range(8):
				var lit := (aspects >> sector) & 1 == 1 and (bands >> ring) & 1 == 1
				var a0 := deg_to_rad(float(sector) * 45.0 - 22.5 - 90.0)
				var a1 := deg_to_rad(float(sector) * 45.0 + 22.5 - 90.0)
				var points := PackedVector2Array()
				for k in range(5):
					var a := lerpf(a0, a1, float(k) / 4.0)
					points.append(centre + Vector2(cos(a), sin(a)) * r_out)
				for k in range(5):
					var a := lerpf(a1, a0, float(k) / 4.0)
					points.append(centre + Vector2(cos(a), sin(a)) * maxf(r_in, 0.5))
				draw_colored_polygon(points, on if lit else off)
				draw_polyline(points + PackedVector2Array([points[0]]), Color(0.1, 0.1, 0.12), 1.0)
		draw_string(ThemeDB.fallback_font, centre + Vector2(-4, -radius - 1), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.85, 0.85, 0.85))
