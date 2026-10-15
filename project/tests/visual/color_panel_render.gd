extends SceneTree

# Offscreen visual render of the isolated Color section (real scripts, real
# themes, no backend): builds the same node tree Main.tscn hands to
# EditPanelLayout, renders it in a SubViewport and saves a PNG per theme.
# Needs a real renderer, so run WITHOUT --headless:
#   Godot --path godot-poc/project --script res://tests/visual/color_panel_render.gd -- [out_dir] [--mode as_shot|auto|custom]
# Writes <out_dir>/color_panel_dark.png and color_panel_light.png (default /tmp).
# Not a *_smoke_test, so no test runner picks it up.

const Layout := preload("res://EditPanelLayout.gd")
const ModeBarScript := preload("res://WbModeBar.gd")
const GradientScript := preload("res://ColorGradientSlider.gd")
const CenterScript := preload("res://CenterOriginSlider.gd")
const Readout := preload("res://ColorReadout.gd")

const KEYS := ["Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks",
		"WhiteBalance", "Tint", "Vibrance", "Saturation", "Dehaze"]
const VIEW_SIZE := Vector2i(380, 475)
const PIXEL_SCALE := 2
const THEMES := {"dark": "res://main_theme.tres", "light": "res://light_theme.tres"}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out_dir: String = "/tmp"
	var mode: String = "custom"
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--mode" and i + 1 < args.size():
			mode = args[i + 1]
		elif not args[i].begins_with("--") and (i == 0 or args[i - 1] != "--mode"):
			out_dir = args[i]
	for theme_name in THEMES:
		var image: Image = await _render(THEMES[theme_name], mode)
		var path: String = out_dir.path_join("color_panel_%s.png" % theme_name)
		var err: int = image.save_png(path)
		print("COLOR_PANEL_RENDER: %s -> %s (%dx%d, err %d)" % [theme_name, path, image.get_width(), image.get_height(), err])
	quit(0)


func _render(theme_path: String, mode: String) -> Image:
	var viewport := SubViewport.new()
	viewport.size = VIEW_SIZE * PIXEL_SCALE
	viewport.size_2d_override = VIEW_SIZE
	viewport.size_2d_override_stretch = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)

	var shell := PanelContainer.new()
	shell.theme = load(theme_path)
	shell.theme_type_variation = &"SidePanel"
	shell.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(shell)
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	shell.add_child(margin)
	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 8)
	margin.add_child(panel)

	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["SF Mono", "Menlo", "ui-monospace", "monospace"])
	for key in ["ToneHeader", "ColorHeader", "HSep", "ToneCurveHeaderRow", "ToneCurveEditor"]:
		var placeholder := Control.new()
		placeholder.name = key
		panel.add_child(placeholder)
	var bar: HBoxContainer = ModeBarScript.new()
	bar.name = "WbModeBar"
	panel.add_child(bar)
	var readouts: Dictionary = {}
	for key in KEYS:
		var label := Label.new()
		label.name = key + "Label"
		label.text = {"WhiteBalance": "Temp"}.get(key, key)
		panel.add_child(label)
		var row := HBoxContainer.new()
		row.name = key + "Row"
		row.add_theme_constant_override("separation", 8)
		panel.add_child(row)
		var slider: HSlider
		if key in ["WhiteBalance", "Tint"]:
			slider = GradientScript.new()
		else:
			slider = CenterScript.new()
			if key in ["Vibrance", "Saturation"]:
				slider.set("amber_accent", true)
		slider.name = key + "Slider"
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(slider)
		var value := Label.new()
		value.name = key + "ValueLabel"
		value.custom_minimum_size.x = 52
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.add_theme_font_override("font", mono)
		row.add_child(value)
		var reset := Button.new()
		reset.text = "↺"
		reset.flat = true
		reset.focus_mode = Control.FOCUS_NONE
		reset.custom_minimum_size = Vector2(24, 0)
		row.add_child(reset)
		readouts[key] = [slider, value]
	var footer := OptionButton.new()
	footer.name = "EditResOptionButton"
	panel.add_child(footer)

	# Reference-like sample state: warm Temp, magenta Tint, boosted Vibrance.
	var temp: HSlider = readouts["WhiteBalance"][0]
	temp.min_value = 1667.0
	temp.max_value = 25000.0
	temp.step = 50.0
	temp.set_value_no_signal(5517.0)
	(readouts["WhiteBalance"][1] as Label).text = "5517K"
	var tint: HSlider = readouts["Tint"][0]
	tint.min_value = -100.0
	tint.max_value = 100.0
	tint.stops = PackedColorArray([Color(0.25, 0.72, 0.35), Color(0.93, 0.93, 0.93), Color(0.85, 0.25, 0.75)])
	tint.set_value_no_signal(12.0)
	for key in ["Vibrance", "Saturation", "Tint"]:
		var slider: HSlider = readouts[key][0]
		if key != "Tint":
			slider.min_value = -50.0
			slider.max_value = 50.0
		var shown: float = {"Vibrance": 25.0, "Saturation": 0.0, "Tint": 12.0}[key]
		slider.set_value_no_signal(shown)
		Readout.apply(readouts[key][1], shown)
	Layout.build(panel)
	bar.set_mode(mode)
	for section_name in ["BasicSection", "ToneCurveSection", "EffectsSection"]:
		panel.get_node(section_name).visible = false

	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = viewport.get_texture().get_image()
	viewport.queue_free()
	return image
