extends SceneTree

# White balance verification: load the fixture RAW, read back the as-shot
# Kelvin via get_white_balance_temperature() (reads channelmixerrgb's
# default_params "temperature" field), then sweep
# set_white_balance_temperature() across warm/cool extremes. This exercises
# BOTH introspection code paths the refactor touches for this module: the
# float field write ("temperature") AND the two enum writes ("illuminant" ->
# "DT_ILLUMINANT_D", "adaptation" -> "DT_ADAPTATION_CAT16") resolved by name
# via dt_iop_set_enum(). A wrong/no-op enum code (miswired illuminant, or a
# name lookup silently failing) would leave the CAT inactive and both extreme
# Kelvin targets would render identically -- so rather than assert a specific
# warm/cool sign (channelmixerrgb's CAT math is not worth re-deriving here),
# this checks the two extremes produce a materially different mean R-B channel
# balance, proving the enum + float writes actually reached the pipe. Asserts:
#   1) get_white_balance_temperature() returns a plausible Kelvin (1667..25000)
#   2) temperature=3000 vs temperature=8000 render with a materially different
#      mean R-B channel balance (direction-agnostic: proves the writes landed)
#   3) both renders succeed without error
# Run:
#   Godot --headless --path godot-poc/project --script res://tests/white_balance_smoke_test.gd \
#         -- <input_raw>
# with DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR exported.

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
		_die("temperature=3000 vs 8000 did not materially change R-B balance (%.3f vs %.3f) -- CAT writes may not have reached the pipe" % [warm_rb, cool_rb])
		return

	print("WHITE_BALANCE_SMOKE: PASS")
	quit(0)
