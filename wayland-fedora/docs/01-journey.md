# The journey: from a Rust clean-room idea to a Wayland-native OpenRV rpm

A chronological account of the decisions and pivots. Dates are commit or file dates (2026-10-28 to 2026-11-01);
anything not dated comes from the project notes and is described without a date.

## 1. Starting point: a clean-room Rust player ("rvr")

The first idea was to write a **clean-room, Rust re-implementation of the core of an RV-style player**: sequence
parsing, JPEG/PNG/EXR/DPX decoders, a look-ahead frame cache, a playback clock, a wgpu window and an egui user
interface that imitates RV's layout. It lives in its own repository (`legacy-rvr/` in the workspace, six commits on
2026-10-29, a docs-only commit on 2026-10-31). It reached a working prototype (images and H.264 video, no audio, no
colour management, no annotations) and is explicitly **paused**.

Why it was dropped: an RV-compatible player is a very large surface (colour management, sessions, stereo, scripting,
review tools, every codec). OpenRV already exists under Apache-2.0 and already has all of it. The remaining problem
was not "write a player" but "run OpenRV well on a modern Fedora desktop".

## 2. First OpenRV build: v1.0.0 with Qt 5.15.2

Before the pivot there was a build of **OpenRV v1.0.0 against Qt 5.15.2** (Qt downloaded with `aqtinstall`, Python 3.9,
PySide2 5.15.2.1, FFmpeg 4.4.3), built on Fedora 44 with GCC 16.2 and no root: about 1 h 50 min, ~10 GB, patches kept in
`legacy-qt5/patches/`. It ran on X11/XWayland. Its value was twofold: a working **reference** to compare behaviour
against (window size, look, menus) and a catalogue of GCC 16 / CMake 4 build problems. The tree was deleted later to
leave one project folder; the recipe, patches and scripts stay in `legacy-qt5/` (outside this repository).

## 3. Pivot: port OpenRV to Wayland

The goal became: a current OpenRV that runs **natively on Wayland** (GNOME on Fedora 44) with a GNOME-style window
frame instead of going through XWayland. That meant moving from Qt 5.15 to Qt 6, whose QtWayland is maintained and
has client-side decoration plugins (the project notes do not record a detailed comparison with Qt 5's Wayland support).

## 4. "Option B": newer OpenRV main against the system Qt

The project referred to the chosen route as "option B": take a **newer upstream `main`** (commit `cade394`, "4.0.0",
VFX Reference Platform CY2026) and build it against the **Fedora system Qt 6.11.2**,
so that the result follows Fedora's Qt (security fixes, QtWayland, the Adwaita decoration plugin that Fedora
packages for Qt 6) instead of a Qt downloaded from download.qt.io. The repository does not document what "option A"
was; the natural alternative is upstream's own pinned, downloaded Qt, which this route avoids. The consequences are
recorded in `BUILD_NOTES.md`:

* A **synthetic Qt prefix** (`sysqt6/prefix`). OpenRV's CMake wants one Qt prefix with headers, CMake files, tools and
  libraries; Fedora splits runtime and `-devel` packages and root was not available. `tools/make_qt_prefix.sh`
  downloads the `-devel` rpms, unpacks them without installing (`rpm2cpio | cpio`) and builds a symlink farm over the
  unpacked rpms and the installed runtime Qt, with stubs for tools that CMake imports but nothing provides.
