/*
 * DtBackend implementation. Architecture: the "two languages, one process"
 * section of godot-poc/README.md. Links against and calls into darktable
 * (https://github.com/darktable-org/darktable), Copyright (C) the darktable
 * contributors, licensed under the GNU General Public License v3.0 or later.
 * See NOTICE for full attribution.
 */

#include "dt_backend.h"

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

extern "C" {
#include "common/dtpthread.h"
#include "common/introspection.h" // dt_introspection_field_t + dt_introspection_get_enum_value()
}

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>

#include <dlfcn.h>

using namespace godot;

// sRGB <-> linear lookup tables for the dehaze post-stage (_apply_dehaze).
// Decode exact per 8-bit value; encode is a 4096-entry table, within 8-bit error.
namespace dt_dehaze_lut {
static float _dt_srgb_to_linear[256];
static uint8_t _dt_linear_to_srgb[4096];
static const bool _init = []() {
  for(int v = 0; v < 256; v++) {
    const float c = v / 255.0f;
    _dt_srgb_to_linear[v] = (c <= 0.04045f) ? c / 12.92f
                                            : powf((c + 0.055f) / 1.055f, 2.4f);
  }
  for(int i = 0; i < 4096; i++) {
    const float l = i / 4095.0f;
    const float s = (l <= 0.0031308f) ? l * 12.92f
                                      : 1.055f * powf(l, 1.0f / 2.4f) - 0.055f;
    int v = (int)std::lrint(s * 255.0f);
    _dt_linear_to_srgb[i] = (uint8_t)std::clamp(v, 0, 255);
  }
  return true;
}();
} // namespace dt_dehaze_lut
using namespace dt_dehaze_lut;

void DtBackend::_bind_methods() {
  ClassDB::bind_method(D_METHOD("init", "display_width", "display_height"), &DtBackend::init,
                       DEFVAL(0), DEFVAL(0));
  ClassDB::bind_method(D_METHOD("load_image", "path"), &DtBackend::load_image);
  ClassDB::bind_method(D_METHOD("set_exposure", "ev"), &DtBackend::set_exposure);
  ClassDB::bind_method(D_METHOD("set_contrast", "value"), &DtBackend::set_contrast);
  ClassDB::bind_method(D_METHOD("set_shadows", "value"), &DtBackend::set_shadows);
  ClassDB::bind_method(D_METHOD("set_highlights", "value"), &DtBackend::set_highlights);
  ClassDB::bind_method(D_METHOD("set_blacks", "value"), &DtBackend::set_blacks);
  ClassDB::bind_method(D_METHOD("set_whites", "value"), &DtBackend::set_whites);
  ClassDB::bind_method(D_METHOD("set_saturation", "value"), &DtBackend::set_saturation);
  ClassDB::bind_method(D_METHOD("set_desaturation", "amount"), &DtBackend::set_desaturation);
  ClassDB::bind_method(D_METHOD("set_dehaze", "value"), &DtBackend::set_dehaze);
  ClassDB::bind_method(D_METHOD("set_vibrance", "value"), &DtBackend::set_vibrance);
  ClassDB::bind_method(D_METHOD("set_tonecurve", "points"), &DtBackend::set_tonecurve);
  ClassDB::bind_method(D_METHOD("set_crop", "left", "top", "right", "bottom"), &DtBackend::set_crop);
  ClassDB::bind_method(D_METHOD("set_white_balance_temperature", "kelvin"), &DtBackend::set_white_balance_temperature);
  ClassDB::bind_method(D_METHOD("get_white_balance_temperature"), &DtBackend::get_white_balance_temperature);
  ClassDB::bind_method(D_METHOD("process_fit", "max_width", "max_height"), &DtBackend::process_fit);
  ClassDB::bind_method(D_METHOD("render_view", "viewport_w", "viewport_h", "scale", "center_x", "center_y"), &DtBackend::render_view);
  ClassDB::bind_method(D_METHOD("render_preview", "viewport_w", "viewport_h", "scale", "center_x", "center_y"), &DtBackend::render_preview);
  ClassDB::bind_method(D_METHOD("export_image", "path"), &DtBackend::export_image);
  ClassDB::bind_method(D_METHOD("get_width"), &DtBackend::get_width);
  ClassDB::bind_method(D_METHOD("get_height"), &DtBackend::get_height);
  ClassDB::bind_method(D_METHOD("get_native_width"), &DtBackend::get_native_width);
  ClassDB::bind_method(D_METHOD("get_native_height"), &DtBackend::get_native_height);
  ClassDB::bind_method(D_METHOD("get_raw_width"), &DtBackend::get_raw_width);
  ClassDB::bind_method(D_METHOD("get_raw_height"), &DtBackend::get_raw_height);
  ClassDB::bind_method(D_METHOD("cleanup"), &DtBackend::cleanup);
  ClassDB::bind_method(D_METHOD("unload_image"), &DtBackend::unload_image);
}

namespace {

// dladdr() target: an address inside libdt_backend's own image, not a member fn pointer.
void dt_backend_dladdr_anchor() {}

bool path_exists(const std::string &path) {
  return g_file_test(path.c_str(), G_FILE_TEST_EXISTS) == TRUE;
}

// A candidate datadir must really hold darktable data. Sentinel is
// rawspeed/cameras.xml: the bundler copies it and dt_rawspeed_load_meta() needs it
// (darktable.png was a stale sentinel that never matched; see PORTABILITY_PLAN.md).
bool datadir_looks_valid(const std::string &datadir) {
  gchar *sentinel = g_build_filename(datadir.c_str(), "rawspeed", "cameras.xml", NULL);
  const bool ok = path_exists(sentinel);
  g_free(sentinel);
  return ok;
}

// --- introspection field access ---------------------------------------------
// DT_MODULE_INTROSPECTION() gives every IOP module get_p(params, "name") (byte
// address of a named field inside the opaque params blob) and get_f("name")
// (its runtime descriptor: type, size, offset, enum value table). A name typo
// surfaces as a NULL return (setter bails), never a shifted struct offset.

// Live-params field address by name (for writes); NULL (logged) if missing.
void *dt_iop_field(dt_iop_module_t *m, const char *name)
{
  if(!m || !m->get_p) return nullptr;
  void *p = m->get_p(m->params, name);
  if(!p)
    UtilityFunctions::printerr("DtBackend: module has no params field \"", name, "\"");
  return p;
}

// Same, but on default_params (as-shot values resolved at load, see get_white_balance_temperature).
const void *dt_iop_field_default(dt_iop_module_t *m, const char *name)
{
  if(!m || !m->get_p) return nullptr;
  const void *p = m->get_p(m->default_params, name);
  if(!p)
    UtilityFunctions::printerr("DtBackend: module has no params field \"", name, "\"");
  return p;
}

// Returns false (logging) if the field is unknown.
bool dt_iop_set_float(dt_iop_module_t *m, const char *name, float value)
{
  float *p = (float *)dt_iop_field(m, name);
  if(!p) return false;
  *p = value;
  return true;
}

// Returns false (logging) if the field is unknown.
bool dt_iop_set_int(dt_iop_module_t *m, const char *name, int value)
{
  int *p = (int *)dt_iop_field(m, name);
  if(!p) return false;
  *p = value;
  return true;
}

// Write an enum field by resolving its symbolic C name (e.g. "DT_ILLUMINANT_D")
// via the generated introspection (enum fields are int-sized in all modules here).
// Returns false (logging) if the field or the named value is unknown.
bool dt_iop_set_enum(dt_iop_module_t *m, const char *name, const char *value_name)
{
  if(!m || !m->get_f) return false;
  dt_introspection_field_t *f = m->get_f(name);
  int code = 0;
  if(!f || !dt_introspection_get_enum_value(f, value_name, &code))
  {
    UtilityFunctions::printerr("DtBackend: enum field \"", name,
                               "\" has no value \"", value_name, "\"");
    return false;
  }
  int *p = (int *)dt_iop_field(m, name);
  if(!p) return false;
  *p = code;
  return true;
}

// Pin toneequal's mask machinery to the "simple tone curve" preset
// (toneequal.c:480-491): details = DT_TONEEQ_NONE (no guided filter, just a
// global tone curve), method = DT_TONEEQ_NORM_2, iterations = 1, so the blob
// starts in a known state. Returns false (logging) if any field is missing.
bool toneequal_pin_preset(dt_iop_module_t *m)
{
  return dt_iop_set_enum(m, "details", "DT_TONEEQ_NONE")
      && dt_iop_set_enum(m, "method", "DT_TONEEQ_NORM_2")
      && dt_iop_set_int(m, "iterations", 1)
      && dt_iop_set_float(m, "blending", 5.0f)
      && dt_iop_set_float(m, "smoothing", 1.414213562f)
      && dt_iop_set_float(m, "feathering", 1.0f)
      && dt_iop_set_float(m, "quantization", 0.0f)
      && dt_iop_set_float(m, "contrast_boost", 0.0f)
      && dt_iop_set_float(m, "exposure_boost", 0.0f);
}

} // namespace

