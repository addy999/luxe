/*
 * DtBackend implementation. See the architecture section of godot-poc/README.md
 * for how these pieces fit together.
 */
#include "dt_backend.h"

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

extern "C" {
#include "common/dtpthread.h"
}

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>

#include <dlfcn.h>

using namespace godot;

// sRGB <-> linear lookup tables for the dehaze post-stage (_apply_dehaze).
// Decode is exact per 8-bit sRGB value; encode is a 4096-entry linear-in
// table indexed by the top 12 bits of the linear float (saturating beyond
// 1.0), which is well within 8-bit rounding error.
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

// Anchor function whose address lives inside libdt_backend's own image, used
// solely as a dladdr() target below (dladdr needs *some* address that
// resolves back to this .dylib/.framework; a plain free function is simpler
// than trying to dladdr a non-static member function pointer).
void dt_backend_dladdr_anchor() {}

// True if `path` exists on disk. Uses glib's g_file_test() to stay
// consistent with the rest of this file's glib usage (g_build_filename(),
// g_mkdir_with_parents(), etc. below).
bool path_exists(const std::string &path) {
  return g_file_test(path.c_str(), G_FILE_TEST_EXISTS) == TRUE;
}

// A candidate resource_dir is only accepted if it actually contains a real
// darktable datadir. The sentinel here used to be "darktable.png" directly
// under datadir, on the assumption every darktable datadir install ships a
// flat share/darktable/darktable.png -- WRONG for this darktable checkout
// (verified: source/build/share/darktable/ has no bare darktable.png at all;
// the app icon assets only exist nested under icons/hicolor/<size>/apps/ and
// pixmaps/, per source/data/CMakeLists.txt's install rules). That stale
// sentinel meant datadir_looks_valid() returned false for every real,
// correctly-populated datadir this project's own bundle produces, which
// silently defeated *both* of compute_dt_dirs()'s bundle-relative fallback
// candidates (discovered while fixing the DT_BACKEND_DATADIR-override bug:
// after that fix correctly
// stopped accepting a bogus dev-tree default in an exported .app, the
// fallback candidates below it in compute_dt_dirs() were *also* failing to
// resolve, tracing back to this sentinel never matching anything).
// "rawspeed/cameras.xml" is used instead: bundle_darktable_deps.sh always
// copies it (it is the exact file this whole check exists to protect --
// dt_rawspeed_load_meta() in imageio_rawspeed.cc builds this same relative
// path off datadir), and it exists directly, unnested, in every real
// datadir this project produces.
bool datadir_looks_valid(const std::string &datadir) {
  gchar *sentinel = g_build_filename(datadir.c_str(), "rawspeed", "cameras.xml", NULL);
  const bool ok = path_exists(sentinel);
  g_free(sentinel);
  return ok;
}

} // namespace

