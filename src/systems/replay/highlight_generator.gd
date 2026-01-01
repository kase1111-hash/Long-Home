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

@export_group("Highlight Settings")
## Minimum importance for highlight
@export var min_importance: float = 0.6
## Buffer before event (seconds)
@export var lead_in: float = 3.0
## Buffer after event (seconds)
@export var lead_out: float = 2.0
## Maximum highlight duration
@export var max_duration: float = 15.0
## Minimum gap between highlights
@export var min_gap: float = 5.0

@export_group("Ethical Settings")
## Exclude fatal events
@export var exclude_fatal: bool = true
## Use neutral titles
@export var neutral_titles: bool = true

# =============================================================================
# STATE
# =============================================================================

## Generated highlights
var highlights: Array[Highlight] = []

## Recording reference
var recording: RecordingService.RecordingData

## Streamer tools reference
var streamer_tools: StreamerTools


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

func generate_highlights(rec: RecordingService.RecordingData) -> Array[Highlight]:
	recording = rec
	highlights.clear()

	if recording == null:
		return highlights

	# Find notable events
	var notable_events := _find_notable_events()

	# Convert to highlights
	for event in notable_events:
		var highlight := _create_highlight(event)
		if highlight:
			highlights.append(highlight)

	# Merge overlapping highlights
	_merge_overlapping()

	# Sort by importance
	highlights.sort_custom(func(a, b): return a.importance > b.importance)

	highlights_ready.emit(highlights)
	return highlights


func _find_notable_events() -> Array[Dictionary]:
	var events: Array[Dictionary] = []

	for event in recording.events:
		# Skip fatal events if configured
		if exclude_fatal and event.event_type == "fatal_event":
			continue

		var importance := _calculate_importance(event)
		if importance >= min_importance:
			events.append({
				"event": event,
				"importance": importance
			})

	return events


func _calculate_importance(event: RecordingService.RecordedEvent) -> float:
	match event.event_type:
		"slide_started":
			return 0.6
		"slide_ended":
			var outcome: String = event.data.get("outcome", "")
			match outcome:
				"CLEAN_STOP":
					return 0.7
				"TUMBLE_STOP":
					return 0.8
				"TERRAIN_CATCH":
					return 0.7
				_:
					return 0.5
		"rope_deployed":
			var quality: String = event.data.get("quality", "")
			if quality in ["MARGINAL", "POOR"]:
				return 0.8
			return 0.6
		"injury":
			return 0.5 + event.data.get("severity", 0) * 0.3
		"decision":
			return 0.5
		"weather_changed":
			var to_weather: String = event.data.get("to", "")
			if to_weather in ["STORM", "WHITEOUT"]:
				return 0.7
			return 0.4
		_:
			return 0.0


func _create_highlight(event_data: Dictionary) -> Highlight:
	var event: RecordingService.RecordedEvent = event_data["event"]
	var importance: float = event_data["importance"]

	# Check ethical exclusion
	if streamer_tools and streamer_tools.should_exclude_from_clip(event.timestamp, recording):
		return null

	var highlight := Highlight.new()
	highlight.id = str(randi())
	highlight.importance = importance
	highlight.category = _get_category(event)

	# Calculate timing
	highlight.start_time = maxf(0.0, event.timestamp - lead_in)
	highlight.end_time = minf(
		recording.end_time - recording.start_time,
		event.timestamp + lead_out
	)
	highlight.duration = highlight.end_time - highlight.start_time

	# Cap duration
	if highlight.duration > max_duration:
		highlight.end_time = highlight.start_time + max_duration
		highlight.duration = max_duration

	# Generate title
	highlight.title = _generate_title(event)

	# Thumbnail at peak moment
	highlight.thumbnail_time = event.timestamp

	highlight_generated.emit(highlight)
	return highlight


func _get_category(event: RecordingService.RecordedEvent) -> String:
	match event.event_type:
		"slide_started", "slide_ended":
			return "descent"
		"rope_deployed":
			return "technical"
		"injury":
			return "challenge"
		"decision":
			return "choice"
		"weather_changed":
			return "conditions"
		_:
			return "moment"


func _generate_title(event: RecordingService.RecordedEvent) -> String:
	if not neutral_titles:
		return event.event_type.capitalize().replace("_", " ")

	# Ethical neutral titles
	match event.event_type:
		"slide_started":
			return "Slope Navigation"
		"slide_ended":
			var outcome: String = event.data.get("outcome", "")
			match outcome:
				"CLEAN_STOP":
					return "Controlled Descent"
				"TUMBLE_STOP":
					return "Recovery Moment"
				"TERRAIN_CATCH":
					return "Terrain Interaction"
				_:
					return "Descent Sequence"
		"rope_deployed":
			return "Technical Section"
		"injury":
			return "Challenging Terrain"
		"decision":
			return "Key Decision Point"
		"weather_changed":
			return "Conditions Change"
		_:
			return "Mountain Moment"


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
			# Merge - extend current
			current.end_time = maxf(current.end_time, next.end_time)
			current.duration = current.end_time - current.start_time
			current.importance = maxf(current.importance, next.importance)

			# Keep better title
			if next.importance > current.importance:
				current.title = next.title
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
		"choice":
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
