/*
 * DtBackend implementation. Every darktable call below is cited against
 * godot-poc/DARKTABLE_API_NOTES.md (section letters refer to that file).
 */
#include "dt_backend.h"

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

extern "C" {
#include "common/dtpthread.h"
}

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cmath>

#include <dlfcn.h>

using namespace godot;

void DtBackend::_bind_methods() {
  ClassDB::bind_method(D_METHOD("init"), &DtBackend::init);
  ClassDB::bind_method(D_METHOD("load_image", "path"), &DtBackend::load_image);
  ClassDB::bind_method(D_METHOD("set_exposure", "ev"), &DtBackend::set_exposure);
  ClassDB::bind_method(D_METHOD("process_fit", "max_width", "max_height"), &DtBackend::process_fit);
  ClassDB::bind_method(D_METHOD("render_view", "viewport_w", "viewport_h", "scale", "center_x", "center_y"), &DtBackend::render_view);
  ClassDB::bind_method(D_METHOD("export_image", "path"), &DtBackend::export_image);
  ClassDB::bind_method(D_METHOD("get_width"), &DtBackend::get_width);
  ClassDB::bind_method(D_METHOD("get_height"), &DtBackend::get_height);
  ClassDB::bind_method(D_METHOD("get_native_width"), &DtBackend::get_native_width);
  ClassDB::bind_method(D_METHOD("get_native_height"), &DtBackend::get_native_height);
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
// candidates (PORTABILITY_PLAN.md 5.3.4 root-cause fix, discovered when
// fixing the DT_BACKEND_DATADIR-override bug: after that fix correctly
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

// Computes --datadir/--moduledir at runtime (see PORTABILITY_PLAN.md section
// 3.5 for the full rationale). Tried in order, cheapest/most-dev-friendly
// first:
//
//   1. DT_BACKEND_DATADIR / DT_BACKEND_MODULEDIR env vars, if BOTH are set.
//      Pure dev convenience -- lets the inner dev loop point at
//      source/build/share|lib/darktable without any bundle/dladdr logic.
//   2. Bundle-relative via Godot's own running executable path
//      (OS::get_executable_path()). Matches the exported .app layout from
//      PORTABILITY_PLAN.md section 3.3:
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
  // bundle-relative candidates below (PORTABILITY_PLAN.md 5.3.4 root-cause
  // fix): this branch used to accept the env var unconditionally, which
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
}

DtBackend::~DtBackend() {
  cleanup();
}

// Section A: dt_init(argc, argv, init_gui, load_data, L). darktable-cli
// forces --library :memory: and --conf write_sidecar_files=never onto a
// synthetic argv before calling dt_init (main.c:482-492) so it never
// touches the user's real config/db -- we mirror that here rather than
// forwarding Godot's own argv.
bool DtBackend::init() {
  if(initialized) {
    UtilityFunctions::print("DtBackend::init: already initialized");
    return true;
  }

  // --datadir/--moduledir are required here: darktable normally resolves
  // these relative to its own executable's path, but here it's loaded as a
  // shared library inside Godot.app, so that auto-detection resolves to
  // nonsense paths under Godot.app itself. These used to be compile-time
  // constants baked in by SConstruct (DT_DATADIR_PATH/DT_MODULEDIR_PATH),
  // which hardcoded this dev machine's absolute paths into the compiled
  // binary and broke as soon as the binary moved -- see
  // PORTABILITY_PLAN.md section 3. They are now computed at runtime by
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
  // argv entries are char*, not const char*, so the gchar* pointers from
  // g_build_filename()/g_strdup() plug in directly -- but they MUST stay
  // alive until after dt_init() returns (freed below), since dt_init() reads
  // argv synchronously during this call.
  char *argv[] = { arg0, arg1, arg2, arg3, arg4, arg5, datadir, arg7, moduledir,
                    arg9, configdir, arg11, cachedir, nullptr };
  int argc = 13;

  // init_gui = FALSE (headless), load_data = TRUE (custom presets, matches
  // darktable-cli's default), L = NULL (no Lua state).
  const int rc = dt_init(argc, argv, FALSE, TRUE, NULL);
  g_free(configdir);
  g_free(cachedir);
  g_free(datadir);
  g_free(moduledir);
  // DARKTABLE_API_NOTES.md section A: both darktable-cli and darktable-mcp
  // treat a *non-zero* return from dt_init() as fatal init failure, so 0
  // means success here.
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

  initialized = true;
  return true;
}

