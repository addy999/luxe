extends SceneTree

# RejectStore pure-logic smoke test: set round-trip, key reuse against
# EditStore.edit_key, toggle on/off, all-or-nothing load rejection (missing /
# malformed / version mismatch / bad shape / non-String element), and atomic
# write surviving a stray .tmp. All calls go to a redirected test path so the
# real user://rejects.json is never touched. No backend, no fixtures, no args.
# Run: Godot --headless --path godot-poc/project --script res://tests/reject_smoke_test.gd

const TEST_PATH: String = "user://rejects_test.json"


# quit() is deferred: _initialize keeps running after a _die, so a later
# quit(0) would override the failure exit code and still print PASS. The flag
# makes the first failure stick.
var _failed: bool = false


func _die(msg: String) -> void:
	printerr("REJECT_SMOKE: FAIL: " + msg)
	_failed = true
	quit(1)


func _initialize() -> void:
	_cleanup()
	_test_round_trip()
	_test_key_reuse()
	_test_toggle()
	_test_rejections()
	_test_atomic_leftover_tmp()
	await _test_lazy_resolve_hides()
	_cleanup()
	if _failed:
		return
	print("REJECT_SMOKE: PASS")
	quit(0)


func _test_round_trip() -> void:
	if not RejectStore.save_set({"aaa": true, "bbb": true, "ccc": true}, TEST_PATH):
		_die("save_set returned false")
		return
	var loaded: Dictionary = RejectStore.load_set(TEST_PATH)
	for k in ["aaa", "bbb", "ccc"]:
		if not loaded.has(k):
			_die("loaded set missing key %s" % k)
			return
	if loaded.has("zzz"):
		_die("loaded set contains uninvited key zzz")
		return
	print("REJECT_SMOKE: round-trip OK")


func _test_key_reuse() -> void:
	var rk: String = RejectStore.reject_key("DSC_0001.ARW", "deadbeef")
	var ek: String = EditStore.edit_key("DSC_0001.ARW", "deadbeef")
	if rk != ek:
		_die("reject_key %s != edit_key %s for identical inputs" % [rk, ek])
		return
	print("REJECT_SMOKE: key-reuse OK")


func _test_toggle() -> void:
	# Start from a genuinely empty store.
	if not RejectStore.save_set({}, TEST_PATH):
		_die("toggle: initial empty save failed")
		return
	if not RejectStore.load_set(TEST_PATH).is_empty():
		_die("toggle: set non-empty after empty save")
		return

	# Toggle on.
	var on: Dictionary = RejectStore.load_set(TEST_PATH)
	var key: String = RejectStore.reject_key("TOGGLE.ARW", "togglehash")
	on[key] = true
	if not RejectStore.save_set(on, TEST_PATH):
		_die("toggle: save after adding key failed")
		return
	if not RejectStore.load_set(TEST_PATH).has(key):
		_die("toggle: key absent after toggle-on")
		return

	# Toggle off.
	var off: Dictionary = RejectStore.load_set(TEST_PATH)
	off.erase(key)
	if not RejectStore.save_set(off, TEST_PATH):
		_die("toggle: save after erasing key failed")
		return
	var final_set: Dictionary = RejectStore.load_set(TEST_PATH)
	if final_set.has(key):
		_die("toggle: key still present after toggle-off")
		return
	if not final_set.is_empty():
		_die("toggle: set non-empty after toggling the only key off")
		return
	print("REJECT_SMOKE: toggle OK")


func _test_rejections() -> void:
	# Missing file.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	if not RejectStore.load_set(TEST_PATH).is_empty():
		_die("load_set of missing file returned non-empty")
		return

	# Malformed JSON.
	_write_raw(TEST_PATH, "not json at all")
	if not RejectStore.load_set(TEST_PATH).is_empty():
		_die("load_set of malformed JSON returned non-empty")
		return

	# Version mismatch.
	_write_raw(TEST_PATH, '{"version": 999, "keys": ["x"]}')
	if not RejectStore.load_set(TEST_PATH).is_empty():
		_die("load_set of version-mismatched file returned non-empty")
		return

	# Bad shape (keys not an array).
	_write_raw(TEST_PATH, '{"version": 1, "keys": "nope"}')
	if not RejectStore.load_set(TEST_PATH).is_empty():
		_die("load_set of non-array keys returned non-empty")
		return

	# Non-String element.
	_write_raw(TEST_PATH, '{"version": 1, "keys": ["ok", 5]}')
	if not RejectStore.load_set(TEST_PATH).is_empty():
		_die("load_set of non-String key element returned non-empty")
		return
	print("REJECT_SMOKE: rejections OK")


