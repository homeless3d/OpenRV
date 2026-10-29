# OpenRV on Wayland with the system Qt 6 (Fedora) -- `wayland-qt6`

This branch of the fork is **OpenRV `main` (at `cade394`, "4.0.0", VFX platform CY2026) plus seven small commits** that make
it build against the **system Fedora Qt 6.11.2 / PySide6 6.11.2 / GCC 16 / FFmpeg 8** and run **natively on Wayland**
(libadwaita client-side decorations on GNOME, desktop OpenGL 4.6) with OpenRV's **original gradient look**. This directory
(`wayland-fedora/`) holds the notes, scripts and patches around those commits; it is the only thing added to the tree.
Upstream's own `README.md` is untouched; upstream is <https://github.com/AcademySoftwareFoundation/OpenRV>.

* Fork `main` is a plain mirror of upstream `main` (never committed to). All work lives on `wayland-qt6`;
  tag `upstream-base-cade394` marks the upstream commit the commits sit on.
* The code commits are also available as plain patches: [`patches/0001..0007`](patches) and
  [`patches/source_patches.diff`](patches/source_patches.diff) (the combined diff against upstream, `wayland-fedora/` excluded).
* **Binaries are not distributed** (no releases, no rpm): the build enables FFmpeg decoders that are patent-encumbered in some
  jurisdictions (AAC, HEVC, ...) and the rpm bundles a Qt/QtWebEngine snapshot. Build it yourself, see below.

## What works / what was verified

Everything below was run on **one machine: Fedora 44, NVIDIA 615.71 (EGL/GL 4.6), Qt 6.11.2, GCC 16**, and only on
*private headless compositors and X servers*, because a real GNOME session cannot be screenshotted or driven from the build
environment. Read the "not verified" column honestly.

| Area | Verified (how) | NOT verified |
|---|---|---|
| Build against system Qt 6.11.2 + PySide6 6.11.2 + GCC 16 | full `dependencies` + `rv` build, ~2h45m, rv starts, PySide6 imports in the bundled Python 3.13 | other Qt/GCC versions, other distributions |
| Native Wayland start, libadwaita title bar | headless weston and headless mutter 50; `libadwaita.so` seen in `/proc/<pid>/maps` | real GNOME session on hardware (dock icon, portal theme, window buttons) |
| Viewport draws (patch 0002) | weston headless: jpg sequence, timeline, cache bar, HUD like the X11 build | Mesa (AMD/Intel) -- only NVIDIA exercised |
| Timeline scrub / viewport drags (0003) | headless mutter, pointer injected through `org.gnome.Mutter.RemoteDesktop`: scrub continues outside the window, release over the toolbar ends it, right-drag scrub, popups | touch / tablet input, other compositors (KWin, Sway, Weston desktop shell) |
| Menu warnings (0004) | `QObject::disconnect` warnings 222 -> 0 per menu rebuild | -- |
| Video decode (0005) | weston headless `-play`: H.264, H.264+AAC, B-frames, HEVC, ProRes 422 10-bit, mpeg4 .mov, jpg sequence; no `sendPacketToDecoder`, no crash dump | **audio output** (no sound device; AAC only decoded), hardware decode, VP9 (OpenRV always disables it) |
| Original look + window size (0006) | xcb 1024x657 == the original; Wayland 1024x655 client | HiDPI / fractional scaling |
| File dialog corner (0007) | weston headless capture: Open button complete; headless mutter: dialog still resizes from its decoration edge, click on the former notch presses Open; xcb keeps the grip | real GNOME session, HiDPI / fractional scaling |
| xcb fallback | Xvfb: starts and plays | -- |
| Web panels (QtWebEngine) | in the locally built rpm: a `QWebEngineView` created from Python rendered (`loadFinished ok=True`) | interactive use of the built-in web pages |
| Self-contained rpm | built locally (`packaging/build_rpm.sh`), unpacked privately (`rpm2cpio`, `unshare -r`), run with a scrubbed environment and with the host Qt/ICU/FFmpeg/NSS libraries hidden: 0 stray library mappings | actually installing it with `dnf`/`rpm` (scriptlets), other Fedora releases (glibc is forward-only), GTK file dialogs |

