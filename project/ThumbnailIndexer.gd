extends Node

# GUI-side handle for the background RAW-thumbnail worker. Spawns the same app
# binary headless with a "--thumb-worker" user arg; the worker scans every
# given root, renders a disk-cached thumbnail for whatever is missing one, then
# exits. This node owns the spawned process's pid and a poll Timer; the worker
# writes straight to the shared on-disk ThumbnailCache, so this node's only job
# is to periodically ask the current view to re-check the cache for its visible
# placeholder tiles.
#
# B1 additions: progress is read from thumb_worker_status.json each poll tick
# and forwarded to poll_target.on_index_progress(done, total). If the worker
# process dies with work still outstanding (crash, not a clean completion), it
# is respawned (same roots) up to MAX_RESPAWNS times; the worker's own
# startup-time skip-list fold isolates whatever RAW crashed it. A dead worker
# never blocks the GUI: once respawns are exhausted, polling just stops.

const MAX_RESPAWNS: int = 8

var _pid: int = -1
var _poll_timer: Timer = null
var _poll_target: Object = null
var _roots: PackedStringArray = PackedStringArray()
var _respawn_count: int = 0


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

	_roots = roots
	_poll_target = poll_target
	_respawn_count = 0
	_spawn()


# Builds dev-vs-exported argv and launches the worker on `_roots`. Separated
# from start() so a crash respawn can relaunch without resetting the retry
# counter or re-touching the poll target.
func _spawn() -> void:
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
	for root in _roots:
		args.append(root)

	_pid = OS.create_process(path, args, false)
	if _pid <= 0:
		printerr("ThumbnailIndexer: failed to spawn worker (path=", path, ")")
		_pid = -1
		return

	_poll_timer.start()


# Kills the worker if still running. Safe to call multiple times (e.g. once
# from _cleanup_backend on quit, having already stopped naturally).
func stop() -> void:
	if _pid != -1 and OS.is_process_running(_pid):
		OS.kill(_pid)
		# Deliberate kill, not a crash: blank the worker's mid-render marker so the
		# next launch re-renders the interrupted photo instead of skip-listing it.
		# A genuine crash goes through the respawn path (not stop()), which leaves
		# inprogress set so the offender IS skip-listed.
		ThumbWorkerIPC.clear_inprogress()
	_pid = -1
	if _poll_timer != null:
		_poll_timer.stop()


func _on_poll_timeout() -> void:
	if _poll_target == null or not is_instance_valid(_poll_target):
		_poll_timer.stop()
		return
	if _pid != -1 and OS.is_process_running(_pid):
		_poll_target.refresh_visible_from_cache()
		var status: Dictionary = ThumbWorkerIPC.read_status()
		_poll_target.on_index_progress(int(status["done"]), int(status["total"]))
		return

	# Worker process is dead. One final sweep to pick up anything it finished
	# right before exiting/crashing.
	_poll_target.refresh_visible_from_cache()
	_pid = -1

	var status: Dictionary = ThumbWorkerIPC.read_status()
	var complete: bool = bool(status["complete"])
	var total: int = int(status["total"])
	var done: int = int(status["done"])
	if complete or total == 0 or done >= total:
		# Clean finish (or nothing was ever queued): stop polling.
		_poll_timer.stop()
		_poll_target.on_indexing_finished()
		return

	# Crashed mid-work: respawn (same roots; the worker's own startup skip-list
	# fold isolates whatever RAW crashed it), bounded by MAX_RESPAWNS so a
	# worker that keeps dying can't loop forever.
	if _respawn_count < MAX_RESPAWNS:
		_respawn_count += 1
		printerr("ThumbnailIndexer: worker died with work outstanding (done=",
			done, "/", total, "), respawning (attempt ", _respawn_count, ")")
		_spawn()
		return

	printerr("ThumbnailIndexer: worker crashed too many times, giving up")
	_poll_timer.stop()
	_poll_target.on_indexing_finished()
