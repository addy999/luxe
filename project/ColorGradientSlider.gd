extends HSlider
## HSlider whose track is a multi-stop colour gradient (Temp: blue-white-amber,
## Tint: green-white-magenta) with a round knob drawn on top. The native track,
## fill and grabber are suppressed and repainted in _draw().

const TRACK_HEIGHT := 8.0
const KNOB_RADIUS := 7.0
const GRABBER_WIDTH := 16  # transparent grabber icon size (2 * KNOB_RADIUS + 2)
const STRIP_WIDTH := 2.0

## Evenly spaced gradient stops, left to right (default: Temp, sky blue to
## amber through near-white).
@export var stops: PackedColorArray = PackedColorArray([
	Color("4faeef"), Color(0.93, 0.93, 0.93), Color("f0a62e")])

var _hovering: bool = false


func _ready() -> void:
	# The grabber icon is transparent but keeps its width: Slider insets the
	# track by the grabber width, and _draw() paints the knob over that spot.
	var img := Image.create(GRABBER_WIDTH, GRABBER_WIDTH, false, Image.FORMAT_RGBA8)
	var blank := ImageTexture.create_from_image(img)
	for icon_name in ["grabber", "grabber_highlight", "grabber_disabled"]:
		add_theme_icon_override(icon_name, blank)
	var empty := StyleBoxEmpty.new()
	for style_name in ["slider", "grabber_area", "grabber_area_highlight"]:
		add_theme_stylebox_override(style_name, empty)
	value_changed.connect(func(_v: float) -> void: queue_redraw())
	resized.connect(queue_redraw)
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


func _set_hover(hovering: bool) -> void:
	_hovering = hovering
	queue_redraw()


## Gradient colour at t in 0..1 across the evenly spaced stops.
func sample(t: float) -> Color:
	if stops.is_empty():
		return Color()
	if stops.size() == 1:
		return stops[0]
	var scaled: float = clampf(t, 0.0, 1.0) * float(stops.size() - 1)
	var i: int = mini(int(scaled), stops.size() - 2)
	return stops[i].lerp(stops[i + 1], scaled - float(i))


func _draw() -> void:
	var size_v: Vector2 = get_size()
	if size_v.x <= KNOB_RADIUS * 2.0 or size_v.y <= 0.0 or stops.is_empty():
		return
	var dim: float = 1.0 if editable else 0.45
	var radius: float = TRACK_HEIGHT * 0.5
	var track_y: float = (size_v.y - TRACK_HEIGHT) * 0.5
	var centre_y: float = size_v.y * 0.5

	# Track: round caps in the end colours, vertical strips between them.
	var cap_left: Color = sample(0.0)
	var cap_right: Color = sample(1.0)
	cap_left.a *= dim
	cap_right.a *= dim
	draw_circle(Vector2(radius, centre_y), radius, cap_left)
	draw_circle(Vector2(size_v.x - radius, centre_y), radius, cap_right)
	var x: float = radius
	var last: float = size_v.x - radius
	while x < last:
		var strip: float = minf(STRIP_WIDTH, last - x)
		var c: Color = sample((x + strip * 0.5) / size_v.x)
		c.a *= dim
		draw_rect(Rect2(x, track_y, strip, TRACK_HEIGHT), c)
		x += strip

	# Knob centre travels between half-grabber margins, like Slider's own grabber.
	var span: float = max_value - min_value
	var ratio: float = 0.0 if span <= 0.0 else (value - min_value) / span
	var centre := Vector2(GRABBER_WIDTH * 0.5 + ratio * (size_v.x - GRABBER_WIDTH), centre_y)
	var fill: Color = get_theme_color("font_color", "Label")
	fill.a = dim
	var ring: Color = Color(0.0, 0.0, 0.0, 0.5 * dim)
	if _hovering and editable and has_theme_color("center_fill", "HSlider"):
		ring = get_theme_color("center_fill", "HSlider")
	draw_circle(centre, KNOB_RADIUS, ring)
	draw_circle(centre, KNOB_RADIUS - 1.5, fill)
