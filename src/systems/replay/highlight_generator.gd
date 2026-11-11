class_name HighlightGenerator
extends Node
## Generates ethical highlights from recorded gameplay
## Excludes fatal moments, uses neutral titles
##
## Design Philosophy:
## - Fatal moments excluded from auto-highlights
## - Highlight titles never reference death
## - Focus on skill, terrain, decisions

# =============================================================================
# SIGNALS
# =============================================================================

signal highlight_generated(highlight: Highlight)
signal highlights_ready(highlights: Array[Highlight])
signal export_complete(path: String)

# =============================================================================
# DATA STRUCTURES
# =============================================================================

class Highlight:
	var id: String
	var title: String
	var start_time: float
	var end_time: float
	var duration: float
	var importance: float
	var category: String
	var thumbnail_time: float

	func to_dict() -> Dictionary:
		return {
			"id": id,
			"title": title,
			"start": start_time,
			"end": end_time,
			"duration": duration,
			"importance": importance,
			"category": category,
			"thumbnail": thumbnail_time
		}


# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Ethical Settings")
## Exclude fatal events
@export var exclude_fatal: bool = true
## Use neutral titles
@export var neutral_titles: bool = true

@export_group("Highlight Settings")
## Buffer before event (seconds)
@export var lead_in: float = 4.0
## Buffer after event (seconds)
@export var lead_out: float = 4.0
## Maximum highlight duration
@export var max_duration: float = 40.0
## Minimum gap between highlights
@export var min_gap: float = 3.0
## A glissade shorter than this is not a highlight (seconds)
@export var min_slide_time: float = 4.0

## Nothing is a highlight from this long before control was lost (seconds):
## "clips stop before loss of control"
const FATAL_MARGIN := 8.0

## Where on the mountain, by the share of the height still above base camp
const SECTIONS := [
	[0.85, "Summit Slopes"],
	[0.6, "Upper Face"],
	[0.35, "Middle Slopes"],
	[0.12, "Lower Slopes"],
	[-INF, "Run-Out"],
]

## Slides that ended under control (SPEC-SHEET 17: "successful long slides";
## uncontrolled slides are excluded)
const CONTROLLED_SLIDE_ENDS := ["CLEAN_STOP", "TERRAIN_CATCH"]

## Incidents that make getting home afterwards worth a highlight. None of
## them is a highlight itself.
const TROUBLE := [
	"self_arrest_failed", "slide_from_slip", "slide_upset", "slide_impact", "ski_crash",
	"fall_from_slip", "fall_over", "fall_injury", "hard_landing", "injury",
	"avalanche_triggered", "avalanche_caught", "avalanche_burial",
	"crevasse_fall", "anchor_failure", "rope_jam", "rope_lost",
]

# =============================================================================
# STATE
# =============================================================================

## Generated highlights
var highlights: Array[Highlight] = []

## Recording reference
var recording: RecordingService.RecordingData

## Streamer tools reference
var streamer_tools: StreamerTools

## Heights of the summit and of base camp (for naming the part of the mountain)
var _top: float = 0.0
var _bottom: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("HighlightGenerator", self)
	ServiceLocator.get_service_async("StreamerTools", func(s): streamer_tools = s)
	print("[HighlightGenerator] Initialized")


# =============================================================================
# GENERATION
# =============================================================================

