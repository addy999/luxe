extends SceneTree

# Real-scene Color panel wiring test. Instantiates Main.tscn against the real
# DtBackend and drives the As Shot / Auto / Custom buttons and the four Color
# sliders through the same handlers a user triggers, then checks mode state,
# persistence (save, reopen, legacy record), Before/After, image switching and
# export exclusion. Backend-free pieces live in tests/unit/color_panel_smoke_test.gd.
#
# Run: Godot --headless --path godot-poc/project --script res://tests/feature/color_controls_smoke_test.gd -- <input_raw> [--allow-old-backend]
# (DT_BACKEND_DATADIR / DT_BACKEND_MODULEDIR exported, private HOME recommended;
# scripts/feature_smoke_tests.sh does both.) --allow-old-backend skips the
# checks that need compute_auto_white_balance / set_white_balance, for runs
# against a binary built before the backend change.

const ColorWb := preload("res://ColorWb.gd")
const MAX_WAIT_FRAMES: int = 1200
const SAMPLE_GRID: int = 10
const MAX_CHANNEL_DIFF: float = 0.004
const SECOND_IMAGE: String = "res://tests/fixtures/e2e_fixture.jpg"

var _failed: bool = false
var _main: Control = null
var _allow_old: bool = false


func _check(condition: bool, message: String) -> void:
	if not condition:
		printerr("COLOR_CONTROLS_SMOKE: FAIL: " + message)
		_failed = true


