extends Control
class_name ToneCurveEditor

# A minimal spline editor for darktable's tonecurve module (L channel only).
# Backs DtBackend.set_tonecurve() -- see .claude/skills/add-darktable-module and
# docs/DARKTABLE_API_NOTES.md section F's tonecurve subsection.
#
# Curve space is [0,1] x [0,1] with (0,0) at the bottom-left and (1,1) at the
# top-right, matching darktable's own curve editor convention. Points are kept
# sorted by x at all times except mid-drag (see _dragging_index below).
#
# The drawn curve is a monotone cubic Hermite spline (Fritsch-Carlson tangents),
# the same interpolation family darktable's MONOTONE_HERMITE curve type uses --
# this is an independent reimplementation for preview purposes, not darktable's
# own dt_draw_curve code, so it may differ from the rendered result by a hair at
# extreme node placements. Good enough for the UI to look like what the pixel
# pipe will actually do.

signal curve_changed(points: PackedVector2Array)

const MIN_SPACING_X: float = 0.025
const MAX_NODES: int = 20
const HIT_RADIUS: float = 10.0
const POINT_RADIUS: float = 4.5
const PADDING: float = 10.0

var _color_bg: Color
var _color_border: Color
var _color_grid: Color
var _color_diagonal: Color
var _color_curve: Color
var _color_point: Color
var _color_point_selected: Color

var _points: Array[Vector2] = [Vector2(0.0, 0.0), Vector2(1.0, 1.0)]
var _dragging_index: int = -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0, 180)
	ThemeManager.theme_changed.connect(_on_theme_changed)
	_update_colors(ThemeManager.is_dark)


# Mirrors main_theme.tres/light_theme.tres's canvas_bg so the curve panel
# matches the rest of the app instead of staying hardcoded to dark mode.
func _on_theme_changed(is_dark: bool) -> void:
	_update_colors(is_dark)
	queue_redraw()


func _update_colors(is_dark: bool) -> void:
	if is_dark:
		_color_bg = Color(0.11, 0.11, 0.11, 1.0)
		_color_border = Color(0.227, 0.227, 0.227, 1.0)
		_color_grid = Color(0.227, 0.227, 0.227, 0.5)
		_color_diagonal = Color(0.4, 0.4, 0.4, 0.6)
		_color_curve = Color(0.29, 0.616, 0.878, 1.0)
		_color_point = Color(0.95, 0.95, 0.95, 1.0)
		_color_point_selected = Color(0.4, 0.702, 0.949, 1.0)
	else:
		_color_bg = Color(0.82, 0.82, 0.82, 1.0)
		_color_border = Color(0.6, 0.6, 0.6, 1.0)
		_color_grid = Color(0.6, 0.6, 0.6, 0.5)
		_color_diagonal = Color(0.35, 0.35, 0.35, 0.6)
		_color_curve = Color(0.12, 0.4, 0.65, 1.0)
		_color_point = Color(0.15, 0.15, 0.15, 1.0)
		_color_point_selected = Color(0.09, 0.3, 0.55, 1.0)


func _get_minimum_size() -> Vector2:
	return Vector2(0, 180)


# Resets to the identity curve (darktable's own default, tonecurve.c's init()):
# 2 nodes, (0,0) and (1,1). Called when a new image loads.
func reset_to_default() -> void:
	_points = [Vector2(0.0, 0.0), Vector2(1.0, 1.0)]
	_dragging_index = -1
	queue_redraw()
	curve_changed.emit(PackedVector2Array(_points))


func get_points() -> PackedVector2Array:
	return PackedVector2Array(_points)


# --- Coordinate mapping --------------------------------------------------------

func _curve_rect() -> Rect2:
	return Rect2(Vector2(PADDING, PADDING), size - Vector2(PADDING, PADDING) * 2.0)


func _curve_to_screen(p: Vector2) -> Vector2:
	var r: Rect2 = _curve_rect()
	return Vector2(r.position.x + p.x * r.size.x, r.position.y + (1.0 - p.y) * r.size.y)


func _screen_to_curve(p: Vector2) -> Vector2:
	var r: Rect2 = _curve_rect()
	var x: float = 0.0
	var y: float = 0.0
	if r.size.x > 0.0:
		x = (p.x - r.position.x) / r.size.x
	if r.size.y > 0.0:
		y = 1.0 - (p.y - r.position.y) / r.size.y
	return Vector2(clampf(x, 0.0, 1.0), clampf(y, 0.0, 1.0))


# --- Drawing --------------------------------------------------------------------

func _draw() -> void:
	var r: Rect2 = _curve_rect()
	draw_rect(Rect2(Vector2.ZERO, size), _color_bg, true)
	draw_rect(Rect2(Vector2.ZERO, size), _color_border, false, 1.0)

	# Quarter gridlines.
	for i in range(1, 4):
		var t: float = i / 4.0
		var gx: float = r.position.x + t * r.size.x
		var gy: float = r.position.y + t * r.size.y
		draw_line(Vector2(gx, r.position.y), Vector2(gx, r.position.y + r.size.y), _color_grid, 1.0)
		draw_line(Vector2(r.position.x, gy), Vector2(r.position.x + r.size.x, gy), _color_grid, 1.0)

	draw_line(_curve_to_screen(Vector2(0, 0)), _curve_to_screen(Vector2(1, 1)), _color_diagonal, 1.0)

	# Sampled spline curve.
	var samples: int = 64
	var prev: Vector2 = _curve_to_screen(Vector2(0.0, _sample_curve(0.0)))
	for i in range(1, samples + 1):
		var x: float = float(i) / float(samples)
		var cur: Vector2 = _curve_to_screen(Vector2(x, _sample_curve(x)))
		draw_line(prev, cur, _color_curve, 2.0)
		prev = cur

	# Control points.
	for i in range(_points.size()):
		var screen_pt: Vector2 = _curve_to_screen(_points[i])
		var color: Color = _color_point_selected if i == _dragging_index else _color_point
		draw_circle(screen_pt, POINT_RADIUS, color)


