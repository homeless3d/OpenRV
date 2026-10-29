# OpenRV (Qt 6.11.2 / Wayland) as a self-contained rpm

`wayland-fedora/packaging/` turns the staged OpenRV build (`build/stage/app`, native Wayland, Qt 6.11.2) into
`wayland-fedora/packaging/out/openrv-4.0.0-0.wayland.qt6.1.fc44.x86_64.rpm`.
The package carries its own Qt 6.11.2 (QtWebEngine, plugins, PySide6, ...) and everything Qt/RV need that is not
part of the base OS, so a later Fedora with a different Qt (or a different ICU, FFmpeg, libxkbcommon, ...) cannot
break it. Only the C library, the C++ runtime and the GPU / Wayland / X11 / D-Bus / audio / font stack of the host
are used from the system (list below). Size: 215 MB rpm (zstd level 19), 735 MB installed (770 MB rpm SIZE tag), see "Slimming".

## Install / uninstall (you run these, the build never does)

    sudo dnf install ./wayland-fedora/packaging/out/openrv-4.0.0-0.wayland.qt6.1.fc44.x86_64.rpm
    rv movie.mp4            # or: openrv, or the "OpenRV" launcher in the GNOME grid
    sudo dnf remove openrv

Installs into `/opt/openrv` (+ `/usr/bin/{rv,openrv,rvio,rvls,rvpkg,rvpush}`, one `.desktop`, hicolor icons,
licenses, this file in `/usr/share/doc/openrv`). Per-user data stays in `~/.local/share/ASWF/OpenRV` and `~/.rv`.
`/usr/bin/rv` is also owned by Fedora's kernel-tools package `rv` (the kernel runtime-verification tool): the rpm
declares `Conflicts: rv`; `/usr/bin/openrv` never conflicts.

## Rebuild (no sudo, nothing installed, nothing downloaded)

    cd $OQ   # workspace containing build/stage, see ../BUILD_NOTES.md
    ./wayland-fedora/packaging/build_rpm.sh         # ~1 min; needs rpmbuild, patchelf, magick, rsync, zstd, python3

Optional environment: `STAGE=` (staged tree), `VERSION=`, `RELEASE=`, `PATCHELF=`.
The Qt/Chromium libraries are copied from the **host at build time** (`/usr/lib64`, `/usr/lib64/qt6`,
`/usr/share/qt6`). They must be the same Qt version OpenRV was built against (6.11.2); after a Fedora update that
bumps Qt, rebuild OpenRV against it first (BUILD_NOTES.md) and then re-run the script to refresh the bundled copy.
Steps of `build_rpm.sh`:

1. rsync the stage into `work/root/opt/openrv` without `*.a`, headers, breakpad symbols, test programs, the Vulkan
   loader and PySide6's private 470 MB Qt copy; delete the stage's dangling links into the host's Qt.
2. Copy the Qt plugin tree, `QtWebEngineProcess`, `.pak`/v8 snapshot, locales and translations from the host;
   write `bin/qt.conf` and `libexec/qt.conf` (relative `Prefix=..`, Plugins, Libraries, LibraryExecutables, Data,
   Translations) so Qt looks only at the bundled copies; `PySide6/Qt/{lib,libexec,resources,translations}` are links to them.
3. Replace the upstream tcsh wrappers with one POSIX `sh` launcher (`launcher/openrv-wrapper.sh`).
4. `closure.py`: ldd closure of every ELF file in the tree; every dependency that resolves outside the tree and is not
   on `excludelist.txt` is copied to `lib/<soname>` and scanned in turn; `dlopen-extras.txt` adds the NSS token modules.
   Reports: `work/bundled-libs.txt`, `work/denied-seen.txt`.
