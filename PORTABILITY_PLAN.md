# Portability Implementation Plan: Distributable macOS `.app`

Status: planning only, no implementation done yet.
Scope of this document: get `godot-poc` from "runs on this one dev machine, from this
one absolute path" to "runs as a standalone `.app` on any Mac, from any path, with no
Homebrew installed." Linux/Windows are noted at the end for later, not implemented here.

This plan was written against the actual repo state as of the investigation (see
"Verified current state" below). Re-verify file contents before executing any phase —
if someone has touched `SConstruct` or `dt_backend.cpp` since, line numbers will drift.

---

## 1. Goal & scope

**Goal**: produce a `.app` bundle exported from the Godot project (`godot-poc/project/`)
that a user can:

- copy to `/Applications` (or anywhere else) on a Mac that has never had Homebrew,
  Xcode command line tools, darktable, or this repo installed, and
- double-click, and have it launch and run the existing PoC feature set (RAW import,
  live exposure edit through the real darktable pixelpipe, zoom/pan preview, full-res
  export) with zero manual setup.

"Portable" here means precisely:

1. No absolute, machine-specific filesystem paths baked into any binary inside the
   `.app` (no `/Users/addybhatia/...`, no `/opt/homebrew/...`).
2. No runtime dependency on Homebrew-installed libraries being present on the target
   machine — every `.dylib` the app needs ships inside the bundle.
3. The `.app` can be moved to a different path on disk (e.g. dragged from Downloads to
   Applications, or run from an external drive) without breaking.
4. None of `source/`, `godot-poc/extension/`, `godot-poc/project/` need to exist on the
   target machine — only the exported `.app`.

Out of scope for this plan: code signing / notarization for Gatekeeper (worth doing
before any real external distribution, but orthogonal to the dependency/path problem
this plan solves — note it as a follow-up in section 7), auto-update, installer/DMG
polish beyond what's needed to prove portability, Linux/Windows implementation (see
section 8, notes only).

---

## 2. Prerequisite decision: licensing (must be resolved before shipping outside the dev team)