// Sections B + C + D(steps 1-4): import the file, load it into a
// dt_develop_t, then stand up a persistent pixelpipe once (not per
// process() call) so repeated set_exposure()/process() calls are cheap.
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

  // Section B, step 1: dt_film_t must be zeroed via dt_film_init() before
  // dt_film_new() -- an uninitialized images_mutex SIGKILLs on macOS. Mirror
  // dt_bridge.c (NOT main.c's inline pattern, which skips dt_film_init()).
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

  // Section B, step 2: import into the (in-memory) library DB.
  const dt_imgid_t new_imgid = dt_image_import(filmid, cpath, TRUE, FALSE);
  dt_film_cleanup(&film);

  if(!dt_is_valid_imgid(new_imgid)) {
    UtilityFunctions::printerr("DtBackend::load_image: dt_image_import() failed for path: ", path);
    return false;
  }
  imgid = new_imgid;

  // Section C: dt_dev_init(&dev, FALSE) -> dt_dev_load_image(&dev, imgid).
  dt_dev_init(&dev, FALSE);
  dt_dev_load_image(&dev, imgid);

  // Section D, step 2: pull the full-res buffer from the mipmap cache. Kept
  // alive as member state (mipmap_buf) until cleanup(), since it backs the
  // pipe's input buffer.
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

  // Section D, step 3: DARKTABLE_API_NOTES.md is explicit that
  // dt_dev_pixelpipe_init_full() does NOT exist in this checkout -- only
  // _init(), _init_preview(), _init_preview2(), _init_export(),
  // _init_thumbnail(), _init_dummy(). Use plain dt_dev_pixelpipe_init() for
  // this live/full preview pipe.
  if(!dt_dev_pixelpipe_init(&pipe)) {
    UtilityFunctions::printerr("DtBackend::load_image: dt_dev_pixelpipe_init() failed");
    dt_mipmap_cache_release(&mipmap_buf);
    std::memset(&mipmap_buf, 0, sizeof(mipmap_buf));
    dt_dev_cleanup(&dev);
    imgid = NO_IMGID;
    return false;
  }

  // Section D, step 4: set input, ICC, build nodes, sync params.
  // DT_COLORSPACE_DISPLAY / DT_INTENT_LAST mirrors dt_bridge.c's own call to
  // dt_imageio_export_with_flags() (dt_bridge.c:1205, DARKTABLE_API_NOTES.md
  // section D "_mcp_fmt_t" example) -- the concrete "sane default" the task
  // asked to find, taken directly from the working reference implementation
  // rather than guessed.
  dt_dev_pixelpipe_set_input(&pipe, &dev, (float *)mipmap_buf.buf,
                              mipmap_buf.width, mipmap_buf.height, mipmap_buf.iscale);
  dt_dev_pixelpipe_set_icc(&pipe, DT_COLORSPACE_DISPLAY, NULL, DT_INTENT_LAST);
  dt_dev_pixelpipe_create_nodes(&pipe, &dev);
  dt_dev_pixelpipe_synch_all(&pipe, &dev);

  (void)wd;
  (void)ht;

  pipe_ready = true;
  image_loaded = true;
  exposure_module = nullptr;
  native_width = 0;
  native_height = 0;
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
}