5. `patchelf --set-rpath` on every ELF file: `$ORIGIN`-relative directories of its bundled dependencies plus `lib/`.
   Nothing absolute, no reference to the build tree (the stage's RUNPATHs pointed into `build/RV_DEPS_*`).
6. Desktop file, icons (from `src/src/bin/apps/rv/RV.ico` and `RV.icns` of the OpenRV tree), `/usr/bin` links, licenses.
7. `closure.py --verify`: every NEEDED entry of every ELF must be found through its own RUNPATH inside the tree or be
   deny-listed (`work/system-libs.txt` = the runtime system list); the build fails otherwise.
8. `rpmbuild -bb openrv.spec` (the payload is prepared above; the spec only packs it).

## Slimming (nothing for debugging, testing or building is shipped)

Before: 347 MB rpm (zstd 10), 1222 MB installed. After: **215 MB rpm (zstd 19, `w19T0`, whole build 70 s), 735 MB installed**.

* `strip --strip-unneeded` on all 494 ELF files (795 MB -> 663 MB; `.dynsym` is kept, so linking/dlopen/Python modules are unaffected), done before
  patchelf. The spec still has `debug_package %{nil}`, `_build_id_links none`, `__strip /bin/true` (the strip is done by the build script).
* Removed: `symbols/` (Breakpad .sym), `crashpad_handler*` (RV only logs "Crashpad handler not found / Failed to initialize crash handler" on stderr and
  runs normally; crash dumps are simply not written), `dump_syms`, `minidump_*`, `symbolicate_crash.sh`, all `*Test` programs, `rvprof`, `makeFBIOformats`,
  `makeMovieIOformats`, `rvio_sw`, static libs, headers, cmake/pkgconfig files, Qt tools (moc, rcc, uic ...).
* Python: stdlib `test/`, idlelib, tkinter, turtledemo, ensurepip, lib2to3, `_test*`/`xx*` extension modules, pip, setuptools, wheel, Cython, meson,
  ninja, `tests` dirs, `.pyi` stubs, PySide6 docs/typesystems/scripts. `__pycache__` (compiled once at build time) is kept: it shortens startup.
* PySide6 modules nothing in RV imports (RV's Python only uses Core, Gui, Widgets, UiTools, WebEngine*): Designer, Help, Pdf, PdfWidgets,
  QuickControls2, QuickTest, SpatialAudio, Sql, WebSockets, WebEngineQuick. Their Qt libraries (Designer, Help, Sql, ...) drop out of the closure automatically (135 instead of 147 libraries copied).
* WebEngine: DevTools resources pak; locale paks except en-US, es, es-419; Qt translations except `qt_es`/`qtbase_es`.
* Runtime speed: the stage was configured `CMAKE_BUILD_TYPE=Release` with `-O3 -DNDEBUG`, no LTO and no `-g` in the flags (so nothing to strip but the symbol tables).
  A rebuild with `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON` (LTO) and `-march=x86-64-v3` could add a few percent but costs hours and portability; not done.
  The package uses linker defaults (lazy binding, no BIND_NOW), a short RUNPATH per file (only the directories that really hold its bundled dependencies,
  usually 1-2), no Qt shader/resource caches, and a launcher that is a single `sh` script ending in `exec`.
* Biggest remaining items (MB, installed): libQt6WebEngineCore 205, python3.13 stdlib+site-packages 159, plugins/Mu 33, libicudata 31,
  numpy.libs (OpenBLAS) 26, numpy 25, rv.bin 21, libavcodec 17, lib/OpenSSL 16, resources (WebEngine paks) 15; then libpython3.13 (32 MB -> 6 MB stripped),
  libQt6Gui 12, libQt6Quick 10, libQt6Widgets 9.

## What is bundled

* Qt 6.11.2: `libQt6*.so.6` copied from the host (Core, Gui, Widgets, OpenGL, WaylandClient, XcbQpa, DBus, Network, Multimedia,
  Svg, Qml/Quick, WebEngineCore/Widgets, ... as needed by rv.bin and the remaining 23 PySide6 modules). Plugins in `plugins/Qt`:
  `platforms` (wayland, xcb, offscreen, minimal), `wayland-decoration-client` (`libadwaita.so` = QAdwaitaDecorations, `libbradient.so`),
  `wayland-graphics-integration-client`, `wayland-shell-integration`, `xcbglintegrations`, `platformthemes` (xdg-desktop-portal),
  `platforminputcontexts` (compose, ibus), `iconengines`, `imageformats` (gif icns ico jpeg svg tga tiff wbmp webp), `tls`
  (openssl, certonly), `networkinformation` (glib, NetworkManager).
* QtWebEngine: `libQt6WebEngineCore`, `libexec/QtWebEngineProcess`, `resources/*.pak`, `v8_context_snapshot.bin`,
  `translations/qtwebengine_locales` (Fedora's WebEngine uses the system-style ICU, so there is no `icudtl.dat`; ICU 77 is bundled).
* From the stage itself: PySide6 6.11.2 + shiboken6, Python 3.13 (+ numpy, PyOpenGL...), OpenSSL 3 (`lib/OpenSSL`), FFmpeg n8.0
  (libavcodec/libavformat/libavutil), OpenEXR, OIIO, OCIO, Boost, ...
* Copied from Fedora because Qt/Chromium/RV link them (135 files in total with the Qt libs): ICU, NSS/NSPR (+ softokn/freebl/nssckbi,
  loaded by name), libxkbcommon(-x11), libxkbfile, the xcb-util family (icccm, image, keysyms, render, render-util, shape, util, cursor, xkb),
  libdouble-conversion, libb2, libpcre2-16, libzstd, libwebp(+demux/mux/sharpyuv), libevent, libminizip, libxml2, libxslt, libre2,
  libsnappy, 39 abseil libs, libopus/vorbis/ogg/FLAC/mpg123/lame/gsm (QtMultimedia), libopenjp2, liblcms2, libLerc, libexpat, libffi,
  libsqlite3, libtasn1, libreadline/ncurses, liblzma, libbz2, libbrotli, libaio.
* Deliberately NOT shipped: eglfs/linuxfb/vnc platforms, `generic` (evdev/libinput/tslib), `multimedia` plugins (they would load the host's
  FFmpeg/GStreamer; RV plays through its own FFmpeg), the KDE `kimg_*` image plugins, the GTK3 platform theme (drags in the GTK stack; the
  portal theme is used instead), QML import modules (`/usr/lib64/qt6/qml`: RV ships no QML applications), Qt tools, test programs,
  static libraries, headers, `rvio_sw` (needs OSMesa, which Fedora no longer ships). The stage's own Vulkan loader is dropped in
  favour of the system one (it must match the installed ICDs).

## What stays on the system, and why (`excludelist.txt`, AppImage-style)

Direct dependencies at run time (`work/system-libs.txt`, confirmed with `/proc/<pid>/maps`, see below):

| group | libraries | reason |
|---|---|---|
| glibc | ld-linux, libc, libm, libpthread | forward compatible only (a newer glibc runs older binaries); cannot be bundled |
| C++ runtime | libstdc++, libgcc_s, libgomp | the build uses the GCC 16 runtime (needs GLIBCXX/CXXABI as of Fedora 44); Mesa/NVIDIA load the system one in the same process, a bundled older copy would break them. Forward compatible |
| GPU | libGL, libGLX, libEGL, libOpenGL, libGLU, libgbm, libvulkan, libdrm, libva ... | the vendor driver (Mesa or NVIDIA, glvnd) must match kernel and hardware |
| Wayland | libwayland-client, libwayland-cursor, libwayland-egl | Qt and the EGL driver share wl_proxy/wl_display objects in one process: exactly one copy |
| X11 core | libX11, libX11-xcb, libxcb, libXau, libXext, libXfixes, libXrandr, libXcomposite, libXdamage, libXtst, libSM, libICE, libxcb-{dri3,glx,present,sync,xfixes,randr,shm} | the GLX/DRI drivers link the same ones (the other xcb-* libs are bundled) |
| IPC / services | libdbus-1, libudev, libsystemd, libselinux, glib/gobject/gio, libpcre2-8 | host daemons and GIO modules (dconf, portals) |
| audio | libasound, libpulse, libpipewire | the client must match the running sound server |
| fonts | libfontconfig, libfreetype, libharfbuzz(-subset), libgraphite2 | fontconfig reads the host's `/etc/fonts`; mixing a bundled freetype/harfbuzz with it is the classic AppImage breakage. Stable ABIs |
| misc | libproxy, libgssapi_krb5 (Qt6Network), libopenh264 | Cisco's binary alone carries the patent grant (Fedora `noopenh264` stub or Cisco's repo) |

Requires are generated by rpm from the ELF files (`AutoReq`), with everything the package carries and the interpreter paths of the
bundled scripts filtered out (`requires-exclude.regex`); `AutoProv: no`, so the bundled `libQt6*.so.6`, `libav*` ... are never advertised
as provides. This yields versioned `libc.so.6(GLIBC_2.43)`, `libstdc++.so.6(GLIBCXX_3.4.32)`, `libGL.so.1()(64bit)` ... plus explicit
`fontconfig`, `xkeyboard-config`, `shared-mime-info` (Recommends: adwaita-sans-fonts, xdg-desktop-portal, mesa-dri-drivers).

## Layout, launcher, RUNPATH

* Relocatable: the launcher derives `RV_HOME` from its own (symlink-resolved) path; every ELF file has an `$ORIGIN` RUNPATH and `qt.conf`
  is relative, so the tree also works unpacked anywhere (`rpm2cpio x.rpm | cpio -idm`, then `opt/openrv/bin/rv`). `LD_LIBRARY_PATH` is not
  used (so children such as xdg-open do not inherit it); `QT_PLUGIN_PATH`, `QT_QPA_PLATFORM_PLUGIN_PATH`, `QML2_IMPORT_PATH`,
  `QT_QPA_PLATFORMTHEME`, `PYTHONHOME`, `LD_PRELOAD` are unset by the launcher.
* `/opt/openrv/bin/<name>` (sh) execs `<name>.bin`; `/usr/bin/{rv,openrv,rvio,rvls,rvpkg,rvpush}` are symlinks to it.
  Defaults: `QT_QPA_PLATFORM=wayland;xcb` when `WAYLAND_DISPLAY` or `$XDG_RUNTIME_DIR/wayland-0` exists, `xcb` otherwise (export it to
  override), `QT_WAYLAND_DECORATION=adwaita`; like upstream's wrapper, `rv` unsets `LANG`.
* Desktop: `com.aswf.rv.desktop`. RV's Wayland `xdg_toplevel.set_app_id` is `com.aswf.rv` (captured with `WAYLAND_DEBUG=1`,
  local capture), so file name and `StartupWMClass` match it and GNOME shows the `openrv` icon in the dock. `%post/%postun`
  refresh the desktop/icon caches only if the tools exist and never fail.

## Verification performed (logs, /proc maps and screenshots were captured locally; they are not part of the repository)

Run on the rpm built here, extracted privately (`rpm2cpio | cpio`; also `rpm --root` inside `unshare -r`), with a scrubbed environment
(`env -i HOME XDG_RUNTIME_DIR WAYLAND_DISPLAY [DISPLAY]`) on private compositors (weston headless, Xvfb); the real GNOME session was not used.

* `test/smoke.sh` runs rv, records `/proc/<pid>/maps` of rv.bin and the QtWebEngineProcess children and takes a screenshot;
  `test/classify_maps.py` sorts every mapped path outside the package into deny-listed system lib / private dependency of such a lib /
  GPU driver payload / data; anything else is a violation (exit 1). Result: 0 violations; no host libQt6*, libav*, libicu*, nss, xkbcommon ...
* `test/hide_system_libs.sh` (unprivileged user+mount namespace): `/usr/lib64` becomes a symlink farm without any host Qt6, ICU, FFmpeg,
  NSS, xkbcommon, xcb-util, webp, abseil ... and `/usr/lib64/qt6`; rv still starts and plays (local capture).
* Wayland: H.264 mp4 (`-play`), jpg sequence, a QWebEngineView created from Python (renders, `loadFinished ok=True`, bundled QtWebEngineProcess
  children), and the xcb fallback on Xvfb (no Wayland).
  `libadwaita.so` is mapped from `plugins/Qt/wayland-decoration-client/` inside the package.

## Caveats

* glibc only moves forward: it runs on Fedora 44 and newer, not on older releases (the rpm Requires `libc.so.6(GLIBC_2.43)`); same for libstdc++.
* If the GPU/Wayland stack changes drastically (new libwayland soname, glvnd replaced ...), dnf will refuse the package (unsatisfied Requires)
  or it needs a rebuild; a soname bump of a *bundled* library cannot affect it.
* The bundled Qt is a snapshot: Fedora's later security fixes for Qt/Chromium/NSS/ICU are NOT picked up. Rebuild periodically
  (QtWebEngine is a full Chromium).
* Not verified: a real GNOME session (dock icon, portal theme, HiDPI/fractional scaling), other Fedora versions or distributions, GPUs other
  than this machine's NVIDIA 615 (EGL under weston headless; Mesa not exercised), audio output, GTK file dialogs (no gtk3 theme: Qt's
  own/portal dialog), Widevine (Chromium picks Google Chrome's CDM from `/opt/google/chrome` if installed - the only non-package,
  non-system file that was mapped), `rpm` scriptlets (the `--root` test used `--noscripts`).
