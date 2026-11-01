# Technical discoveries

Every problem found during the port: symptom, root cause, fix, where it lives. Commit hashes are on branch
`wayland-qt6`; the numbers in parentheses are the patch files in [`../patches/`](../patches) and the item numbers in
[`../BUILD_NOTES.md`](../BUILD_NOTES.md), which holds the original lab notes. The overview table of all commits is in
[00-INDEX.md](00-INDEX.md#what-changed-vs-upstream).

Platform for all measurements: Fedora 44, NVIDIA 615.71 (EGL, desktop OpenGL 4.6), Qt 6.11.2, GCC 16, mutter 50.

| # | Topic | Commit | Primary file(s) |
|---|---|---|---|
| 1 | Build against system Qt / GCC 16 | `1e9bec3` | `cmake/defaults/CY2026.cmake`, `make_pyside6.py`, `python3.cmake`, `qt6.cmake` |
| 2 | NV-GLX query crashes without X11 | `1e9bec3` | `RvDocument.cpp` |
| 3 | OpenGL ES 3.2 context once QtWebEngine loads | `1e9bec3` | `main.cpp`, `GLView.cpp` |
| 4 | Black viewport | `972e559` | `GLWindow.cpp` |
| 5 | Timeline scrub stops outside the viewport | `4dd29f5` | `GLWindow.cpp` |
| 6 | QMenu "wildcard disconnect" warning flood | `d675d6f` | `RvDocument.cpp` |
| 7 | mp4 / H.264 / HEVC | `2290950` + cache variable | `ffmpeg.cmake`, `ffmpeg_n8.0_av_stream_get_first_dts.patch` |
| 8 | Original skin and window size | `ac12806` | `RvCommon/CMakeLists.txt`, `RvApplication.cpp` |
| 9 | Open dialog clipped button | `fe62385` | `RvFileDialog.cpp` |
| 10 | Icon | `b3088f4` | `RV.svg`, `RV.ico` |
| 11 | NV-GLX message only on xcb | `1e9bec3` | `RvDocument.cpp` |
| 12 | Crashpad handler not shipped | packaging (not a source commit) | `launcher/openrv-wrapper.sh`, `build_rpm.sh` |
| 13 | Startup time | `43cb7f1`, `0495a0f`, `bd35652` | see [03-startup-performance.md](03-startup-performance.md) |

## 1. Building against the system Qt 6.11.2 and GCC 16 (`1e9bec3`, patch 0001)

* **Symptom**: upstream's CY2026 defaults want PySide6 6.8.3 and a downloaded Qt; GCC 16 and CMake 4 reject several
  third-party sources.
* **Fixes in the commit**: PySide6 6.8.3 -> 6.11.2 with the MD5 of the `download.qt.io` zip
  (`cmake/defaults/CY2026.cmake`); find the Qt6 component `GuiPrivate` because the versionless `Qt::GuiPrivate`
  target does not exist on the system Qt (`RvCommon/CMakeLists.txt`); do not stage Qt's `cmake`/`pkgconfig` lib
  directories (they clash with other dependencies installed into `stage/app/lib`, `qt6.cmake`); `numpy` added to
  `RV_PYTHON_WHEEL_SAFE` because numpy 2.3 from source fails (highway uses the `evex512` target attribute that GCC 16
  dropped, `python3.cmake`); `make_pyside6.py` accepts a system libclang (`RV_PYSIDE_SYSTEM_LLVM_DIR`, avoids a 700 MB
  download) and the PySide6 >= 6.9 source layout; tkinter/sqlite3 imports are optional in
  `test_python_distribution.py`.
* **Not in any commit** (flags, environment, or edits to downloaded sources): `-D__EVEX512__` for libdeflate/OpenEXR,
  `<cstdint>` for yaml-cpp, the Breakpad `minidump_stackwalk` link line, the `-Wno-error=...` C flags, `-fpermissive`,
  `-Wl,--allow-shlib-undefined`. See `BUILD_NOTES.md` ("Fixes applied to downloaded dependency sources") and the table
  in `MAINTENANCE.md` section 3.

## 2. Segfault: NV-GLX query without an X11 display (`1e9bec3`)

* **Symptom**: crash at startup on Wayland.
* **Cause**: `RvDocument` calls `XQueryExtension(QX11Info::display(), "NV-GLX", ...)`; `QX11Info::display()` is null
  on Wayland.
* **Fix**: only query when `QX11Info::isPlatformX11() && QX11Info::display()`. A grep of the tree showed no other
  direct Xlib use (BUILD_NOTES item 3).

## 3. OpenGL ES 3.2 contexts once QtWebEngine is present (`1e9bec3`)

* **Symptom**: on Wayland, "unsupported version 150", "GPU lacks fragment program", basic pixel drawing.
* **Cause**: Qt's global share context (`AA_ShareOpenGLContexts`) is created from the default `QSurfaceFormat`. With
  QtWebEngine loaded, every context, including RV's viewport that shares with it, became OpenGL ES 3.2. RV asked for
  OpenGL 2.1, which EGL honours literally.
* **Fix** (Wayland only): `apps/rv/main.cpp` sets the default format to desktop OpenGL 4.1 compatibility before
  `QApplication` is created (when `QT_QPA_PLATFORM` is `wayland*`, or `WAYLAND_DISPLAY` is set and `DISPLAY` is not);
  `GLView.cpp` requests the same for the viewport. Result: GL 4.6.0 NVIDIA, fragment program available. xcb is
  unchanged.

## 4. Black viewport (`972e559`, patch 0002)

* **Symptom**: window, menus and toolbars fine, viewport black (grey when the subsurface was ARGB), no image,
  timeline or HUD.
* **Investigation**: `paintGL()` and `Session::render()` did run (gdb). `glReadPixels` of the default framebuffer at
  the end of `paintGL()` returned `[0,0,0,0]` everywhere, even alpha, which `paintGL` forces to 1;
  `glGetIntegerv(GL_DRAW_BUFFER)` returned 0 (`GL_NONE`) with no GL error. Calling `glDrawBuffer(GL_BACK)` /
  `glReadBuffer(GL_BACK)` from gdb at `paintGL` entry immediately produced pixels.
* **Root cause**: RV makes the viewport window's context current before its window surface exists
  (`QTGLVideoDevice::makeCurrent` at startup). Qt's EGL backend binds it **surfaceless**; per
  `EGL_KHR_surfaceless_context` the context's draw and read buffers are then initialised to `GL_NONE` and stay that
  way when the window surface is bound later, so every draw is discarded. GLX on xcb never starts surfaceless, which is
  why X11 worked.
* **Fix**: at the top of `GLWindow::paintGL`, on Wayland and for the default framebuffer only, if the draw buffer is
  `GL_NONE` set draw and read buffer to `GL_BACK` (`GL_FRONT` for single-buffered formats). X11 untouched.
* A tried `setAlphaBufferSize(0)` change in `GLView` was dropped as unnecessary: the grey came from the same `GL_NONE`
  buffer.

## 5. Timeline scrub stops when the pointer leaves (`4dd29f5`, patch 0003)

* **Symptom**: a drag in the viewport (the timeline scrub is one) stopped as soon as the pointer left the viewport or
  the window. On X11 the same drag continues anywhere.
* **Evidence**: private headless mutter with pointer input injected through `org.gnome.Mutter.RemoteDesktop`, plus
  `WAYLAND_DEBUG=1` and a Python event probe loaded with `-pyeval`. During a button-down the compositor does **not**
  pin pointer focus to the pressed surface: moving from the viewport subsurface to the rest of the main window sends
  `wl_pointer.leave(viewport)` + `enter(toplevel)`; leaving the window sends `leave(toplevel)` + `enter(viewport)`.
* **Root cause**: QtWayland's `Pointer::pointer_leave()` sets `mButtons = Qt::NoButton`, so every later move reached RV
  with no buttons (plus a Leave) and RV saw a plain hover. `QWindow::setMouseGrabEnabled()` is popup-only in QtWayland.
* **Fix** (Wayland only): when a button is pressed in `GLWindow`, an application-wide event filter hands the viewport
  every mouse move and the release, with the really held buttons and the position mapped with `mapFromGlobal()`, and
  drops Enter/Leave events (as Qt's xcb backend does while a button is down). It ends at the release, wherever it
  lands, or when a popup takes over.
* **Verified** in headless mutter: the scrub continues with the pointer below the window; release over the toolbar
  ends it (no stuck drag); right-drag scrub, toolbar play/stop, File menu and right-click popup behave as on xcb.
* **Note**: repaint scheduling was ruled out as the cause (`update()` -> frame callback -> `paintGL` works; RV simply
  stops requesting redraws when the frame is idle).

## 6. QMenu "wildcard disconnect" warning flood (`d675d6f`, patch 0004)

* **Symptom**: `QObject::disconnect: wildcard call disconnects from destroyed signal of QMenu::unnamed`, 222 lines on
  every menu rebuild (mode toggles, close).
* **Cause** (gdb backtrace on the warning): `RvDocument::purgeMenus` -> `disconnectActions()` called `QMenu::disconnect()`
  with no arguments. Qt 6.11 warns when a wildcard disconnect hits an object whose `destroyed()` is connected, and the
  call also cut those connections. The only connections RV makes on those menus are `aboutToShow()` -> `this`.
* **Fix**: `m->disconnect(this)`. Verified: 222 -> 0 warnings per rebuild.
* **Open point**: who else connects to the menus' `destroyed()` was not identified (not reproducible in a plain Qt
  test program).

## 7. mp4 / H.264 / HEVC (`2290950` + cache variable, patch 0005)

* **Symptom**: an H.264 `.mp4` failed with `sendPacketToDecoder failed in video stream`; MPEG-4 `.mov` worked.
* **Diagnosis**: the launcher of the time used `LD_PRELOAD` on the system FFmpeg (Fedora `ffmpeg-free` 8.1.3), so
  `/proc/<pid>/maps` showed only the system `libav*`; probing `avcodec_find_decoder_by_name` through ctypes showed the
  system library has **no h264 and no hevc** decoder (aac, prores, mpeg4, vp9, av1, dnxhd, ac3 are there). The
  preload existed because the system `libQt6WebEngineCore` imports a symbol that FFmpeg 8 removed. Comparing
  `nm -D --undefined-only libQt6WebEngineCore.so.6` with the exports of the five bundled libraries: the **only**
  missing symbol was `av_stream_get_first_dts`.
* **Fix 1** (commit): `cmake/dependencies/patch/ffmpeg_n8.0_av_stream_get_first_dts.patch`, applied from
  `ffmpeg.cmake` (FFmpeg 8 builds, non-Windows), appends `int64_t av_stream_get_first_dts(const AVStream*)` returning
  `cffstream(st)->first_dts` to `libavformat/utils.c`. The bundled libavformat now satisfies both RV and QtWebEngine,
  so the `LD_PRELOAD` was removed.
* **Fix 2** (cache variable, not in git): OpenRV disables patent-sensitive decoders by default, and `mio_ffmpeg` blocks
  more through `-D__FFMPEG_ENABLE_NON_FREE_DECODER_<name>`. Configure with
  `-DRV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE="aac;hevc;ac3;ac3_fixed;eac3;mpeg2video;vp9;prores;dnxhd;qtrle;dvvideo"`.
  Encoders are untouched; no `--enable-nonfree` / GPL. `vp9` stays unavailable because OpenRV always passes
  `--disable-parser=vp9`.
* **Verified**: H.264, H.264+AAC, B-frames, HEVC, ProRes 422 10-bit, mpeg4 `.mov` and a jpg sequence play in headless
  weston, no `sendPacketToDecoder`, no crash dump. **Not verified**: audio output, hardware decode.
* **Side effect**: the system QtWebEngine is now bound to OpenRV's FFmpeg 8.0 plus the shim; it imports only a handful
  of avcodec/avformat symbols, all present.
* The patent/licence position of the re-enabled decoders is the builder's to check.

## 8. Original skin and window size (`ac12806`, patch 0006)

* **Symptom**: upstream `main` looks flat; on Qt 6 the window came out one menubar height too short.
* **Cause (look)**: `main` ships a new flat theme as `rv_linux_dark.qss`. The original gradient sheet is still in the
  tree as `rv_linux_dark_legacy.qss`.
* **Fix (look)**: on Linux `RvCommon/CMakeLists.txt` compiles the legacy file under the symbol `rv_linux_dark`
  (Windows still uses the flat file; `-qtcss <file>` still overrides).
* **Cause (size)**: Qt 6 sizes the window inside `show()` while the menubar is still empty (size hint 0), so the
  viewport lost one menubar.
* **Fix (size)**: `RvApplication::newSessionFromFiles` grows the window to `sizeHint()` once the menus exist, only
  without `-geometry` and not fullscreen/maximised. Result: xcb 1024x657, identical to the Qt 5 build; Wayland 1024x655
  client area (menubar 21 px at 96 dpi with Adwaita Sans 10 vs 23 px under Xvfb at 100 dpi).
* **Residual**: the menubar font follows the platform theme (Sans on xcb, Adwaita Sans on GNOME).

## 9. Open dialog: clipped Open button (`fe62385`, patch 0007)

* **Symptom**: in File > Open, the bottom-right corner of the Open/Save button looked cut off (square notch).
* **Not the decoration**: the window was not clipped (QWindow 997x480 equals the widget; adwaita frame margins
  11/49/11/11).
* **Cause**: `RvFileDialog` enables `QDialog`'s size grip, a 17x17 child in the bottom-right corner raised above the
  layout. The QSS rule `QWidget { background-color: rgb(50,50,50) }` makes `QStyleSheetStyle` paint it as an opaque
  flat square (no grip glyph) and it also takes the clicks. The layout's right/bottom margins are 8 px, so it covers a
  9x9 px corner of the button. Measured with a `-pyeval` probe: grip at (980,463) 17x17, Open button right 989 /
  bottom 472.
* **Upstream bug**: the same overlap exists on xcb with Qt 6 and in the original Qt 5 build.
* **Fix**: `setSizeGripEnabled(!platformName().startsWith("wayland"))`. On Wayland the decoration / compositor already
  provides resize edges. X11 is deliberately unchanged (see [06-open-issues.md](06-open-issues.md)).
* **Verified**: weston capture shows the complete button; in headless mutter the dialog still resizes from its
  decoration edge (997x480 -> 1047x520) and a click on the former notch presses Open. The console window also has a
  grip but its Close button ends 4 px left of it (no overlap).

## 10. Icon (`b3088f4`)

The icon was redrawn as an SVG (`src/bin/apps/rv/RV.svg`, a traced vector) and `RV.ico` was regenerated from it. The
rpm derives its hicolor PNGs (16 to 512 px) and the scalable icon from the same SVG (`build_rpm.sh` step 6). Which
tool traced the artwork is not recorded in the repository.

## 11. The "NV-GLX Extension Missing" message appears only on xcb (`1e9bec3`)

The same guard as in item 2: `haveNV` defaults to true and is only cleared by an actual X11 query, so the message
about the NVIDIA GLX extension (meaningless on Wayland) is printed only when running on X11 and the extension is
really absent.

## 12. Crashpad handler not shipped; crash dumps disabled in the launcher (packaging)

* **Symptom**: with the handler removed, RV prints "Crashpad handler not found / Failed to initialize crash handler"
  on stderr and otherwise runs normally.
* **Decision**: the rpm does not ship `crashpad_handler*`, Breakpad symbols or `symbolicate_crash.sh` (size; nothing
  in the package could symbolicate a dump). The launcher exports `RV_CRASH_DUMPS_ENABLED=0` (default, overridable;
  `TwkUtil/CrashHandler.cpp` reads it) so RV does not try to start the missing handler; it prints one INFO line instead. This lives in the workspace's `packaging/launcher/openrv-wrapper.sh`; see the sync note in
  [04-packaging-rpm.md](04-packaging-rpm.md).

## 13. Smaller findings

* **Harmless messages on Wayland**: "Failed to find vkGetPhysicalDeviceWaylandPresentationSupportKHR" (bundled Vulkan
  loader) and "GBM is not supported ... Fallback to Vulkan rendering in Chromium" are benign; the rpm drops the
  bundled Vulkan loader in favour of the system one.
* **Qt plugins**: in the development tree, `build/stage/app/plugins/Qt` holds symlinks into `/usr/lib64/qt6/plugins`
  (`libadwaita.so`, `libbradient.so`, `libqwayland.so`, `wayland-egl`).
* **Qt debug output is swallowed**: RV installs its own message handler, so `QT_LOGGING_RULES` shows nothing; use gdb.
* **`rvio` needs an X display** (XWayland is fine): it segfaults in `FBOVideoDevice` without one, also in the original
  build tree.
* **Wayland `app_id`** is `com.aswf.rv` (captured with `WAYLAND_DEBUG=1`), hence the desktop file name
  `com.aswf.rv.desktop` so GNOME shows the right icon.
* **Earlier unexplained crash**: one `-play test.mp4` run exited silently (crashpad dump) while the system FFmpeg was
  preloaded; not seen again over about ten runs of six files after fix 7.
