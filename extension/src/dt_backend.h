/*
 * DtBackend -- GDExtension shim exposing darktable's headless pixelpipe to
 * GDScript for the Godot-on-darktable PoC.
 *
 * See the "The big idea: two languages, one process" section of
 * godot-poc/README.md for the overall architecture this class implements.
 *
 * This backend holds exactly one image/session at a time (darktable's core
 * state -- darktable.image_cache, darktable.mipmap_cache, etc. -- is a
 * single process-wide global), matching the architecture's "one
 * image/session at a time in-process" constraint.
 *
 * This file reproduces several private IOP parameter structs verbatim from
 * darktable (https://github.com/darktable-org/darktable), Copyright (C) the
 * darktable contributors, licensed under the GNU General Public License v3.0
 * or later. See NOTICE for full attribution and source provenance, and each
 * struct below for the specific upstream file/line it was copied from.
 */
#pragma once

#include <string>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>

// darktable headless core headers.
extern "C" {
#include "common/darktable.h"
#include "common/film.h"
#include "common/image.h"
#include "common/mipmap_cache.h"
#include "develop/blend.h" // dt_develop_blend_params_t + DEVELOP_MASK_* (blend params for uniform-opacity blending; also included by pixelpipe_hb.c in the nogui build, so it is safe headless)
#include "develop/develop.h"
#include "develop/imageop.h"
#include "develop/pixelpipe_hb.h"
#include "imageio/imageio_common.h"
#include "imageio/imageio_module.h"
}

// dt_iop_exposure_params_t is defined inside source/src/iop/exposure.c
// itself (not a header) -- darktable IOP modules keep their params struct
// private to their own translation unit and only expose it to the rest of
// darktable as an opaque `void *params` blob sized by `params_size`, with
// runtime introspection doing the rest. That means this struct can't be
// #included; it's redeclared here to match exposure.c exactly (field order
// and types straight from source/src/iop/exposure.c:49-75,
// DT_MODULE_INTROSPECTION version 7).
// If exposure.c's params struct or introspection version ever changes,
// this redeclaration must be updated to match.
typedef enum dt_iop_exposure_mode_t
{
  EXPOSURE_MODE_MANUAL,
  EXPOSURE_MODE_DEFLICKER
} dt_iop_exposure_mode_t;

typedef struct dt_iop_exposure_params_t
{
  dt_iop_exposure_mode_t mode;
  float black;
  float exposure;
  float deflicker_percentile;
  float deflicker_target_level;
  gboolean compensate_exposure_bias;
  gboolean compensate_hilite_pres;
} dt_iop_exposure_params_t;

// dt_iop_colorbalancergb_params_t is likewise private to
// source/src/iop/colorbalancergb.c, so it's redeclared here to match that file
// exactly (source/src/iop/colorbalancergb.c:54-106, DT_MODULE_INTROSPECTION
// version 5). We only drive the `contrast` field ($MIN: -1.0 $MAX: 1.0
// $DEFAULT: 0.0), but the WHOLE struct and its trailing enum must be reproduced
// verbatim -- field order and types are load-bearing: the opaque void* params
// blob is indexed by offset, so a wrong/missing field silently shifts `contrast`
// to the wrong bytes. Every field here is 4 bytes (float, or the int-sized enum),
// so the layout is padding-free. The enum name keeps darktable's own upstream
// spelling `colorbalancrgb` (missing the second `e`) on purpose. If this
// module's struct or introspection version changes upstream, update this block.
typedef enum dt_iop_colorbalancrgb_saturation_t
{
  DT_COLORBALANCE_SATURATION_JZAZBZ = 0,
  DT_COLORBALANCE_SATURATION_DTUCS = 1
} dt_iop_colorbalancrgb_saturation_t;

typedef struct dt_iop_colorbalancergb_params_t
{
  /* params of v1 */
  float shadows_Y;
  float shadows_C;
  float shadows_H;
  float midtones_Y;
  float midtones_C;
  float midtones_H;
  float highlights_Y;
  float highlights_C;
  float highlights_H;
  float global_Y;
  float global_C;
  float global_H;
  float shadows_weight;
  float white_fulcrum;
  float highlights_weight;
  float chroma_shadows;
  float chroma_highlights;
  float chroma_global;
  float chroma_midtones;
  float saturation_global;
  float saturation_highlights;
  float saturation_midtones;
  float saturation_shadows;
  float hue_angle;

  /* params of v2 */
  float brilliance_global;
  float brilliance_highlights;
  float brilliance_midtones;
  float brilliance_shadows;

  /* params of v3 */
  float mask_grey_fulcrum;

  /* params of v4 */
  float vibrance;
  float grey_fulcrum;
  float contrast;

  /* params of v5 */
  dt_iop_colorbalancrgb_saturation_t saturation_formula;
} dt_iop_colorbalancergb_params_t;

// dt_iop_shadhi_params_t is likewise private to source/src/iop/shadhi.c, so
// it's redeclared here to match that file exactly (source/src/iop/shadhi.c:
// 66-80, DT_MODULE_INTROSPECTION version 5). We only drive `shadows` ($MIN:
// -100.0 $MAX: 100.0 $DEFAULT: 50.0) and `highlights` ($MIN: -100.0 $MAX:
// 100.0 $DEFAULT: -50.0), but the whole struct must be reproduced verbatim --
// field order/types are load-bearing (offset-indexed opaque void* params
// blob), including `reserved2`, which carries no introspection tag but must
// stay in place or every field after it (compress onward) shifts. The op
// name for lookup is "shadhi" (source filename), while name() returns the
// display string "shadows and highlights". dt_gaussian_order_t is normally
// declared in source/src/common/gaussian.h; redeclared here for the same
// reason. If shadhi.c's struct or introspection version changes upstream,
// update this block.
// dt_gaussian_order_t used to be redeclared here (shadhi.c keeps it private);
// blend.h (needed for monochrome's blend-opacity driving) pulls in
// common/gaussian.h which defines it for real, so the redeclaration is gone.