// Display-sized preview mip. darktable fixes DT_MIPMAP_F at cache-init time
// (1440x900/1920x1200, inside dt_init(), too late for --conf), so we write the
// cache's public size fields directly after dt_init() and before any DT_MIPMAP_F
// get. Full mechanics (header derivation, no disk cache, half-display cap):
// docs/PERF-IMPROVEMENT.md "Preview mip size".
static void set_preview_mip_size(const int width, const int height) {
  if(!darktable.mipmap_cache || width <= 0 || height <= 0) return;

  const int mip_width = width / 2;
  const int mip_height = height / 2;
  if(mip_width <= 0 || mip_height <= 0) return;

  dt_mipmap_cache_t *cache = darktable.mipmap_cache;
  const size_t old_pixels = (size_t)cache->max_width[DT_MIPMAP_F]
                                * (size_t)cache->max_height[DT_MIPMAP_F];
  const size_t payload = 4 * sizeof(float) * (size_t)mip_width * (size_t)mip_height;

  // Header = buffer_size minus its payload; fall back to a safe fixed pad if buffer_size looks bogus.
  size_t header = sizeof(size_t) * 4; // 32 bytes: a safe lower bound
  if(cache->buffer_size[DT_MIPMAP_F] > 4 * sizeof(float) * old_pixels)
    header = cache->buffer_size[DT_MIPMAP_F] - 4 * sizeof(float) * old_pixels;

  cache->max_width[DT_MIPMAP_F] = (uint32_t)mip_width;
  cache->max_height[DT_MIPMAP_F] = (uint32_t)mip_height;
  cache->buffer_size[DT_MIPMAP_F] = header + payload;

  UtilityFunctions::print("DtBackend::set_preview_mip_size: DT_MIPMAP_F mip set to ",
                          mip_width, "x", mip_height, " (", (int64_t)((header + payload) >> 20),
                          " MB buffer)");
}

// Computes --datadir/--moduledir at runtime, in order: (1) DT_BACKEND_DATADIR/
// DT_BACKEND_MODULEDIR env vars (dev convenience), (2) bundle-relative via Godot's
// executable path, (3) dladdr() on this extension's own loaded image, (4) fail
// init() outright rather than hand dt_init() a bogus path.
bool DtBackend::compute_dt_dirs(std::string &datadir, std::string &moduledir) {
  // --- 1. env var override (dev convenience) --------------------------
  // Same sentinel check as the bundle candidates: this branch used to accept a wrong-but-existing path.
  const char *env_datadir = std::getenv("DT_BACKEND_DATADIR");
  const char *env_moduledir = std::getenv("DT_BACKEND_MODULEDIR");
  if(env_datadir && env_moduledir && env_datadir[0] != '\0' && env_moduledir[0] != '\0') {
    if(datadir_looks_valid(env_datadir)) {
      datadir = env_datadir;
      moduledir = env_moduledir;
      UtilityFunctions::print("DtBackend::compute_dt_dirs: using DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR override");
      return true;
    }
    UtilityFunctions::printerr(
        "DtBackend::compute_dt_dirs: DT_BACKEND_DATADIR/DT_BACKEND_MODULEDIR set but '",
        env_datadir, "' does not look like a valid datadir (no darktable.png found) -- ignoring override and falling through to bundle-relative detection");
  }

  // --- 2. bundle-relative via Godot's own executable path -------------
  {
    const godot::String exe_path = godot::OS::get_singleton()->get_executable_path();
    // .../MyApp.app/Contents/MacOS/MyApp -> get_base_dir() twice -> .../Contents
    const godot::String contents_dir = exe_path.get_base_dir().get_base_dir();
    const std::string resource_dir = std::string(contents_dir.utf8().get_data()) + "/Resources/darktable";
    const std::string candidate_datadir = resource_dir + "/share/darktable";
    const std::string candidate_moduledir = resource_dir + "/lib/darktable";
    if(datadir_looks_valid(candidate_datadir)) {
      datadir = candidate_datadir;
      moduledir = candidate_moduledir;
      UtilityFunctions::print("DtBackend::compute_dt_dirs: using bundle-relative dirs from Godot executable path");
      return true;
    }
  }

  // --- 3. dladdr() on this extension's own loaded image ----------------
  {
    Dl_info info;
    if(dladdr(reinterpret_cast<void *>(&dt_backend_dladdr_anchor), &info) != 0 && info.dli_fname) {
      // info.dli_fname e.g. .../Contents/Frameworks/libdt_backend.*.framework/libdt_backend.*
      gchar *lib_dir = g_path_get_dirname(info.dli_fname);       // .../Frameworks/libdt_backend.*.framework
      gchar *frameworks_dir = g_path_get_dirname(lib_dir);       // .../Frameworks
      gchar *contents_dir = g_path_get_dirname(frameworks_dir);  // .../Contents

      gchar *resource_dir = g_build_filename(contents_dir, "Resources", "darktable", NULL);
      gchar *candidate_datadir = g_build_filename(resource_dir, "share", "darktable", NULL);
      gchar *candidate_moduledir = g_build_filename(resource_dir, "lib", "darktable", NULL);

      const bool ok = datadir_looks_valid(candidate_datadir);
      if(ok) {
        datadir = candidate_datadir;
        moduledir = candidate_moduledir;
      }

      g_free(lib_dir);
      g_free(frameworks_dir);
      g_free(contents_dir);
      g_free(resource_dir);
      g_free(candidate_datadir);
      g_free(candidate_moduledir);

      if(ok) {
        UtilityFunctions::print("DtBackend::compute_dt_dirs: using bundle-relative dirs from extension's own dladdr() path");
        return true;
      }
    }
  }

  // --- 4. nothing resolved ----------------------------------------------
  UtilityFunctions::printerr(
      "DtBackend::compute_dt_dirs: could not locate darktable's datadir/moduledir. "
      "Set DT_BACKEND_DATADIR and DT_BACKEND_MODULEDIR env vars (e.g. to "
      "source/build/share/darktable and source/build/lib/darktable) for local dev, "
      "or run from an exported .app bundle with Contents/Resources/darktable/{share,lib}/darktable populated.");
  return false;
}

DtBackend::DtBackend() {
  std::memset(&dev, 0, sizeof(dev));
  std::memset(&pipe, 0, sizeof(pipe));
  std::memset(&mipmap_buf, 0, sizeof(mipmap_buf));
  std::memset(&preview_pipe, 0, sizeof(preview_pipe));
  std::memset(&preview_mipmap_buf, 0, sizeof(preview_mipmap_buf));
}

DtBackend::~DtBackend() {
  cleanup();
}

