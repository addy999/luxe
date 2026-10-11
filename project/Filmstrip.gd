extends VBoxContainer
class_name Filmstrip

# Horizontal filmstrip under the Edit view (Lightroom-style): every photo in
# the current library location, click to open. Collapsible via the arrow
# button; collapsed, the strip keeps only the arrow row so Edit grows back.
#
# Data comes duck-typed from a source object (LibraryView implements these),
# so the strip mirrors the grid's visible list and reuses its texture/badge
# caches without owning any photo state:
#   filmstrip_count() -> int                   (VISIBLE-space count)
#   filmstrip_path(i) -> String                (VISIBLE-space path, "" if oob)
#   filmstrip_texture(path) -> Texture2D       (null if not decoded yet)
#   filmstrip_edited(path) -> bool
#   filmstrip_rejected(path) -> bool
#
# Thumbs are CACHED-ONLY: an undecoded photo shows its extension placeholder.
# Rendering a RAW thumb needs the shared backend pipe (a reload + re-render of
# the photo being edited), so the strip never requests one; tiles fill as the
# Library grid decodes them (thumb_ready -> update_tile).
#
# Virtualization is the grid's technique at fixed tile size: a recycled pool
# of custom-draw Controls over a Content whose minimum width spans the full
# strip, so the ScrollContainer scrolls the whole list.

signal photo_selected(path: String)

# Fixed tile geometry (no zoom; the grid's zoom slider stays Library-only).
const TILE_WIDTH: float = 112.0
const TILE_HEIGHT: float = 76.0
const SEP: int = 6
const MARGIN: float = 8.0
# Extra tiles kept bound left/right of the viewport so a scroll tick reveals
# ready tiles instead of blanks.
const BUFFER_TILES: int = 8
const TOGGLE_ROW_HEIGHT: float = 18.0

# Duck-typed source (LibraryView). Null before bind_source.
var source: Object = null
# Strip contents shown when true; collapsed shows only the arrow row.
var open: bool = true: set = _set_open

var _selected_path: String = ""
var _arrow: Button
var _scroll: ScrollContainer
var _content: Control
var _strip_area: MarginContainer
var _pool: Array[FilmstripTile] = []   # recycled tiles, all children of _content

# Palette mirrors LibraryItem's, re-derived on theme_changed.
var _color_tile: Color
var _color_tile_hover: Color
var _color_border: Color
var _color_accent: Color
var _color_caption: Color


func _ready() -> void:
	var theme_manager: Node = get_node_or_null("/root/ThemeManager")
	if theme_manager != null:
		theme_manager.theme_changed.connect(_on_theme_changed)
	_update_colors(theme_manager != null and not theme_manager.is_dark)

	# Toggle row: a thin strip-wide button row so a click anywhere on it works,
	# not just on the small arrow glyph.
	var toggle_row := Button.new()
	toggle_row.name = "ToggleRow"
	toggle_row.custom_minimum_size = Vector2(0, TOGGLE_ROW_HEIGHT)
	toggle_row.focus_mode = Control.FOCUS_NONE
	toggle_row.flat = true
	toggle_row.text = "▼"
	toggle_row.tooltip_text = "Hide thumbnail strip"
	toggle_row.pressed.connect(_on_arrow_pressed)
	add_child(toggle_row)
	_arrow = toggle_row

	# A MarginContainer, NOT a plain Control: a bare Control never lays out its
	# children, so the ScrollContainer below would keep width 0 and clip every
	# tile (the strip renders as an empty grey box).
	_strip_area = MarginContainer.new()
	_strip_area.name = "StripArea"
	_strip_area.visible = false
	_strip_area.custom_minimum_size = Vector2(0, MARGIN * 2.0 + TILE_HEIGHT)
	_strip_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_strip_area)

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_strip_area.add_child(_scroll)

	_content = Control.new()
	_content.name = "Content"
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.add_child(_content)

	_scroll.get_h_scroll_bar().value_changed.connect(_on_scrolled)
	# The strip relays out when resized, not just scrolled: it is built while
	# hidden (width 0) and only gets a real viewport size when Edit view shows it.
	_scroll.resized.connect(_relayout)
	_apply_open()


func _on_theme_changed(is_dark: bool) -> void:
	_update_colors(is_dark)
	for tile in _pool:
		tile.queue_redraw()


func _update_colors(is_dark: bool) -> void:
	_color_tile = Color(0.184, 0.184, 0.184, 1.0) if is_dark else Color(0.93, 0.93, 0.93, 1.0)
	_color_tile_hover = Color(0.227, 0.227, 0.227, 1.0) if is_dark else Color(0.88, 0.88, 0.88, 1.0)
	_color_border = Color(0.227, 0.227, 0.227, 1.0) if is_dark else Color(0.78, 0.78, 0.78, 1.0)
	_color_accent = Color(0.29, 0.616, 0.878, 1.0) if is_dark else Color(0.12, 0.40, 0.65, 1.0)
	_color_caption = Color(0.541, 0.541, 0.541, 1.0) if is_dark else Color(0.45, 0.45, 0.45, 1.0)