// Shared re-sync + native-dimension refresh, used by both process_fit() and
// render_view() so there is exactly one call site for
// dt_dev_pixelpipe_get_dimensions(). Note: that call is scale-independent --
// it always reports the pipe's native (scale=1.0) processed_width/
// processed_height regardless of what scale process() is later called with
// (imageio.c:1251-1253 calls it once, before picking any scale) -- so caching
// native_width/native_height here is safe to reuse across repeated renders.
bool DtBackend::refresh_native_dimensions() {
  if(!image_loaded || !pipe_ready) {
    UtilityFunctions::printerr("DtBackend::refresh_native_dimensions: no image loaded / pipe not ready");
    return false;
  }

  dt_dev_pixelpipe_synch_all(&pipe, &dev);

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

// General ROI render: implements darktable's own darkroom scale/ROI math,
// source/src/develop/develop.c:874-890, verbatim:
//   scale = zoom_scale * ppd;                 // ppd (HiDPI) fixed at 1.0 here
//   pipe_width  = scale * pipe->processed_width;
//   pipe_height = scale * pipe->processed_height;
//   wd = MIN(window_width,  pipe_width);      // clip render region to viewport
//   ht = MIN(window_height, pipe_height);
//   x  = CLAMP(pipe_width  * (.5 + zoom_x) - wd/2, 0, pipe_width  - wd);
//   y  = CLAMP(pipe_height * (.5 + zoom_y) - ht/2, 0, pipe_height - ht);
//   dt_dev_pixelpipe_process(pipe, dev, x, y, wd, ht, scale, devid);
// center_x/center_y here are develop.c's zoom_x/zoom_y, range [-0.5, 0.5],
// (0,0) = centered. When scale <= fit-scale, pipe_w/pipe_h <= viewport, so
// wd=pipe_w, x=0 (whole image renders, matches process_fit()'s old
// trivial-case behavior). When scale > fit-scale (e.g. 100% on a large
// image), only a viewport-sized ROI renders, positioned by center_x/center_y.
PackedByteArray DtBackend::render_view(int viewport_w, int viewport_h, double scale,
                                       double center_x, double center_y) {
  PackedByteArray out;

  if(!refresh_native_dimensions()) {
    return out;
  }

  if(viewport_w <= 0 || viewport_h <= 0) {
    UtilityFunctions::printerr("DtBackend::render_view: invalid viewport_w/viewport_h");
    return out;
  }
  if(scale <= 0.0) {
    UtilityFunctions::printerr("DtBackend::render_view: invalid scale");
    return out;
  }

  // pipe_w/pipe_h = scale * native dims (develop.c:875-876).
  const int pipe_w = std::max(1, (int)std::lround(scale * native_width));
  const int pipe_h = std::max(1, (int)std::lround(scale * native_height));

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
  dt_dev_pixelpipe_process(&pipe, &dev, x, y, wd, ht, (float)scale, DT_DEVICE_NONE);

  // Lock backbuf_mutex around the read, per DARKTABLE_API_NOTES.md sections
  // G/I. dtpthread.h (checked directly: source/src/common/dtpthread.h)
  // declares exactly dt_pthread_mutex_lock()/dt_pthread_mutex_unlock() (both
  // release and _DEBUG builds), so no deviation from the requested names was
  // needed here.
  dt_pthread_mutex_lock(&pipe.backbuf_mutex);

  uint8_t *backbuf = pipe.backbuf;
  if(!backbuf) {
    dt_pthread_mutex_unlock(&pipe.backbuf_mutex);
    UtilityFunctions::printerr("DtBackend::render_view: pipe.backbuf is NULL (no valid output buffer)");
    return out;
  }

  // Size the copy/swap loop to wd * ht (the ROI just rendered), NOT
  // native_width/native_height or pipe_w/pipe_h -- pipe.backbuf only holds
  // wd * ht pixels' worth of valid data after the process() call above.
  const int64_t pixel_count = (int64_t)wd * (int64_t)ht;
  const int64_t byte_count = pixel_count * 4;

  out.resize(byte_count);
  uint8_t *dst = out.ptrw();

  // darktable's 8-bit backbuf is BGRx-ordered (DARKTABLE_API_NOTES.md
  // section D/G, imageio.c's byte-swap code); Godot's FORMAT_RGBA8 wants
  // R,G,B,A. Swap byte 0 <-> byte 2 per pixel and force alpha to 0xFF, since
  // the notes explicitly warn darktable's own path does not reliably write
  // a usable alpha byte here.
  for(int64_t k = 0; k < pixel_count; ++k) {
    const uint8_t *src_px = backbuf + k * 4;
    uint8_t *dst_px = dst + k * 4;
    dst_px[0] = src_px[2]; // R <- B
    dst_px[1] = src_px[1]; // G
    dst_px[2] = src_px[0]; // B <- R
    dst_px[3] = 0xFF;      // force opaque alpha
  }

  dt_pthread_mutex_unlock(&pipe.backbuf_mutex);

  // get_width()/get_height() report the actual *rendered* (ROI) dims, not
  // the native sensor dims, so Main.gd builds its Image at the right size.
  processed_width = wd;
  processed_height = ht;

  return out;
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
// dt_dev_write_history_ext(), exactly as darktable-mcp does before it renders
// (dt_bridge.c:1299). init() set darktable.prefer_library_history so the
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

  // dt_imageio_export_with_flags() returns FALSE on SUCCESS (footgun called
  // out in dt_bridge.c:1200). Flags mirror darktable-cli's dt_imageio_export()
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

  if(image_loaded) {
    dt_dev_cleanup(&dev);
    dt_mipmap_cache_release(&mipmap_buf);
    std::memset(&mipmap_buf, 0, sizeof(mipmap_buf));
    image_loaded = false;
    imgid = NO_IMGID;
    exposure_module = nullptr;
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

  dt_dev_cleanup(&dev);
  dt_mipmap_cache_release(&mipmap_buf);
  std::memset(&mipmap_buf, 0, sizeof(mipmap_buf));
  image_loaded = false;
  imgid = NO_IMGID;
  exposure_module = nullptr;

  processed_width = 0;
  processed_height = 0;
  native_width = 0;
  native_height = 0;
}
