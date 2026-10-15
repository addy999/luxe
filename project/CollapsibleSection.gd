extends VBoxContainer

var header: Button
var content: VBoxContainer
var _chevron: Label


func _init(title: String = "", expanded: bool = true) -> void:
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var header_margin := MarginContainer.new()
	header_margin.name = "HeaderMargin"
	header_margin.add_theme_constant_override("margin_top", 16)
	add_child(header_margin)

	header = Button.new()
	header.name = "Header"
	header.theme_type_variation = &"SectionHeader"
	header.custom_minimum_size.y = 40
	header.toggle_mode = true
	header.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	header_margin.add_child(header)

	var header_row := HBoxContainer.new()
	header_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	header_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(header_row)
	var title_label := Label.new()
	title_label.text = title
	title_label.theme_type_variation = &"GroupHeader"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(title_label)
	_chevron = Label.new()
	_chevron.theme_type_variation = &"GroupHeader"
	_chevron.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(_chevron)

	content = VBoxContainer.new()
	content.name = "Content"
	content.add_theme_constant_override("separation", 14)
	add_child(content)
	header.toggled.connect(set_expanded)
	set_expanded(expanded)


func set_expanded(expanded: bool) -> void:
	header.set_pressed_no_signal(expanded)
	content.visible = expanded
	_chevron.text = "⌄" if expanded else "›"
	header.tooltip_text = "Collapse section" if expanded else "Expand section"
