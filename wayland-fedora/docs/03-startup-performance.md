# Startup performance

Goal: shorten the time from launching `rv` to a usable window, on the installed, self-contained rpm. All numbers
below are from one machine (Fedora 44, NVIDIA) and one small test session; treat them as relative, not as
benchmarks. "First frame" = time to the first rendered frame of the main window. "Idle" = time until the process stops
doing startup work (CPU quiet).

## Methodology

The machine had no `perf` and no `strace` installed and nothing could be installed, so the tools were improvised:

* **Poor-man's profiler**: attach `gdb` to `rv.bin` repeatedly during startup and take the main thread's backtrace
  (repeated samples during the startup window). Frames that show up in most samples are where the time goes. Run `rv.bin` directly
  (the `bin/rv` shipped by upstream is a csh wrapper) with `RV_HOME` and `LD_LIBRARY_PATH` set.
* **Python imports**: `PYTHONPROFILEIMPORTTIME=1` prints a per-module import cost table for the embedded Python.
* **Time to first frame**: `WAYLAND_DEBUG=client` and the timestamp of the first `wl_surface.attach` carrying a buffer
  for the main window, relative to process start. Works on native Wayland in a private compositor, no screenshots
  needed.
* **Cold-cache simulation**: drop a file tree from the page cache with `posix_fadvise(POSIX_FADV_DONTNEED)` (no root
  needed, unlike writing to `/proc/sys/vm/drop_caches`) and then start `rv`; the amount of data read from disk
  was compared with and without the optimisations.
* **Interleaved runs**: A/B variants run alternately (A B A B ...) rather than in blocks, so drift in CPU frequency,
  cache state and background load affects both equally. The number of runs per variant and the statistic used (median or mean) were not recorded in the repository.

## Findings

| Finding | Evidence | Action |
|---|---|---|
| `rv.runtime` called `QWebEngineProfile.defaultProfile()` during startup, which initialises **Chromium on the main thread** (about 1 s, plus ~1.5 s of CPU across the `QtWebEngineProcess` children) even if no web view is ever shown | gdb samples and import timing during startup; the 1 s / 1.5 s figures are from the commit messages of `43cb7f1` / `0495a0f` | Defer, then make lazy (commits below) |
| **Mu sources compiled on every launch**: `/opt/openrv` is read-only for users and the package shipped no `.muc`, so the Mu compiler ran each time (and again whenever an optional package mode such as session_manager, annotate or doc_browser was switched on) | gdb samples in the Mu compiler; Mu writes `.muc` only next to the `.mu`, which users cannot write to, and has no staleness check (a `.muc` silently wins over an edited `.mu`) | Precompile in the rpm with `rv -debug compile` (build step 7b, see below) |
| `certifi` imported just to learn the CA bundle path (`sitecustomize.py`) | `PYTHONPROFILEIMPORTTIME`: ~0.2 s | Locate the file with `importlib.util.find_spec` (`bd35652`) |
| Dynamic linking (`ld.so`) | ~15 ms measured | Nothing to gain; prelink or similar is not worth it |
| AJADevices plugin load | cost 0 in samples | Left alone |
| Vulkan / GBM messages on stderr | "Failed to find vkGetPhysicalDeviceWaylandPresentationSupportKHR", "GBM is not supported" | Harmless; no time cost |
| QSS (style sheet) parsing | no measurable effect | Left alone |

## Commits

| Commit | Change | Effect reported |
|---|---|---|
| `43cb7f1` | `rv.runtime`: do the web engine user-agent setup 600 ms after startup (a `QTimer.singleShot`) instead of at import | First window on Wayland 2.3 s -> 1.3 s (as measured when it was committed) |
| `0495a0f` | `rv.runtime`: no longer scheduled at all. `setup_webview_default_profile()` imports PySide lazily, is idempotent, and is called by `webview2.py` right before it creates its `QWebEngineView`. The Mu `doc_browser` cannot call it and uses Chromium's default user agent | Chromium never starts unless a web view is shown |
| `bd35652` | `src/build/sitecustomize.py`: find `cacert.pem` next to the `certifi` package with `importlib.util.find_spec`; fall back to `certifi.where()` | ~0.2 s |
| (rpm) | `packaging/build_rpm.sh` step 7b: precompile Mu to `.muc` / `.mud` in the final tree | Mu no longer compiled at launch |

