extends SceneTree

# One-off crop verification: load the fixture RAW, render full frame, apply a
# centered 50% crop via set_crop(), render again, and assert the second buffer
# is materially smaller AND its content matches the center of the first buffer
# (proves the clipping module actually cropped the pipe output, not just
# changed dimensions). Run:
#   Godot --headless --path godot-poc/project --script res://tests/crop_smoke_test.gd \
#         -- <input_raw> <out_dir>
# with DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR exported.

func _die(msg: String) -> void:
	printerr("CROP_SMOKE: FAIL: " + msg)
	quit(1)


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2:
		_die("usage: -- <input_raw> <out_dir>")
		return
	var input_path: String = args[0]
	var out_dir: String = args[1]

	var backend: DtBackend = DtBackend.new()
	if not backend.init():
		_die("DtBackend.init() failed")
		return
	if not backend.load_image(input_path):
		_die("load_image failed")
		return

	backend.set_exposure(0.0)
	var full: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var fw: int = backend.get_width()
	var fh: int = backend.get_height()
	print("CROP_SMOKE: full frame %dx%d (%d bytes)" % [fw, fh, full.size()])
	if fw <= 0 or fh <= 0:
		_die("full-frame render failed")
		return

	# Centered 50% crop in normalized edge coordinates.
	backend.set_crop(0.25, 0.25, 0.75, 0.75)
	var cropped: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var cw: int = backend.get_width()
	var ch: int = backend.get_height()
	print("CROP_SMOKE: cropped frame %dx%d" % [cw, ch])

	# 1) dimensions shrank by ~half on both axes (edit scale 0.5 -> same buffer
	#    scale on both renders, so the ratio must hold regardless of scale).
	if absf(float(cw) / float(fw) - 0.5) > 0.05 or absf(float(ch) / float(fh) - 0.5) > 0.05:
		_die("crop did not halve dimensions: %dx%d vs %dx%d" % [cw, ch, fw, fh])
		return

	# 2) content check: cropped pixel (0,0) must approximately equal full-frame
	#    pixel at (fw*0.25, fh*0.25) -- the top-left corner of the crop box.
	var px := func(data: PackedByteArray, w: int, x: int, y: int) -> Color:
		var i: int = (y * w + x) * 4
		return Color(data[i] / 255.0, data[i + 1] / 255.0, data[i + 2] / 255.0)
	var cx0: int = int(round(fw * 0.25))
	var cy0: int = int(round(fh * 0.25))
	var a: Color = px.call(full, fw, cx0, cy0)
	var b: Color = px.call(cropped, cw, 0, 0)
	var dist: float = sqrt(pow(a.r - b.r, 2) + pow(a.g - b.g, 2) + pow(a.b - b.b, 2))
	print("CROP_SMOKE: corner match full(%.3f,%.3f,%.3f) vs cropped(%.3f,%.3f,%.3f) dist=%.4f" % [
		a.r, a.g, a.b, b.r, b.g, b.b, dist])
	if dist > 0.08:
		_die("cropped buffer content does not match the crop-box origin in the full frame (dist=%.4f)" % dist)
		return

	# 3) clearing the crop restores the full frame.
	backend.set_crop(0.0, 0.0, 1.0, 1.0)
	var restored: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	print("CROP_SMOKE: restored frame %dx%d" % [backend.get_width(), backend.get_height()])
	if backend.get_width() != fw or backend.get_height() != fh:
		_die("clearing crop did not restore dimensions")
		return

	print("CROP_SMOKE: PASS")
	quit(0)
