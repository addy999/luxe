extends Control

# Luxe: main scene controller bridging the GDExtension DtBackend to the UI.
# Two decoupled view knobs (edit resolution on the backend, display zoom on the
# frontend); see docs/PERF-IMPROVEMENT.md.

@onready var scroll_container: ScrollContainer = $Root/MiddleHBox/Scroll
@onready var panel_scroll: ScrollContainer = $Root/MiddleHBox/RightPanel/PanelScroll
@onready var texture_rect: TextureRect = $Root/MiddleHBox/Scroll/Center/TextureRect
@onready var empty_state: CenterContainer = $Root/MiddleHBox/EmptyState
@onready var exposure_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ExposureRow/ExposureSlider
@onready var exposure_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ExposureRow/ExposureValueLabel
@onready var contrast_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ContrastRow/ContrastSlider
@onready var contrast_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ContrastRow/ContrastValueLabel
@onready var highlights_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/HighlightsRow/HighlightsSlider
@onready var highlights_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/HighlightsRow/HighlightsValueLabel
@onready var shadows_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ShadowsRow/ShadowsSlider
@onready var shadows_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ShadowsRow/ShadowsValueLabel
@onready var blacks_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/BlacksRow/BlacksSlider
@onready var blacks_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/BlacksRow/BlacksValueLabel
@onready var whites_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/WhitesRow/WhitesSlider
@onready var whites_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/WhitesRow/WhitesValueLabel
@onready var dehaze_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/DehazeRow/DehazeSlider
@onready var dehaze_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/DehazeRow/DehazeValueLabel
@onready var sharpening_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/SharpeningRow/SharpeningSlider
@onready var sharpening_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/SharpeningRow/SharpeningValueLabel
@onready var noise_reduction_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/NoiseReductionRow/NoiseReductionSlider
@onready var noise_reduction_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/NoiseReductionRow/NoiseReductionValueLabel
@onready var straighten_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/StraightenRow/StraightenSlider
@onready var straighten_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/StraightenRow/StraightenValueLabel
@onready var saturation_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/SaturationRow/SaturationSlider
@onready var saturation_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/SaturationRow/SaturationValueLabel
@onready var vibrance_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/VibranceRow/VibranceSlider
@onready var vibrance_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/VibranceRow/VibranceValueLabel
@onready var tone_curve_editor: ToneCurveEditor = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ToneCurveEditor
@onready var white_balance_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/WhiteBalanceRow/WhiteBalanceSlider
@onready var white_balance_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/WhiteBalanceRow/WhiteBalanceValueLabel
@onready var tint_slider: HSlider = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/TintRow/TintSlider
@onready var tint_value_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/TintRow/TintValueLabel
@onready var wb_mode_bar: HBoxContainer = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/WbModeBar
@onready var edit_res_option: OptionButton = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/EditResOptionButton
@onready var open_button: Button = $Root/TopBar/TopBarRow/OpenButton
@onready var export_button: Button = $Root/TopBar/TopBarRow/ExportButton
@onready var theme_button: Button = $Root/TopBar/TopBarRow/ThemeButton
@onready var resolution_label: Label = $Root/BottomBar/BottomRow/ResolutionLabel
@onready var zoom_slider: HSlider = $Root/TopBar/TopBarRow/ZoomSlider
@onready var fit_button: Button = $Root/TopBar/TopBarRow/FitButton
@onready var zoom_value_label: Label = $Root/TopBar/TopBarRow/ZoomValueLabel
@onready var file_dialog: FileDialog = $FileDialog
@onready var export_dialog: FileDialog = $ExportDialog
@onready var view_tab_bar: TabBar = $Root/TopBar/TopBarRow/ViewTabBar
@onready var library_view: LibraryView = $Root/LibraryView
@onready var middle_hbox: HBoxContainer = $Root/MiddleHBox
@onready var library_status_label: Label = $Root/BottomBar/BottomRow/LibraryStatusLabel
@onready var top_vsep: Control = $Root/TopBar/TopBarRow/VSep
@onready var reject_button: Button = $Root/TopBar/TopBarRow/RejectButton
@onready var hide_rejected_button: Button = $Root/TopBar/TopBarRow/HideRejectedButton
@onready var filename_label: Label = $Root/TopBar/FilenameLabel
@onready var filmstrip: Filmstrip = $Root/Filmstrip

# --- Edit-view QUICK ACTIONS cluster (RightPanel section, below VIEW) ---------
@onready var quick_actions_header: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/QuickActionsHeader
@onready var edit_cluster: HBoxContainer = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/EditClusterRow
@onready var cluster_prev_button: Button = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/EditClusterRow/ClusterPrevButton
@onready var cluster_next_button: Button = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/EditClusterRow/ClusterNextButton
@onready var cluster_crop_button: Button = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/EditClusterRow/ClusterCropButton
@onready var cluster_rotate_ccw_button: Button = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/EditClusterRow/ClusterRotateCcwButton
@onready var cluster_rotate_cw_button: Button = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/EditClusterRow/ClusterRotateCwButton
@onready var cluster_reject_button: Button = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/EditClusterRow/ClusterRejectButton
@onready var cluster_compare_button: Button = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/EditClusterRow/ClusterCompareButton

const CropOverlayScript := preload("res://CropOverlay.gd")
const ThumbnailIndexerScript := preload("res://ThumbnailIndexer.gd")
const ResizeHandleScript := preload("res://ResizeHandle.gd")
const ColorWbScript := preload("res://ColorWb.gd")
const ColorReadoutScript := preload("res://ColorReadout.gd")

# --- View switching (Library vs Edit) ------------------------------------------
enum View { LIBRARY, EDIT }

var _view: int = View.LIBRARY
# TabBar.current_tab emits tab_changed on assignment; guards _set_view recursion.
var _switching_view: bool = false
var _edit_only_controls: Array[Control] = []
var _library_only_controls: Array[Control] = []

var _crop_overlay: Control = null
var _crop_bar: HBoxContainer = null
var _crop_before_edit: Rect2 = Rect2(0, 0, 1, 1)

# --- Before/after compare (hold Space or the Before button) --------------------
var _comparing: bool = false
# Lazily rendered on first hold per photo; as-shot neutral tonal values, with
# the CURRENT crop/orientation so framing matches the edited view. Cleared
# whenever a new photo loads or crop/orientation/edit-scale change.
var _before_texture: ImageTexture = null
# _edit_scale the cached _before_texture was rendered at; a mismatch forces a
# re-render so compare never shows a stale resolution.
var _before_texture_scale: float = -1.0
# As-shot defaults dict (same shape as _params), snapshotted in open_photo.
var _neutral_params: Dictionary = {}

# Latest whole-image Edit render, held so the debounced save can downsample it
# into the edited library thumbnail without re-rendering. _last_render_sig is
# the params signature captured at render dispatch (not completion), so a
# slider move during an in-flight render still tags the frame with the params
# it was actually rendered from; a mismatch means the frame is stale and must
# not be written.
var _last_render_image: Image = null
var _last_render_sig: String = ""
@onready var top_bar: PanelContainer = $Root/TopBar
@onready var right_panel: PanelContainer = $Root/MiddleHBox/RightPanel
@onready var right_panel_handle: Control = $Root/MiddleHBox/RightPanelHandle
@onready var navigator = $Navigator
@onready var bottom_bar: PanelContainer = $Root/BottomBar

var backend: DtBackend = null
var image_texture: ImageTexture = null

# --- Background thumbnail indexer (worker process, spawned once per session) --
var _thumb_indexer: Node = null
# Last priority list written to thumb_worker_priority.json, so a stationary
# view does not rewrite the same unchanged list every poll tick.
var _last_priority_paths: PackedStringArray = PackedStringArray()
# True while the worker has outstanding work; makes the status label visible
# in both views (normally Library-only) and drives its progress text.
var _indexing_active: bool = false

var _image_loaded: bool = false

# Swaps the cached thumbnail (edited variant first) into the viewport and forces
# a draw, so the incoming photo is visible before open_photo blocks the main
# thread in load_image. No-op when neither thumb is cached. image_texture is
# re-bound by _on_process_done when the real render lands.
func _show_thumb_placeholder(path: String) -> void:
	var mtime: int = FileAccess.get_modified_time(path)
	var img: Image = ThumbnailCache.load_cached(ThumbnailCache.edited_cache_key(path, mtime))
	if img == null:
		img = ThumbnailCache.load_cached(ThumbnailCache.cache_key(path, mtime))
	if img == null:
		return
	texture_rect.texture = ImageTexture.create_from_image(img)
	filename_label.text = path.get_file()
	RenderingServer.force_draw()


# --- RAW library thumbnails ----------------------------------------------------
# Rendering itself now happens entirely in the background worker process (see
# "Background thumbnail indexer" in docs/GODOT_FRONTEND_NOTES.md); this scale
# constant is still used by _render_backend_thumb, called directly by the
# worker branch and by _resolve_thumb_hash on first open.
const _RAW_THUMB_SCALE: float = 0.25   # ~320-360px on a 1440x900 F mip
var _edited_path: String = ""          # last successfully opened image path

# --- Persistent edit history (EditStore) --------------------------------------
var _edit_key: String = ""             # EditStore record id for the open photo ("" = none)
var _edit_thumb_hash: String = ""      # thumbnail content hash, stored in the record's meta
var _edit_file_name: String = ""       # base name of the open photo, stored in the record's meta
var _save_timer: Timer = null          # one-shot debounce for auto-save
const _SAVE_DEBOUNCE_SEC: float = 0.8
# True while open_photo restores params; suppresses the auto-save arm on the
# load-time _request_render so merely opening a photo never writes a record.
var _restoring: bool = false

# --- Persistent UI state (UiStateStore) ---------------------------------------
# Write-through: each change point (zoom step, filter toggle, photo open) saves
# the whole dict; it's one tiny atomic file.
var _ui_state: Dictionary = UiStateStore.defaults()

# Per-image as-shot CCT and tint; the As Shot / reset target.
var _wb_default_temperature: float = 6500.0
var _wb_default_tint: float = 0.0
# True from an Auto click until _resolve_auto_wb measures the image; the
# measurement runs inside _start_process so it never overlaps a render task.
var _auto_wb_pending: bool = false
var _reset_buttons: Array[Button] = []

# --- Edit state: the authoritative "what to render" ---------------------------
var _params: Dictionary = {
	"exposure": 0.0,
	"contrast": 0.0,
	"highlights": -50.0,
	"shadows": 50.0,
	"blacks": 0.0,
	"whites": 0.0,
	"dehaze": 0.0,
	"sharpening": 0.0,
	"denoise": 0.0,
	"saturation": 25.0,
	"desaturation": 0.0,
	"vibrance": 25.0,
	"tonecurve": PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 1.0)]),
	"wb_temperature": 6500.0,
	"wb_tint": 0.0,
	"wb_mode": ColorWbScript.AS_SHOT,
	"wb_override": false,
	"crop": Rect2(0, 0, 1, 1),
	"orientation": 0,
	"straighten_angle": 0.0,
}

# --- Slider offsets vs. module defaults ----------------------------------------
const _MODULE_RANGES: Dictionary = {
	# key: [module_min, module_default, module_max]
	"highlights": [-100.0, -50.0, 100.0],
	"shadows": [-100.0, 50.0, 100.0],
	"saturation": [0.0, 25.0, 100.0],
	"vibrance": [0.0, 25.0, 100.0],
}


func _map_offset_to_module(key: String, offset: float) -> float:
	var range_vals: Array = _MODULE_RANGES[key]
	var lo: float = range_vals[0]
	var dflt: float = range_vals[1]
	var hi: float = range_vals[2]
	if offset <= 0.0:
		return lo + (offset + 50.0) / 50.0 * (dflt - lo)
	return dflt + offset / 50.0 * (hi - dflt)


# Inverse of _map_offset_to_module: recovers the -50..50 UI slider offset from a
# stored module-space value, for restoring persisted edits into the sliders.
func _map_module_to_offset(key: String, module_value: float) -> float:
	var range_vals: Array = _MODULE_RANGES[key]
	var lo: float = range_vals[0]
	var dflt: float = range_vals[1]
	var hi: float = range_vals[2]
	if module_value <= dflt:
		if dflt - lo == 0.0:
			return 0.0
		return (module_value - lo) / (dflt - lo) * 50.0 - 50.0
	if hi - dflt == 0.0:
		return 0.0
	return (module_value - dflt) / (hi - dflt) * 50.0


# Last values pushed to the backend, keyed like _params.
var _applied_params: Dictionary = {}
# What the pipe's white balance currently holds ("neutral" or "temp,tint");
# "" after a photo load, before the first apply.
var _wb_backend_key: String = ""

