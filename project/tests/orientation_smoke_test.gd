extends SceneTree

# Orientation: render the neutral frame, then rotate via set_orientation() in
# 90-degree clockwise steps and assert the geometry matches each quarter-turn.
# quarter_turns 1 and 3 must SWAP width/height; 2 must keep them; 0 must be an
# exact identity (same dims as the untouched frame). The corner-content check
# proves a real rotation for the 90 CW case: the full frame's bottom-left pixel
# lands at the rotated frame's top-left.
# Run: Godot --headless --path godot-poc/project --script res://tests/orientation_smoke_test.gd -- <input_raw>  (DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR must be exported)

func _die(msg: String) -> void:
	printerr("ORIENT_SMOKE: FAIL: " + msg)
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

	backend.set_exposure(0.0)
	var full: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var fw: int = backend.get_width()
	var fh: int = backend.get_height()
	print("ORIENT_SMOKE: base frame %dx%d (%d bytes)" % [fw, fh, full.size()])
	if fw <= 0 or fh <= 0:
		_die("base render failed")
		return

	# 90 CW: dims swap.
	backend.set_orientation(1)
	var r1: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var w1: int = backend.get_width()
	var h1: int = backend.get_height()
	print("ORIENT_SMOKE: 90cw frame %dx%d" % [w1, h1])
	if w1 != fh or h1 != fw:
		_die("90cw did not swap dims: got %dx%d expected %dx%d" % [w1, h1, fh, fw])
		return

	# 90 CW maps the base bottom-left pixel to the rotated top-left.
	var px := func(data: PackedByteArray, w: int, x: int, y: int) -> Color:
		var i: int = (y * w + x) * 4
		return Color(data[i] / 255.0, data[i + 1] / 255.0, data[i + 2] / 255.0)
	var a: Color = px.call(full, fw, 0, fh - 1)
	var b: Color = px.call(r1, w1, 0, 0)
	var dist: float = sqrt(pow(a.r - b.r, 2) + pow(a.g - b.g, 2) + pow(a.b - b.b, 2))
	print("ORIENT_SMOKE: 90cw corner base-BL(%.3f,%.3f,%.3f) vs rot-TL(%.3f,%.3f,%.3f) dist=%.4f" % [
		a.r, a.g, a.b, b.r, b.g, b.b, dist])
	if dist > 0.08:
		_die("90cw content does not match expected corner mapping (dist=%.4f)" % dist)
		return

	# 180: dims unchanged.
	backend.set_orientation(2)
	var _r2: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var w2: int = backend.get_width()
	var h2: int = backend.get_height()
	print("ORIENT_SMOKE: 180 frame %dx%d" % [w2, h2])
	if w2 != fw or h2 != fh:
		_die("180 changed dims: got %dx%d expected %dx%d" % [w2, h2, fw, fh])
		return

	# 270 CW: dims swap again.
	backend.set_orientation(3)
	var _r3: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var w3: int = backend.get_width()
	var h3: int = backend.get_height()
	print("ORIENT_SMOKE: 270cw frame %dx%d" % [w3, h3])
	if w3 != fh or h3 != fw:
		_die("270cw did not swap dims: got %dx%d expected %dx%d" % [w3, h3, fh, fw])
		return

	# 0: exact identity, dims restored and content matches the base frame.
	backend.set_orientation(0)
	var r0: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	print("ORIENT_SMOKE: identity frame %dx%d" % [backend.get_width(), backend.get_height()])
	if backend.get_width() != fw or backend.get_height() != fh:
		_die("quarter_turns=0 did not restore dims")
		return
	if r0.size() != full.size():
		_die("identity buffer size mismatch: %d vs %d" % [r0.size(), full.size()])
		return
	var c: Color = px.call(full, fw, int(fw * 0.5), int(fh * 0.5))
	var d: Color = px.call(r0, fw, int(fw * 0.5), int(fh * 0.5))
	var idist: float = sqrt(pow(c.r - d.r, 2) + pow(c.g - d.g, 2) + pow(c.b - d.b, 2))
	if idist > 0.02:
		_die("quarter_turns=0 is not identity (center dist=%.4f)" % idist)
		return

	# Regression: load_image() rebuilds dev.iop, which frees the previous
	# "flip" module instance. A cached flip_module pointer not reset across
	# reloads goes stale, so re-run the 90cw check against a freshly reloaded
	# image the way opening a second photo in the app would.
	if not backend.load_image(input_path):
		_die("second load_image failed")
		return
	backend.set_orientation(1)
	var r1b: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var w1b: int = backend.get_width()
	var h1b: int = backend.get_height()
	print("ORIENT_SMOKE: post-reload 90cw frame %dx%d" % [w1b, h1b])
	if w1b != fh or h1b != fw:
		_die("post-reload 90cw did not swap dims: got %dx%d expected %dx%d" % [w1b, h1b, fh, fw])
		return
	if r1b.size() == 0:
		_die("post-reload 90cw render returned empty buffer")
		return

	print("ORIENT_SMOKE: PASS")
	quit(0)
