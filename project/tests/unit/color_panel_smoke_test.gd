extends SceneTree

# Backend-free Color panel tests: white-balance mode model (restore, legacy
# inference, As Shot/Auto/Custom persistence through EditStore), the segmented
# WbModeBar, the gradient sliders, and the Color section layout built by
# EditPanelLayout. Main's own wiring needs the GDExtension and is covered by
# tests/feature/color_controls_smoke_test.gd.

const ColorWb := preload("res://ColorWb.gd")
const Layout := preload("res://EditPanelLayout.gd")
const ModeBarScript := preload("res://WbModeBar.gd")
const GradientScript := preload("res://ColorGradientSlider.gd")
const Readout := preload("res://ColorReadout.gd")
const CenterScript := preload("res://CenterOriginSlider.gd")

const AS_SHOT_K: float = 5513.0
const AS_SHOT_TINT: float = 4.0
const EDIT_DIR: String = "user://edits"

var _failed: bool = false


func _check(condition: bool, message: String) -> void:
	if not condition:
		printerr("COLOR_PANEL_SMOKE: FAIL: " + message)
		_failed = true


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_modes()
	_test_legacy_and_restore()
	_test_persistence()
	await _test_readout()
	await _test_mode_bar()
	await _test_gradient_slider()
	await _test_center_slider()
	await _test_layout()
	_cleanup()
	if _failed:
		quit(1)
		return
	print("COLOR_PANEL_SMOKE: PASS")
	quit(0)


func _test_modes() -> void:
	_check(ColorWb.MODES == ["as_shot", "auto", "custom"], "mode names are the stored strings")
	_check(ColorWb.is_valid_mode("auto") and not ColorWb.is_valid_mode("daylight"), "mode validation")
	_check(not ColorWb.is_valid_mode(1) and not ColorWb.is_valid_mode(null), "non-strings are invalid modes")
	var shot: Dictionary = ColorWb.as_shot_values(AS_SHOT_K, AS_SHOT_TINT)
	_check(shot["wb_mode"] == ColorWb.AS_SHOT, "as_shot_values mode")
	_check(shot["wb_temperature"] == AS_SHOT_K and shot["wb_tint"] == AS_SHOT_TINT, "as_shot_values numbers")
	_check(shot["wb_override"] == false, "As Shot carries no override")
	# Exact camera state vs explicit correction: decided by wb_override, never by
	# comparing numbers (identical numbers can mean either).
	_check(ColorWb.is_neutral(ColorWb.AS_SHOT, true), "As Shot mode is always neutral")
	_check(ColorWb.is_neutral(ColorWb.CUSTOM, false), "Custom without an override is neutral")
	_check(ColorWb.is_neutral(ColorWb.AUTO, false), "an unresolved Auto without an override is neutral")
	_check(not ColorWb.is_neutral(ColorWb.CUSTOM, true), "Custom with an override is an explicit correction")
	_check(not ColorWb.is_neutral(ColorWb.AUTO, true), "Auto with an override is an explicit correction")


