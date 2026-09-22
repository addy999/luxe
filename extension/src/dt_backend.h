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
 * Links against and drives darktable (https://github.com/darktable-org/darktable),
 * Copyright (C) the darktable contributors, licensed under the GNU General
 * Public License v3.0 or later. See NOTICE for full attribution. IOP params
 * are accessed via darktable's generated introspection API (get_p/get_f), not
 * by redeclaring private structs -- see the note below.
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

// --- darktable params access strategy --------------------------------------
// darktable IOP modules keep their params struct private to their own
// translation unit: exposure.c defines dt_iop_exposure_params_t locally, never
// in a header. The rest of darktable sees only an opaque `void *params` blob
// sized by `params_size`, with runtime introspection doing the rest
// (source/src/common/introspection.h). So rather than redeclare those structs
// here -- struct layout is load-bearing and drifts silently with every upstream
// field edit -- this backend drives modules through the generated per-module
// accessors: `module->get_p(params, "name")` returns the byte address of a field
// looked up BY NAME, and
// `dt_introspection_get_enum_value(module->get_f("name"), "ENUM_VALUE", &code)`
// resolves an enum's symbolic value to its integer code. A field rename/removal
// upstream surfaces as a NULL lookup (logged, and the setter bails) instead of a
// silently-shifted struct offset. See dt_iop_field()/dt_iop_set_enum() in
// dt_backend.cpp.
//
// The only constants still needed below are plain literals documented at their
// darktable source sites -- no private enum or struct is redeclared in this file.

// channelmixerrgb.c:82-83 -- clamp range for the White Balance Kelvin slider.
#define DT_BACKEND_CHANNELMIXERRGB_TEMP_MIN 1667.0f
#define DT_BACKEND_CHANNELMIXERRGB_TEMP_MAX 25000.0f

// tonecurve.c:48 -- max spline control points on the L-channel curve.
#define DT_BACKEND_TONECURVE_MAXNODES 20

// curve_tools.h:29 -- CUBIC_SPLINE 0, CATMULL_ROM 1, MONOTONE_HERMITE 2.
// tonecurve_type[] stores one of these as a plain int (no named enum type in
// the struct), so the interpolation kind is written as this literal rather than
// resolved from a nonexistent enum introspection.
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
  // toneequal ("tone equalizer") backs the Blacks/Whites sliders via its
  // 1-EV-band gains ("blacks"/"whites" fields) -- see set_blacks()/set_whites().
  dt_iop_module_t *toneequal_module = nullptr;
  dt_iop_module_t *velvia_module = nullptr;
  // monochrome backs the saturation slider's BELOW-neutral range only -- see
  // set_saturation() in dt_backend.cpp for how the two modules split the range.
  dt_iop_module_t *monochrome_module = nullptr;
  dt_iop_module_t *vibrance_module = nullptr;
  dt_iop_module_t *tonecurve_module = nullptr;
  // White balance now targets channelmixerrgb ("color calibration"), not
  // temperature -- see set_white_balance_temperature() below.
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
  // "blacks"/"whites" 1-EV-band gains. This replaced the earlier rgblevels
  // wiring, whose 0..1-bounded endpoints could only move one way, so Whites-up
  // had nothing to push and the slider read as broken. Both setters take -1..1
  // and write ±1 EV into their band. Sign note: positive Blacks in Lightroom
  // DEEPENS blacks, but a positive toneequal gain LIFTS its band, so
  // set_blacks writes -value. Neutral (0) disables toneequal so it costs
  // nothing in the pipe.
  void set_blacks(float value);
  void set_whites(float value);
  void set_saturation(float value);
  // The saturation axis's below-neutral half. `amount` is the desaturation
  // amount in 0..1: 0 disables monochrome entirely (full color, the neutral
  // point), 1 enables it at full opacity (full B&W), and values between enable
  // it with a uniform-blend opacity of amount*100% so the image fades
  // continuously between the two. Implemented on the "monochrome" module via
  // its blend parameters rather than any of its own fields (monochrome's own
  // params stay at their neutral INTROSPECTION defaults).
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
  // White balance via channelmixerrgb's chromatic adaptation -- see the white
  // balance NOTE in dt_backend.cpp. Sets illuminant = "DT_ILLUMINANT_D",
  // adaptation = "DT_ADAPTATION_CAT16", and `temperature` (clamped to
  // DT_BACKEND_CHANNELMIXERRGB_TEMP_MIN/_MAX), leaving the channel-mix matrix
  // untouched. Enables the module and records a headless history item, same
  // pattern as every other setter here.
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
  // Drives the tonecurve module's L-channel spline (see dt_backend.cpp's
  // set_tonecurve for the array layout). `points` is a caller-sorted list of {x,y} control points in [0,1]x[0,1]
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
