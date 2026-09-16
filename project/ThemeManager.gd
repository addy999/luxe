extends Node

# Autoload. Owns the light/dark Theme resources, applies the active one to the
# scene root, and persists the choice across launches. The root Control's
# `theme` property cascades to every child automatically (see main_theme.tres),
# so switching is a single assignment -- no per-node overrides needed.
#
# Font sizes: Theme resources only store baked pixel values, so there's no
# "em" unit to lean on. FONT_RATIOS recreates that relationship -- every
# style's size is expressed as a ratio of BASE_FONT_SIZE (the "1em" role,
# matching Label/Button/default). Bumping font_scale rescales all of them
# together, same as changing a root font-size in CSS.

signal theme_changed(is_dark: bool)
signal font_scale_changed(scale: float)

const SETTINGS_PATH := "user://settings.cfg"
const DARK_THEME_PATH := "res://main_theme.tres"
const LIGHT_THEME_PATH := "res://light_theme.tres"

const BASE_FONT_SIZE := 22
const MIN_FONT_SCALE := 0.75
const MAX_FONT_SCALE := 2.0

# theme_type -> size relative to BASE_FONT_SIZE, taken from the ratios
# already baked into main_theme.tres/light_theme.tres.
const FONT_RATIOS := {
	"": 1.0, # default_font_size
	"Button": 1.0,
	"CheckBox": 1.0,
	"CheckButton": 1.0,
	"GroupHeader": 11.0 / 13.0,
	"Label": 1.0,
	"Logo": 20.0 / 13.0,
	"Muted": 12.0 / 13.0,
	"LineEdit": 1.0,
	"TextEdit": 1.0,
	"PopupMenu": 1.0,
	"ProgressBar": 1.0,
	"Tree": 1.0,
}

var _dark_theme: Theme = preload(DARK_THEME_PATH)
var _light_theme: Theme = preload(LIGHT_THEME_PATH)
var is_dark: bool = true
var font_scale: float = 1.0


func _ready() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		is_dark = config.get_value("ui", "dark_mode", true)
	_apply_font_scale(_dark_theme)
	_apply_font_scale(_light_theme)
	_apply()


func toggle_theme() -> void:
	is_dark = not is_dark
	_apply()
	_save_settings()


func set_font_scale(scale: float) -> void:
	font_scale = clampf(scale, MIN_FONT_SCALE, MAX_FONT_SCALE)
	_apply_font_scale(_dark_theme)
	_apply_font_scale(_light_theme)
	font_scale_changed.emit(font_scale)


func _apply_font_scale(theme: Theme) -> void:
	var base := BASE_FONT_SIZE * font_scale
	theme.default_font_size = roundi(base)
	for theme_type: String in FONT_RATIOS:
		if theme_type.is_empty():
			continue
		theme.set_font_size("font_size", theme_type, roundi(base * FONT_RATIOS[theme_type]))


func _apply() -> void:
	var root := get_tree().current_scene
	if root is Control:
		root.theme = _dark_theme if is_dark else _light_theme
	theme_changed.emit(is_dark)


func _save_settings() -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH) # ok to ignore error -- missing file just starts empty
	config.set_value("ui", "dark_mode", is_dark)
	config.save(SETTINGS_PATH)