## The highlights of a recording, in the order they happened (SPEC-SHEET 17):
## long glissades that ended under control, slips that were arrested, the
## rope going out, the weather turning, and coming home after trouble. Never
## a fall, an impact, a slide out of control or anything from the moments
## before control was lost for good. Titles name the place and what was done
## ("Upper Face - Weather Turn"), never the danger.
##
## A glissade is a slide the climber sat down to; the axe at the end of one is
## how it is stopped, not a close call. A slide they did not choose (a slip, a
## tumble, a ski crash) is never a highlight, but stopping one with the axe is.
##   top, bottom: heights of the summit and of base camp (metres)
func generate_highlights(rec: RecordingService.RecordingData, top: float = 0.0, bottom: float = 0.0) -> Array[Highlight]:
	recording = rec
	_top = top
	_bottom = bottom
	highlights.clear()

	if recording == null or recording.frames.is_empty():
		return highlights

	var slide_started := -1.0
	## The slide under way was the climber's choice (SlideSystem says so when
	## one starts: its "slide_initiated" decision)
	var slide_chosen := true
	var trouble := false
	for event in recording.events:
		match event.event_type:
			"decision":
				if str(event.data.get("type", "")) == "slide_initiated":
					var context: Variant = event.data.get("context", {})
					slide_chosen = not (context is Dictionary and bool((context as Dictionary).get("uncontrolled", false)))
			"slide_started":
				slide_started = event.timestamp
			"slide_ended":
				var controlled := str(event.data.get("outcome", "")) in CONTROLLED_SLIDE_ENDS
				if not controlled or not slide_chosen:
					trouble = true
				elif slide_started >= 0.0 and event.timestamp - slide_started >= min_slide_time:
					_add(slide_started - lead_in, event.timestamp + lead_out, "Glissade", "descent", 0.7, slide_started)
				slide_started = -1.0
				slide_chosen = true
			"rope_deployed":
				_add(event.timestamp - lead_in, event.timestamp + lead_out * 2.0, "Abseil", "technical", 0.6, event.timestamp)
			"weather_changed":
				var title := _weather_title(str(event.data.get("from", "")), str(event.data.get("to", "")))
				if not title.is_empty():
					_add(event.timestamp - lead_in, event.timestamp + lead_out, title, "conditions", 0.6, event.timestamp)
			"injury":
				trouble = true
			"incident":
				var incident := str(event.data.get("type", ""))
				if incident == "self_arrest_success":
					# The axe stopping a slide nobody chose: a close call, caught.
					# From the slip to the stop, the stop always in it.
					if not slide_chosen:
						var to := event.timestamp + lead_out
						var from := event.timestamp - lead_in * 1.5
						if slide_started >= 0.0:
							from = maxf(slide_started - lead_in, to - max_duration)
						_add(from, to, "Self-Arrest", "recovery", 0.8, event.timestamp)
						trouble = true
				elif incident in TROUBLE:
					trouble = true
			"run_ended":
				if trouble and str(event.data.get("outcome", "")) in ["CLEAN_RETURN", "INJURED_RETURN"]:
					_add(event.timestamp - lead_in * 2.0, event.timestamp, "Safe Return", "return", 0.75, event.timestamp)

	_merge_overlapping()
	highlights.sort_custom(func(a, b): return a.start_time < b.start_time)

	highlights_ready.emit(highlights)
	return highlights


## Add a highlight unless the ethical rules keep it out
func _add(from: float, to: float, what: String, category: String, importance: float, at: float) -> void:
	var first := recording.frames[0].timestamp
	var last := recording.frames[-1].timestamp
	# Nothing from the moments before control was lost for good, nor after
	var lost := recording.loss_time() if exclude_fatal else INF
	if is_finite(lost):
		last = minf(last, lost - FATAL_MARGIN)
		if at > last:
			return
	if streamer_tools != null and streamer_tools.should_exclude_from_clip(at, recording):
		return
	var highlight := Highlight.new()
	highlight.id = "%s_%d" % [category, highlights.size()]
	highlight.start_time = clampf(from, first, last)
	highlight.end_time = clampf(minf(to, highlight.start_time + max_duration), highlight.start_time, last)
	highlight.duration = highlight.end_time - highlight.start_time
	if highlight.duration < 1.0:
		return
	highlight.importance = importance
	highlight.category = category
	highlight.thumbnail_time = clampf(at, highlight.start_time, highlight.end_time)
	highlight.title = "%s - %s" % [section_name(_height_at(at)), what] if neutral_titles else what
	highlights.append(highlight)
	highlight_generated.emit(highlight)


