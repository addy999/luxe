extends HSlider
## HSlider that paints its amber fill from a configurable origin value to the
## current knob position, instead of Godot's default left-edge fill.
## At value == origin_value, no fill is drawn (neutral grey track only).
## Used by the Edit-panel adjustment sliders (Exposure, Contrast, Highlights,
## Shadows, Blacks, Whites, Dehaze, Saturation, Vibrance, White Balance).

const CORNER_RADIUS := 2.0
const EPSILON := 0.0001

## The value the fill is anchored to (the slider's reset/default value).
## Not necessarily the geometric center (e.g. white balance's as-shot K).
@export var origin_value: float = 0.0

func _ready() -> void:
	# Replace the theme's left-origin fill styleboxes with empty ones so the
	# built-in grabber_area painting no longer draws anything; _draw() below
	# paints the center-origin fill instead. The track background ("slider"
	# stylebox) is left untouched so the grey track still comes from the theme.
	var empty_style := StyleBoxEmpty.new()
	add_theme_stylebox_override("grabber_area", empty_style)
	add_theme_stylebox_override("grabber_area_highlight", empty_style)
	value_changed.connect(_on_value_changed)
	resized.connect(queue_redraw)

func _on_value_changed(_value: float) -> void:
	queue_redraw()

## Fill color comes from the active Theme's "HSlider/colors/center_fill" entry
## (swapped between dark/light by ThemeManager). When no theme resolves
## (theme-less headless test harnesses), returns GDScript's zero default;
## such harnesses never draw the fill.
func _fill_color() -> Color:
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

	if abs(value - origin_clamped) <= EPSILON:
		return

	var left_x: float = min(origin_x, value_x)
	var right_x: float = max(origin_x, value_x)
	var fill_rect := Rect2(left_x, track_y, right_x - left_x, track_height)
	draw_rect_rounded(fill_rect, _fill_color(), CORNER_RADIUS)

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
