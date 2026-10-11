extends SceneTree

# RejectStore pure-logic smoke test: set round-trip, key reuse against
# EditStore.edit_key, toggle on/off, all-or-nothing load rejection (missing /
# malformed / version mismatch / bad shape / non-String element), and atomic
# write surviving a stray .tmp. All calls go to a redirected test path so the
# real user://rejects.json is never touched. No backend, no fixtures, no args.
# Run: Godot --headless --path godot-poc/project --script res://tests/reject_smoke_test.gd

const TEST_PATH: String = "user://rejects_test.json"


func _die(msg: String) -> void:
	printerr("REJECT_SMOKE: FAIL: " + msg)
	quit(1)


func _initialize() -> void:
	_cleanup()
	_test_round_trip()
	_test_key_reuse()
	_test_toggle()
	_test_rejections()
	_test_atomic_leftover_tmp()
	_cleanup()
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