var _processing: bool = false
# Set when a request arrived mid-render; exactly one follow-up runs.
var _render_queued: bool = false
var _current_task_id: int = -1

# --- Live-render EWMA gate (docs/PERF-IMPROVEMENT.md fix 4) --------------------
const _RENDER_AVG_COUNT: int = 8
var _render_avg_usec: float = 0.0        # EWMA of render start-to-start latency.
var _last_render_start_usec: int = 0     # Start time of the most recent render (0 = none).
var _render_start_usec: int = 0          # Start time of the in-flight render, for the EWMA.
var _gate_timer: Timer = null            # One-shot trailing render when the gate is shut.
var _exporting: bool = false
var _export_path: String = ""
var _source_basename: String = "export"

# --- Edit resolution (backend render scale) ------------------------------------
# Fraction of the preview mip the pipe processes; 100% uses the full pipe.
const _EDIT_MODES: Array = [
	{"id": 0, "label": "100%", "scale": 1.00},
	{"id": 1, "label": "75%", "scale": 0.75},
	{"id": 2, "label": "50%", "scale": 0.50},
	{"id": 3, "label": "25%", "scale": 0.25},
	{"id": 4, "label": "Auto", "scale": -1.0}, # scale computed by _auto_compute_scale()
]
const _EDIT_DEFAULT_ID: int = 2 # 50%, fallback used until an image's size is known.
const _EDIT_AUTO_ID: int = 4
const _EDIT_SCALE_EPSILON: float = 0.01 # min |delta| in _edit_scale to re-render
var _edit_scale: float = 0.50
var _edit_mode_id: int = _EDIT_DEFAULT_ID # dropdown id; see docs/GODOT_FRONTEND_NOTES.md
var _auto_floor_scale: float = 0.50 # Auto's lower bound; set per image load
const _AUTO_FULL_ZOOM: float = 1.5 # display zoom at which Auto reaches 100% edit res


func _is_auto_mode() -> bool:
	return _edit_mode_id == _EDIT_AUTO_ID

# Size-adaptive default edit scale, by raw megapixels (tiers in order).
const _EDIT_DEFAULT_BY_SIZE: Array = [
	{"min_megapixels": 20.0, "id": 3}, # huge (e.g. medium format, stitched) -> 25%
	{"min_megapixels": 12.0, "id": 2}, # large (typical modern camera) -> 50%
	{"min_megapixels": 0.0, "id": 0},  # normal/HD -> 100%
]


func _pick_default_edit_mode_id(raw_w: int, raw_h: int) -> int:
	if raw_w <= 0 or raw_h <= 0:
		return _EDIT_DEFAULT_ID
	var megapixels: float = (raw_w * raw_h) / 1000000.0
	for tier in _EDIT_DEFAULT_BY_SIZE:
		if megapixels >= tier["min_megapixels"]:
			return tier["id"]
	return _EDIT_DEFAULT_ID

const _WHOLE_IMAGE_VIEWPORT: int = 1000000

# --- Display zoom (frontend TextureRect scale) --------------------------------
const _ZOOM_MIN_PCT: float = 10.0
const _ZOOM_MAX_PCT: float = 400.0
var _display_zoom: float = -1.0 # -1.0 = Fit; otherwise native-relative scale.

# --- Library thumbnail zoom (shares TopBar's ZoomSlider/ZoomValueLabel) --------
const _LIBRARY_ZOOM_MIN_PCT: float = 50.0
const _LIBRARY_ZOOM_MAX_PCT: float = 400.0
var _library_thumb_zoom_pct: float = 100.0

# --- Right settings panel width (resizable via RightPanelHandle) --------------
const _RIGHT_PANEL_MIN_WIDTH: float = 350.0
const _RIGHT_PANEL_MAX_WIDTH: float = 650.0

const _STRETCH_SCALE: int = 0
const _STRETCH_KEEP_ASPECT_CENTERED: int = 5

var _dragging: bool = false


# Dev-only env setup for the backend's datadir detection (docs/DARKTABLE_API_NOTES.md A).
func _configure_dt_backend_env() -> void:
	if not OS.has_feature("editor"):
		return
	if OS.has_environment("DT_BACKEND_DATADIR") and OS.has_environment("DT_BACKEND_MODULEDIR"):
		return
	var datadir: String = ProjectSettings.get_setting(
		"dt_backend/datadir", "res://../../source/build/share/darktable")
	var moduledir: String = ProjectSettings.get_setting(
		"dt_backend/moduledir", "res://../../source/build/lib/darktable")
	OS.set_environment("DT_BACKEND_DATADIR", ProjectSettings.globalize_path(datadir))
	OS.set_environment("DT_BACKEND_MODULEDIR", ProjectSettings.globalize_path(moduledir))


func _ready() -> void:
	var _user_args: PackedStringArray = OS.get_cmdline_user_args()
	if _user_args.has("--thumb-worker"):
		_run_thumb_worker(_user_args)
		return

	_gate_timer = Timer.new()
	_gate_timer.one_shot = true
	_gate_timer.timeout.connect(_on_render_gate_timeout)
	add_child(_gate_timer)

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = _SAVE_DEBOUNCE_SEC
	_save_timer.timeout.connect(_on_save_timer_timeout)
	add_child(_save_timer)

	_setup_reset_buttons()
	_apply_mono_value_label_font()
	preload("res://EditPanelLayout.gd").build(
		$Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox)
	# Load before _setup_views: _set_view(LIBRARY) seeds the shared zoom slider
	# from _library_thumb_zoom_pct, so the restored value must be in place first.
	_ui_state = UiStateStore.load()
	_library_thumb_zoom_pct = clampf(
		float(_ui_state.get("library_zoom_pct", 100.0)),
		_LIBRARY_ZOOM_MIN_PCT, _LIBRARY_ZOOM_MAX_PCT)
	# LibraryView's own _ready (runs before this, as a child) already defaulted
	# to _locations[0]; re-home it on the restored photo's actual location so
	# the filmstrip/grid don't show the wrong library after a restart.
	var last_photo: String = _ui_state.get("last_photo", "")
	if last_photo != "" and FileAccess.file_exists(last_photo):
		library_view.select_location_for_path(last_photo)
	_setup_views()
	_apply_restored_ui_state()

	_animate_entrance()
	_update_empty_state()
	await get_tree().process_frame
	if not _init_backend():
		return
	_finish_ready()
	_maybe_reopen_last_photo()


# Applies persisted UI state on launch, after _setup_views connected the
# controls: the hide-rejected filter and the library zoom. Same appliers as
# the live change handlers, minus their write-back (the values came from
# disk). The last photo is reopened separately, after the backend is up.
func _apply_restored_ui_state() -> void:
	if _ui_state.get("hide_rejected", false):
		hide_rejected_button.set_pressed_no_signal(true)
		library_view.set_hide_rejected(true)
		# Label names the action the next click performs (see toggle handler).
		hide_rejected_button.text = "Show Rejected"
		hide_rejected_button.tooltip_text = "Show rejected photos"
	# The grid is zero-width at this point: this just parks the RAW scale (snap
	# is a no-op without a width); _finish_ready re-applies it snapped once
	# layout has run.
	library_view.set_thumb_zoom(_library_thumb_zoom_pct / 100.0)
	right_panel.custom_minimum_size.x = clampf(
		float(_ui_state["right_panel_width"]), _RIGHT_PANEL_MIN_WIDTH, _RIGHT_PANEL_MAX_WIDTH)
	filmstrip.set_height(float(_ui_state["filmstrip_height"]))


# Restores the last session's final state: reopen the last photo (its saved
# edits come back through EditStore inside open_photo) straight into the Edit
# view. Skipped when the file is gone, launching into Library as before.
func _maybe_reopen_last_photo() -> void:
	var path: String = _ui_state.get("last_photo", "")
	if path == "" or not FileAccess.file_exists(path):
		return
	open_photo(path)


func _setup_views() -> void:
	_edit_only_controls = [
		filename_label, export_button, fit_button,
		top_vsep, quick_actions_header, edit_cluster,
	]
	_library_only_controls = [
		reject_button, hide_rejected_button,
	]
	view_tab_bar.add_tab("Library")
	view_tab_bar.add_tab("Edit")
	# Connected after both tabs exist: adding the first tab to an empty TabBar
	# emits tab_changed, which would hit _set_view with a half-built bar.
	view_tab_bar.tab_changed.connect(_on_view_tab_changed)
	library_view.photo_activated.connect(_on_library_photo_activated)
	library_view.status_changed.connect(_on_library_status_changed)
	library_view.zoom_requested.connect(_on_library_zoom_requested)
	library_view.cursor_reject_state.connect(_on_cursor_reject_state)
	# The filmstrip reads LibraryView state through its duck-typed source; this
	# signal covers every mutation the strip needs to redraw for.
	library_view.photos_changed.connect(_on_library_photos_changed)
	library_view.locations_changed.connect(_on_library_locations_changed)
	filmstrip.photo_selected.connect(open_photo)
	filmstrip.bind_source(library_view, "")
	filmstrip.height_changed.connect(_on_filmstrip_height_changed)
	reject_button.pressed.connect(_on_reject_button_pressed)
	hide_rejected_button.toggled.connect(_on_hide_rejected_toggled)
	_setup_right_panel_handle()
	_set_view(View.LIBRARY)


# RightPanel is a fixed-width PanelContainer (size_flags_horizontal = 0), so
# the handle just drags its custom_minimum_size.x within a fixed range. The
# handle sits left of the panel: dragging right encroaches on the panel's
# space, so growing coordinates SHRINK it (sign -1).
func _setup_right_panel_handle() -> void:
	right_panel_handle.axis = ResizeHandleScript.Axis.HORIZONTAL
	right_panel_handle.min_size = _RIGHT_PANEL_MIN_WIDTH
	right_panel_handle.max_size = _RIGHT_PANEL_MAX_WIDTH
	right_panel_handle.sign = -1.0
	right_panel_handle.get_size_cb = Callable(self, "_get_right_panel_width")
	right_panel_handle.set_size_cb = Callable(self, "_set_right_panel_width")
	right_panel_handle.resize_ended.connect(_on_right_panel_resize_ended)


func _get_right_panel_width() -> float:
	return right_panel.custom_minimum_size.x


func _set_right_panel_width(width: float) -> void:
	right_panel.custom_minimum_size.x = width


func _on_right_panel_resize_ended(width: float) -> void:
	_ui_state["right_panel_width"] = width
	UiStateStore.save(_ui_state)


func _on_filmstrip_height_changed(height: float) -> void:
	_ui_state["filmstrip_height"] = height
	UiStateStore.save(_ui_state)


func _set_view(view: int) -> void:
	_view = view
	var in_library: bool = view == View.LIBRARY

	if in_library:
		# A hold that's still down when the view switches away (e.g. the mouse
		# clicked the tab bar while Space stayed held) would otherwise never
		# get its release event.
		_end_compare()
		# Leaving Edit: commit any pending debounced save before the backend may
		# be hijacked by RAW thumb jobs, then refresh the edited photo's badge so
		# a freshly-saved edit shows its dot on return to the grid.
		_flush_pending_save()
		if _edited_path != "":
			library_view.invalidate_thumb(_edited_path)
			library_view.refresh_edited_badge(_edited_path)
		# Cancel any pending/in-flight edit render before Library takes over the
		# backend. A render armed by a slider edit just before the switch would
		# otherwise fire HERE, in Library view, against a view that no longer
		# shows the texture it would produce. The pending edit is already in
		# _params + EditStore, so it re-renders when the photo is next opened.
		_quiesce_edit_render()

	library_view.visible = in_library
	middle_hbox.visible = not in_library
	filmstrip.visible = not in_library
	for control in _edit_only_controls:
		control.visible = not in_library
	for control in _library_only_controls:
		control.visible = in_library
	resolution_label.visible = not in_library
	library_status_label.visible = in_library or _indexing_active

	_switching_view = true
	view_tab_bar.current_tab = view
	_switching_view = false

	view_tab_bar.set_tab_disabled(View.EDIT, not _image_loaded)

	zoom_value_label.visible = not in_library

	# The per-view slider-restore below reassigns min/max, and reassigning a
	# Range's min/max re-clamps its value and EMITS value_changed (even via
	# code). Guard the whole restore so a stale clamp can't clobber the
	# stored zoom.
	_switching_view = true
	if in_library:
		# Library's 50..400 clamp range replaces Edit's 10..400; min/max must
		# be assigned before set_value_no_signal, since reassigning the range
		# re-clamps the slider's current value.
		zoom_slider.min_value = _LIBRARY_ZOOM_MIN_PCT
		zoom_slider.max_value = _LIBRARY_ZOOM_MAX_PCT
		zoom_slider.set_value_no_signal(_library_thumb_zoom_pct)
	else:
		zoom_slider.min_value = _ZOOM_MIN_PCT
		zoom_slider.max_value = _ZOOM_MAX_PCT
	_switching_view = false

	if in_library:
		library_view.on_view_entered()
	else:
		if _display_zoom < 0.0:
			_update_zoom_readout()
		else:
			zoom_slider.set_value_no_signal(_display_zoom * 100.0)
			_update_zoom_readout()
		# The strip was hidden a moment ago; sizes are stale, so reveal after
		# layout settles (same deferred pattern as the display layout below).
		filmstrip.set_selected(_edited_path)
		filmstrip.reveal_selected.call_deferred()
		# scroll_container.size is stale while MiddleHBox is hidden.
		_apply_display_layout.call_deferred()


