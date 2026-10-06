extends Control
class_name LibraryItem

# One grid tile in LibraryView: thumbnail/RAW placeholder + filename caption.
# Owns no photo-list state; LibraryView drives setup()/set_texture()/set_selected().

signal clicked(index: int)
signal activated(index: int)
signal zoom_gestured(factor: float)

const THUMB_SIZE: float = 200.0
const CAPTION_HEIGHT: float = 28.0
const TILE_SIZE: Vector2 = Vector2(200.0, THUMB_SIZE + CAPTION_HEIGHT)
# Grid-column spacing LibraryView uses alongside TILE_SIZE for its column math.
const GROUP_SEP: int = 12

var _index: int = -1
var _photo: Dictionary = {}
var _texture: Texture2D = null
var _selected: bool = false
var _hovered: bool = false
var _tile_scale: float = 1.0

var _color_tile: Color
var _color_tile_hover: Color
var _color_border: Color
var _color_accent: Color
var _color_caption: Color


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	# Respects a _tile_scale set via set_tile_scale() before this node entered
	# the tree; a bare `custom_minimum_size = TILE_SIZE` here would clobber it,
	# leaving the cell sized for scale 1.0 while _draw uses the real scale.
	_apply_tile_size()
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# Resolved by node path, not the ThemeManager identifier: autoloads are not
	# registered in --script mode, where a direct identifier fails to compile.
	var theme_manager: Node = get_node_or_null("/root/ThemeManager")
	if theme_manager != null:
		theme_manager.theme_changed.connect(_on_theme_changed)
		_update_colors(theme_manager.is_dark)
	else:
		_update_colors(true)


func _on_theme_changed(is_dark: bool) -> void:
	_update_colors(is_dark)
	queue_redraw()


func _update_colors(is_dark: bool) -> void:
	if is_dark:
		_color_tile = Color(0.184, 0.184, 0.184, 1.0)
		_color_tile_hover = Color(0.227, 0.227, 0.227, 1.0)
		_color_border = Color(0.227, 0.227, 0.227, 1.0)
		_color_accent = Color(0.29, 0.616, 0.878, 1.0)
		_color_caption = Color(0.541, 0.541, 0.541, 1.0)
	else:
		_color_tile = Color(0.93, 0.93, 0.93, 1.0)
		_color_tile_hover = Color(0.88, 0.88, 0.88, 1.0)
		_color_border = Color(0.78, 0.78, 0.78, 1.0)
		_color_accent = Color(0.12, 0.40, 0.65, 1.0)
		_color_caption = Color(0.45, 0.45, 0.45, 1.0)


func setup(index: int, photo: Dictionary) -> void:
	_index = index
	_photo = photo
	_texture = null
	_selected = false
	queue_redraw()


func set_selected(selected: bool) -> void:
	if _selected == selected:
		return
	_selected = selected
	queue_redraw()


func set_texture(tex: Texture2D) -> void:
	_texture = tex
	queue_redraw()


func has_texture() -> bool:
	return _texture != null


func clear_texture() -> void:
	_texture = null
	queue_redraw()


func get_photo_index() -> int:
	return _index


func set_tile_scale(scale: float) -> void:
	scale = clamp(scale, 0.5, 4.0)
	if is_equal_approx(scale, _tile_scale) and custom_minimum_size.x > 0.0:
		return
	_tile_scale = scale
	_apply_tile_size()
	queue_redraw()


func _apply_tile_size() -> void:
	custom_minimum_size = Vector2(
		TILE_SIZE.x * _tile_scale, THUMB_SIZE * _tile_scale + CAPTION_HEIGHT)


func _draw() -> void:
	var thumb_rect := Rect2(Vector2.ZERO, Vector2(size.x, THUMB_SIZE * _tile_scale))
	var bg_color: Color = _color_tile_hover if (_selected or _hovered) else _color_tile
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)

	if _selected:
		draw_rect(Rect2(Vector2.ONE, size - Vector2(2.0, 2.0)), _color_accent, false, 2.0)
	else:
		draw_rect(Rect2(Vector2.ZERO, size), _color_border, false, 1.0)

	if _texture != null:
		_draw_letterboxed(thumb_rect)
	else:
		_draw_raw_placeholder(thumb_rect)

	_draw_caption()


# Letterbox: scale to fit thumb_rect keeping aspect, center both axes.
func _draw_letterboxed(thumb_rect: Rect2) -> void:
	var tex_size: Vector2 = _texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var fit_scale: float = min(thumb_rect.size.x / tex_size.x, thumb_rect.size.y / tex_size.y)
	var drawn_size: Vector2 = tex_size * fit_scale
	var drawn_pos: Vector2 = thumb_rect.position + (thumb_rect.size - drawn_size) * 0.5
	draw_texture_rect(_texture, Rect2(drawn_pos, drawn_size), false)


func _draw_raw_placeholder(thumb_rect: Rect2) -> void:
	var inset_rect: Rect2 = thumb_rect.grow(-8.0)
	draw_rect(inset_rect, _color_border, true)

	var ext: String = (_photo.get("name", "") as String).get_extension().to_upper()
	if ext.is_empty():
		return
	var font: Font = get_theme_font("font", "Label")
	var font_size: int = get_theme_font_size("font_size", "Label")
	var text_size: Vector2 = font.get_string_size(ext, HORIZONTAL_ALIGNMENT_CENTER, -1.0, font_size)
	var text_pos: Vector2 = thumb_rect.position + (thumb_rect.size - text_size) * 0.5
	text_pos.y += font.get_ascent(font_size)
	draw_string(font, text_pos, ext, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, _color_caption)


func _draw_caption() -> void:
	var name: String = _photo.get("name", "") as String
	if name.is_empty():
		return
	var font: Font = get_theme_font("font", "Label")
	var font_size: int = get_theme_font_size("font_size", "Label")
	var caption_rect := Rect2(Vector2(4.0, size.y - CAPTION_HEIGHT), Vector2(size.x - 8.0, CAPTION_HEIGHT))
	var truncated: String = _truncate_to_width(name, font, font_size, caption_rect.size.x)
	var baseline_y: float = caption_rect.position.y + (CAPTION_HEIGHT + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	draw_string(font, Vector2(caption_rect.position.x, baseline_y), truncated,
		HORIZONTAL_ALIGNMENT_LEFT, caption_rect.size.x, font_size, _color_caption)


# Appends an ellipsis once the string no longer fits max_width.
func _truncate_to_width(text: String, font: Font, font_size: int, max_width: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= max_width:
		return text
	var ellipsis: String = "…"
	var lo: int = 0
	var hi: int = text.length()
	while lo < hi:
		var mid: int = (lo + hi + 1) / 2
		var candidate: String = text.substr(0, mid) + ellipsis
		if font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= max_width:
			lo = mid
		else:
			hi = mid - 1
	return text.substr(0, lo) + ellipsis


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if mb.double_click:
				activated.emit(_index)
			else:
				clicked.emit(_index)
			accept_event()
			return
		# Cmd-wheel zooms; plain wheel is left unhandled so the ScrollContainer
		# ancestor still receives it for scrolling.
		if mb.is_command_or_control_pressed():
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				zoom_gestured.emit(1.1)
				accept_event()
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				zoom_gestured.emit(1.0 / 1.1)
				accept_event()
		return

	if event is InputEventMagnifyGesture:
		zoom_gestured.emit(event.factor)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		_hovered = true
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_hovered = false
		queue_redraw()