func _test_legacy_and_restore() -> void:
	# Never-edited photo: As Shot at the photo's own as-shot values.
	var fresh: Dictionary = ColorWb.resolve_saved({}, AS_SHOT_K, AS_SHOT_TINT)
	_check(fresh["wb_mode"] == ColorWb.AS_SHOT, "new photo starts As Shot")
	_check(fresh["wb_temperature"] == AS_SHOT_K and fresh["wb_tint"] == AS_SHOT_TINT,
			"new photo uses per-image as-shot values")

	# A record with no white-balance data at all (edited only other sliders).
	var other_only: Dictionary = ColorWb.resolve_saved({"exposure": 1.0}, AS_SHOT_K, AS_SHOT_TINT)
	_check(other_only["wb_mode"] == ColorWb.AS_SHOT, "record without WB keys stays As Shot")

	_check(fresh["wb_override"] == false, "new photo has no override")

	# Legacy temperature-only record: Custom with an override and tint 0 (what
	# it was rendered with), whether or not the temperature matches as-shot.
	var changed: Dictionary = ColorWb.resolve_saved({"wb_temperature": 7000.0}, AS_SHOT_K, AS_SHOT_TINT)
	_check(changed["wb_mode"] == ColorWb.CUSTOM and changed["wb_override"] == true, "legacy changed temperature restores Custom + override")
	_check(changed["wb_temperature"] == 7000.0 and changed["wb_tint"] == 0.0,
			"legacy temperature kept, tint 0 not as-shot tint")
	var same: Dictionary = ColorWb.resolve_saved({"wb_temperature": AS_SHOT_K}, AS_SHOT_K, AS_SHOT_TINT)
	_check(same["wb_mode"] == ColorWb.CUSTOM and same["wb_override"] == true,
			"legacy record at exactly the as-shot temperature still keeps its forced correction")
	_check(same["wb_temperature"] == AS_SHOT_K and same["wb_tint"] == 0.0, "legacy as-shot-temperature record keeps tint 0")

	# Small manual changes are real overrides (no fuzzy matching to as-shot).
	var near: Dictionary = ColorWb.resolve_saved(
		{"wb_mode": "custom", "wb_override": true, "wb_temperature": AS_SHOT_K + 10.0, "wb_tint": AS_SHOT_TINT + 0.2},
		AS_SHOT_K, AS_SHOT_TINT)
	_check(near["wb_override"] == true and near["wb_temperature"] == AS_SHOT_K + 10.0 and near["wb_tint"] == AS_SHOT_TINT + 0.2,
			"a tiny stored Temp/Tint change stays an override with its exact values")

	# Custom selected without an override (Custom click, Vibrance edits) stays
	# Custom on reopen and restores the exact as-shot state.
	var plain_custom: Dictionary = ColorWb.resolve_saved(
		{"wb_mode": "custom", "wb_override": false, "wb_temperature": 1234.0, "wb_tint": 9.0}, AS_SHOT_K, AS_SHOT_TINT)
	_check(plain_custom["wb_mode"] == ColorWb.CUSTOM and plain_custom["wb_override"] == false, "Custom without override reopens Custom, no override")
	_check(plain_custom["wb_temperature"] == AS_SHOT_K and plain_custom["wb_tint"] == AS_SHOT_TINT, "no-override Custom restores as-shot values")

	# New-format records missing the bool: infer from the mode.
	_check(ColorWb.resolve_saved({"wb_mode": "as_shot"}, AS_SHOT_K, AS_SHOT_TINT)["wb_override"] == false, "missing bool: As Shot infers false")
	_check(ColorWb.resolve_saved({"wb_mode": "auto", "wb_temperature": 4000.0}, AS_SHOT_K, AS_SHOT_TINT)["wb_override"] == true, "missing bool: Auto infers true")
	_check(ColorWb.resolve_saved({"wb_mode": "custom", "wb_temperature": 4000.0}, AS_SHOT_K, AS_SHOT_TINT)["wb_override"] == true, "missing bool: Custom infers true")
	# A non-bool override value is ignored like a missing one.
	_check(ColorWb.resolve_saved({"wb_mode": "custom", "wb_override": "yes", "wb_temperature": 4000.0}, AS_SHOT_K, AS_SHOT_TINT)["wb_override"] == true,
			"non-bool override falls back to inference")

	# Saved modes win and restore their values verbatim.
	var auto_rec: Dictionary = ColorWb.resolve_saved(
		{"wb_mode": "auto", "wb_temperature": 4300.0, "wb_tint": -12.5}, AS_SHOT_K, AS_SHOT_TINT)
	_check(auto_rec["wb_mode"] == ColorWb.AUTO, "saved Auto mode restored")
	_check(auto_rec["wb_temperature"] == 4300.0 and auto_rec["wb_tint"] == -12.5, "saved Auto values restored")
	var custom_rec: Dictionary = ColorWb.resolve_saved(
		{"wb_mode": "custom", "wb_override": true, "wb_temperature": AS_SHOT_K, "wb_tint": 0.0}, AS_SHOT_K, AS_SHOT_TINT)
	_check(custom_rec["wb_mode"] == ColorWb.CUSTOM and custom_rec["wb_tint"] == 0.0 and custom_rec["wb_override"] == true,
			"saved Custom override keeps exact values even when they equal as-shot")

	# As Shot always restores the current as-shot defaults, not stale numbers.
	var stale: Dictionary = ColorWb.resolve_saved(
		{"wb_mode": "as_shot", "wb_temperature": 9999.0, "wb_tint": 50.0}, AS_SHOT_K, AS_SHOT_TINT)
	_check(stale["wb_temperature"] == AS_SHOT_K and stale["wb_tint"] == AS_SHOT_TINT,
			"As Shot restores as-shot defaults")

	# Garbage mode falls back to inference.
	var bad: Dictionary = ColorWb.resolve_saved({"wb_mode": "sepia"}, AS_SHOT_K, AS_SHOT_TINT)
	_check(bad["wb_mode"] == ColorWb.AS_SHOT, "invalid mode with no temperature is As Shot")


