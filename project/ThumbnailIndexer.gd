extends Node

# GUI-side handle for the background RAW-thumbnail worker. Spawns the same app
# binary headless with a "--thumb-worker" user arg; the worker scans every
# given root, renders a disk-cached thumbnail for whatever is missing one, then
# exits. This node owns the spawned process's pid and a poll Timer; the worker
# writes straight to the shared on-disk ThumbnailCache, so this node's only job
# is to periodically ask the current view to re-check the cache for its visible
# placeholder tiles.

var _pid: int = -1
var _poll_timer: Timer = null
var _poll_target: Object = null


func _ready() -> void:
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 0.75
	_poll_timer.autostart = false
	_poll_timer.one_shot = false
	_poll_timer.timeout.connect(_on_poll_timeout)
	add_child(_poll_timer)


# Spawns the worker over `roots` (absolute globalized directory paths) and
# starts polling `poll_target.refresh_visible_from_cache()`. Re-targetable: an
# already-running worker is killed and respawned on the new root set, so callers
# can restart it when the library location set changes.
func start(roots: PackedStringArray, poll_target: Object) -> void:
	if roots.is_empty():
		return
	stop()

	var path: String
	var args: PackedStringArray = PackedStringArray()
	if OS.has_feature("editor"):
		# Dev: OS.get_executable_path() is the editor binary itself, which needs
		# --path to the project plus --headless to avoid opening the editor UI.
		path = OS.get_executable_path()
		args.append("--path")
		args.append(ProjectSettings.globalize_path("res://"))
		args.append("--headless")
	else:
		# Exported: the binary IS the app; --script is unavailable here, so the
		# same binary is relaunched headless and Main._ready branches on the
		# user arg below.
		path = OS.get_executable_path()
		args.append("--headless")
	args.append("--")
	args.append("--thumb-worker")
	for root in roots:
		args.append(root)

	_pid = OS.create_process(path, args, false)
	if _pid <= 0:
		printerr("ThumbnailIndexer: failed to spawn worker (path=", path, ")")
		_pid = -1
		return

	_poll_target = poll_target
	_poll_timer.start()


# Kills the worker if still running. Safe to call multiple times (e.g. once
# from _cleanup_backend on quit, having already stopped naturally).
func stop() -> void:
	if _pid != -1 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	if _poll_timer != null:
		_poll_timer.stop()


func _on_poll_timeout() -> void:
	if _poll_target == null or not is_instance_valid(_poll_target):
		_poll_timer.stop()
		return
	if _pid != -1 and OS.is_process_running(_pid):
		_poll_target.refresh_visible_from_cache()
		return
	# Worker exited: one final sweep to pick up anything it finished right
	# before quitting, then stop polling.
	_poll_target.refresh_visible_from_cache()
	_poll_timer.stop()
	_pid = -1
