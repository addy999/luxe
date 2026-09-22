extends SceneTree

# Shadows/Highlights verification: load the fixture RAW, render the neutral
# frame, then sweep set_shadows()/set_highlights() via the
# introspection-resolved shadhi "shadows"/"highlights" fields (see
# dt_iop_set_float() in dt_backend.cpp). shadhi.c's own convention: positive
# `shadows` lifts shadow tones (frame BRIGHTENS), positive `highlights` lifts
# highlight tones too (also brightens; negative highlights pulls them down).
# `shadows` is checked against WHOLE-FRAME mean luma (the fixture, even
# lifted, is still overwhelmingly shadow-toned, so the shadows band dominates
# the mean). `highlights` only acts on already-bright pixels, which are a
# small minority of this frame -- moving them barely shifts the WHOLE-frame
# mean, so `highlights` is instead checked against the mean of the BRIGHTEST
# QUARTILE of sampled pixels, where the band's effect is concentrated.
# Asserts:
#   1) shadows=+70 brightens the frame vs. neutral (whole-frame mean)
#   2) shadows=-70 darkens the frame vs. neutral (whole-frame mean)
#   3) highlights=+70 brightens the brightest pixels vs. neutral
#   4) highlights=-70 darkens the brightest pixels vs. neutral
#   5) resetting both to 0 restores the neutral frame (mean within tolerance)
# Run:
#   Godot --headless --path godot-poc/project --script res://tests/shadows_highlights_smoke_test.gd \
#         -- <input_raw>
# with DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR exported.

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


# Mean luma of the brightest ~25% of sampled pixels -- where shadhi's
# highlights band has most of its effect, unlike the whole-frame mean.
func _bright_quartile_mean_luma(data: PackedByteArray, w: int, h: int) -> float:
	var lumas: Array = []
	for y in h:
		var row: int = y * w * 4
		for x in range(0, w, 16):
			var i: int = row + x * 4
			lumas.append(0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2])
	if lumas.is_empty():
		return -1.0
	lumas.sort()
	var cutoff: int = int(lumas.size() * 0.75)
	var sum: float = 0.0
	var n: int = 0
	for i in range(cutoff, lumas.size()):
		sum += lumas[i]
		n += 1
	if n == 0:
		return -1.0
	return sum / n


func _die(msg: String) -> void:
	printerr("SHADOWS_HIGHLIGHTS_SMOKE: FAIL: " + msg)
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

	# Lift the frame well past set_shadows()'s +4.0 EV: the fixture RAW is
	# nearly black, and shadhi's highlights band needs real bright-pixel
	# content to act on, not just a lifted-but-still-dark frame.
	backend.set_exposure(6.0)

	var neutral: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var w: int = backend.get_width()
	var h: int = backend.get_height()
	if w <= 0 or h <= 0:
		_die("neutral render failed")
		return
	var neutral_luma: float = _mean_luma(neutral, w, h)
	print("SHADOWS_HIGHLIGHTS_SMOKE: neutral frame %dx%d, mean luma %.3f" % [w, h, neutral_luma])

	backend.set_shadows(70.0)
	var shadows_up: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var shadows_up_luma: float = _mean_luma(shadows_up, w, h)
	print("SHADOWS_HIGHLIGHTS_SMOKE: shadows=70 frame, mean luma %.3f" % shadows_up_luma)

	backend.set_shadows(-70.0)
	var shadows_down: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var shadows_down_luma: float = _mean_luma(shadows_down, w, h)
	print("SHADOWS_HIGHLIGHTS_SMOKE: shadows=-70 frame, mean luma %.3f" % shadows_down_luma)

	backend.set_shadows(0.0)
	var highlights_neutral: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var highlights_neutral_luma: float = _bright_quartile_mean_luma(highlights_neutral, w, h)
	print("SHADOWS_HIGHLIGHTS_SMOKE: highlights-neutral frame, bright-quartile mean luma %.3f" % highlights_neutral_luma)

	backend.set_highlights(70.0)
	var highlights_up: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var highlights_up_luma: float = _bright_quartile_mean_luma(highlights_up, w, h)
	print("SHADOWS_HIGHLIGHTS_SMOKE: highlights=70 frame, bright-quartile mean luma %.3f" % highlights_up_luma)

	backend.set_highlights(-70.0)
	var highlights_down: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var highlights_down_luma: float = _bright_quartile_mean_luma(highlights_down, w, h)
	print("SHADOWS_HIGHLIGHTS_SMOKE: highlights=-70 frame, bright-quartile mean luma %.3f" % highlights_down_luma)

	backend.set_highlights(0.0)
	var reset: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var reset_luma: float = _mean_luma(reset, w, h)
	print("SHADOWS_HIGHLIGHTS_SMOKE: reset frame, mean luma %.3f" % reset_luma)

	if shadows_up_luma <= neutral_luma + 0.5:
		_die("shadows=70 did not brighten (luma %.3f vs neutral %.3f)" % [shadows_up_luma, neutral_luma])
		return
	if shadows_down_luma >= neutral_luma - 0.5:
		_die("shadows=-70 did not darken (luma %.3f vs neutral %.3f)" % [shadows_down_luma, neutral_luma])
		return
	if highlights_up_luma <= highlights_neutral_luma + 0.5:
		_die("highlights=70 did not brighten the brightest pixels (luma %.3f vs neutral %.3f)" % [highlights_up_luma, highlights_neutral_luma])
		return
	if highlights_down_luma >= highlights_neutral_luma - 0.5:
		_die("highlights=-70 did not darken the brightest pixels (luma %.3f vs neutral %.3f)" % [highlights_down_luma, highlights_neutral_luma])
		return
	if absf(reset_luma - neutral_luma) > 2.0:
		_die("reset did not restore neutral (luma %.3f vs %.3f)" % [reset_luma, neutral_luma])
		return

	print("SHADOWS_HIGHLIGHTS_SMOKE: PASS")
	quit(0)