func _test_persistence() -> void:
	var key: String = EditStore.edit_key("COLOR_TEST.ARW", "colorhash")
	var params: Dictionary = {
		"vibrance": 40.0,
		"wb_temperature": 4300.0,
		"wb_tint": -12.5,
		"wb_mode": ColorWb.AUTO,
		"wb_override": true,
		"crop": Rect2(0, 0, 1, 1),
	}
	var meta: Dictionary = {"file_name": "COLOR_TEST.ARW", "thumb_hash": "colorhash", "updated_at": 1}
	_check(EditStore.save(key, params, meta), "save with wb_mode/wb_tint")
	var loaded: Dictionary = EditStore.load(key)
	_check(loaded.get("wb_mode", "") == "auto", "wb_mode string round-trips")
	_check(is_equal_approx(float(loaded.get("wb_tint", 0.0)), -12.5), "wb_tint round-trips")
	var restored: Dictionary = ColorWb.resolve_saved(loaded, AS_SHOT_K, AS_SHOT_TINT)
	_check(loaded.get("wb_override", null) is bool and loaded["wb_override"] == true, "wb_override bool round-trips as a bool")
	_check(restored["wb_override"] == true, "override restored from disk")
	_check(restored["wb_mode"] == ColorWb.AUTO, "Auto mode restored from disk")
	_check(restored["wb_temperature"] == 4300.0 and restored["wb_tint"] == -12.5,
			"Auto values restored from disk without recompute")

	# Mode participates in the render signature (a mode-only change is a change).
	var other: Dictionary = params.duplicate()
	other["wb_mode"] = ColorWb.CUSTOM
	_check(EditStore.params_signature(params) != EditStore.params_signature(other),
			"wb_mode affects params_signature")
	var other_override: Dictionary = params.duplicate()
	other_override["wb_override"] = false
	_check(EditStore.params_signature(params) != EditStore.params_signature(other_override),
			"wb_override affects params_signature")
	var other_tint: Dictionary = params.duplicate()
	other_tint["wb_tint"] = 3.0
	_check(EditStore.params_signature(params) != EditStore.params_signature(other_tint),
			"wb_tint affects params_signature")

	# Older record on disk: temperature only, no wb_mode/wb_tint.
	var legacy_key: String = EditStore.edit_key("LEGACY.ARW", "legacyhash")
	_check(EditStore.save(legacy_key, {"wb_temperature": 7000.0, "exposure": 0.5}, meta), "save legacy-shaped record")
	var legacy_loaded: Dictionary = EditStore.load(legacy_key)
	_check(not legacy_loaded.has("wb_mode") and not legacy_loaded.has("wb_tint"), "legacy record has no new keys")
	var legacy_restored: Dictionary = ColorWb.resolve_saved(legacy_loaded, AS_SHOT_K, AS_SHOT_TINT)
	_check(legacy_restored["wb_mode"] == ColorWb.CUSTOM and legacy_restored["wb_tint"] == 0.0 and legacy_restored["wb_override"] == true,
			"legacy record restores Custom + override with tint 0")

	# Custom selected without an override survives a save/load round trip.
	var plain_key: String = EditStore.edit_key("PLAIN.ARW", "plainhash")
	_check(EditStore.save(plain_key, {"wb_mode": "custom", "wb_override": false, "wb_temperature": AS_SHOT_K,
			"wb_tint": AS_SHOT_TINT, "vibrance": 30.0}, meta), "save Custom without override")
	var plain_loaded: Dictionary = EditStore.load(plain_key)
	_check(plain_loaded.get("wb_override", null) == false, "false override round-trips")
	var plain_restored: Dictionary = ColorWb.resolve_saved(plain_loaded, AS_SHOT_K, AS_SHOT_TINT)
	_check(plain_restored["wb_mode"] == ColorWb.CUSTOM and plain_restored["wb_override"] == false,
			"Custom + Vibrance-only edit reopens Custom with no override")


