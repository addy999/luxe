extends SceneTree

const Layout := preload("res://EditPanelLayout.gd")
const KEYS := [
	"Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks",
	"WhiteBalance", "Vibrance", "Saturation", "Dehaze",
]
var _failed: bool = false
var _changes: int = 0


func _check(condition: bool, message: String) -> void:
	if not condition:
		printerr("EDIT_PANEL_SMOKE: FAIL: " + message)
		_failed = true


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var panel := VBoxContainer.new()
	panel.size.x = 350
	panel.theme = load("res://main_theme.tres")
	root.add_child(panel)
	for key in ["ToneHeader", "ColorHeader", "HSep", "ToneCurveHeaderRow", "ToneCurveEditor"]:
		var placeholder := Control.new()
		placeholder.name = key
		placeholder.custom_minimum_size.y = 30
		panel.add_child(placeholder)
	var sliders: Array[HSlider] = []
	var resets: Array[Button] = []
	for key in KEYS:
		var label := Label.new()
		label.name = key + "Label"
		label.text = key
		panel.add_child(label)
		var row := HBoxContainer.new()
		row.name = key + "Row"
		panel.add_child(row)
		var slider := HSlider.new()
		slider.name = key + "Slider"
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value = 25
		slider.value_changed.connect(func(_value: float) -> void: _changes += 1)
		row.add_child(slider)
		sliders.append(slider)
		var value := Label.new()
		value.name = key + "ValueLabel"
		value.text = "25"
		row.add_child(value)
		var reset := Button.new()
		reset.text = "↺"
		reset.pressed.connect(func() -> void: slider.value = 0)
		row.add_child(reset)
		resets.append(reset)
	var footer := OptionButton.new()
	footer.name = "EditResOptionButton"
	panel.add_child(footer)
	Layout.build(panel)
	await process_frame
	await process_frame

	var basic = panel.get_node("BasicSection")
	var curve = panel.get_node("ToneCurveSection")
	var color = panel.get_node("ColorSection")
	var effects = panel.get_node("EffectsSection")
	_check(basic.content.get_child_count() == 6, "Basic should contain six controls")
	_check(color.content.get_child_count() == 3, "Color should contain three controls")
	_check(effects.content.get_child_count() == 1, "Effects should contain Dehaze")
	for child in effects.get_children():
		_check(not child is HSeparator, "No divider should precede quick settings")
	_check(not curve.content.visible, "Tone Curve should start collapsed")
	_check(_changes == 0, "Building the layout must not emit value_changed")
	var open_height: float = panel.get_combined_minimum_size().y
	basic.header.button_pressed = false
	await process_frame
	await process_frame
	_check(not basic.content.visible, "Header toggle must collapse its content")
	_check(panel.get_combined_minimum_size().y < open_height, "Collapse must reclaim vertical space")
	_check(color.content.visible, "Collapsing Basic must not collapse Color")
	_check(_changes == 0, "Collapsing must not emit edit signals")
	for slider in sliders:
		_check(slider.value == 25, "Collapse must preserve slider values")
	basic.header.button_pressed = true
	curve.header.button_pressed = true
	await process_frame
	await process_frame
	_check(basic.content.visible and curve.content.visible, "Sections should reopen independently")
	for i in sliders.size():
		var slider: HSlider = sliders[i]
		_check(slider.size.x >= 340, "Sliders should span the panel at its minimum width")
		resets[i].pressed.emit()
		_check(slider.value == 0, "Reparenting must preserve reset connections")
	_check(_changes == KEYS.size(), "Each reset should emit exactly one edit signal")
	_check(footer.visible, "View controls must remain available")
	panel.theme = load("res://light_theme.tres")
	await process_frame
	_check(basic.header.has_theme_stylebox("hover_pressed"), "Light theme should support section headers")
	panel.free()
	if _failed:
		quit(1)
		return
	print("EDIT_PANEL_SMOKE: PASS")
	quit(0)