func _on_view_tab_changed(tab: int) -> void:
	if _switching_view:
		return
	if tab == View.EDIT and not _image_loaded:
		_set_view(View.LIBRARY)
		return
	_set_view(tab)


func _on_library_photo_activated(path: String) -> void:
	open_photo(path)


func _on_library_status_changed(status: String) -> void:
	library_status_label.text = status


func _on_reject_button_pressed() -> void:
	library_view.toggle_reject_cursor()


func _on_hide_rejected_toggled(pressed: bool) -> void:
	library_view.set_hide_rejected(pressed)
	_ui_state["hide_rejected"] = pressed
	UiStateStore.save(_ui_state)
	# Label names the action the next click performs, not the current state.
	hide_rejected_button.text = "Show Rejected" if pressed else "Hide Rejected"
	hide_rejected_button.tooltip_text = \
		"Show rejected photos" if pressed else "Hide rejected photos"


# Reject-button pressed-state sync; LibraryView emits this on every reject
# toggle AND every cursor move, so the button always tracks the cursor photo.
func _on_cursor_reject_state(rejected: bool) -> void:
	reject_button.set_pressed_no_signal(rejected)


# Edit-view photo cycling: move to the prev/next photo in the current
# library's visible set (follows the hide-rejected toggle), but only when the
# open photo belongs to that library.
# Stops at the ends (no wrap). open_photo() flushes the pending save, waits
# out in-flight tasks, reloads params, and re-renders. No-ops outside Edit view
# or while a crop overlay / render / export is in flight, so navigation (from
# keys or the cluster buttons) never races the pipe.
func _edit_navigate(dir: int) -> void:
	if _view != View.EDIT or _crop_overlay != null or _processing or _exporting:
		return
	var idx: int = library_view.get_photo_index_master(_edited_path)
	if idx < 0:
		return
	var nxt: int = library_view.next_visible_master(idx, dir)
	if nxt < 0:
		return
	var next_path: String = library_view.get_photo_master_path(nxt)
	if next_path != "":
		open_photo(next_path)


# The strip only exists in Edit view, but it reads LibraryView state directly,
# so it refreshes regardless of which view is active (cheap: pool redraws).
# Deliberately does NOT call reveal_selected() here: this fires on every
# background thumb decode anywhere in the library, so re-revealing on each
# tick would yank the scroll back to the selected photo while the user is
# browsing elsewhere in the strip. reveal_selected() is called once, where
# the selection actually changes (entering Edit / opening a photo, below).
func _on_library_photos_changed() -> void:
	filmstrip.refresh()


# Returns true when a text-editing control currently holds keyboard focus, so
# Edit-view key shortcuts yield to typing (LineEdit/TextEdit grab the key in
# their own _gui_input).
func _text_field_focused() -> bool:
	var owner: Control = get_viewport().gui_get_focus_owner()
	return owner is LineEdit or owner is TextEdit


# _input runs before GUI focus navigation (step 1 of the viewport input order),
# so the Edit-view photo-cycling keys (Left/Right) and reject key (X) are caught
# here and marked handled, preventing a focused slider/control from eating the
# arrow keys as ui_left/ui_right focus traversal or value nudges. See
# docs/GODOT_FRONTEND_NOTES.md "Edit-view arrow-key input handling".
func _input(event: InputEvent) -> void:
	if _view != View.EDIT:
		return
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if _text_field_focused():
		return
	var kc: int = key_event.keycode
	if kc == KEY_SPACE and _image_loaded and _crop_overlay == null:
		# Caught on both press and release (unlike the other Edit-view keys
		# below), since the compare swap runs for the duration of the hold.
		if key_event.is_pressed():
			if not key_event.is_echo():
				_begin_compare()
		else:
			_end_compare()
		get_viewport().set_input_as_handled()
		return
	if not key_event.is_pressed() or key_event.is_echo():
		return
	if kc == KEY_LEFT or kc == KEY_RIGHT:
		# _edit_navigate no-ops on crop overlay / render / export in flight and
		# off-library photos.
		_edit_navigate(-1 if kc == KEY_LEFT else 1)
		get_viewport().set_input_as_handled()
	elif kc == KEY_X and _image_loaded:
		_toggle_reject_edited_photo()
		get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	var kc: int = (event as InputEventKey).keycode
	if kc == KEY_ESCAPE:
		if _crop_overlay != null:
			_on_crop_overlay_canceled()
			accept_event()
			return
		if _view == View.EDIT:
			_set_view(View.LIBRARY)
			accept_event()
		return


# Physical (device) pixel size of the screen.
func _display_pixel_size() -> Vector2i:
	var screen: int = DisplayServer.window_get_current_screen()
	var screen_size: Vector2i = DisplayServer.screen_get_size(screen)
	if screen_size.x <= 0 or screen_size.y <= 0:
		return Vector2i.ZERO
	var dpi_scale: float = maxf(1.0, DisplayServer.screen_get_scale(screen))
	return Vector2i(roundi(screen_size.x * dpi_scale), roundi(screen_size.y * dpi_scale))


func _init_backend() -> bool:
	_configure_dt_backend_env()
	backend = DtBackend.new()
	var display_size: Vector2i = _display_pixel_size()
	var ok: bool = backend.init(display_size.x, display_size.y)
	if not ok:
		open_button.disabled = true
		exposure_slider.editable = false
		contrast_slider.editable = false
		highlights_slider.editable = false
		shadows_slider.editable = false
		blacks_slider.editable = false
		whites_slider.editable = false
		dehaze_slider.editable = false
		saturation_slider.editable = false
		vibrance_slider.editable = false
		white_balance_slider.editable = false
		_set_color_wb_controls_enabled(false)
		for btn in _reset_buttons:
			btn.disabled = true
		return false
	return true


func _finish_ready() -> void:
	exposure_value_label.text = "%.2f" % exposure_slider.value
	contrast_value_label.text = "%.2f" % contrast_slider.value
	highlights_value_label.text = "%.2f" % highlights_slider.value
	shadows_value_label.text = "%.2f" % shadows_slider.value
	blacks_value_label.text = "%.2f" % blacks_slider.value
	whites_value_label.text = "%.2f" % whites_slider.value
	dehaze_value_label.text = "%.2f" % dehaze_slider.value
	ColorReadoutScript.apply(saturation_value_label, saturation_slider.value)
	ColorReadoutScript.apply(vibrance_value_label, vibrance_slider.value)
	white_balance_value_label.text = "%dK" % roundi(white_balance_slider.value)
	ColorReadoutScript.apply(tint_value_label, tint_slider.value)
	wb_mode_bar.mode_selected.connect(_on_wb_mode_selected)
	# No photo is open yet; open_photo enables the controls.
	_set_color_wb_controls_enabled(false)

	for mode in _EDIT_MODES:
		edit_res_option.add_item(mode["label"], mode["id"])
	edit_res_option.select(_EDIT_AUTO_ID)
	_edit_mode_id = _EDIT_AUTO_ID
	_edit_scale = _EDIT_MODES[_EDIT_DEFAULT_ID]["scale"]

	# Start in Fit; the scene already sets slider 100 + toggle on.
	_display_zoom = -1.0
	fit_button.set_pressed_no_signal(true)
	_update_zoom_readout()

	# Wider, easy-to-grab scrollbars (shared width; colors come from the theme).
	ScrollbarStyle.widen(scroll_container)
	ScrollbarStyle.widen(panel_scroll)

	scroll_container.resized.connect(_on_scroll_resized)
	# Scrollbar value_changed fires for every pan source (image drag, scrollbar
	# drag, zoom recenter), all of which set scroll_horizontal/vertical.
	scroll_container.get_h_scroll_bar().value_changed.connect(_on_scroll_moved)
	scroll_container.get_v_scroll_bar().value_changed.connect(_on_scroll_moved)
	navigator.pan_to.connect(_on_navigator_pan_to)

	texture_rect.gui_input.connect(_on_texture_rect_gui_input)

	ThemeManager.theme_changed.connect(_on_theme_changed)
	_on_theme_changed(ThemeManager.is_dark)

	cluster_prev_button.pressed.connect(_edit_navigate.bind(-1))
	cluster_next_button.pressed.connect(_edit_navigate.bind(1))
	cluster_prev_button.disabled = true
	cluster_next_button.disabled = true
	cluster_crop_button.toggled.connect(_on_crop_button_toggled)
	cluster_crop_button.disabled = true
	cluster_rotate_ccw_button.pressed.connect(_on_rotate_ccw_button_pressed)
	cluster_rotate_cw_button.pressed.connect(_on_rotate_cw_button_pressed)
	cluster_rotate_ccw_button.disabled = true
	cluster_rotate_cw_button.disabled = true
	cluster_reject_button.toggled.connect(_on_cluster_reject_button_toggled)
	cluster_reject_button.disabled = true
	cluster_compare_button.button_down.connect(_on_cluster_compare_button_down)
	cluster_compare_button.button_up.connect(_on_cluster_compare_button_up)
	cluster_compare_button.disabled = true

	# Launch restore pass 2: apply the restored library zoom against the grid's
	# real width now that layout has run (snap needs a width; _ready's pass ran
	# at zero). Also syncs the shared slider to the snapped value.
	_set_library_zoom(_library_thumb_zoom_pct)

	_start_thumb_indexer()


# (Re)targets the background RAW-thumbnail worker at every saved library
# location (not just the one currently browsed) so the grid and filmstrip both
# fill in regardless of where the user navigates. Safe to call repeatedly: the
# indexer node is created once and reused; each call restarts the worker on the
# current root set, so a library added/removed mid-session gets covered.
func _start_thumb_indexer() -> void:
	var locations: PackedStringArray = Library.load_locations()
	if locations.is_empty():
		return
	var roots: PackedStringArray = PackedStringArray()
	for location in locations:
		roots.append(ProjectSettings.globalize_path(location))
	if _thumb_indexer == null:
		_thumb_indexer = ThumbnailIndexerScript.new()
		add_child(_thumb_indexer)
	_thumb_indexer.start(roots, self)


# A library location was added or removed: re-point the worker at the new set.
func _on_library_locations_changed() -> void:
	_start_thumb_indexer()


# Polled by ThumbnailIndexer (~1x/second) while the worker fills the on-disk
# cache. Refreshes whichever view's visible tiles from disk: the grid always
# (cheap, also warms the cache for a later return to Library), and the filmstrip
# when it is showing (Edit view), since its visible range differs from the grid's.
func refresh_visible_from_cache() -> void:
	library_view.refresh_visible_from_cache()
	if filmstrip != null and filmstrip.visible:
		filmstrip.refresh_from_cache()
	_write_thumb_priority()


# Tells the worker which photos the user is currently looking at, most
# important (center of the active view) first. Writes only when the list
# differs from the last write, so a stationary view does not churn disk every
# poll tick.
func _write_thumb_priority() -> void:
	var paths: PackedStringArray = PackedStringArray()
	if filmstrip != null and filmstrip.visible:
		paths = filmstrip.get_visible_paths()
	elif library_view != null:
		paths = library_view.get_visible_paths()
	if paths == _last_priority_paths:
		return
	_last_priority_paths = paths
	ThumbWorkerIPC.write_priority(paths)


# Called by ThumbnailIndexer each poll tick while the worker is alive.
func on_index_progress(done: int, total: int) -> void:
	_indexing_active = total > 0 and done < total
	if _indexing_active:
		library_status_label.visible = true
		library_status_label.text = "Indexing thumbnails... %d/%d" % [done, total]
	elif not _view == View.LIBRARY:
		library_status_label.visible = false