// Display-sized preview mip (): darktable sizes the DT_MIPMAP_F float preview mip once, inside
// dt_mipmap_cache_init() (source/src/common/mipmap_cache.c:744-746), from the
// `highres_preview_mip` conf flag: 1440x900 or 1920x1200. That is below a HiDPI
// display's device pixel count, so the preview reads soft. dt_mipmap_cache_init()
// runs inside dt_init(), so a --conf injection from here would be too late and a
// conf set before dt_init() is impossible (the conf does not exist yet).
//
// The supported override is to write the cache's public size fields directly,
// AFTER dt_init() and BEFORE any DT_MIPMAP_F buffer is requested. Feasibility,
// traced through mipmap_cache.c:
//   * `max_width[DT_MIPMAP_F]`/`max_height[DT_MIPMAP_F]` are read at cache-entry
//     *allocation* time, in _mipmap_cache_allocate_dynamic(), to seed the
//     descriptor's width/height (:508-509). Entries are allocated lazily on the
//     first get() of that mip, not at init, so a write before our first
//     DT_MIPMAP_F get sticks.
//   * `buffer_size[DT_MIPMAP_F]` is also read at allocation time (:487), to size
//     the entry's allocation. It must be updated in lockstep with the max fields
//     or the buffer would be too small for the generated mip. The payload is
//     4 channels * sizeof(float) = 16 bytes/pixel (init()'s formula at :799-801),
//     and the header size is derived from darktable's own init-time numbers
//     rather than redeclaring the (private-to-mipmap_cache.c) descriptor struct:
//     header = old buffer_size - 16 * old_w * old_h. That self-adjusts if
//     upstream changes the descriptor.
//   * Generation itself (_init_f, :1360+) derives the real output dims from the
//     descriptor's width/height, so it follows the fields.
//   * The DT_MIPMAP_F mip is NOT disk-cached: the disk read/write paths are
//     gated on `mip <= DT_MIPMAP_LDR_MAX` (= DT_MIPMAP_10, :527), and
//     DT_MIPMAP_F is above that. So there is no stale-size disk cache to
//     invalidate; the mip is regenerated in memory every process.
// Called with the display's physical pixels. The mip is capped at HALF that
// size (aspect-fit into width/2 x height/2), so on the 3024x1964 panel the mip
// is generated at half display resolution (~1512x982 for the 6048x4024
// fixture) rather than the full panel. Darktable still aspect-fits the image
// into these bounds, so the real output is min(half-display, image).
static void set_preview_mip_size(const int width, const int height) {
  if(!darktable.mipmap_cache || width <= 0 || height <= 0) return;

  const int mip_width = width / 2;
  const int mip_height = height / 2;
  if(mip_width <= 0 || mip_height <= 0) return;

  dt_mipmap_cache_t *cache = darktable.mipmap_cache;
  const size_t old_pixels = (size_t)cache->max_width[DT_MIPMAP_F]
                                * (size_t)cache->max_height[DT_MIPMAP_F];
  const size_t payload = 4 * sizeof(float) * (size_t)mip_width * (size_t)mip_height;

  // Header = existing buffer_size minus its payload; guard against an
  // unexpectedly small/zero buffer_size by falling back to a safe fixed pad.
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

// Computes --datadir/--moduledir at runtime. Tried in order,
// cheapest/most-dev-friendly first:
//
//   1. DT_BACKEND_DATADIR / DT_BACKEND_MODULEDIR env vars, if BOTH are set.
//      Pure dev convenience -- lets the inner dev loop point at
//      source/build/share|lib/darktable without any bundle/dladdr logic.
//   2. Bundle-relative via Godot's own running executable path
//      (OS::get_executable_path()). Matches the exported .app layout:
//        MyApp.app/Contents/MacOS/MyApp                (executable_path)
//        MyApp.app/Contents/Resources/darktable/share/darktable
//        MyApp.app/Contents/Resources/darktable/lib/darktable
//      Only accepted if darktable.png actually exists under the computed
//      datadir -- during in-editor dev runs, get_executable_path() returns
//      the *Godot editor's* binary path, which has no Resources/darktable
//      next to it, so this candidate correctly falls through.
//   3. dladdr() on this extension's own loaded image (works regardless of
//      host process -- editor or exported app). Two sub-candidates are
//      tried, both relative to the directory containing
//      libdt_backend.*.framework/libdt_backend.*:
//        a. <dir>/../../Resources/darktable/{share,lib}/darktable, i.e. the
//           same Contents/Resources/darktable layout as step 2, reached from
//           Contents/Frameworks/libdt_backend.*.framework/libdt_backend.*
//           instead of Contents/MacOS/MyApp. Useful once Phase 2 places the
//           framework under Contents/Frameworks/.
//   4. If nothing resolves, print an error and fail init() outright rather
//      than silently handing dt_init() a bogus/nonexistent path.
bool DtBackend::compute_dt_dirs(std::string &datadir, std::string &moduledir) {
  // --- 1. env var override (dev convenience) --------------------------
  // Validated with the same datadir_looks_valid() sentinel check as the
  // bundle-relative candidates below: this branch used to accept the env var
  // unconditionally, which
  // meant a wrong-but-existing path (e.g. Main.gd's dev-tree default,
  // erroneously globalized against an exported .app's bundle path) would be
  // silently accepted as datadir instead of falling through to the
  // candidates below that actually know how to find a real bundle datadir.
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
    // .../MyApp.app/Contents/MacOS/MyApp -> get_base_dir() -> .../MacOS
    // -> get_base_dir() again -> .../Contents
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
      // info.dli_fname e.g.:
      //   .../Contents/Frameworks/libdt_backend.*.framework/libdt_backend.*
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

// Section A: dt_init(argc, argv, init_gui, load_data, L). darktable-cli
// forces --library :memory: and --conf write_sidecar_files=never onto a
// synthetic argv before calling dt_init (main.c:482-492) so it never
// touches the user's real config/db -- we mirror that here rather than
// forwarding Godot's own argv.
bool DtBackend::init(int display_width, int display_height) {
  if(initialized) {
    UtilityFunctions::print("DtBackend::init: already initialized");
    return true;
  }

  // --datadir/--moduledir are required here: darktable normally resolves
  // these relative to its own executable's path, but here it's loaded as a
  // shared library inside Godot.app, so that auto-detection resolves to
  // nonsense paths under Godot.app itself. These used to be compile-time
  // constants baked in by SConstruct (DT_DATADIR_PATH/DT_MODULEDIR_PATH),
  // which baked absolute paths into the compiled binary and broke as soon as
  // the binary moved. They are now computed at runtime by
  // compute_dt_dirs() (env var override -> bundle-relative via Godot's
  // executable path -> dladdr()-relative fallback -> hard failure).
  //
  // --configdir/--cachedir are required for the same underlying reason as
  // --library :memory: above: darktable's config dir holds a SQLite lock
  // file (data.db) that only one darktable instance can hold at a time. If
  // we let dt_init() fall back to its default (~/.config/darktable), then
  // running a headless test/tool while a Godot editor Play session already
  // has this extension initialized fails with "can't acquire database
  // lock", because both processes fight over the same real user config dir.
  // Pointing both at a private directory under the user's cache dir means
  // every instance of this extension gets its own config/cache sandbox,
  // fully isolated from ~/.config/darktable and from each other only in the
  // sense that no two instances share a dir unless intentionally pointed at
  // the same one.
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
  // dt_init() needs mutable char* argv entries; the gchar* pointers from
  // g_build_filename() are already exactly that, so build datadir/moduledir
  // the same way (consistent with configdir/cachedir just above) rather than
  // hand-rolling std::vector<char> buffers.
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

  // argv entries are char*, not const char*, so the gchar* pointers from
  // g_build_filename()/g_strdup() plug in directly -- but they MUST stay
  // alive until after dt_init() returns (freed below), since dt_init() reads
  // argv synchronously during this call.
  std::vector<char *> argv_vec = { arg0, arg1, arg2, arg3, arg4, arg5, datadir, arg7, moduledir,
                                   arg9, configdir, arg11, cachedir };
  argv_vec.push_back(nullptr);
  int argc = (int)argv_vec.size() - 1;

  // init_gui = FALSE (headless), load_data = TRUE (custom presets, matches
  // darktable-cli's default), L = NULL (no Lua state).
  const int rc = dt_init(argc, argv_vec.data(), FALSE, TRUE, NULL);
  g_free(configdir);
  g_free(cachedir);
  g_free(datadir);
  g_free(moduledir);
  // dt_init() returns non-zero to signal a fatal init failure, so 0 means
  // success here.
  if(rc != 0) {
    UtilityFunctions::printerr("DtBackend::init: dt_init() failed, rc=", rc);
    return false;
  }

  // We init with `--library :memory:` (an sqlite DB), so edits must be read
  // back from that DB, not from XMP sidecars. darktable-cli sets this same
  // flag whenever it was given a --library (main.c:616,
  // `darktable.prefer_library_history = (library != NULL)`); without it the
  // fresh dev that dt_imageio_export_with_flags() loads for export would look
  // for a nonexistent XMP and drop every edit. See export_image().
  darktable.prefer_library_history = TRUE;

  // --- display size: size the DT_MIPMAP_F preview mip to half the display --
  // The preview pipe reads DT_MIPMAP_F (see load_image()); by default darktable
  // generates that mip at a fixed 1440x900/1920x1200, below a HiDPI display's
  // device pixel count. set_preview_mip_size() caps it at half the display's
  // physical pixels here, after dt_init() (so darktable.mipmap_cache exists) and
  // before any image / mip is requested. Main.gd passes physical (device) pixels;
  // 0,0 (unknown/headless) leaves darktable's fixed default in place. See
  // set_preview_mip_size()'s comment for why a direct field write is the
  // supported mechanism.
  if(display_width > 0 && display_height > 0) {
    set_preview_mip_size(display_width, display_height);
  } else {
    UtilityFunctions::print("DtBackend::init: no display size given; "
                            "DT_MIPMAP_F preview mip keeps darktable's default (1440x900 / 1920x1200)");
  }

  initialized = true;
  return true;
}

// Import the file, load it into a dt_develop_t, then stand up a persistent
// pixelpipe once (not per process() call) so repeated set_exposure()/process()
// calls are cheap.
bool DtBackend::load_image(String path) {
  if(!initialized) {
    UtilityFunctions::printerr("DtBackend::load_image: init() was not called");
    return false;
  }
  // Replace rather than reject: GDScript's "Open" handler no longer needs to
  // track whether an image is already loaded before calling this, so opening
  // a second image just swaps the session.
  if(image_loaded) {
    unload_image();
  }

  const CharString path_utf8 = path.utf8();
  const char *cpath = path_utf8.get_data();

  // dt_film_t must be zeroed via dt_film_init() before dt_film_new() -- an
  // uninitialized images_mutex SIGKILLs on macOS. Use dt_film_init() rather
  // than darktable's main.c inline pattern, which skips it.
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

  // Import into the (in-memory) library DB.
  const dt_imgid_t new_imgid = dt_image_import(filmid, cpath, TRUE, FALSE);
  dt_film_cleanup(&film);

  if(!dt_is_valid_imgid(new_imgid)) {
    UtilityFunctions::printerr("DtBackend::load_image: dt_image_import() failed for path: ", path);
    return false;
  }
  imgid = new_imgid;

  // dt_dev_init(&dev, FALSE) -> dt_dev_load_image(&dev, imgid).
  dt_dev_init(&dev, FALSE);
  dt_dev_load_image(&dev, imgid);

  // Pull the full-res buffer from the mipmap cache. Kept alive as member state
  // (mipmap_buf) until cleanup(), since it backs the pipe's input buffer.
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

  // dt_dev_pixelpipe_init_full() does NOT exist -- only dt_dev_pixelpipe_init(),
  // _init_preview(), _init_preview2(), _init_export(), _init_thumbnail(),
  // _init_dummy(). Use plain dt_dev_pixelpipe_init() for this live/full
  // preview pipe.
  if(!dt_dev_pixelpipe_init(&pipe)) {
    UtilityFunctions::printerr("DtBackend::load_image: dt_dev_pixelpipe_init() failed");
    dt_mipmap_cache_release(&mipmap_buf);
    std::memset(&mipmap_buf, 0, sizeof(mipmap_buf));
    dt_dev_cleanup(&dev);
    imgid = NO_IMGID;
    return false;
  }

  // Point the pipe at its input, choose the output colorspace, then build the
  // module node list and commit the current params/history into it.
  // dt_dev_pixelpipe_set_input() records the buffer plus its dimensions and
  // scale (and derives a starting output descriptor via get_output_format());
  // DT_COLORSPACE_DISPLAY with a NULL profile means "convert the output into
  // the user's configured display profile", and DT_INTENT_LAST is darktable's
  // sentinel for "no explicit rendering intent" (colorout.c leaves the intent
  // at the module default in that case) -- both are the values darktable's own
  // display-referred export path uses. create_nodes() then materializes one
  // node per active module and synch_all() commits each module's params (and
  // this image's history) into those nodes.
  dt_dev_pixelpipe_set_input(&pipe, &dev, (float *)mipmap_buf.buf,
                              mipmap_buf.width, mipmap_buf.height, mipmap_buf.iscale);
  dt_dev_pixelpipe_set_icc(&pipe, DT_COLORSPACE_DISPLAY, NULL, DT_INTENT_LAST);
  dt_dev_pixelpipe_create_nodes(&pipe, &dev);
  dt_dev_pixelpipe_synch_all(&pipe, &dev);

  // --- Fix #5: separate fast preview pipe, fed the display-sized DT_MIPMAP_F --
  // dt_dev_pixelpipe_init_preview() (pixelpipe_hb.c:251-257) makes a PREVIEW-type
  // pipe with its own cache; the GUI feeds its preview pipe the downscaled
  // DT_MIPMAP_F mip (develop.c:705-723, develop_jobs.c:25). This build does the
  // same, but the mip was regenerated at the display's physical resolution by
  // init() -> set_preview_mip_size(), so it is both fast (demosaic runs at the
  // mip's resolution, not native) and sharp (at the display's real pixel count).
  //
  // This mip is fetched once and held open (preview_mipmap_buf) for the preview
  // pipe's lifetime, exactly like mipmap_buf backs the full pipe.
  dt_mipmap_cache_get(&preview_mipmap_buf, imgid, DT_MIPMAP_F, DT_MIPMAP_BLOCKING, 'r');
  if(preview_mipmap_buf.buf && preview_mipmap_buf.width && preview_mipmap_buf.height
     && dt_dev_pixelpipe_init_preview(&preview_pipe)) {
    // DT_DEV_PIXELPIPE_FAST is darktable's "non-final quality" marker. It is
    // effectively a no-op headless: _dev_pixelpipe_process_rec()
    // (pixelpipe_hb.c:2030-2041) re-derives it on every recursion from the
    // *focused GUI module* (dt_dev_gui_module() -> darktable.develop->gui_module,
    // NULL here) and clears it on the first pass. The real fast paths come from
    // dt_pipe_is_preview() (type == PREVIEW), which demosaic, denoiseprofile, and
    // friends already honor. Set anyway to match the GUI, and in case that
    // derivation changes upstream.
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

  // both pipes committed their pieces from defaults/history above, so neither
  // has a pending change to dispatch (see the dispatch members in dt_backend.h)
  pipe_needs_full_synch = false;
  pipe_change_pending = false;
  pipe_change_multi = false;
  pipe_change_module = nullptr;

  // Cache both pipes' native (scale=1.0) dimensions now, before any render. The
  // UI needs the full pipe's native dims for its display-zoom math even when the
  // first render is a fast preview render (which refreshes only the preview dims).
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

// Section F: locate the exposure module once, clamp EV, write directly into
// its live params blob, mark enabled, record a history item via the
// headless _ext variant (the GUI-only dt_dev_add_history_item() no-ops
// without darktable.gui).
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

  dt_iop_exposure_params_t *p = (dt_iop_exposure_params_t *)exposure_module->params;
  p->exposure = ev;
  exposure_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, exposure_module, TRUE, TRUE);
  note_pipe_change(exposure_module);
}

// Section F, same pattern as set_exposure(): locate the colorbalancergb ("color
// balance rgb") module once, clamp to the contrast field's $MIN/$MAX
// (-1.0..1.0), write only that field directly into its live params blob, enable
// it, and record a headless history item. This is a scene-referred, pivoted
// contrast (grey_fulcrum), unlike colisa's asymmetric Lab curve. All other
// params keep the module's introspection defaults already sitting in the blob
// (e.g. grey_fulcrum 0.1845, saturation_formula DTUCS) -- we never zero them,
// exactly like set_exposure() only touches one field of a multi-field struct.
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

  dt_iop_colorbalancergb_params_t *p = (dt_iop_colorbalancergb_params_t *)colorbalance_module->params;
  p->contrast = value;
  colorbalance_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, colorbalance_module, TRUE, TRUE);
  note_pipe_change(colorbalance_module);
}