typedef enum dt_iop_shadhi_algo_t
{
  SHADHI_ALGO_GAUSSIAN,
  SHADHI_ALGO_BILATERAL
} dt_iop_shadhi_algo_t;

typedef struct dt_iop_shadhi_params_t
{
  dt_gaussian_order_t order;
  float radius;
  float shadows;
  float whitepoint;
  float highlights;
  float reserved2;
  float compress;
  float shadows_ccorrect;
  float highlights_ccorrect;
  unsigned int flags;
  float low_approximation;
  dt_iop_shadhi_algo_t shadhi_algo;
} dt_iop_shadhi_params_t;

// dt_iop_toneequalizer_params_t is likewise private to
// source/src/iop/toneequal.c, so it's redeclared here to match that file
// exactly (source/src/iop/toneequal.c:171-193, DT_MODULE_INTROSPECTION
// version 2). This module backs the app's "Blacks"/"Whites" sliders, which
// need TWO-SIDED control (Lightroom semantics: positive Whites brightens,
// positive Blacks deepens). It replaced rgblevels, whose black/white POINT
// fields are hard-bounded to 0..1 (RGBLEVELS_MIN/MAX, rgblevels.c:36-38) and
// at neutral already sit AT those extremes, so there was no field to write
// for "expand the range" -- Whites could only compress the white point down,
// which read as broken in the UI. toneequal exposes nine 1-EV-band gain
// fields, all two-sided (-2..+2 EV, default 0, zero coupling); we drive
// `whites` (the -1 EV band, toneequal.c:180) and `blacks` (the -5 EV band,
// toneequal.c:176). NOTE THE SIGN: a positive EV gain LIFTS its band, but
// Lightroom's positive Blacks DEEPENS blacks, so the Blacks setter writes
// -value (sign-inverted); Whites writes +value straight through. The UI range
// is -1..1; Blacks maps to the FULL ±2 EV band gain (at ±1 EV it felt weaker
// than the shadhi-backed Shadows slider), Whites to ±1 EV. Mask machinery
// is pinned to the
// module's "simple tone curve" preset values (toneequal.c:480-491): details =
// DT_TONEEQ_NONE (no guided filter -- global tone curve, cheap and free of
// side effects), method = DT_TONEEQ_NORM_2 (dt_iop_luminance_mask_method_t,
// source/src/common/luminance_mask.h:39-49, 4-byte enum, RGB euclidean norm =
// 4), iterations = 1, all boost fields 0. blending/feathering/quantization/
// smoothing are ignored by DT_TONEEQ_NONE but set to preset defaults anyway
// so the params blob always matches a known state. Every field is 4 bytes, so
// the layout is padding-free. If toneequal.c's struct or introspection
// version changes upstream, update this block.

typedef enum dt_iop_toneequalizer_filter_t
{
  DT_TONEEQ_NONE = 0,
  DT_TONEEQ_AVG_GUIDED,
  DT_TONEEQ_GUIDED,
  DT_TONEEQ_AVG_EIGF,
  DT_TONEEQ_EIGF
} dt_iop_toneequalizer_filter_t;

typedef struct dt_iop_toneequalizer_params_t
{
  float noise;              // $MIN: -2.0 $MAX: 2.0 $DEFAULT: 0.0 ("blacks")
  float ultra_deep_blacks;  // $MIN: -2.0 $MAX: 2.0 $DEFAULT: 0.0 ("deep shadows")
  float deep_blacks;        // $MIN: -2.0 $MAX: 2.0 $DEFAULT: 0.0 ("shadows")
  float blacks;             // $MIN: -2.0 $MAX: 2.0 $DEFAULT: 0.0 ("light shadows")
  float shadows;            // $MIN: -2.0 $MAX: 2.0 $DEFAULT: 0.0 ("mid-tones")
  float midtones;           // $MIN: -2.0 $MAX: 2.0 $DEFAULT: 0.0 ("dark highlights")
  float highlights;         // $MIN: -2.0 $MAX: 2.0 $DEFAULT: 0.0 ("highlights")
  float whites;             // $MIN: -2.0 $MAX: 2.0 $DEFAULT: 0.0 ("whites")
  float speculars;          // $MIN: -2.0 $MAX: 2.0 $DEFAULT: 0.0 ("speculars")
  float blending;           // $MIN: 0.01 $MAX: 100.0 $DEFAULT: 5.0
  float smoothing;          // $DEFAULT: sqrt(2)
  float feathering;         // $MIN: 0.01 $MAX: 10000.0 $DEFAULT: 1.0
  float quantization;       // $MIN: 0.0 $MAX: 2.0 $DEFAULT: 0.0
  float contrast_boost;     // $MIN: -16.0 $MAX: 16.0 $DEFAULT: 0.0
  float exposure_boost;     // $MIN: -16.0 $MAX: 16.0 $DEFAULT: 0.0
  dt_iop_toneequalizer_filter_t details; // $DEFAULT: DT_TONEEQ_EIGF (we pin NONE)
  int method;               // dt_iop_luminance_mask_method_t, $DEFAULT: DT_TONEEQ_NORM_2 (4)
  int iterations;           // $MIN: 1 $MAX: 20 $DEFAULT: 1
} dt_iop_toneequalizer_params_t;

