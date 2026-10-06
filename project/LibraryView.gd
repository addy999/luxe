extends HBoxContainer
class_name LibraryView

# Library photo-browsing view: a sidebar of scan locations and a virtualized
# thumbnail grid for the selected location. Main.gd instances this scene and
# listens for photo_activated to switch into the editor.
#
# Virtualization: instead of one Control per photo (thousands of nodes + a
# texture cap that thrashed on scroll), a small recycled tile pool covers only
# the visible rows plus a buffer. Tiles are children of `Content`, a plain
# Control whose minimum height equals the full virtual grid so the
# ScrollContainer still scrolls the whole list. Decoded textures live in a
# path-keyed LRU (`_tex_cache`) that outlives tile recycling, so scrolling
# back over recently-seen photos is instant with no re-decode.

signal photo_activated(path: String)
# Mirrors the sidebar CountLabel text; Main.gd routes this to a bottom-bar label.
signal status_changed(status: String)
signal add_location_requested()
# A visible, untextured RAW tile needs a backend-rendered thumbnail; Main.gd
# owns the backend and handles the actual render.
signal raw_thumb_requested(index: int)
# Multiplicative zoom request (centered on 1.0), same convention as Main.gd's
# _zoom_by_factor. Emitted by pinch/Cmd-wheel gestures over tiles or empty grid area.
signal zoom_requested(factor: float)

const LibraryItemScript := preload("res://LibraryItem.gd")

const THUMB_WORKERS: int = 2
# Decoded textures held in memory, keyed by path. The virtualized grid only
# ever shows a few dozen tiles, so this is a scroll-back cache, not a 1:1 map.
const MAX_CACHE_TEXTURES: int = 400
# Extra rows kept bound above and below the viewport so a flick reveals ready
# tiles instead of blanks.
const BUFFER_ROWS: int = 2
const _THUMB_DEBOUNCE_SEC: float = 0.1
const _GRID_MARGIN: float = 16.0

@onready var locations_vbox: VBoxContainer = $Sidebar/SidebarMargin/SidebarVBox/LocationsVBox
@onready var add_location_button: Button = $Sidebar/SidebarMargin/SidebarVBox/AddLocationButton
@onready var grid_scroll: ScrollContainer = $GridPanel/GridScroll
@onready var content: Control = $GridPanel/GridScroll/Content
@onready var empty_state: CenterContainer = $EmptyState

var _add_location_dialog: FileDialog = null
var _thumb_timer: Timer = null

var _locations: PackedStringArray = PackedStringArray()
var _selected_location: String = ""

var _photos: Array[Dictionary] = []
var _cursor: int = -1
var _thumb_scale: float = 1.0

var _scan_generation: int = 0
var _scanning: bool = false

# --- Virtualized layout --------------------------------------------------------
var _pool: Array[LibraryItem] = []   # recycled tiles, bound to visible indices
var _cols: int = 1
var _tile_w: float = 0.0
var _tile_h: float = 0.0

# --- Texture cache (path-keyed LRU) --------------------------------------------
var _tex_cache: Dictionary = {}      # path -> Texture2D
var _tex_lru: Array[String] = []     # oldest first; access moves to the back
# Paths with an in-flight request, so a scroll tick doesn't re-queue them.
var _requested: Dictionary = {}      # path -> true

# --- Bounded thumbnail workers (jpg/png decode) --------------------------------
var _queue: Array[int] = []
var _inflight: int = 0
var _mutex: Mutex = Mutex.new()


