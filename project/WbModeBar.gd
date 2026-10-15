extends HBoxContainer
## Three equal-width toggle segments (As Shot / Auto / Custom) on a rounded
## track: the selected segment is a lighter rounded fill with semibold
## near-white text, inactive text is muted. Dark colours are the constants
## below; the light theme derives them from the HSlider track and theme fonts.

const ColorWbScript := preload("res://ColorWb.gd")

## Emitted on every click of a segment, including the already-selected one.
## set_mode() mirrors state without emitting.
signal mode_selected(mode: String)

const SEGMENTS: Array = [
	["AsShotButton", "As Shot", ColorWbScript.AS_SHOT, "Use the camera's white balance"],
	["AutoButton", "Auto", ColorWbScript.AUTO, "Estimate white balance from the image"],
	["CustomButton", "Custom", ColorWbScript.CUSTOM, "Adjust white balance manually"],
]
const SEGMENT_HEIGHT := 28.0
const CORNER_RADIUS := 10
const PILL_INSET := 2
const SEMIBOLD_EMBOLDEN := 0.5

const DARK_TRACK := Color("131315")
const DARK_SELECTED := Color("2b2b30")
const DARK_TEXT := Color("99999f")
const DARK_SELECTED_TEXT := Color("f2f2f4")

var current_mode: String = ColorWbScript.AS_SHOT
var _buttons: Dictionary = {}
var _group := ButtonGroup.new()
var _track := StyleBoxFlat.new()
var _semibold := FontVariation.new()


func _init() -> void:
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for segment in SEGMENTS:
		var button := Button.new()
		button.name = segment[0]
		button.text = segment[1]
		button.tooltip_text = segment[3]
		button.toggle_mode = true
		button.button_group = _group
		button.focus_mode = Control.FOCUS_NONE
		button.clip_text = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size = Vector2(0.0, SEGMENT_HEIGHT)
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.pressed.connect(mode_selected.emit.bind(segment[2]))
		add_child(button)
		_buttons[segment[2]] = button
	_semibold.variation_embolden = SEMIBOLD_EMBOLDEN
	set_mode(current_mode)


func _ready() -> void:
	_apply_styles()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and not _buttons.is_empty():
		_apply_styles()


func _draw() -> void:
	_track.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))


func get_button(mode: String) -> Button:
	return _buttons[mode]


## Highlights `mode` without emitting mode_selected.
func set_mode(mode: String) -> void:
	if not ColorWbScript.is_valid_mode(mode):
		return
	current_mode = mode
	for key in _buttons:
		(_buttons[key] as Button).set_pressed_no_signal(key == mode)
	_apply_selection_styles()


func set_enabled(enabled: bool) -> void:
	for button: Button in _buttons.values():
		button.disabled = not enabled


func _palette() -> Dictionary:
	var slider_track := get_theme_stylebox("slider", "HSlider") as StyleBoxFlat
	var is_dark: bool = slider_track == null or slider_track.bg_color.get_luminance() < 0.5
	if is_dark:
		return {
			"track": DARK_TRACK,
			"selected": DARK_SELECTED,
			"text": DARK_TEXT,
			"text_hover": DARK_SELECTED_TEXT,
			"selected_text": DARK_SELECTED_TEXT,
			"disabled_text": get_theme_color("font_disabled_color", "Button"),
			"hover": Color(1, 1, 1, 0.05),
		}
	var track_color: Color = slider_track.bg_color
	return {
		"track": track_color,
		"selected": track_color.lightened(0.75),
		"text": get_theme_color("font_color", "Muted"),
		"text_hover": get_theme_color("font_color", "Label"),
		"selected_text": get_theme_color("font_color", "Label"),
		"disabled_text": get_theme_color("font_disabled_color", "Button"),
		"hover": Color(0, 0, 0, 0.05),
	}


func _flat(fill: Color, border: Color = Color(0, 0, 0, 0), border_width: int = 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.set_corner_radius_all(CORNER_RADIUS)
	style.set_border_width_all(border_width)
	style.border_color = border
	style.content_margin_left = 4.0
	style.content_margin_right = 4.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	return style


func _apply_styles() -> void:
	var colors: Dictionary = _palette()
	var track_color: Color = colors["track"]
	_track = _flat(track_color)
	queue_redraw()
	var base_font: Font = get_theme_font("font", "Button")
	_semibold.base_font = base_font
	# Unselected segments are transparent so the track shows through; the
	# selected one is a lighter fill ringed in the track colour, which insets it.
	var pill: StyleBoxFlat = _flat(colors["selected"], track_color, PILL_INSET)
	for button: Button in _buttons.values():
		button.add_theme_stylebox_override("normal", _flat(Color(0, 0, 0, 0)))
		button.add_theme_stylebox_override("hover", _flat(colors["hover"]))
		button.add_theme_stylebox_override("pressed", pill)
		button.add_theme_stylebox_override("hover_pressed", pill)
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		button.add_theme_color_override("font_color", colors["text"])
		button.add_theme_color_override("font_hover_color", colors["text_hover"])
		button.add_theme_color_override("font_pressed_color", colors["selected_text"])
		button.add_theme_color_override("font_hover_pressed_color", colors["selected_text"])
		button.add_theme_color_override("font_disabled_color", colors["disabled_text"])
	_apply_selection_styles()


# Per-selection styling: the selected segment is semibold, and keeps a dimmed
# fill when disabled (a disabled button draws its `disabled` style whether or
# not it is selected).
func _apply_selection_styles() -> void:
	if _buttons.is_empty():
		return
	var colors: Dictionary = _palette()
	var dimmed_pill: StyleBoxFlat = _flat(
		(colors["selected"] as Color).lerp(colors["track"], 0.5), colors["track"], PILL_INSET)
	for key in _buttons:
		var button: Button = _buttons[key]
		var selected: bool = key == current_mode
		button.add_theme_stylebox_override("disabled", dimmed_pill if selected else _flat(Color(0, 0, 0, 0)))
		if selected and _semibold.base_font != null:
			button.add_theme_font_override("font", _semibold)
		else:
			button.remove_theme_font_override("font")