// dt_iop_velvia_params_t is likewise private to source/src/iop/velvia.c, so
// it's redeclared here to match that file exactly (source/src/iop/velvia.c:
// 40-44, DT_MODULE_INTROSPECTION version 2). We only drive `strength` ($MIN:
// 0.0 $MAX: 100.0 $DEFAULT: 25.0), but the whole struct (including `bias`)
// must be reproduced verbatim -- field order/types are load-bearing. If
// velvia.c's struct or introspection version changes upstream, update this
// block. "velvia" is a saturation-boost module and is what this app's
// "Saturation" slider drives.
typedef struct dt_iop_velvia_params_t
{
  float strength;
  float bias;
} dt_iop_velvia_params_t;

// dt_iop_monochrome_params_t is likewise private to source/src/iop/monochrome.c,
// so it is redeclared here to match that file exactly (source/src/iop/
// monochrome.c:49-55, DT_MODULE_INTROSPECTION version 2). This backend never
// writes any of these fields -- the module's introspection defaults (a=0, b=0,
// size=2, highlights=0) sitting in the live params blob are already a plain
// neutral grayscale conversion, which is all the saturation slider's
// below-neutral range needs. What it DOES drive is the module's blend
// parameters (dt_develop_blend_params_t, source/src/develop/blend.h:180-225):
// uniform-mask mode (DEVELOP_MASK_ENABLED) with a fractional `opacity`
// (0..100), so the slider can fade between full color and full B&W. If
// monochrome.c's struct or introspection version changes upstream, update
// this block.
typedef struct dt_iop_monochrome_params_t
{
  float a;
  float b;
  float size;
  float highlights;
} dt_iop_monochrome_params_t;

// dt_iop_vibrance_params_t is likewise private to source/src/iop/vibrance.c,
// so it's redeclared here to match that file exactly (source/src/iop/
// vibrance.c:37-40, DT_MODULE_INTROSPECTION version 2). Single-field struct:
// `amount` ($MIN: 0.0 $MAX: 100.0 $DEFAULT: 25.0). If vibrance.c's struct or
// introspection version changes upstream, update this block.
typedef struct dt_iop_vibrance_params_t
{
  float amount;
} dt_iop_vibrance_params_t;

// NOTE on white balance: earlier revisions of this backend drove `temperature.c`'s
// red/green/blue directly to implement white balance, matching darktable's
// LEGACY workflow where `temperature` owns the camera-to-D65 correction. In
// the modern scene-referred (sigmoid) workflow this checkout defaults to,
// `temperature` is instead pinned to a neutral D65_LATE preset (1.0/1.0/1.0)
// and the real chromatic adaptation is performed by `channelmixerrgb` (op
// name "channelmixerrgb", display name "color calibration"; see
// source/src/iop/channelmixerrgb.c reload_defaults(), lines ~3844-3888).
// Force-enabling/committing `temperature` for WB fought that handoff and
// left the camera-to-D65 correction never applied, which is the "green
// tint" bug. `temperature` is now left completely untouched by this backend
// (no setter, no getter, no forced enable/history item); the struct
// redeclaration for it has been removed along with set/get_white_balance_red/
// _blue(). White balance is now driven via set_white_balance_temperature()
// below, which targets `channelmixerrgb`'s `temperature`/`illuminant`/
// `adaptation` fields instead. If a future task needs to read/write
// `temperature.c`'s own params again, its struct was: { float red; float
// green; float blue; float various; int preset; } (source/src/iop/
// temperature.c:67-74, DT_MODULE_INTROSPECTION version 4).

// dt_iop_channelmixer_rgb_params_t is private to
// source/src/iop/channelmixerrgb.c, so it's redeclared here to match that
// file exactly (source/src/iop/channelmixerrgb.c:92-116, DT_MODULE_
// INTROSPECTION version 3). CHANNEL_SIZE is 4 (channelmixerrgb.c:73). We only
// drive `illuminant`, `adaptation`, and `temperature` ($MIN: TEMP_MIN=1667.0
// $MAX: TEMP_MAX=25000.0 $DEFAULT: 5003.0) to implement white balance as a
// chromatic-adaptation-transform (CAT) problem: illuminant = DT_ILLUMINANT_D
// (daylight) with `temperature` set from the Kelvin slider, and adaptation =
// DT_ADAPTATION_CAT16 (both are the module's own defaults for a
// non-monochrome raw with no other CAT already registered on the pipe -- see
// reload_defaults() below). The channel-mix matrix (red/green/blue/grey[])
// and everything else is left at whatever darktable itself initialized, so
// this backend only ever touches 3 of the ~20 fields. The WHOLE struct must
// still be reproduced verbatim -- field order/types are load-bearing, since
// the opaque void* params blob is indexed by offset. Every field here is
// 4 bytes (float, gboolean/gint, or a 4-byte enum), so the layout is
// padding-free.
//
// Per source/src/iop/channelmixerrgb.c commit_params() (lines ~3092-3098):
// for any illuminant OTHER than DT_ILLUMINANT_CAMERA/DT_ILLUMINANT_CUSTOM,
// the module derives the CIE xy chromaticity coordinates (`x`,`y` in this
// struct) FROM `illuminant`+`temperature` at commit time via
// illuminant_to_xy() -- it does not read back the `x`,`y` fields we don't
// set for DT_ILLUMINANT_D. So setting `temperature` alone (with illuminant
// pinned to DT_ILLUMINANT_D) is sufficient to drive the adaptation matrix;
// `x`/`y` are left untouched (they default to 0.333 per the struct's own
// $DEFAULT and are irrelevant for DT_ILLUMINANT_D).
//
// Per reload_defaults() (channelmixerrgb.c lines ~3844-3888): on a fresh RAW
// load with no other module already registered as the pipe's CAT, darktable
// itself computes the AS-SHOT temperature from the camera's raw white-balance
// coefficients (find_temperature_from_raw_coeffs()) and typically resolves
// illuminant to DT_ILLUMINANT_CAMERA or DT_ILLUMINANT_D (via
// _check_if_close_to_daylight()), NOT the struct's flat $DEFAULT: 5003.0.
// get_white_balance_temperature() below reads that already-resolved
// as-shot value back (before this backend's setter ever runs) so the UI can
// seed its slider from the real per-image default, matching the old
// get_white_balance_red()/_blue() pattern. If channelmixerrgb.c's struct or
// introspection version changes upstream, update this block.
#define DT_BACKEND_CHANNELMIXERRGB_CHANNEL_SIZE 4

