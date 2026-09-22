extends SceneTree

# Saturation verification: load the fixture RAW, render the neutral frame,
# then sweep the saturation axis across BOTH modules that implement it (see
# set_saturation()/set_desaturation() in dt_backend.cpp):
#   - set_saturation() drives velvia's introspection-resolved "strength" field
#     (boost-only, 0..100) for the ABOVE-neutral half.
#   - set_desaturation() drives monochrome's BLEND opacity (not a params
#     field) for the BELOW-neutral half, fading the frame toward grayscale.
# Chroma spread (mean |channel - luma| per pixel) is the signal: velvia
# boosts it, monochrome's blend collapses it toward zero. Asserts:
#   1) saturation=100 increases mean chroma vs. neutral
#   2) desaturation=1.0 (full B&W) drives mean chroma near zero
#   3) resetting both restores the neutral frame (mean luma within tolerance)
# Run:
#   Godot --headless --path godot-poc/project --script res://tests/saturation_smoke_test.gd \
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


func _mean_luma(data: PackedByteArray, w: int, h: int) -> float:
	var sum: float = 0.0
	var n: int = 0
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
	printerr("SATURATION_SMOKE: FAIL: " + msg)
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
	var neutral_luma: float = _mean_luma(neutral, w, h)
	print("SATURATION_SMOKE: neutral frame %dx%d, mean chroma %.3f, mean luma %.3f" % [w, h, neutral_chroma, neutral_luma])

	backend.set_saturation(100.0)
	var boosted: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var boosted_chroma: float = _mean_chroma(boosted, w, h)
	print("SATURATION_SMOKE: saturation=100 frame, mean chroma %.3f" % boosted_chroma)

	backend.set_saturation(0.0)
	backend.set_desaturation(1.0)
	var bw: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var bw_chroma: float = _mean_chroma(bw, w, h)
	print("SATURATION_SMOKE: desaturation=1.0 frame, mean chroma %.3f" % bw_chroma)

	backend.set_desaturation(0.0)
	var reset: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var reset_luma: float = _mean_luma(reset, w, h)
	print("SATURATION_SMOKE: reset frame, mean luma %.3f" % reset_luma)

	if boosted_chroma <= neutral_chroma + 0.3:
		_die("saturation=100 did not increase chroma (chroma %.3f vs neutral %.3f)" % [boosted_chroma, neutral_chroma])
		return
	if bw_chroma > 1.0:
		_die("desaturation=1.0 did not collapse chroma to near-zero (chroma %.3f)" % bw_chroma)
		return
	if absf(reset_luma - neutral_luma) > 2.0:
		_die("reset did not restore neutral luma (%.3f vs %.3f)" % [reset_luma, neutral_luma])
		return

	print("SATURATION_SMOKE: PASS")
	quit(0)
