extends SceneTree
# Headless functional smoke test for the darktable pixel pipeline, driven
# through the *real* Godot consumer (DtBackend GDExtension) rather than
# darktable-cli. Shared acceptance oracle: RAW -> EV list -> PNGs. An IOP .so
# that dlopens but fails mid-render is only caught by a real functional run,
# not the dependency/leak audits. Intentionally not wired into Main.tscn: it
# constructs DtBackend directly so nothing about the UI can mask a pipeline
# failure. Invoked by scripts/smoke_test.sh, which exports
# DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR (read from the environment by
# compute_dt_dirs in dt_backend.cpp).

func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 4:
		_die("usage: -- <input_raw> <output_dir> <ev1> <ev2> [ev3 ...] (got %d args)" % args.size())
		return

	var input_path: String = args[0]
	var out_dir: String = args[1]
	var evs: Array = []
	for i in range(2, args.size()):
		evs.append(float(args[i]))

	if not FileAccess.file_exists(input_path):
		_die("input RAW does not exist: %s" % input_path)
		return

	print("SMOKE: input=", input_path)
	print("SMOKE: out_dir=", out_dir)
	print("SMOKE: evs=", evs)

	var backend: DtBackend = DtBackend.new()
	if not backend.init():
		_die("DtBackend.init() failed (check DT_BACKEND_DATADIR / DT_BACKEND_MODULEDIR)")
		return
	print("SMOKE: init ok")

	if not backend.load_image(input_path):
		_die("load_image failed: %s" % input_path)
		return
	print("SMOKE: loaded %s (%dx%d)" % [
		input_path, backend.get_raw_width(), backend.get_raw_height()])

	var wrote: PackedStringArray = PackedStringArray()
	for ev in evs:
		backend.set_exposure(ev)
		# tag with the EV so runs never collide and negatives stay legible ("-1.0" -> "m1_0").
		var tag: String = ("%+.2f" % ev).replace("+", "p").replace("-", "m").replace(".", "_")
		var out_path: String = out_dir.path_join("smoke_ev_%s.png" % tag)
		if not backend.export_image(out_path):
			backend.cleanup()
			_die("export_image failed at ev=%f -> %s" % [ev, out_path])
			return
		print("SMOKE: exported ev=%.2f -> %s" % [ev, out_path])
		wrote.append(out_path)

	backend.cleanup()

	# Own lines so the shell wrapper can collect paths without parsing prose.
	for p in wrote:
		print("SMOKE_FILE: ", p)
	print("SMOKE_RESULT: PASS")
	quit(0)


func _die(msg: String) -> void:
	printerr("SMOKE_RESULT: FAIL - ", msg)
	quit(1)
