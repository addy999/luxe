extends SceneTree

# Tonecurve: drive set_tonecurve() with an S-curve, then an identity curve.
# Unlike every other setter this writes a COUNTED ARRAY of {x,y} node structs,
# not a single scalar: set_tonecurve() resolves the array base via
# get_p("tonecurve") and per-node x/y byte offsets via
# get_f("tonecurve[0][0].x"/".y") (dt_backend.cpp) rather than a hardcoded
# struct stride. A wrong stride/offset would scramble every node past the
# first, so this covers the one introspection path no scalar-field test hits.
# Run: Godot --headless --path godot-poc/project --script res://tests/tonecurve_smoke_test.gd \
#         -- <input_raw>  (DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR must be exported)

func _luma_stats(data: PackedByteArray, w: int, h: int) -> Vector2:
	var sum: float = 0.0
	var sumsq: float = 0.0
	var n: int = 0
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
	printerr("TONECURVE_SMOKE: FAIL: " + msg)
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

	backend.set_exposure(4.0)

	var neutral: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var w: int = backend.get_width()
	var h: int = backend.get_height()
	if w <= 0 or h <= 0:
		_die("neutral render failed")
		return
	var neutral_stats: Vector2 = _luma_stats(neutral, w, h)
	print("TONECURVE_SMOKE: neutral frame %dx%d, mean %.3f stddev %.3f" % [w, h, neutral_stats.x, neutral_stats.y])

	var s_curve: PackedVector2Array = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(0.25, 0.10),
		Vector2(0.5, 0.5),
		Vector2(0.75, 0.90),
		Vector2(1.0, 1.0),
	])
	backend.set_tonecurve(s_curve)
	var curved: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var curved_stats: Vector2 = _luma_stats(curved, w, h)
	print("TONECURVE_SMOKE: s-curve frame, mean %.3f stddev %.3f" % [curved_stats.x, curved_stats.y])

	var identity: PackedVector2Array = PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(1.0, 1.0),
	])
	backend.set_tonecurve(identity)
	var reset: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var reset_stats: Vector2 = _luma_stats(reset, w, h)
	print("TONECURVE_SMOKE: identity-curve frame, mean %.3f stddev %.3f" % [reset_stats.x, reset_stats.y])

	if curved_stats.y <= neutral_stats.y + 0.5:
		_die("s-curve did not increase luma spread (stddev %.3f vs neutral %.3f): node array write may be scrambled" % [curved_stats.y, neutral_stats.y])
		return
	if absf(reset_stats.x - neutral_stats.x) > 2.0:
		_die("identity curve did not restore neutral (mean %.3f vs %.3f)" % [reset_stats.x, neutral_stats.x])
		return

	print("TONECURVE_SMOKE: PASS")
	quit(0)