func _test_readout() -> void:
	_check(Readout.signed_text(12.4) == "+12", "positive readout is signed")
	_check(Readout.signed_text(-7.6) == "-8", "negative readout is signed")
	_check(Readout.signed_text(0.2) == "0" and Readout.signed_text(-0.4) == "0", "neutral readout is a bare 0")
	var holder := Control.new()
	holder.theme = load("res://main_theme.tres")
	root.add_child(holder)
	var label := Label.new()
	label.theme_type_variation = &"Muted"
	holder.add_child(label)
	await process_frame
	Readout.apply(label, 0.0)
	_check(label.text == "0" and not label.has_theme_color_override("font_color"), "zero keeps the muted colour")
	Readout.apply(label, 25.0)
	_check(label.text == "+25" and label.has_theme_color_override("font_color"), "non-zero uses the amber accent")
	var amber: Color = label.get_theme_color("font_color")
	_check(amber.is_equal_approx(Color(0.941, 0.651, 0.18)), "dark theme accent is the reference amber #f0a62e")
	holder.theme = load("res://light_theme.tres")
	await process_frame
	Readout.refresh(label)
	_check(label.get_theme_color("font_color") != amber, "accent follows the light theme")
	Readout.apply(label, -3.0)
	_check(label.text == "-3" and label.has_theme_color_override("font_color"), "negative values use the accent too")
	Readout.apply(label, 0.0)
	_check(not label.has_theme_color_override("font_color"), "returning to zero clears the accent")
	holder.free()


