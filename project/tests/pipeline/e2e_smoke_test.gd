extends SceneTree

# End-to-end regression oracle: unlike smoke_test.gd and the other
# tests/*_smoke_test.gd (which talk to DtBackend directly, bypassing the UI
# on purpose), this one instantiates the real Main.tscn and drives it the
# way a user would -- slider.value assignments and the real signal handlers
# -- then exports through the real export flow. It exists to catch wiring
# regressions in Main.gd itself (e.g. a table-driven refactor binding the
# wrong setter to the wrong slider), which the backend-only tests cannot see.
#
# Run: Godot --headless --path godot-poc/project --script res://tests/e2e_smoke_test.gd
#        -- <input_raw> <out_dir> [--update-fixture]
# (DT_BACKEND_DATADIR / DT_BACKEND_MODULEDIR must be exported; see scripts/e2e_smoke_test.sh)
#
# Pixel comparison samples a fixed grid of points rather than every pixel --
# full-resolution exports can be tens of megapixels and GDScript is
# interpreted, so a full scan would make the test prohibitively slow.

const FIXTURE_PATH: String = "res://tests/fixtures/e2e_fixture.jpg"
const SAMPLE_GRID: int = 12          # SAMPLE_GRID^2 sample points across the image
const MAX_CHANNEL_DIFF: float = 0.04 # per-sample-point, per-channel tolerance (0..1)
const MAX_WAIT_FRAMES: int = 1200    # safety cap so a stuck render fails instead of hanging


func _die(msg: String) -> void:
	printerr("E2E_SMOKE: FAIL - ", msg)
	quit(1)


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2:
		_die("usage: -- <input_raw> <out_dir> [--update-fixture]")
		return

	var input_path: String = args[0]
	var out_dir: String = args[1]
	var update_fixture: bool = args.has("--update-fixture")

	if not FileAccess.file_exists(input_path):
		_die("input RAW does not exist: %s" % input_path)
		return

	var main: Control = (load("res://Main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	# Main._ready() itself awaits one process_frame before init_backend(); give
	# it two to be safe.
	await process_frame
	await process_frame

	if main.backend == null:
		_die("backend failed to initialize (check DT_BACKEND_DATADIR/MODULEDIR)")
		return
	print("E2E_SMOKE: backend initialized")

	main._on_file_dialog_file_selected(input_path)
	if not await _wait_render_idle(main):
		_die("timed out waiting for the initial render")
		return
	if main.image_texture == null:
		_die("image failed to load: %s" % input_path)
		return
	print("E2E_SMOKE: loaded %s (%dx%d)" % [
		input_path, main.backend.get_raw_width(), main.backend.get_raw_height()])

	# --- drive every slider, one real value_changed signal at a time --------
	var slider_edits: Array = [
		["exposure_slider", 1.0],
		["contrast_slider", 0.3],
		["highlights_slider", -20.0],
		["shadows_slider", 20.0],
		["blacks_slider", -0.3],
		["whites_slider", 0.3],
		["dehaze_slider", 0.4],
		["saturation_slider", 20.0],
		["vibrance_slider", 20.0],
		["white_balance_slider", 5500.0],
	]
	for edit in slider_edits:
		var slider_name: String = edit[0]
		var value: float = edit[1]
		var slider: HSlider = main.get(slider_name)
		slider.value = value
		if not await _wait_render_idle(main):
			_die("timed out waiting for render after %s = %f" % [slider_name, value])
			return
		print("E2E_SMOKE: %s -> %f ok" % [slider_name, value])

	# --- tone curve: fire the editor's real signal, same as a mouse drag ----
	var curve_points := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(0.25, 0.15), Vector2(0.75, 0.85), Vector2(1.0, 1.0)])
	main.tone_curve_editor.curve_changed.emit(curve_points)
	if not await _wait_render_idle(main):
		_die("timed out waiting for render after tone curve edit")
		return
	print("E2E_SMOKE: tone curve ok")

	# --- crop: open the overlay, then apply, same calls the Done button makes
	main._on_crop_button_toggled(true)
	if not await _wait_render_idle(main):
		_die("timed out waiting for render after opening crop")
		return
	main._on_crop_overlay_applied(Rect2(Vector2(0.1, 0.1), Vector2(0.7, 0.7)))
	if not await _wait_render_idle(main):
		_die("timed out waiting for render after applying crop")
		return
	print("E2E_SMOKE: crop ok")

	# --- export, through the real dialog-selected handler -------------------
	var out_path: String = out_dir.path_join("e2e_output.jpg")
	main._on_export_dialog_file_selected(out_path)
	if not await _wait_export_idle(main):
		_die("timed out waiting for export")
		return
	if not FileAccess.file_exists(out_path):
		_die("export did not produce a file: %s" % out_path)
		return
	print("E2E_SMOKE: exported -> ", out_path)

	var output_img: Image = Image.load_from_file(out_path)
	if output_img == null:
		_die("could not decode exported file: %s" % out_path)
		return

	var fixture_abs: String = ProjectSettings.globalize_path(FIXTURE_PATH)
	if update_fixture or not FileAccess.file_exists(FIXTURE_PATH):
		DirAccess.make_dir_recursive_absolute(fixture_abs.get_base_dir())
		if output_img.save_jpg(fixture_abs, 0.92) != OK:
			_die("could not write fixture: %s" % fixture_abs)
			return
		print("E2E_SMOKE: wrote new fixture -> ", fixture_abs, " (re-run without --update-fixture to verify)")
		print("E2E_SMOKE_RESULT: PASS")
		quit(0)
		return

	var fixture_img: Image = Image.load_from_file(fixture_abs)
	if fixture_img == null:
		_die("could not decode fixture: %s" % fixture_abs)
		return

	var mismatch: String = _compare_sampled(output_img, fixture_img)
	if mismatch != "":
		_die(mismatch)
		return

	print("E2E_SMOKE_RESULT: PASS")
	quit(0)


