class_name RejectStore

# Persistent set of rejected photo keys. One flat versioned JSON file at the
# top of user:// (no sharding: the whole set is small and read/written whole).
# A key is a membership flag ({key: true}) so presence checks are O(1).
# Mirrors Library.gd's versioned JSON + all-or-nothing validation and
# EditStore's atomic tmp+rename write.

const STORE_PATH: String = "user://rejects.json"
const VERSION: int = 1


# Reuse EditStore's identity so a photo keys identically in both stores.
static func reject_key(file_name: String, hash: String) -> String:
	return EditStore.edit_key(file_name, hash)


# Whole-set load. Returns a {key: true} membership dict, or {} on missing
# file, malformed JSON, version mismatch, or bad shape (all-or-nothing).
static func load_set(path: String = STORE_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {}
	var data: Dictionary = parsed
	if int(data.get("version", -1)) != VERSION:
		return {}
	if not data.has("keys") or not (data["keys"] is Array):
		return {}
	var raw_list: Array = data["keys"]
	var result: Dictionary = {}
	for item in raw_list:
		if not (item is String):
			return {}
		result[item] = true
	return result


# Atomic tmp+rename write of the full set; a crash mid-write cannot corrupt
# an existing file. Returns false on any I/O failure.
static func save_set(keys: Dictionary, path: String = STORE_PATH) -> bool:
	var payload: Dictionary = {"version": VERSION, "keys": keys.keys()}
	var text: String = JSON.stringify(payload, "\t")

	var tmp_path: String = path + ".tmp"
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
