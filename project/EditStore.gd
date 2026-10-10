class_name EditStore

# Persistent, non-destructive edit history. One JSON record per photo, sharded
# into 2-char subdirectories under user://edits (same layout as ThumbnailCache).
# Each record is a self-contained identity+sync envelope (id, file_name,
# thumb_hash, updated_at) wrapping the restorable `params` dict, so a record can
# later become one cloud object keyed by `id`. Mirrors Library.gd's versioned
# JSON + all-or-nothing validation.

const STORE_DIR: String = "user://edits"
const VERSION: int = 1


# md5 of the photo's decoded thumbnail bytes; stable across edit sessions
# because thumbnails render neutral/as-shot (no set_* calls), so applying edits
# never changes it. Survives file moves/renames.
static func thumb_hash(img: Image) -> String:
	if img == null:
		return ""
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(img.get_data())
	return ctx.finish().hex_encode()


# Composite identity: file name (not full path) + thumbnail content hash. The
# hash disambiguates same-named files; the name keeps records human-traceable.
static func edit_key(file_name: String, hash: String) -> String:
	return ("%s|%s" % [file_name, hash]).md5_text()


static func store_path(key: String) -> String:
	return "%s/%s/%s.json" % [STORE_DIR, key.substr(0, 2), key]


# True when a saved edit record exists for this (file_name, thumb_hash). Used by
# the Library grid to flag edited photos without reading the record.
static func has_record(file_name: String, hash: String) -> bool:
	if hash == "":
		return false
	return FileAccess.file_exists(store_path(edit_key(file_name, hash)))


# Serializes a live _params dict into JSON-native types (PackedVector2Array and
# Rect2 have no JSON representation; everything else is a plain float).
static func _params_to_json(params: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in params:
		var value: Variant = params[key]
		if value is PackedVector2Array:
			var pts: Array = []
			for p in (value as PackedVector2Array):
				pts.append([p.x, p.y])
			out[key] = pts
		elif value is Rect2:
			var r: Rect2 = value
			out[key] = [r.position.x, r.position.y, r.size.x, r.size.y]
		else:
			out[key] = value
	return out


# Inverse of _params_to_json: rebuilds PackedVector2Array / Rect2 for the two
# keys that need it; passes floats through. Returns {} if the shape is wrong.
static func _params_from_json(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var src: Dictionary = raw
	var out: Dictionary = {}
	for key in src:
		var value: Variant = src[key]
		if key == "tonecurve":
			if not (value is Array):
				return {}
			var pts: PackedVector2Array = PackedVector2Array()
			for p in (value as Array):
				if not (p is Array) or (p as Array).size() != 2:
					return {}
				pts.append(Vector2(float(p[0]), float(p[1])))
			out[key] = pts
		elif key == "crop":
			if not (value is Array) or (value as Array).size() != 4:
				return {}
			var a: Array = value
			out[key] = Rect2(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
		else:
			out[key] = value
	return out


# Writes the record atomically: a full write to <path>.tmp followed by a rename
# over the real path, so a crash mid-write cannot corrupt an existing record.
# `meta` carries file_name / thumb_hash / updated_at. Returns false on any I/O
# failure.
static func save(key: String, params: Dictionary, meta: Dictionary) -> bool:
	var payload: Dictionary = {
		"version": VERSION,
		"id": key,
		"file_name": meta.get("file_name", ""),
		"thumb_hash": meta.get("thumb_hash", ""),
		"updated_at": meta.get("updated_at", 0),
		"params": _params_to_json(params),
	}
	var text: String = JSON.stringify(payload, "\t")

	var out_path: String = store_path(key)
	var shard_dir: String = out_path.get_base_dir()
	var err: int = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shard_dir))
	if err != OK and err != ERR_ALREADY_EXISTS:
		return false

	var tmp_path: String = out_path + ".tmp"
	var file: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()

	err = DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path),
		ProjectSettings.globalize_path(out_path))
	if err != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return false
	return true


# Returns the restorable params dict (PackedVector2Array/Rect2 reconstructed),
# or {} on missing file, malformed JSON, version mismatch, or bad param shape.
static func load(key: String) -> Dictionary:
	var path: String = store_path(key)
	if not FileAccess.file_exists(path):
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {}
	var data: Dictionary = parsed
	if int(data.get("version", -1)) != VERSION:
		return {}
	if not data.has("params"):
		return {}
	return _params_from_json(data["params"])
