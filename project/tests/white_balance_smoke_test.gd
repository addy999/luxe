extends SceneTree

# White balance: read as-shot Kelvin via get_white_balance_temperature()
# (channelmixerrgb's "temperature" default_params field), then sweep
# set_white_balance_temperature() across warm/cool extremes. Exercises BOTH
# introspection paths: the float "temperature" write AND the enum writes
# ("illuminant" -> DT_ILLUMINANT_D, "adaptation" -> DT_ADAPTATION_CAT16) via
# dt_iop_set_enum() (dt_backend.cpp). A miswired enum value, or a name lookup
# that silently fails, would leave the CAT inactive and both extremes would
# render identically, so the check is direction-agnostic (channelmixerrgb's CAT
# math is not re-derived here): the extremes must just give materially
# different mean R-B balance, proving the writes actually reached the pipe.
# Run: Godot --headless --path godot-poc/project --script res://tests/white_balance_smoke_test.gd -- <input_raw>  (DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR must be exported)

func _mean_rb_diff(data: PackedByteArray, w: int, h: int) -> float:
	var sum: float = 0.0
	var n: int = 0
	for y in h:
		var row: int = y * w * 4
		for x in range(0, w, 16):
			var i: int = row + x * 4
			sum += float(data[i]) - float(data[i + 2]) # R - B
			n += 1
	if n == 0:
		return 0.0
	return sum / n


func _die(msg: String) -> void:
	printerr("WHITE_BALANCE_SMOKE: FAIL: " + msg)
	quit(1)


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 1:
		_die("usage: -- <input_raw>")
		return
	var input_path: String = args[0]

	var backend: DtBackend = DtBackend.new()
	if not backend.init():
		_die("DtBackend.init() failed")
		return
	if not backend.load_image(input_path):
		_die("load_image failed")
		return

	var as_shot: float = backend.get_white_balance_temperature()
	print("WHITE_BALANCE_SMOKE: as-shot temperature %.1f K" % as_shot)
	if as_shot < 1667.0 or as_shot > 25000.0:
		_die("as-shot temperature out of plausible range: %.1f" % as_shot)
		return

	backend.set_exposure(4.0)

	backend.set_white_balance_temperature(3000.0)
	var warm: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var w: int = backend.get_width()
	var h: int = backend.get_height()
	if w <= 0 or h <= 0:
		_die("warm-target render failed")
		return
	var warm_rb: float = _mean_rb_diff(warm, w, h)
	print("WHITE_BALANCE_SMOKE: temperature=3000 frame %dx%d, mean R-B %.3f" % [w, h, warm_rb])

	backend.set_white_balance_temperature(8000.0)
	var cool: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var cool_rb: float = _mean_rb_diff(cool, w, h)
	print("WHITE_BALANCE_SMOKE: temperature=8000 frame, mean R-B %.3f" % cool_rb)

	if absf(cool_rb - warm_rb) < 1.0:
		_die("temperature=3000 vs 8000 did not materially change R-B balance (%.3f vs %.3f): CAT writes may not have reached the pipe" % [warm_rb, cool_rb])
		return

	print("WHITE_BALANCE_SMOKE: PASS")
	quit(0)
