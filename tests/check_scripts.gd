extends SceneTree
## Loads every GDScript file in the project and reports the ones that fail
## to compile. Run with:
##   godot --headless --path . -s res://tests/check_scripts.gd
## Exit code is non-zero when any script fails.

const ROOTS := ["res://src", "res://tests"]


func _init() -> void:
	# Defer so quit() exit codes propagate once the main loop is running
	call_deferred("_run")


func _run() -> void:
	var files: Array[String] = []
	for root in ROOTS:
		_collect(root, files)
	files.sort()

	var failed: Array[String] = []
	for path in files:
		var script := ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
		if script == null or not script.can_instantiate():
			failed.append(path)

	print("[check_scripts] Checked %d scripts, %d failed" % [files.size(), failed.size()])
	for path in failed:
		print("[check_scripts] FAILED: %s" % path)

	quit(1 if failed.size() > 0 else 0)


func _collect(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_collect(full, out)
		elif entry.ends_with(".gd") and entry != "check_scripts.gd":
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
