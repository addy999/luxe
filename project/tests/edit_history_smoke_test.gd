extends SceneTree

# EditStore pure-logic smoke test: params round-trip (incl. PackedVector2Array
# tonecurve + Rect2 crop), key stability/collision, atomic write survives a
# stray .tmp, and all-or-nothing load rejection (missing / malformed / version
# mismatch / bad param shape). No backend, no fixtures, no arguments.
# Run: Godot --headless --path godot-poc/project --script res://tests/edit_history_smoke_test.gd

const TEST_DIR: String = "user://edits"


func _die(msg: String) -> void:
	printerr("EDIT_HISTORY_SMOKE: FAIL: " + msg)
	quit(1)


func _initialize() -> void:
	_cleanup()
	_test_round_trip()
	_test_key_stability()
	_test_atomic_write()
	_test_rejections()
	_cleanup()
	print("EDIT_HISTORY_SMOKE: PASS")
	quit(0)


func _sample_params() -> Dictionary:
	return {
		"exposure": 1.25,
		"contrast": -0.5,
		"highlights": -72.0,
		"shadows": 80.0,
		"blacks": -0.3,
		"whites": 0.4,
		"dehaze": 0.2,
		"saturation": 60.0,
		"desaturation": 0.0,
		"vibrance": 40.0,
		"tonecurve": PackedVector2Array([Vector2(0.0, 0.1), Vector2(0.5, 0.6), Vector2(1.0, 0.9)]),
		"wb_temperature": 5200.0,
		"crop": Rect2(0.1, 0.2, 0.7, 0.6),
	}


func _test_round_trip() -> void:
	var key: String = EditStore.edit_key("IMG_1234.CR2", "deadbeef")
	var params: Dictionary = _sample_params()
	var meta: Dictionary = {"file_name": "IMG_1234.CR2", "thumb_hash": "deadbeef", "updated_at": 1739000000}
	if not EditStore.save(key, params, meta):
		_die("save returned false")
		return
	if not FileAccess.file_exists(EditStore.store_path(key)):
		_die("record file missing after save: %s" % EditStore.store_path(key))
		return

	var loaded: Dictionary = EditStore.load(key)
	if loaded.is_empty():
		_die("load returned empty after save")
		return
	# Scalar keys.
	for k in ["exposure", "contrast", "highlights", "shadows", "blacks", "whites",
			"dehaze", "saturation", "desaturation", "vibrance", "wb_temperature"]:
		if not is_equal_approx(float(loaded[k]), float(params[k])):
			_die("key %s round-trip mismatch: %s vs %s" % [k, loaded[k], params[k]])
			return
	# tonecurve (PackedVector2Array).
	var curve: PackedVector2Array = loaded["tonecurve"]
	var want_curve: PackedVector2Array = params["tonecurve"]
	if curve.size() != want_curve.size():
		_die("tonecurve size mismatch: %d vs %d" % [curve.size(), want_curve.size()])
		return
	for i in curve.size():
		if not curve[i].is_equal_approx(want_curve[i]):
			_die("tonecurve point %d mismatch: %s vs %s" % [i, curve[i], want_curve[i]])
			return
	# crop (Rect2).
	var crop: Rect2 = loaded["crop"]
	if not crop.is_equal_approx(params["crop"]):
		_die("crop round-trip mismatch: %s vs %s" % [crop, params["crop"]])
		return
	print("EDIT_HISTORY_SMOKE: round-trip OK")


func _test_key_stability() -> void:
	var a: String = EditStore.edit_key("IMG.CR2", "hash_a")
	var a2: String = EditStore.edit_key("IMG.CR2", "hash_a")
	if a != a2:
		_die("edit_key not stable for identical inputs")
		return
	var b: String = EditStore.edit_key("IMG.CR2", "hash_b")
	if a == b:
		_die("edit_key collided across different thumb hashes")
		return
	var c: String = EditStore.edit_key("OTHER.CR2", "hash_a")
	if a == c:
		_die("edit_key collided across different file names")
		return

	# thumb_hash distinguishes different image bytes, matches identical bytes.
	var img1: Image = Image.create(8, 8, false, Image.FORMAT_RGB8)
	img1.fill(Color(0.2, 0.4, 0.6))
	var img2: Image = Image.create(8, 8, false, Image.FORMAT_RGB8)
	img2.fill(Color(0.2, 0.4, 0.6))
	var img3: Image = Image.create(8, 8, false, Image.FORMAT_RGB8)
	img3.fill(Color(0.9, 0.1, 0.1))
	if EditStore.thumb_hash(img1) != EditStore.thumb_hash(img2):
		_die("thumb_hash differs for identical bytes")
		return
	if EditStore.thumb_hash(img1) == EditStore.thumb_hash(img3):
		_die("thumb_hash collided for different bytes")
		return
	print("EDIT_HISTORY_SMOKE: key stability OK")


func _test_atomic_write() -> void:
	var key: String = EditStore.edit_key("ATOMIC.CR2", "x")
	var meta: Dictionary = {"file_name": "ATOMIC.CR2", "thumb_hash": "x", "updated_at": 1}
	if not EditStore.save(key, _sample_params(), meta):
		_die("atomic: initial save failed")
		return
	# A stray .tmp (crash mid-write) must not affect the committed record.
	var tmp: FileAccess = FileAccess.open(EditStore.store_path(key) + ".tmp", FileAccess.WRITE)
	if tmp == null:
		_die("atomic: could not create stray .tmp")
		return
	tmp.store_string("garbage")
	tmp.close()
	var loaded: Dictionary = EditStore.load(key)
	if loaded.is_empty():
		_die("atomic: committed record unreadable with stray .tmp present")
		return
	# A second save overwrites cleanly despite the stray tmp.
	if not EditStore.save(key, _sample_params(), meta):
		_die("atomic: re-save failed with stray .tmp present")
		return
	print("EDIT_HISTORY_SMOKE: atomic write OK")


func _test_rejections() -> void:
	# Missing record.
	if not EditStore.load(EditStore.edit_key("NOPE.CR2", "nope")).is_empty():
		_die("load of missing record returned non-empty")
		return

	# Malformed JSON.
	var bad_key: String = EditStore.edit_key("BAD.CR2", "bad")
	_write_raw(bad_key, "not json at all")
	if not EditStore.load(bad_key).is_empty():
		_die("load of malformed JSON returned non-empty")
		return

	# Version mismatch.
	var ver_key: String = EditStore.edit_key("VER.CR2", "ver")
	_write_raw(ver_key, JSON.stringify({"version": 999, "params": {"exposure": 1.0}}))
	if not EditStore.load(ver_key).is_empty():
		_die("load of version-mismatched record returned non-empty")
		return

	# Bad param shape (tonecurve not an array of pairs).
	var shape_key: String = EditStore.edit_key("SHAPE.CR2", "shape")
	_write_raw(shape_key, JSON.stringify({
		"version": EditStore.VERSION,
		"params": {"tonecurve": "oops"},
	}))
	if not EditStore.load(shape_key).is_empty():
		_die("load of bad param shape returned non-empty")
		return
	print("EDIT_HISTORY_SMOKE: rejections OK")


func _write_raw(key: String, text: String) -> void:
	var path: String = EditStore.store_path(key)
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path.get_base_dir()))
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_die("could not write raw record %s" % path)
		return
	f.store_string(text)
	f.close()


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
	_remove_dir_recursive(TEST_DIR)