typedef enum dt_backend_illuminant_t
{
  DT_BACKEND_ILLUMINANT_PIPE            = 0,
  DT_BACKEND_ILLUMINANT_A               = 1,
  DT_BACKEND_ILLUMINANT_D               = 2,
  DT_BACKEND_ILLUMINANT_E               = 3,
  DT_BACKEND_ILLUMINANT_F               = 4,
  DT_BACKEND_ILLUMINANT_LED             = 5,
  DT_BACKEND_ILLUMINANT_BB              = 6,
  DT_BACKEND_ILLUMINANT_CUSTOM          = 7,
  DT_BACKEND_ILLUMINANT_DETECT_SURFACES = 8,
  DT_BACKEND_ILLUMINANT_DETECT_EDGES    = 9,
  DT_BACKEND_ILLUMINANT_CAMERA          = 10,
} dt_backend_illuminant_t;

typedef enum dt_backend_illuminant_fluo_t
{
  DT_BACKEND_ILLUMINANT_FLUO_F1  = 0,
  DT_BACKEND_ILLUMINANT_FLUO_F2  = 1,
  DT_BACKEND_ILLUMINANT_FLUO_F3  = 2,
  DT_BACKEND_ILLUMINANT_FLUO_F4  = 3,
  DT_BACKEND_ILLUMINANT_FLUO_F5  = 4,
  DT_BACKEND_ILLUMINANT_FLUO_F6  = 5,
  DT_BACKEND_ILLUMINANT_FLUO_F7  = 6,
  DT_BACKEND_ILLUMINANT_FLUO_F8  = 7,
  DT_BACKEND_ILLUMINANT_FLUO_F9  = 8,
  DT_BACKEND_ILLUMINANT_FLUO_F10 = 9,
  DT_BACKEND_ILLUMINANT_FLUO_F11 = 10,
  DT_BACKEND_ILLUMINANT_FLUO_F12 = 11,
} dt_backend_illuminant_fluo_t;

typedef enum dt_backend_illuminant_led_t
{
  DT_BACKEND_ILLUMINANT_LED_B1   = 0,
  DT_BACKEND_ILLUMINANT_LED_B2   = 1,
  DT_BACKEND_ILLUMINANT_LED_B3   = 2,
  DT_BACKEND_ILLUMINANT_LED_B4   = 3,
  DT_BACKEND_ILLUMINANT_LED_B5   = 4,
  DT_BACKEND_ILLUMINANT_LED_BH1  = 5,
  DT_BACKEND_ILLUMINANT_LED_RGB1 = 6,
  DT_BACKEND_ILLUMINANT_LED_V1   = 7,
  DT_BACKEND_ILLUMINANT_LED_V2   = 8,
} dt_backend_illuminant_led_t;

typedef enum dt_backend_adaptation_t
{
  DT_BACKEND_ADAPTATION_LINEAR_BRADFORD = 0,
  DT_BACKEND_ADAPTATION_CAT16           = 1,
  DT_BACKEND_ADAPTATION_FULL_BRADFORD   = 2,
  DT_BACKEND_ADAPTATION_XYZ             = 3,
  DT_BACKEND_ADAPTATION_RGB             = 4,
} dt_backend_adaptation_t;

typedef enum dt_backend_channelmixerrgb_version_t
{
  DT_BACKEND_CHANNELMIXERRGB_V_1 = 0,
  DT_BACKEND_CHANNELMIXERRGB_V_2 = 1,
  DT_BACKEND_CHANNELMIXERRGB_V_3 = 2,
} dt_backend_channelmixerrgb_version_t;

// TEMP_MIN/TEMP_MAX from channelmixerrgb.c:82-83, used to clamp
// set_white_balance_temperature()'s input.
#define DT_BACKEND_CHANNELMIXERRGB_TEMP_MIN 1667.0f
#define DT_BACKEND_CHANNELMIXERRGB_TEMP_MAX 25000.0f

typedef struct dt_iop_channelmixer_rgb_params_t
{
  /* params of v1 and v2 */
  float red[DT_BACKEND_CHANNELMIXERRGB_CHANNEL_SIZE];
  float green[DT_BACKEND_CHANNELMIXERRGB_CHANNEL_SIZE];
  float blue[DT_BACKEND_CHANNELMIXERRGB_CHANNEL_SIZE];
  float saturation[DT_BACKEND_CHANNELMIXERRGB_CHANNEL_SIZE];
  float lightness[DT_BACKEND_CHANNELMIXERRGB_CHANNEL_SIZE];
  float grey[DT_BACKEND_CHANNELMIXERRGB_CHANNEL_SIZE];
  gboolean normalize_R, normalize_G, normalize_B, normalize_sat, normalize_light, normalize_grey;
  dt_backend_illuminant_t illuminant;
  dt_backend_illuminant_fluo_t illum_fluo;
  dt_backend_illuminant_led_t illum_led;
  dt_backend_adaptation_t adaptation;
  float x, y;
  float temperature;
  float gamut;
  gboolean clip;

  /* params of v3 */
  dt_backend_channelmixerrgb_version_t version;

  /* always add new params after this so we can import legacy params with memcpy on the common part of the struct */

} dt_iop_channelmixer_rgb_params_t;

