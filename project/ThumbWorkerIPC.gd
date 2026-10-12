class_name ThumbWorkerIPC
extends RefCounted

# Atomic read/write of the three small JSON files that let the GUI and the
# background thumb worker (Main._run_thumb_worker) talk without pipes. Same
# tmp+rename idiom as RejectStore.gd / UiStateStore.gd. Every load function
# degrades to an empty/default shape on a missing or malformed file; nothing
# here ever throws.

const PRIORITY_PATH: String = "user://thumb_worker_priority.json"
const STATUS_PATH: String = "user://thumb_worker_status.json"
const SKIP_PATH: String = "user://thumb_worker_skip.json"

const VERSION: int = 1


# Shared tmp+rename writer: stores `text` at `path` via a pid-suffixed tmp file
# so concurrent writers (GUI + worker) never clobber each other's tmp name.
static func _write_atomic(path: String, text: String) -> bool:
	var tmp_path: String = "%s.tmp.%d" % [path, OS.get_process_id()]
	var file: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()

	var err: int = DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path),
		ProjectSettings.globalize_path(path))
	if err != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return false
	return true


static func _load_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {}
	return parsed


# --- Priority file: GUI writes, worker reads. Most-important path first. -----

static func write_priority(paths: PackedStringArray) -> bool:
	var payload: Dictionary = {"version": VERSION, "paths": Array(paths)}
	return _write_atomic(PRIORITY_PATH, JSON.stringify(payload, "\t"))


# Returns the path list, or an empty array on missing/malformed/wrong-version
# file (no prioritization; caller falls back to scan order).
static func read_priority() -> PackedStringArray:
	var data: Dictionary = _load_dict(PRIORITY_PATH)
	if int(data.get("version", -1)) != VERSION:
		return PackedStringArray()
	if not data.has("paths") or not (data["paths"] is Array):
		return PackedStringArray()
	var result: PackedStringArray = PackedStringArray()
	for item in data["paths"]:
		if item is String:
			result.append(item)
	return result


# --- Status file: worker writes, GUI reads. ----------------------------------

static func write_status(done: int, total: int, inprogress: String, complete: bool) -> bool:
	var payload: Dictionary = {
		"version": VERSION,
		"done": done,
		"total": total,
		"inprogress": inprogress,
		"complete": complete,
	}
	return _write_atomic(STATUS_PATH, JSON.stringify(payload, "\t"))


# Returns {"done":int,"total":int,"inprogress":String,"complete":bool}. All
# fields default to 0/""/false on a missing/malformed/wrong-version file, so a
# dead-worker check reads this as "nothing in flight" rather than crashing.
static func read_status() -> Dictionary:
	var data: Dictionary = _load_dict(STATUS_PATH)
	if int(data.get("version", -1)) != VERSION:
		return {"done": 0, "total": 0, "inprogress": "", "complete": false}
	return {
		"done": int(data.get("done", 0)),
		"total": int(data.get("total", 0)),
		"inprogress": String(data.get("inprogress", "")),
		"complete": bool(data.get("complete", false)),
	}


# --- Skip (poison-RAW) list: worker reads at startup, folds in crashes, writes back. ---

static func read_skip() -> PackedStringArray:
	var data: Dictionary = _load_dict(SKIP_PATH)
	if int(data.get("version", -1)) != VERSION:
		return PackedStringArray()
	if not data.has("paths") or not (data["paths"] is Array):
		return PackedStringArray()
	var result: PackedStringArray = PackedStringArray()
	for item in data["paths"]:
		if item is String:
			result.append(item)
	return result


static func write_skip(paths: PackedStringArray) -> bool:
	var payload: Dictionary = {"version": VERSION, "paths": Array(paths)}
	return _write_atomic(SKIP_PATH, JSON.stringify(payload, "\t"))