# Called by ThumbnailIndexer once the worker finishes or gives up respawning.
# Text is left as-is: LibraryView's status_changed signal keeps it current
# whenever Library view is active; only visibility (Library-only again) needs
# restoring here.
func on_indexing_finished() -> void:
	_indexing_active = false
	library_status_label.visible = _view == View.LIBRARY


func _update_empty_state() -> void:
	var empty: bool = not _image_loaded
	empty_state.visible = empty
	scroll_container.visible = not empty


func _animate_entrance() -> void:
	# One-shot launch animation: bars fade in and scale 0.98 -> 1.0, staggered
	# (tween modulate/scale, NOT position; see docs/GODOT_FRONTEND_NOTES.md).
	# The launch view is Library, so animate the library grid, not right_panel
	# (hidden inside MiddleHBox, zero-size pivot there).
	var bars: Array = [top_bar, library_view, bottom_bar]
	for bar in bars:
		if bar != null:
			bar.modulate.a = 0.0
			bar.scale = Vector2(0.98, 0.98)
	await get_tree().process_frame
	for i in bars.size():
		var bar: Control = bars[i]
		if bar == null:
			continue
		bar.pivot_offset = bar.size * 0.5
		var tw: Tween = create_tween().set_parallel(true) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		var delay: float = 0.05 * i
		tw.tween_property(bar, "modulate:a", 1.0, 0.30).set_delay(delay)
		tw.tween_property(bar, "scale", Vector2.ONE, 0.30).set_delay(delay)


func _on_open_button_pressed() -> void:
	file_dialog.popup_centered()


func _on_file_dialog_file_selected(path: String) -> void:
	open_photo(path)


# Loads path into the editor, resets all edit state, and switches to Edit view.
# Returns false when the backend is unavailable or the file can't be decoded.
func open_photo(path: String) -> bool:
	if backend == null:
		return false
	# Commit the previously edited photo's pending save before its key/params are
	# replaced (open_photo is reachable directly from the file dialog in Edit).
	_flush_pending_save()
	_show_thumb_placeholder(path)

	# A render task may be mid-flight inside the pipe; load_image must not race it.
	if _processing and _current_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_current_task_id)
		_processing = false

	# A new image is loading; any in-progress compare against the old one is stale.
	if _comparing:
		_end_compare()
	cluster_compare_button.disabled = true
	_before_texture = null
	_last_render_image = null
	_last_render_sig = ""

	_auto_wb_pending = false
	var ok: bool = backend.load_image(path)
	if not ok:
		_image_loaded = false
		_update_empty_state()
		export_button.disabled = true
		_set_color_wb_controls_enabled(false)
		return false

	_image_loaded = true
	_set_color_wb_controls_enabled(not _exporting)
	_update_empty_state()
	_edited_path = path
	filename_label.text = path.get_file()

	_applied_params.clear()
	_wb_backend_key = ""
	_reset_render_gate()

	_source_basename = path.get_file().get_basename()
	export_button.disabled = false
	cluster_prev_button.disabled = false
	cluster_next_button.disabled = false
	cluster_crop_button.disabled = false
	cluster_crop_button.set_pressed_no_signal(false)
	cluster_rotate_ccw_button.disabled = false
	cluster_rotate_cw_button.disabled = false
	cluster_reject_button.disabled = false
	_sync_cluster_reject_button(path)

	# Resolve this photo's EditStore identity, then restore its saved params (or
	# as-shot defaults for a never-edited photo). Keyed by file name + a hash of
	# the neutral thumbnail, so edits survive file moves/renames.
	var as_shot_temperature: float = backend.get_white_balance_temperature()
	_wb_default_temperature = as_shot_temperature
	var as_shot_tint: float = backend.get_white_balance_tint()
	_wb_default_tint = as_shot_tint
	white_balance_slider.queue_redraw()
	tint_slider.queue_redraw()
	_resolve_edit_key(path)
	var defaults: Dictionary = {
		"exposure": 0.0,
		"contrast": 0.0,
		"highlights": _map_offset_to_module("highlights", 0.0),
		"shadows": _map_offset_to_module("shadows", 0.0),
		"blacks": 0.0,
		"whites": 0.0,
		"dehaze": 0.0,
		"sharpening": 0.0,
		"denoise": 0.0,
		"saturation": _map_offset_to_module("saturation", 0.0),
		"desaturation": 0.0,
		"vibrance": _map_offset_to_module("vibrance", 0.0),
		"tonecurve": PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 1.0)]),
		"wb_temperature": as_shot_temperature,
		"wb_tint": as_shot_tint,
		"wb_mode": ColorWbScript.AS_SHOT,
		"wb_override": false,
		"crop": Rect2(0, 0, 1, 1),
		"orientation": 0,
		"straighten_angle": 0.0,
	}
	var saved: Dictionary = EditStore.load(_edit_key) if _edit_key != "" else {}
	# Merge over defaults so a record missing a key (older schema) still gets a
	# sane value for it.
	var restored: Dictionary = defaults.duplicate(true)
	for key in saved:
		if defaults.has(key):
			restored[key] = saved[key]
	# White balance restores as a unit: saved mode/values, legacy records
	# (temperature only) inferred, never-edited photos As Shot.
	restored.merge(ColorWbScript.resolve_saved(saved, as_shot_temperature, as_shot_tint), true)
	_apply_params_to_ui(restored)

	# Before/after compare: as-shot tonal values, keyed by this photo. crop and
	# orientation are substituted from the live _params at render time (see
	# _render_before_texture), so the compare view keeps the same framing as the
	# edited view instead of jumping back to the original crop/rotation.
	_neutral_params = defaults.duplicate(true)
	_before_texture = null
	_comparing = false
	cluster_compare_button.disabled = false

	_auto_floor_scale = _EDIT_MODES[_pick_default_edit_mode_id(
		backend.get_raw_width(), backend.get_raw_height())]["scale"]
	_display_zoom = -1.0
	fit_button.set_pressed_no_signal(true)
	_update_zoom_readout()
	# Each photo opens in Auto; the size-tiered scale above is Auto's floor.
	_edit_mode_id = _EDIT_AUTO_ID
	edit_res_option.select(_EDIT_AUTO_ID)
	_edit_scale = _auto_compute_scale()
	_set_view(View.EDIT)
	# The load-time render pushes restored params to the backend; it must not arm
	# auto-save (opening a photo is not an edit).
	_restoring = true
	_request_render()
	_restoring = false
	# Write-through: this is now the photo the next launch reopens in Edit.
	_ui_state["last_photo"] = path
	UiStateStore.save(_ui_state)
	return true


# --- RAW library thumbnails ----------------------------------------------------
# RAW thumbnail rendering runs entirely in the background worker process (see
# "Background thumbnail indexer" in docs/GODOT_FRONTEND_NOTES.md); the GUI only
# polls the shared on-disk cache (refresh_visible_from_cache / fill_path_from_cache).
# _render_backend_thumb stays here because _resolve_thumb_hash below (first-open
# edit-key hashing) and the worker branch both call it directly against the
# image already loaded in their respective backend.

# Renders a neutral thumbnail of the image CURRENTLY loaded in the backend via
# the preview pipe, downsamples to THUMB_MAX, and stores it under `key`. Backend
# + Image calls only (safe on a worker thread). Returns null on render failure.
func _render_backend_thumb(key: String) -> Image:
	var bytes: PackedByteArray = backend.render_preview(
		_WHOLE_IMAGE_VIEWPORT, _WHOLE_IMAGE_VIEWPORT, _RAW_THUMB_SCALE, 0.0, 0.0)
	var w: int = backend.get_width()
	var h: int = backend.get_height()
	if w <= 0 or h <= 0 or bytes.size() < w * h * 4:
		return null
	var img: Image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)
	var long_edge: int = maxi(w, h)
	if long_edge > ThumbnailCache.THUMB_MAX:
		var s: float = float(ThumbnailCache.THUMB_MAX) / float(long_edge)
		img.resize(maxi(1, roundi(w * s)), maxi(1, roundi(h * s)), Image.INTERPOLATE_LANCZOS)
	return ThumbnailCache.store_thumb(key, img)


# Resolves _edit_key / _edit_thumb_hash / _edit_file_name for `path`, which is
# assumed loaded in the backend. Reuses the disk thumbnail when present; for a
# RAW with no cached thumb yet, renders one through the backend (which holds the
# image at this point in open_photo). Clears the key if no thumbnail can be had,
# so edits for that photo simply aren't persisted rather than keyed wrongly.
func _resolve_edit_key(path: String) -> void:
	_edit_key = ""
	_edit_thumb_hash = ""
	_edit_file_name = path.get_file()
	var mtime: int = FileAccess.get_modified_time(path)
	var cache_key: String = ThumbnailCache.cache_key(path, mtime)
	_edit_thumb_hash = _resolve_thumb_hash(path, cache_key)
	if _edit_thumb_hash == "":
		return
	_edit_key = EditStore.edit_key(_edit_file_name, _edit_thumb_hash)


# Hashes the on-disk (JPEG, lossy) thumbnail so the key is identical whether the
# thumb was just built/rendered or loaded from cache: build_thumbnail and
# _render_backend_thumb return the pre-encode in-memory image, which hashes
# differently from the decoded cache file. Builds/renders the thumb first if it
# is missing, then always re-reads from disk. Returns "" if no thumb can be had.
func _resolve_thumb_hash(path: String, cache_key: String) -> String:
	if ThumbnailCache.load_cached(cache_key) == null:
		if Library.is_raw(path.get_file()):
			_render_backend_thumb(cache_key)
		else:
			ThumbnailCache.build_thumbnail(path, cache_key)
	var disk: Image = ThumbnailCache.load_cached(cache_key)
	if disk == null:
		return ""
	return EditStore.thumb_hash(disk)


# Pushes a params dict into every slider/curve/crop control AND into _params,
# without firing control signals (set_value_no_signal), so restoring saved edits
# doesn't re-trigger renders or auto-save. The inverse of the per-control
# value_changed handlers; the one place that rebuilds the full UI from _params.
func _apply_params_to_ui(p: Dictionary) -> void:
	_params["exposure"] = p["exposure"]
	exposure_slider.set_value_no_signal(p["exposure"])
	exposure_value_label.text = "%.2f" % p["exposure"]

	_params["contrast"] = p["contrast"]
	contrast_slider.set_value_no_signal(p["contrast"])
	contrast_value_label.text = "%.2f" % p["contrast"]

	# Offset-mapped keys store module space in _params; the slider shows the
	# -50..50 UI offset, recovered via _map_module_to_offset.
	_params["highlights"] = p["highlights"]
	var hl_off: float = _map_module_to_offset("highlights", p["highlights"])
	highlights_slider.set_value_no_signal(hl_off)
	highlights_value_label.text = "%.2f" % hl_off

	_params["shadows"] = p["shadows"]
	var sh_off: float = _map_module_to_offset("shadows", p["shadows"])
	shadows_slider.set_value_no_signal(sh_off)
	shadows_value_label.text = "%.2f" % sh_off

	# blacks stores the sign-inverted slider value (see _on_blacks handler).
	_params["blacks"] = p["blacks"]
	blacks_slider.set_value_no_signal(-p["blacks"])
	blacks_value_label.text = "%.2f" % (-p["blacks"])

	_params["whites"] = p["whites"]
	whites_slider.set_value_no_signal(p["whites"])
	whites_value_label.text = "%.2f" % p["whites"]

	_params["dehaze"] = p["dehaze"]
	dehaze_slider.set_value_no_signal(p["dehaze"])
	dehaze_value_label.text = "%.2f" % p["dehaze"]

	_params["sharpening"] = p["sharpening"]
	sharpening_slider.set_value_no_signal(p["sharpening"])
	sharpening_value_label.text = "%d" % roundi(p["sharpening"])

	_params["denoise"] = p["denoise"]
	noise_reduction_slider.set_value_no_signal(p["denoise"])
	noise_reduction_value_label.text = "%d" % roundi(p["denoise"])

	# saturation/desaturation are two _params keys driven by one slider: a
	# positive offset is saturation above its module default, a negative offset
	# (saturation pinned to default, desaturation > 0) reads back as negative.
	_params["saturation"] = p["saturation"]
	_params["desaturation"] = p["desaturation"]
	var sat_off: float = 0.0
	if p["desaturation"] > 0.0:
		sat_off = -p["desaturation"] * 50.0
	else:
		sat_off = _map_module_to_offset("saturation", p["saturation"])
	saturation_slider.set_value_no_signal(sat_off)
	ColorReadoutScript.apply(saturation_value_label, sat_off)

	_params["vibrance"] = p["vibrance"]
	var vib_off: float = _map_module_to_offset("vibrance", p["vibrance"])
	vibrance_slider.set_value_no_signal(vib_off)
	ColorReadoutScript.apply(vibrance_value_label, vib_off)

	_params["tonecurve"] = p["tonecurve"]
	tone_curve_editor.set_points(p["tonecurve"])

	_params["wb_temperature"] = p["wb_temperature"]
	_params["wb_tint"] = float(p["wb_tint"])
	_params["wb_mode"] = p["wb_mode"]
	_params["wb_override"] = bool(p["wb_override"])
	_sync_wb_ui()

	_params["crop"] = p["crop"]

	_params["orientation"] = int(p["orientation"])

	_params["straighten_angle"] = p["straighten_angle"]
	straighten_slider.set_value_no_signal(p["straighten_angle"])
	straighten_value_label.text = "%.1f°" % p["straighten_angle"]