// dt_iop_tonecurve_params_t is likewise private to source/src/iop/tonecurve.c,
// so it's redeclared here to match that file exactly (source/src/iop/
// tonecurve.c:81-112, DT_MODULE_INTROSPECTION version 5). Unlike every other
// module above, the field we drive (`tonecurve[0]`, the L-channel curve) is a
// fixed-size array of {x,y} node structs plus a live node count
// (`tonecurve_nodes[0]`), not a single scalar -- see set_tonecurve() below
// for the spline UI this backs. DT_IOP_TONECURVE_MAXNODES is 20
// (tonecurve.c:48). The whole
// struct (all three L/a/b channels, autoscale, preset, unbound_ab,
// preserve_colors) must be reproduced verbatim even though we only ever touch
// channel 0 -- field order/types are load-bearing. If tonecurve.c's struct or
// introspection version changes upstream, update this block.
#define DT_BACKEND_TONECURVE_MAXNODES 20

typedef struct dt_iop_tonecurve_node_t
{
  float x;
  float y;
} dt_iop_tonecurve_node_t;

typedef enum dt_iop_tonecurve_autoscale_t
{
  DT_S_SCALE_MANUAL = 0,
  DT_S_SCALE_AUTOMATIC = 1,
  DT_S_SCALE_AUTOMATIC_XYZ = 2,
  DT_S_SCALE_AUTOMATIC_RGB = 3,
} dt_iop_tonecurve_autoscale_t;

// Mirrors the plain #defines CUBIC_SPLINE/CATMULL_ROM/MONOTONE_HERMITE from
// source/src/common/curve_tools.h:27-29 (0/1/2) -- tonecurve_type[] stores one
// of these as a plain int, not a named enum type, in the real struct.
#define DT_BACKEND_MONOTONE_HERMITE 2

typedef struct dt_iop_tonecurve_params_t
{
  dt_iop_tonecurve_node_t tonecurve[3][DT_BACKEND_TONECURVE_MAXNODES]; // L, a, b
  int tonecurve_nodes[3];
  int tonecurve_type[3];
  dt_iop_tonecurve_autoscale_t tonecurve_autoscale_ab;
  int tonecurve_preset;
  int tonecurve_unbound_ab;
  int preserve_colors; // dt_iop_rgb_norms_t, 4-byte enum
} dt_iop_tonecurve_params_t;

// dt_iop_clipping_params_t is likewise private to source/src/iop/clipping.c,
// so it's redeclared here to match that file exactly (source/src/iop/
// clipping.c:58-79, DT_MODULE_INTROSPECTION version 5). We only drive the
// crop box cx/cy/cw/ch -- which are LEFT/TOP/RIGHT/BOTTOM edges, NOT x/y/w/h
// (the $DESCRIPTION labels at clipping.c:61-64 and commit_params' copysignf
// at clipping.c:3094-3104 confirm; sign of cw/ch encodes flip, magnitude is
// the edge) -- as normalized fractions 0..1 of the whole image. commit_params
// clamps them (clipping.c:1325-1328): cx/cy to 0..0.9, |cw|/|ch| to 0.1..1.0.
// No crop = cx=0, cy=0, cw=1, ch=1 (image.c initializes usercrop to {0,0,1,1},
// and clipping's own commit_box resets to the same when first enabled). All
// other fields (angle, keystone quad, ratio) are left at the module's
// introspection defaults so no rotation/keystone/aspect-lock is applied.
// The WHOLE struct must be reproduced verbatim -- field order/types are
// load-bearing (opaque void* params blob indexed by offset). gboolean is
// glib's gint (4 bytes) and every field here is 4 bytes, so the layout is
// padding-free. If clipping.c's struct or introspection version changes
// upstream, update this block.
typedef struct dt_iop_clipping_params_t
{
  float angle; // $MIN: -180.0 $MAX: 180.0
  float cx;    // $MIN: 0.0 $MAX: 1.0 $DESCRIPTION: "left"
  float cy;    // $MIN: 0.0 $MAX: 1.0 $DESCRIPTION: "top"
  float cw;    // $MIN: 0.0 $MAX: 1.0 $DESCRIPTION: "right"
  float ch;    // $MIN: 0.0 $MAX: 1.0 $DESCRIPTION: "bottom"
  float k_h, k_v;
  float kxa;   // $MIN: 0.0 $MAX: 1.0 $DEFAULT: 0.2
  float kya;   // $MIN: 0.0 $MAX: 1.0 $DEFAULT: 0.2
  float kxb;   // $MIN: 0.0 $MAX: 1.0 $DEFAULT: 0.8
  float kyb;   // $MIN: 0.0 $MAX: 1.0 $DEFAULT: 0.2
  float kxc;   // $MIN: 0.0 $MAX: 1.0 $DEFAULT: 0.8
  float kyc;   // $MIN: 0.0 $MAX: 1.0 $DEFAULT: 0.8
  float kxd;   // $MIN: 0.0 $MAX: 1.0 $DEFAULT: 0.2
  float kyd;   // $MIN: 0.0 $MAX: 1.0 $DEFAULT: 0.8
  int k_type, k_sym;
  int k_apply;   // $DEFAULT: 0
  int crop_auto; // gboolean: $DEFAULT: TRUE ("automatic cropping")
  int ratio_n;   // $DEFAULT: -1
  int ratio_d;   // $DEFAULT: -1
} dt_iop_clipping_params_t;

