extends RefCounted

# Backend-free white-balance model shared by Main.gd and the unit tests.
#
# Persisted keys:
#   wb_mode      "as_shot" | "auto" | "custom": the selected segment.
#   wb_override  false: the pipe holds the exact camera state (module defaults);
#                true: wb_temperature/wb_tint are applied as an explicit correction.
# wb_override is false for a fresh photo and As Shot; true after a manual
# Temp/Tint edit, a successful Auto, or for a legacy temperature-only record.
# Selecting Custom or editing Vibrance/Saturation leaves it untouched.

const AS_SHOT := "as_shot"
const AUTO := "auto"
const CUSTOM := "custom"
const MODES: Array = [AS_SHOT, AUTO, CUSTOM]


static func is_valid_mode(value: Variant) -> bool:
	return value is String and MODES.has(value)


# The per-photo neutral white-balance values As Shot restores.
static func as_shot_values(as_shot_temp: float, as_shot_tint: float) -> Dictionary:
	return {
		"wb_mode": AS_SHOT,
		"wb_override": false,
		"wb_temperature": as_shot_temp,
		"wb_tint": as_shot_tint,
	}


# True when the pipe must hold the exact camera state rather than an explicit
# Temp/Tint correction.
static func is_neutral(mode: String, override: bool) -> bool:
	return mode == AS_SHOT or not override


# Mode of a saved record: a valid stored wb_mode wins; a legacy record (a
# temperature, no mode) is Custom; a record with no white-balance data is As Shot.
static func infer_mode(saved: Dictionary) -> String:
	if is_valid_mode(saved.get("wb_mode", null)):
		return saved["wb_mode"]
	if saved.has("wb_temperature"):
		return CUSTOM
	return AS_SHOT


# wb_mode/wb_override/wb_temperature/wb_tint to restore for a photo; `saved` is
# the loaded EditStore record ({} for a never-edited photo).
# Override: false for As Shot; otherwise the stored bool, defaulting to true (a
# legacy record, or a new record missing the bool).
# Values: without an override, the photo's current as-shot values (the mode
# stays as stored); with one, the stored values verbatim (Auto is never
# recomputed on restore; a missing tint is 0.0, what legacy records rendered with).
static func resolve_saved(saved: Dictionary, as_shot_temp: float, as_shot_tint: float) -> Dictionary:
	var mode: String = infer_mode(saved)
	var stored: Variant = saved.get("wb_override", null)
	var override: bool = mode != AS_SHOT and (stored if stored is bool else true)
	if not override:
		var neutral: Dictionary = as_shot_values(as_shot_temp, as_shot_tint)
		neutral["wb_mode"] = mode
		return neutral
	return {
		"wb_mode": mode,
		"wb_override": true,
		"wb_temperature": float(saved.get("wb_temperature", as_shot_temp)),
		"wb_tint": float(saved.get("wb_tint", 0.0)),
	}