func _on_exposure_slider_value_changed(value: float) -> void:
	exposure_value_label.text = "%.2f" % value
	_params["exposure"] = value
	_request_render()


func _on_contrast_slider_value_changed(value: float) -> void:
	contrast_value_label.text = "%.2f" % value
	_params["contrast"] = value
	_request_render()


func _on_highlights_slider_value_changed(value: float) -> void:
	highlights_value_label.text = "%.2f" % value
	_params["highlights"] = _map_offset_to_module("highlights", value)
	_request_render()


func _on_shadows_slider_value_changed(value: float) -> void:
	shadows_value_label.text = "%.2f" % value
	_params["shadows"] = _map_offset_to_module("shadows", value)
	_request_render()


func _on_blacks_slider_value_changed(value: float) -> void:
	blacks_value_label.text = "%.2f" % value
	_params["blacks"] = -value
	_request_render()


func _on_whites_slider_value_changed(value: float) -> void:
	whites_value_label.text = "%.2f" % value
	_params["whites"] = value
	_request_render()


func _on_dehaze_slider_value_changed(value: float) -> void:
	dehaze_value_label.text = "%.2f" % value
	_params["dehaze"] = value
	_request_render()


func _on_sharpening_slider_value_changed(value: float) -> void:
	sharpening_value_label.text = "%d" % roundi(value)
	_params["sharpening"] = value
	_request_render()


func _on_noise_reduction_slider_value_changed(value: float) -> void:
	noise_reduction_value_label.text = "%d" % roundi(value)
	_params["denoise"] = value
	_request_render()


func _on_saturation_slider_value_changed(value: float) -> void:
	ColorReadoutScript.apply(saturation_value_label, value)
	if value > 0.0:
		_params["saturation"] = _map_offset_to_module("saturation", value)
		_params["desaturation"] = 0.0
	else:
		_params["saturation"] = _map_offset_to_module("saturation", 0.0)
		_params["desaturation"] = -value / 50.0
	_enter_custom_wb_mode()
	_request_render()


func _on_vibrance_slider_value_changed(value: float) -> void:
	ColorReadoutScript.apply(vibrance_value_label, value)
	_params["vibrance"] = _map_offset_to_module("vibrance", value)
	_enter_custom_wb_mode()
	_request_render()


func _on_tone_curve_changed(points: PackedVector2Array) -> void:
	_params["tonecurve"] = points
	_request_render()


func _on_white_balance_slider_value_changed(value: float) -> void:
	white_balance_value_label.text = "%dK" % roundi(value)
	_params["wb_temperature"] = value
	_enter_custom_wb_mode(true)
	_request_render()


func _on_tint_slider_value_changed(value: float) -> void:
	ColorReadoutScript.apply(tint_value_label, value)
	_params["wb_tint"] = value
	_enter_custom_wb_mode(true)
	_request_render()


# Pushes _params' white-balance keys into Temp, Tint and the mode bar without
# firing their signals.
func _sync_wb_ui() -> void:
	white_balance_slider.set_value_no_signal(_params["wb_temperature"])
	white_balance_value_label.text = "%dK" % roundi(_params["wb_temperature"])
	tint_slider.set_value_no_signal(_params["wb_tint"])
	ColorReadoutScript.apply(tint_value_label, _params["wb_tint"])
	wb_mode_bar.set_mode(_params["wb_mode"])


# Called by the four Color slider handlers (Temp, Tint, Vibrance, Saturation):
# any edit makes the white-balance mode Custom and cancels an unresolved Auto.
# The values themselves were already written by the calling handler. Only the
# Temp/Tint handlers pass manual_override: Vibrance/Saturation edits leave
# wb_override alone, so they never turn an exact as-shot state into a forced
# correction.
func _enter_custom_wb_mode(manual_override: bool = false) -> void:
	_auto_wb_pending = false
	if manual_override:
		_params["wb_override"] = true
	if _params["wb_mode"] != ColorWbScript.CUSTOM:
		_params["wb_mode"] = ColorWbScript.CUSTOM
		wb_mode_bar.set_mode(ColorWbScript.CUSTOM)


# Segmented-control click. Only mutates _params/UI and queues work: As Shot and
# Auto go through _request_render (Auto's measurement and every backend setter
# run later inside _start_process / _apply_params_to_backend); Custom changes
# no values, so it only arms the save.
func _on_wb_mode_selected(mode: String) -> void:
	if backend == null or not _image_loaded or _exporting:
		wb_mode_bar.set_mode(_params["wb_mode"])
		return
	_auto_wb_pending = mode == ColorWbScript.AUTO
	if mode == ColorWbScript.AS_SHOT:
		_params.merge(ColorWbScript.as_shot_values(_wb_default_temperature, _wb_default_tint), true)
		_sync_wb_ui()
	else:
		_params["wb_mode"] = mode
		wb_mode_bar.set_mode(mode)
	if mode == ColorWbScript.CUSTOM:
		_mark_edit_dirty()
	else:
		_request_render()


# Runs the pending Auto measurement (at most once per click). Must only be
# called when no render task is running. On success the measured temperature
# and tint replace the sliders' values and are pushed through the normal apply
# path; on failure the photo stays as it was and the mode falls back to Custom.
func _resolve_auto_wb() -> void:
	if not _auto_wb_pending:
		return
	_auto_wb_pending = false
	var result: Dictionary = backend.compute_auto_white_balance()
	if result["ok"]:
		_params["wb_temperature"] = clampf(
			float(result["temperature"]), white_balance_slider.min_value, white_balance_slider.max_value)
		_params["wb_tint"] = clampf(
			float(result["tint"]), tint_slider.min_value, tint_slider.max_value)
		_params["wb_mode"] = ColorWbScript.AUTO
		_params["wb_override"] = true
	else:
		push_warning("Auto white balance unavailable; switching to Custom")
		_params["wb_mode"] = ColorWbScript.CUSTOM
	_sync_wb_ui()


# Enables/disables the controls that have no per-control editable bookkeeping
# elsewhere (the segmented mode bar and Tint).
func _set_color_wb_controls_enabled(enabled: bool) -> void:
	wb_mode_bar.set_enabled(enabled)
	tint_slider.editable = enabled


# --- Reset buttons ------------------------------------------------------------

func _make_reset_button(tooltip_text: String) -> Button:
	var btn := Button.new()
	btn.text = "↺"
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = tooltip_text
	btn.custom_minimum_size = Vector2(24, 0)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_reset_buttons.append(btn)
	return btn


func _add_slider_reset(slider: HSlider, default_value: float) -> void:
	# Also anchors the center-origin amber fill (CenterOriginSlider.gd) to this
	# same default, so "no fill" and "reset" always agree on neutral.
	if slider.has_method("set") and slider.get("origin_value") != null:
		slider.set("origin_value", default_value)
	var btn := _make_reset_button("Reset to default")
	btn.pressed.connect(func() -> void: slider.value = default_value)
	slider.get_parent().add_child(btn)
	_show_reset_when(btn, slider, func() -> bool: return not is_equal_approx(slider.value, default_value))


# Hides btn (alpha + no input, layout space kept) while is_changed returns
# false; re-evaluated on every redraw of watched, which covers
# set_value_no_signal restores.
func _show_reset_when(btn: Button, watched: Control, is_changed: Callable) -> void:
	var refresh := func() -> void:
		var changed: bool = is_changed.call()
		btn.modulate.a = 1.0 if changed else 0.0
		btn.mouse_filter = Control.MOUSE_FILTER_STOP if changed else Control.MOUSE_FILTER_IGNORE
	watched.draw.connect(refresh)
	refresh.call()


## Shared monospace font for slider/zoom numeric readouts, so digits align in
## a tabular column. Falls back through common system mono family names.
var _mono_value_font: SystemFont = null

func _apply_mono_value_label_font() -> void:
	_mono_value_font = SystemFont.new()
	_mono_value_font.font_names = PackedStringArray(["SF Mono", "Menlo", "ui-monospace", "monospace"])
	var value_labels: Array[Label] = [
		exposure_value_label,
		contrast_value_label,
		highlights_value_label,
		shadows_value_label,
		blacks_value_label,
		whites_value_label,
		dehaze_value_label,
		sharpening_value_label,
		noise_reduction_value_label,
		straighten_value_label,
		saturation_value_label,
		vibrance_value_label,
		white_balance_value_label,
		tint_value_label,
		zoom_value_label,
	]
	for label in value_labels:
		label.add_theme_font_override("font", _mono_value_font)

func _setup_reset_buttons() -> void:
	_add_slider_reset(exposure_slider, 0.0)
	_add_slider_reset(contrast_slider, 0.0)
	_add_slider_reset(highlights_slider, 0.0)
	_add_slider_reset(shadows_slider, 0.0)
	_add_slider_reset(blacks_slider, 0.0)
	_add_slider_reset(whites_slider, 0.0)
	_add_slider_reset(dehaze_slider, 0.0)
	_add_slider_reset(sharpening_slider, 0.0)
	_add_slider_reset(noise_reduction_slider, 0.0)
	_add_slider_reset(saturation_slider, 0.0)
	_add_slider_reset(vibrance_slider, 0.0)
	_add_slider_reset(straighten_slider, 0.0)

	var wb_btn := _make_reset_button("Reset to as-shot white balance")
	wb_btn.pressed.connect(func() -> void:
		white_balance_slider.value = _wb_default_temperature)
	white_balance_slider.get_parent().add_child(wb_btn)
	_show_reset_when(wb_btn, white_balance_slider, func() -> bool:
		return not is_equal_approx(white_balance_slider.value, _wb_default_temperature))

	var tint_btn := _make_reset_button("Reset to as-shot tint")
	tint_btn.pressed.connect(func() -> void:
		tint_slider.value = _wb_default_tint)
	tint_slider.get_parent().add_child(tint_btn)
	_show_reset_when(tint_btn, tint_slider, func() -> bool:
		return not is_equal_approx(tint_slider.value, _wb_default_tint))

	var tone_label: Label = $Root/MiddleHBox/RightPanel/PanelScroll/PanelMargin/PanelVBox/ToneCurveLabel
	var vbox: Node = tone_label.get_parent()
	var slot: int = tone_label.get_index()
	var tone_header := HBoxContainer.new()
	tone_header.name = "ToneCurveHeaderRow"
	tone_header.add_theme_constant_override("separation", 8)
	vbox.add_child(tone_header)
	vbox.move_child(tone_header, slot)
	tone_label.reparent(tone_header)
	tone_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tone_btn := _make_reset_button("Reset tone curve")
	tone_btn.pressed.connect(func() -> void: tone_curve_editor.reset_to_default())
	tone_header.add_child(tone_btn)
	_show_reset_when(tone_btn, tone_curve_editor, func() -> bool:
		var pts: PackedVector2Array = tone_curve_editor.get_points()
		return not (pts.size() == 2 and pts[0].is_equal_approx(Vector2(0, 0)) and pts[1].is_equal_approx(Vector2(1, 1))))


# Single entry point for every control; coalesces edits into one render at a time.
func _request_render() -> void:
	if backend == null or not _image_loaded or _exporting:
		return
	# Every slider/curve/crop handler funnels through here, so this is the one
	# choke point for marking the edit dirty (suppressed during restore).
	_mark_edit_dirty()
	if _processing:
		_render_queued = true
		return
	if not _render_gate_open():
		_arm_render_gate_timer()
		return
	_start_process()


func _render_gate_open() -> bool:
	if _last_render_start_usec == 0:
		return true
	var elapsed_usec: int = Time.get_ticks_usec() - _last_render_start_usec
	return float(elapsed_usec) >= _render_avg_usec * 0.5


