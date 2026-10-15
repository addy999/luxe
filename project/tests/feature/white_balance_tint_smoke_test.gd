extends SceneTree

# White balance tint / reset / Auto against the real DtBackend:
#  - reset_white_balance() restores the EXACT load appearance (byte-identical render)
#  - set_white_balance(k, 0) is byte-identical to the legacy temperature-only path
#  - tint > 0 shifts the image toward magenta, tint < 0 toward green (monotonic, visible)
#  - temperature: higher Kelvin (bluer scene light) -> warmer image
#  - single-axis setters keep the other axis; out-of-range / non-finite input is safe
#  - compute_auto_white_balance(): ok, finite, in bounds, repeatable, cached, independent
#    of other edits (exposure), image dependent (RAW vs JPEG), and survives image switching
# Run: Godot --headless --path godot-poc/project --script res://tests/feature/white_balance_tint_smoke_test.gd -- <input_raw>
# (DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR must be exported; use a private HOME.)

const VIEW_W: int = 1000000
const VIEW_H: int = 1000000
const VIEW_SCALE: float = 0.25

var _backend: DtBackend


func _die(msg: String) -> void:
	printerr("WHITE_BALANCE_TINT_SMOKE: FAIL: " + msg)
	quit(1)


func _render() -> PackedByteArray:
	return _backend.render_view(VIEW_W, VIEW_H, VIEW_SCALE, 0.0, 0.0)


# Mean (R, G, B) over a subsample of an RGBA8 frame.
func _mean_rgb(data: PackedByteArray) -> Vector3:
	var n: int = data.size() / 4
	var sr: float = 0.0
	var sg: float = 0.0
	var sb: float = 0.0
	var cnt: int = 0
	for i in range(0, n, 7):
		var o: int = i * 4
		sr += data[o]
		sg += data[o + 1]
		sb += data[o + 2]
		cnt += 1
	if cnt == 0:
		return Vector3.ZERO
	return Vector3(sr / cnt, sg / cnt, sb / cnt)


# Magenta-vs-green measure: positive = magenta cast.
func _magenta(data: PackedByteArray) -> float:
	var m: Vector3 = _mean_rgb(data)
	return (m.x + m.z) * 0.5 - m.y


# Red-vs-blue measure: positive = warm cast.
func _warm(data: PackedByteArray) -> float:
	var m: Vector3 = _mean_rgb(data)
	return m.x - m.z


func _srgb_encode(v: float) -> float:
	v = clampf(v, 0.0, 1.0)
	return 12.92 * v if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055


# Synthetic scene: top half = 8 neutral grey bands, bottom half = saturated colour
# patches (a dominant coloured area to stress Auto). `gains` is a linear-light RGB
# illuminant cast applied to everything. Saved as an sRGB PNG.
func _make_cast_image(path: String, gains: Vector3) -> bool:
	var w: int = 256
	var h: int = 192
	var img: Image = Image.create(w, h, false, Image.FORMAT_RGB8)
	var patches: Array[Vector3] = [
		Vector3(0.7, 0.1, 0.1), Vector3(0.1, 0.6, 0.15), Vector3(0.1, 0.15, 0.7),
		Vector3(0.6, 0.35, 0.25), Vector3(0.7, 0.65, 0.1), Vector3(0.45, 0.2, 0.5)]
	for y in h:
		for x in w:
			var lin: Vector3
			if y < h / 2:
				var band: int = x * 8 / w
				var g: float = 0.06 + 0.12 * band
				lin = Vector3(g, g, g)
			else:
				lin = patches[x * patches.size() / w]
			lin = Vector3(lin.x * gains.x, lin.y * gains.y, lin.z * gains.z)
			img.set_pixel(x, y, Color(_srgb_encode(lin.x), _srgb_encode(lin.y), _srgb_encode(lin.z)))
	return img.save_png(path) == OK


# Mean chroma of the neutral (top-half) bands of a rendered RGBA8 frame: how far
# grey is from R=G=B.
func _grey_chroma(data: PackedByteArray, w: int, h: int) -> float:
	var sum: float = 0.0
	var n: int = 0
	for y in range(2, h / 2 - 2, 3):
		for x in range(2, w - 2, 3):
			var o: int = (y * w + x) * 4
			var r: float = data[o]
			var g: float = data[o + 1]
			var b: float = data[o + 2]
			sum += (absf(r - g) + absf(b - g)) * 0.5
			n += 1
	return sum / maxf(n, 1)


