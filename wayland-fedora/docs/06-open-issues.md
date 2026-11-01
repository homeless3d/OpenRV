# Open issues, caveats and backlog

An honest list. "Unverified" means nobody checked, not that it is broken.

## Not verified at all

| Area | Notes |
|---|---|
| **HiDPI / fractional scaling** | Never tested; window sizes, the libadwaita frame, the menubar height and icon scaling are untested at scale != 1 |
| **Other compositors** (KDE KWin, Sway, wlroots, Weston desktop shell) | The scrub fix (0003) depends on mutter's pointer-focus behaviour as observed; other compositors may behave differently (possibly better, possibly not). Touch and tablet input untested |
| **Audio output** | No sound device in the test environment. AAC was only demuxed and decoded. PulseAudio / PipeWire output through RV is unverified |
| **Other Fedora versions / distributions** | One machine: Fedora 44, NVIDIA 615.71, GCC 16, Qt 6.11.2. The rpm requires glibc 2.43-level symbols, so it cannot run on older Fedora |
| **GPUs other than NVIDIA proprietary** | Mesa (AMD / Intel) not exercised. Patch 0002 (surfaceless EGL `GL_NONE` buffers) is spec behaviour, so Mesa should be affected equally, but this was not checked |
| **Installing the rpm with `dnf`** | Only unpacked and run privately; scriptlets (desktop and icon cache) not run |
| **Web panels in daily use** | A `QWebEngineView` created from Python renders; interactive use of the built-in web pages is untested |

## Known issues and rough edges

* **Fresh full rebuild is not scripted end to end.** `make_qt_prefix.sh` is scripted (and was re-run against the
  downloaded rpms), but the rest is manual: the Breakpad `minidump_stackwalk` link line, the yaml-cpp `<cstdint>`
  include, the venv, the extra sysroot and perl modules, and PySide6's read-only directories during `setup.py install`.
  [`../BUILD_NOTES.md`](../BUILD_NOTES.md) is the authority. Expect to redo them the first time.
* **Ghost / "hand" buttons in the bottom bar.** Some buttons in the bottom toolbar look like ghost or hand-shaped
  items. Reported by the maintainer; not investigated, cause unknown.
* **Display label** shows the monitor model ("SAM LU28R55 DP-5" style) where the original showed the connector
  ("DP-5"). Not investigated; the cause (probably the screen name Qt 6 reports on Wayland) is unverified.
* **`doc_browser.mu` user agent without " RV/4.0.0".** Since commit `0495a0f` the profile user agent is only extended
  when `webview2` creates a web view (it calls `setup_webview_default_profile()`). The Mu `doc_browser` cannot call
  Python, so after the lazy WebEngine start it uses Chromium's default user agent. Web pages that key on the `RV/` suffix
  would behave differently there. Documented in the commit message; no workaround yet.
* **Edited `.mu` with a stale `.muc`.** The rpm ships precompiled `.muc` next to the Mu sources, and Mu has no
  staleness check: a `.muc` silently wins over an edited `.mu`. Anyone editing files under `/opt/openrv/plugins/Mu` must
  delete the matching `.muc` / `.mud`. In a source build (`build/stage`) no `.muc` are generated, so this only affects
  the rpm.
* **Three Mu modules are not precompiled** (`external_ioprocess`, `maya_tools`, `rvnuke_mode`): compiling or loading
  them crashes rv (an upstream Mu issue). They still load from source.
* **VP9 is unavailable.** OpenRV always passes `--disable-parser=vp9`, so the decoder is not built even with `vp9` in
  `RV_FFMPEG_NON_FREE_DECODERS_TO_ENABLE`. Not pursued.
* **The `patches/` directory is behind the branch.** Patches 0001-0007 and `source_patches.diff` do not include the icon
  and startup commits (`b3088f4`, `43cb7f1`, `0495a0f`, `bd35652`).
* **The committed `packaging/` is behind the workspace copy** (step 7b, crash-dump default, SVG icons); see
  [04-packaging-rpm.md](04-packaging-rpm.md).
* **Size grip guard is Wayland-only.** Patch 0007 removes the 17x17 size grip only on Wayland. The same overlap exists
  on X11 (and in the original Qt 5 build); X11 was left unchanged on purpose to keep behaviour identical to upstream
  there. It could be fixed for X11 too (for example by keeping the grip but leaving room for it in the layout margins)
  and is a candidate for an upstream pull request.
* **Menu bar font** follows the platform theme (Sans on xcb, Adwaita Sans on GNOME), so the menubar is 21 px on
  Wayland against 23 px under Xvfb at 100 dpi.
* **Who else connects to the QMenu `destroyed()` signal** (the other half of the Qt 6.11 warning, item 6) was not
  identified; the warning is gone because RV no longer does a wildcard disconnect.
* **Harmless startup messages** about Vulkan and GBM remain (Chromium falling back to Vulkan / software rendering).

## User-side, not part of the repository

* **GNOME title bar height.** The libadwaita window frame may look too tall or short depending on the user's GTK
  settings. The maintainer adjusted it with a user stylesheet (`~/.config/gtk-4.0/gtk.css`, a `min-height` of 42 px on the
  titlebar). That is a personal desktop setting, not something the package ships or should change.

## Maintenance risks

* **Qt and Chromium in the rpm are frozen** at the version copied at build time; security fixes need a rebuild.
* **Upstream drift**: expected conflict points are `cmake/defaults/CY2026.cmake`, `cmake/dependencies/python3.cmake`,
  `GLWindow.cpp`, `RvDocument.cpp`, `make_pyside6.py`. `tools/update-from-upstream.sh` replays the commits and reports
  conflicts per commit ([`../MAINTENANCE.md`](../MAINTENANCE.md)).
* **Workarounds that should disappear** when upstream or Qt fix the cause: patch 0003 (QtWayland resets buttons on
  `wl_pointer.leave`), patch 0002 (if Qt initialises the draw buffer on surfaceless contexts), patch 0005 (if QtWebEngine
  stops importing `av_stream_get_first_dts`), numpy as a wheel (if highway supports GCC 16).

## Licence and clean-room note

* OpenRV is **Apache-2.0**; the changes in this repository are under the same licence. Qt 6 and PySide6 are LGPL-3.0;
  QtWebEngine adds the licences of Chromium's third-party code; FFmpeg as configured here is LGPL-2.1-or-later (no
  `--enable-gpl`, no `--enable-nonfree`).
* Everything documented here is derived from OpenRV's Apache-2.0 sources, from the behaviour of the builds, and from
  public Qt / Wayland / Mesa documentation. It is **not** derived from the proprietary Autodesk RV binaries, and no such
  material is published or quoted in this repository.
* The Rust prototype `rvr` mentioned in [01-journey.md](01-journey.md) was a separate, clean-room effort and is not part of
  this repository.
* Binaries are not distributed. The rpm bundles a Qt/QtWebEngine snapshot and enables FFmpeg decoders (AAC, HEVC,
  ProRes, DNxHD, AC-3, MPEG-2, DV, ...) whose patent situation depends on the jurisdiction; build it yourself and
  check your local rules before redistributing.