func _render_gate_pending() -> bool:
	return _gate_timer != null and not _gate_timer.is_stopped()


func _arm_render_gate_timer() -> void:
	if _render_gate_pending():
		return
	var remaining_usec: float = _render_avg_usec * 0.5 \
		- float(Time.get_ticks_usec() - _last_render_start_usec)
	if remaining_usec <= 1000.0:
		_start_process()
		return
	_gate_timer.start(remaining_usec / 1000000.0)


func _reset_render_gate() -> void:
	if _gate_timer != null:
		_gate_timer.stop()
	_render_queued = false
	_render_avg_usec = 0.0
	_last_render_start_usec = 0


func _on_render_gate_timeout() -> void:
	# Never render outside Edit: a timer armed by a slider edit can fire after
	# the user has already switched to Library, where the backend is shared with
	# RAW thumb jobs (see _quiesce_edit_render / _start_process guard).
	if backend == null or not _image_loaded or _exporting or _view != View.EDIT:
		return
	if _processing:
		_render_queued = true
		return
	_start_process()


# Cancels the edit-render machinery so nothing renders once Library owns the
# backend: stops the debounce-gate timer, drops a queued render, and waits out
# any in-flight render task (brief main-thread stall, same tradeoff as
# open_photo). The deferred _on_process_done for a waited-out task still runs
# harmlessly (texture_rect is hidden in Library).
func _quiesce_edit_render() -> void:
	if _gate_timer != null:
		_gate_timer.stop()
	_render_queued = false
	if _processing and _current_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_current_task_id)
		_processing = false


func _params_differ(key: String) -> bool:
	if not _applied_params.has(key):
		return true
	return _params[key] != _applied_params[key]


func _snapshot_applied_params() -> void:
	for key in _params:
		var value: Variant = _params[key]
		if value is PackedVector2Array:
			value = (value as PackedVector2Array).duplicate()
		_applied_params[key] = value


# The ONE place mapping _params keys to backend setters; only changed params are pushed.
func _apply_params_to_backend() -> void:
	if _params_differ("exposure"):
		backend.set_exposure(_params["exposure"])
	if _params_differ("contrast"):
		backend.set_contrast(_params["contrast"])
	if _params_differ("highlights"):
		backend.set_highlights(_params["highlights"])
	if _params_differ("shadows"):
		backend.set_shadows(_params["shadows"])
	if _params_differ("blacks"):
		backend.set_blacks(_params["blacks"])
	if _params_differ("whites"):
		backend.set_whites(_params["whites"])
	if _params_differ("dehaze"):
		backend.set_dehaze(_params["dehaze"])
	# Guarded so the app doesn't crash against an older backend binary that
	# predates these setters.
	if _params_differ("sharpening") and backend.has_method("set_sharpening"):
		backend.set_sharpening(_params["sharpening"])
	if _params_differ("denoise") and backend.has_method("set_denoise"):
		backend.set_denoise(_params["denoise"])
	if _params_differ("saturation"):
		backend.set_saturation(_params["saturation"])
	if _params_differ("desaturation"):
		backend.set_desaturation(_params["desaturation"])
	if _params_differ("vibrance"):
		backend.set_vibrance(_params["vibrance"])
	if _params_differ("tonecurve"):
		backend.set_tonecurve(_params["tonecurve"])
	_apply_white_balance_to_backend()
	if _params_differ("crop"):
		var crop: Rect2 = _params["crop"]
		backend.set_crop(crop.position.x, crop.position.y, crop.end.x, crop.end.y)
	# set_orientation lands alongside this change in a parallel backend build;
	# guarded so the app doesn't crash against an older binary.
	if _params_differ("orientation") and backend.has_method("set_orientation"):
		backend.set_orientation(_params["orientation"])
	if _params_differ("straighten_angle") and backend.has_method("set_straighten_angle"):
		backend.set_straighten_angle(_params["straighten_angle"])
	_snapshot_applied_params()


# White-balance half of _apply_params_to_backend. Mode As Shot, or no wb_override
# (see ColorWb.gd), goes through reset_white_balance (exact load-time module
# defaults); an override pushes the actual Temp/Tint through set_white_balance.
# _wb_backend_key records what the pipe currently holds, so selecting Custom or
# editing Vibrance/Saturation never re-pushes a correction over an exact state.
func _apply_white_balance_to_backend() -> void:
	var neutral: bool = ColorWbScript.is_neutral(_params["wb_mode"], _params["wb_override"])
	var key: String = "neutral" if neutral else "%f,%f" % [_params["wb_temperature"], _params["wb_tint"]]
	if key == _wb_backend_key:
		return
	_wb_backend_key = key
	if neutral:
		backend.reset_white_balance()
	else:
		backend.set_white_balance(_params["wb_temperature"], _params["wb_tint"])


func _start_process() -> void:
	# Edit-view only: renders mutate shared backend state (_apply_params_to_backend
	# pushes cached module pointers), which is unsafe once Library owns the
	# backend for RAW thumbs.
	if backend == null or not _image_loaded or _exporting or _view != View.EDIT:
		return

	_processing = true
	_render_queued = false
	if _gate_timer != null:
		_gate_timer.stop()
	_render_start_usec = Time.get_ticks_usec()
	_last_render_start_usec = _render_start_usec
	export_button.disabled = true
	# _processing is already set, so no save flush can run while Auto measures.
	_resolve_auto_wb()
	_apply_params_to_backend()

	var edit_scale: float = _edit_scale
	var final_quality: bool = _final_quality()
	var sig: String = EditStore.params_signature(_params)
	_current_task_id = WorkerThreadPool.add_task(_process_task.bind(edit_scale, final_quality, sig))


func _final_quality() -> bool:
	return _edit_scale >= 0.999


func _process_task(edit_scale: float, final_quality: bool, sig: String) -> void:
	var bytes: PackedByteArray
	if final_quality:
		bytes = backend.render_view(
			_WHOLE_IMAGE_VIEWPORT, _WHOLE_IMAGE_VIEWPORT, edit_scale, 0.0, 0.0)
	else:
		bytes = backend.render_preview(
			_WHOLE_IMAGE_VIEWPORT, _WHOLE_IMAGE_VIEWPORT, edit_scale, 0.0, 0.0)
	var width: int = backend.get_width()
	var height: int = backend.get_height()
	call_deferred("_on_process_done", bytes, width, height, sig)


func _on_process_done(bytes: PackedByteArray, width: int, height: int, sig: String) -> void:
	var elapsed_usec: int = Time.get_ticks_usec() - _render_start_usec
	_render_avg_usec += float(elapsed_usec) / _RENDER_AVG_COUNT \
		- _render_avg_usec / _RENDER_AVG_COUNT

	if width > 0 and height > 0 and bytes.size() >= width * height * 4:
		var img: Image = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, bytes)
		if image_texture == null \
				or image_texture.get_width() != width \
				or image_texture.get_height() != height:
			image_texture = ImageTexture.create_from_image(img)
			texture_rect.texture = image_texture
			if _crop_overlay != null:
				_crop_overlay.sync_to_texture()
		else:
			image_texture.update(img)
			texture_rect.texture = image_texture
		_apply_display_layout()
		_update_resolution_label(width, height)
		_last_render_image = img
		_last_render_sig = sig

	_processing = false

	if _render_queued and _image_loaded and not _exporting:
		_render_queued = false
		_request_render()
	elif _image_loaded and not _exporting:
		export_button.disabled = false


func _apply_display_layout() -> void:
	if image_texture == null:
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return

	if _display_zoom < 0.0:
		texture_rect.stretch_mode = _STRETCH_KEEP_ASPECT_CENTERED
		texture_rect.custom_minimum_size = scroll_container.size
	else:
		texture_rect.stretch_mode = _STRETCH_SCALE
		texture_rect.custom_minimum_size = Vector2(native_w, native_h) * _display_zoom
	# Only refresh a currently-visible nav; it's repositioned/refreshed on flash.
	if navigator != null and navigator.visible:
		_update_navigator()


# Content size (native * zoom) currently laid out, or zero if fit/unavailable.
func _content_size() -> Vector2:
	if backend == null or _display_zoom < 0.0:
		return Vector2.ZERO
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return Vector2.ZERO
	return Vector2(native_w, native_h) * _display_zoom


# Pushes the current texture + visible-region rect (image fractions) to the
# navigator. When fit, the whole image is visible so the box spans the frame.
func _update_navigator() -> void:
	if navigator == null or image_texture == null:
		return
	navigator.set_texture(image_texture)
	var content: Vector2 = _content_size()
	if content == Vector2.ZERO:
		navigator.set_viewport(Rect2(0, 0, 1, 1))
		return
	var vp: Vector2 = scroll_container.size
	var sz: Vector2 = (vp / content).clamp(Vector2.ZERO, Vector2.ONE)
	var origin := Vector2(scroll_container.scroll_horizontal, scroll_container.scroll_vertical) / content
	origin = origin.clamp(Vector2.ZERO, Vector2.ONE - sz)
	navigator.set_viewport(Rect2(origin, sz))


# Pan (and zoom-recenter) both move scroll; flash the nav so it surfaces.
func _on_scroll_moved(_value: float) -> void:
	_flash_navigator()


# Shows the floating nav at the image area's top-left, then fades it out after
# a hold. Any further zoom/pan restarts the timer.
const _NAV_HOLD_SEC: float = 2.0
const _NAV_FADE_SEC: float = 0.5
var _nav_tween: Tween = null

func _flash_navigator() -> void:
	if navigator == null or _view != View.EDIT or not _image_loaded:
		return
	_update_navigator()
	navigator.size = Vector2(220, 150)
	navigator.position = scroll_container.global_position + Vector2(16, 16)
	navigator.visible = true
	navigator.modulate.a = 1.0
	if _nav_tween != null and _nav_tween.is_valid():
		_nav_tween.kill()
	_nav_tween = create_tween()
	_nav_tween.tween_interval(_NAV_HOLD_SEC)
	_nav_tween.tween_property(navigator, "modulate:a", 0.0, _NAV_FADE_SEC)
	_nav_tween.tween_callback(func() -> void: navigator.visible = false)


# Navigator click/drag: center the viewport on the requested image fraction.
func _on_navigator_pan_to(center: Vector2) -> void:
	var content: Vector2 = _content_size()
	if content == Vector2.ZERO:
		return
	var vp: Vector2 = scroll_container.size
	var target: Vector2 = center * content - vp / 2.0
	var max_scroll := Vector2(maxf(content.x - vp.x, 0.0), maxf(content.y - vp.y, 0.0))
	scroll_container.scroll_horizontal = roundi(clampf(target.x, 0.0, max_scroll.x))
	scroll_container.scroll_vertical = roundi(clampf(target.y, 0.0, max_scroll.y))


func _on_scroll_resized() -> void:
	if not _image_loaded:
		return
	_apply_display_layout()
	if _update_auto_edit_scale():
		_request_render()


func _on_edit_res_option_button_item_selected(index: int) -> void:
	var id: int = edit_res_option.get_item_id(index)
	_edit_mode_id = id
	if id == _EDIT_AUTO_ID:
		_edit_scale = _auto_compute_scale()
	else:
		_edit_scale = _EDIT_MODES[id]["scale"]
	_request_render()


func _on_zoom_slider_value_changed(value: float) -> void:
	# Range min/max reassignment re-clamps and emits this during view
	# switches; those clamped emissions are restore bookkeeping, not input.
	if _switching_view:
		return
	if _view == View.LIBRARY:
		_set_library_zoom(value)
	else:
		_set_display_zoom(value)


# Clamps pct, pushes it to the shared slider/label (library mode), and scales
# LibraryView's tiles. Mirrors _set_display_zoom's slider/label bookkeeping.
func _set_library_zoom(pct: float) -> void:
	# Store the RAW (continuous) value: gestures accumulate multiplicatively
	# off it, and snapping the stored value would re-snap each small factor
	# back to the same step (pinch dead zone). Snap only for the slider/tiles.
	var prev: float = _library_thumb_zoom_pct
	_library_thumb_zoom_pct = clamp(pct, _LIBRARY_ZOOM_MIN_PCT, _LIBRARY_ZOOM_MAX_PCT)
	if not is_equal_approx(prev, _library_thumb_zoom_pct):
		_ui_state["library_zoom_pct"] = _library_thumb_zoom_pct
		UiStateStore.save(_ui_state)
	# Snap to the nearest gap-free zoom level so the slider itself steps
	# between column counts instead of drifting through partial-column states.
	var stepped: float = library_view.snap_thumb_scale(_library_thumb_zoom_pct / 100.0) * 100.0
	if not is_equal_approx(stepped, zoom_slider.value):
		zoom_slider.set_value_no_signal(stepped)
	library_view.set_thumb_zoom(stepped / 100.0)