func _ready() -> void:
	# Resolved by node path, not the ThemeManager identifier: autoloads are not
	# registered in --script mode, where a direct identifier fails to compile.
	var theme_manager: Node = get_node_or_null("/root/ThemeManager")
	if theme_manager != null:
		theme_manager.theme_changed.connect(_on_theme_changed)

	# Keyboard focus and key handling live on Content (the ScrollContainer eats
	# arrow/scroll keys if focused); tiles have FOCUS_NONE so focus stays here.
	content.focus_mode = Control.FOCUS_ALL
	content.mouse_filter = Control.MOUSE_FILTER_STOP
	content.gui_input.connect(_on_grid_gui_input)
	grid_scroll.resized.connect(_on_grid_scroll_resized)
	grid_scroll.get_v_scroll_bar().value_changed.connect(_on_grid_scroll_changed)
	_style_scrollbar()

	_thumb_timer = Timer.new()
	_thumb_timer.one_shot = true
	_thumb_timer.timeout.connect(_on_thumb_timer_timeout)
	add_child(_thumb_timer)

	add_location_button.focus_mode = Control.FOCUS_NONE
	add_location_button.pressed.connect(_on_add_location_button_pressed)

	_setup_add_location_dialog()

	_locations = Library.load_locations()
	_rebuild_sidebar()
	if _locations.size() > 0:
		_select_location(_locations[0])
	else:
		_update_status("No photos yet")


func _style_scrollbar() -> void:
	# Colors/rounding come from the shared theme (scroll_* styleboxes); only the
	# bar thickness is per-ScrollContainer. See ScrollbarStyle.WIDTH.
	ScrollbarStyle.widen(grid_scroll)


func on_view_entered() -> void:
	content.grab_focus()
	_relayout()
	_request_visible_thumbs()


func get_photo_count() -> int:
	return _photos.size()


# Returns the photo dict at index, or an empty Dictionary if out of range.
func get_photo(index: int) -> Dictionary:
	if index < 0 or index >= _photos.size():
		return {}
	return _photos[index]


func _on_theme_changed(_is_dark: bool) -> void:
	for tile in _pool:
		tile.queue_redraw()


# --- Status ---------------------------------------------------------------------

func _update_status(status: String) -> void:
	status_changed.emit(status)


# --- Add-location dialog ---------------------------------------------------------

func _setup_add_location_dialog() -> void:
	_add_location_dialog = FileDialog.new()
	_add_location_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_add_location_dialog.access = FileDialog.ACCESS_FILESYSTEM
	# NOT the native dialog: on macOS it returns dir paths with ".*" appended
	# (the selection is round-tripped through the filename+filter machinery).
	_add_location_dialog.use_native_dialog = true
	_add_location_dialog.title = "Choose a Folder"
	_add_location_dialog.dir_selected.connect(_on_add_location_dir_selected)
	add_child(_add_location_dialog)


func _on_add_location_button_pressed() -> void:
	_add_location_dialog.popup_centered()


func _on_add_location_dir_selected(dir_path: String) -> void:
	dir_path = _normalize_location_path(dir_path)
	if _is_duplicate_or_nested(dir_path):
		_update_status("Already added")
		return
	_locations.append(dir_path)
	Library.save_locations(_locations)
	_rebuild_sidebar()
	_select_location(dir_path)


# Cleans dialog-returned paths: file:// URIs, surrounding quotes/whitespace,
# trailing slashes, and the native macOS dialog's ".*" suffix quirk (the
# selection is round-tripped through the filename+filter machinery, so
# "/photos/EU" comes back as "/photos/EU.*"). The suffix is only stripped
# when the un-mangled path exists, so a folder genuinely named "foo.*" is kept.
func _normalize_location_path(dir_path: String) -> String:
	var p: String = dir_path.strip_edges().strip_escapes()
	p = p.trim_prefix("file://")
	p = p.trim_suffix("/")
	if not DirAccess.dir_exists_absolute(p) and p.ends_with(".*"):
		var stripped: String = p.substr(0, p.length() - 2)
		if DirAccess.dir_exists_absolute(stripped):
			return stripped
	return p


# Rejects exact duplicates and any nesting relationship (either direction).
func _is_duplicate_or_nested(dir_path: String) -> bool:
	for existing in _locations:
		if existing == dir_path:
			return true
		if dir_path.begins_with(existing.path_join("")) or existing.begins_with(dir_path.path_join("")):
			return true
	return false