namespace godot {

class DtBackend : public RefCounted {
  GDCLASS(DtBackend, RefCounted)

private:
  bool initialized = false;
  bool image_loaded = false;
  bool pipe_ready = false;
  bool cleaned_up = false;

  dt_imgid_t imgid = NO_IMGID;
  dt_develop_t dev;
  // Full pipe: DT_DEV_PIXELPIPE_FULL, fed the full-res demosaiced buffer
  // (DT_MIPMAP_FULL). The existing "final quality" render path (render_view()).
  dt_dev_pixelpipe_t pipe;
  dt_mipmap_buffer_t mipmap_buf;
  // Fast preview pipe: DT_DEV_PIXELPIPE_PREVIEW via dt_dev_pixelpipe_init_preview().
  // Hybrid (): it is fed the
  // downscaled DT_MIPMAP_F float mip (knob 1's input, which is fast because
  // demosaic runs at the mip's resolution, not native), but that mip is now
  // generated at the display's physical pixel resolution instead of darktable's
  // fixed 1440x900/1920x1200 (see init()). render_preview()'s `scale` is a
  // fraction of that mip's dimensions. Both pipes share `dev` and therefore the
  // same module params/history; each has its own node list and cache.
  dt_dev_pixelpipe_t preview_pipe;
  // The DT_MIPMAP_F buffer backing the preview pipe's input. Held open (locked)
  // for the preview pipe's lifetime, exactly like mipmap_buf for the full pipe.
  dt_mipmap_buffer_t preview_mipmap_buf;
  bool preview_pipe_ready = false;
  // Cached preview-pipe processed dimensions (scale=1.0), filled by
  // refresh_preview_dimensions(). These are the mip's dimensions, which this
  // build sizes to the display's physical pixels, so they are smaller than the
  // full pipe's native_width/native_height (except on a display as large as the
  // image). Kept separate because they are the preview ROI math's authoritative
  // native size.
  int preview_native_width = 0;
  int preview_native_height = 0;

  // Physical display dimensions passed to init(). Used to size darktable's
  // DT_MIPMAP_F preview mip (see init()); 0,0 keeps darktable's fixed default.
  int display_width_ = 0;
  int display_height_ = 0;

  // Cached module pointer for repeated set_exposure() calls so we don't
  // re-search dev.iop.
  dt_iop_module_t *exposure_module = nullptr;
  dt_iop_module_t *colorbalance_module = nullptr;
  dt_iop_module_t *shadhi_module = nullptr;
  // toneequal ("tone equalizer") backs the Blacks/Whites sliders -- see the
  // dt_iop_toneequalizer_params_t redeclaration above.
  dt_iop_module_t *toneequal_module = nullptr;
  dt_iop_module_t *velvia_module = nullptr;
  // monochrome backs the saturation slider's BELOW-neutral range only -- see
  // set_saturation() in dt_backend.cpp for how the two modules split the range.
  dt_iop_module_t *monochrome_module = nullptr;
  dt_iop_module_t *vibrance_module = nullptr;
  dt_iop_module_t *tonecurve_module = nullptr;
  // White balance now targets channelmixerrgb ("color calibration"), not
  // temperature -- see the NOTE on white balance above
  // dt_iop_channelmixer_rgb_params_t.
  dt_iop_module_t *channelmixer_rgb_module = nullptr;
  dt_iop_module_t *clipping_module = nullptr;

  int processed_width = 0;
  int processed_height = 0;

  // Cached native (scale=1.0) processed dimensions, filled in the first time
  // either process_fit() or render_view() calls dt_dev_pixelpipe_get_dimensions().
  // GDScript needs these (via get_native_width()/get_native_height()) to decide,
  // for a chosen zoom percentage, whether the scaled image exceeds the viewport
  // and therefore needs ROI/panning -- see render_view() below and Main.gd's
  // zoom-mode dropdown.
  int native_width = 0;
  int native_height = 0;

  // Raw sensor/file dimensions (dev.image_storage->width/height), captured at
  // load_image() time, before any pipeline processing runs. Unlike
  // native_width/native_height (which need a process_fit()/render_view() call
  // to populate), these are available immediately after a successful
  // load_image(), so GDScript can pick a size-appropriate default edit scale
  // before the first render. Close enough to the final processed size for that
  // purpose (crop/rotate modules can change it slightly, but not by orders of
  // magnitude).
  int raw_width = 0;
  int raw_height = 0;

  // --- Incremental change dispatch ------------------------------------------
  // Every setter ends with dt_dev_add_history_item_ext(..., no_image=TRUE)
  // because darktable skips building the GUI pipes when gui_attached is FALSE
  // (develop.c:101-116, guarded by dev->gui_attached) yet the !no_image branch
  // unconditionally ORs DT_DEV_PIPE_*_CHANGED onto dev->full.pipe/preview_pipe
  // (develop.c:1404-1410, 1432-1437) -- NULL here, so dropping no_image would
  // crash. That branch is also the only place the GUI's change dispatch comes
  // from, so this bridge tracks the change itself against its standalone
  // `pipe`.
  //
  // One changed module maps exactly onto darktable's DT_DEV_PIPE_TOP_CHANGED /
  // dt_dev_pixelpipe_synch_top(): add_history_item_ext() leaves the module it
  // was called for as the top history item, and synch_top re-commits only that
  // item, so every upstream cache line survives. Two or more changed modules
  // (Main.gd pushes all params on load, and coalesced slider moves can arrive
  // together) cannot be expressed as TOP_CHANGED -- synch_top would commit only
  // the last one -- so that falls back to a full dt_dev_pixelpipe_synch_all().
  bool pipe_change_pending = false;
  bool pipe_change_multi = false;
  bool pipe_needs_full_synch = false;
  dt_iop_module_t *pipe_change_module = nullptr;

