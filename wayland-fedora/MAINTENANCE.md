# Maintenance checklist

Everything here assumes the layout from the README: workspace `$OQ`, this repository checked out as `$OQ/src`, branch
`wayland-qt6`. Paths below are relative to the repository root unless they start with `$OQ`.

## 0. Things that must stay true

* Fork `main` == upstream `main`; never commit there. Work happens on `wayland-qt6` (or a dated successor, see 1).
* The twelve code commits stay small, one concern each; docs/scripts live only under `wayland-fedora/`.
* After any change to the code commits run `git format-patch` again (the update script does it) so `patches/` matches.
* No binaries (rpm, build trees) in git. `packaging/.gitignore` already excludes `work/`, `out/`, `*.rpm`.

## 1. New upstream OpenRV

```bash
wayland-fedora/tools/update-from-upstream.sh            # fetch, dated branch, replay, report; add --push to push to the fork
```

* It fetches `upstream` (falls back to `origin`), creates `wayland-qt6-YYYYMMDD` at upstream `main`, and `git cherry-pick`s every
  commit above the newest `upstream-base-*` tag one at a time. For each it prints `OK` or `CONFLICT` plus the conflicting files and
  rolls the conflicting one back; the rest are still tried. Exit status is non-zero if anything conflicted.
* Then it tags the new base `upstream-base-<hash>` and regenerates `wayland-fedora/patches/` (`git format-patch` limited to
  paths outside `wayland-fedora/`, plus `source_patches.diff`) in one commit.
* Conflicts: `git cherry-pick <hash>`, fix, `git add`, `git cherry-pick --continue`, then regenerate patches:
  ```bash
  B=$(git tag --list 'upstream-base-*' --sort=-creatordate | head -1)
  rm wayland-fedora/patches/0*.patch
  git format-patch --binary -o wayland-fedora/patches $B..HEAD -- . ':(exclude)wayland-fedora'
  git diff $B..HEAD -- . ':(exclude)wayland-fedora' > wayland-fedora/patches/source_patches.diff
  ```
* Expect conflicts most likely in: `cmake/defaults/CY2026.cmake` (upstream bumps versions itself), `cmake/dependencies/python3.cmake`
  (wheel list), `src/lib/app/RvCommon/GLWindow.cpp` / `RvDocument.cpp` (input and menu code), `src/build/make_pyside6.py`.
  If upstream fixed one of the problems itself (e.g. dropped the `evex512` dependency, fixed the wildcard disconnect), drop that commit
  and say so in `README.md` / `BUILD_NOTES.md`.
* Build and verify (section 7), then publish: `git push fork wayland-qt6-YYYYMMDD upstream-base-<hash>` and
  `gh repo edit homeless3d/OpenRV --default-branch wayland-qt6-YYYYMMDD`. Or fast-forward the long-lived `wayland-qt6` to the new branch.
* Keep fork `main` in sync: `gh repo sync homeless3d/OpenRV --branch main` (fast-forward only).

## 2. New Fedora Qt minor (6.11 -> 6.12 ...)

The build uses the *installed* runtime Qt plus the unpacked `-devel` rpms, and builds PySide6 from source against it; all three must
be the same Qt version.

1. `sudo dnf upgrade` (yours to run), then rebuild the Qt prefix: `wayland-fedora/tools/make_qt_prefix.sh` (it warns if the
   downloaded `-devel` rpms and the installed Qt differ). Check `-DRV_DEPS_QT_LOCATION` and `LLVM_INSTALL_DIR` (clang major version
   changes the `llvmNN` directory name -- the script prints the exports).
2. **PySide6 pin**: `cmake/defaults/CY2026.cmake`, variables `RV_DEPS_PYSIDE_VERSION` and `RV_DEPS_PYSIDE_DOWNLOAD_HASH` (MD5 of
   `pyside-setup-everywhere-src-<ver>.zip` from `https://download.qt.io/official_releases/QtForPython/pyside6/PySide6-<ver>-src/`;
   `md5sum` the downloaded zip). PySide6 must match Qt's minor version.
   The `RV_DEPS_QT_VERSION` pin in the same file is only used for the macOS/Windows WebEngine download; with a system Qt the version
   is read from Qt6Core, so it can stay.
3. The two PySide tool patches `cmake/dependencies/patch/pyside6_tools_optional_qt_app_bundles*.patch` must still apply
   (`make_pyside6.py` tolerates the clang-only `ShibokenHelpers` patch not matching). If PySide6 reorganised its tree again, adapt
   `src/build/make_pyside6.py` (patch 0001 already handles the 6.9+ move of `ApiExtractor` to `shiboken6_generator` and the
   `RV_PYSIDE_SYSTEM_LLVM_DIR` shortcut).