// Section F, same pattern as set_exposure()/set_contrast(): locate the shadhi
// ("shadows and highlights") module once, clamp to -70.0..70.0 (tighter than
// the module's own $MIN/$MAX of -100.0..100.0 since the full range is too
// extreme), write only that field directly into its live params blob,
// enable it, and record a headless history item. shadows and highlights are
// looked up via the same cached module pointer since they live in one module.
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

  dt_iop_shadhi_params_t *p = (dt_iop_shadhi_params_t *)shadhi_module->params;
  p->shadows = value;
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

  dt_iop_shadhi_params_t *p = (dt_iop_shadhi_params_t *)shadhi_module->params;
  p->highlights = value;
  shadhi_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, shadhi_module, TRUE, TRUE);
  note_pipe_change(shadhi_module);
}

// Blacks/Whites: same Section F pattern, driving toneequal ("tone
// equalizer") band gains rather than endpoint points. The UI passes a
// two-sided -1..1 (0 = neutral). Blacks maps to the FULL ±2 EV band gain
// (at ±1 EV it felt weaker than the shadhi-backed Shadows slider; ±2 EV
// matches its punch), Whites stays at ±1 EV (the module allows ±2 EV per
// band, but full range proved too extreme on the whites side). Band
// mapping: Blacks -> `blacks` (the -5 EV
// band), Whites -> `whites` (the -1 EV band), toneequal.c:176/180. SIGN
// INVERSION on Blacks: a positive toneequal gain LIFTS its band, but
// Lightroom's positive Blacks DEEPENS blacks, so set_blacks writes -value
// (UI +1 -> module gain -1 EV -> darker shadows; UI -1 -> +1 EV -> lifted,
// washed-out blacks). Whites passes straight through (+1 -> brighter whites).
// Mask machinery is pinned to the "simple tone curve" preset
// (toneequal.c:480-491) with details = DT_TONEEQ_NONE so the module is a
// plain global tone curve: no guided filter, no ROI padding, no detail
// preservation side effects. Both setters disable toneequal at neutral so
// it costs nothing in the pipe, mirroring set_crop()'s full-frame case.
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

  dt_iop_toneequalizer_params_t *p = (dt_iop_toneequalizer_params_t *)toneequal_module->params;
  // Pin the mask machinery to the "simple tone curve" preset state so a
  // fresh params blob is always in a known state.
  p->details = DT_TONEEQ_NONE;
  p->method = 4; // DT_TONEEQ_NORM_2 (RGB euclidean norm)
  p->iterations = 1;
  p->blending = 5.0f;
  p->smoothing = 1.414213562f;
  p->feathering = 1.0f;
  p->quantization = 0.0f;
  p->contrast_boost = 0.0f;
  p->exposure_boost = 0.0f;

  // Sign-inverted, full ±2 EV: see the comment above.
  // UI -1..1 -> module gain +2..-2 EV.
  p->blacks = -value * 2.0f;

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

  dt_iop_toneequalizer_params_t *p = (dt_iop_toneequalizer_params_t *)toneequal_module->params;
  // Same preset pinning as set_blacks (whichever setter runs first puts the
  // blob in a known state; the other re-asserts it).
  p->details = DT_TONEEQ_NONE;
  p->method = 4; // DT_TONEEQ_NORM_2 (RGB euclidean norm)
  p->iterations = 1;
  p->blending = 5.0f;
  p->smoothing = 1.414213562f;
  p->feathering = 1.0f;
  p->quantization = 0.0f;
  p->contrast_boost = 0.0f;
  p->exposure_boost = 0.0f;

  // Straight through: UI +1 -> +1 EV on the whites band (brighter whites).
  p->whites = value;

  toneequal_module->enabled = (value != 0.0f) ? TRUE : FALSE;
  dt_dev_add_history_item_ext(&dev, toneequal_module, TRUE, TRUE);
  note_pipe_change(toneequal_module);
}