func _on_remove_location_pressed(dir_path: String) -> void:
	var idx: int = _locations.find(dir_path)
	if idx < 0:
		return
	_locations.remove_at(idx)
	Library.save_locations(_locations)
	if _selected_location == dir_path:
		_selected_location = ""
		_set_photos([])
		if _locations.size() > 0:
			_select_location(_locations[0])
		else:
			_update_status("No photos yet")
	_rebuild_sidebar()


# --- Sidebar ---------------------------------------------------------------------

func _rebuild_sidebar() -> void:
	# remove_child detaches immediately, unlike queue_free alone, which only
	# defers deletion: without the immediate detach, rows added below would
	# share the VBox with the still-attached old rows until end of frame.
	for child in locations_vbox.get_children():
		locations_vbox.remove_child(child)
		child.queue_free()

	for dir_path: String in _locations:
		locations_vbox.add_child(_build_location_row(dir_path))


func _build_location_row(dir_path: String) -> Button:
	var missing: bool = not DirAccess.dir_exists_absolute(dir_path)
	var label_text: String = dir_path.get_file()
	if label_text.is_empty():
		label_text = dir_path
	if missing:
		label_text += " (missing)"

	var select_btn := Button.new()
	select_btn.theme_type_variation = &"SidebarItem"
	select_btn.focus_mode = Control.FOCUS_NONE
	select_btn.text = label_text
	select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	select_btn.toggle_mode = true
	select_btn.button_pressed = (dir_path == _selected_location)
	select_btn.disabled = missing
	select_btn.clip_text = true
	select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	select_btn.pressed.connect(_select_location.bind(dir_path))

	# The × sits inside the pill (right-anchored) so the whole row stays one
	# hover/click surface; its own rect takes priority for its 28px.
	var remove_btn := Button.new()
	remove_btn.flat = true
	remove_btn.focus_mode = Control.FOCUS_NONE
	remove_btn.text = "×"
	remove_btn.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	remove_btn.custom_minimum_size = Vector2(28, 0)
	remove_btn.offset_left = -34.0
	remove_btn.offset_right = -6.0
	remove_btn.pressed.connect(_on_remove_location_pressed.bind(dir_path))
	select_btn.add_child(remove_btn)

	return select_btn


func _select_location(dir_path: String) -> void:
	_selected_location = dir_path
	_rebuild_sidebar()
	_scan_selected_location()


# --- Scanning ---------------------------------------------------------------------

func _scan_selected_location() -> void:
	if _selected_location.is_empty() or not DirAccess.dir_exists_absolute(_selected_location):
		_set_photos([])
		_update_status("location missing")
		return

	_scan_generation += 1
	var generation: int = _scan_generation
	_scanning = true
	_update_status("Scanning…")

	var dir_path: String = _selected_location
	WorkerThreadPool.add_task(_scan_task.bind(dir_path, generation))


func _scan_task(dir_path: String, generation: int) -> void:
	var results: Array[Dictionary] = Library.scan_location(dir_path)
	call_deferred("_on_scan_done", results, generation)


func _on_scan_done(results: Array[Dictionary], generation: int) -> void:
	if generation != _scan_generation:
		return
	_scanning = false
	_set_photos(results)
	_update_status("%d photos" % _photos.size() if _photos.size() != 1 else "1 photo")
	if _photos.is_empty():
		_update_status("No photos yet")


# --- Photo list / grid reset ---------------------------------------------------

# Swaps the displayed photo set and resets the virtualized grid: drops cached
# textures (they belong to the old list), clears in-flight requests, rewinds
# the scroll and cursor, then relays out.
func _set_photos(photos: Array[Dictionary]) -> void:
	_photos = photos
	_cursor = -1
	_tex_cache.clear()
	_tex_lru.clear()
	_requested.clear()
	_mutex.lock()
	_queue.clear()
	_mutex.unlock()
	for tile in _pool:
		tile.clear_texture()
	grid_scroll.scroll_vertical = 0
	empty_state.visible = _photos.is_empty()
	_relayout()
	_request_visible_thumbs()


