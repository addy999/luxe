extends SceneTree

# Straighten: render full frame, apply a rotation via set_straighten_angle(),
# and assert the backend's own crop_auto shrinks the output so no out-of-frame
# area is exposed (dimensions strictly shrink, and by at least as much as the
# closed-form max-inscribed-rectangle scale for the image's own aspect, which
# is a valid lower bound on darktable's dual-orientation cropscale search).
# Run: Godot --headless --path godot-poc/project --script res://tests/feature/straighten_smoke_test.gd -- <input_raw>

func _die(msg: String) -> void:
	printerr("STRAIGHTEN_SMOKE: FAIL: " + msg)
	quit(1)


# Largest axis-aligned rect sharing image aspect (w x h) that stays inside
# itself once rotated by angle_deg; mirrors clipping.c's crop_auto cropscale
# for its flip=0 branch (darktable also tries flip=1 and keeps the max, so
# this is a valid lower bound, not an exact match).
static func _max_inscribed_scale(w: float, h: float, angle_deg: float) -> float:
	var theta: float = absf(angle_deg) * PI / 180.0
	var a: float = w * 0.5
	var b: float = h * 0.5
	var cos_t: float = cos(theta)
	var sin_t: float = sin(theta)
	var scale: float = INF
	for sy in [1.0, -1.0]:
		var corner_b: float = sy * b
		var ox: float = a * cos_t + corner_b * sin_t
		var oy: float = -a * sin_t + corner_b * cos_t
		if absf(ox) > 1e-6:
			scale = minf(scale, a / absf(ox))
		if absf(oy) > 1e-6:
			scale = minf(scale, b / absf(oy))
	return scale


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
	print("STRAIGHTEN_SMOKE: full frame %dx%d (%d bytes)" % [fw, fh, full.size()])
	if fw <= 0 or fh <= 0 or full.size() == 0:
		_die("full-frame render failed")
		return

	var angle: float = 15.0
	backend.set_straighten_angle(angle)
	var rotated: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	var rw: int = backend.get_width()
	var rh: int = backend.get_height()
	print("STRAIGHTEN_SMOKE: angle=%.1f frame %dx%d" % [angle, rw, rh])
	if rw <= 0 or rh <= 0 or rotated.size() == 0:
		_die("rotated render failed")
		return
	if rw >= fw or rh >= fh:
		_die("straighten did not auto-shrink the frame: %dx%d vs full %dx%d" % [rw, rh, fw, fh])
		return

	var expected_min_scale: float = _max_inscribed_scale(fw, fh, angle)
	var actual_w_ratio: float = float(rw) / float(fw)
	var actual_h_ratio: float = float(rh) / float(fh)
	print("STRAIGHTEN_SMOKE: expected_min_scale=%.4f actual=(%.4f,%.4f)" % [
		expected_min_scale, actual_w_ratio, actual_h_ratio])
	if actual_w_ratio < expected_min_scale - 0.02 or actual_h_ratio < expected_min_scale - 0.02:
		_die("auto-crop shrank more than the max-inscribed-rectangle bound allows")
		return

	backend.set_straighten_angle(0.0)
	var restored: PackedByteArray = backend.render_view(1000000, 1000000, 0.5, 0.0, 0.0)
	print("STRAIGHTEN_SMOKE: restored frame %dx%d" % [backend.get_width(), backend.get_height()])
	if backend.get_width() != fw or backend.get_height() != fh:
		_die("clearing the angle did not restore dimensions")
		return

	print("STRAIGHTEN_SMOKE: PASS")
	quit(0)