## Numbers

Warm = files in the page cache; cold = the install tree dropped from the cache with `posix_fadvise` first.

| Measure | Before | After |
|---|---|---|
| Time to first frame, warm | 1.76 s | 1.41 s |
| Time to idle, warm | 2.90 s | 1.45 s |
| Time to idle, cold | 3.70 s | 1.55 s |
| Data read from disk, cold start | 205 MB | 23 MB |

The cold-start gain is mostly data that is no longer touched (Chromium initialisation and Mu compilation). The
first-frame improvement is smaller than the idle improvement; the table does not say why, and no further analysis of
that difference was done.

## What remains inherent

* Loading **PySide6 / shiboken** (large extension modules and the Qt libraries they pull in).
* `opentimelineio` importing `urllib` and friends at import time.
* `rv.bin` links **`libQt6WebEngineCore` directly**, so its (large) library is mapped and relocated at start even
  though Chromium is no longer initialised.
* Python itself starting and importing the RV UI packages.

Removing these would need either lazy-importing deeper into the Python packages or restructuring the link of `rv.bin`;
neither was attempted.

## Round 2 (in progress)

> **PLACEHOLDER. A second optimisation round is being worked on by another agent at the time of writing. No results
> are recorded here yet and none must be assumed.**

Planned items (from the task description; update this section with measured numbers when they land):

* [ ] Precompile the **37 optional `.mu`** modules in addition to those loaded at start (the live build script's step
  7b generates a `.muc` for every `plugins/Mu/*.mu` except a small exclude list; the workspace packaging README says
  "48 `.muc` for 51 `.mu`", i.e. 51 minus the 3 excluded; how the figure 37 relates to that is unverified).
* [ ] Make step 7b **robust when run headless** (needs a GL-capable display: `xvfb-run`, private Xvfb, private weston,
  or the current session; verification pass that loads every `.muc` back in a fresh process).
* [ ] **Parallelise startup** work where it is independent (what exactly was parallelised: TBD).
* [ ] Python-side lazy imports in `otio_reader` and `session_manager` (uncommitted work in the tree: files
  `src/plugins/rv-packages/otio_reader/otio_reader_plugin.py` and
  `src/plugins/rv-packages/session_manager/local_thumbnail_gen.py` were modified but not committed when this was
  written; their purpose is not documented yet).
* [ ] Re-measure with the same methodology (interleaved, warm and cold) and fill in a table like the one above.
* [ ] Sync the committed copy of `packaging/` (see [04-packaging-rpm.md](04-packaging-rpm.md)).

### What already exists in the live packaging script (state when written)

The workspace's `packaging/build_rpm.sh` (not yet in git) contains step 7b. Facts taken from its header comments:

* `rv -debug compile` writes `.muc` (and `.mud` docs) next to each `.mu` that is loaded during the run; an `-eval`
  expression calls `runtime.load_module()` for every `plugins/Mu/*.mu` so that all of them are compiled.
* Excluded by default (`MUC_EXCLUDE`): `external_ioprocess` (compiling it segfaults rv in
  `Mu::Archive::Writer::freeze()`), `maya_tools` and `rvnuke_mode` (their `.muc` segfaults when loaded in a fresh rv,
  the sources load fine).
* Pass 1 compiles; pass 2 is a plain rv in a fresh process that loads every `.muc` back; the build fails if a module has
  no loadable `.muc`, or if the step writes anything else into the tree.
* The workspace packaging README states the result as 48 `.muc` (+ `.mud`) for 51 `.mu` (not independently re-run
  for this document).