# --- Source binding / external refresh hooks (called by Main.gd) ---------------

# Sets the data source and rebuilds. Also resets the selected tile to the
# currently open photo (selected_path, "" = none).
func bind_source(src: Object, selected_path: String) -> void:
	source = src
	_selected_path = selected_path
	_relayout()


# Re-reads everything (count, paths, textures, badges). Cheap: pool reuse means
# this is O(visible tiles) redraws, no allocation.
func refresh() -> void:
	if source == null:
		return
	_relayout()


# Pushes one photo's fresh texture into whichever tile shows it (called from
# LibraryView.thumb_ready so tiles fill in as the grid decodes).
func update_tile(path: String) -> void:
	for tile in _pool:
		if tile.get_bound_path() == path:
			tile.set_texture(source.filmstrip_texture(path))


func set_selected(path: String) -> void:
	if _selected_path == path:
		return
	_selected_path = path
	for tile in _pool:
		tile.set_selected(tile.get_bound_path() == path)


# Scrolls the selected tile into view (open_photo / photo cycling).
func reveal_selected() -> void:
	if not open or source == null or _selected_path.is_empty():
		return
	var idx: int = -1
	for i in source.filmstrip_count():
		if source.filmstrip_path(i) == _selected_path:
			idx = i
			break
	if idx < 0:
		return
	var x0: float = MARGIN + idx * (TILE_WIDTH + SEP)
	var x1: float = x0 + TILE_WIDTH
	var vis_l: float = _scroll.scroll_horizontal
	var vis_r: float = vis_l + _scroll.size.x
	if x0 < vis_l:
		_scroll.scroll_horizontal = int(x0)
	elif x1 > vis_r:
		_scroll.scroll_horizontal = int(x1 - _scroll.size.x)


func _on_arrow_pressed() -> void:
	open = not open


func _set_open(value: bool) -> void:
	open = value
	if is_inside_tree():
		_apply_open()


func _apply_open() -> void:
	if _strip_area == null:
		return

	_strip_area.visible = open
	_arrow.text = "▲" if open else "▼"
	_arrow.tooltip_text = "Hide thumbnail strip" if open else "Show thumbnail strip"
	# Rebuild from scratch: a hidden (not freed) pool keeps stale bindings and
	# the scroll range goes stale while hidden; refresh() re-derives both.
	if open:
		_relayout()


func _on_scrolled(_value: float) -> void:
	_refresh_tiles()


# --- Virtualized layout --------------------------------------------------------

func _relayout() -> void:
	if source == null or _content == null:
		return
	var count: int = source.filmstrip_count() if open else 0
	var total_w: float = MARGIN * 2.0 + maxi(0, count) * TILE_WIDTH \
		+ maxi(0, count - 1) * SEP
	# Content's min width spans the full strip so the ScrollContainer scrolls
	# the whole list (same trick as the grid's min-height Content).
	_content.custom_minimum_size = Vector2(maxf(total_w, _scroll.size.x), TILE_HEIGHT)
	_content.size = _content.custom_minimum_size
	_refresh_tiles()


func _visible_range() -> Vector2i:
	var first: int = floori((_scroll.scroll_horizontal - MARGIN) / float(TILE_WIDTH + SEP)) - BUFFER_TILES
	var last: int = ceili((_scroll.scroll_horizontal + _scroll.size.x - MARGIN) / float(TILE_WIDTH + SEP)) + BUFFER_TILES
	return Vector2i(maxi(0, first), mini(source.filmstrip_count() - 1, last))


func _tile_x(i: int) -> float:
	return MARGIN + i * (TILE_WIDTH + SEP)


func _ensure_pool(needed: int) -> void:
	while _pool.size() < needed:
		var tile: FilmstripTile = FilmstripTile.new()
		tile.strip = self
		_content.add_child(tile)
		_pool.append(tile)
	for i in _pool.size():
		_pool[i].visible = i < needed


func _refresh_tiles() -> void:
	if source == null or not open or _content == null:
		for tile in _pool:
			tile.visible = false
		return
	var rng: Vector2i = _visible_range()
	_ensure_pool(maxi(0, rng.y - rng.x + 1))
	for i in _pool.size():
		var tile: FilmstripTile = _pool[i]
		if not tile.visible:
			continue
		var idx: int = rng.x + i
		tile.bind(idx, source.filmstrip_path(idx))


# --- Tile helpers (called by _Tile) ---------------------------------------------

func tile_texture(path: String) -> Texture2D:
	return source.filmstrip_texture(path) if source != null else null


func tile_edited(path: String) -> bool:
	return source.filmstrip_edited(path) if source != null else false


func tile_rejected(path: String) -> bool:
	return source.filmstrip_rejected(path) if source != null else false


