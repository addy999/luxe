extends Node

# Autoload. Owns the light/dark Theme resources, applies the active one to the
# scene root, and persists the choice across launches. The root Control's
# `theme` property cascades to every child automatically (see main_theme.tres),
# so switching is a single assignment -- no per-node overrides needed.

signal theme_changed(is_dark: bool)

const SETTINGS_PATH := "user://settings.cfg"
const DARK_THEME_PATH := "res://main_theme.tres"
const LIGHT_THEME_PATH := "res://light_theme.tres"

var _dark_theme: Theme = preload(DARK_THEME_PATH)
var _light_theme: Theme = preload(LIGHT_THEME_PATH)
var is_dark: bool = true


func _ready() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		is_dark = config.get_value("ui", "dark_mode", true)
	_apply()


func toggle_theme() -> void:
	is_dark = not is_dark
	_apply()
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH) # ok to ignore error -- missing file just starts empty
	config.set_value("ui", "dark_mode", is_dark)
	config.save(SETTINGS_PATH)


func _apply() -> void:
	var root := get_tree().current_scene
	if root is Control:
		root.theme = _dark_theme if is_dark else _light_theme
	theme_changed.emit(is_dark)