// Mirror darktable-cli's synthetic argv (--library :memory:,
// --conf write_sidecar_files=never, main.c:482-492) so we never touch the
// user's real config/db, instead of forwarding Godot's argv.
bool DtBackend::init(int display_width, int display_height) {
  if(initialized) {
    UtilityFunctions::print("DtBackend::init: already initialized");
    return true;
  }

  // --datadir/--moduledir are required: darktable resolves them relative to its
  // own executable, but here that is Godot's, which lands on nonsense paths.
  //
  // --configdir/--cachedir: the ~/.config/darktable default holds a SQLite lock
  // only one instance can hold (a Godot editor Play session would block us), so
  // use a private sandbox (still not safe for two concurrent instances of ours).
  gchar *configdir = g_build_filename(g_get_user_cache_dir(), "godot-darktable-poc", "config", NULL);
  gchar *cachedir = g_build_filename(g_get_user_cache_dir(), "godot-darktable-poc", "cache", NULL);
  g_mkdir_with_parents(configdir, 0700);
  g_mkdir_with_parents(cachedir, 0700);

  std::string datadir_str;
  std::string moduledir_str;
  if(!compute_dt_dirs(datadir_str, moduledir_str)) {
    g_free(configdir);
    g_free(cachedir);
    return false;
  }
  // dt_init() needs mutable char* argv entries; the gchar* pointers are exactly that.
  gchar *datadir = g_strdup(datadir_str.c_str());
  gchar *moduledir = g_strdup(moduledir_str.c_str());

  char arg0[] = "dt_backend";
  char arg1[] = "--library";
  char arg2[] = ":memory:";
  char arg3[] = "--conf";
  char arg4[] = "write_sidecar_files=never";
  char arg5[] = "--datadir";
  char arg7[] = "--moduledir";
  char arg9[] = "--configdir";
  char arg11[] = "--cachedir";

  display_width_ = display_width;
  display_height_ = display_height;

  // The gchar* pointers must stay alive until after dt_init() returns: it reads argv synchronously.
  std::vector<char *> argv_vec = { arg0, arg1, arg2, arg3, arg4, arg5, datadir, arg7, moduledir,
                                   arg9, configdir, arg11, cachedir };
  argv_vec.push_back(nullptr);
  int argc = (int)argv_vec.size() - 1;

  // init_gui = FALSE (headless), load_data = TRUE (matches darktable-cli), no Lua.
  const int rc = dt_init(argc, argv_vec.data(), FALSE, TRUE, NULL);
  g_free(configdir);
  g_free(cachedir);
  g_free(datadir);
  g_free(moduledir);
  if(rc != 0) {
    UtilityFunctions::printerr("DtBackend::init: dt_init() failed, rc=", rc);
    return false;
  }

  // --library :memory: means edits must be read back from that DB, not XMP
  // sidecars; without this the export's fresh dev would drop every edit
  // (see DARKTABLE_API_NOTES.md, section D).
  darktable.prefer_library_history = TRUE;

  // Size the DT_MIPMAP_F preview mip to half the display: after dt_init(), before
  // any mip is requested. 0,0 (headless) keeps darktable's fixed default.
  if(display_width > 0 && display_height > 0) {
    set_preview_mip_size(display_width, display_height);
  } else {
    UtilityFunctions::print("DtBackend::init: no display size given; "
                            "DT_MIPMAP_F preview mip keeps darktable's default (1440x900 / 1920x1200)");
  }

  initialized = true;
  return true;
}

// Import the file, load it into a dt_develop_t, stand up a persistent pixelpipe once so setter/render calls are cheap.
bool DtBackend::load_image(String path) {
  if(!initialized) {
    UtilityFunctions::printerr("DtBackend::load_image: init() was not called");
    return false;
  }
  // Replace rather than reject: opening a second image just swaps the session.
  if(image_loaded) {
    unload_image();
  }

  const CharString path_utf8 = path.utf8();
  const char *cpath = path_utf8.get_data();

  // dt_film_init() before dt_film_new() or the uninitialized images_mutex
  // SIGKILLs on macOS (main.c's inline pattern skips it; DARKTABLE_API_NOTES.md B).
  dt_film_t film;
  dt_film_init(&film);

  gchar *directory = g_path_get_dirname(cpath);
  const dt_filmid_t filmid = dt_film_new(&film, directory);
  g_free(directory);

  if(!dt_is_valid_filmid(filmid)) {
    UtilityFunctions::printerr("DtBackend::load_image: dt_film_new() failed for path: ", path);
    dt_film_cleanup(&film);
    return false;
  }

  const dt_imgid_t new_imgid = dt_image_import(filmid, cpath, TRUE, FALSE);
  dt_film_cleanup(&film);

  if(!dt_is_valid_imgid(new_imgid)) {
    UtilityFunctions::printerr("DtBackend::load_image: dt_image_import() failed for path: ", path);
    return false;
  }
  imgid = new_imgid;

  dt_dev_init(&dev, FALSE);
  dt_dev_load_image(&dev, imgid);

  // Full-res input buffer, kept alive as member state until cleanup(): it backs the pipe's input.
  dt_mipmap_cache_get(&mipmap_buf, imgid, DT_MIPMAP_FULL, DT_MIPMAP_BLOCKING, 'r');
  if(!mipmap_buf.buf || !mipmap_buf.width || !mipmap_buf.height) {
    UtilityFunctions::printerr("DtBackend::load_image: dt_mipmap_cache_get() returned an invalid buffer");
    dt_mipmap_cache_release(&mipmap_buf);
    std::memset(&mipmap_buf, 0, sizeof(mipmap_buf));
    dt_dev_cleanup(&dev);
    imgid = NO_IMGID;
    return false;
  }

  const dt_image_t *img = &dev.image_storage;
  const int wd = img->width;
  const int ht = img->height;
  raw_width = wd;
  raw_height = ht;

  // dt_dev_pixelpipe_init_full() does NOT exist: only _init/_init_preview/_init_preview2/_init_export/_init_thumbnail/_init_dummy.
  if(!dt_dev_pixelpipe_init(&pipe)) {
    UtilityFunctions::printerr("DtBackend::load_image: dt_dev_pixelpipe_init() failed");
    dt_mipmap_cache_release(&mipmap_buf);
    std::memset(&mipmap_buf, 0, sizeof(mipmap_buf));
    dt_dev_cleanup(&dev);
    imgid = NO_IMGID;
    return false;
  }

  // Input, output colorspace, node list, params/history commit.
  // DT_COLORSPACE_DISPLAY with a NULL profile = "convert to the user's display
  // profile"; DT_INTENT_LAST is a sentinel ("no explicit override"), not a real
  // ICC intent: colorout.c leaves the rendering intent at the module's own default.
  dt_dev_pixelpipe_set_input(&pipe, &dev, (float *)mipmap_buf.buf,
                              mipmap_buf.width, mipmap_buf.height, mipmap_buf.iscale);
  dt_dev_pixelpipe_set_icc(&pipe, DT_COLORSPACE_DISPLAY, NULL, DT_INTENT_LAST);
  dt_dev_pixelpipe_create_nodes(&pipe, &dev);
  dt_dev_pixelpipe_synch_all(&pipe, &dev);

  // --- Fast preview pipe, fed the display-sized DT_MIPMAP_F ---------------
  // dt_dev_pixelpipe_init_preview() makes a PREVIEW-type pipe with its own
  // cache; the GUI feeds it the downscaled DT_MIPMAP_F mip (develop.c:705-723),
  // same as here, but init() regenerated that mip at display resolution.
  dt_mipmap_cache_get(&preview_mipmap_buf, imgid, DT_MIPMAP_F, DT_MIPMAP_BLOCKING, 'r');
  if(preview_mipmap_buf.buf && preview_mipmap_buf.width && preview_mipmap_buf.height
     && dt_dev_pixelpipe_init_preview(&preview_pipe)) {
    // DT_DEV_PIXELPIPE_FAST is a no-op headless: _dev_pixelpipe_process_rec()
    // re-derives it from the *focused GUI module* (NULL here) and clears it;
    // the real fast paths key off pipe type == PREVIEW. Set anyway to match the GUI.
    preview_pipe.type = (dt_dev_pixelpipe_type_t)(preview_pipe.type | DT_DEV_PIXELPIPE_FAST);
    dt_dev_pixelpipe_set_input(&preview_pipe, &dev, (float *)preview_mipmap_buf.buf,
                               preview_mipmap_buf.width, preview_mipmap_buf.height,
                               preview_mipmap_buf.iscale);
    dt_dev_pixelpipe_set_icc(&preview_pipe, DT_COLORSPACE_DISPLAY, NULL, DT_INTENT_LAST);
    dt_dev_pixelpipe_create_nodes(&preview_pipe, &dev);
    dt_dev_pixelpipe_synch_all(&preview_pipe, &dev);
    preview_pipe_ready = true;
    UtilityFunctions::print("DtBackend::load_image: preview pipe using DT_MIPMAP_F ",
                            preview_mipmap_buf.width, "x", preview_mipmap_buf.height);
  } else {
    UtilityFunctions::printerr("DtBackend::load_image: preview pipe unavailable "
                               "(DT_MIPMAP_F buffer or dt_dev_pixelpipe_init_preview() failed); "
                               "live edits fall back to the full pipe");
    if(preview_mipmap_buf.buf) {
      dt_mipmap_cache_release(&preview_mipmap_buf);
      std::memset(&preview_mipmap_buf, 0, sizeof(preview_mipmap_buf));
    }
  }

  // both pipes committed their pieces from defaults/history above: nothing to dispatch
  pipe_needs_full_synch = false;
  pipe_change_pending = false;
  pipe_change_multi = false;
  pipe_change_module = nullptr;

  // Cache both pipes' native (scale=1.0) dims before any render: the UI's zoom math needs the full pipe's dims even when the first render is a preview.
  dt_dev_pixelpipe_get_dimensions(&pipe, &dev, pipe.iwidth, pipe.iheight,
                                  &pipe.processed_width, &pipe.processed_height);
  native_width = pipe.processed_width;
  native_height = pipe.processed_height;
  preview_native_width = 0;
  preview_native_height = 0;
  if(preview_pipe_ready) {
    dt_dev_pixelpipe_get_dimensions(&preview_pipe, &dev, preview_pipe.iwidth, preview_pipe.iheight,
                                    &preview_native_width, &preview_native_height);
  }

  pipe_ready = true;
  image_loaded = true;
  exposure_module = nullptr;
  colorbalance_module = nullptr;
  shadhi_module = nullptr;
  toneequal_module = nullptr;
  velvia_module = nullptr;
  monochrome_module = nullptr;
  vibrance_module = nullptr;
  tonecurve_module = nullptr;
  channelmixer_rgb_module = nullptr;
  clipping_module = nullptr;
  _dehaze_ambient = 0.0f;
  dehaze_value = 0.0f;
  return true;
}

