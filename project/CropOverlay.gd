extends Control

# Interactive crop editor over the image's TextureRect; Main.gd owns the
# authoritative _params["crop"], this widget only edits and signals back.
# The box is in normalized image fractions (darktable clipping's cx/cy/cw/ch
# edges); while open it swallows mouse input from pan/zoom below.

const _MIN_SIZE: float = 0.02      # smallest allowed box, as image fraction
# Grab tolerances in px (inside an edge / outside it / at corners).
const _HANDLE_GRAB: float = 22.0
const _HANDLE_OUTER: float = 24.0
const _CORNER_GRAB: float = 26.0
const _GRID: int = 3               # rule-of-thirds grid lines per axis

# Hit-test ids.
enum Handle { NONE, MOVE, TL, TR, BL, BR, TOP, BOTTOM, LEFT, RIGHT }

var _rect := Rect2(0, 0, 1, 1)     # working copy while editing
var _orig := Rect2(0, 0, 1, 1)     # what to restore on cancel
var _drag: int = Handle.NONE
var _drag_start_mouse := Vector2.ZERO
var _drag_start_rect := Rect2()

# Host TextureRect, for re-syncing on re-layout.
var _host: TextureRect = null

# Theme colors, pushed by Main.gd via apply_theme().
var _line_color := Color.WHITE
var _dim_color := Color(0, 0, 0, 0.6)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


# Builds the Done/Cancel bar, floating on the clipping pane (not the overlay).
static func build_bar(pane: Control) -> HBoxContainer:
	var bar := PanelContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -52.0
	bar.offset_bottom = -8.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pane.add_child(bar)
	var bar_h := HBoxContainer.new()
	bar_h.alignment = BoxContainer.ALIGNMENT_CENTER
	bar_h.add_theme_constant_override("separation", 10)
	bar.add_child(bar_h)
	return bar_h


func apply_theme(is_dark: bool) -> void:
	_line_color = Color(1, 1, 1, 0.95) if is_dark else Color(0.1, 0.1, 0.1, 0.9)
	_dim_color = Color(0, 0, 0, 0.6) if is_dark else Color(1, 1, 1, 0.55)
	queue_redraw()


# Open over the host with the crop to resume editing.
func open(host: TextureRect, rect: Rect2) -> void:
	_orig = rect
	_rect = rect
	_host = host
	host.add_child(self)
	host.resized.connect(_sync_rect)
	visible = true
	_sync_rect()


# Re-derive position/size from the host's texture and stretch mode.
func _sync_rect() -> void:
	if _host == null:
		return
	var img_rect := Rect2(Vector2.ZERO, _host.size)
	var tex: Texture2D = _host.texture
	if tex != null and _host.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED:
		var tex_size := tex.get_size()
		var fit_scale: float = min(_host.size.x / tex_size.x, _host.size.y / tex_size.y)
		if fit_scale > 0.0 and tex_size.x > 0.0 and tex_size.y > 0.0:
			var drawn := tex_size * fit_scale
			img_rect = Rect2((_host.size - drawn) * 0.5, drawn)
	position = img_rect.position
	size = img_rect.size
	queue_redraw()


func close() -> void:
	if _host != null:
		if _host.resized.is_connected(_sync_rect):
			_host.resized.disconnect(_sync_rect)
		_host.remove_child(self)


# Main.gd's Done button reads this at click time so it commits the latest state.
func get_rect_normalized() -> Rect2:
	return _rect


# Called by Main.gd when the texture's dimensions change (no texture_changed signal).
func sync_to_texture() -> void:
	_sync_rect()


func _draw() -> void:
	var box := _screen_rect()
	# Dim everything outside the crop box.
	var s := size
	draw_rect(Rect2(0, 0, s.x, box.position.y), _dim_color)
	draw_rect(Rect2(0, box.end.y, s.x, s.y - box.end.y), _dim_color)
	draw_rect(Rect2(0, box.position.y, box.position.x, box.size.y), _dim_color)
	draw_rect(Rect2(box.end.x, box.position.y, s.x - box.end.x, box.size.y), _dim_color)
	# Frame + rule-of-thirds grid.
	draw_rect(box, _line_color, false, 1.5)
	for i in range(1, _GRID):
		var fx := box.position.x + box.size.x * float(i) / float(_GRID)
		var fy := box.position.y + box.size.y * float(i) / float(_GRID)
		draw_line(Vector2(fx, box.position.y), Vector2(fx, box.end.y), _line_color, 0.75)
		draw_line(Vector2(box.position.x, fy), Vector2(box.end.x, fy), _line_color, 0.75)
	# Corner handles, clamped in (half outside the box so a flush crop stays grabbable).
	var handle_span: Vector2 = Vector2(maxf(size.x - 8.0, 0.0), maxf(size.y - 8.0, 0.0))

	for pos: Vector2 in [box.position, Vector2(box.end.x, box.position.y),
			Vector2(box.position.x, box.end.y), box.end]:
		var handle: Rect2 = Rect2(pos - Vector2.ONE * 4.0, Vector2(8, 8))
		handle.position = handle.position.clamp(Vector2.ZERO, handle_span)
		draw_rect(handle, _line_color, true)


