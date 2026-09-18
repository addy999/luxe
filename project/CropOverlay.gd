extends Control

# CropOverlay -- an interactive crop editor drawn directly over the image's
# TextureRect. Instantiated in code and parented to the TextureRect itself (see
# _open_crop_overlay() in Main.gd), so it automatically tracks every display-
# zoom/pan/Fit re-layout; the crop box is stored in NORMALIZED image fractions,
# which is exactly the coordinate space darktable's clipping module uses
# (cx/cy/cw/ch as left/top/right/bottom edges). Main.gd owns the authoritative
# value (_params["crop"]); this widget only edits it and signals back.
#
# Interaction: drag inside the box to move it, drag an edge/corner handle to
# resize. "Done" commits via crop_applied; Cancel restores whatever was set
# when the overlay opened. While open, this control swallows mouse input so
# the drag-to-pan/Cmd+wheel handlers under it stay quiet.

# The Done/Cancel bar. Lives OUTSIDE this control, anchored to the visible
# scroll pane (Main.gd parents it to the ScrollContainer): this overlay is
# sized to the DISPLAYED IMAGE, which at high zoom is far larger than the
# pane, so anything anchored here scrolls/shoots off-screen. Main.gd owns the
# bar node and connects its buttons to _on_crop_overlay_applied/canceled.

const _MIN_SIZE: float = 0.02      # smallest allowed box, as image fraction
# Handle grab geometry, in px. _HANDLE_GRAB is how far INSIDE the box an edge
# still counts as grabbable; _HANDLE_OUTER reaches a similar distance OUTSIDE
# the box, so the 1px frame line does not have to be hit exactly. _CORNER_GRAB
# is the circular radius around a corner (corners always outrank edges).
const _HANDLE_GRAB: float = 22.0
const _HANDLE_OUTER: float = 24.0
const _CORNER_GRAB: float = 26.0
const _GRID: int = 3               # rule-of-thirds grid lines per axis

# Handle ids for hit-testing. Corners outrank edges (a corner is always within
# both of its edges' grab bands), edges outrank the interior.
enum Handle { NONE, MOVE, TL, TR, BL, BR, TOP, BOTTOM, LEFT, RIGHT }

var _rect := Rect2(0, 0, 1, 1)     # working copy while editing
var _orig := Rect2(0, 0, 1, 1)     # what to restore on cancel
var _drag: int = Handle.NONE
var _drag_start_mouse := Vector2.ZERO
var _drag_start_rect := Rect2()

# The host TextureRect, remembered so _notification(SORTED_CHILDREN) /
# NOTIFICATION_RESIZED can re-sync this overlay's rect to the image region as
# the host re-lays out (display-zoom changes, Fit, window resizes). Without
# this, the overlay kept its open-time geometry while the image under it
# moved/resized, so zooming detached the crop box from the image.
var _host: TextureRect = null

# Theme-driven chrome colors, pushed by Main.gd's _on_theme_changed() via
# apply_theme() so light/dark switches stay correct while the overlay is open.
var _line_color := Color.WHITE
var _dim_color := Color(0, 0, 0, 0.6)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP  # block clicks from reaching the pan/zoom handlers below


# Build the Done/Cancel bar anchored to the VISIBLE PANE (pane: the
# ScrollContainer that clips the image), not to this overlay. The overlay is
# image-sized: at 200% zoom it is several thousand px tall, and a bar anchored
# to it would be scrolled off-screen. The bar floats at the pane's bottom.
static func build_bar(pane: Control) -> HBoxContainer:
	var bar := PanelContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -52.0
	bar.offset_bottom = -8.0
	# Transparent to mouse input outside its buttons so presses near the pane's
	# bottom edge (where a zoomed image's crop handles sit) still reach the
	# overlay under the bar.
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


# Open over the given TextureRect with the crop to resume editing. The
# overlay's own rect is recomputed from the host's current texture + stretch
# mode by _sync_rect() (also re-run on every host resize), so the box always
# sits on the actual drawn image pixels regardless of zoom/Fit re-layouts:
# normalized fractions then map 1:1 onto the displayed image.
func open(host: TextureRect, rect: Rect2) -> void:
	_orig = rect
	_rect = rect
	_host = host
	host.add_child(self)
	# Re-sync on every host resize (zoom slider, Fit toggle, window resize) so
	# the crop box stays glued to the drawn image region. Texture swaps do NOT
	# signal (TextureRect has no texture_changed) -- Main.gd calls
	# sync_to_texture() after assigning a new texture instead.
	host.resized.connect(_sync_rect)
	visible = true
	_sync_rect()


# Re-derive this overlay's position/size from the host's current texture and
# stretch mode. In STRETCH_SCALE (fixed zoom) the image fills the whole host
# rect; in KEEP_ASPECT_CENTERED (Fit) it letterboxes into a centered sub-rect
# (Godot scales by min(host/tex) per axis and centers -- confirmed behavior).
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


# The box currently being edited, in normalized fractions -- Main.gd's Done
# button reads this at click time so it always commits the latest state.
func get_rect_normalized() -> Rect2:
	return _rect


# Main.gd calls this right after assigning a new texture on the host: the
# buffer dimensions change (lift render, edit-res change), which changes the
# Fit-mode letterbox geometry even though the host node itself did not resize.
func sync_to_texture() -> void:
	_sync_rect()


func _draw() -> void:
	var box := _screen_rect()
	# Dim everything outside the crop box (four strips; avoids a shader).
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
	# Corner handles (small filled squares read better than edge-only handles).
	# Each 8px square is centered on its corner, so half of it lands outside the
	# box -- and for a box flush with an edge (the default full-frame crop)
	# outside the image itself, over the Fit letterbox. Clamp each handle into
	# this control's rect: the overlay IS the drawn image region (see _sync_rect),
	# so the clamp keeps every handle on the image.
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
	# Corners first (highest priority), then edges, then inside. Each corner is
	# a generous circular grab (_CORNER_GRAB) so it wins over the edge bands
	# below. Outside the box beyond all grab bands is Handle.NONE: clicks there
	# are swallowed (no draw-new-box mode; resizing via the handles covers the
	# common cases).
	for pair: Array in [
		[box.position, Handle.TL], [Vector2(box.end.x, box.position.y), Handle.TR],
		[Vector2(box.position.x, box.end.y), Handle.BL], [box.end, Handle.BR]]:
		if p.distance_to(pair[0]) <= _CORNER_GRAB:
			return pair[1]
	# Edge bands reach _HANDLE_GRAB px INSIDE each edge and _HANDLE_OUTER px
	# OUTSIDE it, so the cursor can sit slightly past the box and still grab that
	# side. The along-edge span stays within the box; the corner grabs above own
	# the diagonal regions.
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


# Cursor feedback: reuse the exact hit-test used for drags so the pointer
# always advertises the action a press would start. Godot calls this every
# frame the mouse is over this control (public wrapper: get_cursor_shape()).
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


# Mouse motion handler: translate the hit id into an edge/corner edit. All
# math happens in normalized space so behavior is zoom-independent.
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
