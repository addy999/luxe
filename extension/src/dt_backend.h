/*
 * DtBackend: GDExtension shim exposing darktable's headless pixelpipe to
 * GDScript. One image/session at a time (darktable's core state is
 * process-wide global). See godot-poc/README.md and docs/DARKTABLE_API_NOTES.md.
 * Links against darktable (https://github.com/darktable-org/darktable),
 * Copyright (C) the darktable contributors, GPLv3 or later. See NOTICE.
 */
#pragma once

#include <string>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>

extern "C" {
#include "common/darktable.h"
#include "common/film.h"
#include "common/image.h"
#include "common/mipmap_cache.h"
// blend params; also included by pixelpipe_hb.c in the nogui build, so safe headless
#include "develop/blend.h"
#include "develop/develop.h"
#include "develop/imageop.h"
#include "develop/pixelpipe_hb.h"
#include "imageio/imageio_common.h"
#include "imageio/imageio_module.h"
}

// IOP params structs are private to each module's .c file; never redeclare
// them (layout is load-bearing, drifts silently). Drive fields by NAME via the
// generated introspection accessors (dt_iop_field()/dt_iop_set_enum() in
// dt_backend.cpp), so a renamed/removed field surfaces as a NULL lookup
// instead of a shifted struct offset.

// channelmixerrgb.c:82-83: clamp range for the White Balance Kelvin slider.
#define DT_BACKEND_CHANNELMIXERRGB_TEMP_MIN 1667.0f
#define DT_BACKEND_CHANNELMIXERRGB_TEMP_MAX 25000.0f

// tonecurve.c:48: max spline control points on the L-channel curve.
#define DT_BACKEND_TONECURVE_MAXNODES 20

// curve_tools.h:29: CUBIC_SPLINE 0, CATMULL_ROM 1, MONOTONE_HERMITE 2;
// stored as a plain int in tonecurve_type[] (no named enum in the struct).
#define DT_BACKEND_MONOTONE_HERMITE 2


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
  // Full pipe (DT_DEV_PIXELPIPE_FULL, fed DT_MIPMAP_FULL): render_view().
  dt_dev_pixelpipe_t pipe;
  dt_mipmap_buffer_t mipmap_buf;
  // Fast preview pipe, fed the downscaled DT_MIPMAP_F mip, regenerated at the
  // display's pixel resolution by init() (see set_preview_mip_size()). Both
  // pipes share `dev`; each has its own node list/cache.
  dt_dev_pixelpipe_t preview_pipe;
  // Backs the preview pipe's input; held open (locked) for its lifetime, like mipmap_buf.
  dt_mipmap_buffer_t preview_mipmap_buf;
  bool preview_pipe_ready = false;
  // Preview pipe's scale=1.0 dims = the mip's dims (display-sized), authoritative for preview ROI.
  int preview_native_width = 0;
  int preview_native_height = 0;

  // Physical display size passed to init() to size the DT_MIPMAP_F mip; 0,0 keeps the default.
  int display_width_ = 0;
  int display_height_ = 0;

  // Cached module pointers so repeated setter calls don't re-search dev.iop.
  dt_iop_module_t *exposure_module = nullptr;
  dt_iop_module_t *colorbalance_module = nullptr;
  dt_iop_module_t *shadhi_module = nullptr;
  dt_iop_module_t *toneequal_module = nullptr;
  dt_iop_module_t *velvia_module = nullptr;
  dt_iop_module_t *monochrome_module = nullptr;
  dt_iop_module_t *vibrance_module = nullptr;
  dt_iop_module_t *tonecurve_module = nullptr;
  dt_iop_module_t *channelmixer_rgb_module = nullptr;
  dt_iop_module_t *clipping_module = nullptr;

  int processed_width = 0;
  int processed_height = 0;

  // Native (scale=1.0) processed dims; GDScript's zoom math decides ROI/panning from these.
  int native_width = 0;
  int native_height = 0;

  // Raw sensor/file dimensions, captured at load_image() time (no render needed), so
  // GDScript can pick a default edit scale before the first render.
  int raw_width = 0;
  int raw_height = 0;

  // --- Incremental change dispatch ------------------------------------------
  // Setters end with dt_dev_add_history_item_ext(..., no_image=TRUE): the
  // !no_image branch ORs DT_DEV_PIPE_*_CHANGED onto dev->full.pipe/
  // preview_pipe, which are NULL headless, so dropping it would crash. This
  // bridge therefore tracks pipe changes itself: one changed module maps onto
  // TOP_CHANGED/synch_top(); two or more fall back to synch_all().
  bool pipe_change_pending = false;
  bool pipe_change_multi = false;
  bool pipe_needs_full_synch = false;
  dt_iop_module_t *pipe_change_module = nullptr;

  // Records `module` as changed; full-replay fallback if enabling flips a still-disabled piece.
  void note_pipe_change(dt_iop_module_t *module);

  // Applies any pending change (synch_top for one module, synch_all otherwise)
  // to BOTH pipes: sync only one and the other serves stale pixels.
  void dispatch_pipe_changes();

  // Dispatches pending changes then refreshes the pipe's scale=1.0 dims.
  bool refresh_native_dimensions();
  bool refresh_preview_dimensions();

  // The one ROI-process-read implementation shared by render_view() and
  // render_preview() so the paths cannot drift (develop.c:874-890 math).
  PackedByteArray render_pipe_roi(dt_dev_pixelpipe_t *p, int native_w, int native_h,
                                  int viewport_w, int viewport_h, double scale,
                                  double center_x, double center_y);

  // Computes --datadir/--moduledir at runtime (baked-in absolute paths broke
  // when the binary moved): env vars, then Godot's executable path, then
  // dladdr() on this extension's own library. Returns false if none resolves.
  static bool compute_dt_dirs(std::string &datadir, std::string &moduledir);