`source/LICENSE` is confirmed **GNU GPLv3** (verified: first lines of the file read
"GNU GENERAL PUBLIC LICENSE / Version 3, 29 June 2007 / Copyright (C) 2007 Free
Software Foundation, Inc."). `docs/init_plan.md` already flagged this at spike time.

The architecture in this repo links `libdarktable.dylib` **directly and in-process**
into `libdt_backend`, which is loaded in-process into the Godot executable via
GDExtension (confirmed: `dt_backend.cpp` calls `dt_init()` directly, not over a pipe or
socket). This is materially different from spawning `darktable-cli` as a subprocess.

**This is a legal question, not an engineering one. Get real legal advice before
distributing a compiled `.app` to anyone outside the dev team.** Do not treat either
path below as settled by this document.

The two engineering paths this decision implies, so that whichever way it's resolved,
the engineering work is already scoped:

- **Path A — ship as GPL.** Distribute the whole `.app` (Godot frontend + `dt_backend`
  + `libdarktable.dylib` + all bundled deps) under GPLv3, and make complete
  corresponding source available to anyone who receives a binary, per GPLv3 §6. This is
  compatible with everything in Phases 1–3 below as-is: no architecture change needed,
  just a licensing/distribution decision (LICENSE file in the exported app, source
  offer mechanism, etc.). This is the path of least engineering effort.

- **Path B — restructure to out-of-process to avoid derivative-work status.** Convert
  the current in-process GDExtension call into darktable running as a separate process
  (e.g. a long-lived `darktable-cli`-like helper binary, or a small daemon) that the
  Godot app talks to over a pipe/socket/shared memory (IPC), rather than linking
  `libdarktable.dylib` directly into the same address space as proprietary Godot
  export code. Whether this actually avoids GPL derivative-work status for the *Godot
  frontend binary* is itself a disputed legal question (mere aggregation vs. derivative
  work turns on facts like communication protocol complexity and whether the two are
  designed to work only together) — this is exactly the kind of question to put to a
  lawyer, not resolve by architecture alone. If pursued, this is a substantial rewrite:
  the entire `dt_backend.cpp` init/import/develop/export call sequence documented in
  `docs/DARKTABLE_API_NOTES.md` would need to move behind an IPC boundary, and the
  "GTK-free core" work in Phase 4 becomes irrelevant to this specific question (the
  darktable process would still be GPL either way; the question is only about the
  Godot-side binary's status).

Recommendation for sequencing: do **not** block Phases 1–3 (path resolution, dependency
bundling, export config) on this decision — that engineering work is needed under
either path. Do block **actual distribution to anyone outside the dev team** on this
decision being resolved with real legal input.

---

## 3. Phase 1: relative path resolution

### 3.1 Verified current state (the actual problem)

Confirmed via `otool -l` on the already-built
`godot-poc/project/bin/libdt_backend.macos.template_debug.framework/libdt_backend.macos.template_debug`:

```
Load command LC_RPATH
path /Users/addybhatia/Documents/me/darktable/source/build/bin
Load command LC_RPATH
path /opt/homebrew/lib
```

The first `LC_RPATH` is this exact machine's absolute path, injected by
`godot-poc/extension/SConstruct`. The relevant lines (verified in the actual file):

```python
# extension_dir, default_dt_build_dir computed near top of SConstruct via:
extension_dir = Dir(".").srcnode().abspath
default_dt_src_dir = os.path.normpath(os.path.join(extension_dir, "..", "..", "source", "src"))
default_dt_build_dir = os.path.normpath(os.path.join(extension_dir, "..", "..", "source", "build"))

# ... later, DT_DATADIR_PATH / DT_MODULEDIR_PATH ...
env.Append(
    CPPDEFINES=[
        ("DT_DATADIR_PATH", '\\"%s\\"' % os.path.abspath(os.path.join(dt_build_dir, "share", "darktable"))),
        ("DT_MODULEDIR_PATH", '\\"%s\\"' % os.path.abspath(os.path.join(dt_build_dir, "lib", "darktable"))),
    ]
)

# ... rpath, macOS only ...
if env["platform"] == "macos":
    env.Append(LINKFLAGS=["-Wl,-rpath," + os.path.join(dt_build_dir, "bin")])
```

Three absolute paths get compiled/linked into the binary:

1. `DT_DATADIR_PATH` → e.g. `/Users/addybhatia/.../source/build/share/darktable`
2. `DT_MODULEDIR_PATH` → e.g. `/Users/addybhatia/.../source/build/lib/darktable`
3. The `-Wl,-rpath,<dt_build_dir>/bin` linker flag, needed because
   `libdarktable.dylib`'s own install name is bare `@rpath/libdarktable.dylib` (CMake
   default — confirmed via `otool -D` on `source/build/bin/libdarktable.dylib`).

These are consumed in `godot-poc/extension/src/dt_backend.cpp`, in `init()`:

```cpp
char arg5[] = "--datadir";
char arg6[] = DT_DATADIR_PATH;
char arg7[] = "--moduledir";
char arg8[] = DT_MODULEDIR_PATH;
...
const int rc = dt_init(argc, argv, FALSE, TRUE, NULL);
```

i.e. these macros become literal C string constants baked in at compile time, passed to
`dt_init()` as `argv` entries. There's no runtime override today.

Note also (already correct, no change needed): `dt_backend.cpp::init()` computes
`--configdir`/`--cachedir` **at runtime** via glib
(`g_build_filename(g_get_user_cache_dir(), "godot-darktable-poc", "config"/"cache", NULL)`),
so those two are already portable. Only datadir/moduledir/rpath are the problem.

### 3.2 Target design

Stop baking absolute paths in at SCons configure/link time. Instead:

- At **runtime**, `dt_backend.cpp` should compute datadir/moduledir relative to where
  the currently-running executable/bundle actually is on disk, using Godot's own API
  (`OS::get_executable_path()`, available from GDExtension C++ same as GDScript's
  `OS.get_executable_path()`), then pass those computed strings to `dt_init()` instead
  of the compile-time macros.
- At **link time**, stop hardcoding `-Wl,-rpath,<dt_build_dir>/bin` (a build-machine
  path) and instead set the dylib's rpath to something bundle-relative
  (`@loader_path/...` or `@executable_path/...`), matching where Phase 2 will actually
  place `libdarktable.dylib` inside the exported `.app`.

### 3.3 Concrete plan for `.app` bundle layout

Godot macOS export bundles are structured (Godot 4.x convention) roughly as:

```
MyApp.app/
  Contents/
    MacOS/MyApp                     <- main Godot executable (@executable_path here)
    Frameworks/                     <- GDExtension .framework bundles go here typically
      libdt_backend.macos.template_release.framework/
        libdt_backend.macos.template_release
    Resources/
      ...
```

For this plan, target layout (decided now so Phase 1's rpath and Phase 2's copy step
agree on a single location):

```
MyApp.app/Contents/Frameworks/libdt_backend.*.framework/libdt_backend.*
MyApp.app/Contents/Frameworks/libdarktable.dylib
MyApp.app/Contents/Frameworks/<~230 transitive .dylib deps>
MyApp.app/Contents/Resources/darktable/share/darktable/     <- datadir contents
MyApp.app/Contents/Resources/darktable/lib/darktable/        <- moduledir contents (IOP .so's etc)
```

(`Resources/darktable/...` rather than dumping directly into `Resources/` to avoid
collisions with Godot's own resource pack files.)

### 3.4 SConstruct changes (sketch, not yet applied)

Replace the `os.path.abspath(...)` CPPDEFINES block. Two viable approaches; pick one:

**Option A (preferred): don't bake paths in at all — compute both at runtime in C++.**
Remove the `DT_DATADIR_PATH`/`DT_MODULEDIR_PATH` CPPDEFINES entirely. In `dt_backend.cpp`,
compute them from the extension's own loaded-image path or from Godot's executable
path (see 3.5). This is the cleanest option since it needs zero SCons-time knowledge of
final bundle layout — it works identically whether run from the built debug tree,
from an exported `.app`, or moved anywhere.

**Option B (fallback if Option A proves awkward from GDExtension init context): bake in
paths *relative to the framework's own location*, not absolute.** Still requires
runtime resolution since `@loader_path` isn't expressible inside a C string constant —
so this collapses to the same runtime code as Option A anyway. Recommendation: just do
Option A, don't bother with a hybrid.

For the rpath linker flag, change:

```python
if env["platform"] == "macos":
    env.Append(LINKFLAGS=["-Wl,-rpath," + os.path.join(dt_build_dir, "bin")])
```

to set a bundle-relative rpath instead of (or in addition to, during the transition)
the absolute dev-build one:

```python
if env["platform"] == "macos":
    # Dev-loop rpath: lets the extension run directly from godot-poc/project/bin
    # against source/build/bin without a full export, unchanged from today.
    env.Append(LINKFLAGS=["-Wl,-rpath," + os.path.join(dt_build_dir, "bin")])
    # Bundle rpath: lets the *same* binary also find libdarktable.dylib when it has
    # been copied next to it inside an exported .app's Contents/Frameworks/.
    env.Append(LINKFLAGS=["-Wl,-rpath,@loader_path"])
```

Rationale for keeping both: a single build of `libdt_backend` can be used both for
local editor development (rpath resolves via the absolute dev path) and, once
Phase 2's dependency-bundling script copies `libdarktable.dylib` next to
`libdt_backend` inside the exported `.app`, via `@loader_path` — `dyld` tries each
`LC_RPATH` in order and uses the first one that resolves. No dual-build needed.

### 3.5 dt_backend.cpp/.h changes (sketch, not yet applied)

Remove the `DT_DATADIR_PATH`/`DT_MODULEDIR_PATH` macro usage in `init()`. Replace with
runtime computation. From C++ inside a GDExtension, `godot::OS::get_singleton()->get_executable_path()`
is the equivalent of GDScript's `OS.get_executable_path()` and returns the path to the
running Godot binary (e.g. `.../MyApp.app/Contents/MacOS/MyApp` once exported, or the
Godot editor binary during in-editor dev runs).

Sketch:

```cpp
#include <godot_cpp/classes/os.hpp>

static std::string compute_bundle_resource_dir() {
    // e.g. ".../MyApp.app/Contents/MacOS/MyApp"
    godot::String exe_path = godot::OS::get_singleton()->get_executable_path();
    // Walk up from Contents/MacOS/MyApp to Contents/, then into Resources/darktable
    godot::String contents_dir = exe_path.get_base_dir().get_base_dir(); // .../Contents
    return (contents_dir + "/Resources/darktable").utf8().get_data();
}

// in init():
std::string resource_dir = compute_bundle_resource_dir();
std::string datadir = resource_dir + "/share/darktable";
std::string moduledir = resource_dir + "/lib/darktable";
char arg6[datadir.size() + 1];
strcpy(arg6, datadir.c_str());
// ... same pattern arg8 for moduledir ...
```

Two wrinkles to handle explicitly (don't hand-wave):

1. **Editor/dev-loop case** (running from `godot-poc/project/` in the Godot editor,
   not an exported `.app`): `get_executable_path()` returns the Godot *editor*
   binary's path (e.g. `/Applications/Godot.app/Contents/MacOS/Godot`), which has no
   `Resources/darktable` next to it. Need a fallback: if
   `<computed_datadir>/darktable.png` (or any known-present datadir file) doesn't
   exist, fall back to a path relative to the extension's *own* shared library file
   (not the host executable) — obtainable via `dladdr()` on a function pointer inside
   `dt_backend`'s own translation unit (standard technique for "where am I on disk"
   from inside a loaded `.dylib`, works regardless of host process). During local dev,
   that resolves to `godot-poc/project/bin/libdt_backend.*.framework/...`; ship a copy
   of (or symlink to) `source/build/share/darktable` and `source/build/lib/darktable`
   there too, OR keep a dev-only environment-variable override
   (`DT_BACKEND_DATADIR`/`DT_BACKEND_MODULEDIR`) checked first, before both of the
   above, purely for the inner dev loop. Recommendation: implement the env var
   override first (cheapest, unblocks iterating on this plan itself), add the
   `dladdr`-based fallback when doing the actual export-and-verify work in Phase 3.
2. **Path is computed once at `init()` time**, cached in the existing `bool
   g_initialized` -style state already present in `dt_backend.cpp` — no per-call
   overhead concern.

### 3.6 Also fix the stale doc cross-reference

Several source comments (in `SConstruct`, `dt_backend.h`/`.cpp`) reference
`godot-poc/build-darktable.md`. The file actually lives at
`/Users/addybhatia/Documents/me/darktable/docs/build-darktable.md`. Fix these comments
while touching these files for the path-resolution work (cheap, avoids misleading the
next engineer).

---

## 4. Phase 2: dependency bundling

### 4.1 The scope of the problem, verified

`otool -L` on the actual built artifacts confirms:

- `source/build/bin/libdarktable.dylib`: own install name is `@rpath/libdarktable.dylib`
  (relative, fine); but its ~55 *dependencies* resolve to a mix of macOS system
  frameworks/`/usr/lib` (fine, always present) and **absolute `/opt/homebrew/opt/...`
  paths** (glib, gtk+3, gdk, pango, harfbuzz, cairo, exiv2, lensfun, openexr, jpeg-xl,
  webp, libavif, libheif, etc.) — not fine, these don't exist on a clean machine.
- `godot-poc/project/bin/libdt_backend.macos.template_debug.framework/libdt_backend.macos.template_debug`:
  same absolute-`/opt/homebrew/opt/...` dependency set (~62 entries, since it directly
  links the full `dt_link_flags.json` link_libs list: glib/gtk/cairo/pango/opencv/
  gmic/icu4c/lua/pugixml/osm-gps-map/etc.), plus `@rpath/libdarktable.dylib`.

This matches the ~230-unique-dylib transitive closure previously estimated (glib/gobject/
gio, cairo/pango/harfbuzz, gdk-pixbuf, OpenCV + OpenVINO/protobuf/abseil, OpenEXR,
exiv2, lensfun, libheif/libavif/libjxl/libwebp+codecs, gphoto2, libsecret, icu4c, lua,
gmic, GraphicsMagick, X11 libs) once you walk both binaries' full dependency trees
recursively, not just their direct dependencies.

### 4.2 Prior art to reuse: `source/packaging/macosx/3_make_hb_darktable_package.sh`

Full directory listing of `source/packaging/`:

```
packaging/
  AppImage/AppRun
  arch/README
  CMakeLists.txt
  macosx/
    1_install_hb_dependencies.sh
    2_build_hb_darktable_custom.sh
    2_build_hb_darktable_default.sh
    3_make_hb_darktable_package.sh   <- the one we adapt
    4_make_hb_darktable_dmg.sh
    BUILD_hb.txt, BUILD-ARM64.txt, BUILD.txt
    darktable.bundle, defaults.list, generate-macos-app-icon.sh
    gtk-mac-bundler-0.7.4.patch, Icons.icns, Info.plist,
    macos_install_background.png, make-app-bundle, open.desktop, settings.ini
  nix/flake.nix
  opensuse/darktable.changes, darktable.spec
  Solaris_11/...
  ubuntu/README
  windows/darktable.iss.in, README.md
```

`3_make_hb_darktable_package.sh` (353 lines) does **not** use `dylibbundler` or
`macdeployqt` — it's a hand-rolled bash pipeline using only `otool` and
`install_name_tool`. Two functions matter:

1. **`install_dependencies()`** — recursive dependency-tree walker. Runs
   `otool -L "$1" | grep compatibility | cut -d\( -f1 | sed ...` to extract each
   dependency's path, resolves any `@loader_path`/`@rpath` tokens by substituting the
   binary's own resolved absolute directory, filters to only paths under
   `$(brew --prefix)` (i.e. skips system frameworks — correct, those ship with macOS),
   copies each match into the bundle's lib directory, then **recurses into the
   just-copied file** to walk further down the tree — with a dedup check (skip if
   destination file already exists) so it terminates instead of infinitely re-walking
   shared deps.
2. **`reset_exec_path()`** — rewrites load commands *in the copied files*, not the
   originals:
   - Special-cases `libdarktable.dylib`'s own rpath specifically via
     `install_name_tool -rpath @loader_path/../lib/darktable @loader_path/../Resources/lib/darktable "$1"`.
   - For every Homebrew dependency reference found via `otool -L`, runs
     `install_name_tool -change "$hbDependency" "@executable_path/../Resources/lib/$dynDepOrigFile" "$1"`.
   - Rewrites the file's own install name/ID via `otool -D` + `install_name_tool -id "@executable_path/../Resources${1#$dtResourcesDir}" "$1"`.
   - Sweeps any leftover `@rpath/...` references (deliberately skipping
     `libdarktable.dylib` itself) and rewrites those too.
   - All `install_name_tool` invocations are best-effort (`|| true`), i.e. tolerant of
     "nothing to change" cases.
   - Also handles glib schema compilation, gdk-pixbuf loader cache rewriting (raw
     `sed` on a text cache file), gtk immodules cache rewriting, icon cache
     regeneration, lensfun data copying — all **darktable-GUI-specific concerns that
     this PoC almost certainly does not need** since it runs headless
     (`init_gui=FALSE`, confirmed in `dt_backend.cpp`). Do not port these steps.

### 4.3 What to build: `godot-poc/scripts/bundle_darktable_deps.sh` (new script, modeled on the above)

Do not modify `3_make_hb_darktable_package.sh` in place — it's darktable's own
packaging script for darktable's own standalone `.app` and should keep working
unmodified for that purpose. Write a **new script**,
`godot-poc/scripts/bundle_darktable_deps.sh`, adapted for this project's different
target layout (Godot's `Contents/Frameworks/`, not darktable's `Contents/Resources/lib/`).

Concrete responsibilities, in order:

1. **Inputs** (script arguments, all required, no defaults baked in):
   - `$1` = path to the exported `.app` (e.g. `godot-poc/project/export/darktable-godot-poc.app`)
   - `$2` = path to `source/build` (to source `libdarktable.dylib`, `share/darktable`,
     `lib/darktable` from)
2. **Locate the two seed binaries already inside the exported `.app`**:
   `Contents/Frameworks/libdt_backend.*.framework/libdt_backend.*` (copied there by
   Godot's export step per Phase 3's `export_presets.cfg` filter) and copy in
   `libdarktable.dylib` from `$2/bin/libdarktable.dylib` alongside it.
3. **Walk the transitive dependency tree** of both seed binaries using the same
   `otool -L` + recursive-copy logic as `install_dependencies()` above, adapted to:
   - destination directory: `Contents/Frameworks/` (flat, matching Godot macOS export
     convention for GDExtension dependencies) instead of darktable's
     `Contents/Resources/lib/`.
   - filter condition: copy anything resolving under `$(brew --prefix)` (same test as
     upstream) OR under `$2` itself (e.g. any other `source/build`-produced `.dylib`
     darktable's own build emits) — anything NOT under `/usr/lib`, NOT under
     `/System/Library`, and NOT already inside the `.app`.
4. **Rewrite load commands** on every copied file using the same
   `otool -L` / `install_name_tool -change` / `-id` pattern as `reset_exec_path()`,
   adapted so the rewritten target is always `@loader_path/<filename>` (all deps sit
   flat in the same `Contents/Frameworks/` directory as `libdt_backend` and
   `libdarktable.dylib`, so `@loader_path` — "next to me" — is correct and simpler
   than darktable's own `@executable_path/../Resources/lib/...` scheme, which exists
   because darktable's own layout nests libs under Resources).
5. **Copy datadir/moduledir contents**: `cp -R "$2/share/darktable" Contents/Resources/darktable/share/darktable`
   and `cp -R "$2/lib/darktable" Contents/Resources/darktable/lib/darktable` — these
   are data files and IOP module `.so`s respectively, not things `install_name_tool`
   touches, just plain recursive copies. (This is what Phase 1's runtime path
   computation in `dt_backend.cpp` will look for at `Contents/Resources/darktable/...`.)
6. **Skip everything GUI-cache-related** from the upstream script (glib schema
   compile, gdk-pixbuf loader cache, gtk immodules cache, icon cache) — these exist to
   make darktable's *own* GTK UI work standalone; this PoC never initializes GTK
   (`init_gui=FALSE`), so none of it is exercised. If Phase 4 (GTK-free core) ships
   later, GTK stops being linked at all and this concern disappears entirely; until
   then, GTK's dylib itself still needs to be *present* (Phase 2 copies it, since it's
   a link-time dependency) even though never initialized at runtime.
7. **Idempotency**: script should be safe to re-run against the same `.app` (skip
   files already correctly rewritten; a `--clean` flag that removes
   `Contents/Frameworks/*.dylib` first and starts over is fine and simpler than trying
   to detect partial-rewrite state).

### 4.4 Where this runs in the build pipeline

**Post-SCons-build, post-Godot-export, as a separate manual/CI script step** — not a
live Godot export post-process hook. Reasoning: Godot's export process itself has no
supported hook point for running arbitrary shell scripts *after* it finishes writing
the `.app` bundle (there is an "export flags" mechanism for iOS/Android but nothing
gives a clean "run this after macOS export" today without editor plugin code, which is
extra complexity this doesn't need). Concretely, the sequence is:

```
1. cd source && ./build.sh                          # builds libdarktable.dylib (existing step, unchanged)
2. cd godot-poc/extension && scons arch=arm64 target=template_release   # builds libdt_backend (existing step, unchanged)
3. Open godot-poc/project/ in Godot editor (or `godot --headless --export-release "macOS" <out>.app`)
                                                       # produces the .app with libdt_backend.framework already inside it
                                                       # (via export_presets.cfg filters — see Phase 3)
4. godot-poc/scripts/bundle_darktable_deps.sh <out>.app source/build
                                                       # NEW: copies + rewrites all darktable deps into the .app
5. (later, Phase 3.3) verify the .app launches from a different path with no Homebrew
```

If this becomes a CI pipeline later, step 4 is just another shell step after the
`godot --export-release` invocation — no architectural change needed.

---

## 5. Phase 3: Godot export configuration

### 5.1 Current state (verified)

`godot-poc/project/export_presets.cfg` **does not exist** — this project has never
been exported from the editor. This is greenfield; there is no existing config to
preserve compatibility with.

Also verified: `godot-poc/project/dt_backend.gdextension` currently has **only macOS
entries**:

```ini
[configuration]
entry_symbol = "dt_backend_library_init"
compatibility_minimum = "4.1"

[libraries]
macos.debug = "res://bin/libdt_backend.macos.template_debug.framework"
macos.release = "res://bin/libdt_backend.macos.template_release.framework"
```

No changes needed here for the macOS-only scope of this plan, beyond ensuring the
`macos.release` entry's framework actually exists (i.e. Phase 1's SCons build was run
with `target=template_release`, not just the `template_debug` currently built).

### 5.2 Steps to create `export_presets.cfg`

1. In the Godot editor, open `godot-poc/project/`, go to **Project → Export...**, add a
   **macOS** preset. This generates a base `export_presets.cfg` with standard fields
   (bundle identifier, icon, codesigning section, etc.) — fill in a bundle identifier
   like `com.lazertechnologies.darktable-godot-poc` (adjust to actual org).
2. **Runtime/binary format**: ensure "Application → Binary Format" targets the arm64
   architecture actually built in Phase 1/2 (this whole dependency tree is arm64-only
   per the existing Homebrew build — do not enable universal/x86_64 export unless the
   entire darktable dependency chain is rebuilt for x86_64 too, which is a much larger
   undertaking not in scope here).
3. **Critical step — file filter for non-resource files**: Godot's export only bundles
   things it recognizes as project resources by default; raw dylibs/frameworks in
   `bin/` need an explicit entry under **"Resources → Filters to export non-resource
   files/folders"** (a glob-pattern field in the export preset). Add:
   ```
   bin/*
   ```
   or more precisely, since only the release framework should ship in a release
   export:
   ```
   bin/libdt_backend.macos.template_release.framework/*
   ```
   Verify post-export that `Contents/Frameworks/libdt_backend.macos.template_release.framework/`
   (Godot places GDExtension frameworks under `Contents/Frameworks/` for macOS exports)
   actually contains the compiled binary, not just an empty directory — this is the
   single most common Godot export misconfiguration for native extensions.
4. **Do not** try to make Godot's export filter also pull in `libdarktable.dylib` or
   the ~230 transitive deps — that's what Phase 2's `bundle_darktable_deps.sh` does
   *after* export, deliberately kept as a separate step rather than fought into Godot's
   resource-filter mechanism (which isn't designed for "copy and rewrite install names
   on 230 files").

### 5.3 Verifying the exported `.app` is actually standalone

Concrete verification steps, in order of rigor (do all of them, cheapest first):

1. **Move test**: export to e.g. `~/Desktop/export-test/darktable-godot-poc.app`, then
   `mv` (not copy) it to a completely different path, e.g. `/tmp/moved-test.app`, and
   launch it from there (`open /tmp/moved-test.app`, or run the embedded binary
   directly for stderr visibility:
   `/tmp/moved-test.app/Contents/MacOS/<binary> 2>&1 | tee /tmp/launch.log`). If Phase
   1's runtime path computation is correct, this must work identically to launching
   from the original export path — if it doesn't, something is still resolving an
   absolute path.
2. **`otool -l` rpath audit**: for every `.dylib`/`.framework` binary inside the moved
   `.app`, run `otool -l <file> | grep -A2 LC_RPATH` and confirm no absolute paths
   appear — only `@loader_path`, `@executable_path`, or nothing.
3. **`otool -L` dependency audit** (the important one): for every single file under
   `Contents/Frameworks/`, run `otool -L <file>` and grep the output for `/opt/homebrew`
   or any bare `/Users/` path. There should be **zero** matches across the entire
   bundle. Script this as a loop rather than eyeballing 230 files by hand:
   ```bash
   find /tmp/moved-test.app/Contents/Frameworks -type f \( -name "*.dylib" -o -perm +111 \) \
     -exec sh -c 'otool -L "$1" | grep -qE "/opt/homebrew|/Users/" && echo "LEAK: $1"' _ {} \;
   ```
   A clean bundle prints nothing.
4. **Homebrew-absence test (the real proof)**: temporarily rename the Homebrew prefix
   so nothing can accidentally still resolve through it even if some rpath/dep-audit
   step above was missed —
   `sudo mv /opt/homebrew /opt/homebrew.disabled-for-test` — then repeat the launch
   test from step 1. Relaunch. If the app still runs and can import a RAW file and
   change exposure, portability is proven for real, not just by audit. Restore
   afterward: `sudo mv /opt/homebrew.disabled-for-test /opt/homebrew`. (A scratch VM or
   a spare non-dev macOS user account without Homebrew installed at all is the cleaner
   version of this test if available — see Section 7.)
5. **Functional smoke test** on the moved, Homebrew-disabled `.app`: reproduce the
   existing headless GDScript smoke test mentioned in `docs/build-darktable.md` (import
   a RAW, set EV to two different values, confirm two different-content PNG exports) —
   this is the same test already used to validate the in-editor build; running it
   against the exported, moved, Homebrew-disabled `.app` is the actual acceptance
   criterion for this whole plan.

---

## 6. Phase 4 (optional/stretch): GTK-free core

`docs/GTK-FREE-PLAN.md` exists (182 lines) and is directly relevant to shrinking
Phase 2's scope, though **not required** for Phases 1–3 to work.

Key points from that plan, summarized:

- The actual pixel-processing path this PoC exercises (pixelpipe, IOP `process()`/
  `commit_params()`, imageio codecs) is **already GTK-free** — GTK is linked as dead
  weight in the same shared library, gated at runtime by `init_gui=FALSE` (which is
  exactly the flag `dt_backend.cpp::init()` already passes to `dt_init()`).
- Four blockers identified to actually removing GTK from the build: (1) darktable's
  CMake glob-links GTK3 as a `PUBLIC` dependency of the core lib rather than scoping it
  to GUI-only translation units; (2) GTK headers leak into some core headers; (3) IOP
  and format modules each carry their own `gui_*` GTK-calling functions compiled into
  the same object as their headless `process()` functions; (4) a handful of unguarded
  GTK calls exist in nominally "core" files like `common/database.c`/`common/film.c`
  (dialog popups on certain error paths).
- Two strategies considered: **Strategy A** (add a compile-time `USE_GUI=OFF` CMake
  option, `#ifdef`-guard the ~100 IOP files' `gui_*` functions) — accepted; **Strategy
  B** (split into two libraries) — rejected, since it doesn't actually remove GTK
  symbols from the IOP `.so` files themselves, so it doesn't shrink the dependency
  closure at all, defeating the point.
- 6-phase execution plan estimated at **~4–7 focused days** total effort for the full
  Strategy A.
- Explicitly notes a **fast path**: if the goal is only unblocking this Godot PoC
  (not full GTK elimination from darktable generally), only Phases 0–2 of that plan
  are needed — and the current PoC already effectively relies on that fast path today
  (GTK is linked but never initialized).

**How this affects Phase 2 if pursued**: every GTK3/GDK/glib-related dependency (and
their onward transitive deps — pango, harfbuzz, cairo, gdk-pixbuf, atk, at-spin, etc.)
would drop out of the link step entirely, meaning `bundle_darktable_deps.sh` in Phase 2
would have dramatically fewer files to copy and rewrite (likely cutting the ~230-file
closure by more than half, since GTK's own dependency tree is one of the largest
branches). This is a real win for bundle size and build fragility, but is **not a
blocker** for shipping Phase 1–3 as planned — GTK dylibs bundle and rewrite exactly
like any other dependency via the same `install_name_tool` mechanism; they're just
extra weight, not extra complexity.

Recommendation: treat Phase 4 as a follow-on optimization after Phases 1–3 produce a
working portable `.app`, not a prerequisite. Revisit if bundle size or build fragility
(a 230-file dependency-rewrite script is more surface area for something to go subtly
wrong) becomes a real pain point.

---

## 7. Verification checklist

Concrete, ordered, repeatable:

- [ ] `source/build/bin/libdarktable.dylib` builds successfully via `source/build.sh`
      (unchanged prerequisite, not part of this plan's changes).
- [ ] `godot-poc/extension` builds via `scons arch=arm64 target=template_release`
      (and `target=template_debug` for dev) with Phase 1's SConstruct changes applied,
      no absolute paths in `CPPDEFINES` (grep the built binary's strings for the dev
      machine's home directory path — `strings <binary> | grep "/Users/"` — should
      return nothing after Phase 1).
- [ ] `otool -l` on the freshly built `libdt_backend` shows only relative
      (`@loader_path`, or the intentionally-kept absolute dev-loop rpath — see 3.4) —
      no bundle-breaking absolute paths reach the *exported* copy (verified after
      Phase 2's rewrite, not on the raw SCons output, since the dev-loop rpath is
      deliberately still absolute for local iteration).
- [ ] `export_presets.cfg` exists, macOS preset configured, "Filters to export
      non-resource files/folders" includes the `bin/libdt_backend.*.framework/*`
      pattern (Phase 3.2).
- [ ] Export produces a `.app` with `Contents/Frameworks/libdt_backend.*.framework/`
      containing the actual compiled binary (not empty).
- [ ] `bundle_darktable_deps.sh` runs against the exported `.app` without errors, and
      `Contents/Frameworks/` afterward contains `libdarktable.dylib` plus its full
      transitive dependency set (spot-check count: expect on the order of ~150-230
      files depending on whether Phase 4 was applied).
- [ ] `Contents/Resources/darktable/share/darktable/` and
      `Contents/Resources/darktable/lib/darktable/` exist and are non-empty (copied
      datadir/moduledir).
- [ ] Automated dependency-leak scan (the `find | otool -L | grep` loop in 5.3.3)
      returns zero matches for `/opt/homebrew` or `/Users/` across every file in
      `Contents/Frameworks/`.
- [ ] Move test (5.3.1): `.app` launches correctly from a path other than where it was
      exported.
- [ ] Homebrew-disabled test (5.3.4): with `/opt/homebrew` temporarily renamed away
      (or, better, run on a genuinely clean macOS user account / VM without Homebrew
      ever installed — more convincing than the rename trick, since the rename trick
      can't catch a dependency that was somehow satisfied via a *different* absolute
      path like `/usr/local` on an Intel Mac), the `.app` still launches and the
      functional smoke test (5.3.5) passes.
- [ ] Functional smoke test (5.3.5) passes on the moved, Homebrew-disabled `.app`:
      import a RAW file, set two different EV values, export both, confirm the two
      output PNGs have different byte content (mirrors the existing headless GDScript
      test already used to validate the in-editor build per `docs/build-darktable.md`).
- [ ] (Follow-up, not blocking this plan's acceptance criteria, but noted): code
      signing and notarization — an unsigned/unnotarized `.app` distributed to anyone
      outside the dev machine will hit Gatekeeper "unidentified developer" friction on
      first launch. Not solved by anything in this plan; requires an Apple Developer
      ID certificate and a `codesign --deep --sign` + `xcrun notarytool submit` pass
      over the final bundled `.app` (the existing
      `source/packaging/macosx/3_make_hb_darktable_package.sh` ends with an ad-hoc/
      cert-based `codesign --deep` call worth reading for reference, but this is a
      distinct step from dependency bundling and should be scoped separately, likely
      alongside resolving the GPL question in Section 2 since both gate real external
      distribution).

---

## 8. Cross-platform notes (not current priority — notes for later)

Verified from `source/packaging/`: darktable's own packaging effort is overwhelmingly
macOS-focused. Actual contents for other platforms:

- **Linux**: `packaging/AppImage/AppRun` (a single AppImage entrypoint stub, not a
  dependency-bundling script), `packaging/ubuntu/README` (points at standard Debian
  packaging, not custom), `packaging/opensuse/darktable.spec` +
  `darktable.changes` (RPM spec, relies on system package manager to resolve deps, not
  bundling), `packaging/arch/README` (points at the AUR). **No custom dependency-tree-
  walking/rewriting script exists for Linux** analogous to `3_make_hb_darktable_package.sh`
  — there's nothing to directly adapt the way Phase 2 adapts the macOS script.
- **Windows**: `packaging/windows/darktable.iss.in` (an Inno Setup installer script
  template) + `README.md`. This assumes darktable is already built and its DLLs
  collected by the build process (e.g. via MSYS2/MinGW's own dependency resolution);
  there's no darktable-authored equivalent of "walk the PE import table and rewrite
  paths" here either. **No precedent to adapt for Windows.**

What would actually differ, for whenever this is picked up:

**Linux**: ELF binaries use `RPATH`/`RUNPATH` (readable/writable via `patchelf
--set-rpath`, or `chrpath`) instead of Mach-O `LC_RPATH`/`install_name_tool`. Discovery
of the dependency tree would use `ldd` (or better, `readelf -d` to avoid `ldd`'s
"actually execute the loader" behavior on untrusted binaries) instead of `otool -L`.
Distribution shape would most naturally be an AppImage (bundles a full filesystem
subtree + a `AppRun` entrypoint that sets `LD_LIBRARY_PATH` before exec'ing the real
binary — much coarser-grained than macOS's per-file rpath rewriting; the darktable
`AppRun` stub already present is a reasonable model for this) rather than trying to
replicate macOS's precise per-dylib `install_name_tool`-style rewriting, since Linux's
`LD_LIBRARY_PATH`/`RPATH` model makes "just bundle everything and point RUNPATH/
LD_LIBRARY_PATH at a bundle-relative lib dir" simpler than doing 230 individual
rewrites. `patchelf --set-rpath '$ORIGIN/../lib'` (the `$ORIGIN` token is ELF's
equivalent of `@loader_path`) is the direct tool-level analog of Phase 2's
`install_name_tool -change` step.

**Windows**: PE/DLL search order is fundamentally different (no rpath concept at all;
DLLs are resolved by searching the directory containing the `.exe`, then a fixed system
search order, then `PATH`) — the practical consequence is that "bundling" on Windows
usually just means **copying every dependency DLL into the same directory as the
`.exe`** (since that directory is always first in the search order), no path-rewriting
step analogous to `install_name_tool`/`patchelf` needed at all. The tooling precedent
to look at is Qt's `windeployqt` (walks a Qt app's dependencies and copies DLLs next to
the exe) as a *pattern* to imitate, even though this project isn't Qt-based — a
custom script using `dumpbin /dependents` (MSVC) or `objdump -p` (MinGW toolchain,
more likely relevant here since darktable's Windows builds are traditionally
MSYS2/MinGW-based per `packaging/windows/README.md`) to enumerate DLL dependencies and
copy-not-rewrite them would be the direct analog of Phase 2's script. Also worth
noting: darktable's Windows distribution has no precedent for this specific
GDExtension-in-Godot architecture at all (no prior art anywhere in `source/packaging/windows/`
resembling what this project needs) — this would be closer to a from-scratch design
than an adaptation, unlike macOS where `3_make_hb_darktable_package.sh` is directly
adaptable. Static linking (building `libdarktable` and its full dependency chain as
static libraries, producing a single self-contained `.exe` with zero runtime DLL
bundling needed) is worth evaluating as an alternative to dynamic bundling specifically
on Windows, where the dependency-search-path story is weaker than macOS/Linux — but
this is a build-system-level decision for darktable's own CMake config, out of scope
for a document about the Godot-side packaging step, and not something to decide without
first checking whether darktable's dependencies (GTK3, OpenCV, etc.) are even
practically available as static libraries on Windows via whatever package manager is
used there (vcpkg/MSYS2) — flag as a research question if/when Windows work starts, not
an answered one here.

Neither platform is being implemented now; this section exists so whoever picks up
cross-platform work later doesn't have to re-derive "what's actually in
`source/packaging/`" from scratch.
