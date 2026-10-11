extends SceneTree

# UiStateStore pure-logic smoke test: defaults on a fresh user://, round-trip
# of all three fields (zoom float / hide bool / last photo string), per-field
# type fallback (one wrong-typed field doesn't sink the others), all-or-nothing
# rejections (missing / malformed / version mismatch / bad shape), and the
# atomic tmp+rename write surviving a stray .tmp. No backend, no fixtures,
# no arguments.
# Run: Godot --headless --path godot-poc/project --script res://tests/ui_state_smoke_test.gd

const TEST_PATH: String = "user://ui_state_test.json"


# quit() is deferred: _initialize keeps running after a _die, so a later
# quit(0) would override the failure exit code and still print PASS. The flag
# makes the first failure stick.
var _failed: bool = false


func _die(msg: String) -> void:
	printerr("UI_STATE_SMOKE: FAIL: " + msg)
	_failed = true
	quit(1)


func _initialize() -> void:
	_cleanup()
	_test_defaults()
	_test_round_trip()
	_test_field_fallback()
	_test_rejections()
	_test_atomic_write()
	_cleanup()
	if _failed:
		return
	print("UI_STATE_SMOKE: PASS")
	quit(0)


func _test_defaults() -> void:
	var state: Dictionary = UiStateStore.load(TEST_PATH)
	if not is_equal_approx(float(state["library_zoom_pct"]), 100.0):
		_die("default library_zoom_pct is %s, want 100.0" % state["library_zoom_pct"])
		return
	if state["hide_rejected"] != false:
		_die("default hide_rejected is %s, want false" % state["hide_rejected"])
		return
	if state["last_photo"] != "":
		_die("default last_photo is '%s', want empty" % state["last_photo"])
		return
	print("UI_STATE_SMOKE: defaults OK")


func _test_round_trip() -> void:
	var state: Dictionary = {
		"library_zoom_pct": 173.5,
		"hide_rejected": true,
		"last_photo": "/photos/trip/IMG_1234.ARW",
	}
	if not UiStateStore.save(state, TEST_PATH):
		_die("save returned false")
		return
	var loaded: Dictionary = UiStateStore.load(TEST_PATH)
	if not is_equal_approx(float(loaded["library_zoom_pct"]), 173.5):
		_die("library_zoom_pct round-trip mismatch: %s vs 173.5" % loaded["library_zoom_pct"])
		return
	if loaded["hide_rejected"] != true:
		_die("hide_rejected round-trip mismatch: %s vs true" % loaded["hide_rejected"])
		return
	if loaded["last_photo"] != "/photos/trip/IMG_1234.ARW":
		_die("last_photo round-trip mismatch: '%s'" % loaded["last_photo"])
		return
	print("UI_STATE_SMOKE: round-trip OK")


func _test_field_fallback() -> void:
	# One wrong-typed field falls back to its default; the others survive.
	_write_raw(JSON.stringify({
		"version": UiStateStore.VERSION,
		"values": {
			"library_zoom_pct": "big",
			"hide_rejected": true,
			"last_photo": 42,
		},
	}))
	var loaded: Dictionary = UiStateStore.load(TEST_PATH)
	if not is_equal_approx(float(loaded["library_zoom_pct"]), 100.0):
		_die("wrong-typed library_zoom_pct not defaulted: %s" % loaded["library_zoom_pct"])
		return
	if loaded["hide_rejected"] != true:
		_die("valid hide_rejected lost to a sibling's bad type: %s" % loaded["hide_rejected"])
		return
	if loaded["last_photo"] != "":
		_die("wrong-typed last_photo not defaulted: '%s'" % loaded["last_photo"])
		return
	print("UI_STATE_SMOKE: field fallback OK")


func _test_rejections() -> void:
	# Malformed JSON.
	_write_raw("not json at all")
	if not _load_is_default("malformed JSON"):
		return
	# Version mismatch.
	_write_raw(JSON.stringify({"version": 999, "values": {"hide_rejected": true}}))
	if not _load_is_default("version mismatch"):
		return
	# Bad shape: values not a dict.
	_write_raw(JSON.stringify({"version": UiStateStore.VERSION, "values": [1, 2]}))
	if not _load_is_default("bad shape (values not a dict)"):
		return
	print("UI_STATE_SMOKE: rejections OK")


func _test_atomic_write() -> void:
	var state: Dictionary = {"library_zoom_pct": 250.0, "hide_rejected": false, "last_photo": "/x.NEF"}
	if not UiStateStore.save(state, TEST_PATH):
		_die("atomic: initial save failed")
		return
	# A stray .tmp (crash mid-write) must not affect the committed state.
	var tmp: FileAccess = FileAccess.open(TEST_PATH + ".tmp", FileAccess.WRITE)
	if tmp == null:
		_die("atomic: could not create stray .tmp")
		return
	tmp.store_string("garbage")
	tmp.close()
	var loaded: Dictionary = UiStateStore.load(TEST_PATH)
	if not is_equal_approx(float(loaded["library_zoom_pct"]), 250.0):
		_die("atomic: committed state unreadable with stray .tmp present")
		return
	# A second save overwrites cleanly despite the stray tmp.
	if not UiStateStore.save(state, TEST_PATH):
		_die("atomic: re-save failed with stray .tmp present")
		return
	print("UI_STATE_SMOKE: atomic write OK")


# True (and dies) when a load returns defaults, i.e. the malformed input was
# rejected all-or-nothing.
func _load_is_default(what: String) -> bool:
	var state: Dictionary = UiStateStore.load(TEST_PATH)
	var defaults: Dictionary = UiStateStore.defaults()
	for key in defaults:
		var got: Variant = state[key]
		var want: Variant = defaults[key]
		var same: bool = true
		if got is float or got is int:
			same = is_equal_approx(float(got), float(want))
		else:
			same = got == want
		if not same:
			_die("load of %s returned non-default %s=%s" % [what, key, got])
			return false
	return true


func _write_raw(text: String) -> void:
	var f: FileAccess = FileAccess.open(TEST_PATH, FileAccess.WRITE)
	if f == null:
		_die("could not write raw state file %s" % TEST_PATH)
		return
	f.store_string(text)
	f.close()


func _cleanup() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	if FileAccess.file_exists(TEST_PATH + ".tmp"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + ".tmp"))
