extends SceneTree

# Dehaze verification: load the fixture RAW, render the neutral frame, then
# exercise the backend's OWN hue-safe dehaze post-stage (see set_dehaze and
# _apply_dehaze in dt_backend.cpp; no darktable module is involved).
# set_dehaze(1.0) removes haze, set_dehaze(-1.0) adds it. Hue safety is the
# core property: for each pixel the per-channel RANK ORDER of channel values
# (which determines hue) must be unchanged -- the stage applies the same
# scalar affine map to all three channels. Asserts:
#   1) dehaze=1.0 visibly changes the frame vs. neutral
#   2) dehaze=-1.0 differs from the +1.0 frame (negative direction wired)
#   3) dehaze=0 restores the neutral frame (mean within tolerance)
# Run:
#   Godot --headless --path godot-poc/project --script res://tests/dehaze_smoke_test.gd \
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


# Compare the channel ranking (which channel is largest/middle/smallest) for
# sampled pixels between two same-size frames. The dehaze map out =
# (in - A)/t + A with scalar t preserves strict orderings; ties (within a
# small epsilon) are treated as wildcard.
func _channel_orders_preserved(a: PackedByteArray, b: PackedByteArray, w: int, h: int) -> bool:
	var n: int = w * h
	if a.size() < n * 4 or b.size() < n * 4:
		return false
	for k in range(0, n, 997):
		var ar: float = a[k * 4]
		var ag: float = a[k * 4 + 1]
		var ab: float = a[k * 4 + 2]
		var br: float = b[k * 4]
		var bg: float = b[k * 4 + 1]
		var bb: float = b[k * 4 + 2]
		# channel with max value must agree when the neutral pixel's max
		# channel is strictly dominant (>= 8/255 above the runner-up), same
		# for min. Near-neutral pixels (all channels within 8) are skipped.
		var avals: Array = [ar, ag, ab]
		var bvals: Array = [br, bg, bb]
		var amax: float = max(ar, max(ag, ab))
		var amin: float = min(ar, min(ag, ab))
		if amax - amin <= 8.0:
			continue
		var amaxc: int = 0
		for c in 3:
			if avals[c] == amax:
				amaxc = c
		var aminc: int = 0
		for c in 3:
			if avals[c] == amin:
				aminc = c
		var bmax: float = max(br, max(bg, bb))
		var bmin: float = min(br, min(bg, bb))
		var bmaxc: int = 0
		for c in 3:
			if bvals[c] == bmax:
				bmaxc = c
		var bminc: int = 0
		for c in 3:
			if bvals[c] == bmin:
				bminc = c
		if bvals[amaxc] < bmax - 4.0:
			return false
		if bvals[aminc] > bmin + 4.0:
			return false
	return true


func _die(msg: String) -> void:
	printerr("DEHAZE_SMOKE: FAIL: " + msg)
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

	# Neutral frame (no edits beyond darktable's own defaults).
	var neutral: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var nw: int = backend.get_width()
	var nh: int = backend.get_height()
	if nw <= 0 or nh <= 0:
		_die("neutral render failed")
		return
	var neutral_luma: float = _mean_luma(neutral, nw, nh)
	print("DEHAZE_SMOKE: neutral frame %dx%d, mean luma %.3f" % [nw, nh, neutral_luma])

	# Full dehaze: strength 1.0. The fixture is not guaranteed hazy, so only
	# assert the frame VISIBLY changes, not the direction of the mean.
	backend.set_dehaze(1.0)
	var dehazed: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var dehazed_luma: float = _mean_luma(dehazed, nw, nh)
	print("DEHAZE_SMOKE: dehaze=1.0 frame, mean luma %.3f" % dehazed_luma)

	# Full haze ADD: strength -1.0. Must differ from the +1.0 frame, proving
	# the negative direction is wired (not clamped to 0).
	backend.set_dehaze(-1.0)
	var hazed: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var hazed_luma: float = _mean_luma(hazed, nw, nh)
	print("DEHAZE_SMOKE: dehaze=-1.0 frame, mean luma %.3f" % hazed_luma)

	# Reset: strength 0 is an exact no-op and disables the module, so this
	# must match the neutral frame.
	backend.set_dehaze(0.0)
	var reset: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var reset_luma: float = _mean_luma(reset, nw, nh)
	print("DEHAZE_SMOKE: reset frame, mean luma %.3f" % reset_luma)

	# Hue-preservation probe: sample pixels and assert the channel order
	# (R>=G>=B or permutations) is identical between neutral and dehazed
	# frames. A hue rotation or cast would flip some pair.
	if not _channel_orders_preserved(neutral, dehazed, nw, nh):
		_die("dehaze=1.0 changed pixel hue (channel order flipped)")
		return
	if not _channel_orders_preserved(neutral, hazed, nw, nh):
		_die("dehaze=-1.0 changed pixel hue (channel order flipped)")
		return

	if absf(dehazed_luma - neutral_luma) < 1.0:
		_die("dehaze=1.0 did not change the frame (luma %.3f vs neutral %.3f)" % [dehazed_luma, neutral_luma])
		return
	if absf(hazed_luma - dehazed_luma) < 1.0:
		_die("dehaze=-1.0 matches dehaze=1.0 (luma %.3f vs %.3f)" % [hazed_luma, dehazed_luma])
		return
	if absf(reset_luma - neutral_luma) > 2.0:
		_die("reset did not restore neutral (luma %.3f vs %.3f)" % [reset_luma, neutral_luma])
		return

	print("DEHAZE_SMOKE: PASS")
	quit(0)