// Section F, same pattern as set_exposure(): locate the velvia ("saturation
// boost") module once, clamp to `strength`'s $MIN/$MAX (0.0..100.0), write
// only that field, enable, record a headless history item.
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

  dt_iop_velvia_params_t *p = (dt_iop_velvia_params_t *)velvia_module->params;
  p->strength = value;
  velvia_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, velvia_module, TRUE, TRUE);
  note_pipe_change(velvia_module);
}

// The saturation slider's below-neutral half. velvia (above) can only BOOST
// saturation (its $MIN is 0.0 = neutral), so dragging the slider below neutral
// needs a different mechanism: this setter drives the "monochrome" module's
// blend parameters instead of any of its own fields. The module's params blob
// is left at its introspection defaults (a=0, b=0, size=2, highlights=0 --
// already a plain neutral grayscale conversion), while the blend params get a
// uniform-mask mode (DEVELOP_MASK_ENABLED, "uniformly" = no mask, just the
// opacity slider darktable's GUI exposes on every module) with opacity =
// amount * 100%. dt_dev_add_history_item_ext() snapshots module->blend_params
// into the history item (develop.c ~1390) and _dev_pixelpipe_synch() commits
// them back through dt_iop_commit_params() (pixelpipe_hb.c ~660), so opacity
// changes replay exactly like params changes across both pipes.
//
// amount == 0.0 (the neutral point) DISABLES the module outright, same policy
// as set_crop()'s full-frame case: a disabled piece costs nothing in the pipe,
// whereas an enabled-but-0%-opacity piece still pays monochrome's process()
// and blend every render.
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

  // Params blob untouched: its defaults are already a neutral grayscale
  // conversion. Only the blend decides how much of it lands on the image.
  dt_develop_blend_params_t *bp =
      (dt_develop_blend_params_t *)monochrome_module->blend_params;
  if(amount <= 0.0f) {
    monochrome_module->enabled = FALSE;
    // Reset to the module's own defaults so a later re-enable starts from a
    // clean blend state, not a stale fractional opacity. DEVELOP_BLEND_CS_
    // RGB_DISPLAY is monochrome's own blend color space (monochrome.c:155).
    dt_develop_blend_init_blend_parameters(bp, DEVELOP_BLEND_CS_RGB_DISPLAY);
  } else {
    bp->mask_mode = DEVELOP_MASK_ENABLED; // uniform: no mask, just opacity
    bp->opacity = amount * 100.0f;
    monochrome_module->enabled = TRUE;
  }

  dt_dev_add_history_item_ext(&dev, monochrome_module, monochrome_module->enabled, TRUE);
  note_pipe_change(monochrome_module);
}