* **PySide6 6.11.2 built from source** against that prefix (PySide6 must match Qt's minor version), with the source
  zip's MD5 pinned in `cmake/defaults/CY2026.cmake`, and a system libclang instead of the 700 MB libclang download
  (`RV_PYSIDE_SYSTEM_LLVM_DIR`, `make_pyside6.py`).
* **GCC 16 compatibility**: `evex512` target attribute removed (numpy built as a wheel, libdeflate/OpenEXR with
  `-D__EVEX512__`), `<cstdint>` missing in yaml-cpp, stricter C diagnostics demoted, Breakpad link line fixed by hand.
* Full `dependencies` + `rv` build: about 2 h 45 min, ~14 GB; ran only one `ninja` at a time because two concurrent
  runs corrupted the stage copy steps.

Result of this phase (commit `1e9bec3`, 2026-10-29): `rv` starts on native Wayland with libadwaita client-side
decorations (seen in `/proc/<pid>/maps`) and desktop OpenGL 4.6.

## 5. Fixes, one symptom at a time

With the window up, a series of Wayland and Qt 6 specific problems appeared. Each has its own entry (symptom, root
cause, fix, commit) in [02-technical-discoveries.md](02-technical-discoveries.md):

1. Black viewport (surfaceless EGL context leaves `GL_NONE` draw buffer) - `972e559`.
2. Timeline scrub stops when the pointer leaves the viewport - `4dd29f5`.
3. Qt 6.11 "wildcard disconnect" warning flood - `d675d6f`.
4. H.264 / HEVC files do not play. First worked around with `LD_PRELOAD` of the system FFmpeg, which turned out to be
   the cause (it has no H.264/HEVC decoders); replaced by a one-symbol shim in the bundled FFmpeg - `2290950`.
5. The flat default theme and a window one menubar too short - `ac12806` (original gradient look restored).
6. The Open dialog's button corner clipped by a size grip - `fe62385`.
7. A new icon from an SVG source - `b3088f4`.

Because a real GNOME session could not be screenshotted or driven from the build environment, all this was verified on
**private headless compositors** (weston for screenshots, mutter for pointer input, Xvfb for xcb); see
[05-testing-and-testbeds.md](05-testing-and-testbeds.md).

## 6. Making it reproducible and maintainable

Still on 2026-10-29: `wayland-fedora/` was added with README, build notes, environment template, the patches as
`git format-patch` files plus a combined diff (`703e5f4`, `7442787`), tools to rebuild the Qt prefix and the test beds
(`0115237`), `update-from-upstream.sh` to replay the commits on a newer upstream `main` (`d5c6ebb`), and a
maintenance checklist for new upstream / Qt / PySide6 / GCC / FFmpeg releases (`61de07e`). The fork's `main` is kept as
a plain mirror of upstream; all work stays on `wayland-qt6`, tagged `upstream-base-cade394`.

## 7. A self-contained rpm

Because the build uses the host's Qt/Chromium, a later Fedora Qt update would break the installed program. The answer
was a **self-contained rpm** installing to `/opt/openrv` with its own Qt 6.11.2, QtWebEngine, ICU, NSS, FFmpeg and
about 135 bundled host libraries, relocatable through `$ORIGIN` RUNPATHs (`1c52b62`). It was slimmed from a 347 MB /
1222 MB installed first version to 215 MB / 735 MB, and checked by running it with the host's Qt/ICU/FFmpeg libraries
hidden. Details: [04-packaging-rpm.md](04-packaging-rpm.md). The rpm is built locally and never published
(patent-encumbered decoders, bundled Chromium snapshot).

## 8. Startup optimisation

Once installed, startup felt slow (about 3 s until idle). Profiling found Chromium being started on the main thread
for a user-agent string, Mu sources recompiled on every launch, and a needless `certifi` import. Three commits
(`43cb7f1`, `0495a0f`, `bd35652`) plus an rpm-time Mu precompile halved the time. See
[03-startup-performance.md](03-startup-performance.md).

**Round 2.** More lazy imports (`opentimelineio`, `psutil`; `86f93c2`), a step 7b that precompiles every Mu module it
can (48 `.muc`, with a verification pass in a fresh process and a way to run without touching the user's session:
Xvfb or a private headless weston), and then the surprise: while checking what the installed tree still did at start,
it turned out that **almost every `.pyc` in the rpm was stale** (3932 of 3965). `rpmbuild` changes mtimes, `/opt` is
root-owned, so rv never trusted nor rewrote them and recompiled the whole Python side in memory at every launch. A
final step 7c that builds hash-checked `.pyc` cut Python import time from 749 ms to 255 ms, more than all the other
changes of the round. First frame went from 1.55 s to 0.99 s warm. Several ideas gave nothing and were dropped
(prefetching, preload thread, prelink, AJADevices skip, QSS removal, GPU flags). Two crashes found on the way
(`maya_tools` / `rvnuke_mode` `.muc` in a fresh process) were worked around by excluding those modules; the cause is
unknown.

## Decision log (short)

| Decision | Alternative | Reason |
|---|---|---|
| Port OpenRV instead of finishing the Rust player | Keep writing rvr | OpenRV already has the features; the gap was platform integration |
| System Qt 6.11.2 (option B) | Upstream's pinned, downloaded Qt | Follow Fedora's Qt and QtWayland; adwaita decoration plugin available |
| Synthetic prefix from unpacked `-devel` rpms | `sudo dnf install qt6-*-devel` | No root; nothing installed system-wide |
| Bundled FFmpeg with a one-symbol shim | `LD_PRELOAD` of system FFmpeg | System FFmpeg has no H.264/HEVC decoders |
| Original (legacy) QSS on Linux | New flat theme from upstream main | Preserve the familiar RV look |
| Self-contained rpm, built locally, not published | Depend on system Qt; publish binaries | Qt updates break a system-Qt build; patent and licence reasons |
| Keep fixes as small, separate commits and patches | One big patch | Easy to rebase on upstream and to drop when upstream fixes them |