// Shared setter pattern: locate the module once, clamp, write directly into its
// live params blob, mark enabled, record a headless history item (the _ext
// variant; dt_dev_add_history_item() no-ops without darktable.gui).
void DtBackend::set_exposure(float ev) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_exposure: no image loaded");
    return;
  }

  if(ev < -18.0f) ev = -18.0f;
  if(ev > 18.0f) ev = 18.0f;

  if(!exposure_module) {
    exposure_module = dt_iop_get_module_from_list(dev.iop, "exposure");
    if(!exposure_module) {
      UtilityFunctions::printerr("DtBackend::set_exposure: could not find \"exposure\" module in dev.iop");
      return;
    }
  }

  if(!dt_iop_set_float(exposure_module, "exposure", ev)) return;
  exposure_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, exposure_module, TRUE, TRUE);
  note_pipe_change(exposure_module);
}

// Same pattern, on colorbalancergb's `contrast`: a scene-referred pivoted
// contrast (grey_fulcrum), unlike colisa's Lab curve. Clamped to the field's $MIN/$MAX.
void DtBackend::set_contrast(float value) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_contrast: no image loaded");
    return;
  }

  if(value < -1.0f) value = -1.0f;
  if(value > 1.0f) value = 1.0f;

  if(!colorbalance_module) {
    colorbalance_module = dt_iop_get_module_from_list(dev.iop, "colorbalancergb");
    if(!colorbalance_module) {
      UtilityFunctions::printerr("DtBackend::set_contrast: could not find \"colorbalancergb\" module in dev.iop");
      return;
    }
  }

  if(!dt_iop_set_float(colorbalance_module, "contrast", value)) return;
  colorbalance_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, colorbalance_module, TRUE, TRUE);
  note_pipe_change(colorbalance_module);
}

// Same pattern, on shadhi ("shadows and highlights"); clamped -70..70, tighter
// than the module's $MIN/$MAX -100..100 (too extreme).
void DtBackend::set_shadows(float value) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_shadows: no image loaded");
    return;
  }

  if(value < -70.0f) value = -70.0f;
  if(value > 70.0f) value = 70.0f;

  if(!shadhi_module) {
    shadhi_module = dt_iop_get_module_from_list(dev.iop, "shadhi");
    if(!shadhi_module) {
      UtilityFunctions::printerr("DtBackend::set_shadows: could not find \"shadhi\" module in dev.iop");
      return;
    }
  }

  if(!dt_iop_set_float(shadhi_module, "shadows", value)) return;
  shadhi_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, shadhi_module, TRUE, TRUE);
  note_pipe_change(shadhi_module);
}

void DtBackend::set_highlights(float value) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_highlights: no image loaded");
    return;
  }

  if(value < -70.0f) value = -70.0f;
  if(value > 70.0f) value = 70.0f;

  if(!shadhi_module) {
    shadhi_module = dt_iop_get_module_from_list(dev.iop, "shadhi");
    if(!shadhi_module) {
      UtilityFunctions::printerr("DtBackend::set_highlights: could not find \"shadhi\" module in dev.iop");
      return;
    }
  }

  if(!dt_iop_set_float(shadhi_module, "highlights", value)) return;
  shadhi_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, shadhi_module, TRUE, TRUE);
  note_pipe_change(shadhi_module);
}

// Blacks/Whites: same pattern, driving toneequal band gains rather than
// endpoint points. UI -1..1 (0 = neutral). Blacks -> the `blacks` field (the
// -5 EV band) at full ±2 EV gain (±1 EV felt weaker than the shadhi-backed
// Shadows slider); Whites -> `whites` (the -1 EV band) at ±1 EV (toneequal.c:
// 176/180); the module's own ±2 EV per band proved too extreme on whites.
// Blacks is SIGN-INVERTED: a positive toneequal gain LIFTS its band, but
// Lightroom's positive Blacks DEEPENS blacks; Whites passes straight through.
void DtBackend::set_blacks(float value) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_blacks: no image loaded");
    return;
  }

  if(value < -1.0f) value = -1.0f;
  if(value > 1.0f) value = 1.0f;

  if(!toneequal_module) {
    toneequal_module = dt_iop_get_module_from_list(dev.iop, "toneequal");
    if(!toneequal_module) {
      UtilityFunctions::printerr("DtBackend::set_blacks: could not find \"toneequal\" module in dev.iop");
      return;
    }
  }

  if(!toneequal_pin_preset(toneequal_module)) return;

  // Sign-inverted, full ±2 EV (UI -1..1 -> module gain +2..-2 EV): see above.
  if(!dt_iop_set_float(toneequal_module, "blacks", -value * 2.0f)) return;

  toneequal_module->enabled = (value != 0.0f) ? TRUE : FALSE;
  dt_dev_add_history_item_ext(&dev, toneequal_module, TRUE, TRUE);
  note_pipe_change(toneequal_module);
}

void DtBackend::set_whites(float value) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_whites: no image loaded");
    return;
  }

  if(value < -1.0f) value = -1.0f;
  if(value > 1.0f) value = 1.0f;

  if(!toneequal_module) {
    toneequal_module = dt_iop_get_module_from_list(dev.iop, "toneequal");
    if(!toneequal_module) {
      UtilityFunctions::printerr("DtBackend::set_whites: could not find \"toneequal\" module in dev.iop");
      return;
    }
  }

  if(!toneequal_pin_preset(toneequal_module)) return;

  // Straight through: UI +1 -> +1 EV on the whites band (brighter whites).
  if(!dt_iop_set_float(toneequal_module, "whites", value)) return;

  toneequal_module->enabled = (value != 0.0f) ? TRUE : FALSE;
  dt_dev_add_history_item_ext(&dev, toneequal_module, TRUE, TRUE);
  note_pipe_change(toneequal_module);
}

// Same pattern, on velvia ("saturation boost"), which is boost-only: the below-
// neutral saturation half is set_desaturation()'s job. Clamped to $MIN/$MAX.
void DtBackend::set_saturation(float value) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_saturation: no image loaded");
    return;
  }

  if(value < 0.0f) value = 0.0f;
  if(value > 100.0f) value = 100.0f;

  if(!velvia_module) {
    velvia_module = dt_iop_get_module_from_list(dev.iop, "velvia");
    if(!velvia_module) {
      UtilityFunctions::printerr("DtBackend::set_saturation: could not find \"velvia\" module in dev.iop");
      return;
    }
  }

  if(!dt_iop_set_float(velvia_module, "strength", value)) return;
  velvia_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, velvia_module, TRUE, TRUE);
  note_pipe_change(velvia_module);
}