# --- Thumbnail zoom ------------------------------------------------------------

func set_thumb_zoom(scale: float) -> void:
	scale = clamp(scale, 0.5, 4.0)
	if is_equal_approx(scale, _thumb_scale):
		return
	_thumb_scale = scale
	for tile in _pool:
		tile.set_tile_scale(scale)
	_relayout()
	if _cursor >= 0:
		_scroll_cursor_into_view()
	_request_visible_thumbs()


# --- Layout --------------------------------------------------------------------

func _on_grid_scroll_resized() -> void:
	_relayout()
	_request_visible_thumbs()


# Recomputes tile dimensions, column count and the virtual content height, then
# rebinds the pool to the current visible range.
func _relayout() -> void:
	_tile_w = LibraryItemScript.TILE_SIZE.x * _thumb_scale
	_tile_h = LibraryItemScript.THUMB_SIZE * _thumb_scale + LibraryItemScript.CAPTION_HEIGHT

	var sep: float = float(LibraryItemScript.GROUP_SEP)
	var avail_w: float = grid_scroll.size.x - _GRID_MARGIN * 2.0 + sep
	_cols = maxi(1, int(floor(avail_w / (_tile_w + sep))))

	var count: int = _photos.size()
	var rows: int = int(ceil(float(count) / float(_cols))) if count > 0 else 0
	var total_h: float = 0.0
	if rows > 0:
		total_h = _GRID_MARGIN * 2.0 + rows * _tile_h + maxf(0.0, rows - 1) * sep
	# Only the height matters for scrolling; the ScrollContainer stretches
	# Content to the viewport width (horizontal scroll is disabled).
	content.custom_minimum_size = Vector2(0.0, total_h)

	_refresh_tiles()


# Returns [start, end) photo indices that should have a live tile, including the
# buffer rows above and below the viewport.
func _visible_index_range() -> Vector2i:
	var count: int = _photos.size()
	if count == 0 or _cols <= 0:
		return Vector2i(0, 0)
	var sep: float = float(LibraryItemScript.GROUP_SEP)
	var row_h: float = _tile_h + sep
	if row_h <= 0.0:
		return Vector2i(0, 0)

	var scroll_v: float = grid_scroll.scroll_vertical
	var vh: float = grid_scroll.size.y
	var first_row: int = int(floor((scroll_v - _GRID_MARGIN) / row_h)) - BUFFER_ROWS
	var last_row: int = int(floor((scroll_v + vh - _GRID_MARGIN) / row_h)) + BUFFER_ROWS

	var total_rows: int = int(ceil(float(count) / float(_cols)))
	first_row = clampi(first_row, 0, total_rows - 1)
	last_row = clampi(last_row, 0, total_rows - 1)

	var start: int = first_row * _cols
	var end: int = mini(count, (last_row + 1) * _cols)
	return Vector2i(start, end)


func _tile_position(index: int) -> Vector2:
	var sep: float = float(LibraryItemScript.GROUP_SEP)
	var col: int = index % _cols
	var row: int = index / _cols
	return Vector2(
		_GRID_MARGIN + col * (_tile_w + sep),
		_GRID_MARGIN + row * (_tile_h + sep))


func _ensure_pool(size: int) -> void:
	while _pool.size() < size:
		var tile := LibraryItemScript.new()
		tile.set_tile_scale(_thumb_scale)
		tile.clicked.connect(_on_item_clicked)
		tile.activated.connect(_on_item_activated)
		tile.zoom_gestured.connect(_on_item_zoom_gestured)
		content.add_child(tile)
		_pool.append(tile)


