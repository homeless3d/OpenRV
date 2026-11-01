# Testing and test beds

The work was done in an environment from which a real GNOME session could not be screenshotted or driven. Everything
was therefore checked on **private compositors and X servers** started for the purpose, so the user's desktop was
never touched. The scripts are in [`../tools/testbed/`](../tools/testbed) and [`../packaging/test/`](../packaging/test);
the commands are in their READMEs and headers. This page explains the approach, what each bed can and cannot show,
and the pitfalls.

## The test beds

| Bed | Used for | Limits |
|---|---|---|
| **Private headless weston** (`weston --backend=headless --renderer=gl --socket=wl-test`, run with `--debug`) + `weston-screenshooter` | Screenshots on native Wayland: viewport drawing, timeline, HUD, dialogs, movie playback | The screenshooter output is **upside down** (flip with `magick f.png -flip out.png`). It is **flaky**: it sometimes hangs forever, even after the client exits; kill that weston by PID and start a new one. It needs `weston --debug`. The Qt 5 reference build crashes weston, so Qt 5 was compared on Xvfb instead |
| **Private headless mutter** (GNOME's compositor: `dbus-run-session -- mutter --headless --wayland --no-x11 --wayland-display=wl-mut --virtual-monitor 1280x800`) with pointer injection through the **`org.gnome.Mutter.RemoteDesktop` D-Bus API** (`tools/testbed/ptr.py`) | Input behaviour with the real compositor's focus rules: timeline scrub leaving the window, popups, dialog resize | **No screenshots.** Observation is by a `-pyeval` probe that writes events to a file, plus `WAYLAND_DEBUG=1`. mutter 50.6 occasionally aborts in `load_cursor_from_theme` (restart it). Keep one RemoteDesktop session for a whole gesture: stopping it removes the seat's pointer. Relative motion is 1:1 and clamps at 0,0, so "move -10000,-10000" homes the pointer. Use the system `python3` with `gi` (the venv Python has none) |
| **Xvfb** | The xcb fallback; the Qt 5 reference build; comparing window sizes and look with the original | xcb only |
| **gdb** on `rv.bin` | Root-cause work: confirming that `paintGL` ran, reading `GL_DRAW_BUFFER`, backtraces of Qt warnings | `bin/rv` is a **csh wrapper**; run `stage/app/bin/rv.bin` directly with `RV_HOME` set and `LD_LIBRARY_PATH=stage/app/lib`. RV installs its own Qt message handler, so `QT_LOGGING_RULES` output is swallowed |
| **Unprivileged user+mount namespace** (`packaging/test/hide_system_libs.sh`, `unshare -r -m`) | Proving the rpm uses only its bundled libraries: `/usr/lib64` is replaced by a symlink farm hiding the host Qt6, ICU, FFmpeg, NSS, xkbcommon, xcb-util, webp, abseil ... | Startup inside it was slow (cold caches) |
| **`/proc/<pid>/maps` classification** (`packaging/test/smoke.sh`, `classify_maps.py`) | Sorting every mapped path outside the package into deny-listed system lib / private dependency of such a lib / GPU driver payload / data; anything else is a violation | Run with a scrubbed environment (`env -i HOME XDG_RUNTIME_DIR WAYLAND_DISPLAY [DISPLAY]`) |

## Test media

Generated with the scripts in `tools/testbed/`, not stored in git:

* `make_jpg_seq.py`: a numbered colour test sequence `f.0001.jpg ...` (24 frames, 960x540, hue per frame, "frame NNNN" text and a moving square), so
  "frames advance and are the right ones" can be checked on a screenshot.
* `make_movies.py` (PyAV): `test.mp4` (H.264) and `test.mov` (mpeg4).
* `make_codec_movies.py` (PyAV): H.264 + AAC, H.264 with B-frames (`bf=3`), HEVC (libx265), ProRes 422 10-bit
  (`prores_ks`).
* `run1.sh NAME FILE`: plays the file with `-play` under a running weston and takes three screenshots; afterwards it
  reports whether `rv.bin` is still alive (empty = it died).
* `probe.py`: loaded into rv with `-pyeval` (`PROBE_OUT=file`), logs the mouse events the viewport window receives and
  the current frame. Python stdout goes to RV's log, hence the file.

## What was verified where

| Area | Private compositor / X server | Real GNOME session |
|---|---|---|
| Native Wayland start, libadwaita frame | weston and mutter headless; `libadwaita.so` seen in `/proc/<pid>/maps` | Used by the maintainer; not captured by automated evidence |
| Viewport draws (0002) | weston screenshots: jpg sequence, timeline, cache bar, HUD | Maintainer-reported working (image renders); no stored capture |
| Timeline scrub (0003) | mutter + RemoteDesktop injection: scrub continues outside the window, release over the toolbar ends it, right-drag scrub, popups | Maintainer-reported working; no stored capture |
| Menu warnings (0004) | warnings 222 -> 0 per rebuild (log count) | Maintainer-reported (no flood) |
| Open dialog (0007) | weston capture: button complete; mutter: edge resize and click on the former notch | Maintainer-reported working |
| Video decode (0005) | weston `-play`: H.264, H.264+AAC, B-frames, HEVC, ProRes, mpeg4 mov, jpg sequence; no `sendPacketToDecoder`, no crash dump | not recorded |
| Window size / look (0006) | xcb 1024x657 equals the Qt 5 build; Wayland 1024x655 client | not recorded |
| xcb fallback | Xvfb: starts and plays | n/a |
| Self-contained rpm | unpacked privately (`rpm2cpio`, `rpm --root` in `unshare -r`), scrubbed env, host libs hidden: 0 stray mappings; QWebEngineView renders (`loadFinished ok=True`) | **not installed** with `dnf` |

"Maintainer-reported" means the project owner said so in the working session; the repository holds no screenshot or
log for it. Nothing in the repository verifies behaviour on HiDPI, fractional scaling, other compositors, Mesa GPUs or
audio. See [06-open-issues.md](06-open-issues.md).

## Re-running the checks

[`../MAINTENANCE.md`](../MAINTENANCE.md) section 7 lists the checks to rerun after every change (native Wayland start,
non-black viewport, scrub test, movie test for each codec, no `wildcard call disconnects` after toggling a mode twice,
xcb fallback).

## Pitfalls (learned the hard way)

* **`pkill -f <pattern>` and `pgrep -f <pattern>`** match the shell that is running the command (its own command line
  contains the pattern), so a wait loop or a cleanup can kill or wait on itself. Kill by PID, or use `pgrep -x`.
* **`pgrep -x <name>` and the 15-character limit**: the kernel truncates process names (`comm`) to 15 characters, so
  `pgrep -x` with a longer name never matches. `rv.bin` is short enough; longer names (for example
  `QtWebEngineProcess`) need `-f` on a distinctive path or a lookup by parent PID.
* **One `ninja` at a time**: two concurrent runs corrupted stage copy steps early in the build.
* **Screenshots upside down** from `weston-screenshooter` (flip them), and stale `wayland-screenshot-*.png` files pick
  the wrong image: delete before taking a new one.
* **RV swallows Qt logging**; use gdb or a Python probe writing to a file.
* **Never use the real session's display for tests**: set `WAYLAND_DISPLAY` to the private socket and, for X11,
  use a private `DISPLAY`. `rvio` segfaults without an X display.
* When a test needs a clean, comparable environment, start the program with `env -i` and pass only
  `HOME XDG_RUNTIME_DIR WAYLAND_DISPLAY [DISPLAY] PATH`.
