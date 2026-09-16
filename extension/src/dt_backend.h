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
