class_name Library

# Pure-logic layer for the Library feature: filesystem scanning, grid cursor
# math, and persisted scan-location bookkeeping. No scene-tree dependencies.

const SUPPORTED_EXTENSIONS: PackedStringArray = ["jpg", "jpeg", "png", "cr2", "nef", "arw", "dng"]
const RAW_EXTENSIONS: PackedStringArray = ["cr2", "nef", "arw", "dng"]
const LOCATIONS_PATH: String = "user://library_locations.json"
const MAX_SCAN_DEPTH: int = 8


static func is_supported(file_name: String) -> bool:
	if file_name.begins_with("."):
		return false
	var ext: String = file_name.get_extension().to_lower()
	return SUPPORTED_EXTENSIONS.has(ext)


static func is_raw(file_name: String) -> bool:
	var ext: String = file_name.get_extension().to_lower()
	return RAW_EXTENSIONS.has(ext)


# Depth-first directory walk capped at MAX_SCAN_DEPTH; returns one dict per
# supported file, sorted by lowercase name then path.
static func scan_location(dir_path: String, recursive: bool = true) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	_scan_dir(dir_path, recursive, 0, results)
	results.sort_custom(_compare_entries)
	return results


static func _compare_entries(a: Dictionary, b: Dictionary) -> bool:
	var name_a: String = (a["name"] as String).to_lower()
	var name_b: String = (b["name"] as String).to_lower()
	if name_a != name_b:
		return name_a < name_b
	return (a["path"] as String) < (b["path"] as String)


static func _scan_dir(dir_path: String, recursive: bool, depth: int, results: Array[Dictionary]) -> void:
	if depth > MAX_SCAN_DEPTH:
		return
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	if dir.list_dir_begin() != OK:
		return
	var entry: String = dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full_path: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				if recursive:
					_scan_dir(full_path, recursive, depth + 1, results)
			elif is_supported(entry):
				results.append({
					"path": full_path,
					"name": entry,
					"mtime": FileAccess.get_modified_time(full_path),
					"is_raw": is_raw(entry),
				})
		entry = dir.get_next()
	dir.list_dir_end()


# Grid cursor math for arrow-key navigation over a flat, row-major index.
# index: current selection (-1 = none). dx/dy: one-step direction (exactly one
# of them is expected to be nonzero by callers). cols: items per row.
# count: total item count.
static func next_index(index: int, dx: int, dy: int, cols: int, count: int) -> int:
	if count <= 0:
		return -1
	if index < 0:
		return 0
	if dy != 0:
		var target: int = index + dy * cols
		if target >= 0 and target < count:
			return target
		# Moving down past the end: land on the last item if it's a short
		# final row below the current one, otherwise stay put.
		if dy > 0 and index / cols < (count - 1) / cols:
			return count - 1
		return index
	return clampi(index + dx, 0, count - 1)


static func save_locations(locations: PackedStringArray, path: String = LOCATIONS_PATH) -> bool:
	var payload: Dictionary = {"version": 1, "locations": Array(locations)}
	var text: String = JSON.stringify(payload, "\t")
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	return true


static func load_locations(path: String = LOCATIONS_PATH) -> PackedStringArray:
	if not FileAccess.file_exists(path):
		return PackedStringArray()
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return PackedStringArray()
	var data: Dictionary = parsed
	if not data.has("locations") or not (data["locations"] is Array):
		return PackedStringArray()
	var raw_list: Array = data["locations"]
	var result: PackedStringArray = PackedStringArray()
	for item in raw_list:
		if not (item is String):
			return PackedStringArray()
		result.append(item)
	return result