# Polls Main's render-coalescing state until idle (not mid-render, nothing
# queued, no trailing gate timer armed) or MAX_WAIT_FRAMES elapses.
func _wait_render_idle(main: Control) -> bool:
	var frames: int = 0
	while (main._processing or main._render_queued or main._render_gate_pending()) \
			and frames < MAX_WAIT_FRAMES:
		await process_frame
		frames += 1
	return not main._processing and not main._render_queued


func _wait_export_idle(main: Control) -> bool:
	var frames: int = 0
	while main._exporting and frames < MAX_WAIT_FRAMES:
		await process_frame
		frames += 1
	return not main._exporting


# Compares a SAMPLE_GRID x SAMPLE_GRID grid of normalized positions; returns
# "" on match, else a failure description.
func _compare_sampled(a: Image, b: Image) -> String:
	if a.get_width() != b.get_width() or a.get_height() != b.get_height():
		return "dimension mismatch: output %dx%d vs fixture %dx%d" % [
			a.get_width(), a.get_height(), b.get_width(), b.get_height()]

	var w: int = a.get_width()
	var h: int = a.get_height()
	var worst: float = 0.0
	var worst_pos: Vector2i = Vector2i.ZERO
	for gy in range(SAMPLE_GRID):
		for gx in range(SAMPLE_GRID):
			var x: int = clampi(int((float(gx) + 0.5) / SAMPLE_GRID * w), 0, w - 1)
			var y: int = clampi(int((float(gy) + 0.5) / SAMPLE_GRID * h), 0, h - 1)
			var ca: Color = a.get_pixel(x, y)
			var cb: Color = b.get_pixel(x, y)
			var diff: float = max(absf(ca.r - cb.r), max(absf(ca.g - cb.g), absf(ca.b - cb.b)))
			if diff > worst:
				worst = diff
				worst_pos = Vector2i(x, y)

	print("E2E_SMOKE: worst sample diff = %.4f at %s" % [worst, worst_pos])
	if worst > MAX_CHANNEL_DIFF:
		return "pixel mismatch vs fixture: worst per-channel diff %.4f at %s (tolerance %.4f)" % [
			worst, worst_pos, MAX_CHANNEL_DIFF]
	return ""