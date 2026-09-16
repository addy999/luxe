/*
 * DtBackend -- GDExtension shim exposing darktable's headless pixelpipe to
 * GDScript for the Godot-on-darktable PoC.
 *
 * See godot-poc/DARKTABLE_API_NOTES.md for the exact darktable API signatures
 * this class calls, cited file:line against this checkout, and
 * ~/.claude/plans/linked-baking-cherny.md for the overall spike plan.
 *
 * This backend holds exactly one image/session at a time (darktable's core
 * state -- darktable.image_cache, darktable.mipmap_cache, etc. -- is a
 * single process-wide global, DARKTABLE_API_NOTES.md section I), matching
 * the plan's "one image/session at a time in-process" constraint.
 */
#pragma once

#include <string>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

// darktable headless core headers.
extern "C" {
#include "common/darktable.h"
#include "common/film.h"
#include "common/image.h"
#include "common/mipmap_cache.h"
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
// and types straight from DARKTABLE_API_NOTES.md section F, which cites
// source/src/iop/exposure.c:49-75, DT_MODULE_INTROSPECTION version 7).
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
typedef enum dt_gaussian_order_t
{
  DT_IOP_GAUSSIAN_ZERO = 0,
  DT_IOP_GAUSSIAN_ONE = 1,
  DT_IOP_GAUSSIAN_TWO = 2
} dt_gaussian_order_t;

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

// dt_iop_vibrance_params_t is likewise private to source/src/iop/vibrance.c,
// so it's redeclared here to match that file exactly (source/src/iop/
// vibrance.c:37-40, DT_MODULE_INTROSPECTION version 2). Single-field struct:
// `amount` ($MIN: 0.0 $MAX: 100.0 $DEFAULT: 25.0). If vibrance.c's struct or
// introspection version changes upstream, update this block.
typedef struct dt_iop_vibrance_params_t
{
  float amount;
} dt_iop_vibrance_params_t;

// dt_iop_temperature_params_t is likewise private to
// source/src/iop/temperature.c, so it's redeclared here to match that file
// exactly (source/src/iop/temperature.c:67-74, DT_MODULE_INTROSPECTION
// version 4). We drive `red` and `blue` ($MIN: 0.0 $MAX: 8.0 each), but the
// whole struct (including `green`, `various`, `preset`) must be reproduced
// verbatim -- field order/types are load-bearing. Unlike every other module
// here, this struct has NO $DEFAULT in the source: darktable computes the
// real default per-image from the camera's as-shot white-balance
// coefficients at load time (reload_defaults()), so `params` already holds
// the correct as-shot red/green/blue right after load_image() succeeds, same
// as every other module's untouched fields. get_white_balance_red()/_blue()
// read that back so the UI can seed its sliders from the real as-shot value
// instead of a hardcoded default. If temperature.c's struct or introspection
// version changes upstream, update this block.
typedef struct dt_iop_temperature_params_t
{
  float red;
  float green;
  float blue;
  float various;
  int preset;
} dt_iop_temperature_params_t;

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
  dt_dev_pixelpipe_t pipe;
  dt_mipmap_buffer_t mipmap_buf;

  // Cached module pointer for repeated set_exposure() calls (see
  // DARKTABLE_API_NOTES.md section F) so we don't re-search dev.iop.
  dt_iop_module_t *exposure_module = nullptr;
  dt_iop_module_t *colorbalance_module = nullptr;
  dt_iop_module_t *shadhi_module = nullptr;
  dt_iop_module_t *velvia_module = nullptr;
  dt_iop_module_t *vibrance_module = nullptr;
  dt_iop_module_t *temperature_module = nullptr;

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

  // Shared helper: re-syncs the pipe and refreshes native_width/native_height.
  // Called by both process_fit() and render_view() so there is exactly one
  // place that calls dt_dev_pixelpipe_get_dimensions().
  bool refresh_native_dimensions();

  // Computes darktable's --datadir/--moduledir at runtime instead of relying
  // on compile-time-baked absolute paths (see PORTABILITY_PLAN.md section 3).
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

  bool init();
  bool load_image(String path);
  void set_exposure(float ev);
  void set_contrast(float value);
  void set_shadows(float value);
  void set_highlights(float value);
  void set_saturation(float value);
  void set_vibrance(float value);
  void set_white_balance_red(float value);
  void set_white_balance_blue(float value);
  // Read back the temperature module's current (as-shot, pre-edit) red/blue
  // coefficients so the UI can seed its White Balance sliders from the real
  // per-image default instead of a hardcoded constant -- see the
  // dt_iop_temperature_params_t comment above. Returns 0.0f (and prints an
  // error) if no image is loaded or the module can't be found.
  float get_white_balance_red();
  float get_white_balance_blue();
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