# Normalized rect -> screen px rect within this overlay.
func _screen_rect() -> Rect2:
	return Rect2(_rect.position * size, _rect.size * size)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag = _hit_test(event.position)
			if _drag != Handle.NONE:
				_drag_start_mouse = event.position
				_drag_start_rect = _rect
			accept_event()
		else:
			_drag = Handle.NONE
			accept_event()
	elif event is InputEventMouseMotion and _drag != Handle.NONE:
		_apply_drag(event.position)
		accept_event()


func _hit_test(p: Vector2) -> int:
	var box := _screen_rect()
	# Corners first (they sit inside both edge bands), then edges, then inside.
	for pair: Array in [
		[box.position, Handle.TL], [Vector2(box.end.x, box.position.y), Handle.TR],
		[Vector2(box.position.x, box.end.y), Handle.BL], [box.end, Handle.BR]]:
		if p.distance_to(pair[0]) <= _CORNER_GRAB:
			return pair[1]
	# Edge bands: _HANDLE_GRAB px inside, _HANDLE_OUTER px outside; corners own diagonals.
	var on_left: bool = p.x >= box.position.x - _HANDLE_OUTER \
		and p.x <= box.position.x + _HANDLE_GRAB \
		and p.y >= box.position.y and p.y <= box.end.y
	var on_right: bool = p.x <= box.end.x + _HANDLE_OUTER \
		and p.x >= box.end.x - _HANDLE_GRAB \
		and p.y >= box.position.y and p.y <= box.end.y
	var on_top: bool = p.y >= box.position.y - _HANDLE_OUTER \
		and p.y <= box.position.y + _HANDLE_GRAB \
		and p.x >= box.position.x and p.x <= box.end.x
	var on_bottom: bool = p.y <= box.end.y + _HANDLE_OUTER \
		and p.y >= box.end.y - _HANDLE_GRAB \
		and p.x >= box.position.x and p.x <= box.end.x
	if on_top and on_left: return Handle.TL
	if on_top and on_right: return Handle.TR
	if on_bottom and on_left: return Handle.BL
	if on_bottom and on_right: return Handle.BR
	if on_left: return Handle.LEFT
	if on_right: return Handle.RIGHT
	if on_top: return Handle.TOP
	if on_bottom: return Handle.BOTTOM
	if box.has_point(p): return Handle.MOVE
	return Handle.NONE


# Reuse the drag hit-test so the cursor advertises the action a press would start.
func _get_cursor_shape(p: Vector2) -> int:
	match _hit_test(p):
		Handle.TL, Handle.BR:
			return Control.CURSOR_FDIAGSIZE
		Handle.TR, Handle.BL:
			return Control.CURSOR_BDIAGSIZE
		Handle.LEFT, Handle.RIGHT:
			return Control.CURSOR_HSIZE
		Handle.TOP, Handle.BOTTOM:
			return Control.CURSOR_VSIZE
		Handle.MOVE:
			return Control.CURSOR_MOVE
		_:
			return Control.CURSOR_ARROW


# All math happens in normalized space so behavior is zoom-independent.
func _apply_drag(mouse: Vector2) -> void:
	var delta := (mouse - _drag_start_mouse) / size
	var r := _drag_start_rect
	match _drag:
		Handle.MOVE:
			var off := delta
			off.x = clampf(off.x, -r.position.x, 1.0 - r.end.x)
			off.y = clampf(off.y, -r.position.y, 1.0 - r.end.y)
			_rect = Rect2(r.position + off, r.size)
		Handle.LEFT:
			r.position.x = clampf(r.position.x + delta.x, 0.0, r.end.x - _MIN_SIZE)
			_rect = r
		Handle.RIGHT:
			r.end.x = clampf(r.end.x + delta.x, r.position.x + _MIN_SIZE, 1.0)
			_rect = r
		Handle.TOP:
			r.position.y = clampf(r.position.y + delta.y, 0.0, r.end.y - _MIN_SIZE)
			_rect = r
		Handle.BOTTOM:
			r.end.y = clampf(r.end.y + delta.y, r.position.y + _MIN_SIZE, 1.0)
			_rect = r
		Handle.TL:
			r.position.x = clampf(r.position.x + delta.x, 0.0, r.end.x - _MIN_SIZE)
			r.position.y = clampf(r.position.y + delta.y, 0.0, r.end.y - _MIN_SIZE)
			_rect = r
		Handle.TR:
			r.end.x = clampf(r.end.x + delta.x, r.position.x + _MIN_SIZE, 1.0)
			r.position.y = clampf(r.position.y + delta.y, 0.0, r.end.y - _MIN_SIZE)
			_rect = r
		Handle.BL:
			r.position.x = clampf(r.position.x + delta.x, 0.0, r.end.x - _MIN_SIZE)
			r.end.y = clampf(r.end.y + delta.y, r.position.y + _MIN_SIZE, 1.0)
			_rect = r
		Handle.BR:
			r.end.x = clampf(r.end.x + delta.x, r.position.x + _MIN_SIZE, 1.0)
			r.end.y = clampf(r.end.y + delta.y, r.position.y + _MIN_SIZE, 1.0)
			_rect = r
		_:
			pass
	queue_redraw()
