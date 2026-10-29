# OpenRV (main, cade394, "4.0.0") against SYSTEM Qt 6.11.2 on Fedora 44 / Wayland

Workspace: `$OQ` (any directory; `src/` = a checkout of branch `wayland-qt6` of this fork, i.e. OpenRV main at cade394 plus the six commits
below; `patches/0001..0006` are the same commits as `git format-patch`, `patches/source_patches.diff` is the combined diff cade394..HEAD).
Commit <-> patch: 0001 build against system Qt/PySide6/GCC16 + Wayland GL/X11 fixes, 0002 GL_BACK draw buffer, 0003 viewport drags/scrub,
0004 menu disconnect warnings, 0005 FFmpeg av_stream_get_first_dts, 0006 legacy QSS + window size. (Items below mention the patch number
where they used to quote a commit hash.)
Result: `./run_rv_wayland.sh [files]` -> native Wayland, libadwaita client decoration (confirmed loaded via /proc/<pid>/maps),
desktop OpenGL 4.6 (NVIDIA), PySide6 6.11.2 in the bundled Python 3.13. Wall time ~2h45m, ~14 GB disk. VFX platform: CY2026.
No sudo, nothing installed system-wide; extra rpms were only downloaded and extracted (dnf download | rpm2cpio | cpio).

## Environment (env.sh; `source env.sh` before cmake/ninja)
- venv/ (uv, python3.11: meson pyyaml requests wheel py7zr setuptools packaging) first on PATH (cmake scripts call `python3`).
- tools/bin/nasm (copied from ../openrv-build), sysroot/ (headers/libs from rpms, see below), dl/perl (perl modules from rpms).
- CPATH, LIBRARY_PATH, CMAKE_INCLUDE_PATH, CMAKE_LIBRARY_PATH -> sysroot (env CMAKE_*_PATH is needed because ExternalProject sub-builds ignore -D).
- CMAKE_POLICY_VERSION_MINIMUM=3.5
- CFLAGS="-D__EVEX512__", CXXFLAGS="-include cstdint -D__EVEX512__"  (GCC 16: yaml-cpp needs <cstdint>; libdeflate refuses the removed `evex512` target attr)
- LLVM_INSTALL_DIR=CLANG_INSTALL_DIR=RV_PYSIDE_SYSTEM_LLVM_DIR=sysqt6/root/usr/lib64/llvm22

## Extracted rpms (sysroot/ and sysqt6/root/; all via `dnf download --arch=... --disablerepo='*' --enablerepo=fedora --enablerepo=updates`)
- sysroot: mesa-libGLU-devel, libaio/readline/ncurses-devel (old tree), mesa-compat-libOSMesa(+devel) (FindOSMesa needed by TwkGLFMesa),
  systemd-devel (libudev.h for AJA; libudev.so re-pointed to /usr/lib64/libudev.so.1).
- perl (dl/perl): IPC-Cmd Module-Load(-Conditional) Params-Check Locale-Maketext-Simple Text-Template Module-Metadata ExtUtils-MakeMaker ExtUtils-MM-Utils (OpenSSL 3.6 Configure).
- sysqt6/root: the -devel rpms from the task + qt6-qttools, qt6-linguist (real lupdate/lrelease ELF files PySide copies).