func _test_mode_bar() -> void:
	var bar: HBoxContainer = ModeBarScript.new()
	bar.size.x = 330
	bar.theme = load("res://main_theme.tres")
	root.add_child(bar)
	await process_frame
	await process_frame
	var names: Array[String] = []
	for child in bar.get_children():
		names.append(child.name)
	_check(names == ["AsShotButton", "AutoButton", "CustomButton"], "bar has three ordered segments")
	var widths: Array[float] = []
	for child: Button in bar.get_children():
		widths.append(child.size.x)
		_check(child.toggle_mode, "segments are toggle buttons")
	_check(absf(widths[0] - widths[1]) <= 1.0 and absf(widths[1] - widths[2]) <= 1.0,
			"segments are equal width: %s" % str(widths))
	_check(bar.current_mode == "as_shot" and bar.get_button("as_shot").button_pressed, "defaults to As Shot")

	var picked: Array[String] = []
	bar.mode_selected.connect(func(mode: String) -> void: picked.append(mode))
	bar.set_mode("auto")
	_check(picked.is_empty(), "set_mode must not emit mode_selected")
	_check(bar.get_button("auto").button_pressed and not bar.get_button("as_shot").button_pressed,
			"set_mode highlights exactly one segment")
	bar.get_button("custom").pressed.emit()
	bar.get_button("custom").pressed.emit()
	bar.get_button("auto").pressed.emit()
	_check(picked == ["custom", "custom", "auto"], "every click emits, including re-clicking: %s" % str(picked))
	bar.set_mode("bogus")
	_check(bar.current_mode == "auto", "invalid mode is ignored")

	bar.set_enabled(false)
	for child: Button in bar.get_children():
		_check(child.disabled, "set_enabled(false) disables every segment")
	bar.set_enabled(true)
	for child: Button in bar.get_children():
		_check(not child.disabled, "set_enabled(true) re-enables every segment")

	# Dark theme (reference): track #131315 is darker than the selected fill
	# #2b2b30; unselected segments are transparent so the track shows through;
	# every segment's selected state is a fully rounded fill; inactive text
	# #99999f regular, selected near-white semibold.
	var pill_dark := (bar.get_button("auto") as Button).get_theme_stylebox("pressed") as StyleBoxFlat
	var idle_dark := (bar.get_button("auto") as Button).get_theme_stylebox("normal") as StyleBoxFlat
	_check(pill_dark != null and pill_dark.bg_color == Color("2b2b30"), "dark selected fill is #2b2b30")
	_check(pill_dark.border_color == Color("131315") and pill_dark.border_width_left > 0, "pill is inset by a #131315 ring")
	_check(Color("131315").get_luminance() < pill_dark.bg_color.get_luminance(), "track is darker than the selected fill")
	_check(ModeBarScript.CORNER_RADIUS == 10, "outer radius is ~10px")
	for mode in ["as_shot", "auto", "custom"]:
		var pressed := (bar.get_button(mode) as Button).get_theme_stylebox("pressed") as StyleBoxFlat
		_check(pressed.corner_radius_top_left == 10 and pressed.corner_radius_top_right == 10
				and pressed.corner_radius_bottom_left == 10 and pressed.corner_radius_bottom_right == 10,
				"%s selected fill is fully rounded" % mode)
	_check(idle_dark.bg_color.a == 0.0, "unselected segments are transparent")
	var idle_button := bar.get_button("as_shot") as Button
	_check(idle_button.get_theme_color("font_color") == Color("99999f"), "inactive text is #99999f")
	_check((bar.get_button("auto") as Button).get_theme_color("font_pressed_color").get_luminance() > 0.9, "selected text is near-white")
	_check(not idle_button.has_theme_font_override("font"), "inactive text keeps the regular weight")
	_check((bar.get_button("auto") as Button).has_theme_font_override("font"), "selected text is semibold")
	var semibold := (bar.get_button("auto") as Button).get_theme_font("font") as FontVariation
	_check(semibold != null and semibold.variation_embolden > 0.0, "selected font is emboldened")
	bar.set_mode("custom")
	_check(not (bar.get_button("auto") as Button).has_theme_font_override("font")
			and (bar.get_button("custom") as Button).has_theme_font_override("font"), "semibold follows the selection")
	bar.set_mode("auto")
	var disabled_selected := (bar.get_button("auto") as Button).get_theme_stylebox("disabled") as StyleBoxFlat
	var disabled_other := (bar.get_button("custom") as Button).get_theme_stylebox("disabled") as StyleBoxFlat
	_check(disabled_selected.bg_color.a > 0.0 and disabled_other.bg_color.a == 0.0, "disabled bar keeps a dimmed selected pill")
	bar.set_mode("custom")
	disabled_selected = (bar.get_button("custom") as Button).get_theme_stylebox("disabled") as StyleBoxFlat
	_check(disabled_selected.bg_color.a > 0.0, "disabled pill follows the selected segment")
	bar.theme = load("res://light_theme.tres")
	await process_frame
	var track_light: Color = (bar.get_theme_stylebox("slider", "HSlider") as StyleBoxFlat).bg_color
	var pill_light := (bar.get_button("auto") as Button).get_theme_stylebox("pressed") as StyleBoxFlat
	_check(pill_light.bg_color.get_luminance() > track_light.get_luminance() and pill_light.bg_color != pill_dark.bg_color,
			"light theme mirrors the layering: selected fill lighter than the track")
	_check(pill_light.border_color == track_light, "light pill ring matches the light track")
	bar.free()


