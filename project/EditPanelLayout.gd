extends RefCounted

const Section := preload("res://CollapsibleSection.gd")
const COLOR_CONTROL_GAP := 18


# Called after Main has cached scene references and connected reset buttons.
static func build(panel: VBoxContainer) -> void:
	for node_name in ["ToneHeader", "ColorHeader", "HSep"]:
		panel.get_node(NodePath(node_name)).hide()

	var basic := _section(panel, "Basic", "BASIC", 0)
	for key in ["Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks"]:
		_move_slider(panel, basic.content, key)

	var curve := _section(panel, "ToneCurve", "TONE CURVE", 1, false)
	panel.get_node("ToneCurveHeaderRow").reparent(curve.content, false)
	panel.get_node("ToneCurveEditor").reparent(curve.content, false)

	var color := _section(panel, "Color", "COLOR", 2)
	# Segmented mode control first, then Temp, Tint, Vibrance, Saturation, with
	# the Color section's wider 18px rhythm between controls.
	color.content.add_theme_constant_override("separation", COLOR_CONTROL_GAP)
	panel.get_node("WbModeBar").reparent(color.content, false)
	for key in ["WhiteBalance", "Tint", "Vibrance", "Saturation"]:
		_move_slider(panel, color.content, key)

	var effects := _section(panel, "Effects", "EFFECTS", 3)
	_move_slider(panel, effects.content, "Dehaze")
	for section in [basic, curve, color]:
		section.add_child(HSeparator.new())


static func _section(
		panel: VBoxContainer, node_name: String, title: String,
		index: int, expanded: bool = true) -> Section:
	var section := Section.new(title, expanded)
	section.name = node_name + "Section"
	panel.add_child(section)
	panel.move_child(section, index)
	return section


static func _move_slider(panel: VBoxContainer, content: VBoxContainer, key: String) -> void:
	var label: Label = panel.get_node(NodePath(key + "Label"))
	var row: HBoxContainer = panel.get_node(NodePath(key + "Row"))
	var value_label: Label = row.get_node(NodePath(key + "ValueLabel"))
	var card := VBoxContainer.new()
	card.name = key + "Control"
	card.add_theme_constant_override("separation", 0)
	content.add_child(card)
	var title_row := HBoxContainer.new()
	title_row.name = "TitleRow"
	title_row.add_theme_constant_override("separation", 8)
	card.add_child(title_row)
	label.reparent(title_row, false)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_label.reparent(title_row, false)
	value_label.theme_type_variation = &"Muted"
	for child in row.get_children():
		if child is Button:
			child.reparent(title_row, false)
	row.reparent(card, false)
	row.custom_minimum_size.y = 22