func tile_clicked(index: int, path: String) -> void:
	set_selected(path)
	photo_selected.emit(path)


# Nested class so the strip owns its tile type without a second file; the grid's
# LibraryItem stays untouched.
class FilmstripTile extends Control:
	var strip: Filmstrip = null
	var _index: int = -1
	var _path: String = ""
	var _texture: Texture2D = null
	var _selected: bool = false
	var _hovered: bool = false

	const _EDITED_DOT_COLOR: Color = Color(0.98, 0.78, 0.13, 1.0)
	const _EDITED_DOT_RADIUS: float = 4.0
	const _EDITED_DOT_MARGIN: float = 5.0
	const _REJECT_MARK_COLOR: Color = Color(0.86, 0.22, 0.22, 1.0)
	const _REJECT_MARK_RADIUS: float = 4.0
	const _REJECT_MARK_MARGIN: float = 5.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		custom_minimum_size = Vector2(Filmstrip.TILE_WIDTH, Filmstrip.TILE_HEIGHT)
		size = custom_minimum_size

	func bind(index: int, path: String) -> void:
		# No early-return on index/path: refresh() rebinds unchanged tiles too,
		# so a tile bound before its thumbnail decoded picks up the texture here.
		var tex: Texture2D = strip.tile_texture(path) if strip != null and path != "" else null
		var sel: bool = strip != null and strip._selected_path == path
		var changed: bool = _index != index or _path != path \
			or _texture != tex or _selected != sel
		_index = index
		_path = path
		_texture = tex
		_selected = sel
		position = Vector2(strip._tile_x(index), Filmstrip.MARGIN)
		if changed:
			queue_redraw()

	func set_texture(tex: Texture2D) -> void:
		_texture = tex
		queue_redraw()

	func set_selected(selected: bool) -> void:
		if _selected == selected:
			return
		_selected = selected
		queue_redraw()

	func get_bound_path() -> String:
		return _path

	func _on_theme_changed(_is_dark: bool) -> void:
		# The strip re-derives its palette and calls queue_redraw on the pool;
		# tiles only need their own redraw.
		queue_redraw()

	func _draw() -> void:
		if strip == null:
			return
		var thumb_rect := Rect2(Vector2.ZERO, size)
		var bg: Color = strip._color_tile_hover if (_selected or _hovered) else strip._color_tile
		draw_rect(thumb_rect, bg, true)

		var photo_path: String = _path
		if photo_path.is_empty():
			return

		if _texture != null:
			var tex_size: Vector2 = _texture.get_size()
			if tex_size.x > 0.0 and tex_size.y > 0.0:
				var fit: float = minf(thumb_rect.size.x / tex_size.x, thumb_rect.size.y / tex_size.y)
				var drawn: Vector2 = tex_size * fit
				var pos: Vector2 = thumb_rect.position + (thumb_rect.size - drawn) * 0.5
				draw_texture_rect(_texture, Rect2(pos, drawn), false)
		else:
			# Extension placeholder (same convention as the grid's RAW tile).
			var ext: String = photo_path.get_extension().to_upper()
			if not ext.is_empty():
				var font: Font = get_theme_font("font", "Label")
				var font_size: int = get_theme_font_size("font_size", "Label")
				var ts: Vector2 = font.get_string_size(ext, HORIZONTAL_ALIGNMENT_CENTER, -1.0, font_size)
				var tp: Vector2 = thumb_rect.position + (thumb_rect.size - ts) * 0.5
				tp.y += font.get_ascent(font_size)
				draw_string(font, tp, ext, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, strip._color_caption)

		# Accent frame last so the thumbnail cannot paint over it; unselected
		# tiles get no border at all (the gap between tiles is the separator).
		if _selected:
			draw_rect(Rect2(Vector2.ONE, size - Vector2(2.0, 2.0)),
				strip._color_accent, false, 2.0)

		# Badges mirror the grid: edited dot top-right, reject mark top-left.
		if strip.tile_edited(photo_path):
			var dc := Vector2(
				thumb_rect.end.x - _EDITED_DOT_MARGIN - _EDITED_DOT_RADIUS,
				thumb_rect.position.y + _EDITED_DOT_MARGIN + _EDITED_DOT_RADIUS)
			draw_circle(dc, _EDITED_DOT_RADIUS, _EDITED_DOT_COLOR)
		if strip.tile_rejected(photo_path):
			var rc := Vector2(
				thumb_rect.position.x + _REJECT_MARK_MARGIN + _REJECT_MARK_RADIUS,
				thumb_rect.position.y + _REJECT_MARK_MARGIN + _REJECT_MARK_RADIUS)
			draw_circle(rc, _REJECT_MARK_RADIUS, _REJECT_MARK_COLOR)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			strip.tile_clicked(_index, _path)
			accept_event()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER:
			_hovered = true
			queue_redraw()
		elif what == NOTIFICATION_MOUSE_EXIT:
			_hovered = false
			queue_redraw()