4. **Qt API fixes**: expect compile errors from removed/deprecated API, mainly in `src/lib/app/RvCommon/*` and the other Qt-using libraries under `src/lib/`. Components RV links: `src/lib/app/RvCommon/CMakeLists.txt` -- the versionless `Qt::GuiPrivate` target does not exist on the system
   Qt, patch 0001 does `find_package(Qt6 ... GuiPrivate)`. If a new private module is needed, add it the same way (needs the matching
   `qt6-qtbase-private-devel`).
5. Behaviour to re-check, because it depends on Qt/QtWayland internals: patch 0002 (surfaceless EGL leaves `GL_NONE` draw buffer),
   patch 0003 (QtWayland `Pointer::pointer_leave()` resets the buttons; `setMouseGrabEnabled` popup-only) -- if a QtWayland release fixes
   either, the workaround can go; patch 0004 (Qt's wildcard-`disconnect` warning).
6. Rebuild the rpm (section 6) -- it copies Qt from the host at build time and must match the build.

## 3. New GCC / glibc / toolchain

Compat workarounds, where they live, and the commit that carries them:

| Problem (GCC 16 / current glibc) | Workaround | Carried by |
|---|---|---|
| numpy 2.3.0 from source: highway uses the removed `evex512` target attribute | `numpy` in `RV_PYTHON_WHEEL_SAFE` (`cmake/dependencies/python3.cmake`); the cache variable needs `cmake -U RV_PYTHON_WHEEL_SAFE` once | commit 0001 |
| libdeflate / OpenEXR / highway reference `evex512` | `CFLAGS=-D__EVEX512__` (`env.sh`), fresh OpenEXR build dir | env.sh only |
| yaml-cpp (inside OCIO) misses `<cstdint>` | `CXXFLAGS="-include cstdint ..."` (`env.sh`) plus, if the sub-build ignores it, prepend `#include <cstdint>` to `build/RV_DEPS_OCIO/build/ext/build/yaml-cpp/src/yaml-cpp_install/src/emitterutils.cpp` | env.sh / manual |
| Breakpad 2024.02.16: `minidump_stackwalk` / `microdump_stackwalk` fail to link (missing `FastSourceLineResolver` vtable) | manual link line, see `BUILD_NOTES.md` "Fixes applied to downloaded dependency sources" | manual (not in git) |
| stricter C: implicit declarations, int conversions, incompatible pointers in vendored C | `-Wno-error=...` list in `CMAKE_C_FLAGS` (README quick start) | cmake command line |
| C++: `-fpermissive`, `-Wno-template-body` | `CMAKE_CXX_FLAGS` (README quick start) | cmake command line |
| link of `rvio`/`rvio_sw` against the system WebEngine/FFmpeg symbol | `-Wl,--allow-shlib-undefined` | cmake command line |
| `CMAKE_POLICY_VERSION_MINIMUM=3.5` for old third-party CMake projects under CMake 4 | `env.sh` | env.sh |

Work through the build log with `ninja -k 0` and add each new fix either to a commit (if it is a source/cmake change in the
OpenRV tree) or to the table above (if it is a flag or a manual patch of a downloaded dependency). Prefer a commit when it is
a real source fix that upstream might accept.

## 4. New FFmpeg (system or OpenRV's bundled version)

* **`av_stream_get_first_dts`** (patch 0005): `cmake/dependencies/patch/ffmpeg_n8.0_av_stream_get_first_dts.patch`, applied from
  `cmake/dependencies/ffmpeg.cmake` (`RV_FFMPEG_PATCH_COMMAND_STEP`, only `RV_FFMPEG_8`, non-Windows). It appends the function
  returning `cffstream(st)->first_dts` to `libavformat/utils.c`. When OpenRV moves to another FFmpeg: check the patch still applies
  (`libavformat/utils.c`, `cffstream()`), and check which symbols the system `libQt6WebEngineCore.so.6` imports that the bundled
  libraries do not export:
  ```bash
  nm -D --undefined-only /usr/lib64/libQt6WebEngineCore.so.6 | grep -E ' (av|sw)' | awk '{print $2}' | sort > /tmp/want
  for l in $OQ/build/stage/app/lib/libav{codec,format,util}.so.* $OQ/build/stage/app/lib/libsw*.so.*; do nm -D --defined-only $l; done | awk '{print $3}' | sort > /tmp/have
  comm -23 /tmp/want /tmp/have        # must be empty
  ```
  Add another shim like the existing one for anything that shows up. If OpenRV does it itself or Qt stops importing it, drop patch 0005.
* **Decoders**: OpenRV disables some decoders for patent reasons (`cmake/dependencies/ffmpeg.cmake`, `NON_FREE_DECODER_TO_DISABLE`) and
  `mio_ffmpeg` blocks more through `-D__FFMPEG_ENABLE_NON_FREE_DECODER_<name>`. Re-enable with the **cache variable**
  `-DRV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE="aac;hevc;ac3;ac3_fixed;eac3;mpeg2video;vp9;prores;dnxhd;qtrle;dvvideo"` (not stored in git; it is in
  the README command). Check the licence/patent position first. `vp9` stays absent because OpenRV always passes `--disable-parser=vp9`.
* Rebuild only FFmpeg and relink (about 8 minutes) -- exact commands in `BUILD_NOTES.md`, section "FFmpeg".
* Verify with the movie test (section 7): a plain `ffmpeg`/PyAV-encoded `.mp4` must play.

## 5. New PySide6 only (same Qt)

Only the pin in `cmake/defaults/CY2026.cmake` (version + MD5), see 2.2/2.3. PySide6 6.8.3 -> 6.11.2 was exactly that plus the
`make_pyside6.py` layout adaptation.

## 6. Rebuilding the rpm

```bash
OQ=$OQ wayland-fedora/packaging/build_rpm.sh        # ~1 min; needs rpmbuild patchelf magick rsync zstd python3 (no sudo)
```

Output `wayland-fedora/packaging/out/openrv-<VERSION>-<RELEASE>.x86_64.rpm`. `VERSION`, `RELEASE`, `STAGE`, `SRC`, `OQ` can be
overridden by environment variables. It copies Qt/Chromium libraries from the *host* at build time, so rebuild OpenRV first
after a Qt update. Tune `packaging/excludelist.txt` (what the package must take from the system) and `dlopen-extras.txt` when
new `dlopen()`ed libraries appear; `closure.py --verify` fails the build on unresolved NEEDED entries. Then run the package tests
(`packaging/test/smoke.sh`, `classify_maps.py`, `hide_system_libs.sh`; usage in their headers). Never upload the rpm (see README).

## 7. Verification to rerun after every change

Test beds: `tools/testbed/` (see its README for the exact commands).

1. **Starts natively on Wayland**: headless weston, `run_rv_wayland.sh test.mov -play`, screenshot; `libadwaita.so` in
   `/proc/<pid>/maps`; no "unsupported version"/"GPU lacks fragment program" in the log (GL format fix).
2. **Viewport not black** (patch 0002): the screenshot shows image, timeline and HUD.
3. **Scrub test** (patch 0003): headless mutter + `ptr.py` + `probe.py`; drag in the timeline and go outside the window; the frame keeps changing
   until the release.
4. **Movie test**: `make_jpg_seq.py`, `make_movies.py`, `make_codec_movies.py` (needs PyAV), then `run1.sh` for each file:
   h264 mp4, h264+aac, B-frames, hevc, prores, mpeg4 mov, jpg sequence. All should play with advancing frames, no `sendPacketToDecoder`
   in the log, no crash dump.
5. **Menu warnings** (patch 0004): toggle a mode twice; the log must not contain `wildcard call disconnects`.
6. **xcb fallback**: Xvfb, `QT_QPA_PLATFORM=xcb`, plays.
7. Not automated and still open: a real GNOME session, audio, HiDPI. If you can, test there and update the matrix in `README.md`.

Test bed quirks (also in `BUILD_NOTES.md`): `weston-screenshooter` sometimes hangs (restart weston by pid), needs `weston --debug`;
mutter 50 occasionally aborts in `load_cursor_from_theme` (restart); do not use `pkill -f`/`pgrep -f` with a pattern in the same command line.

## 8. Rebuilding the Qt prefix by hand

`tools/make_qt_prefix.sh [OUT]` does: `dnf download --disablerepo='*' --enablerepo=fedora --enablerepo=updates` of the `-devel`
rpms + `qt6-qttools`/`qt6-linguist` (real `lupdate`/`lrelease`) + `clang-devel`/`clang-libs`/`llvm-devel`; `rpm2cpio | cpio` into
`OUT/root`; then `tools/qt_prefix_farm.py` builds `OUT/prefix` (symlink farm over the unpacked rpms and the installed runtime Qt, real copy
of the cmake dirs, real `lib/` dir, private `qtpaths` + `qt.conf`, never-executed stubs for tools/libs the Qt/LLVM cmake files import but
no package provides). The docstring of `qt_prefix_farm.py` explains each fix. If a new Qt release adds a package the build `find_package`s,
add it to `PKGS` (or `EXTRA_PKGS=...`).
