extends HSlider
## HSlider that paints its fill from a configurable origin value to the
## current knob position, instead of Godot's default left-edge fill.
## At value == origin_value, no fill is drawn (neutral grey track only).
## Used by the Edit-panel adjustment sliders (Exposure, Contrast, Highlights,
## Shadows, Blacks, Whites, Dehaze, Saturation, Vibrance).

const CORNER_RADIUS := 2.0
const EPSILON := 0.0001
const KNOB_RADIUS := 7.0
const ColorReadoutScript := preload("res://ColorReadout.gd")

## The value the fill is anchored to (the slider's reset/default value).
@export var origin_value: float = 0.0
## Amber variant (Color panel Vibrance/Saturation): the fill uses the theme's
## HSlider/accent_amber instead of center_fill, and the knob is drawn here
## (grey at origin_value, amber anywhere else) instead of the theme grabber.
@export var amber_accent: bool = false

func _ready() -> void:
	# Replace the theme's left-origin fill styleboxes with empty ones so the
	# built-in grabber_area painting no longer draws anything; _draw() below
	# paints the center-origin fill instead. The track background ("slider"
	# stylebox) is left untouched so the grey track still comes from the theme.
	var empty_style := StyleBoxEmpty.new()
	add_theme_stylebox_override("grabber_area", empty_style)
	add_theme_stylebox_override("grabber_area_highlight", empty_style)
	if amber_accent:
		# A transparent grabber of the original size keeps Slider's track inset
		# (and so the knob travel) unchanged while _draw() paints the knob.
		var original: Texture2D = get_theme_icon("grabber")
		var width: int = maxi(original.get_width() if original else 16, 2)
		var height: int = maxi(original.get_height() if original else 16, 2)
		var blank := ImageTexture.create_from_image(
			Image.create(width, height, false, Image.FORMAT_RGBA8))
		for icon_name in ["grabber", "grabber_highlight", "grabber_disabled"]:
			add_theme_icon_override(icon_name, blank)
	value_changed.connect(_on_value_changed)
	resized.connect(queue_redraw)

func _on_value_changed(_value: float) -> void:
	queue_redraw()

## Fill color comes from the active Theme's "HSlider/colors/center_fill" entry
## (swapped between dark/light by ThemeManager), or accent_amber for the amber
## variant. When no theme resolves (theme-less headless test harnesses),
## returns GDScript's zero default (amber variant: a fixed amber); such
## harnesses never draw the fill.
func _fill_color() -> Color:
	if amber_accent:
		return ColorReadoutScript.accent_color(self)
	if has_theme_color("center_fill", "HSlider"):
		return get_theme_color("center_fill", "HSlider")
	return Color()

func _draw() -> void:
	var track_style: StyleBox = get_theme_stylebox("slider")
	if track_style == null:
		return

	var size: Vector2 = get_size()
	# The grabber icon's width sets how much the track is inset on each side
	# so the fill edge lines up with the knob's visual center, matching how
	# Godot's own Slider::_notification positions the grabber texture.
	var grabber: Texture2D = get_theme_icon("grabber")
	var grabber_w: float = grabber.get_width() if grabber else 8.0
	var half_grabber: float = grabber_w / 2.0

	var track_height: float = track_style.get_minimum_size().y
	if track_height <= 0.0:
		track_height = size.y
	var track_y: float = (size.y - track_height) / 2.0

	var usable_w: float = size.x - grabber_w
	if usable_w <= 0.0:
		return

	var range_span: float = max_value - min_value
	if range_span <= 0.0:
		return

	var origin_clamped: float = clamp(origin_value, min_value, max_value)
	var origin_ratio: float = (origin_clamped - min_value) / range_span
	var value_ratio: float = (value - min_value) / range_span

	var origin_x: float = half_grabber + origin_ratio * usable_w
	var value_x: float = half_grabber + value_ratio * usable_w
	var neutral: bool = abs(value - origin_clamped) <= EPSILON

	if not neutral:
		var left_x: float = min(origin_x, value_x)
		var right_x: float = max(origin_x, value_x)
		var fill_rect := Rect2(left_x, track_y, right_x - left_x, track_height)
		draw_rect_rounded(fill_rect, _fill_color(), CORNER_RADIUS)

	if amber_accent:
		_draw_knob(Vector2(value_x, size.y / 2.0), neutral)

# Round knob of the amber variant: grey at neutral, amber otherwise, on a faint
# dark ring (same construction as ColorGradientSlider's knob).
func _draw_knob(centre: Vector2, neutral: bool) -> void:
	var dim: float = 1.0 if editable else 0.45
	var fill: Color = ColorReadoutScript.accent_color(self)
	if neutral:
		fill = get_theme_color("font_color", "Muted") if has_theme_color("font_color", "Muted") \
				else Color(0.6, 0.6, 0.62)
	fill.a *= dim
	draw_circle(centre, KNOB_RADIUS, Color(0.0, 0.0, 0.0, 0.5 * dim))
	draw_circle(centre, KNOB_RADIUS - 1.5, fill)

func draw_rect_rounded(rect: Rect2, color: Color, radius: float) -> void:
	# draw_rect has no built-in corner radius; approximate with a StyleBoxFlat
	# drawn via its own draw() so corners match the track's 2px radius.
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.corner_radius_top_left = int(radius)
	sb.corner_radius_top_right = int(radius)
	sb.corner_radius_bottom_left = int(radius)
	sb.corner_radius_bottom_right = int(radius)
	sb.draw(get_canvas_item(), rect)