// The saturation slider's below-neutral half. velvia can only BOOST saturation
// (its $MIN is 0.0 = neutral), so below neutral drives the "monochrome"
// module's BLEND parameters instead: uniform-mask mode (just the opacity slider
// every darktable module has) with opacity = amount*100%. blend_params ride
// history items like params changes (see DARKTABLE_API_NOTES.md F.2).
void DtBackend::set_desaturation(float amount) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_desaturation: no image loaded");
    return;
  }

  if(amount < 0.0f) amount = 0.0f;
  if(amount > 1.0f) amount = 1.0f;

  if(!monochrome_module) {
    monochrome_module = dt_iop_get_module_from_list(dev.iop, "monochrome");
    if(!monochrome_module) {
      UtilityFunctions::printerr("DtBackend::set_desaturation: could not find \"monochrome\" module in dev.iop");
      return;
    }
  }

  dt_develop_blend_params_t *bp =
      (dt_develop_blend_params_t *)monochrome_module->blend_params;
  if(amount <= 0.0f) {
    monochrome_module->enabled = FALSE;
    // Reset blend to defaults so a later re-enable starts clean (an enabled-but-0%
    // piece would still pay process() every render). RGB_DISPLAY is monochrome's
    // own blend color space (monochrome.c:155).
    dt_develop_blend_init_blend_parameters(bp, DEVELOP_BLEND_CS_RGB_DISPLAY);
  } else {
    bp->mask_mode = DEVELOP_MASK_ENABLED; // uniform: no mask, just opacity
    bp->opacity = amount * 100.0f;
    monochrome_module->enabled = TRUE;
  }

  dt_dev_add_history_item_ext(&dev, monochrome_module, monochrome_module->enabled, TRUE);
  note_pipe_change(monochrome_module);
}

// Same pattern, on vibrance: clamped 0..100, the `amount` field's $MIN/$MAX.
void DtBackend::set_vibrance(float value) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_vibrance: no image loaded");
    return;
  }

  if(value < 0.0f) value = 0.0f;
  if(value > 100.0f) value = 100.0f;

  if(!vibrance_module) {
    vibrance_module = dt_iop_get_module_from_list(dev.iop, "vibrance");
    if(!vibrance_module) {
      UtilityFunctions::printerr("DtBackend::set_vibrance: could not find \"vibrance\" module in dev.iop");
      return;
    }
  }

  if(!dt_iop_set_float(vibrance_module, "amount", value)) return;
  vibrance_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, vibrance_module, TRUE, TRUE);
  note_pipe_change(vibrance_module);
}

// Dehaze is OUR OWN post-pipe stage, not the darktable "hazeremoval" module
// (see dt_backend.h and DARKTABLE_API_NOTES.md F.8 for why). Ours: single
// achromatic ambient A from the dark-channel prior; per pixel
// t = 1 - strength * min_c(pixel_c / A); out = (in - A)/t + A with the SAME
// scalar t for all channels, so hue is preserved at every strength.
void DtBackend::set_dehaze(float value) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_dehaze: no image loaded");
    return;
  }
  if(value < -1.0f) value = -1.0f;
  if(value > 1.0f) value = 1.0f;
  dehaze_value = value;
  // A depends on the current render, so any other module's change invalidates
  // it. Strength changes do NOT: the min-channel haze ranking barely moves.
  if(value == 0.0f) _dehaze_ambient = 0.0f;
}

void DtBackend::_apply_dehaze(uint8_t *rgba8, int width, int height) const {
  if(dehaze_value == 0.0f) return;
  if(!rgba8 || width <= 0 || height <= 0) return;

  // Lazy per-image ambient estimate: measured on the first non-neutral render,
  // reused after. note_pipe_change() resets it on any other module's change.
  if(_dehaze_ambient <= 0.0f) {
    _dehaze_ambient = _estimate_dehaze_ambient(rgba8, width, height);
    if(_dehaze_ambient <= 0.0f) return; // degenerate (pure black) frame
  }
  const float A = _dehaze_ambient;

  // UI -1..1 -> strength -0.5..+0.5: the raw dark-channel formulation saturates
  // before 1.0 (t floors and posterizes); soft cap is deliberate.
  const float strength = dehaze_value * 0.5f;

  const size_t n = (size_t)width * height;
  for(size_t k = 0; k < n; k++) {
    uint8_t *px = rgba8 + k * 4;
    const float r = _dt_srgb_to_linear[px[0]];
    const float g = _dt_srgb_to_linear[px[1]];
    const float b = _dt_srgb_to_linear[px[2]];
    // min over channels of in/A, the haze-opacity (dark channel) estimate.
    float m = r / A;
    const float mg = g / A;
    const float mb = b / A;
    if(mg < m) m = mg;
    if(mb < m) m = mb;
    if(m > 1.0f) m = 1.0f; // pixels brighter than A don't push t negative
    float t = 1.0f - strength * m;
    if(t < 1.0f / 32.0f) t = 1.0f / 32.0f; // floor: keep the map invertible
    const float inv = 1.0f / t;
    // out = (in - A)/t + A, same scalar t for all three channels: what preserves
    // hue. A bright pass can push above 1.0; the encode table saturates there.
    const int ir = (int)(((r - A) * inv + A) * 4095.0f);
    const int ig = (int)(((g - A) * inv + A) * 4095.0f);
    const int ib = (int)(((b - A) * inv + A) * 4095.0f);
    px[0] = _dt_linear_to_srgb[std::clamp(ir, 0, 4095)];
    px[1] = _dt_linear_to_srgb[std::clamp(ig, 0, 4095)];
    px[2] = _dt_linear_to_srgb[std::clamp(ib, 0, 4095)];
    px[3] = 0xFF;
  }
}

// Dark-channel-prior ambient estimate, achromatic: mean luma of the brightest
// half among the most-hazy 5% of pixels. Returns linear luma in 0..1.
float DtBackend::_estimate_dehaze_ambient(const uint8_t *rgba8, int width, int height) const {
  const size_t n = (size_t)width * height;
  if(n == 0) return 0.0f;
  // Dark channel = min over R,G,B of the gamma-decoded pixel. Sample every 4th
  // pixel for the percentile cut (stable under decimation, cheaper sort).
  std::vector<float> mins;
  mins.reserve(n / 4 + 1);
  for(size_t k = 0; k < n; k += 4) {
    const uint8_t *px = rgba8 + k * 4;
    const float r = _dt_srgb_to_linear[px[0]];
    const float g = _dt_srgb_to_linear[px[1]];
    const float b = _dt_srgb_to_linear[px[2]];
    float m = r < g ? r : g;
    if(b < m) m = b;
    mins.push_back(m);
  }
  const size_t pivot = (size_t)(mins.size() * 0.95f);
  if(pivot >= mins.size()) return 0.0f;
  std::nth_element(mins.begin(), mins.begin() + pivot, mins.end());
  const float crit_haze = mins[pivot];
  // Mean luma of the full-resolution hazy+bright set; scalar, so achromatic by construction.
  float sum = 0.0f;
  int64_t counted = 0;
  for(size_t k = 0; k < n; k++) {
    const uint8_t *px = rgba8 + k * 4;
    const float r = _dt_srgb_to_linear[px[0]];
    const float g = _dt_srgb_to_linear[px[1]];
    const float b = _dt_srgb_to_linear[px[2]];
    float m = r < g ? r : g;
    if(b < m) m = b;
    if(m >= crit_haze) {
      sum += 0.2126f * r + 0.7152f * g + 0.0722f * b;
      counted++;
    }
  }
  if(counted == 0) return 0.0f;
  return sum / (float)counted;
}