// Section F, same pattern as set_exposure(): locate the vibrance module once,
// clamp to `amount`'s $MIN/$MAX (0.0..100.0), write the field, enable, record
// a headless history item.
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

  dt_iop_vibrance_params_t *p = (dt_iop_vibrance_params_t *)vibrance_module->params;
  p->amount = value;
  vibrance_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, vibrance_module, TRUE, TRUE);
  note_pipe_change(vibrance_module);
}

// Dehaze is OUR OWN post-pipe stage, not the darktable "hazeremoval" module.
// That module estimates a per-channel ambient light A0 from the haziest pixels
// with no chroma constraint, so on scenes whose haziest region is tinted (green
// window blinds, warm sky) it divides each channel by a different factor and
// casts the whole frame teal or pink; the cast is spatial (it varies with the
// per-pixel transmission t), so no global correction can undo it. Ours instead:
//
//   1. Estimate a SINGLE achromatic ambient light A from the image's dark
//      channel prior (classic He et al., but with A forced to gray).
//   2. Per pixel, t = 1 - strength * min_c(pixel_c / A), clamped.
//   3. out = (in - A)/t + A -- the SAME scalar t for all three channels.
//
// Because t is a scalar per pixel (not per channel), channel ratios survive
// exactly: hue is mathematically preserved at every strength, on any scene.
// The slider value is -1..1 with 0 = neutral; positive removes haze, negative
// adds it. Applied in display (gamma-encoded) space on the 8-bit backbuf;
// the affine map commutes with the monotone gamma, so hue preservation holds
// there too.
//
// value == 0 is an exact passthrough (the stage is skipped entirely, so the
// neutral point costs nothing).
void DtBackend::set_dehaze(float value) {
  if(!image_loaded) {
    UtilityFunctions::printerr("DtBackend::set_dehaze: no image loaded");
    return;
  }
  if(value < -1.0f) value = -1.0f;
  if(value > 1.0f) value = 1.0f;
  dehaze_value = value;
  // A depends on the current render (other modules' output), so any change
  // elsewhere in the pipe invalidates it; re-estimated lazily on the next
  // non-neutral render. A change of dehaze strength itself does NOT
  // invalidate: the ambient estimate is strength-independent by design (the
  // min-channel ranking of haze opacity barely moves with strength).
  if(value == 0.0f) _dehaze_ambient = 0.0f;
}

// Run the dehaze stage over an RGBA8 gamma-encoded buffer in place. Skipped
// entirely at strength 0. _dehaze_ambient/_estimate are const-cached via
// mutable members (see dt_backend.h).
void DtBackend::_apply_dehaze(uint8_t *rgba8, int width, int height) const {
  if(dehaze_value == 0.0f) return;
  if(!rgba8 || width <= 0 || height <= 0) return;

  // Lazy per-image ambient estimate: measure on the first non-neutral render,
  // reuse after. note_pipe_change() resets _dehaze_ambient to 0 whenever any
  // other module changes, so we always re-estimate against the current render.
  if(_dehaze_ambient <= 0.0f) {
    _dehaze_ambient = _estimate_dehaze_ambient(rgba8, width, height);
    if(_dehaze_ambient <= 0.0f) return; // degenerate (pure black) frame
  }
  const float A = _dehaze_ambient;

  // Strength mapping: the UI's -1..1 maps to haze-removal amount -0.5..+0.5.
  // The raw dark-channel formulation saturates well before 1.0 (t would hit
  // its floor and posterize), so the soft cap is deliberate.
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
    // out = (in - A)/t + A, same scalar t for all three channels: this is
    // what preserves hue. A bright haze-removal pass can push channels above
    // 1.0; the encode table saturates there.
    const int ir = (int)(((r - A) * inv + A) * 4095.0f);
    const int ig = (int)(((g - A) * inv + A) * 4095.0f);
    const int ib = (int)(((b - A) * inv + A) * 4095.0f);
    px[0] = _dt_linear_to_srgb[std::clamp(ir, 0, 4095)];
    px[1] = _dt_linear_to_srgb[std::clamp(ig, 0, 4095)];
    px[2] = _dt_linear_to_srgb[std::clamp(ib, 0, 4095)];
    px[3] = 0xFF;
  }
}