protected:
  static void _bind_methods();

public:
  DtBackend();
  ~DtBackend();

  // Physical (device) pixel dims of the screen, or 0,0 when unknown/headless.
  // init() writes them into the mipmap cache as the DT_MIPMAP_F max dims
  // (see set_preview_mip_size() in dt_backend.cpp).
  bool init(int display_width = 0, int display_height = 0);
  bool load_image(String path);
  void set_exposure(float ev);
  void set_contrast(float value);
  void set_shadows(float value);
  void set_highlights(float value);
  // Blacks/Whites: two-sided -1..1 sliders driven via toneequal's
  // "blacks"/"whites" 1-EV-band gains; positive Blacks writes -value
  // (a positive toneequal gain LIFTS its band, Lightroom's DEEPENS).
  void set_blacks(float value);
  void set_whites(float value);
  void set_saturation(float value);
  // The saturation axis's below-neutral half. amount in 0..1: 0 disables
  // monochrome entirely (neutral), 1 = full B&W, between = uniform-blend opacity.
  void set_desaturation(float amount);
  // Dehaze is NOT the darktable "hazeremoval" module (its per-channel ambient
  // casts tinted scenes; see DARKTABLE_API_NOTES.md F.8). Stores the slider
  // value (-1..1, 0 = neutral; positive removes haze, negative adds it) and
  // _apply_dehaze() runs our hue-safe dark-channel post-pipe stage.
  void set_dehaze(float value);
  // Run the dehaze stage over an RGBA8 gamma-encoded buffer in place; no-op at
  // 0. Shared by render_pipe_roi and export_image so exports match the screen.
  void _apply_dehaze(uint8_t *rgba8, int width, int height) const;
  // Dark-channel-prior estimate of the achromatic ambient A (0..1), cached per image.
  float _estimate_dehaze_ambient(const uint8_t *rgba8, int width, int height) const;
  // Slider value (-1..1, 0 = neutral); not a module param, no darktable module involved.
  float dehaze_value = 0.0f;
  // Cached achromatic ambient A (linear luma 0..1); 0 = not yet measured.
  // Invalidated by note_pipe_change and export_image's full-res re-estimate;
  // mutable because _apply_dehaze is const and estimates it lazily.
  mutable float _dehaze_ambient = 0.0f;
  void set_vibrance(float value);
  // White balance via channelmixerrgb's chromatic adaptation (not the
  // temperature module, scene-referred workflow); see set_white_balance_temperature
  // in dt_backend.cpp. Clamped to DT_BACKEND_CHANNELMIXERRGB_TEMP_MIN/_MAX.
  void set_white_balance_temperature(float kelvin);
  // Read back channelmixerrgb's as-shot `temperature` (pre-edit) so the UI can
  // seed its White Balance slider. Returns 0.0f (and errors) if no image is
  // loaded or the module is missing.
  float get_white_balance_temperature();
  // Drives the clipping module's crop box. All four values are normalized 0..1
  // fractions of the whole image; (left, top) one corner, (right, bottom) the
  // opposite. Clamped to the module's own commit_params() ranges. Full frame
  // (0,0,1,1) DISABLES the module.
  void set_crop(float left, float top, float right, float bottom);
  // Drives the tonecurve module's L-channel spline. `points` is a caller-sorted
  // list of {x,y} control points in [0,1]x[0,1], first x==0, last x==1, 2..
  // DT_BACKEND_TONECURVE_MAXNODES points; ordering is the GDScript widget's job.
  void set_tonecurve(PackedVector2Array points);
  PackedByteArray process_fit(int max_width, int max_height);
  // General ROI render, the same math darktable's own darkroom uses for
  // fit/100%/arbitrary zoom (develop.c:874-890); see render_pipe_roi().
  // center_x/center_y are in [-0.5, 0.5], 0,0 = centered.
  PackedByteArray render_view(int viewport_w, int viewport_h, double scale,
                              double center_x, double center_y);
  // Fast interactive render through the preview pipe, same contract as
  // render_view() EXCEPT that `scale` is a fraction of the preview mip's
  // dimensions (display-sized by init()), not of the image's native size;
  // passed straight through as the pipe's roi_out scale, so it scales
  // intermediate work too. No cap: the mip is the ceiling. Falls back to
  // render_view() if unavailable.
  PackedByteArray render_preview(int viewport_w, int viewport_h, double scale,
                                 double center_x, double center_y);
  bool export_image(String path);
  int get_width();
  int get_height();
  // Native (scale=1.0) processed dims; 0,0 until the first render.
  int get_native_width();
  int get_native_height();
  // Raw file dims; valid immediately after a successful load_image().
  int get_raw_width();
  int get_raw_height();
  void cleanup();

  // Tears down the current image's pipe/dev/mipmap state (mirrors cleanup()'s
  // per-image branch) without touching `initialized`/`cleaned_up`, so the
  // backend can load another image in the same process; no-op when idle.
  void unload_image();
};

} // namespace godot