func _test_gradient_slider() -> void:
	var slider: HSlider = GradientScript.new()
	slider.min_value = 1667.0
	slider.max_value = 25000.0
	slider.step = 50.0
	slider.custom_minimum_size = Vector2(300, 22)
	slider.theme = load("res://main_theme.tres")
	root.add_child(slider)
	var changes: Array[float] = []
	slider.value_changed.connect(func(v: float) -> void: changes.append(v))
	await process_frame
	await process_frame
	var blue: Color = slider.sample(0.0)
	var mid: Color = slider.sample(0.5)
	var amber: Color = slider.sample(1.0)
	_check(blue.is_equal_approx(Color("4faeef")), "Temp starts sky blue #4faeef")
	_check(amber.is_equal_approx(Color("f0a62e")), "Temp ends amber #f0a62e")
	_check(absf(mid.r - mid.g) < 0.05 and absf(mid.g - mid.b) < 0.05 and mid.r > 0.8, "midpoint is near white")
	_check(slider.sample(-1.0) == slider.sample(0.0) and slider.sample(2.0) == slider.sample(1.0),
			"sample clamps outside 0..1")
	# Tint stops as set in Main.tscn: yellow-green #86b546, white, pink #db1665.
	slider.stops = PackedColorArray([Color(0.525, 0.710, 0.275), Color(0.93, 0.93, 0.93), Color(0.859, 0.086, 0.396)])
	_check(slider.sample(0.0).is_equal_approx(Color("86b546")) or absf(slider.sample(0.0).g - 0.710) < 0.01, "tint left end is yellow-green")
	_check(absf(slider.sample(1.0).r - 0.859) < 0.01 and slider.sample(1.0).g < 0.15, "tint right end is pink")
	slider.set_value_no_signal(5000.0)
	_check(changes.is_empty(), "set_value_no_signal does not emit")
	slider.editable = false
	await process_frame
	slider.theme = load("res://light_theme.tres")
	slider.editable = true
	await process_frame
	slider.value = 6000.0
	_check(changes.size() == 1, "user-style value change emits exactly once")
	slider.free()


func _test_center_slider() -> void:
	var holder := VBoxContainer.new()
	holder.theme = load("res://main_theme.tres")
	root.add_child(holder)
	var amber_slider: HSlider = CenterScript.new()
	amber_slider.amber_accent = true
	var plain: HSlider = CenterScript.new()
	for slider in [amber_slider, plain]:
		slider.min_value = -50.0
		slider.max_value = 50.0
		slider.custom_minimum_size = Vector2(300, 22)
		holder.add_child(slider)
	await process_frame
	await process_frame
	_check(amber_slider._fill_color().is_equal_approx(Color(0.941, 0.651, 0.18)), "Vibrance/Saturation fill is amber in the dark theme")
	_check(plain._fill_color().is_equal_approx(Color(0.23137255, 0.23137255, 1.0)), "other sliders keep the theme accent fill")
	_check(amber_slider.has_theme_icon_override("grabber") and not plain.has_theme_icon_override("grabber"),
			"only the amber variant replaces the theme grabber")
	var grabber_image: Image = amber_slider.get_theme_icon("grabber").get_image()
	_check(grabber_image.get_pixel(1, 1).a == 0.0, "replaced grabber is transparent (the knob is drawn in _draw)")
	_check(amber_slider.get_theme_icon("grabber").get_width() >= 8, "replaced grabber keeps a usable width")
	amber_slider.value = 20.0
	plain.value = 20.0
	await process_frame
	amber_slider.value = 0.0
	amber_slider.editable = false
	await process_frame
	amber_slider.editable = true
	holder.theme = load("res://light_theme.tres")
	await process_frame
	_check(amber_slider._fill_color().is_equal_approx(Color(0.722, 0.471, 0.102)), "amber fill follows the light theme")
	holder.free()