# Binds pool tiles to the visible index range: positions them, pulls textures
# from the cache, and marks the cursor tile selected. Cheap enough to run on
# every scroll tick (only a few dozen tiles).
func _refresh_tiles() -> void:
	if _photos.is_empty():
		for tile in _pool:
			tile.visible = false
		return

	var r: Vector2i = _visible_index_range()
	var need: int = r.y - r.x
	_ensure_pool(need)

	var slot: int = 0
	for index in range(r.x, r.y):
		var tile: LibraryItem = _pool[slot]
		if tile.get_photo_index() != index:
			tile.setup(index, _photos[index])
			var path: String = _photos[index]["path"]
			if _tex_cache.has(path):
				tile.set_texture(_cache_get(path))
			else:
				tile.clear_texture()
		# Content is a plain Control, not a layout container, so tile size never
		# tracks custom_minimum_size on its own; set scale AND size explicitly
		# every refresh or _draw uses a stale size and clips the thumbnail.
		tile.set_tile_scale(_thumb_scale)
		tile.size = Vector2(_tile_w, _tile_h)
		tile.set_selected(index == _cursor)
		tile.position = _tile_position(index)
		tile.visible = true
		slot += 1

	for i in range(need, _pool.size()):
		_pool[i].visible = false


func _on_item_clicked(index: int) -> void:
	_set_cursor(index)


func _on_item_activated(index: int) -> void:
	_set_cursor(index)
	_activate(index)


func _on_item_zoom_gestured(factor: float) -> void:
	zoom_requested.emit(factor)


# --- Keyboard navigation ------------------------------------------------------------