// Unlike every scalar setter above, `params` here is a curve: overwrite the
// whole L-channel node array/count from `points` and leave everything else at
// introspection defaults.
void DtBackend::set_tonecurve(PackedVector2Array points) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_tonecurve: no image loaded");
    return;
  }

  int n = points.size();
  if(n < 2) {
    UtilityFunctions::printerr("DtBackend::set_tonecurve: need at least 2 points");
    return;
  }
  if(n > DT_BACKEND_TONECURVE_MAXNODES) {
    UtilityFunctions::printerr("DtBackend::set_tonecurve: too many points");
    return;
  }

  if(!tonecurve_module) {
    tonecurve_module = dt_iop_get_module_from_list(dev.iop, "tonecurve");
    if(!tonecurve_module) {
      UtilityFunctions::printerr("DtBackend::set_tonecurve: could not find \"tonecurve\" module in dev.iop");
      return;
    }
  }

  dt_iop_module_t *m = tonecurve_module;

  // The L-channel spline is tonecurve[0][0..n-1], plus tonecurve_nodes[0] (the
  // live count) and tonecurve_type[0] (interpolation kind). Offsets come from
  // the generated introspection so a node-field reorder can't silently shift the curve.
  float *nodes = (float *)dt_iop_field(m, "tonecurve"); // &tonecurve[0][0].x
  int *node_count = (int *)dt_iop_field(m, "tonecurve_nodes"); // &tonecurve_nodes[0]
  int *node_type = (int *)dt_iop_field(m, "tonecurve_type");   // &tonecurve_type[0]
  if(!nodes || !node_count || !node_type) return;

  dt_introspection_field_t *node_f = m->get_f("tonecurve[0][0]");   // STRUCT {x,y}
  dt_introspection_field_t *x_f    = m->get_f("tonecurve[0][0].x");
  dt_introspection_field_t *y_f    = m->get_f("tonecurve[0][0].y");
  if(!node_f || !x_f || !y_f) return;
  const size_t node_stride = node_f->header.size;                   // sizeof(dt_iop_tonecurve_node_t) == 8
  const size_t x_off = x_f->header.offset - node_f->header.offset;  // 0
  const size_t y_off = y_f->header.offset - node_f->header.offset;  // 4

  for(int i = 0; i < n; i++) {
    Vector2 pt = points[i];
    float x = pt.x, y = pt.y;
    if(x < 0.0f) x = 0.0f;
    if(x > 1.0f) x = 1.0f;
    if(y < 0.0f) y = 0.0f;
    if(y > 1.0f) y = 1.0f;
    char *node = (char *)nodes + (size_t)i * node_stride;
    *(float *)(node + x_off) = x;
    *(float *)(node + y_off) = y;
  }
  node_count[0] = n;
  node_type[0] = DT_BACKEND_MONOTONE_HERMITE;
  tonecurve_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, tonecurve_module, TRUE, TRUE);
  note_pipe_change(tonecurve_module);
}

// White balance via channelmixerrgb's chromatic adaptation, not the temperature
// module: in the scene-referred workflow `temperature` is pinned to a neutral
// D65_LATE preset and the real adaptation is channelmixerrgb's job. Illuminant
// DT_ILLUMINANT_D + adaptation DT_ADAPTATION_CAT16 so `temperature` alone drives
// the CAT (commit_params() derives x/y, channelmixerrgb.c:3092ff).
void DtBackend::set_white_balance_temperature(float kelvin) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_white_balance_temperature: no image loaded");
    return;
  }

  if(kelvin < DT_BACKEND_CHANNELMIXERRGB_TEMP_MIN) kelvin = DT_BACKEND_CHANNELMIXERRGB_TEMP_MIN;
  if(kelvin > DT_BACKEND_CHANNELMIXERRGB_TEMP_MAX) kelvin = DT_BACKEND_CHANNELMIXERRGB_TEMP_MAX;

  if(!channelmixer_rgb_module) {
    channelmixer_rgb_module = dt_iop_get_module_from_list(dev.iop, "channelmixerrgb");
    if(!channelmixer_rgb_module) {
      UtilityFunctions::printerr("DtBackend::set_white_balance_temperature: could not find \"channelmixerrgb\" module in dev.iop");
      return;
    }
  }

  if(!dt_iop_set_enum(channelmixer_rgb_module, "illuminant", "DT_ILLUMINANT_D")) return;
  if(!dt_iop_set_enum(channelmixer_rgb_module, "adaptation", "DT_ADAPTATION_CAT16")) return;
  if(!dt_iop_set_float(channelmixer_rgb_module, "temperature", kelvin)) return;
  channelmixer_rgb_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, channelmixer_rgb_module, TRUE, TRUE);
  note_pipe_change(channelmixer_rgb_module);
}

// Read-only: seeds the UI's White Balance slider from the as-shot value.
float DtBackend::get_white_balance_temperature() {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::get_white_balance_temperature: no image loaded");
    return 0.0f;
  }

  if(!channelmixer_rgb_module) {
    channelmixer_rgb_module = dt_iop_get_module_from_list(dev.iop, "channelmixerrgb");
    if(!channelmixer_rgb_module) {
      UtilityFunctions::printerr("DtBackend::get_white_balance_temperature: could not find \"channelmixerrgb\" module in dev.iop");
      return 0.0f;
    }
  }

  // The as-shot Kelvin lands in DEFAULT params, not live params: a normal color
  // raw leaves live params->temperature at the flat ~5003 default
  // (channelmixerrgb.c ~3883-3886); see DARKTABLE_API_NOTES.md F.4.
  const float *t = (const float *)dt_iop_field_default(channelmixer_rgb_module, "temperature");
  return t ? *t : 0.0f;
}

// Same pattern, on the clipping module ("crop & rotate"). cx/cy/cw/ch are crop
// EDGES, NOT x/y/w/h: (left, top) one corner, (right, bottom) the opposite,
// normalized 0..1 of the whole image. angle/keystone/ratio stay at defaults.
void DtBackend::set_crop(float left, float top, float right, float bottom) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_crop: no image loaded");
    return;
  }

  // Mirror commit_params' clamps (clipping.c:1325-1328).
  if(left < 0.0f) left = 0.0f;
  if(left > 0.9f) left = 0.9f;
  if(top < 0.0f) top = 0.0f;
  if(top > 0.9f) top = 0.9f;
  if(right < 0.1f) right = 0.1f;
  if(right > 1.0f) right = 1.0f;
  if(bottom < 0.1f) bottom = 0.1f;
  if(bottom > 1.0f) bottom = 1.0f;

  if(!clipping_module) {
    clipping_module = dt_iop_get_module_from_list(dev.iop, "clipping");
    if(!clipping_module) {
      UtilityFunctions::printerr("DtBackend::set_crop: could not find \"clipping\" module in dev.iop");
      return;
    }
  }

  if(!dt_iop_set_float(clipping_module, "cx", left)) return;
  if(!dt_iop_set_float(clipping_module, "cy", top)) return;
  if(!dt_iop_set_float(clipping_module, "cw", right)) return;
  if(!dt_iop_set_float(clipping_module, "ch", bottom)) return;

  // Full frame == no crop: disable the module (its process() would just copy). Tighter box re-enables.
  const bool no_crop = (left <= 0.0f && top <= 0.0f && right >= 1.0f && bottom >= 1.0f);
  clipping_module->enabled = no_crop ? FALSE : TRUE;

  dt_dev_add_history_item_ext(&dev, clipping_module, TRUE, TRUE);
  note_pipe_change(clipping_module);
}

// Records `module` as changed since the last pipe synch. See the dispatch
// members in dt_backend.h for why this bridge cannot lean on darktable's own
// change signalling (dev->full.pipe/preview_pipe are NULL headless). The piece
// lookup below detects a first activation (enabled flag vs committed piece),
// the one case a TOP_CHANGED re-commit is too narrow for; use a full replay.
void DtBackend::note_pipe_change(dt_iop_module_t *module) {
  // Any edit outside the dehaze stage invalidates the cached ambient: exposure/
  // WB/contrast move the channel means the next dehaze render re-estimates against.
  if(module) {
    _dehaze_ambient = 0.0f;
  }

  // Two distinct modules before one render cannot be expressed as TOP_CHANGED:
  // synch_top only re-commits the last history item, skipping the earlier one.
  if(pipe_change_pending && pipe_change_module != module)
    pipe_change_multi = true;

  pipe_change_pending = true;
  pipe_change_module = module;

  for(GList *nodes = pipe.nodes; nodes; nodes = g_list_next(nodes)) {
    dt_dev_pixelpipe_iop_t *piece = (dt_dev_pixelpipe_iop_t *)nodes->data;
    if(piece->module == module && piece->enabled != module->enabled) {
      pipe_needs_full_synch = true;
      break;
    }
  }
}

