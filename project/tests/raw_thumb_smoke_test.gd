extends SceneTree

# RawThumb: load a RAW, render a thumbnail-scale preview the same way Main.gd's
# _raw_thumb_task does (render_preview at _RAW_THUMB_SCALE), and assert the
# buffer is well-formed and downscaled to thumbnail-sized bounds.
# Run: Godot --headless --path godot-poc/project --script res://tests/raw_thumb_smoke_test.gd -- <input_raw>  (DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR must be exported)

func _die(msg: String) -> void:
	printerr("RAW_THUMB_SMOKE: FAIL: " + msg)
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

	var bytes: PackedByteArray = backend.render_preview(1000000, 1000000, 0.25, 0.0, 0.0)
	var w: int = backend.get_width()
	var h: int = backend.get_height()
	print("RAW_THUMB_SMOKE: preview render %dx%d, %d bytes" % [w, h, bytes.size()])

	if w <= 0 or h <= 0:
		_die("render_preview produced zero-sized dims (%d x %d)" % [w, h])
		return
	if bytes.size() < w * h * 4:
		_die("buffer too small: %d bytes for %dx%d RGBA8 (need %d)" % [bytes.size(), w, h, w * h * 4])
		return

	var img: Image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)
	if img == null:
		_die("Image.create_from_data failed")
		return

	if not (w > 0 and w <= 400 and h > 0 and h <= 400):
		_die("downscale out of expected bounds: %dx%d (want 0 < dim <= 400)" % [w, h])
		return

	var out_path: String = "user://raw_thumb_smoke_test.jpg"
	if img.save_jpg(out_path, 0.85) != OK:
		_die("failed to save jpg to %s" % out_path)
		return
	print("RAW_THUMB_SMOKE: saved %s" % ProjectSettings.globalize_path(out_path))

	print("RAW_THUMB_SMOKE: PASS")
	quit(0)
