# Contributing to Luxe

Thanks for your interest in Luxe, a Godot-powered RAW photo editor built on
darktable's image-processing engine. This document covers the essentials for
getting set up and submitting changes.

For the full architectural walkthrough (how the GDExtension bridges Godot and
darktable, the two-pipe preview/full design, the UI shell, and more), read
[`README.md`](README.md).

## Prerequisites

- macOS on Apple Silicon is the currently supported development platform.
- Godot 4.6 (the repo targets `4.6.beta3`).
- Python 3 and [SCons](https://scons.org/) (`pip install scons`).
- A C++ toolchain (Xcode Command Line Tools: `xcode-select --install`).
- A GTK-free build of darktable, checked out as a sibling `source/` directory.
  See the "Building darktable" subsection in [`README.md`](README.md).

## Setting up the build

1. Clone and build darktable as described in the README's "Building darktable"
   subsection, placing the checkout at `../source` relative to this repo (so
   `../source/build` holds `lib_darktable`).
2. Clone `godot-cpp` into `extension/godot-cpp` on the branch matching this
   repo's Godot version (the `4.5` branch), then build it:

   ```bash
   cd extension/godot-cpp
   git clone --branch 4.5 --depth 1 https://github.com/godotengine/godot-cpp .
   scons target=template_debug arch=arm64
   scons target=template_release arch=arm64
   ```

3. Build the GDExtension shim from `extension/`:

   ```bash
   cd extension
   scons arch=arm64
   scons arch=arm64 target=template_release
   ```

4. Open the Godot project at `project/project.godot` and run it, or use the
   smoke test (below).

`extension/dt_link_flags.json` is a per-machine file (gitignored) listing the
include paths, link flags, and defines for your darktable build. It is not
distributed with the source; you must construct it yourself before the
extension will compile.

## Running tests

The fast end-to-end check is the headless smoke test:

```bash
scripts/smoke_test.sh                 # auto-discovers a RAW
scripts/smoke_test.sh /path/to/x.ARW  # or pin one
```

Feature-specific smoke tests live in `project/tests/` (crop, dehaze,
blacks/whites) and can be run with `godot --headless --script`.

## Pre-commit hooks

Install the tracked git hooks once after cloning:

```bash
scripts/install-hooks.sh
```

The pre-commit hook rebuilds the GDExtension when its sources change and
aborts the commit if the build fails. Bypass it for a WIP commit with
`git commit --no-verify`.

## Submitting changes

- Keep changes focused and explain the "why" in the commit message.
- Make sure the smoke test passes and the extension builds cleanly.
- Contributions are accepted under the project's license:
  **GPL-3.0-or-later** (see [`LICENSE`](LICENSE)). By submitting a pull
  request you agree to license your contribution under those terms.
- Third-party code you introduce must be license-compatible with
  GPL-3.0-or-later (see [`NOTICE`](NOTICE)).
