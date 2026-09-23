/*
 * DtBackend implementation. Architecture: the "two languages, one process" section
 * of godot-poc/README.md. Links against darktable (github.com/darktable-org/darktable),
 * Copyright (C) the darktable contributors, GPLv3 or later. See NOTICE.
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

// sRGB<->linear LUTs for the dehaze post-stage; decode exact per 8-bit, encode a 4096-entry table.
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

void dt_backend_dladdr_anchor() {}

bool path_exists(const std::string &path) {
  return g_file_test(path.c_str(), G_FILE_TEST_EXISTS) == TRUE;
}

bool datadir_looks_valid(const std::string &datadir) {
  gchar *sentinel = g_build_filename(datadir.c_str(), "rawspeed", "cameras.xml", NULL);
  const bool ok = path_exists(sentinel);
  g_free(sentinel);
  return ok;
}

// --- introspection field access ---------------------------------------------

void *dt_iop_field(dt_iop_module_t *m, const char *name)
{
  if(!m || !m->get_p) return nullptr;
  void *p = m->get_p(m->params, name);
  if(!p)
    UtilityFunctions::printerr("DtBackend: module has no params field \"", name, "\"");
  return p;
}

// Same, but on default_params.
const void *dt_iop_field_default(dt_iop_module_t *m, const char *name)
{
  if(!m || !m->get_p) return nullptr;
  const void *p = m->get_p(m->default_params, name);
  if(!p)
    UtilityFunctions::printerr("DtBackend: module has no params field \"", name, "\"");
  return p;
}

bool dt_iop_set_float(dt_iop_module_t *m, const char *name, float value)
{
  float *p = (float *)dt_iop_field(m, name);
  if(!p) return false;
  *p = value;
  return true;
}

bool dt_iop_set_int(dt_iop_module_t *m, const char *name, int value)
{
  int *p = (int *)dt_iop_field(m, name);
  if(!p) return false;
  *p = value;
  return true;
}

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

static void set_preview_mip_size(const int width, const int height) {
  if(!darktable.mipmap_cache || width <= 0 || height <= 0) return;

  const int mip_width = width / 2;
  const int mip_height = height / 2;
  if(mip_width <= 0 || mip_height <= 0) return;

  dt_mipmap_cache_t *cache = darktable.mipmap_cache;
  const size_t old_pixels = (size_t)cache->max_width[DT_MIPMAP_F]
                                * (size_t)cache->max_height[DT_MIPMAP_F];
  const size_t payload = 4 * sizeof(float) * (size_t)mip_width * (size_t)mip_height;

  size_t header = sizeof(size_t) * 4;
  if(cache->buffer_size[DT_MIPMAP_F] > 4 * sizeof(float) * old_pixels)
    header = cache->buffer_size[DT_MIPMAP_F] - 4 * sizeof(float) * old_pixels;

  cache->max_width[DT_MIPMAP_F] = (uint32_t)mip_width;
  cache->max_height[DT_MIPMAP_F] = (uint32_t)mip_height;
  cache->buffer_size[DT_MIPMAP_F] = header + payload;

  UtilityFunctions::print("DtBackend::set_preview_mip_size: DT_MIPMAP_F mip set to ",
                          mip_width, "x", mip_height, " (", (int64_t)((header + payload) >> 20),
                          " MB buffer)");
}

bool DtBackend::compute_dt_dirs(std::string &datadir, std::string &moduledir) {
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

  {
    const godot::String exe_path = godot::OS::get_singleton()->get_executable_path();
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

  {
    Dl_info info;
    if(dladdr(reinterpret_cast<void *>(&dt_backend_dladdr_anchor), &info) != 0 && info.dli_fname) {
      gchar *lib_dir = g_path_get_dirname(info.dli_fname);
      gchar *frameworks_dir = g_path_get_dirname(lib_dir);
      gchar *contents_dir = g_path_get_dirname(frameworks_dir);

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

bool DtBackend::init(int display_width, int display_height) {
  if(initialized) {
    UtilityFunctions::print("DtBackend::init: already initialized");
    return true;
  }

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

  std::vector<char *> argv_vec = { arg0, arg1, arg2, arg3, arg4, arg5, datadir, arg7, moduledir,
                                   arg9, configdir, arg11, cachedir };
  argv_vec.push_back(nullptr);
  int argc = (int)argv_vec.size() - 1;

  const int rc = dt_init(argc, argv_vec.data(), FALSE, TRUE, NULL);
  g_free(configdir);
  g_free(cachedir);
  g_free(datadir);
  g_free(moduledir);
  if(rc != 0) {
    UtilityFunctions::printerr("DtBackend::init: dt_init() failed, rc=", rc);
    return false;
  }

  darktable.prefer_library_history = TRUE;

  if(display_width > 0 && display_height > 0) {
    set_preview_mip_size(display_width, display_height);
  } else {
    UtilityFunctions::print("DtBackend::init: no display size given; "
                            "DT_MIPMAP_F preview mip keeps darktable's default (1440x900 / 1920x1200)");
  }

  initialized = true;
  return true;
}

bool DtBackend::load_image(String path) {
  if(!initialized) {
    UtilityFunctions::printerr("DtBackend::load_image: init() was not called");
    return false;
  }
  if(image_loaded) {
    unload_image();
  }

  const CharString path_utf8 = path.utf8();
  const char *cpath = path_utf8.get_data();

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

  if(!dt_dev_pixelpipe_init(&pipe)) {
    UtilityFunctions::printerr("DtBackend::load_image: dt_dev_pixelpipe_init() failed");
    dt_mipmap_cache_release(&mipmap_buf);
    std::memset(&mipmap_buf, 0, sizeof(mipmap_buf));
    dt_dev_cleanup(&dev);
    imgid = NO_IMGID;
    return false;
  }

  dt_dev_pixelpipe_set_input(&pipe, &dev, (float *)mipmap_buf.buf,
                              mipmap_buf.width, mipmap_buf.height, mipmap_buf.iscale);
  dt_dev_pixelpipe_set_icc(&pipe, DT_COLORSPACE_DISPLAY, NULL, DT_INTENT_LAST);
  dt_dev_pixelpipe_create_nodes(&pipe, &dev);
  dt_dev_pixelpipe_synch_all(&pipe, &dev);

  dt_mipmap_cache_get(&preview_mipmap_buf, imgid, DT_MIPMAP_F, DT_MIPMAP_BLOCKING, 'r');
  if(preview_mipmap_buf.buf && preview_mipmap_buf.width && preview_mipmap_buf.height
     && dt_dev_pixelpipe_init_preview(&preview_pipe)) {
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

  pipe_needs_full_synch = false;
  pipe_change_pending = false;
  pipe_change_multi = false;
  pipe_change_module = nullptr;

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

  if(!dt_iop_set_float(toneequal_module, "whites", value)) return;

  toneequal_module->enabled = (value != 0.0f) ? TRUE : FALSE;
  dt_dev_add_history_item_ext(&dev, toneequal_module, TRUE, TRUE);
  note_pipe_change(toneequal_module);
}

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
    dt_develop_blend_init_blend_parameters(bp, DEVELOP_BLEND_CS_RGB_DISPLAY); // monochrome's blend space
  } else {
    bp->mask_mode = DEVELOP_MASK_ENABLED;
    bp->opacity = amount * 100.0f;
    monochrome_module->enabled = TRUE;
  }

  dt_dev_add_history_item_ext(&dev, monochrome_module, monochrome_module->enabled, TRUE);
  note_pipe_change(monochrome_module);
}

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

void DtBackend::set_dehaze(float value) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_dehaze: no image loaded");
    return;
  }
  if(value < -1.0f) value = -1.0f;
  if(value > 1.0f) value = 1.0f;
  dehaze_value = value;
  if(value == 0.0f) _dehaze_ambient = 0.0f;
}

void DtBackend::_apply_dehaze(uint8_t *rgba8, int width, int height) const {
  if(dehaze_value == 0.0f) return;
  if(!rgba8 || width <= 0 || height <= 0) return;

  if(_dehaze_ambient <= 0.0f) {
    _dehaze_ambient = _estimate_dehaze_ambient(rgba8, width, height);
    if(_dehaze_ambient <= 0.0f) return;
  }
  const float A = _dehaze_ambient;

  const float strength = dehaze_value * 0.5f;

  const size_t n = (size_t)width * height;
  for(size_t k = 0; k < n; k++) {
    uint8_t *px = rgba8 + k * 4;
    const float r = _dt_srgb_to_linear[px[0]];
    const float g = _dt_srgb_to_linear[px[1]];
    const float b = _dt_srgb_to_linear[px[2]];
    float m = r / A;
    const float mg = g / A;
    const float mb = b / A;
    if(mg < m) m = mg;
    if(mb < m) m = mb;
    if(m > 1.0f) m = 1.0f;
    float t = 1.0f - strength * m;
    if(t < 1.0f / 32.0f) t = 1.0f / 32.0f;
    const float inv = 1.0f / t;
    const int ir = (int)(((r - A) * inv + A) * 4095.0f);
    const int ig = (int)(((g - A) * inv + A) * 4095.0f);
    const int ib = (int)(((b - A) * inv + A) * 4095.0f);
    px[0] = _dt_linear_to_srgb[std::clamp(ir, 0, 4095)];
    px[1] = _dt_linear_to_srgb[std::clamp(ig, 0, 4095)];
    px[2] = _dt_linear_to_srgb[std::clamp(ib, 0, 4095)];
    px[3] = 0xFF;
  }
}

float DtBackend::_estimate_dehaze_ambient(const uint8_t *rgba8, int width, int height) const {
  const size_t n = (size_t)width * height;
  if(n == 0) return 0.0f;
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

  float *nodes = (float *)dt_iop_field(m, "tonecurve");
  int *node_count = (int *)dt_iop_field(m, "tonecurve_nodes");
  int *node_type = (int *)dt_iop_field(m, "tonecurve_type");
  if(!nodes || !node_count || !node_type) return;

  dt_introspection_field_t *node_f = m->get_f("tonecurve[0][0]");
  dt_introspection_field_t *x_f    = m->get_f("tonecurve[0][0].x");
  dt_introspection_field_t *y_f    = m->get_f("tonecurve[0][0].y");
  if(!node_f || !x_f || !y_f) return;
  const size_t node_stride = node_f->header.size;
  const size_t x_off = x_f->header.offset - node_f->header.offset;
  const size_t y_off = y_f->header.offset - node_f->header.offset;

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

  const float *t = (const float *)dt_iop_field_default(channelmixer_rgb_module, "temperature");
  return t ? *t : 0.0f;
}

void DtBackend::set_crop(float left, float top, float right, float bottom) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_crop: no image loaded");
    return;
  }

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

  const bool no_crop = (left <= 0.0f && top <= 0.0f && right >= 1.0f && bottom >= 1.0f);
  clipping_module->enabled = no_crop ? FALSE : TRUE;

  dt_dev_add_history_item_ext(&dev, clipping_module, TRUE, TRUE);
  note_pipe_change(clipping_module);
}

void DtBackend::note_pipe_change(dt_iop_module_t *module) {
  if(module) {
    _dehaze_ambient = 0.0f;
  }

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

  const long x_hi = (long)(pipe_w - wd);
  const long y_hi = (long)(pipe_h - ht);
  const int x = (int)std::clamp(std::lround((double)pipe_w * (0.5 + center_x) - (double)wd / 2.0),
                                 (long)0, x_hi);
  const int y = (int)std::clamp(std::lround((double)pipe_h * (0.5 + center_y) - (double)ht / 2.0),
                                 (long)0, y_hi);

  dt_dev_pixelpipe_process(p, &dev, x, y, wd, ht, (float)scale, DT_DEVICE_NONE);


  dt_pthread_mutex_lock(&p->backbuf_mutex);

  uint8_t *backbuf = p->backbuf;
  if(!backbuf) {
    dt_pthread_mutex_unlock(&p->backbuf_mutex);
    UtilityFunctions::printerr("DtBackend::render_pipe_roi: pipe.backbuf is NULL (no valid output buffer)");
    return out;
  }

  const int64_t pixel_count = (int64_t)wd * (int64_t)ht;
  const int64_t byte_count = pixel_count * 4;

  out.resize(byte_count);
  uint8_t *dst = out.ptrw();

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

  _apply_dehaze(dst, wd, ht);

  processed_width = wd;
  processed_height = ht;

  return out;
}

PackedByteArray DtBackend::render_view(int viewport_w, int viewport_h, double scale,
                                       double center_x, double center_y) {
  if(!refresh_native_dimensions())
    return PackedByteArray();

  return render_pipe_roi(&pipe, native_width, native_height,
                         viewport_w, viewport_h, scale, center_x, center_y);
}

PackedByteArray DtBackend::render_preview(int viewport_w, int viewport_h, double scale,
                                          double center_x, double center_y) {
  if(!refresh_preview_dimensions())
    return render_view(viewport_w, viewport_h, scale, center_x, center_y);

  return render_pipe_roi(&preview_pipe, preview_native_width, preview_native_height,
                         viewport_w, viewport_h, scale, center_x, center_y);
}

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

bool DtBackend::export_image(String path) {
  if(!initialized || !image_loaded) {
    UtilityFunctions::printerr("DtBackend::export_image: no image loaded");
    return false;
  }

  const CharString path_utf8 = path.utf8();
  const char *cpath = path_utf8.get_data();

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

  fdata->max_width = 0;
  fdata->max_height = 0;
  fdata->style[0] = '\0';
  fdata->style_append = FALSE;

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

  if(dehaze_value != 0.0f) {
    Ref<Image> img = Image::load_from_file(path);
    if(img.is_null()) {
      UtilityFunctions::printerr("DtBackend::export_image: dehaze post-pass could not re-open ", path);
      return false;
    }
    Image *im = img.ptr();
    im->convert(Image::FORMAT_RGBA8);
    _dehaze_ambient = 0.0f;
    _apply_dehaze(im->ptrw(), im->get_width(), im->get_height());
    const Error err = path.get_extension().to_lower() == "png"
        ? im->save_png(path)
        : im->save_jpg(path, 0.92f);
    _dehaze_ambient = 0.0f;
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

  pipe_needs_full_synch = false;
  pipe_change_pending = false;
  pipe_change_multi = false;
  pipe_change_module = nullptr;
}