  // Records `module` as changed and raises pipe_needs_full_synch if enabling it
  // flips a still-disabled piece, which the full history replay settles.
  void note_pipe_change(dt_iop_module_t *module);

  // Applies any pending change (synch_top for a single changed module, synch_all
  // for a multi-module batch or an enabled-state flip) to BOTH the full pipe and
  // the preview pipe, then clears the pending flags. Both pipes must be told about
  // a change or one of them silently serves stale pixels on its next render, so
  // the dispatch lives here rather than inside either render entry point.
  void dispatch_pipe_changes();

  // Shared helper: dispatches pending changes then refreshes
  // native_width/native_height from the FULL pipe. Called by process_fit() and
  // render_view() so there is exactly one place that reads the full pipe's
  // dimensions.
  bool refresh_native_dimensions();

  // Same, for the preview pipe: dispatches pending changes then refreshes
  // preview_native_width/preview_native_height. Returns false if no preview pipe
  // is available (dt_dev_pixelpipe_init_preview() failed in load_image()).
  bool refresh_preview_dimensions();

  // The one ROI-process-read implementation, shared by render_view() and
  // render_preview() so the two paths cannot drift. `p` is the pipe to run,
  // native_w/native_h its scale=1.0 processed dimensions. Implements darktable's
  // own darkroom scale/ROI math (develop.c:874-890); see render_view()'s comment.
  PackedByteArray render_pipe_roi(dt_dev_pixelpipe_t *p, int native_w, int native_h,
                                  int viewport_w, int viewport_h, double scale,
                                  double center_x, double center_y);

  // Computes darktable's --datadir/--moduledir at runtime instead of relying
  // on compile-time-baked absolute paths.
  // Tries, in order: (1) DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR env vars,
  // (2) a location relative to Godot's own running executable (exported .app
  // bundle layout), (3) a location relative to this extension's own shared
  // library file on disk (via dladdr()), trying both a dev-loop-ish relative
  // offset and a bundle-relative offset. Returns false (and prints an error)
  // if no candidate resolves to a real, existing darktable datadir.
  static bool compute_dt_dirs(std::string &datadir, std::string &moduledir);

protected:
  static void _bind_methods();

public:
  DtBackend();
  ~DtBackend();

