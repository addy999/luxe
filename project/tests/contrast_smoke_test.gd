extends SceneTree

# Contrast verification: load the fixture RAW, render the neutral frame, then
# sweep set_contrast() to its extremes via the introspection-resolved
# colorbalancergb "contrast" field (see dt_iop_set_float() in dt_backend.cpp).
# Contrast pivots around a mid-grey fulcrum, so mean luma alone is not a
# reliable signal (raising contrast can leave the mean roughly unchanged while
# spreading the histogram). Instead this measures the STANDARD DEVIATION of
# luma, which must rise as |contrast| increases: a wider spread is the
# defining effect of a contrast module. Asserts:
#   1) contrast=+1.0 increases luma spread vs. neutral
#   2) contrast=-1.0 decreases luma spread vs. neutral
#   3) resetting to 0 restores the neutral frame (mean within tolerance)
# Run:
#   Godot --headless --path godot-poc/project --script res://tests/contrast_smoke_test.gd \
#         -- <input_raw>
# with DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR exported.

func _luma_stats(data: PackedByteArray, w: int, h: int) -> Vector2:
	var sum: float = 0.0
	var sumsq: float = 0.0
	var n: int = 0
	# Sample every 16th pixel: enough signal, 16x faster than a full sweep.
	for y in h:
		var row: int = y * w * 4
		for x in range(0, w, 16):
			var i: int = row + x * 4
			var l: float = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]
			sum += l
			sumsq += l * l
			n += 1
	if n == 0:
		return Vector2(-1.0, -1.0)
	var mean: float = sum / n
	var variance: float = max(0.0, sumsq / n - mean * mean)
	return Vector2(mean, sqrt(variance))


func _die(msg: String) -> void:
	printerr("CONTRAST_SMOKE: FAIL: " + msg)
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

	# Lift the frame first so there is real tonal range for contrast to spread.
	backend.set_exposure(4.0)

	var neutral: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var w: int = backend.get_width()
	var h: int = backend.get_height()
	if w <= 0 or h <= 0:
		_die("neutral render failed")
		return
	var neutral_stats: Vector2 = _luma_stats(neutral, w, h)
	print("CONTRAST_SMOKE: neutral frame %dx%d, mean %.3f stddev %.3f" % [w, h, neutral_stats.x, neutral_stats.y])

	backend.set_contrast(1.0)
	var pos: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var pos_stats: Vector2 = _luma_stats(pos, w, h)
	print("CONTRAST_SMOKE: contrast=1.0 frame, mean %.3f stddev %.3f" % [pos_stats.x, pos_stats.y])

	backend.set_contrast(-1.0)
	var neg: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var neg_stats: Vector2 = _luma_stats(neg, w, h)
	print("CONTRAST_SMOKE: contrast=-1.0 frame, mean %.3f stddev %.3f" % [neg_stats.x, neg_stats.y])

	backend.set_contrast(0.0)
	var reset: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var reset_stats: Vector2 = _luma_stats(reset, w, h)
	print("CONTRAST_SMOKE: reset frame, mean %.3f stddev %.3f" % [reset_stats.x, reset_stats.y])

	if pos_stats.y <= neutral_stats.y + 0.5:
		_die("contrast=1.0 did not increase luma spread (stddev %.3f vs neutral %.3f)" % [pos_stats.y, neutral_stats.y])
		return
	if neg_stats.y >= neutral_stats.y - 0.5:
		_die("contrast=-1.0 did not decrease luma spread (stddev %.3f vs neutral %.3f)" % [neg_stats.y, neutral_stats.y])
		return
	if absf(reset_stats.x - neutral_stats.x) > 2.0:
		_die("reset did not restore neutral (mean %.3f vs %.3f)" % [reset_stats.x, neutral_stats.x])
		return

	print("CONTRAST_SMOKE: PASS")
	quit(0)
