# Packaging: the self-contained rpm

The rpm turns the staged build (`build/stage/app`) into a package that carries its own Qt 6.11.2, QtWebEngine, ICU,
NSS, FFmpeg, Python and ~135 libraries copied from the build host, so a later Fedora Qt update cannot break it. It
is built **locally** and never published. The full reference is [`../packaging/README.md`](../packaging/README.md); this
page explains the design and the build flow.

> **Sync note.** The live packaging directory of the workspace (`<project-root>/packaging/`, not tracked) is ahead of
> the copy committed in this repository (`wayland-fedora/packaging/`, last synchronised 2026-10-29). The live copy
> adds step 7b (Mu precompile), the `RV_CRASH_DUMPS_ENABLED=0` default in the launcher, and icons rendered from
> `RV.svg` plus the scalable SVG in the spec (the committed script still cuts them from `RV.ico` / `RV.icns`). The live
> script also assumes it sits in the workspace root (`OQ=$(dirname "$PK")`), whereas the committed one honours `OQ` and
> `SRC` environment variables and finds the source tree relative to the repository. This page describes the live version; check `git log -- wayland-fedora/packaging` to see whether
> the committed copy has caught up.

## Layout and relocation

* Everything installs under **`/opt/openrv`**. The tree is relocatable: it also runs unpacked anywhere
  (`rpm2cpio x.rpm | cpio -idm`, then `opt/openrv/bin/rv`).
* Every ELF file gets an **`$ORIGIN`-relative RUNPATH** set with `patchelf`: only the directories that really hold its
  bundled dependencies (usually one or two) plus `lib/`. Nothing absolute, no reference to the build tree. No
  `LD_LIBRARY_PATH` is used, so child processes such as `xdg-open` do not inherit it.
* **`qt.conf`** files (in `bin/` and `libexec/`) are relative (`Prefix=..`, `Plugins=plugins/Qt`, `Libraries=lib`, ...)
  so Qt looks only at the bundled copies. `PySide6/Qt/{lib,libexec,resources,translations}` are symlinks to the single
  bundled copy instead of a second 470 MB one.
* `/usr/bin/{rv,openrv,rvio,rvls,rvpkg,rvpush}` are symlinks to `/opt/openrv/bin/<name>`.
* The rpm declares **`Conflicts: rv`**: Fedora's kernel-tools package `rv` (the kernel runtime-verification tool) also
  owns `/usr/bin/rv`. `/usr/bin/openrv` never conflicts.
* `ExclusiveArch: x86_64`, `AutoProv: no` (bundled `libQt6*.so.6`, `libav*` ... are never advertised as provides),
  `AutoReq` on with everything the package carries filtered out (`requires-exclude.regex` is generated per build).
  Explicit `Requires: fontconfig xkeyboard-config shared-mime-info`; `Recommends: adwaita-sans-fonts xdg-desktop-portal
  mesa-dri-drivers`.

## The launcher (`launcher/openrv-wrapper.sh`)

One POSIX `sh` script replaces upstream's tcsh wrappers and serves every program: `bin/<name>` execs `bin/<name>.bin`.

* Derives `RV_HOME` from its own symlink-resolved path.
* **Isolation**: unsets `QT_PLUGIN_PATH`, `QT_QPA_PLATFORM_PLUGIN_PATH`, `QML2_IMPORT_PATH`, `QML_IMPORT_PATH`,
  `QT_QPA_PLATFORMTHEME`, `PYTHONHOME`, `BUILD_ROOT`, `LD_PRELOAD`, so a user's environment cannot redirect Qt or Python
  to other copies.
* **Platform selection**: if `QT_QPA_PLATFORM` is unset, `wayland;xcb` when `WAYLAND_DISPLAY` is set or
  `$XDG_RUNTIME_DIR/wayland-0` exists, otherwise `xcb`. Exporting the variable overrides it.
* **Decoration**: `QT_WAYLAND_DECORATION=adwaita` by default (libadwaita look; the plugin ships in
  `plugins/Qt/wayland-decoration-client`).
