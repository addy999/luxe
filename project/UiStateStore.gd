class_name UiStateStore

# App-level UI state persisted across restarts: library thumbnail zoom,
# hide-rejected filter, last opened photo, right panel width, filmstrip
# height, library export settings. One flat versioned JSON at the top
# of user:// (read/written whole, so new fields need no schema per record).
# Mirrors Library.gd's versioned JSON + all-or-nothing validation and
# RejectStore's atomic tmp+rename write.

const STORE_PATH: String = "user://ui_state.json"
const VERSION: int = 1


# Defaults for every tracked field; load() merges a validated file over these.
static func defaults() -> Dictionary:
	return {
		"library_zoom_pct": 100.0,
		"hide_rejected": false,
		"last_photo": "",
		"right_panel_width": 500.0,
		"right_panel_height": 420.0,  # compact (stacked) layout
		"filmstrip_height": 92.0,  # Filmstrip.MIN_STRIP_HEIGHT
		"export_dir": "",
		"export_format": "jpg",  # jpg | png | tif
		"export_locations": [],  # libraries checked for whole-library export
		"export_jpeg_quality": 90,
		"export_png_bpp": 8,
		"export_tif_bpp": 16,
		"export_resize": false,
		"export_long_edge": 2048,
		"export_color_space": "srgb",  # srgb | p3 | adobergb | prophoto
		"export_metadata": true,
	}


# Whole-state load. Returns defaults() on missing file, malformed JSON,
# version mismatch, or bad shape (all-or-nothing). Wrong-typed individual
# fields fall back to their default instead of sinking the whole state.
static func load(path: String = STORE_PATH) -> Dictionary:
	var state: Dictionary = defaults()
	if not FileAccess.file_exists(path):
		return state
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return state
	var data: Dictionary = parsed
	if int(data.get("version", -1)) != VERSION:
		return state
	if not data.has("values") or not (data["values"] is Dictionary):
		return state
	var values: Dictionary = data["values"]
	var zoom: Variant = values.get("library_zoom_pct", state["library_zoom_pct"])
	if zoom is float or zoom is int:
		state["library_zoom_pct"] = float(zoom)
	var hide: Variant = values.get("hide_rejected", state["hide_rejected"])
	if hide is bool:
		state["hide_rejected"] = hide
	var photo: Variant = values.get("last_photo", state["last_photo"])
	if photo is String:
		state["last_photo"] = photo
	var panel_width: Variant = values.get("right_panel_width", state["right_panel_width"])
	if panel_width is float or panel_width is int:
		state["right_panel_width"] = float(panel_width)
	var panel_height: Variant = values.get("right_panel_height", state["right_panel_height"])
	if panel_height is float or panel_height is int:
		state["right_panel_height"] = float(panel_height)
	var strip_height: Variant = values.get("filmstrip_height", state["filmstrip_height"])
	if strip_height is float or strip_height is int:
		state["filmstrip_height"] = float(strip_height)
	var export_dir: Variant = values.get("export_dir", state["export_dir"])
	if export_dir is String:
		state["export_dir"] = export_dir
	var export_format: Variant = values.get("export_format", state["export_format"])
	if export_format is String and export_format in ["jpg", "png", "tif"]:
		state["export_format"] = export_format
	var export_locations: Variant = values.get("export_locations", state["export_locations"])
	if export_locations is Array:
		state["export_locations"] = export_locations
	# Scalar export settings: kept when the stored type matches the default's;
	# JSON reads every number back as float, so int defaults accept floats.
	for key: String in ["export_jpeg_quality", "export_png_bpp", "export_tif_bpp",
			"export_resize", "export_long_edge", "export_color_space", "export_metadata"]:
		var v: Variant = values.get(key)
		if state[key] is int and (v is float or v is int):
			state[key] = int(v)
		elif typeof(v) == typeof(state[key]):
			state[key] = v
	return state


# Atomic tmp+rename write of the whole state; a crash mid-write cannot corrupt
# an existing file. Returns false on any I/O failure.
static func save(state: Dictionary, path: String = STORE_PATH) -> bool:
	var payload: Dictionary = {"version": VERSION, "values": state}
	var text: String = JSON.stringify(payload, "\t")

	var tmp_path: String = path + ".tmp"
	var file: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()

	var err: int = DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path),
		ProjectSettings.globalize_path(path))
	if err != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return false
	return true