func _test_layout() -> void:
	const KEYS := ["Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks",
			"WhiteBalance", "Tint", "Vibrance", "Saturation", "Dehaze"]
	var panel := VBoxContainer.new()
	panel.size.x = 350
	panel.theme = load("res://main_theme.tres")
	root.add_child(panel)
	for key in ["ToneHeader", "ColorHeader", "HSep", "ToneCurveHeaderRow", "ToneCurveEditor"]:
		var placeholder := Control.new()
		placeholder.name = key
		panel.add_child(placeholder)
	var bar: HBoxContainer = ModeBarScript.new()
	bar.name = "WbModeBar"
	panel.add_child(bar)
	var sliders: Dictionary = {}
	for key in KEYS:
		var label := Label.new()
		label.name = key + "Label"
		panel.add_child(label)
		var row := HBoxContainer.new()
		row.name = key + "Row"
		panel.add_child(row)
		var slider: HSlider = GradientScript.new() if key in ["WhiteBalance", "Tint"] else HSlider.new()
		slider.name = key + "Slider"
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(slider)
		sliders[key] = slider
		var value := Label.new()
		value.name = key + "ValueLabel"
		row.add_child(value)
	var footer := OptionButton.new()
	footer.name = "EditResOptionButton"
	panel.add_child(footer)
	Layout.build(panel)
	await process_frame
	await process_frame

	var color = panel.get_node("ColorSection")
	var order: Array[String] = []
	for child in color.content.get_children():
		order.append(child.name)
	_check(order == ["WbModeBar", "WhiteBalanceControl", "TintControl", "VibranceControl", "SaturationControl"],
			"Color order is mode bar, Temp, Tint, Vibrance, Saturation: %s" % str(order))
	_check(is_instance_valid(bar) and bar.get_parent() == color.content, "reparented bar keeps its node")
	_check(is_instance_valid(sliders["Tint"]) and sliders["Tint"].is_inside_tree(),
			"reparented Tint slider reference stays valid")
	_check(color.content.get_theme_constant("separation") == 18, "Color controls sit on an 18px rhythm")
	_check(panel.get_node("BasicSection").content.get_theme_constant("separation") == 14, "other sections keep their 14px rhythm")
	_check(color.content.visible, "Color section starts expanded")
	color.header.button_pressed = false
	await process_frame
	await process_frame
	_check(not color.content.visible, "Color section still collapses")
	_check(panel.get_node("BasicSection").content.visible, "Collapsing Color leaves Basic open")
	color.header.button_pressed = true
	await process_frame
	for child: Button in bar.get_children():
		_check(child.size.x > 0.0, "segments keep a width after the Color section reopens")
	var hit_width: float = (sliders["Tint"] as HSlider).size.x
	_check(hit_width >= 300.0, "Tint spans the panel: %f" % hit_width)
	panel.theme = load("res://light_theme.tres")
	await process_frame
	_check(color.header.has_theme_stylebox("hover_pressed"), "light theme still styles the Color header")
	panel.free()


func _cleanup() -> void:
	var dir: DirAccess = DirAccess.open(EDIT_DIR)
	if dir == null:
		return
	for sub in dir.get_directories():
		var shard: DirAccess = DirAccess.open(EDIT_DIR.path_join(sub))
		for file_name in shard.get_files():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(EDIT_DIR.path_join(sub).path_join(file_name)))