// Dark-channel-prior ambient estimate, achromatic. A = mean luma of the
// brightest half among the most-hazy 5% of pixels (dark channel near its
// maximum). No color assumption anywhere: only brightness ranking among hazy
// regions, so it adapts to any scene. Returns linear-space luma in 0..1.
float DtBackend::_estimate_dehaze_ambient(const uint8_t *rgba8, int width, int height) const {
  const size_t n = (size_t)width * height;
  if(n == 0) return 0.0f;
  // Dark channel = min over R,G,B of the gamma-decoded pixel. Sample every
  // 4th pixel for the percentile cut: the 95th percentile is stable under
  // decimation and this halves the sort cost.
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
  // Mean luma of the (full-resolution) hazy+bright pixel set, scalar so it is
  // achromatic by construction.
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


// Drives the tonecurve module's L-channel spline. Unlike every scalar setter
// above, `params` here is a curve: we overwrite the whole L-channel node
// array/count from `points` (clamped/ordered by the caller -- see the
// dt_backend.h comment on set_tonecurve()) and leave the a/b channels and
// every other field (autoscale, preset, unbound_ab, preserve_colors) exactly
// as introspection defaults left them. Interpolation type is forced to
// MONOTONE_HERMITE to match the module's own default and this backend's
// curve widget, which draws the same monotone-hermite spline.
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

  dt_iop_tonecurve_params_t *p = (dt_iop_tonecurve_params_t *)tonecurve_module->params;
  for(int i = 0; i < n; i++) {
    Vector2 pt = points[i];
    float x = pt.x, y = pt.y;
    if(x < 0.0f) x = 0.0f;
    if(x > 1.0f) x = 1.0f;
    if(y < 0.0f) y = 0.0f;
    if(y > 1.0f) y = 1.0f;
    p->tonecurve[0][i].x = x;
    p->tonecurve[0][i].y = y;
  }
  p->tonecurve_nodes[0] = n;
  p->tonecurve_type[0] = DT_BACKEND_MONOTONE_HERMITE;
  tonecurve_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, tonecurve_module, TRUE, TRUE);
  note_pipe_change(tonecurve_module);
}

// White balance via channelmixerrgb's chromatic adaptation. See the NOTE on
// white balance above dt_iop_channelmixer_rgb_params_t in dt_backend.h for
// why this targets channelmixerrgb ("color calibration") instead of
// temperature. Locates the module once (op name "channelmixerrgb"), clamps
// to TEMP_MIN/TEMP_MAX, sets illuminant = DT_ILLUMINANT_D (daylight) and
// adaptation = DT_ADAPTATION_CAT16 so `temperature` alone drives the CAT
// (commit_params() derives x/y from illuminant+temperature for
// DT_ILLUMINANT_D; see channelmixerrgb.c:3092-3098), enables the module, and
// records a headless history item -- same pattern as every other setter
// here. Does NOT touch `temperature` (source/src/iop/temperature.c); that
// module is left exactly as darktable itself initialized it.
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

  dt_iop_channelmixer_rgb_params_t *p = (dt_iop_channelmixer_rgb_params_t *)channelmixer_rgb_module->params;
  p->illuminant = DT_BACKEND_ILLUMINANT_D;
  p->adaptation = DT_BACKEND_ADAPTATION_CAT16;
  p->temperature = kelvin;
  channelmixer_rgb_module->enabled = TRUE;

  dt_dev_add_history_item_ext(&dev, channelmixer_rgb_module, TRUE, TRUE);
  note_pipe_change(channelmixer_rgb_module);
}

// Read-only: returns channelmixerrgb's current `temperature` without
// touching enabled/history, so the UI can seed its White Balance slider from
// the real per-image as-shot default (see set_white_balance_temperature()
// comment above, and the reload_defaults() note in dt_backend.h). Returns
// 0.0f if no image is loaded or the module can't be found.
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

  // The image's as-shot Kelvin is computed by channelmixerrgb's reload_defaults()
  // -> _check_if_close_to_daylight() into DEFAULT params, not the live params.
  // For a normal color raw the live params use illuminant=DT_ILLUMINANT_CAMERA
  // with an x/y chromaticity, leaving params->temperature at the flat ~5003
  // introspection default; the meaningful as-shot CCT lands in
  // default_params->temperature (channelmixerrgb.c reload_defaults ~3883-3886).
  // This getter exists solely to seed the UI slider at load, so read the
  // as-shot value from default_params.
  dt_iop_channelmixer_rgb_params_t *dp = (dt_iop_channelmixer_rgb_params_t *)channelmixer_rgb_module->default_params;
  return dp->temperature;
}

// Section F, same pattern as set_exposure()/set_tonecurve(): locate the
// clipping module ("crop & rotate") once, clamp the four crop edges to the
// module's own commit_params() ranges (cx/cy to 0..0.9, |cw|/|ch| to
// 0.1..1.0; clipping.c:1325-1328), write them into the live params blob,
// enable the module, and record a headless history item. (left, top) is one
// corner of the crop box and (right, bottom) the opposite corner, all as
// normalized 0..1 fractions of the whole image -- see the struct redeclaration
// comment in dt_backend.h for the left/top/right/bottom (NOT x/y/w/h)
// semantics. Passing the full frame (0, 0, 1, 1) disables the module instead,
// so a cleared crop costs nothing in the pipe. angle and all keystone/ratio
// fields are left exactly as the module's introspection defaults left them.
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

  dt_iop_clipping_params_t *p = (dt_iop_clipping_params_t *)clipping_module->params;
  p->cx = left;
  p->cy = top;
  p->cw = right;
  p->ch = bottom;

  // Full frame == no crop: disable the module entirely (its own process()
  // fast path would degenerate to a copy anyway). Any tighter box re-enables.
  const bool no_crop = (left <= 0.0f && top <= 0.0f && right >= 1.0f && bottom >= 1.0f);
  clipping_module->enabled = no_crop ? FALSE : TRUE;

  dt_dev_add_history_item_ext(&dev, clipping_module, TRUE, TRUE);
  note_pipe_change(clipping_module);
}

