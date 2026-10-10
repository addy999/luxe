extends SceneTree

# Library pure-logic smoke test: extension filtering, directory scan (recursive
# + non-recursive), grid cursor math, thumbnail build/cache round-trip, and
# location persistence round-trip. No backend, no fixtures, no arguments.
# Run: Godot --headless --path godot-poc/project --script res://tests/library_smoke_test.gd

const TEST_ROOT: String = "user://test_library"
const TEST_JSON: String = "user://library_locations_test.json"
const TEST_THUMB: String = "user://thumbs"


func _die(msg: String) -> void:
	printerr("LIBRARY_SMOKE: FAIL: " + msg)
	quit(1)


func _initialize() -> void:
	_test_filtering()
	_test_scan()
	_test_next_index()
	_test_thumbnails()
	_test_persistence()
	_test_zoom_snap()
	_cleanup()
	print("LIBRARY_SMOKE: PASS")
	quit(0)


func _test_filtering() -> void:
	var supported: Array[String] = ["A.JPG", "b.jpeg", "c.PNG", "d.Cr2", "e.NEF", "f.arw", "g.DNG"]
	for name in supported:
		if not Library.is_supported(name):
			_die("is_supported(%s) should be true" % name)
			return
	var unsupported: Array[String] = ["h.txt", "i.psd", "j.tiff", "k", ".DS_Store"]
	for name in unsupported:
		if Library.is_supported(name):
			_die("is_supported(%s) should be false" % name)
			return
	var raw_true: Array[String] = ["d.Cr2", "e.NEF", "f.arw", "g.DNG"]
	for name in raw_true:
		if not Library.is_raw(name):
			_die("is_raw(%s) should be true" % name)
			return
	var raw_false: Array[String] = ["A.JPG", "b.jpeg", "c.PNG", "h.txt", "k", ".DS_Store"]
	for name in raw_false:
		if Library.is_raw(name):
			_die("is_raw(%s) should be false" % name)
			return
	print("LIBRARY_SMOKE: filtering OK")


func _make_solid_jpg(path: String, w: int, h: int) -> void:
	var img: Image = Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(Color(0.8, 0.1, 0.1))
	var err: int = img.save_jpg(path)
	if err != OK:
		_die("failed to write fixture jpg %s (err %d)" % [path, err])


