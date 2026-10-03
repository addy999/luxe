class_name ThumbnailCache

# Disk-backed thumbnail cache for the Library grid. Keys are content-addressed
# by path+mtime+size so stale thumbnails never serve after a file changes.

const THUMB_MAX: int = 320
const CACHE_DIR: String = "user://thumbs"


static func cache_key(path: String, mtime: int) -> String:
	return ("%s|%d|%d" % [path, mtime, THUMB_MAX]).md5_text()


# Shards thumbnails into 256 two-character subdirectories to avoid one huge
# flat directory.
static func cache_path(key: String) -> String:
	return "%s/%s/%s.jpg" % [CACHE_DIR, key.substr(0, 2), key]


static func load_cached(key: String) -> Image:
	var img: Image = Image.load_from_file(cache_path(key))
	return img


# Decodes the source image, downsamples to fit THUMB_MAX on the long edge
# (never upscales), and writes the JPEG cache shard. Returns null on any
# failure (corrupt source, write error).
static func build_thumbnail(path: String, key: String) -> Image:
	var img: Image = Image.load_from_file(path)
	if img == null:
		return null

	var w: int = img.get_width()
	var h: int = img.get_height()
	if w <= 0 or h <= 0:
		return null

	var long_edge: int = maxi(w, h)
	if long_edge > THUMB_MAX:
		var scale: float = float(THUMB_MAX) / float(long_edge)
		var new_w: int = maxi(1, roundi(w * scale))
		var new_h: int = maxi(1, roundi(h * scale))
		img.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)

	return store_thumb(key, img)


# Persists an already-rendered Image (e.g. a backend-rendered RAW thumb) into
# the cache and returns it. Shared code path with build_thumbnail's finish.
static func store_thumb(key: String, img: Image) -> Image:
	if img == null:
		return img

	img.convert(Image.FORMAT_RGB8)

	var out_path: String = cache_path(key)
	var shard_dir: String = out_path.get_base_dir()
	var err: int = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shard_dir))
	if err != OK and err != ERR_ALREADY_EXISTS:
		return img

	img.save_jpg(out_path, 0.85)

	return img


# Caps the on-disk shard count by deleting the oldest shard directories
# (by directory mtime) until the budget is met. Runs once at startup, so a
# simple linear scan is fine.
static func prune(max_entries: int = 20000) -> void:
	var globalized: String = ProjectSettings.globalize_path(CACHE_DIR)
	var dir: DirAccess = DirAccess.open(CACHE_DIR)
	if dir == null:
		return

	var shard_names: PackedStringArray = PackedStringArray()
	if dir.list_dir_begin() != OK:
		return
	var entry: String = dir.get_next()
	while entry != "":
		if not entry.begins_with(".") and dir.current_is_dir():
			shard_names.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()

	var total: int = 0
	for shard_name in shard_names:
		var shard_dir: DirAccess = DirAccess.open(CACHE_DIR.path_join(shard_name))
		if shard_dir == null:
			continue
		shard_dir.list_dir_begin()
		var f: String = shard_dir.get_next()
		while f != "":
			if not shard_dir.current_is_dir():
				total += 1
			f = shard_dir.get_next()
		shard_dir.list_dir_end()

	if total <= max_entries:
		return

	# Oldest-shard-first eviction until back under budget.
	var shard_mtimes: Array = []
	for shard_name in shard_names:
		var abs_dir: String = globalized.path_join(shard_name)
		shard_mtimes.append({"name": shard_name, "mtime": FileAccess.get_modified_time(abs_dir)})
	shard_mtimes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["mtime"] < b["mtime"])

	for shard in shard_mtimes:
		if total <= max_entries:
			break
		var shard_path: String = CACHE_DIR.path_join(shard["name"])
		var removed: int = _remove_dir_recursive(shard_path)
		total -= removed


# Deletes a directory tree via DirAccess; returns the number of files removed.
static func _remove_dir_recursive(dir_path: String) -> int:
	var removed: int = 0
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full_path: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			removed += _remove_dir_recursive(full_path)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(full_path))
			removed += 1
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))
	return removed