// Records `module` as changed since the last pipe synch. See the note on the
// dispatch members in dt_backend.h for why this bridge cannot lean on
// darktable's own change signalling (dev->full.pipe/preview_pipe are NULL
// headless). `module->enabled` was already set to TRUE by the setter before
// this runs, so comparing it against the piece's committed enabled flag tells
// us whether this is the module's first activation; that is the one case a
// TOP_CHANGED re-commit is on its own too narrow for, so fall back to a full
// replay. Every module owns a piece after create_nodes() whether enabled or
// not, so the piece lookup always succeeds for a module in dev.iop.
void DtBackend::note_pipe_change(dt_iop_module_t *module) {
  // Any edit outside the dehaze pair invalidates the cached neutral-mean
  // reference the dehaze cast corrector drives toward (see set_dehaze()):
  // exposure/WB/contrast changes move the channel means the corrector would
  // otherwise treat as dehaze-induced cast and counteract on the next dehaze
  // move. Re-measured lazily on the next non-neutral set_dehaze().
  if(module) {
    _dehaze_ambient = 0.0f;
  }

  // two distinct modules before one render cannot be expressed as TOP_CHANGED:
  // synch_top only re-commits the last history item, silently skipping the
  // earlier one, which is exactly the stale-pixel failure this must avoid.
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

// Applies any pending change to both pipes. See the note above on
// note_pipe_change(): the blanket dt_dev_pixelpipe_synch_all() that used to run
// before every render reset every piece hash and replayed the whole history,
// discarding the pixelpipe cache and making per-render cost grow with history
// length. An ordinary single-module edit now goes through darktable's own
// incremental dispatch instead: dt_dev_pixelpipe_synch_top() re-commits only the
// top history item (the module the setter just touched), so every upstream cache
// line survives and only the changed node and its derivatives reprocess. A
// multi-module batch (or a module whose enabled state flips) still falls back to
// a full replay, which is the only correct choice there.
//
// Both pipes need the same change applied: they have separate node lists and
// caches, so syncing only the pipe about to render would leave the other serving
// stale pixels on its next run. synch_top/synch_all are per-pipe and read only
// dev->history, so calling them once per pipe is safe.
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

// Dispatches pending changes then refreshes the FULL pipe's native dims. Note:
// dt_dev_pixelpipe_get_dimensions() is scale-independent -- it always reports the
// pipe's native (scale=1.0) processed_width/processed_height regardless of what
// scale process() is later called with (imageio.c:1251-1253 calls it once, before
// picking any scale) -- so caching native_width/native_height here is safe to
// reuse across repeated renders.
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

// Same as refresh_native_dimensions() but for the preview pipe. The dispatch it
// triggers is shared, so a render_preview() followed by a render_view() in the
// same cycle only re-syncs each pipe once (the second dispatch sees no pending
// change and returns immediately).
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
// render_preview(): darktable's own darkroom scale/ROI math,
// source/src/develop/develop.c:874-890, verbatim:
//   scale = zoom_scale * ppd;                 // ppd (HiDPI) fixed at 1.0 here
//   pipe_width  = scale * pipe->processed_width;
//   pipe_height = scale * pipe->processed_height;
//   wd = MIN(window_width,  pipe_width);      // clip render region to viewport
//   ht = MIN(window_height, pipe_height);
//   x  = CLAMP(pipe_width  * (.5 + zoom_x) - wd/2, 0, pipe_width  - wd);
//   y  = CLAMP(pipe_height * (.5 + zoom_y) - ht/2, 0, pipe_height - ht);
//   dt_dev_pixelpipe_process(pipe, dev, x, y, wd, ht, scale, devid);
// center_x/center_y are develop.c's zoom_x/zoom_y, range [-0.5, 0.5], (0,0) =
// centered. When scale <= fit-scale, pipe_w/pipe_h <= viewport, so wd=pipe_w,
// x=0 (whole image renders). When scale > fit-scale (e.g. 100% on a large
// image), only a viewport-sized ROI renders, positioned by center_x/center_y.
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

  // pipe_w/pipe_h = scale * native dims (develop.c:875-876).
  const int pipe_w = std::max(1, (int)std::lround(scale * native_w));
  const int pipe_h = std::max(1, (int)std::lround(scale * native_h));

  // wd/ht = MIN(viewport, pipe_dim) (develop.c:877-878): never render more
  // than either the viewport or the full scaled image, whichever is smaller.
  const int wd = std::min(viewport_w, pipe_w);
  const int ht = std::min(viewport_h, pipe_h);

  // x/y = CLAMP(pipe_dim*(.5+center) - half_viewport, 0, pipe_dim - viewport)
  // (develop.c:879-882). When wd==pipe_w (fit or smaller), pipe_w-wd==0 so
  // the clamp forces x=0 regardless of center_x -- panning is a no-op
  // whenever the image already fits, exactly as it should be.
  const long x_hi = (long)(pipe_w - wd);
  const long y_hi = (long)(pipe_h - ht);
  const int x = (int)std::clamp(std::lround((double)pipe_w * (0.5 + center_x) - (double)wd / 2.0),
                                 (long)0, x_hi);
  const int y = (int)std::clamp(std::lround((double)pipe_h * (0.5 + center_y) - (double)ht / 2.0),
                                 (long)0, y_hi);

  // 8-bit/gamma display path (as process_fit() used), not the float
  // _no_gamma() path -- simplest for a PoC preview.
  dt_dev_pixelpipe_process(p, &dev, x, y, wd, ht, (float)scale, DT_DEVICE_NONE);

  // Lock backbuf_mutex around the read, mirroring darktable's own display
  // path. dtpthread.h (source/src/common/dtpthread.h) declares
  // dt_pthread_mutex_lock()/dt_pthread_mutex_unlock() in both release and
  // _DEBUG builds.
  dt_pthread_mutex_lock(&p->backbuf_mutex);

  uint8_t *backbuf = p->backbuf;
  if(!backbuf) {
    dt_pthread_mutex_unlock(&p->backbuf_mutex);
    UtilityFunctions::printerr("DtBackend::render_pipe_roi: pipe.backbuf is NULL (no valid output buffer)");
    return out;
  }

  // Size the copy/swap loop to wd * ht (the ROI just rendered), NOT
  // native_w/native_h or pipe_w/pipe_h -- pipe.backbuf only holds wd * ht
  // pixels' worth of valid data after the process() call above.
  const int64_t pixel_count = (int64_t)wd * (int64_t)ht;
  const int64_t byte_count = pixel_count * 4;

  out.resize(byte_count);
  uint8_t *dst = out.ptrw();

  // darktable's 8-bit backbuf is BGRx-ordered (see imageio.c's byte-swap
  // code); Godot's FORMAT_RGBA8 wants R,G,B,A. Swap byte 0 <-> byte 2 per
  // pixel and force alpha to 0xFF, since darktable does not reliably write a
  // usable alpha byte here.
  //
  // Godot 4 dropped FORMAT_BGRA8 from Image::Format (the enum jumps RGB8 ->
  // RGBA8 -> RGBA4444), so there is no format we could hand the BGRx buffer
  // to unconverted; the swap stays. Each pixel is independent, so parallelize
  // it the way darktable parallelizes its own swap (imageio.c:1437's
  // DT_OMP_FOR). _OPENMP is defined only when the build enables OpenMP (see
  // SConstruct/-Xclang -fopenmp); without it this compiles to the same serial
  // loop as before.
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

  // Dehaze post-stage: runs over the decoded RGBA8 buffer, identically on
  // preview and full pipes, so what the user sees is what set_dehaze stored.
  // A no-op at strength 0. Outside the backbuf_mutex: it mutates the copy
  // we just made, not the pipe.
  _apply_dehaze(dst, wd, ht);

  // get_width()/get_height() report the actual *rendered* (ROI) dims, not
  // the native sensor dims, so Main.gd builds its Image at the right size.
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
// preview mip's dimensions (the mip is sized to the display's physical pixels by
// init(); its dims are preview_native_width/height). There is no cap/clamp: the
// mip is itself the ceiling, and scale 1.0 renders the whole mip. `scale` is
// handed to dt_dev_pixelpipe_process() as the pipe's roi_out scale (see
// render_pipe_roi()), which darktable propagates into every module's input ROI
// via modify_roi_in (pixelpipe_hb.c:2263), so intermediate work and cache lines
// shrink with it, not just the final output. The actual rendered size is
// reported back through get_width()/get_height() (render_pipe_roi() sets them to
// the rendered ROI). If the preview pipe is unavailable this transparently falls
// back to the full pipe, so callers can always route live edits here.
PackedByteArray DtBackend::render_preview(int viewport_w, int viewport_h, double scale,
                                          double center_x, double center_y) {
  if(!refresh_preview_dimensions())
    return render_view(viewport_w, viewport_h, scale, center_x, center_y);

  return render_pipe_roi(&preview_pipe, preview_native_width, preview_native_height,
                         viewport_w, viewport_h, scale, center_x, center_y);
}

// process_fit() is now a thin wrapper around render_view(): compute the "fit"
// scale (develop.c:1066-1076's scale_fit formula, min(target/native), clamped
// to 1.0 so this proxy never upscales past native resolution, matching
// export_image()'s own upscale=FALSE) and delegate with center=(0,0). Kept as
// its own public method since Main.gd's "Fit" zoom mode calls it directly;
// there is now exactly one render implementation (render_view()) behind both
// entry points.
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
// real file on disk (JPEG/PNG/TIFF). This reuses darktable's own export
// engine -- dt_imageio_export_with_flags() -- rather than re-encoding the
// 8-bit preview backbuf, so the output is full-resolution and goes through
// the float/high-quality export pipe (the same path darktable-cli uses).
//
// Key subtlety: dt_imageio_export_with_flags() does NOT use our live `dev`.
// It stands up a *fresh* dt_develop_t from `imgid` internally
// (imageio.c:1066-1068) and replays that image's history from the library DB.
// So we must first flush our in-memory history stack to the DB with
// dt_dev_write_history_ext() before exporting. init() set
// darktable.prefer_library_history so the
// export reads that DB history rather than an (absent) XMP sidecar.
bool DtBackend::export_image(String path) {
  if(!initialized || !image_loaded) {
    UtilityFunctions::printerr("DtBackend::export_image: no image loaded");
    return false;
  }

  const CharString path_utf8 = path.utf8();
  const char *cpath = path_utf8.get_data();

  // Map the file extension to darktable's format-module plugin name. The
  // plugin names come from the module source filenames (jpeg.c -> "jpeg",
  // png.c -> "png", tiff.c -> "tiff"); the "jpg"->"jpeg" / "tif"->"tiff"
  // aliasing mirrors darktable-cli (main.c:773-783).
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

  // Persist the live edit history to the in-memory DB so the export's fresh
  // dev picks it up.
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
  // calling out). Flags mirror darktable-cli's dt_imageio_export()
  // wrapper (imageio.c:1013-1018): ignore_exif=FALSE, display_byteorder=FALSE,
  // high_quality=TRUE, upscale=FALSE, is_scaling=FALSE, scale=1.0,
  // thumbnail=FALSE, filter=NULL, copy_metadata=TRUE, export_masks=FALSE.
  // sRGB output, no storage module (storage is only used for Lua/hooks, which
  // this headless embed doesn't need -- imageio.c guards every use with
  // `if(storage)`). history_end=-1 -> apply the full DB history.
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

  // The dehaze post-stage lives outside darktable's pipe, so the exported
  // file doesn't have it yet. Apply it in place: load the exported image,
  // run the same _apply_dehaze math (with a fresh A estimated on THIS frame
  // at full resolution -- more accurate than reusing the preview-pipe A),
  // and re-encode. JPEG re-encode at quality 0.92 keeps the generational
  // loss negligible; PNG/TIFF are lossless formats so re-saving them is
  // bit-exact modulo the dehaze itself.
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

// Native (scale=1.0) processed dimensions, cached by refresh_native_dimensions()
// (called by process_fit()/render_view()). GDScript uses these to decide, for
// a chosen zoom percentage, whether the scaled image exceeds the viewport
// (and thus needs ROI/panning) without having to render first.
int DtBackend::get_native_width() {
  return native_width;
}

int DtBackend::get_native_height() {
  return native_height;
}

// Raw file dimensions, captured at load_image() time -- see raw_width/
// raw_height above. Available immediately after a successful load_image(),
// unlike get_native_width()/get_native_height() which need a render first.
int DtBackend::get_raw_width() {
  return raw_width;
}

int DtBackend::get_raw_height() {
  return raw_height;
}

// Section H: pixelpipe -> dev -> mipmap buffer -> process-wide dt_cleanup(),
// in that exact order. Guarded against double-cleanup since GDScript may
// call this from both a close handler and object destruction.
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

// Per-image teardown only: pipe -> dev -> mipmap buffer, in that order
// (mirrors cleanup()'s image_loaded branch above) but leaves `initialized`
// and `cleaned_up` untouched so the backend stays usable for a subsequent
// load_image() call. No-op if no image is currently loaded.
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