# --- Monotone cubic Hermite interpolation (Fritsch-Carlson) ---------------------
# Evaluates the spline through _points at a given x in [0,1]. Recomputed per-draw
# rather than cached -- _points is at most MAX_NODES (20) long, so this is cheap.

func _sample_curve(x: float) -> float:
	var n: int = _points.size()
	if n < 2:
		return x
	if x <= _points[0].x:
		return _points[0].y
	if x >= _points[n - 1].x:
		return _points[n - 1].y

	var seg: int = 0
	for i in range(n - 1):
		if x >= _points[i].x and x <= _points[i + 1].x:
			seg = i
			break

	var p0: Vector2 = _points[seg]
	var p1: Vector2 = _points[seg + 1]
	var dx: float = p1.x - p0.x
	if dx <= 0.00001:
		return p0.y

	var m: Array[float] = []
	m.resize(n)
	for i in range(n):
		if i == 0:
			m[i] = (_points[1].y - _points[0].y) / max(_points[1].x - _points[0].x, 0.00001)
		elif i == n - 1:
			m[i] = (_points[n - 1].y - _points[n - 2].y) / max(_points[n - 1].x - _points[n - 2].x, 0.00001)
		else:
			var d0: float = (_points[i].y - _points[i - 1].y) / max(_points[i].x - _points[i - 1].x, 0.00001)
			var d1: float = (_points[i + 1].y - _points[i].y) / max(_points[i + 1].x - _points[i].x, 0.00001)
			m[i] = 0.0 if d0 * d1 <= 0.0 else (d0 + d1) * 0.5

	var t: float = (x - p0.x) / dx
	var t2: float = t * t
	var t3: float = t2 * t
	var h00: float = 2.0 * t3 - 3.0 * t2 + 1.0
	var h10: float = t3 - 2.0 * t2 + t
	var h01: float = -2.0 * t3 + 3.0 * t2
	var h11: float = t3 - t2
	return h00 * p0.y + h10 * dx * m[seg] + h01 * p1.y + h11 * dx * m[seg + 1]


# --- Mouse interaction -----------------------------------------------------------

func _nearest_point_index(screen_pos: Vector2) -> int:
	var best_index: int = -1
	var best_dist: float = HIT_RADIUS
	for i in range(_points.size()):
		var d: float = _curve_to_screen(_points[i]).distance_to(screen_pos)
		if d <= best_dist:
			best_dist = d
			best_index = i
	return best_index


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if mb.double_click:
				reset_to_default()
				return
			var idx: int = _nearest_point_index(mb.position)
			if idx >= 0:
				_dragging_index = idx
			else:
				_try_add_point(_screen_to_curve(mb.position))
			queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_dragging_index = -1
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var idx2: int = _nearest_point_index(mb.position)
			if idx2 >= 0:
				_try_delete_point(idx2)
	elif event is InputEventMouseMotion and _dragging_index >= 0:
		_drag_point(_dragging_index, _screen_to_curve(event.position))


# Inserts a new node at `curve_pos`, keeping _points sorted by x. Rejects the
# add if it would land within MIN_SPACING_X of an existing node in x (mirrors
# tonecurve.c's own "don't add a node too close to others" guard, tonecurve.c:
# 1867-1886) or if MAX_NODES is already reached.
func _try_add_point(curve_pos: Vector2) -> void:
	if _points.size() >= MAX_NODES:
		return

	var insert_at: int = _points.size()
	for i in range(_points.size()):
		if curve_pos.x < _points[i].x:
			insert_at = i
			break

	if insert_at > 0 and curve_pos.x - _points[insert_at - 1].x < MIN_SPACING_X:
		return
	if insert_at < _points.size() and _points[insert_at].x - curve_pos.x < MIN_SPACING_X:
		return

	_points.insert(insert_at, curve_pos)
	_dragging_index = insert_at
	curve_changed.emit(PackedVector2Array(_points))


# Endpoints (index 0 / last) are never removed, only reset to (0,0)/(1,1) --
# mirrors tonecurve.c:1951-1957. Interior nodes are removed outright.
func _try_delete_point(index: int) -> void:
	if index == 0:
		_points[0] = Vector2(0.0, 0.0)
	elif index == _points.size() - 1:
		_points[index] = Vector2(1.0, 1.0)
	else:
		_points.remove_at(index)
	_dragging_index = -1
	queue_redraw()
	curve_changed.emit(PackedVector2Array(_points))


# Endpoints keep x locked at 0.0/1.0 (y is free); interior points are clamped
# to stay strictly between their neighbors in x rather than crossing/reordering
# past them, a simpler stand-in for tonecurve.c's sanity_check() (tonecurve.c:
# 1124-1133), which instead deletes a point that would cross a neighbor.
func _drag_point(index: int, curve_pos: Vector2) -> void:
	var y: float = clampf(curve_pos.y, 0.0, 1.0)
	if index == 0:
		_points[0] = Vector2(0.0, y)
	elif index == _points.size() - 1:
		_points[index] = Vector2(1.0, y)
	else:
		var lo: float = _points[index - 1].x + MIN_SPACING_X
		var hi: float = _points[index + 1].x - MIN_SPACING_X
		var x: float = clampf(curve_pos.x, min(lo, hi), max(lo, hi))
		_points[index] = Vector2(x, y)
	queue_redraw()
	curve_changed.emit(PackedVector2Array(_points))
