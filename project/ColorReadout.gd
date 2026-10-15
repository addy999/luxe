extends RefCounted

# Readout for the zero-centred Color sliders (Tint, Vibrance, Saturation): a
# signed integer ("+12", "-8") in the amber accent when non-zero, a plain "0"
# otherwise. Also the source of the amber accent for the amber slider knobs.

const FALLBACK_AMBER := Color(0.941, 0.651, 0.18)


static func signed_text(value: float) -> String:
	var rounded: int = roundi(value)
	return "%+d" % rounded if rounded != 0 else "0"


# HSlider/accent_amber from `control`'s theme, or FALLBACK_AMBER without a theme.
static func accent_color(control: Control) -> Color:
	if control.has_theme_color("accent_amber", "HSlider"):
		return control.get_theme_color("accent_amber", "HSlider")
	return FALLBACK_AMBER


# Sets the label text and colour; the "readout_active" meta lets refresh()
# recolour after a theme switch.
static func apply(label: Label, value: float) -> void:
	label.text = signed_text(value)
	label.set_meta("readout_active", roundi(value) != 0)
	refresh(label)


# Re-resolves the accent from the label's current theme.
static func refresh(label: Label) -> void:
	if label.get_meta("readout_active", false):
		label.add_theme_color_override("font_color", accent_color(label))
	else:
		label.remove_theme_color_override("font_color")