func _on_library_zoom_requested(factor: float) -> void:
	_set_library_zoom(_library_thumb_zoom_pct * factor)


func _on_theme_button_pressed() -> void:
	ThemeManager.toggle_theme()


func _on_theme_changed(is_dark: bool) -> void:
	for readout in [tint_value_label, vibrance_value_label, saturation_value_label]:
		ColorReadoutScript.refresh(readout)
	theme_button.text = "Light Mode" if is_dark else "Dark Mode"
	if _crop_overlay != null:
		_crop_overlay.apply_theme(is_dark)


func _on_fit_button_toggled(pressed: bool) -> void:
	if pressed:
		_display_zoom = -1.0
		_apply_zoom_change()
	else:
		_set_display_zoom(zoom_slider.value)


# Frontend-only, plus a conditional _update_auto_edit_scale()/_request_render()
# for Auto edit-resolution; see docs/GODOT_FRONTEND_NOTES.md.
func _apply_zoom_change() -> void:
	_update_zoom_readout()
	if not _image_loaded:
		return
	_apply_display_layout()
	if image_texture != null:
		_update_resolution_label(image_texture.get_width(), image_texture.get_height())
	else:
		_update_resolution_label(0, 0)
	if _update_auto_edit_scale():
		_request_render()
	_flash_navigator()


# Fraction of native image size currently on screen.
func _effective_zoom_fraction() -> float:
	if _display_zoom >= 0.0:
		return _display_zoom
	if backend == null:
		return 0.0
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return 0.0
	var avail: Vector2 = scroll_container.size
	var fit: float = min(avail.x / float(native_w), avail.y / float(native_h))
	return clamp(fit, _ZOOM_MIN_PCT / 100.0, _ZOOM_MAX_PCT / 100.0)


func _auto_compute_scale() -> float:
	if _display_zoom < 0.0:
		return _auto_floor_scale
	return clamp(_display_zoom / _AUTO_FULL_ZOOM, _auto_floor_scale, 1.0)


# Recomputes _edit_scale from current zoom when Auto is active. Returns true
# if _edit_scale changed by at least _EDIT_SCALE_EPSILON, or if the change
# crosses the fast/final-quality cutoff (a qualitative change too small for
# the epsilon to catch, since _auto_compute_scale() clamps at exactly 1.0 and
# stops moving once display zoom clears _AUTO_FULL_ZOOM).
func _update_auto_edit_scale() -> bool:
	if not _is_auto_mode() or not _image_loaded:
		return false
	var new_scale: float = _auto_compute_scale()
	var crosses_final_quality: bool = (new_scale >= 0.999) != (_edit_scale >= 0.999)
	if not crosses_final_quality and absf(new_scale - _edit_scale) < _EDIT_SCALE_EPSILON:
		return false
	_edit_scale = new_scale
	return true


func _update_zoom_readout() -> void:
	if _display_zoom < 0.0:
		zoom_value_label.text = "Fit"
		if backend != null:
			var pct: float = _effective_zoom_fraction() * 100.0
			zoom_slider.set_value_no_signal(pct)
	else:
		zoom_value_label.text = "%d%%" % roundi(_display_zoom * 100.0)


func _update_resolution_label(buf_w: int, buf_h: int) -> void:
	if backend == null:
		resolution_label.text = "No image loaded"
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0 or buf_w <= 0 or buf_h <= 0:
		resolution_label.text = "No image loaded"
		return

	var buffer_scale: float = float(buf_w) / float(native_w)
	var edit_pct: int = roundi(buffer_scale * 100.0)
	var mode: String = "final" if _final_quality() else "fast"

	var disp_zoom: float = _effective_zoom_fraction()
	var screen_w: int = roundi(disp_zoom * float(native_w))
	var screen_h: int = roundi(disp_zoom * float(native_h))
	var disp_label: String = "Fit" if _display_zoom < 0.0 else "%d%%" % roundi(disp_zoom * 100.0)

	var buffer_upscale: float = disp_zoom / buffer_scale
	var quality: String = ""
	if buffer_upscale > 1.001:
		quality = "  [upscaled %.1fx - soft]" % buffer_upscale
	elif disp_zoom >= 0.999 and buffer_scale >= 0.999:
		quality = "  [1:1 native pixels]"

	resolution_label.text = "Native %dx%d  |  Editing @ %dx%d |  Display %s" % [
		native_w, native_h, buf_w, buf_h, disp_label]


func _on_texture_rect_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
			return
		if event.pressed and event.is_command_or_control_pressed():
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom_by_factor(1.1)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_by_factor(1.0 / 1.1)
		return

	if event is InputEventMouseMotion and _dragging:
		scroll_container.scroll_horizontal -= int(event.relative.x)
		scroll_container.scroll_vertical -= int(event.relative.y)
		return

	if event is InputEventMagnifyGesture:
		_zoom_by_factor(event.factor)
		return

	if event is InputEventPanGesture and event.is_command_or_control_pressed():
		if event.delta.y < 0.0:
			_zoom_by_factor(1.05)
		elif event.delta.y > 0.0:
			_zoom_by_factor(1.0 / 1.05)


func _zoom_by_factor(multiplier: float) -> void:
	if backend == null:
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return
	var old_effective_zoom: float = _effective_zoom_fraction()
	_set_display_zoom(old_effective_zoom * 100.0 * multiplier)


func _set_display_zoom(target_pct: float) -> void:
	if backend == null:
		return
	var native_w: int = backend.get_native_width()
	var native_h: int = backend.get_native_height()
	if native_w <= 0 or native_h <= 0:
		return
	var viewport_size: Vector2 = scroll_container.size

	var ratio: Vector2
	if _display_zoom < 0.0:
		ratio = Vector2(0.5, 0.5)
	else:
		var old_content_size: Vector2 = Vector2(native_w, native_h) * _display_zoom
		if old_content_size.x > 0.0 and old_content_size.y > 0.0:
			var center_old: Vector2 = Vector2(scroll_container.scroll_horizontal, scroll_container.scroll_vertical) + viewport_size / 2.0
			ratio = center_old / old_content_size
		else:
			ratio = Vector2(0.5, 0.5)

	target_pct = clamp(target_pct, _ZOOM_MIN_PCT, _ZOOM_MAX_PCT)
	_display_zoom = target_pct / 100.0
	zoom_slider.set_value_no_signal(target_pct)
	fit_button.set_pressed_no_signal(false)
	_apply_zoom_change()

	# Re-center on the same content ratio (scroll bar max/page are pushed manually;
	# see docs/GODOT_FRONTEND_NOTES.md).
	var new_content_size: Vector2 = Vector2(native_w, native_h) * _display_zoom
	var target_scroll: Vector2 = ratio * new_content_size - viewport_size / 2.0
	var h_bar: ScrollBar = scroll_container.get_h_scroll_bar()
	var v_bar: ScrollBar = scroll_container.get_v_scroll_bar()
	h_bar.max_value = new_content_size.x
	h_bar.page = viewport_size.x
	v_bar.max_value = new_content_size.y
	v_bar.page = viewport_size.y

	var max_scroll: Vector2 = Vector2(max(new_content_size.x - viewport_size.x, 0.0), max(new_content_size.y - viewport_size.y, 0.0))
	scroll_container.scroll_horizontal = roundi(clamp(target_scroll.x, 0.0, max_scroll.x))
	scroll_container.scroll_vertical = roundi(clamp(target_scroll.y, 0.0, max_scroll.y))


# --- Crop ----------------------------------------------------------------------
func _on_crop_button_toggled(pressed: bool) -> void:
	if not _image_loaded:
		cluster_crop_button.set_pressed_no_signal(false)
		return
	if pressed:
		_open_crop_overlay()
	else:
		_close_crop_overlay()


func _open_crop_overlay() -> void:
	if _crop_overlay != null:
		return
	_crop_overlay = CropOverlayScript.new()
	# Lift the committed crop so the overlay edits against the whole image.
	_crop_before_edit = _params["crop"]
	_params["crop"] = Rect2(0, 0, 1, 1)
	_request_render()
	_crop_overlay.open(texture_rect, _crop_before_edit)
	# apply_theme() needs an ancestor theme to resolve "CropOverlay" colors
	# against, so it must run after open() adds the node to the tree.
	_crop_overlay.apply_theme(ThemeManager.is_dark)
	var overlay: Control = _crop_overlay
	_crop_bar = CropOverlayScript.build_bar(scroll_container)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	_crop_bar.add_child(cancel_btn)
	var done_btn := Button.new()
	done_btn.text = "Done"
	_crop_bar.add_child(done_btn)
	done_btn.pressed.connect(func() -> void:
		_on_crop_overlay_applied(overlay.get_rect_normalized()))
	cancel_btn.pressed.connect(_on_crop_overlay_canceled)


func _close_crop_overlay() -> void:
	if _crop_overlay == null:
		return
	_crop_overlay.close()
	_crop_overlay = null
	if _crop_bar != null:
		_crop_bar.get_parent().queue_free()
		_crop_bar = null


func _on_crop_overlay_applied(rect: Rect2) -> void:
	_close_crop_overlay()
	cluster_crop_button.set_pressed_no_signal(false)
	_params["crop"] = rect
	_before_texture = null
	_request_render()


func _on_crop_overlay_canceled() -> void:
	_close_crop_overlay()
	cluster_crop_button.set_pressed_no_signal(false)
	_params["crop"] = _crop_before_edit
	_before_texture = null
	_request_render()


# --- Straighten --------------------------------------------------------------
# A plain persistent slider like Dehaze/Sharpening, not a modal tool: darktable's
# clipping module auto-shrinks cx/cy/cw/ch toward center whenever angle != 0
# (crop_auto, left at its introspection default — see
# DtBackend::set_straighten_angle), so the live render already IS the final,
# never-out-of-frame result with no extra UI needed to enforce it.
func _on_straighten_slider_value_changed(value: float) -> void:
	straighten_value_label.text = "%.1f°" % value
	_params["straighten_angle"] = value
	_request_render()


# --- Before/after compare ---------------------------------------------------------
# Swaps texture_rect to a cached as-shot render for the duration of the hold
# (Space key or the Before button). The cache is built lazily on first hold per
# photo (and rebuilt if crop/orientation/edit-scale changed since), so repeat
# holds of the same photo are instant.
func _begin_compare() -> void:
	if _comparing or not _image_loaded or backend == null \
			or _crop_overlay != null or _exporting:
		return
	_comparing = true
	if _before_texture == null or _before_texture_scale != _edit_scale:
		_render_before_texture()
	if _before_texture != null:
		texture_rect.texture = _before_texture


func _end_compare() -> void:
	if not _comparing:
		return
	_comparing = false
	if image_texture != null:
		texture_rect.texture = image_texture


# Renders the as-shot neutral tonal values (current crop/orientation kept, so
# framing matches the edited view) into _before_texture. Temporarily swaps
# _params to neutral, pushes it to the backend, renders, then restores the
# edited _params/backend state so this is invisible to the rest of _apply_params_to_backend's
# diff-tracking (_applied_params ends up matching the real edited _params again).
func _render_before_texture() -> void:
	# A background edit render may be mid-flight inside the shared backend;
	# _apply_params_to_backend is unsafe to race (see _start_process).
	if _processing and _current_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_current_task_id)
		_processing = false

	var edited_params: Dictionary = _params
	var neutral: Dictionary = _neutral_params.duplicate(true)
	neutral["crop"] = edited_params["crop"]
	neutral["orientation"] = edited_params["orientation"]
	neutral["straighten_angle"] = edited_params["straighten_angle"]

	_params = neutral
	_apply_params_to_backend()

	var final_quality: bool = _final_quality()
	var bytes: PackedByteArray
	if final_quality:
		bytes = backend.render_view(
			_WHOLE_IMAGE_VIEWPORT, _WHOLE_IMAGE_VIEWPORT, _edit_scale, 0.0, 0.0)
	else:
		bytes = backend.render_preview(
			_WHOLE_IMAGE_VIEWPORT, _WHOLE_IMAGE_VIEWPORT, _edit_scale, 0.0, 0.0)
	var width: int = backend.get_width()
	var height: int = backend.get_height()

	# Restore the edited state regardless of render success, so a decode
	# failure here never leaves the backend pointed at the neutral render.
	_params = edited_params
	_apply_params_to_backend()

	if width <= 0 or height <= 0 or bytes.size() < width * height * 4:
		return
	var img: Image = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, bytes)
	_before_texture = ImageTexture.create_from_image(img)
	_before_texture_scale = _edit_scale


