extends SceneTree

# Vibrance verification: load the fixture RAW, render the neutral frame, then
# sweep set_vibrance() via the introspection-resolved vibrance "amount" field
# (see dt_iop_set_float() in dt_backend.cpp). vibrance is a boost-only module
# ($MIN 0.0 $MAX 100.0) that selectively boosts LESS-saturated pixels more
# than already-saturated ones, so its effect on mean chroma (mean |channel -
# luma| per pixel) is real but smaller than a flat boost like velvia's -- the
# threshold below is tuned accordingly (measured ~+4% on the fixture at
# amount=100). Asserts:
#   1) vibrance=100 increases mean chroma vs. neutral
#   2) resetting to 0 restores the neutral frame (mean chroma within tolerance)
# Run:
#   Godot --headless --path godot-poc/project --script res://tests/vibrance_smoke_test.gd \
#         -- <input_raw>
# with DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR exported.

func _mean_chroma(data: PackedByteArray, w: int, h: int) -> float:
	var sum: float = 0.0
	var n: int = 0
	for y in h:
		var row: int = y * w * 4
		for x in range(0, w, 16):
			var i: int = row + x * 4
			var r: float = data[i]
			var g: float = data[i + 1]
			var b: float = data[i + 2]
			var l: float = 0.299 * r + 0.587 * g + 0.114 * b
			sum += (absf(r - l) + absf(g - l) + absf(b - l)) / 3.0
			n += 1
	if n == 0:
		return -1.0
	return sum / n


func _die(msg: String) -> void:
	printerr("VIBRANCE_SMOKE: FAIL: " + msg)
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
	var neutral_chroma: float = _mean_chroma(neutral, w, h)
	print("VIBRANCE_SMOKE: neutral frame %dx%d, mean chroma %.3f" % [w, h, neutral_chroma])

	backend.set_vibrance(100.0)
	var boosted: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var boosted_chroma: float = _mean_chroma(boosted, w, h)
	print("VIBRANCE_SMOKE: vibrance=100 frame, mean chroma %.3f" % boosted_chroma)

	backend.set_vibrance(0.0)
	var reset: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var reset_chroma: float = _mean_chroma(reset, w, h)
	print("VIBRANCE_SMOKE: reset frame, mean chroma %.3f" % reset_chroma)

	if boosted_chroma <= neutral_chroma + 0.1:
		_die("vibrance=100 did not increase chroma (chroma %.3f vs neutral %.3f)" % [boosted_chroma, neutral_chroma])
		return
	if absf(reset_chroma - neutral_chroma) > 1.0:
		_die("reset did not restore neutral chroma (%.3f vs %.3f)" % [reset_chroma, neutral_chroma])
		return

	print("VIBRANCE_SMOKE: PASS")
	quit(0)
