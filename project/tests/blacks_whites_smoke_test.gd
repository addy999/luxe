extends SceneTree

# Blacks/Whites verification: load the fixture RAW, render the neutral frame,
# then render with the two-sided toneequal band gains (see dt_backend.h's
# dt_iop_toneequalizer_params_t note). set_blacks(1.0) writes -1 EV on the
# -5 EV band (deepens blacks, frame DARKENS), set_blacks(-1.0) writes +1 EV
# (lifts washed blacks, frame BRIGHTENS), set_whites(1.0) writes +1 EV on
# the -1 EV band (boosts whites, frame BRIGHTENS), set_whites(-1.0) writes
# -1 EV (lowers whites, frame DARKENS). Asserts:
#   1) blacks=1.0 darkens the frame (mean luma drops)
#   2) blacks=-1.0 brightens the frame (mean luma rises)
#   3) whites=1.0 brightens the frame (mean luma rises)
#   4) whites=-1.0 darkens the frame (mean luma drops)
#   5) both at full positive strength renders without crashing
#   6) resetting to 0 restores the neutral frame (mean within tolerance)
# Run:
#   Godot --headless --path godot-poc/project --script res://tests/blacks_whites_smoke_test.gd \
#         -- <input_raw>
# with DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR exported.

func _mean_luma(data: PackedByteArray, w: int, h: int) -> float:
	var sum: float = 0.0
	var n: int = 0
	# Sample every 16th pixel: enough signal, 16x faster than a full sweep.
	for y in h:
		var row: int = y * w * 4
		for x in range(0, w, 16):
			var i: int = row + x * 4
			sum += 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]
			n += 1
	if n == 0:
		return -1.0
	return sum / n


func _die(msg: String) -> void:
	printerr("BLACKS_WHITES_SMOKE: FAIL: " + msg)
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

	# The fixture RAW is nearly black (mean ~7.7/255 ≈ -5 EV): almost no pixels
	# live in the whites band, so a whites-band gain barely moves the mean and
	# band interpolation noise can flip the sign. Lift the whole frame with
	# exposure first so the tonal bands are actually populated, then measure
	# the band gains against THAT as the neutral baseline.
	backend.set_exposure(4.0)

	# Neutral frame (no edits beyond darktable's own defaults).
	var neutral: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var nw: int = backend.get_width()
	var nh: int = backend.get_height()
	if nw <= 0 or nh <= 0:
		_die("neutral render failed")
		return
	var neutral_luma: float = _mean_luma(neutral, nw, nh)
	print("BLACKS_WHITES_SMOKE: neutral frame %dx%d, mean luma %.3f" % [nw, nh, neutral_luma])

	# Blacks at full positive strength: -1 EV on the blacks band -> darker.
	backend.set_blacks(1.0)
	var blacks: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var blacks_luma: float = _mean_luma(blacks, nw, nh)
	print("BLACKS_WHITES_SMOKE: blacks=1.0 frame, mean luma %.3f" % blacks_luma)

	# Blacks at full negative strength: +1 EV on the blacks band -> brighter.
	backend.set_blacks(-1.0)
	var neg_blacks: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var neg_blacks_luma: float = _mean_luma(neg_blacks, nw, nh)
	print("BLACKS_WHITES_SMOKE: blacks=-1.0 frame, mean luma %.3f" % neg_blacks_luma)

	# Whites at full positive strength: +1 EV on the whites band -> brighter.
	backend.set_blacks(0.0)
	backend.set_whites(1.0)
	var whites: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var whites_luma: float = _mean_luma(whites, nw, nh)
	print("BLACKS_WHITES_SMOKE: whites=1.0 frame, mean luma %.3f" % whites_luma)

	# Whites at full negative strength: -1 EV on the whites band -> darker.
	backend.set_whites(-1.0)
	var neg_whites: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var neg_whites_luma: float = _mean_luma(neg_whites, nw, nh)
	print("BLACKS_WHITES_SMOKE: whites=-1.0 frame, mean luma %.3f" % neg_whites_luma)

	# Both at full positive strength: independent bands, must render fine.
	backend.set_blacks(1.0)
	backend.set_whites(1.0)
	var both: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var both_luma: float = _mean_luma(both, nw, nh)
	print("BLACKS_WHITES_SMOKE: blacks=1.0 whites=1.0 frame, mean luma %.3f" % both_luma)

	# Reset: back to the neutral frame.
	backend.set_blacks(0.0)
	backend.set_whites(0.0)
	var reset: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var reset_luma: float = _mean_luma(reset, nw, nh)
	print("BLACKS_WHITES_SMOKE: reset frame, mean luma %.3f" % reset_luma)

	if blacks_luma >= neutral_luma - 1.0:
		_die("blacks=1.0 did not darken (luma %.3f vs neutral %.3f)" % [blacks_luma, neutral_luma])
		return
	if neg_blacks_luma <= neutral_luma + 1.0:
		_die("blacks=-1.0 did not brighten (luma %.3f vs neutral %.3f)" % [neg_blacks_luma, neutral_luma])
		return
	if whites_luma <= neutral_luma + 1.0:
		_die("whites=1.0 did not brighten (luma %.3f vs neutral %.3f)" % [whites_luma, neutral_luma])
		return
	if neg_whites_luma >= neutral_luma - 1.0:
		_die("whites=-1.0 did not darken (luma %.3f vs neutral %.3f)" % [neg_whites_luma, neutral_luma])
		return
	if both_luma < 0.0:
		_die("both-extremes render failed")
		return
	if absf(reset_luma - neutral_luma) > 2.0:
		_die("reset did not restore neutral (luma %.3f vs %.3f)" % [reset_luma, neutral_luma])
		return

	print("BLACKS_WHITES_SMOKE: PASS")
	quit(0)