func _finish() -> void:
	if _failed:
		quit(1)
		return
	print("COLOR_CONTROLS_SMOKE: PASS")
	quit(0)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty() or not FileAccess.file_exists(args[0]):
		printerr("COLOR_CONTROLS_SMOKE: FAIL: usage: -- <input_raw> [--allow-old-backend]")
		quit(1)
		return
	var raw: String = args[0]
	_allow_old = args.has("--allow-old-backend")

	_main = (load("res://Main.tscn") as PackedScene).instantiate()
	get_root().add_child(_main)
	await process_frame
	await process_frame
	if _main.backend == null:
		printerr("COLOR_CONTROLS_SMOKE: FAIL: backend failed to initialize")
		quit(1)
		return

	var backend: Object = _main.backend
	var has_auto: bool = backend.has_method("compute_auto_white_balance")
	var has_combined: bool = backend.has_method("set_white_balance") \
			and backend.has_method("reset_white_balance") and backend.has_method("get_white_balance_tint")
	if not _allow_old:
		_check(has_auto and has_combined, "backend lacks the new white-balance API (use --allow-old-backend for an old binary)")
	else:
		has_auto = false

	# --- no photo yet: new controls are disabled -----------------------------
	for mode in ColorWb.MODES:
		_check(_main.wb_mode_bar.get_button(mode).disabled, "%s button disabled before a photo is open" % mode)
	_check(not _main.tint_slider.editable, "Tint disabled before a photo is open")
	_main._on_wb_mode_selected(ColorWb.AUTO)
	_check(_main._params["wb_mode"] == ColorWb.AS_SHOT and not _main._auto_wb_pending,
			"mode click with no photo is ignored")

	# --- open: As Shot with per-image defaults -------------------------------
	_check(_main.open_photo(raw), "open_photo(raw)")
	_check(await _idle(), "initial render")
	_check(_main._edit_key != "", "photo resolved an edit key (persistence checks need it)")
	var as_shot_k: float = _main._wb_default_temperature
	var as_shot_tint: float = _main._wb_default_tint
	_check(_main._params["wb_mode"] == ColorWb.AS_SHOT, "new photo starts As Shot")
	_check(_main.wb_mode_bar.current_mode == ColorWb.AS_SHOT, "bar shows As Shot")
	_check(_main._params["wb_temperature"] == as_shot_k and _main._params["wb_tint"] == as_shot_tint,
			"new photo uses as-shot temperature/tint")
	for mode in ColorWb.MODES:
		_check(not _main.wb_mode_bar.get_button(mode).disabled, "%s button enabled with a photo" % mode)
	_check(_main.tint_slider.editable, "Tint enabled with a photo")
	_check(_main._applied_params.get("wb_mode", "") == ColorWb.AS_SHOT, "As Shot applied through the single apply entry")
	var baseline: Image = _main._last_render_image.duplicate()

	# --- Auto then As Shot returns to the as-shot baseline -------------------
	if has_auto:
		_press(ColorWb.AUTO)
		_check(await _idle(), "render after Auto")
		_check(_main._params["wb_mode"] == ColorWb.AUTO and not _main._auto_wb_pending, "Auto resolved")
		_check(_main._applied_params["wb_temperature"] == _main._params["wb_temperature"]
				and _main._applied_params["wb_tint"] == _main._params["wb_tint"], "Auto values applied to the backend")
		_check(_main.white_balance_slider.value >= _main.white_balance_slider.min_value
				and _main.white_balance_slider.value <= _main.white_balance_slider.max_value, "Auto temperature within slider range")
		var first_k: float = _main._params["wb_temperature"]
		var first_tint: float = _main._params["wb_tint"]
		_press(ColorWb.AUTO)
		_check(await _idle(), "render after repeated Auto")
		_check(is_equal_approx(_main._params["wb_temperature"], first_k) and is_equal_approx(_main._params["wb_tint"], first_tint),
				"Auto is repeatable")
	_press(ColorWb.CUSTOM)
	_press(ColorWb.AS_SHOT)
	_check(await _idle(), "render after As Shot")
	_check(_main._params["wb_temperature"] == as_shot_k and _main._params["wb_tint"] == as_shot_tint,
			"As Shot restores as-shot temperature/tint")
	var worst: float = _worst_diff(baseline, _main._last_render_image)
	_check(worst <= MAX_CHANNEL_DIFF, "As Shot after Auto/Custom matches the first render (worst %.4f)" % worst)

	# --- non-color edits leave the mode alone --------------------------------
	for edit in [["exposure_slider", 0.4], ["contrast_slider", 0.2], ["dehaze_slider", 0.3],
			["highlights_slider", -10.0], ["shadows_slider", 10.0], ["whites_slider", 0.2], ["blacks_slider", -0.2]]:
		(_main.get(edit[0]) as HSlider).value = edit[1]
		_check(_main._params["wb_mode"] == ColorWb.AS_SHOT, "%s must not change the WB mode" % edit[0])
	_main.tone_curve_editor.curve_changed.emit(PackedVector2Array([
		Vector2(0, 0), Vector2(0.3, 0.2), Vector2(1, 1)]))
	_check(_main._params["wb_mode"] == ColorWb.AS_SHOT, "tone curve must not change the WB mode")
	_check(await _idle(), "render after unrelated edits")
	_check(_main._params["wb_temperature"] == as_shot_k and _main._params["wb_tint"] == as_shot_tint,
			"unrelated edits keep white balance values")

	# --- Custom selected / Vibrance-only edit keeps the exact as-shot pipe ----
	_check(_main._wb_backend_key == "neutral", "As Shot photo holds the neutral backend state")
	_press(ColorWb.CUSTOM)
	_main.vibrance_slider.value = _main.vibrance_slider.value + 7.0
	_main.exposure_slider.value = _main.exposure_slider.value + 0.1
	_check(await _idle(), "render after Custom + Vibrance/Exposure edits")
	_check(_main._params["wb_temperature"] == as_shot_k and _main._params["wb_tint"] == as_shot_tint,
			"Custom + Vibrance edit keeps the as-shot Temp/Tint")
	_check(_main._wb_backend_key == "neutral", "Custom + Vibrance edit never re-pushes a computed correction")
	_check(_main._params["wb_override"] == false and _main._params["wb_mode"] == ColorWb.CUSTOM,
			"Custom + Vibrance edit selects Custom and leaves wb_override false")
	_check(_main.vibrance_value_label.text.begins_with("+"), "non-zero Vibrance readout is signed")
	# ...and that survives a save and reopen: still Custom, still the exact as-shot state.
	_main._flush_pending_save()
	_check(_main.open_photo(raw), "reopen after Custom + Vibrance")
	_check(await _idle(), "render after reopen (Custom + Vibrance)")
	_check(_main._params["wb_mode"] == ColorWb.CUSTOM and _main._params["wb_override"] == false,
			"Custom without override restored on reopen")
	_check(_main._params["wb_temperature"] == as_shot_k and _main._params["wb_tint"] == as_shot_tint, "reopen keeps as-shot Temp/Tint")
	_check(_main._wb_backend_key == "neutral", "reopened Custom + Vibrance photo renders the exact as-shot state")
	_check(_main.wb_mode_bar.current_mode == ColorWb.CUSTOM, "bar shows Custom after reopen")

	# --- every Color slider switches Custom, from every mode -----------------
	var sliders: Dictionary = {
		"temp": _main.white_balance_slider, "tint": _main.tint_slider,
		"vibrance": _main.vibrance_slider, "saturation": _main.saturation_slider,
	}
	var start_modes: Array = [ColorWb.AS_SHOT, ColorWb.CUSTOM]
	if has_auto:
		start_modes.append(ColorWb.AUTO)
	for start_mode in start_modes:
		for slider_name in sliders:
			_press(start_mode)
			_check(await _idle(), "render before %s from %s" % [slider_name, start_mode])
			_check(_main.wb_mode_bar.current_mode == start_mode, "bar at %s before touching %s" % [start_mode, slider_name])
			var slider: HSlider = sliders[slider_name]
			var before_value: float = slider.value
			slider.value = before_value + (slider.step * 10.0 if before_value + slider.step * 10.0 <= slider.max_value else -slider.step * 10.0)
			_check(slider.value != before_value, "%s actually moved" % slider_name)
			_check(_main._params["wb_mode"] == ColorWb.CUSTOM, "%s from %s switches to Custom" % [slider_name, start_mode])
			if slider_name == "temp" or slider_name == "tint":
				_check(_main._params["wb_override"] == true, "manual %s edit sets wb_override" % slider_name)
			elif start_mode == ColorWb.AS_SHOT:
				_check(_main._params["wb_override"] == false, "%s edit from As Shot leaves wb_override false" % slider_name)
			elif start_mode == ColorWb.AUTO:
				_check(_main._params["wb_override"] == true, "%s edit after Auto keeps wb_override" % slider_name)
			_check(_main.wb_mode_bar.current_mode == ColorWb.CUSTOM, "bar follows %s from %s" % [slider_name, start_mode])
			_check(await _idle(), "render after %s" % slider_name)
	# Custom keeps numbers; As Shot resets Temp+Tint only.
	_main.white_balance_slider.value = 6000.0
	_main.tint_slider.value = 15.0
	_main.vibrance_slider.value = 21.0
	_main.exposure_slider.value = 0.6
	_check(await _idle(), "render after setting Custom values")
	# The Temp slider snaps to its step grid (anchored at its minimum).
	var custom_k: float = _main.white_balance_slider.value
	var custom_tint: float = _main.tint_slider.value
	var vib: float = _main._params["vibrance"]
	var expo: float = _main._params["exposure"]
	_press(ColorWb.CUSTOM)
	_check(_main._params["wb_mode"] == ColorWb.CUSTOM, "Custom button selects Custom")
	_check(_main._params["wb_temperature"] == custom_k and _main._params["wb_tint"] == custom_tint, "Custom changes no numbers")
	_press(ColorWb.AS_SHOT)
	_check(await _idle(), "render after As Shot button")
	_check(_main._params["wb_temperature"] == as_shot_k and _main._params["wb_tint"] == as_shot_tint, "As Shot resets Temp and Tint")
	_check(_main._params["wb_override"] == false and _main._wb_backend_key == "neutral", "As Shot clears wb_override and restores the exact state")
	_check(_main._params["vibrance"] == vib and _main._params["exposure"] == expo, "As Shot leaves Vibrance and other edits")
	_check(absf(_main.tint_slider.value - as_shot_tint) <= _main.tint_slider.step * 0.5
			and _main.wb_mode_bar.current_mode == ColorWb.AS_SHOT,
			"As Shot updates the controls without extra signals")

	# --- before/after keeps the edited state ---------------------------------
	_main.white_balance_slider.value = 5000.0
	_main.tint_slider.value = -20.0
	_check(await _idle(), "render before compare")
	var edited_temp: float = _main._params["wb_temperature"]
	var edited_tint: float = _main._params["wb_tint"]
	_main._begin_compare()
	_main._end_compare()
	_check(_main._params["wb_mode"] == ColorWb.CUSTOM and _main._params["wb_temperature"] == edited_temp
			and _main._params["wb_tint"] == edited_tint, "compare leaves _params untouched")
	_check(_main._applied_params["wb_mode"] == ColorWb.CUSTOM and _main._applied_params["wb_temperature"] == edited_temp
			and _main._applied_params["wb_tint"] == edited_tint, "compare restores the edited backend state")

	# --- save and reopen restore mode and values ------------------------------
	_main._flush_pending_save()
	_check(_main.open_photo(raw), "reopen after Custom")
	_check(await _idle(), "render after reopen (custom)")
	_check(_main._params["wb_mode"] == ColorWb.CUSTOM and _main._params["wb_temperature"] == edited_temp
			and _main._params["wb_tint"] == edited_tint, "Custom mode and values restored")
	_check(_main.wb_mode_bar.current_mode == ColorWb.CUSTOM and _main.tint_slider.value == edited_tint, "restored controls show Custom values")
	_check(_main._save_timer.is_stopped(), "restoring a photo does not arm a save")

	if has_auto:
		_press(ColorWb.AUTO)
		_check(await _idle(), "render after Auto (persist)")
		var auto_k: float = _main._params["wb_temperature"]
		var auto_tint: float = _main._params["wb_tint"]
		_main._flush_pending_save()
		_check(_main.open_photo(raw), "reopen after Auto")
		_check(await _idle(), "render after reopen (auto)")
		_check(_main._params["wb_mode"] == ColorWb.AUTO, "Auto mode restored")
		_check(is_equal_approx(_main._params["wb_temperature"], auto_k) and is_equal_approx(_main._params["wb_tint"], auto_tint),
				"Auto values restored verbatim, not recomputed")
		_check(not _main._auto_wb_pending, "restore leaves no Auto pending")

		# A save that fires while Auto is still unresolved must resolve it
		# first instead of writing stale numbers under mode "auto".
		_main._auto_wb_pending = true
		_main._params["wb_mode"] = ColorWb.AUTO
		_main._params["wb_temperature"] = 3333.0
		_main._params["wb_tint"] = 33.0
		_main._mark_edit_dirty()
		_main._flush_pending_save()
		_check(not _main._auto_wb_pending, "flush resolves a pending Auto")
		var saved: Dictionary = EditStore.load(_main._edit_key)
		_check(saved.get("wb_mode", "") == "auto" and float(saved.get("wb_temperature", 0.0)) != 3333.0,
				"saved Auto record holds measured, not stale, values")

	_press(ColorWb.AS_SHOT)
	_check(await _idle(), "render after As Shot (persist)")
	_main._flush_pending_save()
	_check(_main.open_photo(raw), "reopen after As Shot")
	_check(await _idle(), "render after reopen (as shot)")
	_check(_main._params["wb_mode"] == ColorWb.AS_SHOT and _main._params["wb_temperature"] == as_shot_k
			and _main._params["wb_tint"] == as_shot_tint, "As Shot restored")

	# --- legacy record whose temperature equals as-shot keeps its forced correction
	var legacy_meta: Dictionary = {"file_name": _main._edit_file_name, "thumb_hash": _main._edit_thumb_hash, "updated_at": 1}
	EditStore.save(_main._edit_key, {"wb_temperature": as_shot_k, "exposure": 0.0}, legacy_meta)
	_check(_main.open_photo(raw), "reopen legacy as-shot-temperature record")
	_check(await _idle(), "render after reopen (legacy at as-shot K)")
	_check(_main._params["wb_mode"] == ColorWb.CUSTOM and _main._params["wb_override"] == true and _main._params["wb_tint"] == 0.0,
			"legacy record at the as-shot temperature restores Custom + override, tint 0")
	_check(_main._wb_backend_key == "%f,%f" % [as_shot_k, 0.0],
			"legacy record at the as-shot temperature is applied as an explicit correction, not the exact reset")

	# --- legacy record: temperature only, no mode/tint -----------------------
	var legacy_k: float = as_shot_k + 800.0
	EditStore.save(_main._edit_key, {"wb_temperature": legacy_k, "exposure": 0.0},
			{"file_name": _main._edit_file_name, "thumb_hash": _main._edit_thumb_hash, "updated_at": 1})
	_check(_main.open_photo(raw), "reopen legacy record")
	_check(await _idle(), "render after reopen (legacy)")
	_check(_main._params["wb_mode"] == ColorWb.CUSTOM and _main._params["wb_temperature"] == legacy_k
			and _main._params["wb_tint"] == 0.0, "legacy temperature-only record restores Custom, tint 0")

	# --- switching to a different image resets to its own As Shot ------------
	_main._flush_pending_save()
	if FileAccess.file_exists(SECOND_IMAGE):
		_check(_main.open_photo(ProjectSettings.globalize_path(SECOND_IMAGE)), "open a second image")
		_check(await _idle(), "render second image")
		_check(_main._params["wb_mode"] == ColorWb.AS_SHOT and _main.wb_mode_bar.current_mode == ColorWb.AS_SHOT,
				"a different photo starts As Shot")
		_check(_main._params["wb_temperature"] == _main._wb_default_temperature, "second image uses its own as-shot temperature")
		_check(_main.open_photo(raw), "back to the RAW")
		_check(await _idle(), "render after switching back")
		_check(_main._params["wb_mode"] == ColorWb.CUSTOM and _main._params["wb_temperature"] == legacy_k,
				"switching back restores that photo's mode")

	# --- export exclusion ----------------------------------------------------
	var export_path: String = ProjectSettings.globalize_path("user://color_controls_export.jpg")
	var mode_before: String = _main._params["wb_mode"]
	_main._on_export_dialog_file_selected(export_path)
	_check(_main._exporting, "export started")
	for mode in ColorWb.MODES:
		_check(_main.wb_mode_bar.get_button(mode).disabled, "%s disabled during export" % mode)
	_check(not _main.tint_slider.editable, "Tint disabled during export")
	_main._on_wb_mode_selected(ColorWb.AUTO)
	_check(_main._params["wb_mode"] == mode_before and not _main._auto_wb_pending, "mode clicks are ignored during export")
	var frames: int = 0
	while _main._exporting and frames < MAX_WAIT_FRAMES:
		await process_frame
		frames += 1
	_check(not _main._exporting, "export finished")
	for mode in ColorWb.MODES:
		_check(not _main.wb_mode_bar.get_button(mode).disabled, "%s re-enabled after export" % mode)
	_check(_main.tint_slider.editable, "Tint re-enabled after export")
	_check(FileAccess.file_exists(export_path), "export wrote a file")
	DirAccess.remove_absolute(export_path)

	_main._flush_pending_save()
	_cleanup_edits()
	_finish()


# Polls Main's render-coalescing state until idle.
func _idle() -> bool:
	var frames: int = 0
	while (_main._processing or _main._render_queued or _main._render_gate_pending()) and frames < MAX_WAIT_FRAMES:
		await process_frame
		frames += 1
	return not _main._processing and not _main._render_queued


# Same signal a mouse click on a segment raises.
func _press(mode: String) -> void:
	_main.wb_mode_bar.get_button(mode).pressed.emit()


func _worst_diff(a: Image, b: Image) -> float:
	if a == null or b == null or a.get_size() != b.get_size():
		return 1.0
	var worst: float = 0.0
	for gy in SAMPLE_GRID:
		for gx in SAMPLE_GRID:
			var x: int = clampi(int((float(gx) + 0.5) / SAMPLE_GRID * a.get_width()), 0, a.get_width() - 1)
			var y: int = clampi(int((float(gy) + 0.5) / SAMPLE_GRID * a.get_height()), 0, a.get_height() - 1)
			var ca: Color = a.get_pixel(x, y)
			var cb: Color = b.get_pixel(x, y)
			worst = maxf(worst, maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b))))
	return worst


func _cleanup_edits() -> void:
	var key: String = _main._edit_key
	if key != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(EditStore.store_path(key)))