## A change of weather worth a title ("" when it is not: small shifts)
func _weather_title(from: String, to: String) -> String:
	if not GameEnums.WeatherState.has(from) or not GameEnums.WeatherState.has(to):
		return ""
	var before := WeatherService.weather_rung(GameEnums.WeatherState[from])
	var after := WeatherService.weather_rung(GameEnums.WeatherState[to])
	if after > before and after >= WeatherService.SNOW_RUNG:
		return "Weather Turn"
	if after < before and before >= WeatherService.SNOW_RUNG:
		return "Sky Clearing"
	return ""


## The climber's height at a moment of the recording
func _height_at(timestamp: float) -> float:
	var frames := recording.frames
	var low := 0
	var high := frames.size() - 1
	while low < high:
		var mid := (low + high + 1) / 2
		if frames[mid].timestamp <= timestamp:
			low = mid
		else:
			high = mid - 1
	return frames[low].player_position.y


## The part of the mountain a height is on ("Upper Face")
func section_name(height: float) -> String:
	if _top - _bottom < 1.0:
		return "The Mountain"
	var share := (height - _bottom) / (_top - _bottom)
	for section in SECTIONS:
		if share >= float(section[0]):
			return section[1]
	return "Run-Out"


func _merge_overlapping() -> void:
	if highlights.size() < 2:
		return

	# Sort by start time
	highlights.sort_custom(func(a, b): return a.start_time < b.start_time)

	var merged: Array[Highlight] = []
	var current := highlights[0]

	for i in range(1, highlights.size()):
		var next := highlights[i]

		# Check for overlap or small gap
		if next.start_time - current.end_time < min_gap:
			# Merge - extend current, keep the title of the more important one
			if next.importance > current.importance:
				current.title = next.title
				current.category = next.category
				current.thumbnail_time = next.thumbnail_time
			current.end_time = maxf(current.end_time, next.end_time)
			current.duration = current.end_time - current.start_time
			current.importance = maxf(current.importance, next.importance)
		else:
			merged.append(current)
			current = next

	merged.append(current)
	highlights = merged


# =============================================================================
# EXPORT
# =============================================================================

func export_highlight_markers(path: String) -> void:
	## Export markers for video editing software

	var markers: Array[Dictionary] = []

	for highlight in highlights:
		markers.append({
			"name": highlight.title,
			"start": highlight.start_time,
			"end": highlight.end_time,
			"color": _get_marker_color(highlight.category)
		})

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"markers": markers}))
		file.close()
		export_complete.emit(path)


func _get_marker_color(category: String) -> String:
	match category:
		"descent":
			return "#3498db"
		"technical":
			return "#9b59b6"
		"challenge":
			return "#e74c3c"
		"recovery", "return":
			return "#f1c40f"
		"conditions":
			return "#1abc9c"
		_:
			return "#95a5a6"


# =============================================================================
# QUERIES
# =============================================================================

func get_highlights() -> Array[Highlight]:
	return highlights


func get_top_highlights(count: int = 5) -> Array[Highlight]:
	var sorted := highlights.duplicate()
	sorted.sort_custom(func(a, b): return a.importance > b.importance)

	var result: Array[Highlight] = []
	for i in range(mini(count, sorted.size())):
		result.append(sorted[i])
	return result


func get_summary() -> Dictionary:
	return {
		"total_highlights": highlights.size(),
		"categories": _count_categories(),
		"total_duration": _total_duration()
	}


func _count_categories() -> Dictionary:
	var counts := {}
	for highlight in highlights:
		var cat: String = highlight.category
		counts[cat] = counts.get(cat, 0) + 1
	return counts


func _total_duration() -> float:
	var total := 0.0
	for highlight in highlights:
		total += highlight.duration
	return total