// A blanket synch_all() before every render discards the pixelpipe cache and
// makes per-render cost grow with history length; a single-module edit uses
// synch_top() instead so upstream cache lines survive. Multi-module batches and
// enabled-state flips still fall back to a full replay. Both pipes need the
// change (separate node lists/caches); synch_top/synch_all only read
// dev->history, so this is safe per pipe. See docs/PERF-IMPROVEMENT.md fix 2.
void DtBackend::dispatch_pipe_changes() {
  if(!(pipe_needs_full_synch || pipe_change_multi || pipe_change_pending))
    return;

  const bool full_synch = pipe_needs_full_synch || pipe_change_multi;

  auto apply = [&](dt_dev_pixelpipe_t *p) {
    if(full_synch)
      dt_dev_pixelpipe_synch_all(p, &dev);
    else
      dt_dev_pixelpipe_synch_top(p, &dev);
  };

  apply(&pipe);
  if(preview_pipe_ready)
    apply(&preview_pipe);

  pipe_needs_full_synch = false;
  pipe_change_pending = false;
  pipe_change_multi = false;
  pipe_change_module = nullptr;
}

// Dispatches pending changes then refreshes the FULL pipe's native dims.
// dt_dev_pixelpipe_get_dimensions() is scale-independent (reports native
// scale=1.0 dims regardless of the scale process() later uses,
// imageio.c:1251-1253), so caching across renders is safe.
bool DtBackend::refresh_native_dimensions() {
  if(!image_loaded || !pipe_ready) {
    UtilityFunctions::printerr("DtBackend::refresh_native_dimensions: no image loaded / pipe not ready");
    return false;
  }

  dispatch_pipe_changes();

  dt_dev_pixelpipe_get_dimensions(&pipe, &dev, pipe.iwidth, pipe.iheight,
                                   &pipe.processed_width, &pipe.processed_height);

  native_width = pipe.processed_width;
  native_height = pipe.processed_height;

  if(native_width <= 0 || native_height <= 0) {
    UtilityFunctions::printerr("DtBackend::refresh_native_dimensions: invalid processed dimensions");
    return false;
  }
  return true;
}

// Same as refresh_native_dimensions() but for the preview pipe; the dispatch is
// shared, so a preview + full render in one cycle re-syncs each pipe once.
bool DtBackend::refresh_preview_dimensions() {
  if(!image_loaded || !preview_pipe_ready) {
    return false;
  }

  dispatch_pipe_changes();

  dt_dev_pixelpipe_get_dimensions(&preview_pipe, &dev, preview_pipe.iwidth, preview_pipe.iheight,
                                  &preview_native_width, &preview_native_height);

  if(preview_native_width <= 0 || preview_native_height <= 0) {
    UtilityFunctions::printerr("DtBackend::refresh_preview_dimensions: invalid preview dimensions");
    return false;
  }
  return true;
}

// The one ROI-process-read implementation behind render_view() and
// render_preview(): darktable's own darkroom scale/ROI math (develop.c:874-890,
// ppd fixed at 1.0). center_x/center_y are develop.c's zoom_x/zoom_y, [-0.5, 0.5],
// (0,0) = centered. At or below fit-scale the whole image renders; above it, only
// a viewport ROI positioned by center. Returns exactly wd*ht RGBA8.
PackedByteArray DtBackend::render_pipe_roi(dt_dev_pixelpipe_t *p, int native_w, int native_h,
                                           int viewport_w, int viewport_h, double scale,
                                           double center_x, double center_y) {
  PackedByteArray out;

  if(viewport_w <= 0 || viewport_h <= 0) {
    UtilityFunctions::printerr("DtBackend::render_pipe_roi: invalid viewport_w/viewport_h");
    return out;
  }
  if(scale <= 0.0) {
    UtilityFunctions::printerr("DtBackend::render_pipe_roi: invalid scale");
    return out;
  }

  const int pipe_w = std::max(1, (int)std::lround(scale * native_w));
  const int pipe_h = std::max(1, (int)std::lround(scale * native_h));
  const int wd = std::min(viewport_w, pipe_w);
  const int ht = std::min(viewport_h, pipe_h);

  // When wd==pipe_w (fit or smaller), pipe_w-wd==0 forces x=0 regardless of
  // center_x: panning is a no-op whenever the image already fits.
  const long x_hi = (long)(pipe_w - wd);
  const long y_hi = (long)(pipe_h - ht);
  const int x = (int)std::clamp(std::lround((double)pipe_w * (0.5 + center_x) - (double)wd / 2.0),
                                 (long)0, x_hi);
  const int y = (int)std::clamp(std::lround((double)pipe_h * (0.5 + center_y) - (double)ht / 2.0),
                                 (long)0, y_hi);

  // 8-bit/gamma display path, not the float _no_gamma() path.
  dt_dev_pixelpipe_process(p, &dev, x, y, wd, ht, (float)scale, DT_DEVICE_NONE);


  // Lock backbuf_mutex around the read, mirroring darktable's own display path.
  dt_pthread_mutex_lock(&p->backbuf_mutex);

  uint8_t *backbuf = p->backbuf;
  if(!backbuf) {
    dt_pthread_mutex_unlock(&p->backbuf_mutex);
    UtilityFunctions::printerr("DtBackend::render_pipe_roi: pipe.backbuf is NULL (no valid output buffer)");
    return out;
  }

  // Size the copy/swap loop to wd * ht (the ROI just rendered): backbuf only
  // holds that many valid pixels after process().
  const int64_t pixel_count = (int64_t)wd * (int64_t)ht;
  const int64_t byte_count = pixel_count * 4;

  out.resize(byte_count);
  uint8_t *dst = out.ptrw();

  // darktable's 8-bit backbuf is BGRx-ordered (see imageio.c's byte-swap code);
  // Godot 4 dropped FORMAT_BGRA8, so swap R/B and force opaque alpha. Parallelized
  // like darktable's own swap (imageio.c:1437's DT_OMP_FOR).
#ifdef _OPENMP
#pragma omp parallel for default(firstprivate) schedule(static)
#endif
  for(int64_t k = 0; k < pixel_count; ++k) {
    const uint8_t *src_px = backbuf + k * 4;
    uint8_t *dst_px = dst + k * 4;
    dst_px[0] = src_px[2]; // R <- B
    dst_px[1] = src_px[1]; // G
    dst_px[2] = src_px[0]; // B <- R
    dst_px[3] = 0xFF;      // force opaque alpha
  }

  dt_pthread_mutex_unlock(&p->backbuf_mutex);

  // Dehaze post-stage, identically on both pipes so exports/preview match.
  // Outside the backbuf_mutex: it mutates our copy, not the pipe.
  _apply_dehaze(dst, wd, ht);

  // get_width()/get_height() report the actual *rendered* (ROI) dims.
  processed_width = wd;
  processed_height = ht;

  return out;
}

// Final-quality render on the full pipe (see render_pipe_roi() for the math).
PackedByteArray DtBackend::render_view(int viewport_w, int viewport_h, double scale,
                                       double center_x, double center_y) {
  if(!refresh_native_dimensions())
    return PackedByteArray();

  return render_pipe_roi(&pipe, native_width, native_height,
                         viewport_w, viewport_h, scale, center_x, center_y);
}

// Fast interactive render on the preview pipe. `scale` is a fraction of the
// preview mip's dimensions (see dt_backend.h); darktable propagates it into
// every module's input ROI via modify_roi_in (pixelpipe_hb.c:2263).
PackedByteArray DtBackend::render_preview(int viewport_w, int viewport_h, double scale,
                                          double center_x, double center_y) {
  if(!refresh_preview_dimensions())
    return render_view(viewport_w, viewport_h, scale, center_x, center_y);

  return render_pipe_roi(&preview_pipe, preview_native_width, preview_native_height,
                         viewport_w, viewport_h, scale, center_x, center_y);
}

// Thin wrapper around render_view(): "fit" scale (develop.c:1066-1076's
// scale_fit formula, clamped to 1.0 so this never upscales past native, matching
// export_image()'s upscale=FALSE), center (0,0).
PackedByteArray DtBackend::process_fit(int max_width, int max_height) {
  PackedByteArray out;

  if(!refresh_native_dimensions()) {
    return out;
  }

  if(max_width <= 0 || max_height <= 0) {
    UtilityFunctions::printerr("DtBackend::process_fit: invalid max_width/max_height");
    return out;
  }

  double scale = std::min((double)max_width / (double)native_width,
                           (double)max_height / (double)native_height);
  if(scale > 1.0) scale = 1.0;
  if(scale <= 0.0) {
    UtilityFunctions::printerr("DtBackend::process_fit: degenerate scale computed, aborting");
    return out;
  }

  return render_view(max_width, max_height, scale, 0.0, 0.0);
}