Details and the reasoning behind each item are in [`BUILD_NOTES.md`](BUILD_NOTES.md) (numbered items 1-12 + the FFmpeg and
look sections; it is the lab notebook of the first build).

## The commits (in order) and why

| # | Commit | Why (BUILD_NOTES item) |
|---|---|---|
| 0001 | **Build against system Qt 6.11.2 (PySide6 6.11.2, GCC 16) and run natively on Wayland** | Pins PySide6 6.11.2 + MD5 in `cmake/defaults/CY2026.cmake` (1); links the Qt6 `GuiPrivate` component (2); no X11 calls without an X display -- `RvDocument` NV-GLX query crashed with a null display (3); on Wayland pins the default `QSurfaceFormat` to desktop OpenGL 4.1 compatibility, otherwise QtWebEngine turns the shared EGL context into OpenGL ES 3.2 (4); does not stage Qt's `cmake/`/`pkgconfig` dirs (5); `numpy` as a wheel because numpy 2.3 from source needs the `evex512` target GCC 16 removed (6); `make_pyside6.py` uses a system libclang and the PySide6 >= 6.9 layout (7); tkinter/sqlite3 optional (8) |
| 0002 | **GLWindow: restore GL_BACK draw/read buffer on Wayland so the viewport draws** | Black viewport: the context is made current before the surface exists (surfaceless EGL), which leaves draw/read buffers at `GL_NONE` (9) |
| 0003 | **GLWindow: keep viewport drags (timeline scrub) going outside the viewport on Wayland** | Wayland has no implicit pointer grab across subsurfaces; QtWayland resets the buttons on every `wl_pointer.leave`, so the scrub stopped (10) |
| 0004 | **RvDocument: disconnect only RV's own menu connections when purging menus** | Qt 6.11 warns on wildcard `disconnect()`; 222 warnings per menu rebuild, and it also cut foreign connections (11) |
| 0005 | **FFmpeg n8.0: re-export `av_stream_get_first_dts` from libavformat** | The system `libQt6WebEngineCore` imports a symbol FFmpeg 8 removed; re-exporting it lets the bundled FFmpeg (with H.264/HEVC) serve both, so the old `LD_PRELOAD` of the decoder-less Fedora FFmpeg is gone (FFmpeg section) |
| 0006 | **Linux: use the original (legacy) gradient QSS; size window incl. menubar on Qt6** | Upstream `main` ships a new flat theme; the original gradient sheet is still in the tree (`rv_linux_dark_legacy.qss`). Qt6 sized the window while the menubar was empty (original look section) |
| 0007 | **RvFileDialog: no size grip on Wayland (it covered the Open button's corner)** | QDialog's 17x17 size grip, painted opaque by the QSS `QWidget` background rule, overlapped the Open/Save button by 9x9 px (8 px layout margins); upstream bug (also xcb and Qt 5), removed only on Wayland where the decoration resizes (12) |

Things that are **not** in the commits because they live in downloaded dependency sources / cache variables are listed in
`BUILD_NOTES.md` ("Fixes applied to downloaded dependency sources"): the Breakpad link line, `yaml-cpp` `<cstdint>`,
libdeflate/highway `-D__EVEX512__`, and the cache variable
`-DRV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE="aac;hevc;ac3;ac3_fixed;eac3;mpeg2video;vp9;prores;dnxhd;qtrle;dvvideo"`
(check the patent/licence situation of those codecs before you build or redistribute).

## Layout of this directory

| Path | What |
|---|---|
| [`BUILD_NOTES.md`](BUILD_NOTES.md) | full build recipe, every workaround and why, test beds, what is verified |
| [`MAINTENANCE.md`](MAINTENANCE.md) | **what to do when upstream OpenRV, Qt, PySide6, GCC/glibc or FFmpeg change** |
| [`env.sh`](env.sh) | environment template (`source` before `cmake`/`ninja`; paths derive from `$OQ`) |
| [`run_rv_wayland.sh`](run_rv_wayland.sh) | launcher: `QT_QPA_PLATFORM=wayland`, `QT_WAYLAND_DECORATION=adwaita` |
| [`patches/`](patches) | `git format-patch` of the seven commits + combined `source_patches.diff` (regenerated by the update script) |
| [`packaging/`](packaging) | self-contained rpm: `build_rpm.sh`, `openrv.spec`, `closure.py`, `excludelist.txt`, launcher, `.desktop`, notes, test scripts |
| [`tools/update-from-upstream.sh`](tools/update-from-upstream.sh) | replay the commits on a new upstream `main`, report conflicts per commit, regenerate `patches/` |
| [`tools/make_qt_prefix.sh`](tools/make_qt_prefix.sh) | rebuild the synthetic Qt prefix (`-DRV_DEPS_QT_LOCATION`) from Fedora's `-devel` rpms, no root |
| [`tools/testbed/`](tools/testbed) | headless weston / mutter test bed: pointer injection, event probe, test-media generators |

## Quick start (Fedora 44, no root)

```bash
# 0. workspace: any directory; the repository is checked out as $OQ/src
export OQ=$HOME/openrv-qt6 && mkdir -p $OQ && cd $OQ
git clone -b wayland-qt6 https://github.com/homeless3d/OpenRV.git src

# 1. Qt prefix from the Fedora -devel rpms (downloads ~100 MB, unpacks, installs nothing)
src/wayland-fedora/tools/make_qt_prefix.sh            # -> $OQ/sysqt6/{rpms,root,prefix}

# 2. tool environment + the extra sysroot/venv pieces described in BUILD_NOTES.md ("Environment", "Extracted rpms")
source src/wayland-fedora/env.sh

# 3. configure + build (one ninja at a time; ~2h45m, ~14 GB)
cmake -S src -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DRV_VFX_PLATFORM=CY2026 \
  -DRV_DEPS_QT_LOCATION=$QT_PREFIX \
  -DRV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE="aac;hevc;ac3;ac3_fixed;eac3;mpeg2video;vp9;prores;dnxhd;qtrle;dvvideo" \
  -DCMAKE_C_FLAGS="-D_GNU_SOURCE -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-incompatible-pointer-types" \
  -DCMAKE_CXX_FLAGS="-include cstdint -fpermissive -Wno-template-body" -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined" \
  -DCMAKE_INCLUDE_PATH=$OQ/sysroot/usr/include -DCMAKE_LIBRARY_PATH=$OQ/sysroot/usr/lib64
ninja -C build -k 0 dependencies && ninja -C build rv

# 4. run
src/wayland-fedora/run_rv_wayland.sh movie.mov
```

Honest caveat: steps 2-3 reproduce what was done by hand once; `BUILD_NOTES.md` is the authority, and expect to redo the
small manual fixes it lists (Breakpad link line, `yaml-cpp` include) the first time. Only `make_qt_prefix.sh` was re-run end
to end as a script (against the already-downloaded rpms, compared with the hand-made prefix), see `MAINTENANCE.md`.

## Optional: the rpm

`packaging/build_rpm.sh` turns `build/stage/app` into a self-contained rpm (own Qt, QtWebEngine, PySide6, ICU, FFmpeg ...;
~215 MB, installs to `/opt/openrv`). It is built **locally** and never published from here; see [`packaging/README.md`](packaging/README.md).

## Licence

OpenRV is Apache-2.0 (see `LICENSE` at the repository root); the changes here are under the same licence. Qt/PySide6 are LGPL-3.0,
FFmpeg (as configured: no GPL, no nonfree) LGPL-2.1+.