func _on_cluster_compare_button_down() -> void:
	_begin_compare()


func _on_cluster_compare_button_up() -> void:
	_end_compare()


# --- Rotate ----------------------------------------------------------------------
# orientation is quarter-turns clockwise, 0..3; backend.set_orientation (added by a
# parallel change) applies it with the same contract, 0 = no-op.
func _on_rotate_cw_button_pressed() -> void:
	if not _image_loaded:
		return
	_params["orientation"] = (int(_params["orientation"]) + 1) % 4
	_before_texture = null
	_request_render()


func _on_rotate_ccw_button_pressed() -> void:
	if not _image_loaded:
		return
	_params["orientation"] = (int(_params["orientation"]) + 3) % 4
	_before_texture = null
	_request_render()


# --- Reject (Edit view) ---------------------------------------------------------
# Mirrors LibraryView's grid toggle so a photo's rejected state is the same
# whether set from the grid or from Edit. The button already flipped its own
# pressed state before this signal fires, so a failed toggle flips it back.
func _on_cluster_reject_button_toggled(_pressed: bool) -> void:
	if not _toggle_reject_edited_photo():
		# Toggle rejected; restore the button to the real persisted state.
		_sync_cluster_reject_button(_edited_path)


# Attempts to toggle the open photo's rejected state; no-ops (returns false)
# when it isn't part of the current library, same guard as _edit_navigate.
# Returns true when the toggle happened.
func _toggle_reject_edited_photo() -> bool:
	if _edited_path == "" or library_view.get_photo_index_master(_edited_path) < 0:
		return false
	library_view.toggle_reject_path(_edited_path)
	_sync_cluster_reject_button(_edited_path)
	return true


# Reads the photo's rejected state from LibraryView (the source of truth) and
# updates the cluster button's pressed state and text label without re-emitting
# toggled. The text ("⚑ Rejected" / "⚑ Approved") is the authoritative indicator.
func _sync_cluster_reject_button(path: String) -> void:
	var mi: int = library_view.get_photo_index_master(path)
	var rejected: bool = false
	if mi >= 0:
		rejected = library_view.is_path_rejected(path)
	cluster_reject_button.set_pressed_no_signal(rejected)
	cluster_reject_button.text = "⚑ Rejected" if rejected else "⚑ Approved"


func _on_export_button_pressed() -> void:
	if not _image_loaded or _exporting or _processing \
			or _render_gate_pending() or _crop_overlay != null or _comparing:
		return
	export_dialog.current_file = "%s_edited.jpg" % _source_basename
	export_dialog.popup_centered()


func _on_export_dialog_file_selected(path: String) -> void:
	if backend == null or not _image_loaded or _exporting:
		return

	_exporting = true
	_export_path = path
	export_button.disabled = true
	open_button.disabled = true
	exposure_slider.editable = false
	contrast_slider.editable = false
	highlights_slider.editable = false
	shadows_slider.editable = false
	blacks_slider.editable = false
	whites_slider.editable = false
	saturation_slider.editable = false
	vibrance_slider.editable = false
	white_balance_slider.editable = false
	_set_color_wb_controls_enabled(false)

	WorkerThreadPool.add_task(_export_task)


func _export_task() -> void:
	var ok: bool = backend.export_image(_export_path)
	call_deferred("_on_export_done", ok, _export_path)


func _on_export_done(ok: bool, path: String) -> void:
	_exporting = false
	open_button.disabled = false
	exposure_slider.editable = true
	contrast_slider.editable = true
	highlights_slider.editable = true
	shadows_slider.editable = true
	blacks_slider.editable = true
	whites_slider.editable = true
	saturation_slider.editable = true
	vibrance_slider.editable = true
	white_balance_slider.editable = true
	_set_color_wb_controls_enabled(_image_loaded)
	export_button.disabled = not _image_loaded
	if not ok:
		push_error("Export failed for %s" % path.get_file())


# --- Persistent edit history: auto-save ---------------------------------------

# Arms the debounced save. No-op during restore, with no resolved edit key, or
# with no image loaded, so only genuine edits to a keyed photo are persisted.
func _mark_edit_dirty() -> void:
	if _restoring or _edit_key == "" or not _image_loaded:
		return
	_save_timer.start(_SAVE_DEBOUNCE_SEC)


# `flush` is true when called from _flush_pending_save, which cannot defer.
func _on_save_timer_timeout(flush: bool = false) -> void:
	if _edit_key == "" or not _image_loaded:
		return
	# An unresolved Auto click still holds the previous temperature/tint; never
	# write those under mode "auto". Resolve it first (safe only with no render
	# task running), or retry after the in-flight render if this is the timer.
	if _auto_wb_pending:
		if _processing and _current_task_id != -1:
			if not flush:
				_save_timer.start(_SAVE_DEBOUNCE_SEC)
				return
			WorkerThreadPool.wait_for_task_completion(_current_task_id)
			_processing = false
		_resolve_auto_wb()
	var meta: Dictionary = {
		"file_name": _edit_file_name,
		"thumb_hash": _edit_thumb_hash,
		"updated_at": int(Time.get_unix_time_from_system()),
	}
	EditStore.save(_edit_key, _params, meta)
	_store_edited_thumb()


# Downsamples the last whole-image Edit render into the edited library
# thumbnail so the grid and filmstrip show the photo as edited. No-ops when
# the held frame predates the current params, when no frame exists, or while
# the crop overlay has _params["crop"] temporarily neutralized. Deletes the
# variant instead of writing one when the photo is back to as-shot, so the
# grid falls back to the neutral thumbnail.
func _store_edited_thumb() -> void:
	if _edited_path == "" or _last_render_image == null or _crop_overlay != null:
		return
	var current_sig: String = EditStore.params_signature(_params)
	if _last_render_sig != current_sig:
		return

	var mtime: int = FileAccess.get_modified_time(_edited_path)
	var ekey: String = ThumbnailCache.edited_cache_key(_edited_path, mtime)

	if current_sig == EditStore.params_signature(_neutral_params):
		ThumbnailCache.erase_cached(ekey)
		library_view.invalidate_thumb(_edited_path)
		return

	var img: Image = _last_render_image.duplicate()
	var w: int = img.get_width()
	var h: int = img.get_height()
	var long_edge: int = maxi(w, h)
	if long_edge > ThumbnailCache.THUMB_MAX:
		var s: float = float(ThumbnailCache.THUMB_MAX) / float(long_edge)
		img.resize(maxi(1, roundi(w * s)), maxi(1, roundi(h * s)), Image.INTERPOLATE_LANCZOS)
	ThumbnailCache.store_thumb(ekey, img)
	library_view.invalidate_thumb(_edited_path)


# Writes a pending debounced save immediately. Called before the app quits and
# when leaving Edit, so a fast quit never drops the last debounce window.
func _flush_pending_save() -> void:
	if _save_timer != null and not _save_timer.is_stopped():
		_save_timer.stop()
		_on_save_timer_timeout(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_flush_pending_save()
		_cleanup_backend()
		if what == NOTIFICATION_WM_CLOSE_REQUEST:
			get_tree().quit()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# A hold (Space or the Before button) that's in progress when focus is
		# lost (alt-tab, etc.) never gets its key/button-up event, which would
		# otherwise strand the view on the before-render.
		_end_compare()


func _exit_tree() -> void:
	_cleanup_backend()


# --- Thumbnail worker mode (headless, no UI) -----------------------------------
# Entered instead of the normal GUI path when "--thumb-worker" is a user arg
# (OS.get_cmdline_user_args(), after the required "--" separator). Scans every
# root passed after the flag, renders a disk-cached thumbnail for every photo
# missing one, then quits. Own DtBackend, own darktable config/cache dir (set
# via env vars before the backend is created) so this process's darktable never
# collides with the GUI instance's.
func _run_thumb_worker(args: PackedStringArray) -> void:
	var roots: PackedStringArray = PackedStringArray()
	var past_flag: bool = false
	for arg in args:
		if arg == "--thumb-worker":
			past_flag = true
			continue
		if not past_flag:
			continue
		if arg.begins_with("--"):
			continue
		roots.append(arg)

	_configure_dt_backend_env()
	var config_dir: String = ProjectSettings.globalize_path("user://thumb_worker_dt/config")
	var cache_dir: String = ProjectSettings.globalize_path("user://thumb_worker_dt/cache")
	DirAccess.make_dir_recursive_absolute(config_dir)
	DirAccess.make_dir_recursive_absolute(cache_dir)
	OS.set_environment("DT_BACKEND_CONFIGDIR", config_dir)
	OS.set_environment("DT_BACKEND_CACHEDIR", cache_dir)

	backend = DtBackend.new()
	var ok: bool = backend.init(0, 0)
	if not ok:
		get_tree().quit(1)
		return

	# Poison-RAW self-isolation: fold in whatever the skip list already has,
	# plus whatever status.json says was mid-render when this process started
	# (a non-empty inprogress not already skip-listed means the previous
	# worker crashed on exactly that photo).
	var skip_set: Dictionary = {}
	for p in ThumbWorkerIPC.read_skip():
		skip_set[p] = true
	var prev_status: Dictionary = ThumbWorkerIPC.read_status()
	var crashed_path: String = String(prev_status.get("inprogress", ""))
	if crashed_path != "" and not skip_set.has(crashed_path):
		skip_set[crashed_path] = true
		printerr("[thumb-worker] skipping poison RAW from previous crash: ", crashed_path)
	ThumbWorkerIPC.write_skip(PackedStringArray(skip_set.keys()))

	# Dedupe across roots by path: the same photo could be reachable from two
	# overlapping/nested locations. Build an ordered pending list, scan order,
	# excluding anything already cached or skip-listed.
	var seen: Dictionary = {}
	var pending: Array[Dictionary] = []
	for root in roots:
		for photo in Library.scan_location(root):
			var path: String = photo["path"]
			if seen.has(path):
				continue
			seen[path] = true
			if skip_set.has(path):
				continue
			var key: String = ThumbnailCache.cache_key(path, photo["mtime"])
			if ThumbnailCache.load_cached(key) != null:
				continue
			pending.append(photo)

	var total: int = pending.size()
	var done: int = 0
	ThumbWorkerIPC.write_status(done, total, "", false)

	var priority_mtime: int = 0
	var priority_order: PackedStringArray = PackedStringArray()

	while not pending.is_empty():
		var cur_mtime: int = FileAccess.get_modified_time(ThumbWorkerIPC.PRIORITY_PATH)
		if cur_mtime != priority_mtime:
			priority_mtime = cur_mtime
			priority_order = ThumbWorkerIPC.read_priority()

		# Pick the first still-pending photo in priority order; fall back to
		# scan order (pending[0]) when none of the priority paths remain.
		var pick_index: int = -1
		for p_path in priority_order:
			for i in pending.size():
				if pending[i]["path"] == p_path:
					pick_index = i
					break
			if pick_index != -1:
				break
		if pick_index == -1:
			pick_index = 0

		var photo: Dictionary = pending[pick_index]
		pending.remove_at(pick_index)

		# Written BEFORE rendering: a hard crash mid-render leaves inprogress
		# pointing at the offending photo for the next worker's skip-list fold.
		ThumbWorkerIPC.write_status(done, total, photo["path"], false)
		_index_one_photo(photo)
		done += 1

		await get_tree().process_frame

	ThumbWorkerIPC.write_status(total, total, "", true)
	get_tree().quit(0)


# Renders and caches one photo if it isn't already cached. Defensive: any
# failure is logged and skipped rather than propagated, so one bad RAW doesn't
# stop the rest of the scan from indexing (a hard darktable segfault can't be
# caught here, so the caller just logs and continues).
func _index_one_photo(photo: Dictionary) -> void:
	var path: String = photo["path"]
	var key: String = ThumbnailCache.cache_key(path, photo["mtime"])
	if ThumbnailCache.load_cached(key) != null:
		return
	if photo["is_raw"]:
		if not backend.load_image(path):
			printerr("[thumb-worker] load_image failed for ", path)
			return
		var img: Image = _render_backend_thumb(key)
		if img == null:
			printerr("[thumb-worker] render failed for ", path)
	else:
		if ThumbnailCache.build_thumbnail(path, key) == null:
			printerr("[thumb-worker] build_thumbnail failed for ", path)


func _cleanup_backend() -> void:
	if _thumb_indexer != null:
		_thumb_indexer.stop()
	if backend != null:
		backend.cleanup()
		backend = null
	_last_render_image = null
	_last_render_sig = ""