// Export the currently-loaded image, with all in-memory edits applied, to a
// real file on disk (JPEG/PNG/TIFF). Reuses darktable's own export engine
// (dt_imageio_export_with_flags()) rather than re-encoding the 8-bit preview
// backbuf, so the output is full-resolution through the float export pipe.
// Subtlety: that function builds a FRESH dev and replays library-DB history,
// so flush our in-memory history first (see DARKTABLE_API_NOTES.md, section D).
bool DtBackend::export_image(String path) {
  if(!initialized || !image_loaded) {
    UtilityFunctions::printerr("DtBackend::export_image: no image loaded");
    return false;
  }

  const CharString path_utf8 = path.utf8();
  const char *cpath = path_utf8.get_data();

  // Map the file extension to darktable's format-module plugin name (named
  // after the module source files); jpg/tif aliasing mirrors main.c:773-783.
  String ext = path.get_extension().to_lower();
  const char *fmt_name = nullptr;
  if(ext == "jpg" || ext == "jpeg") fmt_name = "jpeg";
  else if(ext == "png") fmt_name = "png";
  else if(ext == "tif" || ext == "tiff") fmt_name = "tiff";
  else {
    UtilityFunctions::printerr("DtBackend::export_image: unsupported extension '.", ext,
                               "' (use .jpg, .png, or .tif)");
    return false;
  }

  // Persist the live edit history to the in-memory DB so the export's fresh dev picks it up.
  dt_dev_write_history_ext(&dev, imgid);

  dt_imageio_module_format_t *format = dt_imageio_get_format_by_name(fmt_name);
  if(!format) {
    UtilityFunctions::printerr("DtBackend::export_image: format module '", fmt_name,
                               "' not available");
    return false;
  }

  dt_imageio_module_data_t *fdata = (dt_imageio_module_data_t *)format->get_params(format);
  if(!fdata) {
    UtilityFunctions::printerr("DtBackend::export_image: format->get_params() failed");
    return false;
  }

  // 0 = no size cap -> export at the image's full processed resolution.
  fdata->max_width = 0;
  fdata->max_height = 0;
  fdata->style[0] = '\0';
  fdata->style_append = FALSE;

  // dt_imageio_export_with_flags() returns FALSE on SUCCESS (a footgun worth
  // calling out). Flags mirror darktable-cli's dt_imageio_export() wrapper
  // (imageio.c:1013-1018); history_end=-1: full history.
  const gboolean failed = dt_imageio_export_with_flags(
      imgid, cpath, format, fdata,
      FALSE /*ignore_exif*/, FALSE /*display_byteorder*/, TRUE /*high_quality*/,
      FALSE /*upscale*/, FALSE /*is_scaling*/, 1.0, FALSE /*thumbnail*/,
      NULL /*filter*/, TRUE /*copy_metadata*/, FALSE /*export_masks*/,
      DT_COLORSPACE_SRGB, NULL, DT_INTENT_LAST, NULL /*storage*/, NULL /*storage_params*/,
      1, 1, NULL /*metadata*/, -1 /*history_end*/);

  format->free_params(format, fdata);

  if(failed) {
    UtilityFunctions::printerr("DtBackend::export_image: export failed for ", path);
    return false;
  }

  // The dehaze post-stage lives outside darktable's pipe, so apply it in place
  // on the full-resolution frame (fresh A, more accurate than the preview-pipe
  // A) and re-encode: JPEG at 0.92 keeps generational loss negligible; PNG is lossless.
  if(dehaze_value != 0.0f) {
    Ref<Image> img = Image::load_from_file(path);
    if(img.is_null()) {
      UtilityFunctions::printerr("DtBackend::export_image: dehaze post-pass could not re-open ", path);
      return false;
    }
    Image *im = img.ptr();
    im->convert(Image::FORMAT_RGBA8);
    _dehaze_ambient = 0.0f; // force a fresh estimate on the full-res frame
    _apply_dehaze(im->ptrw(), im->get_width(), im->get_height());
    const Error err = path.get_extension().to_lower() == "png"
        ? im->save_png(path)
        : im->save_jpg(path, 0.92f);
    _dehaze_ambient = 0.0f; // cache belongs to the preview frame again
    if(err != OK) {
      UtilityFunctions::printerr("DtBackend::export_image: dehaze post-pass re-encode failed (", err, ")");
      return false;
    }
  }

  UtilityFunctions::print("DtBackend::export_image: wrote ", path);
  return true;
}

int DtBackend::get_width() {
  return processed_width;
}

int DtBackend::get_height() {
  return processed_height;
}

int DtBackend::get_native_width() {
  return native_width;
}

int DtBackend::get_native_height() {
  return native_height;
}

int DtBackend::get_raw_width() {
  return raw_width;
}

int DtBackend::get_raw_height() {
  return raw_height;
}

// Pipe -> dev -> mipmap buffer -> process-wide dt_cleanup(), in that exact
// order. Guarded against double-cleanup: GDScript may call this from both a
// close handler and object destruction.
void DtBackend::cleanup() {
  if(cleaned_up) {
    return;
  }
  cleaned_up = true;

  if(pipe_ready) {
    dt_dev_pixelpipe_cleanup(&pipe);
    pipe_ready = false;
  }
  if(preview_pipe_ready) {
    dt_dev_pixelpipe_cleanup(&preview_pipe);
    preview_pipe_ready = false;
  }

  if(image_loaded) {
    dt_dev_cleanup(&dev);
    dt_mipmap_cache_release(&mipmap_buf);
    std::memset(&mipmap_buf, 0, sizeof(mipmap_buf));
    if(preview_mipmap_buf.buf) {
      dt_mipmap_cache_release(&preview_mipmap_buf);
      std::memset(&preview_mipmap_buf, 0, sizeof(preview_mipmap_buf));
    }
    image_loaded = false;
    imgid = NO_IMGID;
    exposure_module = nullptr;
    colorbalance_module = nullptr;
    shadhi_module = nullptr;
    toneequal_module = nullptr;
    velvia_module = nullptr;
  monochrome_module = nullptr;
    vibrance_module = nullptr;
    tonecurve_module = nullptr;
    channelmixer_rgb_module = nullptr;
    clipping_module = nullptr;
    _dehaze_ambient = 0.0f;
    dehaze_value = 0.0f;
    }

  if(initialized) {
    dt_cleanup();
    initialized = false;
  }
}

// Per-image teardown only: pipe -> dev -> mipmap buffer, in that order, but
// leaves `initialized` and `cleaned_up` untouched so the backend stays usable
// for a subsequent load_image(). No-op if nothing is loaded.
void DtBackend::unload_image() {
  if(!image_loaded) {
    return;
  }

  if(pipe_ready) {
    dt_dev_pixelpipe_cleanup(&pipe);
    pipe_ready = false;
  }
  if(preview_pipe_ready) {
    dt_dev_pixelpipe_cleanup(&preview_pipe);
    preview_pipe_ready = false;
  }

  dt_dev_cleanup(&dev);
  dt_mipmap_cache_release(&mipmap_buf);
  std::memset(&mipmap_buf, 0, sizeof(mipmap_buf));
  if(preview_mipmap_buf.buf) {
    dt_mipmap_cache_release(&preview_mipmap_buf);
    std::memset(&preview_mipmap_buf, 0, sizeof(preview_mipmap_buf));
  }
  image_loaded = false;
  imgid = NO_IMGID;
  exposure_module = nullptr;
  colorbalance_module = nullptr;
  shadhi_module = nullptr;
  toneequal_module = nullptr;
  velvia_module = nullptr;
  monochrome_module = nullptr;
  vibrance_module = nullptr;
  tonecurve_module = nullptr;
  channelmixer_rgb_module = nullptr;
  clipping_module = nullptr;
  _dehaze_ambient = 0.0f;
  dehaze_value = 0.0f;

  processed_width = 0;
  processed_height = 0;
  native_width = 0;
  native_height = 0;
  preview_native_width = 0;
  preview_native_height = 0;
  raw_width = 0;
  raw_height = 0;

  // drop any dispatch state left over from the torn-down pipe
  pipe_needs_full_synch = false;
  pipe_change_pending = false;
  pipe_change_multi = false;
  pipe_change_module = nullptr;
}