func _on_grid_gui_input(event: InputEvent) -> void:
	if event is InputEventMagnifyGesture:
		zoom_requested.emit(event.factor)
		accept_event()
		return

	if not (event is InputEventKey) or not event.pressed:
		return
	var key_event: InputEventKey = event
	var cols: int = maxi(1, _cols)
	var count: int = _photos.size()
	var handled: bool = true

	match key_event.keycode:
		KEY_LEFT:
			_set_cursor(Library.next_index(_cursor, -1, 0, cols, count))
		KEY_RIGHT:
			_set_cursor(Library.next_index(_cursor, 1, 0, cols, count))
		KEY_UP:
			_set_cursor(Library.next_index(_cursor, 0, -1, cols, count))
		KEY_DOWN:
			_set_cursor(Library.next_index(_cursor, 0, 1, cols, count))
		KEY_HOME:
			_set_cursor(0 if count > 0 else -1)
		KEY_END:
			_set_cursor(count - 1 if count > 0 else -1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_activate(_cursor)
		_:
			handled = false

	if handled:
		accept_event()


func _set_cursor(index: int) -> void:
	if index == _cursor:
		return
	_cursor = index
	if _cursor >= 0:
		_scroll_cursor_into_view()
	_refresh_tiles()
	_request_visible_thumbs()


# Scrolls the minimum amount to bring the cursor's row fully into view.
func _scroll_cursor_into_view() -> void:
	if _cols <= 0 or _cursor < 0:
		return
	var sep: float = float(LibraryItemScript.GROUP_SEP)
	var row: int = _cursor / _cols
	var y_top: float = _GRID_MARGIN + row * (_tile_h + sep)
	var y_bottom: float = y_top + _tile_h
	var scroll_v: float = grid_scroll.scroll_vertical
	var vh: float = grid_scroll.size.y
	if y_top < scroll_v:
		grid_scroll.scroll_vertical = int(y_top)
	elif y_bottom > scroll_v + vh:
		grid_scroll.scroll_vertical = int(y_bottom - vh)


func _activate(index: int) -> void:
	if index < 0 or index >= _photos.size():
		return
	photo_activated.emit(_photos[index]["path"])


# --- Thumbnail loading ---------------------------------------------------------------

func _on_grid_scroll_changed(_value: float) -> void:
	# Rebind tiles immediately so correct images track the scroll; defer the
	# (debounced) request dispatch for anything not yet cached.
	_refresh_tiles()
	_request_visible_thumbs()


# Debounced: scroll/resize events fire rapidly, so the actual request dispatch
# runs once per _THUMB_DEBOUNCE_SEC.
func _request_visible_thumbs() -> void:
	if _thumb_timer.is_stopped():
		_thumb_timer.start(_THUMB_DEBOUNCE_SEC)


func _on_thumb_timer_timeout() -> void:
	if _photos.is_empty():
		return

	var r: Vector2i = _visible_index_range()
	var to_enqueue: Array[int] = []
	for index in range(r.x, r.y):
		var path: String = _photos[index]["path"]
		if _tex_cache.has(path) or _requested.has(path):
			continue
		_requested[path] = true
		if _photos[index].get("is_raw", false):
			raw_thumb_requested.emit(index)
		else:
			to_enqueue.append(index)

	if not to_enqueue.is_empty():
		_mutex.lock()
		for index in to_enqueue:
			_queue.append(index)
		_mutex.unlock()
		_pump()


func _pump() -> void:
	_mutex.lock()
	while _inflight < THUMB_WORKERS and not _queue.is_empty():
		var index: int = _queue.pop_front()
		_inflight += 1
		var generation: int = _scan_generation
		var photo: Dictionary = _photos[index]
		WorkerThreadPool.add_task(_thumb_task.bind(photo, index, generation))
	_mutex.unlock()


# Runs off the main thread: no scene node access, only Library/ThumbnailCache statics.
func _thumb_task(photo: Dictionary, index: int, generation: int) -> void:
	var path: String = photo["path"]
	var mtime: int = photo["mtime"]
	var key: String = ThumbnailCache.cache_key(path, mtime)
	var img: Image = ThumbnailCache.load_cached(key)
	if img == null:
		img = ThumbnailCache.build_thumbnail(path, key)
	call_deferred("_on_thumb_ready", generation, index, img)


func _on_thumb_ready(generation: int, index: int, img: Image) -> void:
	_mutex.lock()
	_inflight -= 1
	_mutex.unlock()

	if generation == _scan_generation and index >= 0 and index < _photos.size():
		var path: String = _photos[index]["path"]
		_requested.erase(path)
		if img != null:
			var tex: ImageTexture = ImageTexture.create_from_image(img)
			_cache_put(path, tex)
			_apply_texture_to_visible(index)

	_pump()


# Applies a backend-rendered RAW thumbnail. Guards against stale results (list
# rescanned or selection changed since the request was made). Returns true on
# success, false if the index/path no longer match or img is null.
func apply_raw_thumb(index: int, path: String, img: Image) -> bool:
	if index < 0 or index >= _photos.size() or _photos[index]["path"] != path:
		_requested.erase(path)
		return false
	_requested.erase(path)
	if img == null:
		return false

	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_cache_put(path, tex)
	_apply_texture_to_visible(index)
	return true


# Pushes a cached texture onto whichever pool tile is currently bound to index.
func _apply_texture_to_visible(index: int) -> void:
	var path: String = _photos[index]["path"]
	for tile in _pool:
		if tile.visible and tile.get_photo_index() == index:
			tile.set_texture(_cache_get(path))
			return


# --- Texture LRU ---------------------------------------------------------------

func _cache_put(path: String, tex: Texture2D) -> void:
	if _tex_cache.has(path):
		_tex_lru.erase(path)
	_tex_cache[path] = tex
	_tex_lru.append(path)
	while _tex_lru.size() > MAX_CACHE_TEXTURES:
		var oldest: String = _tex_lru.pop_front()
		_tex_cache.erase(oldest)


func _cache_get(path: String) -> Texture2D:
	if not _tex_cache.has(path):
		return null
	_tex_lru.erase(path)
	_tex_lru.append(path)
	return _tex_cache[path]
