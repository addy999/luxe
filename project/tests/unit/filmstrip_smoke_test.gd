extends SceneTree

# Filmstrip pure-logic smoke test: virtualized layout math, collapse toggle,
# stub-source binding/refresh, and selection reveal. No backend, no fixtures.
# Run: Godot --headless --path godot-poc/project --script res://tests/filmstrip_smoke_test.gd

const FilmstripScript := preload("res://Filmstrip.gd")

var _failed: bool = false


func _die(msg: String) -> void:
	printerr("FILMSTRIP_SMOKE: FAIL: " + msg)
	_failed = true
	quit(1)


func _initialize() -> void:
	_test_layout_math()
	_test_collapse()
	_test_binding()
	_test_reveal()
	await _test_strip_area_lays_out()
	if _failed:
		return
	print("FILMSTRIP_SMOKE: PASS")
	quit(0)


# Minimal duck-typed source: the five filmstrip_* methods over a path list.
class StubSource:
	var paths: PackedStringArray = PackedStringArray()
	var textures: Dictionary = {}   # path -> Texture2D
	var requested: Array[int] = []  # visible indices passed to request_thumb

	func filmstrip_count() -> int:
		return paths.size()

	func filmstrip_path(i: int) -> String:
		return paths[i] if i >= 0 and i < paths.size() else ""

	func filmstrip_texture(path: String) -> Texture2D:
		return textures.get(path)

	func filmstrip_edited(_path: String) -> bool:
		return false

	func filmstrip_rejected(_path: String) -> bool:
		return false

	func request_thumb(vi: int) -> void:
		requested.append(vi)


func _make_strip(count: int) -> Array:
	var strip = FilmstripScript.new()
	var src = StubSource.new()
	for i in count:
		src.paths.append("/photos/img_%03d.arw" % i)
	# bind_source before _ready: _relayout guards on nodes _ready creates.
	strip.bind_source(src, "")
	get_root().add_child(strip)
	# _initialize runs before the root is ready; children added here get
	# NOTIFICATION_READY (and thus _ready) on the next frame, so await it.
	await process_frame
	return [strip, src]


func _test_layout_math() -> void:
	var strip = FilmstripScript.new()
	# Tile x-position and content width math must line up so the last tile is
	# reachable at max scroll (MARGIN + i*(W+SEP); content = margins + tiles + seps).
	var last_x: float = strip._tile_x(99)
	var expected_x: float = FilmstripScript.MARGIN + 99 * float(FilmstripScript.TILE_WIDTH + FilmstripScript.SEP)
	if absf(last_x - expected_x) > 0.01:
		_die("tile_x mismatch: %f vs %f" % [last_x, expected_x])
		return
	var total_w: float = FilmstripScript.MARGIN * 2.0 + 100 * FilmstripScript.TILE_WIDTH + 99 * FilmstripScript.SEP
	if total_w <= 100 * FilmstripScript.TILE_WIDTH:
		_die("content width math ignores separators")
		return
	print("FILMSTRIP_SMOKE: layout math OK")


func _test_collapse() -> void:
	var pair: Array = await _make_strip(50)
	var strip: Object = pair[0]
	strip.open = false
	if strip._strip_area.visible:
		_die("collapsed strip should hide StripArea")
		return
	if strip._arrow.text != "▼":
		_die("collapsed arrow should point down (click to reopen)")
		return
	strip.open = true
	if not strip._strip_area.visible:
		_die("reopened strip should show StripArea")
		return
	if strip._arrow.text != "▲":
		_die("open arrow should point up")
		return
	print("FILMSTRIP_SMOKE: collapse OK")


func _test_binding() -> void:
	var pair: Array = await _make_strip(40)
	var strip: Object = pair[0]
	var src: Object = pair[1]
	# Force layout with a real viewport size; headless default is small.
	strip._scroll.size = Vector2(600, FilmstripScript.TILE_HEIGHT)
	strip._relayout()
	# First tile bound to first path.
	if strip._pool.is_empty():
		_die("pool should not be empty after relayout")
		return
	if strip._pool[0].get_bound_path() != src.paths[0]:
		_die("first tile bound to wrong path: %s" % strip._pool[0].get_bound_path())
		return
	# Untextured visible tiles must ask the source to load a thumb, so the
	# strip can fill photos the grid never scrolled to.
	if not src.requested.has(0):
		_die("relayout should call request_thumb for untextured visible tile 0")
		return
	# Texture propagation: assign one, refresh, tile picks it up.
	var img: Image = Image.create(8, 8, false, Image.FORMAT_RGB8)
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	src.textures[src.paths[0]] = tex
	strip.refresh()
	if strip._pool[0]._texture != tex:
		_die("refresh() should push the new texture into the bound tile")
		return
	# Selection follows set_selected.
	strip.set_selected(src.paths[3])
	if strip._selected_path != src.paths[3]:
		_die("set_selected should update _selected_path")
		return
	print("FILMSTRIP_SMOKE: binding OK")


func _test_reveal() -> void:
	var pair: Array = await _make_strip(100)
	var strip: Object = pair[0]
	var src: Object = pair[1]
	strip._scroll.size = Vector2(600, FilmstripScript.TILE_HEIGHT)
	strip._relayout()
	strip.set_selected(src.paths[90])
	strip.reveal_selected()
	if strip._scroll.scroll_horizontal <= 0:
		_die("reveal_selected should scroll toward the far tile")
		return
	var stride: float = FilmstripScript.TILE_WIDTH + FilmstripScript.SEP
	var tile_center: float = strip._tile_x(90) + FilmstripScript.TILE_WIDTH * 0.5
	var vis_center: float = strip._scroll.scroll_horizontal + 300.0
	if absf(tile_center - vis_center) > stride * 12.0:
		_die("revealed tile not within the viewport neighborhood")
		return
	print("FILMSTRIP_SMOKE: reveal OK")


# Regression: StripArea must be a layout container. A plain Control does not
# lay out its children, so the ScrollContainer stayed 0-wide and clipped every
# tile, rendering the strip as an empty grey box.
func _test_strip_area_lays_out() -> void:
	var pair: Array = await _make_strip(30)
	var strip: Object = pair[0]
	if not (strip._strip_area is Container):
		_die("StripArea must be a Container so it sizes the ScrollContainer")
		return
	# Give the strip a real width the way the Edit-view VBox does, then let
	# the container pass run.
	strip.size = Vector2(900, 120)
	strip._strip_area.size = Vector2(900, 92)
	await process_frame
	if strip._scroll.size.x <= 0.0:
		_die("ScrollContainer width is 0; tiles would all be clipped")
		return
	if absf(strip._scroll.size.x - strip._strip_area.size.x) > 1.0:
		_die("ScrollContainer (%f) should span StripArea (%f)" % [
			strip._scroll.size.x, strip._strip_area.size.x])
		return
	print("FILMSTRIP_SMOKE: strip area layout OK")