## sysqt6/prefix fixes (RV_DEPS_QT_LOCATION=sysqt6/prefix)
- lib/ is now a REAL dir holding symlinks `libQt6*.so.6`, `.so.6.11.2` -> ../lib64/..., plus `lib/cmake -> ../lib64/cmake`
  (was `lib -> lib64`; qt6.cmake copies the whole lib dir into the stage and the symlink clashed with other deps' cmake dirs).
  resources/, translations/, libexec/ are real dirs of symlinks (file(COPY) cannot duplicate a dir symlink onto an existing dir).
- share/qt6/* symlinks -> /usr/share/qt6/* (PySide6 --standalone copies share/qt6/resources).
- lib64/qt6/bin/qtpaths is a private COPY of /usr/lib64/qt6/bin/qtpaths plus qt.conf in the same dir (Prefix=sysqt6/prefix, Headers=include/qt6, ...)
  so PySide6's `--qtpaths` finds the prefix with the private headers and not /usr.
- stubs (shell scripts / empty .a, never executed) for imported-but-absent tools so CMake's import checks pass:
  lib64/qt6/libexec/{qhelpgenerator,qtattributionsscanner}, bin/{qdoc}, lib64/libQt6QmlFormat.a; DesignerComponents symlink.
  sysqt6/root/usr/{bin,lib64}: empty stubs for every file listed in LLVMExports/ClangTargets (static LLVM/clang libs, clang tools).
- LLVM dir for shiboken: root/usr/lib64/llvm22 + `lib -> lib64` + `lib64/clang/22/include -> /usr/lib/clang/22/include`; root/usr/lib64/libLLVM.so.22.1 -> system.

## Configure / build
```
source env.sh
cmake -S src -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DRV_VFX_PLATFORM=CY2026 \
  -DRV_DEPS_QT_LOCATION=$QT_PREFIX -DCMAKE_INCLUDE_PATH=$OQ/sysroot/usr/include -DCMAKE_LIBRARY_PATH=$OQ/sysroot/usr/lib64 \
  -DCMAKE_C_FLAGS="-D_GNU_SOURCE -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-incompatible-pointer-types" \
  -DCMAKE_CXX_FLAGS="-include cstdint -fpermissive -Wno-template-body" -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined"
ninja -C build -k 0 dependencies    # ~1h (PySide6 6.11.2 is ~1h+ of it)
ninja -C build rv
```
Run only ONE ninja at a time (two concurrent runs corrupted the stage copy steps early on).
Gotcha: `pgrep -f <cmd>` in wait loops matches the waiting shell itself.

## Source patches (patches/*.diff, branch wayland-qt6)
1. cmake/defaults/CY2026.cmake: PySide6 6.8.3 -> 6.11.2, MD5 3ae2b2986b78d932eb62ff72377b6ff9 (zip from download.qt.io). The Qt pin 6.8.3 is only used for the
   macOS/Windows WebEngine download; with system Qt the version is read from Qt6Core. The two pyside tools patches still apply on 6.11.2.
2. RvCommon/CMakeLists.txt: find Qt6 component `GuiPrivate` (versionless Qt::GuiPrivate is not defined otherwise on the system Qt).
3. RvDocument.cpp: NV-GLX XQueryExtension only if QX11Info::isPlatformX11() && display() (null on Wayland -> segfault). No other direct X11 use was found
   (grep of src/: only RvDocument.cpp uses Xlib; nothing else in the app touches X11).
4. GLView.cpp + apps/rv/main.cpp: ON WAYLAND ONLY. Qt's global share context (AA_ShareOpenGLContexts) is created from the default QSurfaceFormat;
   with QtWebEngine present every context (also RV's viewport, which shares with it) became OpenGL ES 3.2 -> "unsupported version 150",
   "GPU lacks fragment program", basic pixel drawing. main.cpp now sets the default format to desktop OpenGL 4.1 compatibility before QApplication
   (when QT_QPA_PLATFORM=wayland*, or WAYLAND_DISPLAY set and no DISPLAY); GLView requests the same for the viewport (RV asked for 2.1, which EGL honours literally).
   Result: GL 4.6.0 NVIDIA 615.71.09, fragment program = 1. xcb behaviour unchanged.
5. qt6.cmake: do not stage Qt's `cmake`/`pkgconfig` lib dirs (clash with other dependency installs into stage/app/lib).
6. python3.cmake: add `numpy` to RV_PYTHON_WHEEL_SAFE (numpy 2.3.0 from source fails: highway uses `evex512`, GCC 16 dropped it; PyOpenGL_accelerate's
   isolated build env pulls numpy too). NOTE: RV_PYTHON_WHEEL_SAFE is a CACHE var: `cmake -U RV_PYTHON_WHEEL_SAFE` was needed once.
7. make_pyside6.py: RV_PYSIDE_SYSTEM_LLVM_DIR skips the 700 MB libclang-19 download (uses system clang 22.1.8); handles the 6.9+ move of ApiExtractor to
   shiboken6_generator; tolerates the ShibokenHelpers (clang-only) patch not matching.
8. test_python_distribution.py: tkinter and sqlite3 imports optional (no tk/sqlite devel -> _tkinter/_sqlite3 not built).
9. GLWindow.cpp (patch 0002), ON WAYLAND ONLY: black viewport fix. Symptom: window, menus, toolbars fine, viewport black (grey when the
   subsurface was ARGB), no image/timeline/HUD; paintGL() and Session::render() DID run (gdb), but glReadPixels of the default framebuffer at the end
   of paintGL() was [0,0,0,0] everywhere -- even alpha, which paintGL forces to 1 -- and glGetIntegerv(GL_DRAW_BUFFER) was 0 (GL_NONE), err 0.
   Cause: RV makes the viewport context current before its window surface exists (QTGLVideoDevice::makeCurrent at startup); Qt's EGL backend then
   binds it surfacelessly, EGL_KHR_surfaceless_context initializes the context's draw/read buffers to GL_NONE, and they stay GL_NONE after the window
   surface is bound, so every draw is discarded. (GLX on xcb never starts surfaceless, hence X11 was fine.) Calling glDrawBuffer/glReadBuffer(GL_BACK)
   from gdb at paintGL entry immediately gave orange pixels. Fix: at the top of paintGL, if Wayland and defaultFramebufferObject()==0 and
   GL_DRAW_BUFFER==GL_NONE, set draw+read buffer to GL_BACK (GL_FRONT for single-buffer formats).
10. GLWindow.cpp (patch 0003), ON WAYLAND ONLY: timeline scrub (any viewport drag) stopped when the pointer left the viewport/window.
   Evidence (private headless mutter, input injected via its RemoteDesktop D-Bus API; WAYLAND_DEBUG + a -pyeval event probe): during the implicit
   grab mutter does NOT pin focus to the pressed surface: viewport subsurface -> rest of main window gives wl_pointer.leave(viewport) +
   enter(toplevel); leaving the window gives leave(toplevel) + enter(viewport) again (motion then arrives on the viewport with out-of-bounds
   coords). QtWayland's Pointer::pointer_leave() does `mButtons = Qt::NoButton`, so every later move reached RV with buttons=0 (plus a Leave);
   RV's translator saw a plain hover and the scrub stopped. QWindow::setMouseGrabEnabled() is popup-only in QtWayland ("This plugin supports
   grabbing the mouse only for popup windows"). Fix: on a press in GLWindow (Wayland only), a qApp event filter, until the release, re-targets
   MouseMove/MouseButtonRelease from any window to the GLWindow with the really-held buttons and mapFromGlobal() position, drops Enter/Leave (as
   Qt xcb does while a button is down), and ends at the release wherever it lands or when a popup becomes active. Verified in mutter: scrub
   continues outside the window (frames 12->15->13 with the pointer below the window), release over the toolbar ends it (no stuck drag),
   toolbar play/stop, File menu, right-click popup and right-drag scrub behave as on xcb/Xvfb.
11. RvDocument.cpp (patch 0004), all platforms: "QObject::disconnect: wildcard call disconnects from destroyed signal of QMenu::unnamed"
   flood (222 lines per menu rebuild: on close and on every mode toggle, RvDocument::purgeMenus <- mergeMenu <- CommandsModule::deactivateMode).
   Source (gdb backtrace on the qWarning): RvDocument::disconnectActions() calling QMenu::disconnect() with no arguments. Qt 6.11 warns when a
   wildcard disconnect (no receiver) hits an object whose destroyed() is connected (qobject.cpp QMetaObjectPrivate::disconnect), and that call
   also cut those connections. RV's own connections on those menus are only aboutToShow() -> RvDocument, so it now calls m->disconnect(this).
   (Who else connects to the menus' destroyed() was not identified: not reproducible in a plain Qt test program.) Verified: 222 -> 0 warnings.
   Repaint scheduling on Wayland was NOT the problem: update() -> QWaylandWindow::requestUpdate -> frame callback -> paintGL works; RV simply stops
   requesting redraws once the frame is idle. A tried GLView change (setAlphaBufferSize(0) on Wayland) turned out to be unnecessary (the grey came from
   the same GL_NONE draw buffer: the alpha=1 clear never reached the surface) and was dropped; the viewport format is the same as on X11.

## Fixes applied to downloaded dependency sources / build dirs (NOT in diffs; redo if build/ is wiped)
- Breakpad 2024.02.16: minidump_stackwalk/microdump_stackwalk fail to link (vtable FastSourceLineResolver::Module). In build/RV_DEPS_BREAKPAD/build:
  `make src/processor/fast_source_line_resolver.o; make -j12 LIBS=$PWD/src/processor/fast_source_line_resolver.o`, then ninja's plain `make` is a no-op.
- OCIO ext yaml-cpp: `#include <cstdint>` prepended to build/RV_DEPS_OCIO/build/ext/build/yaml-cpp/src/yaml-cpp_install/src/emitterutils.cpp.
- OpenEXR 3.4.3/libdeflate: handled by CFLAGS=-D__EVEX512__ (needs a fresh OpenEXR build dir).
- After deleting an ExternalProject build dir also delete its stamps (build/cmake/dependencies/RV_DEPS_X-prefix/src/RV_DEPS_X-stamp/*) and re-run cmake
  (the `_rv_initial_cache.cmake` is written at configure time).
- PySide6 setup.py 'install' (--standalone) failed twice on read-only copied dirs in build/_deps/rv_deps_pyside6-src/build/venv/package*: `chmod -R u+w` them.
- boost/glew/etc: CY2026 pulls current versions (Boost 1.88, GLEW 2.3.1, ...) - no old-tree GLEW/Boost workarounds were needed.

## Runtime
- run_rv_wayland.sh: QT_QPA_PLATFORM=wayland, QT_WAYLAND_DECORATION=adwaita. NO LD_PRELOAD any more (see "FFmpeg" below).
- Linking rvio/rvio_sw needed -Wl,--allow-shlib-undefined for the same WebEngine/FFmpeg symbol (CMAKE_EXE_LINKER_FLAGS above).
- Qt plugins come from /usr/lib64/qt6/plugins via symlinks in build/stage/app/plugins/Qt (libadwaita.so, libbradient.so, libqwayland.so, wayland-egl).
- Harmless on Wayland: "Failed to find vkGetPhysicalDeviceWaylandPresentationSupportKHR" (bundled Vulkan loader), "GBM is not supported ... Fallback to Vulkan rendering in Chromium".
  (The QMenu wildcard-disconnect flood is fixed, see 11.)
- Wayland test bed (GNOME cannot be screenshotted): `XDG_RUNTIME_DIR=/run/user/$(id -u) weston --backend=headless --renderer=gl --width=1280 --height=800
  --socket=wl-test &`, run rv with WAYLAND_DISPLAY=wl-test, capture with `WAYLAND_DISPLAY=wl-test weston-screenshooter` (PNG is upside down:
  `magick f.png -flip out.png`). Flaky: weston-screenshooter sometimes hangs forever (even after the client exits) -> restart weston (kill by pid).
  It reproduced the black viewport exactly. Qt debug output (QT_LOGGING_RULES) is swallowed by RV's message handler; use gdb instead
  (run stage/app/bin/rv.bin with RV_HOME, LD_LIBRARY_PATH=stage/app/lib and the LD_PRELOAD set via `set environment` inside gdb).
- Verified on Wayland (weston headless, after fix 9): jpg sequence image + timeline/cache bar + bottom toolbar drawn like the X11 build; `-play`
  advances at 24 fps and loops; .mov (mpeg4) plays cleanly. (H.264 .mp4 failed back then because of the LD_PRELOAD, fixed, see "FFmpeg".)
- Input test bed (mutter = the real GNOME compositor, private everything): `dbus-run-session -- mutter --headless --wayland --no-x11
  --wayland-display=wl-mut --virtual-monitor 1280x800` (XDG_RUNTIME_DIR=/run/user/$(id -u), own session bus); drive the pointer with
  org.gnome.Mutter.RemoteDesktop CreateSession/Start/NotifyPointerMotionRelative/NotifyPointerButton on that bus (system /usr/bin/python3 + gi;
  the venv python has no gi; keep one RD session for a whole gesture: stopping it removes the seat's pointer). Relative motion is 1:1 and clamps at
  0,0, so "move -10000,-10000" homes it. Observe with a -pyeval probe writing to a file (RV routes Python stdout into its log) + WAYLAND_DEBUG=1.
  mutter 50.6 occasionally aborts (meta-cursor-xcursor.c load_cursor_from_theme assertion) -> restart it. No screenshots in this bed.
- Earlier crash: one `-play test.mp4` run on Wayland exited silently (crashpad dump e946ff55-...), from the preloaded system FFmpeg without an H.264
  decoder; not seen again with the bundled FFmpeg (no new dumps over ~10 `-play` runs of 6 files).
- Not verified: the real GNOME/mutter session after fix 9 (no way to screenshot it here), web panels (WebEngine falls back to Vulkan/software), audio,
  HiDPI/fractional scaling.

## FFmpeg (patch 0005; replaces the old LD_PRELOAD workaround)
Diagnosis (evidence):
- With the old launcher /proc/<pid>/maps showed ONLY /usr/lib64/libav{codec,format,util}.so.62/60, libsw* (Fedora ffmpeg-free 8.1.3) -- the bundled
  stage/app/lib copies were shadowed. Probing `avcodec_find_decoder_by_name` (ctypes): system lib has NO h264 and NO hevc (aac, prores, mpeg4, vp9, av1,
  dnxhd, ac3 are there); that is why an H.264 mp4 failed with "sendPacketToDecoder failed in video stream" (no decoder; mpeg4 .mov worked).
- The bundled n8.0 build (OpenRV's defaults) has h264/hevc but has the "non-free" list disabled in cmake/dependencies/ffmpeg.cmake: aac, ac3, prores,
  dnxhd, vp9, qtrle, dvvideo (patent policy), and mio_ffmpeg additionally blocks hevc/ac3/mpeg2video/prores/svq1/svq3 via the
  -D__FFMPEG_ENABLE_NON_FREE_DECODER_<name> mechanism (init.cpp).
- `nm -D --undefined-only libQt6WebEngineCore.so.6` against the exported symbols of the 5 bundled libs: the ONLY missing symbol is av_stream_get_first_dts.
Fix:
1. src/cmake/dependencies/patch/ffmpeg_n8.0_av_stream_get_first_dts.patch (applied from ffmpeg.cmake's PATCH_COMMAND, RV_FFMPEG_8 non-Windows): appends
   `int64_t av_stream_get_first_dts(const AVStream*)` returning cffstream(st)->first_dts to libavformat/utils.c (the libavformat.v script exports av*).
   Result: libavformat.so.62 exports av_stream_get_first_dts@@LIBAVFORMAT_62; the bundled libs (in stage/app/lib, found via the rv wrapper's
   LD_LIBRARY_PATH) satisfy QtWebEngine too, so rv starts without the preload and maps only the bundled FFmpeg (verified in /proc/<pid>/maps).
2. Decoders: configure with (cache var, not part of the diff)
   `-DRV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE="aac;hevc;ac3;ac3_fixed;eac3;mpeg2video;vp9;prores;dnxhd;qtrle;dvvideo"`
   (check patent/licence situation for your use; encoders untouched). Resulting bundled decoders: h264 hevc aac prores dnxhd ac3 mpeg4 av1/dav1d
   vp8 mp3 ... ; vp9 is still absent because OpenRV unconditionally does --disable-parser=vp9 (decoder not built); not pursued.
   No --enable-nonfree / GPL needed.
Rebuild FFmpeg only: `source env.sh; cmake -S src -B build -DRV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE="..."; rm -rf build/RV_DEPS_FFMPEG;
rm -f build/cmake/dependencies/RV_DEPS_FFMPEG-prefix/src/RV_DEPS_FFMPEG-stamp/RV_DEPS_FFMPEG-*; cmake -S src -B build; ninja -C build RV_DEPS_FFMPEG; ninja -C build rv`
(~3 min FFmpeg + ~5 min rv/mio_ffmpeg relink).
Verified (weston headless, `-play`, ~18 s each = many 1 s loops (scripts: tools/testbed/)): test.mp4 (H.264), h264_aac.mp4
(H.264+AAC), h264_bframes.mp4 (bf=3), hevc.mp4 (libx265), prores.mov (prores_ks 422 10-bit), test.mov (mpeg4), jpg sequence: frames advance, correct
frame numbers/colours, no "sendPacketToDecoder", no crashdump. Xvfb/xcb: h264_aac.mp4 plays. Not verified: audio output (no sound device; AAC only
demuxed/decoded), real GNOME session, hardware decode, interactive menu use after the change (only the menu bar rendering is visible in the shots).
Caveat: the system libQt6WebEngineCore is now bound to OpenRV's FFmpeg 8.0+shim (it only imports a handful of avcodec/avformat symbols, all present).

## Original look + default window size (patch 0006, patch 0006)
- Cause of the flat look: main branch ships a NEW flat theme as rv_linux_dark.qss; the original OpenRV used the gradient sheet, still in the tree as
  rv_linux_dark_legacy.qss (= the oracle's rv_linux_dark.qss plus an annotation slider block). Style is Cleanlooks->Fusion fallback in both. Linux now compiles
  the legacy file under the symbol rv_linux_dark (RvCommon/CMakeLists.txt); Windows/macOS unchanged. `-qtcss <file>` still overrides.
- Window size: oracle default 1024x657 (menubar 23 + toolbar 22 + view 1024x576 + bottom 36). Qt6 sized the window in show() while the menubar was empty (hint 0) ->
  1024x634, viewport one menubar short. RvApplication::newSessionFromFiles now grows the window to sizeHint() once the menus exist (only without -geometry, not fullscreen/maximized).
  Result: xcb 1024x657 identical to oracle; Wayland 1024x655 client (menubar 21 px at 96 dpi, Adwaita Sans 10, vs 23 px at Xvfb 100 dpi).
- Residual: menubar font follows the platform theme (Sans on xcb vs Adwaita Sans); Qt6 text rendering; display label still the monitor model.
- Test beds: weston-screenshooter needs `weston --debug`; the Qt5 oracle on weston Wayland crashes weston -> compare against the oracle on Xvfb (xcb).
