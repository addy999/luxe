extends Control
class_name ResizeHandle

# Thin drag strip that resizes a sibling panel. Decoupled from the target via
# get/set Callables (not a direct Control reference) so owners can resize a
# private field (Filmstrip's _strip_area) without exposing it.
#
# sign convention: +1 when moving the mouse toward larger coordinates should
# GROW the target (handle sits on the target's far edge, e.g. above a
# bottom-docked strip); -1 when it should SHRINK the target (handle sits on
# the target's near edge, e.g. left of a right-docked panel).

enum Axis { HORIZONTAL, VERTICAL }

# Setter re-derives the cursor and strip thickness, so axis can flip at runtime.
@export var axis: Axis = Axis.HORIZONTAL:
	set(value):
		axis = value
		mouse_default_cursor_shape = Control.CURSOR_HSIZE if axis == Axis.HORIZONTAL else Control.CURSOR_VSIZE
		custom_minimum_size = Vector2(_THICKNESS, 0) if axis == Axis.HORIZONTAL else Vector2(0, _THICKNESS)
		queue_redraw()
var min_size: float = 0.0
var max_size: float = 0.0
var sign: float = 1.0
var get_size_cb: Callable = Callable()
var set_size_cb: Callable = Callable()

# Fired once per completed drag (mouse-up), for write-through persistence;
# callers should not persist on every motion event.
signal resize_ended(new_size: float)

const _THICKNESS: float = 6.0

var _dragging: bool = false
var _hovering: bool = false
var _drag_start_mouse: float = 0.0
var _drag_start_size: float = 0.0
var _color_line: Color = Color(1, 1, 1, 0.08)
var _color_line_active: Color = Color(0.231372549, 0.231372549, 1, 0.6)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	if has_theme_color("border", "Filmstrip"):
		_color_line = get_theme_color("border", "Filmstrip")
	if has_theme_color("accent", "Filmstrip"):
		_color_line_active = get_theme_color("accent", "Filmstrip")


func _draw() -> void:
	var active: bool = _dragging or _hovering
	var color: Color = _color_line_active if active else _color_line
	var width: float = 2.0 if active else 1.0
	if axis == Axis.HORIZONTAL:
		var x: float = size.x * 0.5
		draw_line(Vector2(x, 0.0), Vector2(x, size.y), color, width)
	else:
		var y: float = size.y * 0.5
		draw_line(Vector2(0.0, y), Vector2(size.x, y), color, width)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_start_mouse = _mouse_coord()
			_drag_start_size = get_size_cb.call()
			queue_redraw()
		elif _dragging:
			_dragging = false
			resize_ended.emit(get_size_cb.call())
			queue_redraw()
		accept_event()


func _input(event: InputEvent) -> void:
	if not _dragging or not (event is InputEventMouseMotion):
		return
	var delta: float = (_mouse_coord() - _drag_start_mouse) * sign
	set_size_cb.call(clampf(_drag_start_size + delta, min_size, max_size))


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		_hovering = true
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_hovering = false
		queue_redraw()


func _mouse_coord() -> float:
	var gm: Vector2 = get_global_mouse_position()
	return gm.x if axis == Axis.HORIZONTAL else gm.y