func _check_auto(a: Dictionary, label: String) -> bool:
	if not a.get("ok", false):
		_die("%s: compute_auto_white_balance ok=false" % label)
		return false
	var t: float = a["temperature"]
	var tint: float = a["tint"]
	if not is_finite(t) or not is_finite(tint) or not is_finite(float(a["x"])) or not is_finite(float(a["y"])):
		_die("%s: auto result not finite %s" % [label, str(a)])
		return false
	if t < 1667.0 or t > 25000.0 or absf(tint) > 100.0:
		_die("%s: auto result out of bounds %s" % [label, str(a)])
		return false
	return true


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 1:
		_die("usage: -- <input_raw>")
		return
	var raw_path: String = args[0]
	var jpg_path: String = ProjectSettings.globalize_path("res://tests/fixtures/e2e_fixture.jpg")

	_backend = DtBackend.new()
	if not _backend.init():
		_die("DtBackend.init() failed")
		return
	if not _backend.load_image(raw_path):
		_die("load_image(raw) failed")
		return

	# --- as-shot getters -------------------------------------------------------
	var as_k: float = _backend.get_white_balance_temperature()
	var as_tint: float = _backend.get_white_balance_tint()
	print("WHITE_BALANCE_TINT_SMOKE: as-shot %.1f K tint %.2f" % [as_k, as_tint])
	if as_k < 1667.0 or as_k > 25000.0 or absf(as_tint) > 100.0 or not is_finite(as_tint):
		_die("as-shot K/tint implausible: %f / %f" % [as_k, as_tint])
		return

	var base: PackedByteArray = _render()
	if base.is_empty():
		_die("baseline render failed")
		return
	var w: int = _backend.get_width()
	var h: int = _backend.get_height()
	print("WHITE_BALANCE_TINT_SMOKE: baseline frame %dx%d" % [w, h])

	# --- exact As Shot reset ---------------------------------------------------
	_backend.set_white_balance(3000.0, 40.0)
	var edited: PackedByteArray = _render()
	if edited == base:
		_die("set_white_balance(3000, 40) did not change the render")
		return
	_backend.reset_white_balance()
	if _render() != base:
		_die("reset_white_balance() after combined set is not byte-identical to the load render")
		return
	_backend.set_white_balance_temperature(5500.0)
	_backend.set_white_balance_tint(-60.0)
	_backend.reset_white_balance()
	if _render() != base:
		_die("reset_white_balance() after single-axis edits is not byte-identical to the load render")
		return
	# reset must also be idempotent and not disturb an untouched state
	_backend.reset_white_balance()
	if _render() != base:
		_die("reset_white_balance() is not idempotent")
		return
	print("WHITE_BALANCE_TINT_SMOKE: As Shot reset is byte-exact")

	# The combined setter always applies the supplied values (an approximation of the
	# As Shot illuminant here); only reset_white_balance() restores the exact state.
	_backend.set_white_balance(as_k, as_tint)
	var seeded: PackedByteArray = _render()
	var d_seed: float = absf(_magenta(seeded) - _magenta(base)) + absf(_warm(seeded) - _warm(base))
	if seeded.is_empty() or d_seed > 6.0:
		_die("set_white_balance(as_shot_k, as_shot_tint) is far from the As Shot render (%.3f)" % d_seed)
		return
	_backend.reset_white_balance()

	# Visible contrast helps: exposure is orthogonal to white balance
	_backend.set_exposure(1.0)
	var exposed_base: PackedByteArray = _render()

	# --- zero tint == legacy temperature path ---------------------------------
	_backend.set_white_balance_temperature(5500.0)
	var legacy_5500: PackedByteArray = _render()
	_backend.reset_white_balance()
	_backend.set_white_balance(5500.0, 0.0)
	if _render() != legacy_5500:
		_die("set_white_balance(k, 0) differs from legacy set_white_balance_temperature(k)")
		return

	# --- tint direction and magnitude -----------------------------------------
	_backend.set_white_balance(5500.0, 80.0)
	var mag: PackedByteArray = _render()
	_backend.set_white_balance(5500.0, -80.0)
	var grn: PackedByteArray = _render()
	var m0: float = _magenta(legacy_5500)
	var mp: float = _magenta(mag)
	var mn: float = _magenta(grn)
	print("WHITE_BALANCE_TINT_SMOKE: magenta measure tint -80: %.2f, 0: %.2f, +80: %.2f" % [mn, m0, mp])
	if not (mp > m0 + 1.0 and m0 > mn + 1.0):
		_die("tint is not monotonic/visible: -80=%.2f 0=%.2f +80=%.2f" % [mn, m0, mp])
		return
	# tint must not be a temperature move in disguise: warm axis changes much less
	var warm_shift: float = absf(_warm(mag) - _warm(grn))
	var mag_shift: float = absf(mp - mn)
	print("WHITE_BALANCE_TINT_SMOKE: tint axis shift %.2f vs warm-axis shift %.2f" % [mag_shift, warm_shift])
	if mag_shift < warm_shift:
		_die("tint moves the warm axis more than the green-magenta axis (%.2f vs %.2f)" % [warm_shift, mag_shift])
		return

	# --- temperature direction -------------------------------------------------
	_backend.set_white_balance(3000.0, 0.0)
	var cool_k: PackedByteArray = _render()
	_backend.set_white_balance(8000.0, 0.0)
	var warm_k: PackedByteArray = _render()
	var w3: float = _warm(cool_k)
	var w8: float = _warm(warm_k)
	print("WHITE_BALANCE_TINT_SMOKE: warm measure 3000K: %.2f, 8000K: %.2f" % [w3, w8])
	if absf(w8 - w3) < 1.0:
		_die("temperature 3000 vs 8000 K did not change the warm axis")
		return
	if not (w8 > w3):
		_die("higher Kelvin should render warmer (scene light bluer): 3000K=%.2f 8000K=%.2f" % [w3, w8])
		return
	# Temperature at a fixed tint also moves the warm axis (tint kept by single setters)
	_backend.set_white_balance(3000.0, 50.0)
	_backend.set_white_balance_temperature(8000.0)  # keeps tint 50
	var t50_8000: PackedByteArray = _render()
	_backend.set_white_balance(8000.0, 50.0)
	if _render() != t50_8000:
		_die("set_white_balance_temperature() did not preserve tint")
		return
	_backend.set_white_balance(4000.0, 0.0)
	_backend.set_white_balance_tint(50.0)  # keeps kelvin 4000
	var k4000_t50: PackedByteArray = _render()
	_backend.set_white_balance(4000.0, 50.0)
	if _render() != k4000_t50:
		_die("set_white_balance_tint() did not preserve temperature")
		return

	# --- bounds and non-finite input ------------------------------------------
	_backend.set_white_balance(5500.0, 20.0)
	var before_bad: PackedByteArray = _render()
	_backend.set_white_balance(NAN, 0.0)
	_backend.set_white_balance(5500.0, INF)
	_backend.set_white_balance_tint(NAN)
	_backend.set_white_balance_temperature(INF)
	if _render() != before_bad:
		_die("non-finite input changed the render")
		return
	_backend.set_white_balance(1.0e9, 1.0e9)
	var clamped_hi: PackedByteArray = _render()
	_backend.set_white_balance(25000.0, 100.0)
	if _render() != clamped_hi:
		_die("out-of-range kelvin/tint are not clamped to 25000 K / +100")
		return
	_backend.set_white_balance(-5.0, -1.0e9)
	var clamped_lo: PackedByteArray = _render()
	_backend.set_white_balance(1667.0, -100.0)
	if _render() != clamped_lo:
		_die("out-of-range kelvin/tint are not clamped to 1667 K / -100")
		return
	# Every corner of the slider range must be accepted (not silently rejected):
	# each one changes the render relative to the previous state.
	_backend.set_white_balance(5500.0, 20.0)
	var prev: PackedByteArray = _render()
	for tint_extreme in [-100.0, 100.0]:
		for k_extreme in [1667.0, 25000.0]:
			_backend.set_white_balance(k_extreme, tint_extreme)
			var ext: PackedByteArray = _render()
			if ext.is_empty() or ext == prev:
				_die("slider corner %f K / %f tint was rejected or not applied" % [k_extreme, tint_extreme])
				return
			prev = ext

	# Forward/inverse locus maps: bounded reconstruction error over the whole range.
	var worst_k: float = 0.0
	var worst_t: float = 0.0
	var limited_n: int = 0
	var worst_loose_t: float = 0.0
	for k_rt in [1667.0, 2000.0, 2500.0, 3500.0, 3990.0, 4010.0, 5000.0, 6500.0, 10000.0, 18000.0, 25000.0]:
		for t_rt in [-100.0, -60.0, -20.0, 0.0, 20.0, 60.0, 100.0]:
			var rt: Dictionary = _backend.get_white_balance_roundtrip(k_rt, t_rt)
			if not rt.get("ok", false):
				_die("roundtrip rejected %f K / %f tint" % [k_rt, t_rt])
				return
			if rt.get("limited", false):
				# gamut-edge shrink: tint must stay on the same side, never exceed the request
				var t_lim: float = rt["tint"]
				if t_lim * t_rt < 0.0 or absf(t_lim) > absf(t_rt) + 0.5:
					_die("gamut-limited tint %f for request %f K / %f is implausible" % [t_lim, k_rt, t_rt])
					return
				limited_n += 1
				continue
			var err_k: float = absf(float(rt["temperature"]) - k_rt) / k_rt
			var err_t: float = absf(float(rt["tint"]) - t_rt)
			# Core range: strict. The 4000 K daylight/Planckian seam of darktable's locus
			# (a ~0.003 uv step) and the concave (magenta, t <= -90) side at low K, where
			# isotherms cross, make the inverse inexact; those get a loose bound.
			var loose: bool = (k_rt > 3000.0 and k_rt < 5000.0) or t_rt <= -90.0
			if loose:
				if err_k > 0.30 or err_t > 8.0:
					_die("roundtrip too far off at %s -> %s" % [str([k_rt, t_rt]), str(rt)])
					return
				worst_loose_t = maxf(worst_loose_t, err_t)
				continue
			worst_k = maxf(worst_k, err_k)
			worst_t = maxf(worst_t, err_t)
	print("WHITE_BALANCE_TINT_SMOKE: roundtrip core worst rel K error %.4f, tint error %.3f; seam/extreme tint error %.2f; %d gamut-limited points" % [worst_k, worst_t, worst_loose_t, limited_n])
	if worst_k > 0.02 or worst_t > 1.0:
		_die("locus roundtrip error too large: K %.4f tint %.3f" % [worst_k, worst_t])
		return
	print("WHITE_BALANCE_TINT_SMOKE: bounds and non-finite handling OK")

	# --- Auto white balance ----------------------------------------------------
	_backend.reset_white_balance()
	var auto_raw: Dictionary = _backend.compute_auto_white_balance()
	if not _check_auto(auto_raw, "raw"):
		return
	var auto_raw2: Dictionary = _backend.compute_auto_white_balance()
	if auto_raw2 != auto_raw:
		_die("Auto is not repeatable/cached: %s vs %s" % [str(auto_raw), str(auto_raw2)])
		return
	print("WHITE_BALANCE_TINT_SMOKE: auto raw %s" % str(auto_raw))
	# Auto must not touch the edit (query only): full and preview pipes unchanged
	if _render() != exposed_base:
		_die("compute_auto_white_balance() changed the rendered edit state")
		return
	var prev_before: PackedByteArray = _backend.render_preview(VIEW_W, VIEW_H, 0.5, 0.0, 0.0)
	_backend.compute_auto_white_balance()
	if _backend.render_preview(VIEW_W, VIEW_H, 0.5, 0.0, 0.0) != prev_before:
		_die("compute_auto_white_balance() changed the preview pipe output")
		return
	# Apply and compare: an applied Auto must visibly differ from As Shot unless it equals it
	_backend.set_white_balance(auto_raw["temperature"], auto_raw["tint"])
	var auto_render: PackedByteArray = _render()
	if auto_render.is_empty():
		_die("render after applying Auto failed")
		return
	var d_auto: float = absf(_magenta(auto_render) - _magenta(exposed_base)) + absf(_warm(auto_render) - _warm(exposed_base))
	var d_k: float = absf(float(auto_raw["temperature"]) - as_k)
	print("WHITE_BALANCE_TINT_SMOKE: auto-vs-as-shot render shift %.2f, K delta %.0f" % [d_auto, d_k])
	if d_k > 300.0 and d_auto < 0.5:
		_die("Auto differs from As Shot by %.0f K but renders identically" % d_k)
		return

	# --- image switching + image dependence -----------------------------------
	if not _backend.load_image(jpg_path):
		_die("load_image(jpg) failed")
		return
	var jpg_k: float = _backend.get_white_balance_temperature()
	var jpg_tint: float = _backend.get_white_balance_tint()
	print("WHITE_BALANCE_TINT_SMOKE: jpg as-shot %.1f K tint %.2f" % [jpg_k, jpg_tint])
	if jpg_k < 1667.0 or jpg_k > 25000.0 or not is_finite(jpg_tint):
		_die("jpg as-shot values implausible")
		return
	var jpg_base: PackedByteArray = _render()
	if jpg_base.is_empty():
		_die("jpg baseline render failed")
		return
	var auto_jpg: Dictionary = _backend.compute_auto_white_balance()
	if not _check_auto(auto_jpg, "jpg"):
		return
	print("WHITE_BALANCE_TINT_SMOKE: auto jpg %s" % str(auto_jpg))
	var dk: float = absf(float(auto_jpg["temperature"]) - float(auto_raw["temperature"]))
	var dt: float = absf(float(auto_jpg["tint"]) - float(auto_raw["tint"]))
	if dk < 20.0 and dt < 1.0:
		_die("Auto is not image dependent: raw %s, jpg %s" % [str(auto_raw), str(auto_jpg)])
		return
	_backend.set_white_balance(auto_jpg["temperature"], auto_jpg["tint"])
	if _render().is_empty():
		_die("render after applying Auto to jpg failed")
		return
	_backend.reset_white_balance()
	if _render() != jpg_base:
		_die("reset_white_balance() is not byte-exact on the jpg")
		return

	# --- synthetic cast scenes: Auto must actually neutralise the cast -----------
	var cast_path: String = ProjectSettings.globalize_path("user://wb_cast_scene.png")
	var neutral_path: String = ProjectSettings.globalize_path("user://wb_neutral_scene.png")
	if not _make_cast_image(cast_path, Vector3(1.35, 1.0, 0.65)) or not _make_cast_image(neutral_path, Vector3(1.0, 1.0, 1.0)):
		_die("could not write synthetic scenes")
		return
	var auto_scene: Dictionary = {}
	for scene in [["neutral", neutral_path], ["cast", cast_path]]:
		if not _backend.load_image(scene[1]):
			_die("load_image(%s) failed" % scene[0])
			return
		var before: PackedByteArray = _backend.render_view(VIEW_W, VIEW_H, 1.0, 0.0, 0.0)
		var sw: int = _backend.get_width()
		var sh: int = _backend.get_height()
		var chroma_before: float = _grey_chroma(before, sw, sh)
		var a: Dictionary = _backend.compute_auto_white_balance()
		if not _check_auto(a, "synthetic " + scene[0]):
			return
		auto_scene[scene[0]] = a
		_backend.set_white_balance(a["temperature"], a["tint"])
		var chroma_after: float = _grey_chroma(_backend.render_view(VIEW_W, VIEW_H, 1.0, 0.0, 0.0), sw, sh)
		print("WHITE_BALANCE_TINT_SMOKE: synthetic %s auto %s grey chroma %.2f -> %.2f" % [scene[0], str(a), chroma_before, chroma_after])
		if scene[0] == "cast":
			if chroma_before < 10.0:
				_die("synthetic cast scene has no visible cast to correct (%.2f)" % chroma_before)
				return
			if chroma_after > chroma_before * 0.4:
				_die("Auto did not neutralise the cast: grey chroma %.2f -> %.2f" % [chroma_before, chroma_after])
				return
		elif chroma_after > maxf(chroma_before * 2.0, 4.0):
			_die("Auto damaged an already neutral scene: grey chroma %.2f -> %.2f" % [chroma_before, chroma_after])
			return
	if float(auto_scene["cast"]["temperature"]) > float(auto_scene["neutral"]["temperature"]) - 800.0:
		_die("warm-cast scene should read a much lower scene temperature than the neutral scene: %s vs %s" % [str(auto_scene["cast"]), str(auto_scene["neutral"])])
		return

	# Switch back: nothing from the jpg session may leak into the raw load
	if not _backend.load_image(raw_path):
		_die("reload of raw failed")
		return
	if _render() != base:
		_die("reloaded raw does not match the original As Shot render (stale WB state)")
		return
	if absf(_backend.get_white_balance_temperature() - as_k) > 0.01 or absf(_backend.get_white_balance_tint() - as_tint) > 0.01:
		_die("as-shot getters changed across image switching")
		return
	# Auto is independent of other edits: exposure, crop and rotation must not move it
	_backend.set_exposure(3.0)
	_backend.set_crop(0.2, 0.2, 0.8, 0.8)
	_backend.set_orientation(1)
	var auto_edited: Dictionary = _backend.compute_auto_white_balance()
	if not _check_auto(auto_edited, "raw after switch"):
		return
	if absf(float(auto_edited["temperature"]) - float(auto_raw["temperature"])) > 1.0 \
			or absf(float(auto_edited["tint"]) - float(auto_raw["tint"])) > 0.05:
		_die("Auto depends on exposure/crop/orientation edits or stale cache: %s vs %s" % [str(auto_edited), str(auto_raw)])
		return

	print("WHITE_BALANCE_TINT_SMOKE: PASS")
	quit(0)