* **Crash dumps**: `RV_CRASH_DUMPS_ENABLED=0` by default, because `crashpad_handler` is not shipped (see
  [02-technical-discoveries.md](02-technical-discoveries.md#12-crashpad-handler-not-shipped-crash-dumps-disabled-in-the-launcher-packaging)).
* `rv` (only) unsets `LANG`, as upstream's wrapper does.

## Bundled host libraries: `closure.py`, `excludelist.txt`

* `closure.py` computes the `ldd` closure of every ELF file in the tree. A dependency that resolves **outside** the tree
  and is not on `excludelist.txt` is copied to `lib/<soname>` and scanned in turn (two rounds in practice: 128 new
  libraries, then 0). `dlopen-extras.txt` adds libraries that are loaded by name (the NSS token modules
  `softokn`, `freebl`, `nssckbi`). In the recorded run: 135 libraries bundled, 86 deny-listed sonames seen.
* `excludelist.txt` is the AppImage-style list of what must come from the host: glibc, the C++ runtime
  (`libstdc++`, `libgcc_s`, `libgomp`), the GPU stack (libGL/EGL/GLX/gbm/vulkan/drm), Wayland client libraries, the X11
  core, D-Bus / udev / systemd / glib, audio (`libasound`, `libpulse`, `libpipewire`), and fontconfig / freetype /
  harfbuzz. The reasons per group are tabulated in the packaging README.
* The Qt plugin set is chosen explicitly (platforms wayland/xcb/offscreen/minimal, the decoration plugins, shell and
  graphics integrations, the xdg-desktop-portal platform theme, input contexts, selected image formats, tls,
  networkinformation). Deliberately left out: eglfs/linuxfb, `generic`, `multimedia` plugins (they would load the
  host's FFmpeg/GStreamer), KDE `kimg_*`, the GTK3 platform theme, QML imports, Qt tools.

## Desktop integration

* `com.aswf.rv.desktop`: RV's Wayland `app_id` is `com.aswf.rv`, so the file name and `StartupWMClass` match it and
  GNOME shows the right icon in the dock. `Exec=rv %F`, MIME types for common video and image formats.
* Icons: hicolor PNGs at 16, 24, 32, 48, 64, 128, 256, 512 px rendered from `src/bin/apps/rv/RV.svg` with ImageMagick,
  plus the scalable SVG as `openrv.svg`.
* `%post` / `%postun` refresh the desktop and icon caches only if the tools exist and never fail.

## Steps of `build_rpm.sh`

| Step | What |
|---|---|
| 1 | `rsync` the stage into `work/root/opt/openrv`, excluding static libs, headers, Breakpad symbols, test programs, the Vulkan loader, PySide6's private Qt copy; delete dangling links into the host Qt; fix build-tree shebangs |
| 1b | Slim: crash machinery, Python stdlib tests / tkinter / idle / pip / setuptools / Cython / meson, unused PySide6 modules, DevTools resources, locale paks except en-US / es / es-419 |
| 2 | Copy the Qt plugin tree, `QtWebEngineProcess`, `.pak` files and v8 snapshot, locales, translations from the host; write relative `qt.conf` files; link PySide6's `Qt/` directories |
| 3 | Install the single `sh` launcher as every `bin/<name>` |
| 4 | `closure.py`: bundle the host libraries |
| 4b | `strip --strip-unneeded` on all ELF files (keeps `.dynsym`, so linking and `dlopen` are unaffected); 795 MB -> 663 MB in the recorded run |
| 5 | `patchelf --set-rpath` on every ELF file |
| 6 | Desktop file, icons, `/usr/bin` links, licences, the packaging README as `/usr/share/doc/openrv/README.packaging.md` |
| 7 | `closure.py --verify`: with an empty library path every `NEEDED` entry of every ELF must be found through its own RUNPATH inside the tree or be deny-listed; the build fails otherwise. Then the requires-exclude regex is generated |
| 7b | **Mu precompile** (below) |
| 8 | `rpmbuild -bb openrv.spec` (payload prepared above; the spec only packs it; zstd level 19, `w19T0`) |

### Step 7b: precompiling Mu modules

Without it, `rv` compiles Mu from source at every start, because `/opt/openrv` is read-only for users and the package
used to ship no `.muc` (see [03-startup-performance.md](03-startup-performance.md)). The step starts `rv` headless,
with `-debug compile`, and an `-eval` expression that calls `runtime.load_module()` for every `plugins/Mu/*.mu`, which
makes Mu write `.muc` / `.mud` next to each source. Key properties (from the script's own comments):

* Mu has **no staleness check**: a `.muc` silently wins over an edited `.mu`. Hence the `.muc` are generated from the
  final tree, never in `build/stage`.
* Default `MUC_EXCLUDE="external_ioprocess maya_tools rvnuke_mode"`: compiling the first segfaults rv; loading the
  `.muc` of the other two segfaults rv.
* Two passes: compile, then a fresh plain `rv` loads every `.muc` back. The build fails and lists any module whose
  `.muc` is missing or whose load did not return true, and fails if the step wrote any other file into the tree.
* Needs a GL-capable display (the `offscreen` and `minimal` Qt platforms abort without a GL context). `MUC_DISPLAY=auto`
  tries `xvfb-run`, a private `Xvfb -displayfd`, a private headless weston, the current session (a short-lived window
  appears), else stops with install instructions. `MUC_TIMEOUT` (default 60 s) and `MUC_EXCLUDE` are configurable.
* Everything it starts is stopped by PID / process group; private directories are removed on exit.

## Requirements and invocation

```bash
cd <project-root>        # the workspace containing build/stage and packaging/ (live copy)
./packaging/build_rpm.sh # about 1 min without 7b; no sudo, nothing installed, nothing downloaded
# committed copy, from a checkout:  OQ=$OQ wayland-fedora/packaging/build_rpm.sh
```

Needs `rpmbuild`, `patchelf`, `magick` (ImageMagick), `rsync`, `zstd`, `python3`, and for step 7b `xvfb-run` or `Xvfb`
(or weston, or a running session). Optional environment: `STAGE`, `VERSION`, `RELEASE`, `PATCHELF`, `MUC_DISPLAY`,
`MUC_TIMEOUT`, `MUC_EXCLUDE`. Output: `packaging/out/openrv-4.0.0-0.wayland.qt6.1.fc44.x86_64.rpm`
(215 MB, 735 MB installed in the recorded run). Install is the user's step: `sudo dnf install ./...rpm`.

## Caveats

* **Qt and Chromium are frozen at build time.** The libraries are copied from the host (`/usr/lib64`, `/usr/lib64/qt6`,
  `/usr/share/qt6`) and must be the same Qt version OpenRV was built against (6.11.2). After a Fedora Qt update:
  rebuild OpenRV against the new Qt first ([`../MAINTENANCE.md`](../MAINTENANCE.md) section 2), then re-run the script.
  The bundled Qt/Chromium/NSS/ICU do not receive Fedora's later security fixes until you rebuild.
* **Patent-encumbered codecs**: the build enables AAC, HEVC, ProRes, DNxHD, AC-3/E-AC-3, MPEG-2, QuickTime RLE and DV
  decoders that OpenRV disables by default. Check your jurisdiction before redistributing; this is why the rpm is not
  published.
* glibc and libstdc++ only move forward: the rpm requires `libc.so.6(GLIBC_2.43)`-level symbols, so it targets Fedora 44
  and newer.
* **Not verified**: installing with `dnf`/`rpm` for real (scriptlets; the tests used `rpm --root` with `--noscripts` and
  `rpm2cpio`), other Fedora releases, a real GNOME session's dock icon / portal theme, HiDPI / fractional scaling,
  Mesa GPUs, audio output, GTK file dialogs (there is no GTK3 platform theme).
* `rvio` needs an X display (XWayland is fine); `rvio_sw` is not shipped (it needs OSMesa, which Fedora no longer ships).
* Widevine: Chromium may pick Google Chrome's CDM from `/opt/google/chrome` if installed; that was the only
  non-package, non-system file seen mapped in the tests.
* The licence expression in the spec summarises the main components; it is not a legal audit.

## Size history

First version 347 MB rpm (zstd 10) / 1222 MB installed. After slimming: 215 MB (zstd 19) / 735 MB installed. The largest
items installed: `libQt6WebEngineCore` 205 MB, Python 3.13 stdlib + site-packages 159 MB, `plugins/Mu` 33 MB,
`libicudata` 31 MB, numpy.libs (OpenBLAS) 26 MB, numpy 25 MB, `rv.bin` 21 MB, `libavcodec` 17 MB. No LTO or
`-march` tuning was done (hours of rebuild for a few percent, and portability loss).