  // display_width/display_height are the physical (device) pixel dimensions of
  // the screen the app is on, or 0,0 when unknown/headless. init() writes them
  // into darktable's mipmap cache as the DT_MIPMAP_F max dimensions (after
  // dt_init(), before any mip is requested), so the preview pipe's input mip is
  // generated at the display's resolution rather than darktable's fixed
  // 1440x900/1920x1200. 0,0 leaves darktable's fixed default untouched.
  bool init(int display_width = 0, int display_height = 0);
  bool load_image(String path);
  void set_exposure(float ev);
  void set_contrast(float value);
  void set_shadows(float value);
  void set_highlights(float value);
  // Blacks/Whites: Lightroom-style two-sided sliders driven via toneequal's
  // 1-EV-band gains (see the dt_iop_toneequalizer_params_t redeclaration
  // above). This replaced the earlier rgblevels wiring, whose 0..1-bounded
  // endpoints could only move one way, so Whites-up had nothing to push and
  // the slider read as broken. Both setters take -1..1 and write ±1 EV into
  // their band. Sign note: positive Blacks in Lightroom DEEPENS blacks, but a
  // positive toneequal gain LIFTS its band, so set_blacks writes -value.
  // Neutral (0) disables toneequal so it costs nothing in the pipe.
  void set_blacks(float value);
  void set_whites(float value);
  void set_saturation(float value);
  // The saturation axis's below-neutral half. `amount` is the desaturation
  // amount in 0..1: 0 disables monochrome entirely (full color, the neutral
  // point), 1 enables it at full opacity (full B&W), and values between enable
  // it with a uniform-blend opacity of amount*100% so the image fades
  // continuously between the two. Implemented on the "monochrome" module via
  // its blend parameters rather than any of its own fields -- see the note on
  // dt_iop_monochrome_params_t above.
  void set_desaturation(float amount);
  // Dehaze is NOT the darktable "hazeremoval" module: that module estimates a
  // per-channel ambient light A0 from the haziest pixels with no chroma
  // constraint, so on scenes whose haziest region is tinted (green window
  // blinds, warm sky) it multiplies each channel by a different 1/t and casts
  // the whole frame teal or pink. Nothing downstream of it can undo that
  // (casts from a per-pixel 1/t are spatial, not global). Instead set_dehaze
  // stores the slider value and _apply_dehaze() runs OUR dark-channel-prior
  // dehaze as a post-pipe stage on the rendered buffer. Hue-safe by
  // construction: A0 is forced achromatic (single scalar) and every pixel
  // gets out = (in - A)/t + A with the SAME scalar t per pixel applied to all
  // three channels, so channel RATIOS (hue) are preserved at every strength,
  // on any scene. value is -1..1 (0 = neutral, exact passthrough).
  void set_dehaze(float value);
  // Run the dehaze stage over an RGBA8 gamma-encoded buffer in place.
  // dehaze_value == 0 leaves the buffer untouched. Shared by render_pipe_roi
  // (preview/view) and export_image so exports match what the user sees.
  void _apply_dehaze(uint8_t *rgba8, int width, int height) const;
  // Dark-channel-prior estimate of the achromatic ambient light A (0..1) for
  // one RGBA8 buffer, and caching of it per image. Not exposed to GDScript.
  float _estimate_dehaze_ambient(const uint8_t *rgba8, int width, int height) const;
  // Slider value (-1..1, 0 = neutral) stored by set_dehaze and consumed by
  // _apply_dehaze at render time. Not a module param: no darktable module is
  // involved (see the set_dehaze comment).
  float dehaze_value = 0.0f;
  // Cached achromatic ambient A (linear luma 0..1), measured on the first
  // non-neutral dehaze render of the current pipe state; 0 = not yet
  // measured. Invalidated by note_pipe_change on any other module's edit,
  // and by export_image's full-res re-estimate. mutable because _apply_dehaze
  // is const and estimates it lazily.
  mutable float _dehaze_ambient = 0.0f;
  void set_vibrance(float value);
  // White balance via channelmixerrgb's chromatic adaptation -- see the NOTE
  // on white balance above dt_iop_channelmixer_rgb_params_t. Sets illuminant
  // = DT_ILLUMINANT_D, adaptation = DT_ADAPTATION_CAT16, and `temperature`
  // (clamped to DT_BACKEND_CHANNELMIXERRGB_TEMP_MIN/_MAX), leaving the
  // channel-mix matrix untouched. Enables the module and records a headless
  // history item, same pattern as every other setter here.
  void set_white_balance_temperature(float kelvin);
  // Read back channelmixerrgb's current `temperature` (as-shot right after
  // load_image(), pre-edit) so the UI can seed its White Balance slider from
  // the real per-image default instead of a hardcoded constant. Returns
  // 0.0f (and prints an error) if no image is loaded or the module can't be
  // found.
  float get_white_balance_temperature();
  // Drives the clipping module's crop box ("clipping", display name "crop &
  // rotate"). All four values are normalized 0..1 fractions of the whole
  // image; (left, top) is one corner, (right, bottom) the opposite corner.
  // Clamped to the module's own commit_params() ranges (left/top 0..0.9,
  // right/bottom 0.1..1.0). Passing the full frame (0, 0, 1, 1) DISABLES the
  // module instead of enabling it, so "no crop" costs nothing in the pipe.
  // Enables the module and records a headless history item, same pattern as
  // every other setter here. Rotation/keystone/aspect are never touched.
  void set_crop(float left, float top, float right, float bottom);
  // Drives the tonecurve module's L-channel spline (see dt_iop_tonecurve_params_t
  // above). `points` is a caller-sorted list of {x,y} control points in [0,1]x[0,1]
  // (the coordinate space darktable's own curve editor uses), first point x==0,
  // last point x==1, 2..DT_BACKEND_TONECURVE_MAXNODES points. Node ordering/
  // spacing/endpoint rules are enforced by the GDScript curve widget, not here.
  void set_tonecurve(PackedVector2Array points);
  PackedByteArray process_fit(int max_width, int max_height);
  // General ROI render, the same math darktable's own darkroom uses for
  // fit/100%/arbitrary zoom (source/src/develop/develop.c:874-890):
  //   scale = zoom_scale * ppd (ppd fixed at 1.0 here, no HiDPI yet)
  //   pipe_w/pipe_h = scale * native_w/native_h
  //   wd/ht = MIN(viewport, pipe_w/pipe_h)              (clip to viewport)
  //   x/y   = CLAMP(pipe_w*(.5+center_x) - wd/2, 0, pipe_w - wd)  (pan)
  // center_x/center_y are in [-0.5, 0.5], 0,0 = centered (matches darktable's
  // own zoom_x/zoom_y convention). process_fit() is now a thin wrapper around
  // this that picks scale = fit-scale and center = (0,0).
  PackedByteArray render_view(int viewport_w, int viewport_h, double scale,
                              double center_x, double center_y);
  // Fast interactive render through the separate preview pipe (see preview_pipe
  // above), same viewport/scale/center contract as render_view() EXCEPT that
  // `scale` is a fraction of the preview mip's dimensions (the mip is sized to
  // the display's physical pixels by init()), not of the image's native size.
  // `scale` is passed straight through as the pipe's roi_out scale, so it scales
  // the intermediate module work and cache lines, not just the final buffer.
  // There is no cap/clamp: the mip itself is the ceiling (scale 1.0 = the whole
  // display-resolution mip). The resulting buffer dims are reported via
  // get_width()/get_height(). Falls back to render_view() if the preview pipe
  // could not be created, so a caller can always use this for live edits.
  PackedByteArray render_preview(int viewport_w, int viewport_h, double scale,
                                 double center_x, double center_y);
  bool export_image(String path);
  int get_width();
  int get_height();
  // Native (scale=1.0) processed dimensions -- see native_width/native_height
  // above. Valid only after at least one process_fit()/render_view() call
  // (both call refresh_native_dimensions() first); returns 0,0 before that.
  int get_native_width();
  int get_native_height();
  // Raw file dimensions -- see raw_width/raw_height above. Valid immediately
  // after a successful load_image(); returns 0,0 before that.
  int get_raw_width();
  int get_raw_height();
  void cleanup();

  // Tears down the currently loaded image's pipe/dev/mipmap state (mirrors
  // cleanup()'s per-image branch) without touching `initialized`/
  // `cleaned_up`, so the backend can go on to load another image in the same
  // process. Called automatically by load_image() when an image is already
  // loaded, so GDScript's "Open" action always replaces rather than errors.
  // Safe to call when no image is loaded (no-op).
  void unload_image();
};

} // namespace godot