func _test_atomic_leftover_tmp() -> void:
	# A stray .tmp (crash mid-write) must not corrupt the committed set.
	_write_raw(TEST_PATH + ".tmp", "garbage")
	if not RejectStore.save_set({"kkk": true}, TEST_PATH):
		_die("atomic: save failed with stray .tmp present")
		return
	var loaded: Dictionary = RejectStore.load_set(TEST_PATH)
	if not loaded.has("kkk"):
		_die("atomic: committed set missing key with stray .tmp present")
		return
	print("REJECT_SMOKE: atomic-leftover-tmp OK")


# Regression: the rejected flag is resolved LAZILY (in _mark_edited, when a
# thumbnail becomes ready), long after the scan built the visible map. If that
# resolution does not rebuild the map, a photo whose reject flag is only
# discovered at thumb-ready stays visible in a hiding grid until some unrelated
# toggle rebuilds it. Drives the real LibraryView against on-disk fixtures.
func _test_lazy_resolve_hides() -> void:
	var dir: String = "user://test_reject_lazy"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var paths: Array[String] = []
	for i in range(3):
		var path: String = "%s/photo_%d.jpg" % [dir, i]
		var img: Image = Image.create(40, 30, false, Image.FORMAT_RGB8)
		img.fill(Color(0.1 * (i + 1), 0.4, 0.7))
		img.save_jpg(path)
		paths.append(ProjectSettings.globalize_path(path))

	var view: Node = load("res://LibraryView.tscn").instantiate()
	get_root().add_child(view)
	await process_frame

	# Persist a reject for photo_1 keyed the way the app keys it (on-disk thumb
	# hash), so the flag can only be discovered once that thumb is built.
	var photos: Array[Dictionary] = Library.scan_location(ProjectSettings.globalize_path(dir))
	if photos.size() != 3:
		_die("lazy-resolve: expected 3 fixture photos, got %d" % photos.size())
		return
	var target: Dictionary = photos[1]
	var key_name: String = (target["path"] as String).get_file()
	var cache_key: String = ThumbnailCache.cache_key(target["path"], target["mtime"])
	var thumb: Image = ThumbnailCache.build_thumbnail(target["path"], cache_key)
	if thumb == null:
		_die("lazy-resolve: could not build fixture thumbnail")
		return
	# Re-read from disk: the stored JPEG is the canonical hash input.
	var on_disk: Image = ThumbnailCache.load_cached(cache_key)
	var hash: String = EditStore.thumb_hash(on_disk)
	var rej_key: String = EditStore.edit_key(key_name, hash)

	view._reject_set = {rej_key: true}
	view._hide_rejected = true
	view._set_photos(photos)

	# Before any thumb resolves, the flag is unknown: all three are visible.
	if view.get_photo_count() != 3:
		_die("lazy-resolve: expected 3 visible before resolution, got %d" % view.get_photo_count())
		return

	# Thumb-ready for the rejected photo resolves its flag; the hiding grid
	# must drop it immediately.
	view._mark_edited(target)
	view._reapply_hide_filter()
	if view.get_photo_count() != 2:
		_die("lazy-resolve: rejected photo still visible after resolution (count %d)"
			% view.get_photo_count())
		return
	for vi in range(view.get_photo_count()):
		if view.filmstrip_path(vi) == target["path"]:
			_die("lazy-resolve: rejected path still present in the visible map")
			return
	print("REJECT_SMOKE: lazy-resolve-hides OK")


func _write_raw(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_die("could not write raw file %s" % path)
		return
	f.store_string(text)
	f.close()


func _cleanup() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + ".tmp"))
