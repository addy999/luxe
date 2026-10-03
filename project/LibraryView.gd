extends HBoxContainer
class_name LibraryView

# Library photo-browsing view: a sidebar of scan locations and a thumbnail
# grid for the selected location. Main.gd instances this scene and listens
# for photo_activated to switch into the editor.

signal photo_activated(path: String)
# Mirrors the sidebar CountLabel text; Main.gd routes this to a bottom-bar label.
signal status_changed(status: String)
signal add_location_requested()
# A visible, untextured RAW tile needs a backend-rendered thumbnail; Main.gd
# owns the backend and handles the actual render.
signal raw_thumb_requested(index: int)

const LibraryItemScript := preload("res://LibraryItem.gd")

const THUMB_WORKERS: int = 2
const MAX_LIVE_THUMBS: int = 400
const _THUMB_DEBOUNCE_SEC: float = 0.1
const _GRID_MARGIN: int = 16
const _SCROLL_PRELOAD_SCREENS: float = 1.0

@onready var locations_vbox: VBoxContainer = $Sidebar/SidebarMargin/SidebarVBox/LocationsVBox
@onready var add_location_button: Button = $Sidebar/SidebarMargin/SidebarVBox/AddLocationButton
@onready var count_label: Label = $Sidebar/SidebarMargin/SidebarVBox/CountLabel
@onready var grid_scroll: ScrollContainer = $GridPanel/GridScroll
@onready var grid: GridContainer = $GridPanel/GridScroll/GridMargin/Grid
@onready var empty_state: CenterContainer = $EmptyState

var _add_location_dialog: FileDialog = null
var _thumb_timer: Timer = null

var _locations: PackedStringArray = PackedStringArray()
var _selected_location: String = ""

var _photos: Array[Dictionary] = []
var _items: Array[LibraryItem] = []
var _cursor: int = -1

var _scan_generation: int = 0
var _scanning: bool = false

# --- Bounded thumbnail workers -------------------------------------------------
var _queue: Array[int] = []
var _inflight: int = 0
var _mutex: Mutex = Mutex.new()
var _live_thumb_indices: Array[int] = []


func _ready() -> void:
	# Resolved by node path, not the ThemeManager identifier: autoloads are not
	# registered in --script mode, where a direct identifier fails to compile.
	var theme_manager: Node = get_node_or_null("/root/ThemeManager")
	if theme_manager != null:
		theme_manager.theme_changed.connect(_on_theme_changed)

	grid.focus_mode = Control.FOCUS_ALL
	grid.gui_input.connect(_on_grid_gui_input)
	grid_scroll.resized.connect(_on_grid_scroll_resized)
	grid_scroll.get_v_scroll_bar().value_changed.connect(_on_grid_scroll_changed)

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


func on_view_entered() -> void:
	grid.grab_focus()
	_request_visible_thumbs()


func get_photo_count() -> int:
	return _photos.size()


# Returns the photo dict at index, or an empty Dictionary if out of range.
func get_photo(index: int) -> Dictionary:
	if index < 0 or index >= _photos.size():
		return {}
	return _photos[index]


func _on_theme_changed(_is_dark: bool) -> void:
	queue_redraw()


# --- Status ---------------------------------------------------------------------

func _update_status(status: String) -> void:
	count_label.text = status
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
		_photos.clear()
		_populate_grid()
		if _locations.size() > 0:
			_select_location(_locations[0])
		else:
			_update_status("No photos yet")
	_rebuild_sidebar()


# --- Sidebar ---------------------------------------------------------------------

func _rebuild_sidebar() -> void:
	for child in locations_vbox.get_children():
		child.queue_free()

	for dir_path: String in _locations:
		locations_vbox.add_child(_build_location_row(dir_path))


