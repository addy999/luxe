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
#include "develop/blend.h"
#include "develop/develop.h"
#include "develop/imageop.h"
#include "develop/pixelpipe_hb.h"
#include "imageio/imageio_common.h"
#include "imageio/imageio_module.h"
}

#define DT_BACKEND_CHANNELMIXERRGB_TEMP_MIN 1667.0f
#define DT_BACKEND_CHANNELMIXERRGB_TEMP_MAX 25000.0f

#define DT_BACKEND_TONECURVE_MAXNODES 20

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
  // Full pipe (DT_MIPMAP_FULL input): render_view().
  dt_dev_pixelpipe_t pipe;
  dt_mipmap_buffer_t mipmap_buf;
  // Fast preview pipe, fed the display-sized DT_MIPMAP_F mip; shares `dev` with `pipe`.
  dt_dev_pixelpipe_t preview_pipe;
  // Backs the preview pipe's input; held open (locked) for its lifetime, like mipmap_buf.
  dt_mipmap_buffer_t preview_mipmap_buf;
  bool preview_pipe_ready = false;
  // Preview pipe's scale=1.0 dims (= the mip's dims).
  int preview_native_width = 0;
  int preview_native_height = 0;

  int display_width_ = 0;
  int display_height_ = 0;

  // Cached module pointers, filled on first use.
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

  // Raw sensor/file dims, captured at load_image().
  int raw_width = 0;
  int raw_height = 0;

  // --- Incremental change dispatch ------------------------------------------
  bool pipe_change_pending = false;
  bool pipe_change_multi = false;
  bool pipe_needs_full_synch = false;
  dt_iop_module_t *pipe_change_module = nullptr;

  void note_pipe_change(dt_iop_module_t *module);
  void dispatch_pipe_changes();
  bool refresh_native_dimensions();
  bool refresh_preview_dimensions();

  // The one ROI-process-read implementation shared by both render paths.
  PackedByteArray render_pipe_roi(dt_dev_pixelpipe_t *p, int native_w, int native_h,
                                  int viewport_w, int viewport_h, double scale,
                                  double center_x, double center_y);

  static bool compute_dt_dirs(std::string &datadir, std::string &moduledir);

protected:
  static void _bind_methods();

public:
  DtBackend();
  ~DtBackend();

  // Physical (device) pixel dims of the screen, 0,0 when unknown/headless.
  bool init(int display_width = 0, int display_height = 0);
  bool load_image(String path);
  void set_exposure(float ev);
  void set_contrast(float value);
  void set_shadows(float value);
  void set_highlights(float value);
  // Two-sided -1..1 sliders; 0 = neutral (module disabled). Sign conventions in
  // docs/DARKTABLE_API_NOTES.md F.3.
  void set_blacks(float value);
  void set_whites(float value);
  void set_saturation(float value);
  // Saturation's below-neutral half: amount 0..1 (0 = neutral, 1 = full B&W).
  void set_desaturation(float amount);
  // -1..1 slider value, 0 = neutral; our own post-pipe stage (docs F.8), not
  // darktable's "hazeremoval" module.
  void set_dehaze(float value);
  // Dehaze stage over an RGBA8 gamma-encoded buffer, in place; no-op at 0.
  void _apply_dehaze(uint8_t *rgba8, int width, int height) const;
  // Dark-channel-prior estimate of the achromatic ambient A (0..1).
  float _estimate_dehaze_ambient(const uint8_t *rgba8, int width, int height) const;
  // Slider value (-1..1, 0 = neutral); not a darktable module param.
  float dehaze_value = 0.0f;
  // Cached ambient A (linear luma 0..1); 0 = not yet measured. Mutable: _apply_dehaze is const.
  mutable float _dehaze_ambient = 0.0f;
  void set_vibrance(float value);
  // Kelvin, clamped to _TEMP_MIN/_MAX (docs F.4).
  void set_white_balance_temperature(float kelvin);
  // As-shot Kelvin for seeding the UI slider; 0.0f if no image/module.
  float get_white_balance_temperature();
  // Normalized 0..1 crop EDGES (left, top, right, bottom); full frame disables the module.
  void set_crop(float left, float top, float right, float bottom);
  // L-channel spline points in [0,1]x[0,1], caller-sorted, 2..MAXNODES.
  void set_tonecurve(PackedVector2Array points);
  PackedByteArray process_fit(int max_width, int max_height);
  // ROI render on the full pipe; center_x/center_y in [-0.5, 0.5], 0,0 = centered.
  PackedByteArray render_view(int viewport_w, int viewport_h, double scale,
                              double center_x, double center_y);
  // Same contract as render_view() on the preview pipe, except `scale` is a
  // fraction of the preview mip's dims; falls back to render_view().
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

  // Per-image teardown that leaves `initialized`/`cleaned_up` intact, so another
  // image can load in-process; no-op when idle.
  void unload_image();
};

} // namespace godot