func _write_zero_file(path: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_die("failed to write zero-byte file %s" % path)
	f.close()


func _test_scan() -> void:
	var root: String = ProjectSettings.globalize_path(TEST_ROOT)
	DirAccess.make_dir_recursive_absolute(root)
	DirAccess.make_dir_recursive_absolute(root.path_join("nested"))
	_make_solid_jpg("%s/a.jpg" % root, 64, 48)
	_make_solid_jpg("%s/B.PNG" % root, 32, 32)
	_write_zero_file("%s/c.ARW" % root)
	_write_zero_file("%s/d.txt" % root)
	_make_solid_jpg("%s/nested/e.jpeg" % root, 16, 16)
	_make_solid_jpg("%s/.hidden.jpg" % root, 8, 8)

	var rec: Array[Dictionary] = Library.scan_location(root, true)
	if rec.size() != 4:
		_die("recursive scan found %d entries, expected 4" % rec.size())
		return
	var flat: Array[Dictionary] = Library.scan_location(root, false)
	if flat.size() != 3:
		_die("non-recursive scan found %d entries, expected 3" % flat.size())
		return

	# Case-insensitive name order: a.jpg, B.PNG, c.ARW, e.jpeg.
	var expected: Array[String] = ["a.jpg", "B.PNG", "c.ARW", "e.jpeg"]
	for i in rec.size():
		if rec[i]["name"] != expected[i]:
			_die("scan order wrong at %d: got %s, expected %s" % [i, rec[i]["name"], expected[i]])
			return
		if not (rec[i]["path"] as String).is_absolute_path():
			_die("scan path not absolute: %s" % rec[i]["path"])
			return
		if rec[i]["mtime"] <= 0:
			_die("mtime not populated for %s" % rec[i]["name"])
			return
	var raw_hits: int = 0
	for entry in rec:
		if entry["is_raw"]:
			raw_hits += 1
			if entry["name"] != "c.ARW":
				_die("is_raw true on unexpected entry %s" % entry["name"])
				return
	if raw_hits != 1:
		_die("is_raw true on %d entries, expected 1" % raw_hits)
		return
	print("LIBRARY_SMOKE: scan OK (%d recursive / %d flat)" % [rec.size(), flat.size()])


func _check_next(index: int, dx: int, dy: int, cols: int, count: int, want: int) -> bool:
	var got: int = Library.next_index(index, dx, dy, cols, count)
	if got != want:
		_die("next_index(%d, %d, %d, %d, %d) = %d, expected %d" % [index, dx, dy, cols, count, got, want])
		return false
	return true


func _test_next_index() -> void:
	# count=7, cols=3 (rows 0-1 full, row 2 short with 1 item).
	if not _check_next(0, 1, 0, 3, 7, 1):
		return
	if not _check_next(2, 1, 0, 3, 7, 3):
		return
	# 4 is on row 1; down lands past the end on the short row 2 -> last item.
	if not _check_next(4, 0, 1, 3, 7, 6):
		return
	# 6 is already the last item; down keeps it.
	if not _check_next(6, 0, 1, 3, 7, 6):
		return
	# 1 on row 0; up would be row -1, out of range -> stays.
	if not _check_next(1, 0, -1, 3, 7, 1):
		return
	# No selection; any move selects the first item.
	if not _check_next(-1, 1, 0, 3, 7, 0):
		return
	# Empty grid -> -1.
	if not _check_next(0, 1, 0, 3, 0, -1):
		return
	print("LIBRARY_SMOKE: next_index OK")


func _bump_mtime(path: String, old_mtime: int) -> int:
	# Rewrite the file until the filesystem reports a different mtime
	# (second-granularity filesystems need a wait between writes).
	for i in 10:
		var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_8(i + 1)
			f.close()
		var mtime: int = FileAccess.get_modified_time(path)
		if mtime != old_mtime:
			return mtime
		OS.delay_msec(1200)
	return old_mtime


func _test_thumbnails() -> void:
	var root: String = ProjectSettings.globalize_path(TEST_ROOT)

	var small_path: String = "%s/a.jpg" % root
	var small_mtime: int = FileAccess.get_modified_time(small_path)
	var small_key: String = ThumbnailCache.cache_key(small_path, small_mtime)
	var small: Image = ThumbnailCache.build_thumbnail(small_path, small_key)
	if small == null:
		_die("build_thumbnail returned null for 64x48 jpg")
		return
	if small.get_width() != 64 or small.get_height() != 48:
		_die("small thumb upscaled/resized: %dx%d" % [small.get_width(), small.get_height()])
		return

	var big_path: String = "%s/big.jpg" % root
	_make_solid_jpg(big_path, 1024, 768)
	var big_mtime: int = FileAccess.get_modified_time(big_path)
	var big_key: String = ThumbnailCache.cache_key(big_path, big_mtime)
	var big: Image = ThumbnailCache.build_thumbnail(big_path, big_key)
	if big == null:
		_die("build_thumbnail returned null for 1024x768 jpg")
		return
	if maxi(big.get_width(), big.get_height()) != ThumbnailCache.THUMB_MAX:
		_die("big thumb long edge %d, expected %d" % [maxi(big.get_width(), big.get_height()), ThumbnailCache.THUMB_MAX])
		return

	if not FileAccess.file_exists(ThumbnailCache.cache_path(big_key)):
		_die("cache shard missing for big thumb: %s" % ThumbnailCache.cache_path(big_key))
		return
	var cached: Image = ThumbnailCache.load_cached(big_key)
	if cached == null:
		_die("load_cached miss after build")
		return
	if cached.get_width() != big.get_width() or cached.get_height() != big.get_height():
		_die("cached thumb dims %dx%d != built %dx%d" % [cached.get_width(), cached.get_height(), big.get_width(), big.get_height()])
		return
	var miss: Image = ThumbnailCache.load_cached(ThumbnailCache.cache_key(big_path, 12345))
	if miss != null:
		_die("load_cached hit on a fabricated key")
		return

	var new_mtime: int = _bump_mtime(big_path, big_mtime)
	if new_mtime == big_mtime:
		_die("could not mutate mtime for cache_key change check")
		return
	if ThumbnailCache.cache_key(big_path, new_mtime) == big_key:
		_die("cache_key identical after mtime change")
		return
	print("LIBRARY_SMOKE: thumbnails OK")


func _test_persistence() -> void:
	var saved: PackedStringArray = PackedStringArray(["/Users/x/pics", "/Volumes/Ext/RAW"])
	if not Library.save_locations(saved, TEST_JSON):
		_die("save_locations failed")
		return
	var loaded: PackedStringArray = Library.load_locations(TEST_JSON)
	if loaded != saved:
		_die("load_locations round-trip mismatch: %s vs %s" % [str(loaded), str(saved)])
		return

	var f: FileAccess = FileAccess.open(TEST_JSON, FileAccess.WRITE)
	if f == null:
		_die("failed to write garbage json")
		return
	f.store_string("not json")
	f.close()
	var garbage: PackedStringArray = Library.load_locations(TEST_JSON)
	if garbage.size() != 0:
		_die("load_locations on garbage returned %d entries, expected 0" % garbage.size())
		return
	print("LIBRARY_SMOKE: persistence OK")


func _test_zoom_snap() -> void:
	var tile_w: float = LibraryItem.TILE_SIZE.x
	var sep: float = float(LibraryItem.GROUP_SEP)
	# avail_w is the layout width plus one separator (see _relayout).
	for viewport_w in [1000.0, 1234.0, 3550.0]:
		var avail_w: float = viewport_w + sep
		var scale: float = LibraryView.snap_scale(1.0, avail_w)
		# Snapped scale must fill the row exactly: floor/round of the width
		# ratio is an integer column count whose cells tile the full width.
		var cols: int = int(round(avail_w / (tile_w * scale + sep)))
		var filled: float = cols * tile_w * scale + (cols - 1) * sep
		if absf(filled - viewport_w) > 0.5:
			_die("snap_scale(%s) leaves a gap: %d cols fill %.2f of %.2f" % [viewport_w, cols, filled, viewport_w])
			return
		# Out-of-range requests clamp to the nearest in-range snapped level.
		var lo: float = LibraryView.snap_scale(0.01, avail_w)
		var hi: float = LibraryView.snap_scale(99.0, avail_w)
		if lo < 0.5 or hi > 4.0:
			_die("snap_scale out of clamp range: lo %.3f hi %.3f" % [lo, hi])
			return
		if not is_equal_approx(lo, LibraryView.snap_scale(lo, avail_w)):
			_die("snap_scale not idempotent at lo %.3f" % lo)
			return
	print("LIBRARY_SMOKE: zoom snap OK")

func _remove_dir_recursive(dir_path: String) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full_path: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				_remove_dir_recursive(full_path)
			else:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(full_path))
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))


func _cleanup() -> void:
	_remove_dir_recursive(TEST_ROOT)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_JSON))
	_remove_dir_recursive(TEST_THUMB)
	print("LIBRARY_SMOKE: cleanup OK")