func _build_location_row(dir_path: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var missing: bool = not DirAccess.dir_exists_absolute(dir_path)
	var label_text: String = dir_path.get_file()
	if label_text.is_empty():
		label_text = dir_path
	if missing:
		label_text += " (missing)"

	var select_btn := Button.new()
	select_btn.flat = true
	select_btn.focus_mode = Control.FOCUS_NONE
	select_btn.text = label_text
	select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	select_btn.toggle_mode = true
	select_btn.button_pressed = (dir_path == _selected_location)
	select_btn.disabled = missing
	select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	select_btn.pressed.connect(_select_location.bind(dir_path))
	row.add_child(select_btn)

	var remove_btn := Button.new()
	remove_btn.flat = true
	remove_btn.focus_mode = Control.FOCUS_NONE
	remove_btn.text = "×"
	remove_btn.custom_minimum_size = Vector2(24, 0)
	remove_btn.pressed.connect(_on_remove_location_pressed.bind(dir_path))
	row.add_child(remove_btn)

	return row


func _select_location(dir_path: String) -> void:
	_selected_location = dir_path
	_rebuild_sidebar()
	_scan_selected_location()


# --- Scanning ---------------------------------------------------------------------

func _scan_selected_location() -> void:
	if _selected_location.is_empty() or not DirAccess.dir_exists_absolute(_selected_location):
		_photos.clear()
		_populate_grid()
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
	_photos = results
	_populate_grid()
	_update_status("%d photos" % _photos.size() if _photos.size() != 1 else "1 photo")
	if _photos.is_empty():
		_update_status("No photos yet")


# --- Grid population ---------------------------------------------------------------

func _populate_grid() -> void:
	for child in grid.get_children():
		child.queue_free()
	_items.clear()
	_cursor = -1
	_live_thumb_indices.clear()
	_mutex.lock()
	_queue.clear()
	_mutex.unlock()

	for i in _photos.size():
		var item := LibraryItemScript.new()
		item.setup(i, _photos[i])
		item.clicked.connect(_on_item_clicked)
		item.activated.connect(_on_item_activated)
		grid.add_child(item)
		_items.append(item)

	empty_state.visible = _photos.is_empty()
	_recompute_columns()
	_request_visible_thumbs()


func _on_item_clicked(index: int) -> void:
	_set_cursor(index)


func _on_item_activated(index: int) -> void:
	_set_cursor(index)
	_activate(index)


# --- Column layout -----------------------------------------------------------------

func _on_grid_scroll_resized() -> void:
	_recompute_columns()
	_request_visible_thumbs()


func _recompute_columns() -> void:
	var tile_w: float = LibraryItemScript.TILE_SIZE.x
	var sep: int = LibraryItemScript.GROUP_SEP
	var avail_w: float = grid_scroll.size.x - _GRID_MARGIN * 2.0 + sep
	var cols: int = maxi(1, floori(avail_w / (tile_w + sep)))
	if cols != grid.columns:
		grid.columns = cols


# --- Keyboard navigation ------------------------------------------------------------

func _on_grid_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var key_event: InputEventKey = event
	var cols: int = maxi(1, grid.columns)
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
	if _cursor == index:
		return
	if _cursor >= 0 and _cursor < _items.size():
		_items[_cursor].set_selected(false)
	_cursor = index
	if _cursor >= 0 and _cursor < _items.size():
		_items[_cursor].set_selected(true)
		grid_scroll.ensure_control_visible(_items[_cursor])
	_request_visible_thumbs()


func _activate(index: int) -> void:
	if index < 0 or index >= _photos.size():
		return
	photo_activated.emit(_photos[index]["path"])


# --- Thumbnail loading ---------------------------------------------------------------

func _on_grid_scroll_changed(_value: float) -> void:
	_request_visible_thumbs()


# Debounced: scroll/resize events fire rapidly, so the actual scan of visible
# items runs once per _THUMB_DEBOUNCE_SEC.
func _request_visible_thumbs() -> void:
	if _thumb_timer.is_stopped():
		_thumb_timer.start(_THUMB_DEBOUNCE_SEC)


func _on_thumb_timer_timeout() -> void:
	if _items.is_empty():
		return

	var viewport_rect: Rect2 = Rect2(grid_scroll.global_position, grid_scroll.size)
	var preload_margin: float = grid_scroll.size.y * _SCROLL_PRELOAD_SCREENS
	var expanded_rect: Rect2 = viewport_rect.grow_individual(0, preload_margin, 0, preload_margin)

	var to_enqueue: Array[int] = []
	for i in _items.size():
		var item: LibraryItem = _items[i]
		if item.has_texture():
			continue
		var item_rect := Rect2(item.global_position, item.size)
		if not expanded_rect.intersects(item_rect):
			continue
		if _photos[i].get("is_raw", false):
			raw_thumb_requested.emit(i)
			continue
		to_enqueue.append(i)

	_mutex.lock()
	for i in to_enqueue:
		if not _queue.has(i):
			_queue.append(i)
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

	if generation == _scan_generation and index >= 0 and index < _items.size() and img != null:
		var tex: ImageTexture = ImageTexture.create_from_image(img)
		_items[index].set_texture(tex)
		_live_thumb_indices.append(index)
		_evict_if_over_budget()

	_pump()


# Applies a backend-rendered RAW thumbnail to its tile. Guards against stale
# results (list rescanned or selection changed since the request was made).
# Returns true on success, false if the index/path no longer match or img is null.
func apply_raw_thumb(index: int, path: String, img: Image) -> bool:
	if index < 0 or index >= _photos.size():
		return false
	if _photos[index]["path"] != path:
		return false
	if img == null:
		return false

	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_items[index].set_texture(tex)
	_live_thumb_indices.append(index)
	_evict_if_over_budget()
	return true


# Evicts textures from tiles farthest from the viewport center until back
# under MAX_LIVE_THUMBS; disk cache makes re-decode on scroll-back cheap.
func _evict_if_over_budget() -> void:
	if _live_thumb_indices.size() <= MAX_LIVE_THUMBS:
		return

	var viewport_center: float = grid_scroll.global_position.y + grid_scroll.size.y * 0.5
	_live_thumb_indices.sort_custom(func(a: int, b: int) -> bool:
		var dist_a: float = absf(_items[a].global_position.y - viewport_center)
		var dist_b: float = absf(_items[b].global_position.y - viewport_center)
		return dist_a > dist_b)

	while _live_thumb_indices.size() > MAX_LIVE_THUMBS:
		var farthest: int = _live_thumb_indices.pop_front()
		if farthest >= 0 and farthest < _items.size():
			_items[farthest].clear_texture()