* `rvio` needs an X display (`DISPLAY`, XWayland is fine): it segfaults in `FBOVideoDevice` without one, also in the original build tree.
* Starting inside the library-hiding namespace was slower (the first window appeared after ~20 s; cold caches), normal start ~2-8 s.

## Licences and patents

* OpenRV: Apache-2.0. Qt 6 / PySide6: LGPL-3.0 (QtWebEngine: LGPL-3.0 plus the BSD/MIT/... licences of Chromium's third-party code); the
  libraries are plain shared objects in `/opt/openrv/lib` and `/opt/openrv/plugins/Qt` and can be replaced. FFmpeg, as configured by this
  build, is **LGPL-2.1-or-later** (`libavcodec license: LGPL version 2.1 or later`; no `--enable-gpl`, no `--enable-nonfree`), so the License
  tag is a combined permissive/LGPL expression, not GPL. `/usr/share/licenses/openrv` has LICENSE, Notice.txt, THIRD-PARTY.md and a Qt note.
* The build configuration (BUILD_NOTES.md) enables the AAC, HEVC, ProRes, DNxHD, AC-3/E-AC-3, MPEG-2, QuickTime RLE and DV decoders that
  OpenRV's defaults disable for patent reasons. Check the patent/licence situation of those codecs in your jurisdiction before redistributing.
* The licence expression in the spec summarises the main components; it is not a legal audit.

## Note for this repository

The built `.rpm` is deliberately **not** published anywhere: it bundles a Qt/QtWebEngine snapshot and FFmpeg decoders
(AAC, HEVC, ...) whose patent/licensing situation depends on the jurisdiction. Build it locally with `build_rpm.sh`.
`work/` and `out/` (git-ignored) are created next to this file.
